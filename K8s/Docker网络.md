# Docker 网络

> **Docker 单机网络靠 veth pair + Linux bridge + iptables NAT**：每个容器一个独立 Network Namespace，里面只有 lo 和一根 veth；veth 另一端插到宿主的 docker0 网桥；容器访问外网走 SNAT，外网访问容器走 DNAT。**跨主机方案靠 CNI 插件**——overlay 封 VXLAN、calico 走 BGP、cilium 用 eBPF——K8s Pod 网络全部建立在这套之上。
>
> 本篇要解决面试官四个连环追问：
>
> ① **容器为什么能有独立 IP？**——Network Namespace + veth pair + bridge
> ② **`docker run -p 8080:80` 怎么实现端口映射？**——iptables DNAT 规则
> ③ **跨主机容器怎么通信？**——overlay / flannel / calico / cilium 四派对比
> ④ **CNI 是什么？跟 Service 什么关系？**——CNI 给 Pod IP，Service 在 Pod IP 之上做 LB
>
> 跟其它模块的关系：
> - 前置：[Docker 容器原理](./Docker容器原理.md) Network Namespace 章节
> - 下游：[Service 与 kube-proxy](./Service与kube-proxy.md) 的 ClusterIP 实现也是 iptables/IPVS
> - 联动：[Network/TCP 协议](../Network/TCP协议.md) / [Network/多路复用](../Network/多路复用.md) 是底层

---

## 一、单机 Docker 4 种网络模式

```bash
docker run --network=<mode> ...
```

| 模式 | 隔离 | 容器 IP | 典型用途 |
| --- | --- | --- | --- |
| **bridge**（默认） | 独立 NET Namespace + 私有 IP | 172.17.0.x | 大多数业务 |
| **host** | 共享宿主 NET Namespace | 宿主 IP | 性能敏感（省一层 veth + iptables） |
| **none** | 独立 NET Namespace 但只有 lo | 无 | 完全离线场景 |
| **container:<id>** | 共享另一个容器的 NET Namespace | 同那个容器 | Pod 内 sidecar 共享网络（K8s 用） |

**Pod 网络的本质**：Pod 内多容器都是 `--network=container:<pause-id>` ——共享 Pause 容器的 Network Namespace。所以 Pod 内容器能用 `localhost` 互通。

---

## 二、bridge 模式深拆

### 2.1 拓扑图

```
                  外网 / 其他主机
                       │
                       ▼
              ┌────────────────┐
              │   eth0（宿主） │  192.168.1.10
              └────────────────┘
                       │ iptables NAT（SNAT/DNAT）
                       │
              ┌────────────────┐
              │     docker0     │  172.17.0.1（网桥，相当于交换机）
              │   Linux Bridge  │
              └────────────────┘
                  │           │
            veth1 │           │ veth2
                  │           │
            ┌─────┴─────┐ ┌───┴────────┐
            │ container1│ │ container2 │
            │ eth0      │ │ eth0       │
            │ 172.17.0.2│ │ 172.17.0.3 │
            └───────────┘ └────────────┘
            (在自己的 NET Namespace)
```

### 2.2 容器启动时网络的 5 步

1. **创建 Network Namespace**：`unshare -n` 等价；容器有了独立网络栈
2. **创建 veth pair**：在宿主创建一对虚拟网卡 `vethXXX <-> eth0`（一根线两头）
3. **一头插容器**：把 eth0 那头移进容器的 Namespace（`ip link set eth0 netns <pid>`）
4. **另一头插网桥**：vethXXX 接到 docker0 网桥
5. **容器内配 IP**：从 docker0 子网（默认 172.17.0.0/16）分配，设置默认路由 → 172.17.0.1

**veth pair 工作原理**：内核虚拟设备，**任何一端发包，另一端立即收到**——相当于一根虚拟双绞线。

### 2.3 容器访问外网（出向）：SNAT

