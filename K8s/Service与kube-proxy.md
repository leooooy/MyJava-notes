# Service 与 kube-proxy

> **Pod IP 是飘的（重建就变），不能直接暴露**——Service 提供**稳定的 ClusterIP（虚拟 IP）+ DNS 域名**，背后由 kube-proxy 在每个节点上写 **iptables / IPVS 规则**做 DNAT，把 Service IP 解到一组 Endpoint Pod。**Headless Service**（clusterIP: None）跳过 ClusterIP 直接返回 Pod IP 列表，给 StatefulSet 做有序服务发现用。
>
> 本篇要解决面试官四个连环追问：
>
> ① **Service IP 是真实 IP 吗？怎么实现的？**——虚拟 IP，靠 iptables/IPVS 转发
> ② **iptables vs IPVS 区别？大集群必须用 IPVS 吗？**——O(n) vs O(1) 性能差异
> ③ **Headless Service 跟普通 Service 区别？**——直接 DNS 解析到 Pod IP
> ④ **EndpointSlice 替代了 Endpoint，为什么？**——Endpoint 单对象瓶颈
>
> 跟其它模块的关系：
> - 前置：[Docker 网络](./Docker网络.md) 中 iptables NAT
> - 前置：[Pod 与生命周期](./Pod与生命周期.md)（Pod IP 飘是 Service 存在的根因）
> - 配套：[Ingress 与网关](./Ingress与网关.md)（L7 流量入口在 Service 之上）
> - 联动：[Microservice/服务注册与发现](../Microservice/服务注册与发现.md)（Nacos/Eureka vs K8s Service）

---

## 一、为什么需要 Service？

直接用 Pod IP 通信的两个根本问题：

```
1. Pod IP 重建会变
   Pod-A 调 Pod-B（10.244.1.5）
   Pod-B 重启 → 新 IP 10.244.1.7
   Pod-A 仍用 10.244.1.5 → 连不上
   你写的应用要不停 watch Pod 变化，太复杂

2. 多副本怎么 LB
   Deployment 跑 3 个副本 → 3 个不同 IP
   Pod-A 怎么轮询 / 选一个调用？
```

**Service 是 Pod 之上的稳定抽象**：给一组 Pod 一个**稳定的 ClusterIP + DNS 域名**，谁挂了 / 谁加了 K8s 自动维护后端列表——调用方只跟 Service 说话。

```
                 Service: my-svc
                 ClusterIP: 10.96.0.5（虚拟 IP，永不变）
                 DNS: my-svc.default.svc.cluster.local
                       │
                       ▼
              ┌────────┼────────┐
              ▼        ▼        ▼
            Pod-A    Pod-B    Pod-C
            10.244.1.5  ...   ...
            （Endpoint 列表，K8s 自动维护）
```

---

## 二、Service 4 种类型

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-svc
spec:
  type: ClusterIP        # 4 选 1
  selector:
    app: myapp
  ports:
  - port: 80             # Service 端口
    targetPort: 8080     # Pod 端口
    protocol: TCP
```

| 类型 | 暴露范围 | 实现 | 用途 |
| --- | --- | --- | --- |
| **ClusterIP**（默认） | 集群内 | 虚拟 IP + iptables/IPVS DNAT | 集群内服务调用 |
| **NodePort** | 节点 IP:30000-32767 | ClusterIP 之上 + 节点端口 | 简单暴露（开发 / 演示） |
| **LoadBalancer** | 云厂商 LB 公网 IP | NodePort 之上 + 云 LB | 生产对外暴露 |
| **ExternalName** | DNS CNAME | DNS 别名（无 ClusterIP） | Service 别名指向外部 DNS |

### 2.1 ClusterIP

**默认类型**——集群内访问。

```
集群内 Pod-A：curl http://my-svc:80/
            ↓
DNS 解析 my-svc → 10.96.0.5
            ↓
Pod-A 发包 dst=10.96.0.5
            ↓
节点 iptables/IPVS 拦截 → DNAT 到 10.244.1.5:8080
            ↓
真正打到 Pod-B
```

**ClusterIP 不是真实 IP**——没有任何网卡绑定它，全靠 iptables/IPVS 规则识别。

### 2.2 NodePort

```yaml
spec:
  type: NodePort
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30080      # 30000-32767 范围
```

**任意节点的 30080 端口**都能访问到 Service。背后还是 ClusterIP，多了节点端口转发：

```
外网客户端 → http://node-1.ip:30080
              ↓
