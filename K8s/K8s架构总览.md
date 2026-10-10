# Kubernetes 架构总览

> **K8s 是声明式 API + 控制循环范式的容器编排平台**——你写 YAML 描述"想要什么"（期望状态），各种 Controller 通过 watch apiserver 不断 reconcile（实际状态 → 期望状态），最终把容器调度到节点上跑起来。**控制面 4 件套（apiserver / etcd / scheduler / controller-manager）+ 数据面 2 件套（kubelet / kube-proxy）= K8s 全部**。
>
> 本篇要解决面试官"画一下 K8s 架构图"的开场题，并解决四个连环追问：
>
> ① **6 大组件分别干什么？** ——apiserver 是大脑，etcd 是记忆，scheduler 调 Pod，controller 守循环
> ② **声明式 API 怎么工作？** ——YAML → apiserver → etcd → controller watch → reconcile
> ③ **Pod 是怎么从 YAML 跑起来的？** ——25 步全链路
> ④ **为什么 etcd 是 K8s 唯一的存储？** ——Raft 一致性、串行化语义
>
> 跟其它模块的关系：
> - 前置：[Docker 容器原理](./Docker容器原理.md) 是 K8s 调度的"砖头"
> - 下游：[Pod 与生命周期](./Pod与生命周期.md) / [工作负载](./工作负载.md) / [Service 与 kube-proxy](./Service与kube-proxy.md) 都是这套架构的具象化
> - 联动：[Distributed/一致性算法](../Distributed/一致性算法.md) 解释 etcd 的 Raft

---

## 一、为什么需要 K8s？

容器解决了"应用怎么打包跑起来"，但**几千个容器跑在几百台机器上**还要解决：
- 哪个容器跑哪台机器？（**调度**）
- 容器挂了谁来重启？（**自愈**）
- 流量怎么打到容器？（**服务发现**）
- 怎么不停机发布？（**滚动更新**）
- 怎么应对流量波动？（**弹性伸缩**）

K8s 的**核心创新**：用**声明式 API + 控制循环**统一回答上面所有问题——你只描述"我要 3 个副本""挂了重启"，至于怎么实现是 K8s 的事。这套范式来自 Google 内部的 Borg / Omega 系统，K8s 是它的开源版。

**为什么不用 Docker Swarm？**——Swarm 是 Docker 自家编排，简单但能力弱；K8s 由 Google + RedHat + 社区主导，CNCF 生态最大，已成事实标准。Mesos / Nomad 也基本被 K8s 占领了。

---

## 二、整体架构图

```
                       ┌────────── kubectl / API client ──────────┐
                       │                                           │
                       ▼                                           │
   ┌───────────────────────────────────────────────────────────┐  │
   │                Control Plane（控制面，原叫 Master）         │  │
   │                                                           │  │
   │   ┌────────────┐   ┌──────────┐   ┌─────────────────┐    │  │
   │   │ apiserver  │←→ │   etcd   │   │ controller-mgr  │    │  │
   │   │ (REST+gRPC)│   │  (Raft)  │   │ Deployment/RS/  │    │  │
   │   │ 鉴权 / 准入 │   │ 唯一存储  │   │ Node/Endpoint…  │    │  │
   │   │ Watch     │   │          │   │ 控制循环 reconcile│    │  │
   │   └─────┬──────┘   └──────────┘   └─────────┬───────┘    │  │
   │         │                                    │            │  │
   │         │            ┌──────────────────┐   │            │  │
   │         └─────────── │     scheduler    │ ──┘            │  │
   │                      │ Filter + Score   │                │  │
   │                      │ 给 Pod 选节点     │                │  │
   │                      └──────────────────┘                │  │
   └───────────────────────────────────────────────────────────┘  │
            ↕ kubelet 发 watch                                    │
                                                                  │
   ┌─────────────── Worker Node 1 ─────────────────────┐         │
   │                                                   │         │
   │   ┌──────────┐    ┌────────────┐                  │         │
   │   │  kubelet │ ←→ │ kube-proxy │                  │         │
   │   │ Pod 生命  │    │ Service 转发│                  │         │
   │   │ Probe    │    │ iptables/  │                  │         │
   │   │ 上报状态  │    │   IPVS     │                  │         │
   │   └────┬─────┘    └────────────┘                  │         │
   │        │ CRI gRPC                                 │         │
   │        ▼                                          │         │
   │   ┌──────────────┐                                │         │
   │   │  containerd  │ ←─ runc ─→ 容器（Pod）          │         │
   │   └──────────────┘                                │         │
   └───────────────────────────────────────────────────┘         │
                          ...                                    │
   ┌─────────────── Worker Node N ─────────────────────┐         │
   └───────────────────────────────────────────────────┘         │
```