```
container1（172.17.0.2）发包 → 8.8.8.8

1. 包出 container1 eth0 → veth1 → docker0
2. docker0 路由到宿主 eth0
3. iptables POSTROUTING 链 MASQUERADE：
   src IP 172.17.0.2 → 改成宿主 192.168.1.10
4. 包从宿主 eth0 发出
5. 回包到宿主 192.168.1.10
6. iptables 反向解 NAT：dst 改回 172.17.0.2
7. 通过 docker0 → veth1 → container1 eth0
```

iptables 看到的规则：

```bash
$ iptables -t nat -L POSTROUTING
MASQUERADE  all  --  172.17.0.0/16  anywhere
```

### 2.4 外网访问容器（入向）：DNAT

```bash
docker run -p 8080:80 nginx
# 在宿主 iptables 加规则：
# dst 192.168.1.10:8080 的包 → 改 dst 为 172.17.0.2:80
```

iptables 规则：

```bash
$ iptables -t nat -L DOCKER
DNAT  tcp  --  anywhere  anywhere  tcp dpt:8080  to:172.17.0.2:80
```

**`-p` 三种语法**：
- `-p 8080:80` 监听宿主所有网卡的 8080 → 容器 80
- `-p 127.0.0.1:8080:80` 只监听宿主 lo（不暴露公网，安全）
- `-p 80`（不写宿主端口）随机选高位端口（一般 32768+）

### 2.5 自定义网络与容器互通

```bash
docker network create mynet           # 创建用户定义 bridge
docker run --network mynet --name web nginx
docker run --network mynet --name app curlimages/curl curl http://web
# ✅ 通——用户自定义 bridge 自带 DNS，按容器名解析
```

**默认 bridge（docker0）vs 用户自定义 bridge**：
- 默认 bridge **没有 DNS**——容器名解析不了，只能用 IP
- 用户自定义 bridge **有内置 DNS**——容器名 = 域名，IP 重启变了不影响
- 生产**永远用自定义 bridge**

---

## 三、跨主机网络方案

单机 bridge 模式只能让容器在本机互通；跨主机要靠 **CNI 插件**。主流四派：

| 方案 | 工作模式 | 性能 | 网络要求 | 国内主流 |
| --- | --- | --- | --- | --- |
| **flannel host-gw** | 路由（每节点路由表） | 接近原生 | 节点二层互通 | 早期 K8s |
| **flannel VXLAN** | overlay 封包（UDP 4789 端口） | 损 5~15%（封包） | 节点三层互通即可 | 简单环境 |
| **calico BGP** | 路由（BGP 自动同步） | 接近原生 | 三层网络 / 公有云 | **生产首选** |
| **calico IP-in-IP** | overlay（IP-in-IP 封包） | 损 5~10% | 三层 + 公有云某些限制 | 跨子网时用 |
| **cilium eBPF** | eBPF（内核态，绕过 iptables） | **最优**（绕 iptables） | 内核 ≥ 4.19 | 大集群崛起 |

### 3.1 overlay（VXLAN）模式

```
节点 A（10.0.0.10）                  节点 B（10.0.0.11）
   ┌────────────┐                       ┌────────────┐
   │ Pod 10.244.1.5│                    │ Pod 10.244.2.7│
   └──────┬─────┘                       └─────┬──────┘
          │                                    │
   ┌──────┴────┐ flannel.1（VXLAN）  ┌─────────┴─────┐
   │  10.244.1.0│ ←封包：→  │ UDP 4789 │ ← 解包  │  10.244.2.0  │
   └────────────┘                       └────────────────┘
          │                                    │
   节点 A eth0  10.0.0.10  ──────────→  节点 B eth0  10.0.0.11
   (节点真实物理网络)
```

**封包格式**：原始 Pod-to-Pod 包整体 → UDP（端口 4789）→ 节点的物理网络。**性能开销**：每包多 50 字节封头 + 用户态/内核态切换 + UDP 校验 → 损 5~15%。