node-1 iptables：dst=node-1.ip:30080 → 10.96.0.5:80（ClusterIP）
              ↓
普通 ClusterIP 流程 → DNAT 到 Pod
```

**生产很少裸用**——通常是 LoadBalancer 的底层。

### 2.3 LoadBalancer

```yaml
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
```

**云厂商配套**：K8s 看到 type=LoadBalancer，调云厂商 API 创建一个外部 LB（AWS ELB / GCP LB / 阿里 SLB），LB 后端指向所有节点的 NodePort。**Service 自动获取一个外部 IP**（kubectl get svc 看 EXTERNAL-IP）。

```
外网 → 云 LB（公网 IP）
       ↓
       round-robin 转发到任意节点的 NodePort
       ↓
       NodePort → ClusterIP → Pod
```

**裸金属集群替代**：MetalLB（自己搭 LB）或直接用 Ingress + NodePort。

### 2.4 ExternalName

```yaml
spec:
  type: ExternalName
  externalName: api.example.com
# 不是 LB，不是 ClusterIP——只是 DNS CNAME
# 集群内 my-svc.default.svc.cluster.local → CNAME → api.example.com
```

**唯一用途**：给外部服务起个集群内的别名（迁移 / 解耦），改外部地址只改 Service 不改业务代码。

---

## 三、ClusterIP 是怎么实现的？

### 3.1 kube-proxy 的角色

每个节点跑一份 kube-proxy（DaemonSet），watch Service 和 EndpointSlice → 维护节点 iptables/IPVS 规则。

```
apiserver
   │
   │ watch Service / EndpointSlice
   ▼
kube-proxy（每节点一份）
   │
   ▼
本节点 iptables / IPVS 规则
```

### 3.2 iptables 模式（默认）

```bash
# Service: my-svc, ClusterIP 10.96.0.5:80, 后端 Pod 10.244.1.5:8080 / 10.244.1.6:8080

# 节点 iptables 规则（简化版）
-A KUBE-SERVICES -d 10.96.0.5/32 -p tcp --dport 80 -j KUBE-SVC-XXX

-A KUBE-SVC-XXX -m statistic --mode random --probability 0.5 -j KUBE-SEP-AAA   # 50% 概率
-A KUBE-SVC-XXX -j KUBE-SEP-BBB                                                # 剩下都给 BBB

-A KUBE-SEP-AAA -p tcp -j DNAT --to-destination 10.244.1.5:8080
-A KUBE-SEP-BBB -p tcp -j DNAT --to-destination 10.244.1.6:8080
```

**核心机制**：
- DNAT：把 dst 从 ClusterIP 改到 Pod IP
- 负载均衡：用 `--probability` 做随机分配（不是真正的 LRU / WRR）

**性能问题**：iptables 是**链式线性匹配**——5000 Service 时会有 5 万条规则，每个包要遍历整条链 → CPU 占用高 + 同步规则慢（一次全量 sync 几十秒）。

### 3.3 IPVS 模式（推荐生产）

启用：`kube-proxy --proxy-mode=ipvs`。

```bash
# IPVS 看到的规则（hash 表 O(1)）
$ ipvsadm -L -n
TCP  10.96.0.5:80 rr               # rr = round-robin
  -> 10.244.1.5:8080  Masq  1  0  0
  -> 10.244.1.6:8080  Masq  1  0  0
```

**核心差异**：
- **数据结构**：hash 表，匹配 O(1)；iptables 是链式 O(n)
- **算法**：rr / wrr / lc / wlc / sh 等多种 LB 算法可选；iptables 只能简单概率
- **性能**：5000 Service 规则同步 ms 级；iptables 30s+

**何时切 IPVS**：
- 节点数 / Service 数过千
- iptables 规则同步慢、CPU 占用高
- 需要更多 LB 算法（如最小连接 lc）

**注意**：IPVS 也用 iptables 做一些预处理（KUBE-MARK-MASQ 等），但 LB 这块走 IPVS hash 表。

### 3.4 conntrack 与连接跟踪

无论 iptables 还是 IPVS，DNAT 都依赖 **conntrack 表**——记录"原始连接 → 转换后连接"的映射，回包要逆向解 NAT。

```
Pod-A → 10.96.0.5:80（ClusterIP）          conntrack 记录：
       ↓ DNAT                              src=PodA dst=10.96.0.5 → src=PodA dst=10.244.1.5
       变成 dst=10.244.1.5:8080
                                           回包用这条记录逆向：