---

## 三、控制面 4 大组件

### 3.1 apiserver：唯一入口

**角色**：**所有人都跟 apiserver 说话**——kubectl、controller、scheduler、kubelet 全是 apiserver 的客户端。它是 K8s 的**大脑 + 总线**。

**5 个职责**：

| 职责 | 干什么 |
| --- | --- |
| **REST 接口** | 提供 `/api/v1/pods`、`/apis/apps/v1/deployments` 等 HTTPS 端点 |
| **认证（Authentication）** | 你是谁——证书 / Token / OIDC / Webhook |
| **鉴权（Authorization）** | 你能干啥——RBAC / ABAC / Node / Webhook |
| **准入控制（Admission）** | 这操作允许吗——MutatingAdmission（改写）+ ValidatingAdmission（校验） |
| **Watch 长连接** | 客户端 watch 资源变更，**HTTP Chunked / WebSocket 流式推送** |

**为什么只有 apiserver 能直接读写 etcd？**——所有写都要走鉴权 / 准入 / 校验链，etcd 直连等于绕过安全层。生产环境 etcd 监听 localhost only。

**apiserver 是无状态的**——所有状态在 etcd；apiserver 可水平扩缩，多副本前面挂 LB（kube-apiserver 高可用方案）。

### 3.2 etcd：唯一存储

**角色**：分布式 KV 存储，K8s 全部状态（Pod / Service / ConfigMap / Secret / Lease）都存这里。

**为什么用 etcd 不用 MySQL / Redis？**

| 维度 | etcd | MySQL | Redis |
| --- | --- | --- | --- |
| 一致性 | **Raft 强一致** | 主从异步（强一致难） | RDB/AOF 持久化但弱一致 |
| Watch | **原生支持，O(1)** | 需轮询 / binlog 监听 | Pub/Sub 不可靠 |
| 数据量 | 几 GB（适合元数据） | TB+ | GB（内存） |
| 适用 | **配置 / 元数据 / 协调** | 业务大数据 | 缓存 |

**核心特性**：
- **Raft 一致性**（详见 [Distributed/一致性算法](../Distributed/一致性算法.md)）——3/5/7 节点集群容忍 1/2/3 节点故障
- **Watch 机制**——客户端对某个 key prefix 注册 watch，etcd 流式推送变更（K8s 控制循环的核心）
- **MVCC**——保留历史版本，watch 可从某个 revision 起获取增量
- **TTL / Lease**——节点心跳过期自动删 key，K8s 用来做 leader election

**etcd 性能边界**：
- 单 etcd 集群推荐**最多 1 万 Pod / 1500 节点**
- 单 etcd 数据量推荐 **< 8GB**（默认配额 2GB，可调 `--quota-backend-bytes=8589934592`）
- Compact 不及时会涨碎片，定期 `etcdctl defrag`

### 3.3 scheduler：Pod 调度器

**角色**：watch 到 `nodeName=""` 的 Pod，给它选个节点写回 `nodeName`。

**两阶段算法**：