### 3.2 calico BGP 模式

```
节点 A（10.0.0.10）                  节点 B（10.0.0.11）
   ┌────────────┐                       ┌────────────┐
   │ Pod 10.244.1.5│                    │ Pod 10.244.2.7│
   └──────┬─────┘                       └─────┬──────┘
          │                                    │
   节点 A 路由表：                       节点 B 路由表：
   10.244.2.0/24 via 10.0.0.11           10.244.1.0/24 via 10.0.0.10
   ↑ BGP 自动同步                        ↑ BGP 自动同步
          │                                    │
   节点 A eth0 ──────直接路由（无封包）→  节点 B eth0
```

**核心**：把每个节点当成一个"路由器"，BGP 协议自动同步路由——**不封包，性能接近原生**。代价：要求节点之间三层互通（公有云有时不支持）。

### 3.3 cilium eBPF 模式

```
传统 iptables 路径（kube-proxy）：
Pod → iptables 链 → conntrack → veth → 出网卡
     （O(n) 规则线性匹配，1 万 Service 时极慢）

cilium eBPF 路径：
Pod → eBPF 程序（内核态 hash 表 O(1)）→ 出网卡
     （绕过 iptables / conntrack，性能最优）
```

**为什么 eBPF 大集群必选**：iptables 规则随 Service 数量线性膨胀，1 万 Service 时一次同步要几十秒；eBPF 用 hash 表查找 O(1)，规则更新毫秒级。

### 3.4 CNI 标准简介

CNI（Container Network Interface）是 K8s 与网络插件的契约——**只定义两个动作**：

```
ADD       → 给容器分配网络（IP + 路由）
DEL       → 容器销毁时回收
```

CNI 插件本质是个**二进制可执行文件**，放在 `/opt/cni/bin/`；kubelet 启动 Pod 时调它。

**为什么 K8s 选 CNI 不选 CNM（Docker 的网络模型）**：CNI 简单、跟容器运行时解耦；CNM 跟 Docker 强绑定。Docker Swarm 用 CNM，K8s 用 CNI——这是 Docker / K8s 网络生态分裂的根本。

---

## 四、参数 / 配置 / 取舍

### 4.1 docker0 网桥默认配置

```bash
# /etc/docker/daemon.json
{
  "bip": "172.17.0.1/16",          # docker0 网桥 IP + 子网
  "default-address-pools": [
    {"base": "172.17.0.0/16", "size": 24}   # 自定义网络从这里分配
  ],
  "mtu": 1500,                     # MTU 默认 1500
  "iptables": true,                # 让 docker 自动写 iptables
  "ip-forward": true               # 开启 IP 转发（容器才能访问外网）
}
```

**生产关键配置**：
- **`bip`**：默认 172.17.0.1/16 经常**跟公司内网冲突**（很多公司也用 172 段）→ 改成 192.168.250.0/24 之类避开
- **`mtu`**：物理网卡 MTU=1500 时，VXLAN 封包后实际 = 1500 - 50 = 1450；要么宿主 MTU 调大到 1550，要么容器 MTU 设 1450
- **`iptables: false`**：极少用，意味着自己管 NAT（极其罕见）

### 4.2 host 模式适用场景

```bash
docker run --network=host nginx
```

**性能优势**：省掉 veth + bridge + iptables 这一层，吞吐量约高 5~10%、延迟低 100μs。

**代价**：
- 容器和宿主**共享端口空间**——容器要 80 端口，宿主就不能再用 80
- 没有网络隔离——容器能看到宿主所有网卡
- 不支持 `-p` 端口映射

**生产用途**：
- 高性能网关 / 代理（Envoy / Nginx 极致性能）
- 某些 CNI 插件 Pod（calico-node / cilium-agent）必须 host 模式才能改宿主网络

---

## 五、对比 / 选型

### 5.1 单机 4 种网络模式选型