回包 src=10.244.1.5 → ↓ 逆向 NAT          src=10.244.1.5 → 改成 src=10.96.0.5
       src 改成 10.96.0.5
       Pod-A 看到回包 src=10.96.0.5（它请求的目标）
```

**conntrack 表满会怎样**：满了拒绝新连接 → 业务报错 connection refused。生产调大：

```bash
sysctl -w net.netfilter.nf_conntrack_max=1048576
```

---

## 四、Endpoint 与 EndpointSlice

### 4.1 Endpoint（旧）

```yaml
# 自动生成的 Endpoint 对象
apiVersion: v1
kind: Endpoints
metadata:
  name: my-svc
subsets:
- addresses:
  - ip: 10.244.1.5
  - ip: 10.244.1.6
  ports:
  - port: 8080
```

**问题**：Service 后端 1000 Pod → Endpoint 是**一个对象 1000 条记录**——任何一个 Pod 状态变（新加 / Ready 切 NotReady），整个对象 PUT 一次到 etcd → apiserver 推给所有节点 kube-proxy → 节点全量重写规则。**这是大集群最大瓶颈**。

### 4.2 EndpointSlice（新，K8s 1.21+ 默认）

```yaml
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: my-svc-abc           # 一个 Service 可有多个 Slice
  labels:
    kubernetes.io/service-name: my-svc
addressType: IPv4
endpoints:
- addresses: ["10.244.1.5"]
  conditions:
    ready: true
- addresses: ["10.244.1.6"]
  conditions:
    ready: true
ports:
- port: 8080
```

**关键改进**：
- 一个 Service 后端拆成**多个 Slice**（默认 100 endpoint / Slice）
- 单 Pod 状态变只更新所属 Slice，不动其他 Slice
- 序列化 / 推送压力分摊
- 支持 IPv4 / IPv6 双栈、拓扑感知（topologyKeys）

**国内生产建议**：K8s 1.21+ 自动用，不用关心；老版本升级要确认 EndpointSlice Controller 跑起来。

---

## 五、Headless Service：跳过 ClusterIP

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql-headless
spec:
  clusterIP: None             # 关键：无 ClusterIP
  selector:
    app: mysql
  ports:
  - port: 3306
```

**特性**：
- **不分配 ClusterIP**——也就没有 iptables/IPVS DNAT
- **DNS 直接解析到 Pod IP 列表**：

```bash
$ nslookup mysql-headless
mysql-headless.default.svc.cluster.local has address 10.244.1.5
mysql-headless.default.svc.cluster.local has address 10.244.1.6
mysql-headless.default.svc.cluster.local has address 10.244.1.7
```

**跟 StatefulSet 配合**——每个 Pod 还有独立 DNS：

```bash
$ nslookup mysql-0.mysql-headless
mysql-0.mysql-headless.default.svc.cluster.local has address 10.244.1.5
```

**典型用途**：
- StatefulSet 副本之间互连（主从 / 分片找彼此）
- 客户端要自己做 LB（gRPC 长连接需要直连每个 Pod）
- 服务发现集成（应用自己 DNS 拉 Pod 列表）

---

## 六、CNI 简介：跟 Service 的边界

**容易混淆**：CNI 给 Pod 分 IP；kube-proxy 在 Pod IP 之上做 LB。两层职责清楚：

```
[CNI 插件] — 给 Pod 分配 IP，配 Pod 间路由 / overlay / 跨节点通信
                ↓
            Pod 网络（10.244.0.0/16）
                ↓
[kube-proxy] — 在 Pod 网络之上提供 Service 抽象（iptables/IPVS DNAT）
                ↓
            Service 网络（10.96.0.0/16，虚拟 IP）
                ↓
[CoreDNS]  — 把 Service 名 → ClusterIP，把 Headless Service 名 → Pod IP 列表
```

**主流 CNI**：详见 [Docker 网络](./Docker网络.md) 第三章。

**cilium 特殊性**：可以同时实现 CNI（Pod 网络）+ kube-proxy（Service 转发），靠 eBPF **绕过 iptables**——大集群性能最优。