```
1. Filter（预选 / Predicate）—— 过滤掉不合规的节点
   - NodeName / NodeAffinity（亲和约束）
   - PodFitsResources（资源够不够 = node.allocatable - node.requested）
   - Taint / Toleration（污点容忍）
   - VolumeBinding（PVC 能不能挂上）

2. Score（优选 / Priority）—— 剩下的打分排序
   - LeastRequestedPriority（资源利用率低优先）
   - BalancedResourceAllocation（CPU/内存均衡）
   - ImageLocality（节点本地有镜像优先）
   - InterPodAffinity（亲和打分）
```

详见 [调度与资源管理](./调度与资源管理.md)。

### 3.4 controller-manager：控制循环集合

K8s 的"自愈"靠**几十个 Controller 跑控制循环**，全部塞在 controller-manager 这一个进程里：

```
Deployment Controller       → 管 Deployment → 创建/更新 ReplicaSet
ReplicaSet Controller       → 管 RS → 维持 Pod 数 = 期望副本数
Node Controller             → 管 Node → 节点失联 5min 标记 NotReady → evict Pod
Endpoint Controller         → 管 Service ↔ Endpoint 同步
Service Controller          → 跟云厂商 LB API 联动（LoadBalancer 类型 Service）
Job Controller              → 管 Job → 跑完次数 = completions 就停
CronJob Controller          → 定时创建 Job
PV/PVC Controller           → 管 PVC 绑定到 PV
Namespace Controller        → 删 Namespace 时级联删资源
ServiceAccount Controller   → 自动创建 default ServiceAccount
HPA Controller              → 拉 metrics 计算副本数（kube-controller-manager 里）
Garbage Collector           → 级联删 OwnerReference 子资源
...
```

**控制循环的标准模板**：

```go
for {
    desired := apiserver.Get(resource)         // 期望状态
    actual  := apiserver.Watch(actualState)    // 实际状态
    diff    := compare(desired, actual)
    if len(diff) > 0 {
        apiserver.Apply(diff)                  // 让实际向期望靠拢
    }
}
```

**这就是声明式 API 的"魔法"——永远在循环、永远在收敛。** 你写 `replicas: 3` 不是命令"现在创建 3 个"，而是声明"始终保持 3 个"。

---

## 四、数据面 2 大组件

### 4.1 kubelet：节点代理

**角色**：每个节点跑一份的"管家"——管 Pod 生命周期、Probe、上报节点状态。

**5 个职责**：

| 职责 | 干什么 |
| --- | --- |
| **Pod 生命周期** | watch apiserver 调度到本节点的 Pod → 调 CRI 创建容器 |
| **健康检查** | 跑 Liveness / Readiness / Startup Probe |
| **上报状态** | 节点资源 / Pod 状态定时上报 apiserver（NodeStatus / PodStatus） |
| **挂载存储** | 调 CSI 创建 / 挂载 PV |
| **日志 / 指标** | 提供 kubectl logs、暴露 cAdvisor 指标 |

**kubelet 不通过 docker 命令调容器**——通过 **CRI（Container Runtime Interface）** gRPC 调用 containerd（K8s 1.24+）。

### 4.2 kube-proxy：Service 转发

**角色**：每节点跑一份，watch Service / EndpointSlice 资源 → 写本节点的 iptables / IPVS 规则。

**3 种模式**：

| 模式 | 实现 | 性能 |
| --- | --- | --- |
| userspace | 用户态代理（已淘汰） | 极差 |
| **iptables**（默认） | 节点 iptables 规则 | O(n) 线性匹配 |
| **IPVS** | 内核 LVS hash 表 | **O(1) 推荐生产** |

详见 [Service 与 kube-proxy](./Service与kube-proxy.md)。

### 4.3 容器运行时

**链路**：`kubelet → CRI(gRPC) → containerd → runc → 容器`（K8s 1.24+ 删 dockershim 后的标准）。

详见 [Docker 容器原理](./Docker容器原理.md) 第三章。

---

## 五、声明式 API 与控制循环