| 场景 | 选 | 为什么 |
| --- | --- | --- |
| 业务容器 | bridge | 默认、隔离 + 端口映射 |
| 性能极致 | host | 省一层网络栈 |
| 完全离线 | none | 完全不要网络 |
| Pod 内 sidecar | container:<id> | 共享 NET Namespace |

### 5.2 跨主机 CNI 选型

| 场景 | 选 | 关键考量 |
| --- | --- | --- |
| 学习 / 简单环境 | flannel | 易部署 |
| 标准生产 | **calico BGP** | 性能 + NetworkPolicy |
| 公有云 / 不支持 BGP | calico IP-in-IP | 兼容公有云 |
| 大集群（千节点 + 万 Service） | **cilium** | eBPF 摆脱 iptables 瓶颈 |
| 强安全 / 微隔离 | calico / cilium | 都支持 NetworkPolicy |

---

## 六、生产踩坑

### 坑 1：docker0 网桥 IP 跟公司内网冲突

**现象**：容器跑起来后访问公司内网 172.17.x.x 服务全部不通。

**根因**：默认 docker0 = 172.17.0.0/16，刚好覆盖了公司内网段 → 容器认为该段是本地网络，不走默认路由。

**修复**：改 `/etc/docker/daemon.json` 的 `bip`：

```json
{ "bip": "192.168.250.1/24" }
```

或 K8s 安装时 CNI 配置 podCIDR 避开公司网段。

### 坑 2：跨主机 MTU 不匹配 → 大包丢失

**现象**：小包（HTTP GET）正常，大包（POST 上传文件 > 1500 字节）卡死或超时。

**根因**：物理网卡 MTU=1500；VXLAN 封包后实际 = 1500 - 50 = 1450；但 Pod 默认还是 1500，发出来的包到了 VXLAN 隧道入口超 MTU 不能分片（DF 位）→ 丢弃。

**修复**：
- Pod / 容器 MTU 调到 1450（CNI 配置）
- 或物理网卡 MTU 调到 1550（如果能改）
- 监控 `tcpdump` 看到 ICMP `fragmentation needed` 包是确认信号

### 坑 3：iptables 规则爆炸

**现象**：集群 5000 Service 后，新 Pod 启动慢、Service 切流要 30 秒。

**根因**：kube-proxy iptables 模式给每个 Service 写 N 条规则；规则量随 Service 数线性膨胀；同步一次要遍历全量。

**修复**：
- 切 IPVS 模式（hash 表 O(1)）
- 大集群直接换 cilium eBPF（绕过 iptables）

### 坑 4：host 模式端口冲突

**现象**：两个 host 模式容器都要 80 端口，第二个起不来。

**根因**：host 模式共享宿主端口空间。

**修复**：① 改一个用 bridge 模式 + `-p`；② 协调端口（一个用 80，另一个用 8080）；③ K8s 中 host 模式 Pod 用 nodeAffinity 绑定不同节点。

### 坑 5：默认 bridge 无 DNS → 容器互访只能用 IP

**现象**：早期写的 docker-compose，容器 A 用 `web:8080` 访问 B 不通；改成 IP 才通。

**根因**：默认 docker0 不带 DNS；用户自定义网络才有内置 DNS。

**修复**：永远用 `docker network create xxx` + `--network xxx`，或 docker-compose 默认就会创建专属网络。

---

## 七、面试高频追问

**Q1：容器为什么能有独立 IP？**

A：靠 **Linux Network Namespace + veth pair + bridge 三件套**：① 容器进程创建时加 `CLONE_NEWNET` → 独立网络栈（自己的网卡、路由表、iptables、conntrack）；② 宿主上创建 veth pair（虚拟双绞线），一头插容器 Namespace 改名 eth0，另一头插 docker0 网桥；③ 容器内 eth0 从 docker0 子网分配 IP，默认路由指向 docker0 IP（172.17.0.1）。