---

## 七、生产踩坑

### 坑 1：iptables 规则爆炸 → CPU 飙

**现象**：节点数 50 / Service 数 5000，节点 kube-proxy CPU 50%，新 Pod 注册延迟 1 分钟。

**根因**：iptables 模式 5000 Service × 平均 10 副本 = 5 万条规则，每次 EndpointSlice 变化全量重写。

**修复**：
- 切 IPVS：`kube-proxy --proxy-mode=ipvs`
- 大集群直接 cilium eBPF（绕过 iptables/conntrack）

### 坑 2：conntrack 表满 → connection refused

**现象**：高并发场景偶发 `connection refused`，dmesg 看到 `nf_conntrack: table full`。

**根因**：默认 `nf_conntrack_max` 太小（25 万）；NodePort + 反向代理流量大、长连接多。

**修复**：

```bash
sysctl -w net.netfilter.nf_conntrack_max=1048576
sysctl -w net.netfilter.nf_conntrack_buckets=262144
echo 'net.netfilter.nf_conntrack_max=1048576' >> /etc/sysctl.conf
```

或迁 IPVS（也用 conntrack，但默认配置更友好），或上 cilium（eBPF 不依赖 conntrack）。

### 坑 3：Headless Service 没配 → StatefulSet DNS 不通

**现象**：StatefulSet 起来了，但 mysql-0 ping mysql-1 失败，DNS 解析不出来。

**根因**：StatefulSet 配的 `serviceName` 指向的 Service 是普通 ClusterIP（不是 Headless）——不会注册 Pod 级 DNS。

**修复**：把对应 Service 的 `clusterIP: None` 加上，重启 StatefulSet。

### 坑 4：SessionAffinity 与连接池冲突

**现象**：开了 `sessionAffinity: ClientIP` 后某个 Pod 流量倾斜（90% 流量打到一个 Pod）。

**根因**：客户端是反向代理 / SDK 连接池——所有请求都从同一个 ClientIP 发出，会话粘性把它绑死到一个后端。

**修复**：
- 用应用层会话粘性（Cookie）替代 ClientIP
- 关 SessionAffinity，用应用层处理（Session 存 Redis）

### 坑 5：跨命名空间访问 Service 不通

**现象**：Pod 在 ns-A，访问 ns-B 的 Service 写 `http://my-svc` 不通。

**根因**：DNS 查询默认带 ns 后缀，写 `my-svc` 会被解析成 `my-svc.ns-A.svc.cluster.local`。

**修复**：写完整域名 `http://my-svc.ns-B.svc.cluster.local` 或简写 `http://my-svc.ns-B`。

### 坑 6：LoadBalancer Service Pending

**现象**：在裸金属集群创 type=LoadBalancer，EXTERNAL-IP 永远 `<pending>`。

**根因**：LoadBalancer 类型依赖云厂商插件（cloud-controller-manager）调用云 API；裸金属没人响应。

**修复**：
- 裸金属装 **MetalLB**（开源 LB 实现，支持 ARP / BGP）
- 或改用 NodePort + 自建 nginx / haproxy

---

## 八、面试高频追问

**Q1：Service IP 是真实 IP 吗？怎么实现的？**

A：**不是真实 IP**——没有任何网卡绑定 ClusterIP。它是个**虚拟 IP**，靠**节点的 iptables/IPVS 规则识别后做 DNAT**：包发到 ClusterIP，节点 netfilter hook 拦截 → 改目标地址为某个 Pod IP → 包就转到 Pod 了。所以 ClusterIP 在集群外 ping 不通（节点没绑定它，也没路由）。

**Q2：kube-proxy 三种模式区别？怎么选？**

A：**userspace（淘汰）**：用户态代理转发，性能最差。**iptables（默认）**：每 Service 一组 iptables 规则，**线性匹配 O(n)**——5000 Service 时规则 5 万条，同步全量 30s+，CPU 高。**IPVS（推荐生产）**：内核 LVS hash 表 **O(1)**，规则量小、同步快、支持多种 LB 算法（rr/wrr/lc/wlc/sh）。**选型**：节点数 / Service 数过千切 IPVS；超大集群（万节点）直接 cilium eBPF 绕过 iptables/conntrack。

**Q3：Endpoint 跟 EndpointSlice 区别？**