### 5.1 命令式 vs 声明式

**命令式（Imperative）**：

```bash
docker run -d --name web1 nginx
docker run -d --name web2 nginx
docker run -d --name web3 nginx
# 一台机器挂了 → 你得手动 docker run 在另一台
```

**声明式（Declarative）**：

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  replicas: 3      # 我要 3 个，不管在哪
  template:
    spec:
      containers: [...]
# K8s 控制循环保证永远是 3 个 → 节点挂了自动调度到别处
```

**核心差别**：声明式描述**目标状态**，命令式描述**步骤**。声明式有"幂等性"（YAML apply 多次结果一样）和"自愈"（永远向目标收敛）。

### 5.2 Watch 机制

apiserver 提供 **HTTP Chunked / WebSocket 长连接**：客户端可以 watch 某个资源（如 Pods），任何变更（Add / Update / Delete）apiserver 立即推送事件。

```
Controller 启动：
  1. List 全量当前状态（一次性快照）
  2. Watch 增量变更（长连接，按 ResourceVersion 续传）
  3. 内存里维护 informer cache
  4. 事件触发 reconcile
```

**为什么不是轮询？**——轮询要么慢（间隔大）要么炸 apiserver（间隔小 × 节点数 × 控制器数）。Watch 是 push 模型，apiserver 只在变化时推；客户端 informer 缓存 + 事件队列把压力分担到客户端。

### 5.3 ResourceVersion 与乐观并发

apiserver 用 **`resourceVersion`** 实现乐观锁：

```yaml
# kubectl get 拿到的对象带 resourceVersion: "12345"
# 改完 PUT 回去
# 如果 etcd 里现在是 12347（被别人改过）→ 拒绝（409 Conflict）
# 客户端要 re-fetch + retry
```

避免多个 Controller 同时改同一个对象出冲突。

---

## 六、Pod 创建全流程（25 步深拆）

```
1.  kubectl apply -f deploy.yaml
2.  kubectl 把 yaml POST 到 apiserver /apis/apps/v1/deployments
3.  apiserver Authentication（验证证书 / Token）
4.  apiserver Authorization（RBAC 检查"你能创 Deployment 吗"）
5.  apiserver Mutating Admission（如自动注入 sidecar）
6.  apiserver Validating Admission（如校验 image 是否在白名单）
7.  apiserver 写入 etcd（Raft commit）
8.  apiserver 返回 201 Created → kubectl 退出

9.  Deployment Controller 通过 Watch 收到 Add 事件
10. 调 apiserver 创建对应的 ReplicaSet（带 OwnerReference 指向 Deployment）

11. ReplicaSet Controller Watch 收到 RS Add 事件
12. 检查 actual = 0 < desired = 3，调 apiserver 创建 3 个 Pod（nodeName 为空）

13. Scheduler Watch 收到 Pod Add 事件（nodeName=""）
14. Filter 阶段过滤节点
15. Score 阶段打分排序
16. 调 apiserver Bind API：Pod.spec.nodeName = "node-7"

17. node-7 上的 kubelet Watch 收到 nodeName=node-7 的 Pod
18. kubelet 调 CRI 准备运行环境（拉镜像 / 创 sandbox / 配网络）
19. CNI 插件分配 Pod IP（calico/flannel）
20. CRI（containerd）调 runc 创建容器（Namespace + Cgroups）
21. kubelet 跑 startupProbe → readinessProbe
22. readinessProbe 通过 → kubelet 上报 PodStatus.ready=true

23. Endpoint Controller Watch 收到 Pod ready 事件
24. 把 Pod IP 加到 Service 对应的 EndpointSlice

25. kube-proxy Watch 收到 EndpointSlice 变更 → 更新本节点 iptables/IPVS 规则
   → 流量开始打到这个 Pod