**Q2：`docker run -p 8080:80` 怎么实现的？**

A：Docker 在宿主 iptables NAT 表的 DOCKER 链插入 **DNAT 规则**：`dst 宿主IP:8080 → 改 dst 为 容器IP:80`。包到了宿主网卡命中规则被改目标地址，再通过 docker0 → veth → 容器 eth0。回包反向解 NAT。`iptables -t nat -L DOCKER` 能看到所有规则。

**Q3：跨主机容器通信有几种方案？怎么选？**

A：**4 大派**：① **overlay/VXLAN**——封包走 UDP 4789，损耗 5~15%，要求节点三层互通就行；② **flannel host-gw**——直接路由不封包，性能近原生但要求节点二层互通；③ **calico BGP**——用 BGP 协议自动同步节点路由表，不封包，**生产首选**；④ **cilium eBPF**——绕过 iptables 用 eBPF hash 表，**大集群必选**。简单环境选 flannel；标准生产选 calico；千节点选 cilium。

**Q4：CNI 是什么？跟 CNM 区别？**

A：**CNI（Container Network Interface）** 是 K8s/容器与网络插件的契约——只定义 ADD（分配 IP）和 DEL（回收）两个动作；插件是放在 `/opt/cni/bin/` 的可执行文件，kubelet 启动 Pod 时调用。**CNM（Container Network Model）** 是 Docker 自家的网络模型，跟 Docker 强绑定。**K8s 选 CNI 不选 CNM** 因为 CNI 简单、跟运行时解耦——这也是 Docker Swarm vs K8s 网络生态分裂的根本。

**Q5：iptables 模式 vs IPVS 模式 kube-proxy 区别？**

A：**iptables**：每 Service 一组规则（线性匹配 O(n)）；5000 Service 时规则有 5 万条+，同步全量要 10+ 秒，新 Pod 启动慢。**IPVS**：内核 LB 模块，hash 表 O(1)；规则量小、同步快、CPU 低。**生产建议**：节点数 / Service 数过千就切 IPVS（kube-proxy `--proxy-mode=ipvs`）；超大集群直接 cilium 走 eBPF 摆脱 iptables 瓶颈。

**Q6：Pod 内多个容器怎么通信？**

A：**通过 localhost**——Pod 内多容器都共享 Pause 容器的 Network Namespace（`--network=container:<pause-id>`），所以它们的网卡视图是一样的：都看到同一个 eth0、同一个 lo、同一个 IP 地址。容器 A 监听 8080，容器 B 直接 `curl localhost:8080` 就通。**注意**：端口不能冲突（共享端口空间）。

**Q7：MTU 不匹配会怎样？**

A：跨主机包大于 MTU 又不能分片（IP 头 DF 位）→ 路由器丢弃 + 发回 ICMP `fragmentation needed`；HTTP 表现：小请求 OK、大请求（上传文件）卡死。VXLAN 封包后实际可用 MTU = 物理 MTU - 50；calico IP-in-IP 减 20。**修复**：调容器 MTU（CNI 配置）或调物理 MTU。监控 ICMP 错误包是确认信号。

**Q8：host 模式有什么优劣？**

A：**优势**：省 veth + bridge + iptables 这一层，吞吐量高 5~10% / 延迟低 100μs，性能最佳。**代价**：① 容器和宿主共享端口（不能两个容器都要 80）；② 没有网络隔离（容器看到所有宿主网卡）；③ `-p` 失效。**用途**：极致性能（Envoy / Nginx）；CNI 插件 Pod（必须改宿主网络）。

**Q9：veth pair 是什么？为什么需要它？**

A：**veth = Virtual Ethernet Pair**，内核虚拟设备，一对两端——一端发包另一端立即收到，相当于"虚拟网线"。容器需要 veth 来**跨 Network Namespace 通信**：容器在自己的 NET Namespace 里有 eth0，宿主在默认 NET Namespace 里有 vethXXX，两者是 veth pair 的两端，包能互通。docker0 网桥则把多根 veth 连成局域网。