A：**Endpoint 是一个 Service 的所有后端 Pod 信息塞在一个对象里**——单 Service 千 Pod 时这个对象很大，任何一个 Pod 状态变（Ready 切换）整个对象 PUT 一次到 etcd → 推给所有节点 → 全量重写规则。**EndpointSlice（K8s 1.21+ 默认）** 把后端拆成多个 Slice（默认 100 endpoint / Slice），单 Pod 变只更新所属 Slice——序列化和推送压力分摊，**大集群必备**。还支持双栈 / 拓扑感知。

**Q4：Headless Service 是什么？跟普通 Service 区别？**

A：**`clusterIP: None`** 的 Service——**不分配 ClusterIP，没有 iptables/IPVS 规则，DNS 直接解析到 Pod IP 列表**。普通 Service：DNS → ClusterIP（一个 IP），客户端连 ClusterIP 由 kube-proxy LB；Headless：DNS → 多个 Pod IP，客户端自己处理（自己 LB / 自己选实例）。**用途**：① StatefulSet 必备（Pod 级 DNS `mysql-0.headless-svc`）；② gRPC 等长连接客户端需要直连每个后端做客户端 LB。

**Q5：Service 4 种类型怎么选？**

A：① **ClusterIP**（默认）—— 集群内服务调用，99% 内部流量用它；② **NodePort** —— 简单暴露（开发 / 演示），生产很少裸用；③ **LoadBalancer** —— 生产对外暴露，依赖云厂商创外部 LB；④ **ExternalName** —— 给外部服务起集群内别名（DNS CNAME，无 ClusterIP，无负载均衡）。**实际**：内部用 ClusterIP；对外用 LoadBalancer（云）或 Ingress（多 Service 共享一个 LB）；裸金属上 MetalLB。

**Q6：Pod IP 和 Service IP 有什么不同？**

A：**Pod IP 是 CNI 分的真实 IP**——每个 Pod 一个，重启变（除非 StatefulSet 配 Headless），跨节点通信靠 CNI（calico / flannel）实现；**Service IP 是 kube-proxy 维护的虚拟 IP**——没网卡绑定，靠节点 iptables/IPVS 拦截做 DNAT。Pod IP 在 Pod 网段（10.244.0.0/16）；Service IP 在 Service 网段（10.96.0.0/16）。两者完全独立，CNI 给 Pod IP，kube-proxy 在 Pod 之上提供 Service 抽象。

**Q7：CoreDNS 怎么解析 Service 名？**

A：**Pod 启动时 K8s 把 CoreDNS 的 ClusterIP 写到 Pod 的 `/etc/resolv.conf`** 作为 nameserver。Pod 查询 `my-svc` → 走 CoreDNS。CoreDNS 配置了 `kubernetes` 插件，watch apiserver Service / EndpointSlice，内存里维护 `<svc-name>.<ns>.svc.cluster.local → ClusterIP` 映射；Headless 的解析为多个 Pod IP；Pod 名（StatefulSet）解析为对应 Pod IP。**关键域名**：`<svc>.<ns>.svc.cluster.local`（Service）、`<pod-name>.<svc>.<ns>.svc.cluster.local`（Headless Pod）。

**Q8：iptables 规则爆炸怎么解？**

A：**iptables 链式匹配 O(n)**——5000 Service × 10 副本 = 5 万条规则，每包要遍历整条链。**3 种修复**：① 切 **IPVS**（hash 表 O(1)，最常见解法）；② 用 **EndpointSlice**（K8s 1.21+ 默认，减少同步压力）；③ 上 **cilium eBPF**（绕过 iptables 用 eBPF map 直接转发，最彻底）。生产**节点数 / Service 数过千就该切 IPVS**，万级一定上 cilium。

**Q9：conntrack 表满会怎样？怎么处理？**

A：**会拒绝新连接，dmesg 报 `nf_conntrack: table full, dropping packet`**——业务表现 connection refused / connection timeout。**根因**：iptables / IPVS 都依赖 conntrack 表跟踪连接做反向 NAT；默认表大小 25 万；NodePort 大流量 / 长连接多很容易撑爆。**修复**：① `sysctl -w net.netfilter.nf_conntrack_max=1048576` 调大；② 调 `nf_conntrack_tcp_timeout_*` 缩短超时；③ 切 cilium eBPF（不用 conntrack）。