```

**关键洞察**：**没有"中央调度器"**——每个组件独立 watch + reconcile，只通过 apiserver 协作。这是 K8s 可扩展的根本（加一个 controller 不影响其他）。

---

## 七、生产踩坑

### 坑 1：apiserver Watch 风暴

**现象**：apiserver CPU 100%，节点 NotReady 频发。

**根因**：业务自研 Operator 每秒 List 全量 Pods 而不是 Watch + Informer cache → apiserver 频繁全量序列化大对象。

**修复**：用 **client-go Informer**（自动 list-watch + 缓存），不要手撸 List；定期 `--watch-cache-size` 调整 apiserver Watch 缓存。

### 坑 2：etcd 性能瓶颈 / 碎片

**现象**：apply YAML 卡 3 秒；`etcdctl endpoint status` 看到数据库 5GB（实际 1GB）。

**根因**：MVCC 历史版本累积没 compact + defrag。

**修复**：

```bash
# 设置自动 compact
etcd --auto-compaction-mode=periodic --auto-compaction-retention=1h

# 手动 defrag（每个节点单独做，不要并发）
etcdctl defrag --endpoints=localhost:2379
```

### 坑 3：controller-manager 主备切换抖动

**现象**：节点挂掉后过 5min controller 才发现 evict Pod。

**根因**：controller-manager 通过 Lease 选主——当前 leader hang 了，Lease 续期失败 15s 后才切主。

**修复**：调小 lease-duration（默认 15s）→ 故障检测更快但抖动风险增加。

### 坑 4：apiserver 认证证书过期

**现象**：某天突然全集群挂了，所有 kubectl 报 `x509: certificate has expired`。

**根因**：kubeadm 生成的证书默认有效期 1 年；超期没轮换。

**修复**：

```bash
kubeadm certs check-expiration       # 看过期时间
kubeadm certs renew all              # 续证（短期方案）
# 长期方案：kubeadm 1.15+ 默认每次升级集群顺带续证
```

### 坑 5：scheduler 卡死 / 无法调度

**现象**：新 Pod 长期 Pending，`kubectl describe` 看不到 Failed 事件。

**根因**：scheduler 内部死锁 / 资源全占满 / 亲和约束矛盾。

**修复**：① `kubectl get events` + `kubectl describe pod` 看具体原因；② `kubectl describe nodes` 看节点 allocatable；③ 重启 scheduler；④ 检查 PodDisruptionBudget 是否过严。

---

## 八、面试高频追问

**Q1：画一下 K8s 架构图。**

A：**控制面 4 大件 + 数据面 2 大件 + 容器运行时**：

- **控制面**：① **apiserver**（唯一入口、鉴权、准入、Watch）；② **etcd**（唯一存储、Raft 一致性）；③ **scheduler**（Filter+Score 调 Pod）；④ **controller-manager**（Deployment / RS / Node / Endpoint 等几十个控制循环）
- **数据面**：⑤ **kubelet**（节点代理、Pod 生命周期、Probe）；⑥ **kube-proxy**（Service 转发、iptables/IPVS）
- **运行时**：containerd → runc → 容器

**关键关系**：所有人都跟 apiserver 说话，apiserver 是唯一进 etcd 的；其他组件都是 apiserver 的 watch 客户端 + reconcile。

**Q2：apiserver 是有状态还是无状态？**

A：**无状态**——所有状态在 etcd；apiserver 可以水平扩缩、滚动重启不影响数据。生产高可用：3 个 apiserver 副本 + 前面 LB（kube-vip / HAProxy / 云 LB）。客户端用 LB VIP 连。

**Q3：为什么 K8s 选 etcd 不用 MySQL / Redis？**

A：① **Raft 强一致**——MySQL 主从异步复制做不到、Redis 持久化弱一致；② **原生 Watch**——MySQL 要轮询或解析 binlog、Redis Pub/Sub 不可靠（断了消息丢）；③ **数据规模匹配**——K8s 状态是元数据级（几 GB），etcd 设计就是干这个的；④ **MVCC**——保留历史版本，Watch 可从某 revision 增量。

**Q4：scheduler 的 Filter 和 Score 干啥？**

A：**Filter（预选）过滤掉不合规的节点**——nodeName / 资源够不够 / 污点容忍 / 亲和约束 / Volume 能挂上；剩下的进**Score（优选）打分排序**——LeastRequested（资源使用率低）/ BalancedResource（CPU 内存均衡）/ ImageLocality（本地有镜像）/ InterPodAffinity 等几十个 Priority 函数。最后选最高分节点 Bind。两阶段是为了**性能**——Filter 把上千节点缩到几十个再打分。

**Q5：controller-manager 里有多少 Controller？**

A：**几十个**——Deployment / ReplicaSet / DaemonSet / StatefulSet / Job / CronJob / Node / Endpoint / Service / Namespace / ServiceAccount / PV / PVC / HPA / GarbageCollector ……每个独立 watch + reconcile。**所有 Controller 跑同一个进程**（kube-controller-manager），通过 Lease 做 leader election——同一时刻只有一个进程的 controllers 在跑（防并发改同一对象）。云厂商 Controller（LoadBalancer Service / cloud-provider routes）在另一个进程 cloud-controller-manager 里。

**Q6：声明式 API 跟命令式有什么区别？**

A：① **描述目标 vs 描述步骤**——`replicas: 3` 是"始终保持 3 个"，不是"现在创 3 个"；② **幂等**——apply 同一份 YAML 多次结果一样，命令式重跑会出错；③ **自愈**——节点挂了 K8s 自动重建 Pod，命令式要人工干预；④ **可回滚**——保留历史 revision；命令式难追溯；⑤ **代价**——理解曲线陡（要懂控制循环），调试有时反直觉。

**Q7：kubelet 怎么跟容器运行时通信？**

A：通过 **CRI（Container Runtime Interface）gRPC**——kubelet 不直接调 docker / containerd 命令，而是定义了 CRI 标准 API（PodSandboxService + ContainerService 等），由运行时实现。K8s 1.24+ 删除 dockershim 后，链路是 **kubelet → CRI → containerd → runc → 容器**。这套设计让运行时可插拔（containerd / CRI-O / Kata / gVisor 任选）。

**Q8：Pod 从 YAML 到运行经过哪些步骤？**

A：**核心 5 步**：① kubectl apply → apiserver 鉴权 / 准入 → 写 etcd；② Deployment Controller watch 到，创 ReplicaSet；③ ReplicaSet Controller 创 Pod（nodeName 空）；④ Scheduler Filter+Score 选节点，Bind 写回；⑤ 目标节点 kubelet watch 到，调 CRI 创容器，CNI 配网络，跑 Probe，Ready 后上报。详细 25 步见正文第六节。**关键洞察**：没有"中央调度器"，每个组件独立 watch + reconcile，只通过 apiserver 协作。

**Q9：怎么扩展 K8s？**

A：**4 大扩展点**：① **CRD + Operator**——自定义资源 + Controller，最常用（如 Istio / Argo / Prometheus Operator）；② **Admission Webhook**——MutatingAdmission（改写）/ ValidatingAdmission（拒绝）；③ **Scheduler Extender / Scheduler Plugin Framework**——自定义调度策略；④ **CRI / CNI / CSI** 三大接口——容器运行时、网络、存储。CRD + Operator 是 K8s 最强大的扩展模式，整个云原生生态建立在此。

**Q10：etcd 的容量上限和性能边界？**

A：① **数据量**：默认配额 2GB，调到 8GB 是上限（再大性能急速下降）；② **集群规模**：单 etcd 集群推荐 1500 节点 / 5000 Service / 1 万 Pod；③ **Raft 节点数**：3 / 5 / 7（奇数，多了写性能下降）；④ **写吞吐**：~10K 写 / 秒（SSD），主要靠 Raft commit 同步。**超大集群方案**：拆多 K8s 集群（一般 1000~5000 节点一个）+ 集群联邦（KubeFed / Karmada）。

**Q11：为什么控制循环要无限循环？**

A：**因为现实世界永远在变**——节点会挂、网络会抖、磁盘会满、用户会改 YAML、Pod 会 OOM。控制循环每次 watch 事件触发 reconcile，对比期望 vs 实际、做出修正。**这是 K8s 自愈的核心**——不需要人工介入，故障自动恢复。代价：状态可能短暂偏离（最终一致性）；reconcile 风暴（大批资源同时变化时 controller CPU 飙升）。

**Q12：Webhook 和 Operator 是同一个东西吗？**

A：**不是**。**Webhook** 是 apiserver 调你（Mutating/Validating Admission），处理"创建/更新对象时是否放行 / 怎么改写"——同步、调用密集、失败影响 apiserver。**Operator** 是你 watch apiserver（基于 Controller 模式），处理"声明状态 → 实际状态收敛"——异步、独立运行。**典型搭配**：Operator 处理业务逻辑（管理一组资源），Webhook 处理验证 / 注入（如 Istio sidecar 注入是 MutatingWebhook，不是 Operator）。

---

## 九、答题模板（60 秒话术）

> K8s 是 **声明式 API + 控制循环范式的容器编排平台**——你写 YAML 描述期望状态，K8s 通过几十个 Controller watch + reconcile 让实际状态向期望收敛。
>
> **架构 = 控制面 4 件 + 数据面 2 件**：① **apiserver** 唯一入口（鉴权 / 准入 / Watch）；② **etcd** 唯一存储（Raft 强一致 + Watch + MVCC）；③ **scheduler**（Filter 过滤 + Score 打分两阶段调 Pod）；④ **controller-manager**（Deployment / RS / Node / Endpoint 等几十个控制循环）；⑤ **kubelet** 节点代理（Pod 生命周期 / Probe / 上报）；⑥ **kube-proxy**（Service 转发，iptables/IPVS）。所有组件都是 apiserver 的客户端，只有 apiserver 进 etcd。
>
> **Pod 创建流程**（kubectl apply 后）：apiserver 鉴权写 etcd → Deployment Controller 创 RS → RS Controller 创 Pod → scheduler Filter+Score 选节点 → 目标节点 kubelet watch 到，调 CRI（containerd）→ runc → 容器；CNI 配网络 / Probe 通过后 Endpoint Controller 把 Pod IP 加到 Service → kube-proxy 更新 iptables → 流量打过来。
>
> **声明式 API 的本质**：YAML 是"目标状态"不是"步骤"，K8s 通过 watch + reconcile 永远向目标收敛——所以**幂等**、**自愈**、**可回滚**。Watch 是 apiserver 提供的 HTTP Chunked 长连接，client-go Informer 维护本地 cache 减少 List 压力。
>
> **生产经验**：apiserver 无状态可水平扩缩；etcd 推荐 3/5/7 奇数节点 Raft，**单集群 1500 节点 / 1 万 Pod / 8GB 数据**是上限；超大规模拆多集群 + 联邦（KubeFed / Karmada）。常见坑：自研 Operator 用 List 不用 Watch 风暴 apiserver；etcd 不定期 compact + defrag 性能恶化；apiserver 证书 1 年到期忘续。

---

## 十、相关文档

- 前置：[Docker 容器原理](./Docker容器原理.md) — 容器是 K8s 的"砖头"
- 下游：[Pod 与生命周期](./Pod与生命周期.md) — Pod 是最小调度单元
- 下游：[工作负载](./工作负载.md) — Deployment / StatefulSet 是 Pod 的管理器
- 下游：[Service 与 kube-proxy](./Service与kube-proxy.md) — Service 实现细节
- 下游：[调度与资源管理](./调度与资源管理.md) — Scheduler 详解
- 联动：[Distributed/一致性算法](../Distributed/一致性算法.md) — etcd Raft