**Q10：怎么调试容器网络？**

A：**5 件武器**：① `docker exec` 进容器跑 `ip addr` / `ip route` / `ping` / `curl`；② 宿主跑 `nsenter -t <pid> -n <command>` 在容器 Namespace 里跑命令（不依赖容器内有工具）；③ 宿主 `tcpdump -i docker0 / -i vethXXX` 抓包；④ 宿主 `iptables -t nat -L -n -v` 看规则匹配次数；⑤ `conntrack -L` 看连接跟踪表。`netshoot` 镜像专为调试网络打造，含全套工具。

**Q11：能让容器跟宿主在同一个 IP 段吗？**

A：能，**用 macvlan / ipvlan 模式**——容器直接接到物理网卡，从物理网络 DHCP 拿 IP，跟宿主邻居关系。代价：① 容器和宿主网卡在同一段，**很多云厂商禁用**（防 IP 伪造攻击）；② 失去 NAT 的便利性。生产几乎不用，特殊兼容场景才用（比如老应用必须用物理网络 IP）。

**Q12：NetworkPolicy 是什么？谁实现？**

A：K8s 的**网络隔离策略 API**——声明 Pod 之间能不能互通（`Ingress` / `Egress` 规则）。**K8s 本身只定义 API 不实现**——靠 CNI 插件实现：calico / cilium 都支持，flannel 不支持（要装 canal = flannel + calico policy 才有）。生产建议：默认拒绝所有跨命名空间流量（`default-deny`），按需开放。

---

## 八、答题模板（60 秒话术）

> Docker 单机网络是 **Network Namespace + veth pair + Linux bridge + iptables NAT** 四件套：每容器一个独立 Network Namespace（`CLONE_NEWNET`），里面只有 lo 和一根 veth 当 eth0，veth 另一端插宿主的 **docker0 网桥**；容器访问外网走 **iptables MASQUERADE 做 SNAT**，外网通过 `-p 8080:80` 访问容器走 **DNAT 规则**改目标地址。
>
> **4 种网络模式**：bridge（默认 / 业务用）、host（共享宿主网络栈 / 性能极致）、none（无网络 / 完全离线）、container:`<id>`（共享别人的 Namespace / **K8s Pod 内 sidecar 就靠这个**）。
>
> **跨主机 4 派 CNI**：① **overlay VXLAN**——封 UDP 4789 包跨主机传，损 5~15%；② **flannel host-gw**——节点路由表直转，性能近原生但要二层互通；③ **calico BGP**——BGP 协议自动同步路由，**生产首选**；④ **cilium eBPF**——绕过 iptables 用 eBPF hash 表，**千节点万 Service 大集群必选**。
>
> **CNI 不是 CNM**——K8s 选 CNI（简单 / 解耦），Docker Swarm 用 CNM。CNI 给 Pod 分配 IP，K8s Service 在 Pod IP 之上做 LB（kube-proxy）；两层职责清楚。
>
> **生产 5 大坑**：① docker0 默认 172.17 段跟公司内网冲突 → 改 bip；② VXLAN MTU 不匹配 → 大包丢失；③ iptables 5000 Service 规则爆炸 → 切 IPVS / cilium；④ host 模式端口冲突；⑤ 默认 bridge 无 DNS → 一律用自定义 bridge。

---

## 九、相关文档

- 前置：[Docker 容器原理](./Docker容器原理.md) — Network Namespace 基础
- 下游：[Service 与 kube-proxy](./Service与kube-proxy.md) — ClusterIP 也是 iptables/IPVS
- 配套：[Ingress 与网关](./Ingress与网关.md) — L7 流量入口
- 联动：[Network/TCP 协议](../Network/TCP协议.md) / [Network/多路复用](../Network/多路复用.md)