**Q10：Service 外部流量怎么打到 Pod？**

A：**生产一般两层**：① 外部 LB（云 LoadBalancer / MetalLB / 自建 LVS）→ 节点 NodePort 或 ClusterIP；② 节点 kube-proxy 通过 iptables/IPVS 做 DNAT 到 Pod IP。**关键参数**：`externalTrafficPolicy: Local` 让外部流量保留 Source IP（不做 SNAT），代价是只能转到本节点的 Pod（其他节点没 Pod 就丢包，需配合健康检查只发到有 Pod 的节点）；`Cluster`（默认）做 SNAT、转任意节点 Pod，丢失 Source IP。

**Q11：sessionAffinity 怎么用？**

A：

```yaml
spec:
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800
```

按 ClientIP 做粘性——同 ClientIP 的请求始终打到同一个 Pod。**坑**：客户端走反向代理 / 连接池 → 所有请求都从同 ClientIP 发出 → 流量倾斜到一个 Pod。**生产建议**：会话粘性走应用层（Cookie / Redis Session），不要用 Service 层 sessionAffinity。

**Q12：能不能在 K8s Service 之外也用 Pod 域名？**

A：能——**`pod.cluster.local` 域名**（Pod IP 反查）：`10-244-1-5.default.pod.cluster.local`（IP 中点改横）。但这个域名不稳定（IP 变了域名变），实用性低。**真正稳定的 Pod 域名只有 StatefulSet + Headless Service 组合**——`mysql-0.mysql-headless.ns.svc.cluster.local`。

---

## 九、答题模板（60 秒话术）

> Pod IP **重建会变**，不能直接用——Service 提供**稳定的 ClusterIP（虚拟 IP）+ DNS 域名**，靠 kube-proxy 在每个节点写 iptables/IPVS 规则做 DNAT 把 Service IP 转到一组后端 Pod。
>
> **4 种 Service**：① **ClusterIP**（默认 / 集群内）；② **NodePort**（节点端口 / 简单暴露）；③ **LoadBalancer**（云厂商 LB / 生产对外）；④ **ExternalName**（DNS CNAME / 外部别名）。
>
> **kube-proxy 3 种模式**：① **iptables**（默认，链式 O(n)）—— 5000 Service 规则爆炸 / 同步 30s+；② **IPVS**（hash 表 O(1)）—— 大集群推荐，规则少 + 多种 LB 算法；③ **cilium eBPF** —— 绕过 iptables/conntrack，万级集群必选。**节点 / Service 数过千就切 IPVS**。
>
> **EndpointSlice 替代 Endpoint**（1.21+ 默认）：旧 Endpoint 是单对象塞所有后端，1000 Pod 变一次推给所有节点；EndpointSlice 拆成多 Slice（默认 100/Slice），分散推送压力。
>
> **Headless Service**（`clusterIP: None`）跳过 ClusterIP，**DNS 直接解析到 Pod IP 列表**——StatefulSet 必备（每个 Pod 还有独立域名 `mysql-0.headless-svc.ns`）；客户端 LB 长连接（gRPC）也用它。
>
> **CNI vs Service 边界**：CNI 给 Pod 分 IP（Pod 网络 10.244.0.0/16），kube-proxy 在 Pod 网络之上提供 Service 抽象（Service 网络 10.96.0.0/16）；CoreDNS 把 Service 名解析为 ClusterIP（普通 Service）或 Pod IP 列表（Headless）。
>
> **5 大生产坑**：① iptables 规则爆炸切 IPVS；② conntrack 表满调 `nf_conntrack_max`；③ Headless 没配 StatefulSet DNS 不通；④ sessionAffinity 配 ClientIP 流量倾斜；⑤ 裸金属 LoadBalancer Pending 装 MetalLB。

---

## 十、相关文档

- 前置：[Docker 网络](./Docker网络.md) — iptables NAT / CNI 概念
- 前置：[Pod 与生命周期](./Pod与生命周期.md) — Pod IP 不稳定是 Service 的根因
- 配套：[Ingress 与网关](./Ingress与网关.md) — L7 流量入口建在 Service 之上
- 配套：[工作负载](./工作负载.md) — StatefulSet 与 Headless Service
- 联动：[Microservice/服务注册与发现](../Microservice/服务注册与发现.md) — Nacos vs K8s Service
