# K8s 云原生面试模块

> **容器运行时 + 容器编排平台**——大厂后端 P7+ 必考的工程平台层。从 **Docker 容器原理**（Namespace / Cgroups / UnionFS）到 **Kubernetes 编排**（Pod / Workload / Service / Ingress / 调度 / 弹性），是当前 Java 工程师跳槽时最大的差距点。
>
> 本模块聚焦 **云原生在大厂面试中的核心 4 个问题**：
>
> ① **应用怎么跑** → Docker 容器化（Namespace 做隔离 / Cgroups 做限额 / UnionFS 做镜像分层），K8s 用 Pod 把容器拢成最小调度单元
> ② **应用怎么扩** → Workload（Deployment / StatefulSet / DaemonSet / Job）声明副本数，HPA / VPA / CA 三层弹性
> ③ **应用怎么联** → Service（ClusterIP / NodePort / LB / Headless）+ kube-proxy（iptables / IPVS）+ Ingress / Gateway API
> ④ **应用怎么活** → 调度（亲和 / 污点 / 抢占）+ 资源 QoS + 健康检查（Liveness / Readiness / Startup）+ 滚动发布 + PDB + 优雅停机
>
> 跟其它模块的关系：
> - 微服务运行时承载 → [Microservice 模块](../Microservice/README.md)（Nacos / Feign / Sentinel / Gateway 都跑在 K8s 之上）
> - 网络底层 → [Network 模块](../Network/README.md)（CNI / Service IP / iptables 全要靠 TCP/IP 与 epoll 知识打底）
> - 分布式理论 → [Distributed 模块](../Distributed/README.md)（etcd 用 Raft、Service 发现是分布式问题、调度涉及一致性）

---

## 一、模块导航

### 1. Docker 容器篇（5 篇）

> 容器运行时与镜像，K8s 的"砖头"。先理解容器，才能理解 Pod。

| 文档 | 一句话定位 |
| --- | --- |
| [Docker 容器原理](./Docker容器原理.md) | Namespace / Cgroups / UnionFS 三件套、Docker vs VM、containerd / runc 演进、容器逃逸 |
| [Dockerfile 与镜像优化](./Dockerfile与镜像优化.md) | 多阶段构建、镜像分层、构建缓存、`.dockerignore`、镜像瘦身（Alpine / distroless） |
| [Docker 网络](./Docker网络.md) | bridge / host / none / container 4 种模式、iptables NAT / SNAT、跨主机方案（overlay / flannel / calico） |
| [Docker 存储与数据卷](./Docker存储与数据卷.md) | Volume / Bind Mount / tmpfs、与 K8s PV 的承接关系、写时复制层 |
| [Docker Compose 多服务编排（本地实战）](./DockerCompose多服务编排.md) | profiles 按需启动、`${VAR}` 插值 vs `env_file`、全量校验崩溃、WebRTC/UDP 容器网络坑（node_ip + 端口映射） |

### 2. K8s 架构与对象（4 篇）

> K8s 是什么、有什么对象。先建立 mental model，才能调度发布。

| 文档 | 一句话定位 |
| --- | --- |
| [K8s 架构总览](./K8s架构总览.md) | Master/Worker、apiserver / etcd / scheduler / controller / kubelet / kube-proxy 6 大件、声明式 API |
| [Pod 与生命周期](./Pod与生命周期.md) | Pod 设计哲学、Pause 容器、initContainer、状态机（Pending → Running → Succeeded/Failed）、生命周期钩子、Probe 三种 |
| [工作负载](./工作负载.md) | Deployment / StatefulSet / DaemonSet / Job / CronJob / ReplicaSet —— 6 种 Workload 取舍 |
| [Service 与 kube-proxy](./Service与kube-proxy.md) | 4 种 Service、iptables vs IPVS、Endpoint / EndpointSlice、Headless Service、CNI 简介 |

### 3. K8s 网络存储与配置（3 篇）

> Pod 调度起来之后，怎么对外暴露 / 怎么持久化 / 怎么注配置。

| 文档 | 一句话定位 |
| --- | --- |
| [Ingress 与网关](./Ingress与网关.md) | Ingress vs Service、Nginx Ingress Controller、Gateway API、TLS 终结、灰度路由 |
| [存储与持久化](./存储与持久化.md) | Volume / PV / PVC / StorageClass / CSI、动态供应、回收策略（Retain / Delete / Recycle）、StatefulSet 存储 |
| [ConfigMap 与 Secret](./ConfigMap与Secret.md) | 注入方式（env / volume / subPath）、热更新机制、加密（KMS / Sealed Secret）、与 Nacos 配置中心对比 |

### 4. K8s 调度与发布（2 篇）

> 资源怎么分、应用怎么发——大厂运维场景题集中区。

| 文档 | 一句话定位 |
| --- | --- |
| [调度与资源管理](./调度与资源管理.md) | Scheduler 流程（Filter + Score）、节点亲和 / Pod 亲和反亲和、污点容忍、抢占、QoS（Guaranteed / Burstable / BestEffort）、requests/limits、OOMKill |
| [发布与弹性伸缩](./发布与弹性伸缩.md) | Deployment 滚动策略（maxSurge / maxUnavailable）、蓝绿 / 金丝雀、HPA / VPA / Cluster Autoscaler、PDB、优雅停机（preStop + terminationGracePeriodSeconds） |

### 5. 实战（4 篇）

> 把前面的调度 / 存储 / DaemonSet / Ingress 串成一次真实部署，坑都在这。

| 文档 | 一句话定位 |
| --- | --- |
| [EKS 可观测性 LGTM 栈部署实战](./EKS可观测性LGTM栈部署实战.md) | Loki+Grafana+Tempo+Prometheus 三条信号管道；nodeSelector+toleration 锁节点、DaemonSet 全覆盖、EBS gp2 持久化、PodMonitor 精准抓取、trace_id 高基数、复用 ALB + TargetGroupBinding + 手工放行安全组 8 大坑 |
| [EKS Grafana 多环境 Dashboard 落地实战](./EKS-Grafana多环境Dashboard落地实战.md) | dev→EKS 派生盘、按 `namespace` 一键切三环境；变量正则捕获组吞值→No data、RWO 卷升级 Multi-Attach 死锁→Recreate、持久化盖住新 uid、sidecar `provider.folder` 全局污染→`folderAnnotation` 分文件夹、Windows kubectl 路径 cygpath 5 大坑 |
| [EKS 节点组与 Kustomize 部署全链路实战](./EKS节点组与Kustomize部署全链路实战.md) | 节点→节点组(NodeGroup=ASG,Spot vs OnDemand)→nodeSelector+taint 隔离→Kustomize base/overlay 分层→Deployment→Service 六层全链路；标签体系不统一/只写 nodeSelector 漏 toleration/节点组版本漂移 等 7 坑 |
| [从 Pod 名字反推部署：Helm / Operator / YAML 锚点](./从Pod名字反推部署-Helm-Operator-YAML锚点.md) | 读栈能力：一个 values 文件=一个 Helm release、Pod 名三层拆解(release+fullname+控制器后缀)、Operator 模式调谐链(CR→operator→StatefulSet→Pod 两层接力)、为什么 `prometheus-`/`alertmanager-` 前缀、YAML 锚点 `&`/`*`/`<<:` 复用 |

---

## 二、面试高频题 → 文档映射

### 容器原理

| 高频题 | 跳转 |
| --- | --- |
| Docker 是怎么实现隔离的？Namespace 有几种？ | [Docker 容器原理](./Docker容器原理.md) |
| Cgroups 是怎么做资源限制的？v1 vs v2？ | [Docker 容器原理](./Docker容器原理.md) |
| 容器和虚拟机本质区别？性能开销谁大？ | [Docker 容器原理](./Docker容器原理.md) |
| Docker 镜像是怎么分层的？UnionFS / OverlayFS 原理？ | [Docker 容器原理](./Docker容器原理.md) |
| containerd 和 runc 什么关系？为什么 K8s 1.24 弃用 dockershim？ | [Docker 容器原理](./Docker容器原理.md) |
| 多阶段构建怎么用？为什么镜像能从 1G 瘦身到 50M？ | [Dockerfile 与镜像优化](./Dockerfile与镜像优化.md) |
| `RUN apt install` 为什么放第一行更慢？构建缓存怎么命中？ | [Dockerfile 与镜像优化](./Dockerfile与镜像优化.md) |
| `COPY` vs `ADD` 怎么选？为什么生产用 COPY？ | [Dockerfile 与镜像优化](./Dockerfile与镜像优化.md) |
| Docker 默认网络模式？怎么实现两个容器互通？ | [Docker 网络](./Docker网络.md) |
| 跨主机容器通信怎么搞？overlay / flannel / calico 区别？ | [Docker 网络](./Docker网络.md) |

### Pod / Workload

| 高频题 | 跳转 |
| --- | --- |
| 为什么需要 Pod？直接调度容器不行吗？ | [Pod 与生命周期](./Pod与生命周期.md) |
| Pause 容器是干什么的？ | [Pod 与生命周期](./Pod与生命周期.md) |
| initContainer 和普通 Container 区别？ | [Pod 与生命周期](./Pod与生命周期.md) |
| Pod 状态有哪些？CrashLoopBackOff 怎么排查？ | [Pod 与生命周期](./Pod与生命周期.md) |
| Liveness / Readiness / Startup Probe 区别？ | [Pod 与生命周期](./Pod与生命周期.md) |
| Deployment 和 StatefulSet 区别？什么场景用哪个？ | [工作负载](./工作负载.md) |
| StatefulSet 怎么保证稳定网络标识？ | [工作负载](./工作负载.md) |
| DaemonSet 适用场景？日志采集为什么用它？ | [工作负载](./工作负载.md) |
| Job 失败重试怎么控制？CronJob 错过执行时间怎么办？ | [工作负载](./工作负载.md) |

### 网络 / 存储 / 配置

| 高频题 | 跳转 |
| --- | --- |
| Service 4 种类型？ClusterIP 怎么实现？ | [Service 与 kube-proxy](./Service与kube-proxy.md) |
| iptables vs IPVS 模式区别？为什么大集群用 IPVS？ | [Service 与 kube-proxy](./Service与kube-proxy.md) |
| Headless Service 是啥？为什么 StatefulSet 离不开它？ | [Service 与 kube-proxy](./Service与kube-proxy.md) |
| EndpointSlice 是干嘛的？为什么 1.21 默认替代 Endpoint？ | [Service 与 kube-proxy](./Service与kube-proxy.md) |
| CNI 是什么？flannel / calico / cilium 怎么选？ | [Service 与 kube-proxy](./Service与kube-proxy.md) |
| Ingress 和 Service 区别？为什么需要 Ingress？ | [Ingress 与网关](./Ingress与网关.md) |
| Ingress vs Gateway API 演进？ | [Ingress 与网关](./Ingress与网关.md) |
| PV / PVC / StorageClass 三层关系？为什么这么设计？ | [存储与持久化](./存储与持久化.md) |
| 动态供应原理？CSI 在做什么？ | [存储与持久化](./存储与持久化.md) |
| ConfigMap 改了之后 Pod 自动生效吗？ | [ConfigMap 与 Secret](./ConfigMap与Secret.md) |
| Secret 真的加密吗？怎么做生产级密钥管理？ | [ConfigMap 与 Secret](./ConfigMap与Secret.md) |

### 调度 / 发布 / 弹性

| 高频题 | 跳转 |
| --- | --- |
| Scheduler 怎么挑节点？Filter + Score 流程？ | [调度与资源管理](./调度与资源管理.md) |
| 节点亲和 / Pod 亲和反亲和有什么用？ | [调度与资源管理](./调度与资源管理.md) |
| 污点容忍机制？Master 节点为什么默认不调度业务 Pod？ | [调度与资源管理](./调度与资源管理.md) |
| QoS 三档怎么决定？OOMKill 优先级？ | [调度与资源管理](./调度与资源管理.md) |
| requests 和 limits 区别？怎么估算？ | [调度与资源管理](./调度与资源管理.md) |
| Deployment 滚动更新参数（maxSurge / maxUnavailable）含义？ | [发布与弹性伸缩](./发布与弹性伸缩.md) |
| 蓝绿发布 vs 金丝雀 vs 滚动发布怎么选？ | [发布与弹性伸缩.md](./发布与弹性伸缩.md) |
| HPA 触发条件？冷却时间怎么算？ | [发布与弹性伸缩](./发布与弹性伸缩.md) |
| Pod 优雅停机怎么实现？SIGTERM 后什么时候被 SIGKILL？ | [发布与弹性伸缩](./发布与弹性伸缩.md) |
| PDB 是什么？什么场景必须配？ | [发布与弹性伸缩](./发布与弹性伸缩.md) |

### EKS 实战

| 高频题 | 跳转 |
| --- | --- |
| EKS 节点是怎么管理的？NodeGroup 和 ASG 什么关系？ | [EKS 节点组与 Kustomize 部署全链路实战](./EKS节点组与Kustomize部署全链路实战.md) |
| 怎么把非生产负载隔离到独立节点？为什么 nodeSelector 还要配 toleration？ | [EKS 节点组与 Kustomize 部署全链路实战](./EKS节点组与Kustomize部署全链路实战.md) |
| Spot 和 On-Demand 节点组怎么选？Spot 被回收有什么影响？ | [EKS 节点组与 Kustomize 部署全链路实战](./EKS节点组与Kustomize部署全链路实战.md) |
| Kustomize base/overlay 解决什么问题？多环境差异怎么组织？ | [EKS 节点组与 Kustomize 部署全链路实战](./EKS节点组与Kustomize部署全链路实战.md) |
| 一个服务从节点到被访问的完整链路是怎样的？ | [EKS 节点组与 Kustomize 部署全链路实战](./EKS节点组与Kustomize部署全链路实战.md) |
| Deployment 的 selector 和 template.labels 为什么要写两遍？ | [EKS 节点组与 Kustomize 部署全链路实战](./EKS节点组与Kustomize部署全链路实战.md) |

### 读栈 / Helm / Operator

| 高频题 | 跳转 |
| --- | --- |
| 一屏 pod 怎么反推谁装的？为什么有的带 chart 前缀有的不带？ | [从 Pod 名字反推部署](./从Pod名字反推部署-Helm-Operator-YAML锚点.md) |
| Pod 名字是怎么拼出来的？看名字能不能判断工作负载类型？ | [从 Pod 名字反推部署](./从Pod名字反推部署-Helm-Operator-YAML锚点.md) |
| Operator 模式是什么？Prometheus 的 pod 是 Helm 直接建的吗？ | [从 Pod 名字反推部署](./从Pod名字反推部署-Helm-Operator-YAML锚点.md) |
| CR 改了之后 pod 怎么自动重建？调谐链几层控制器？ | [从 Pod 名字反推部署](./从Pod名字反推部署-Helm-Operator-YAML锚点.md) |
| YAML 里 `&` `*` `<<:` 是什么意思？Helm values 怎么复用配置？ | [从 Pod 名字反推部署](./从Pod名字反推部署-Helm-Operator-YAML锚点.md) |
| Helm 和 kubectl 什么关系？为什么 Helm 装的别用 kubectl 手改？ | [从 Pod 名字反推部署](./从Pod名字反推部署-Helm-Operator-YAML锚点.md) |

---

## 三、依赖关系图

```
                     [Docker 容器原理]
                  Namespace+Cgroups+UnionFS
                            │
            ┌───────────────┼───────────────┐
            ▼               ▼               ▼
       [Dockerfile]    [Docker 网络]   [Docker 存储]
       多阶段/分层      bridge/overlay   Volume/Mount
            │               │               │
            └───────────────┼───────────────┘
                            ▼
                   [K8s 架构总览]
              apiserver/etcd/scheduler/
              controller/kubelet/kube-proxy
                            │
            ┌───────────────┼───────────────┐
            ▼               ▼               ▼
        [Pod 与          [工作负载]    [Service+
       生命周期]         Deployment    kube-proxy]
       Pause+init        StatefulSet   iptables/IPVS
            │             DaemonSet/Job        │
            └───────────────┼─────────────────┘
                            ▼
            ┌───────────────┼───────────────┐
            ▼               ▼               ▼
        [Ingress 与     [存储与         [ConfigMap
         网关]           持久化]         与 Secret]
        Nginx/GW API    PV/PVC/CSI      env/volume
            │               │               │
            └───────────────┼───────────────┘
                            ▼
            ┌───────────────┴───────────────┐
            ▼                               ▼
       [调度与                         [发布与
        资源管理]                        弹性伸缩]
       Scheduler/亲和/                 滚动/蓝绿/HPA/
       污点/QoS                         PDB/优雅停机
```

**面试高频追问主线**：

1. **容器**：Namespace（6 类隔离）→ Cgroups（CPU/内存/IO 限制）→ UnionFS（镜像分层）→ 容器 vs VM
2. **K8s 控制面**：apiserver（唯一入口 / 鉴权）→ etcd（Raft / 配置存储）→ scheduler（Filter+Score）→ controller-manager（控制循环）
3. **K8s 数据面**：kubelet（节点代理 / Probe）→ kube-proxy（Service 实现）→ CNI（网络插件）→ CSI（存储插件）
4. **声明式 API**：YAML → apiserver → etcd → controller watch → kubelet 创建 Pod → 容器运行时 → cgroups 隔离
5. **流量进入**：Client → Ingress（L7）→ Service ClusterIP（kube-proxy DNAT）→ Endpoint Pod
6. **应用发布**：Deployment 改镜像 → 新 ReplicaSet → 滚动更新（maxSurge/maxUnavailable）→ Probe 通过 → 老 RS 缩容

---

## 四、跨模块联动

| 主题 | 本模块 | 关联模块 |
| --- | --- | --- |
| 注册中心 | Service / Headless Service | [Microservice/服务注册与发现](../Microservice/服务注册与发现.md)（Nacos / Eureka 与 K8s Service 互补） |
| 配置中心 | [ConfigMap 与 Secret](./ConfigMap与Secret.md) | [Microservice/Nacos](../Microservice/Nacos.md)（Nacos Config 用还是 ConfigMap 用） |
| 网关 | [Ingress 与网关](./Ingress与网关.md) | [Microservice/SpringCloudGateway](../Microservice/SpringCloudGateway.md)（应用层网关 vs Ingress 网关） |
| 限流 | Service Mesh / Ingress Annotation | [Microservice/Sentinel](../Microservice/Sentinel.md)、[Microservice/限流算法](../Microservice/限流算法.md) |
| 容器网络 | [Docker 网络](./Docker网络.md) / [Service](./Service与kube-proxy.md) | [Network/网络 IO 模型](../Network/网络IO模型.md)、[Network/多路复用](../Network/多路复用.md)（CNI 底层全靠 epoll） |
| 一致性存储 | etcd（Raft） | [Distributed/一致性算法](../Distributed/一致性算法.md) |
| 分布式锁 | Lease / etcd Election | [Distributed/分布式锁](../Distributed/分布式锁.md) |
| 优雅停机 | preStop + terminationGracePeriodSeconds | Project/性能优化（连接池关闭 / MQ 消费收尾） |
| 资源限制 | requests/limits / cgroups | [JVM/jvm 参数](../JVM/jvm参数.md)（容器化 JVM 必配 `-XX:+UseContainerSupport`） |

---

## 五、推荐学习路径

### 新手路径（按依赖顺序）

```
1. Docker 容器原理        ← 先理解容器是什么、隔离怎么做的
2. Dockerfile 与镜像优化   ← 把应用打成镜像
3. Docker 网络            ← 容器之间怎么通信
4. Docker 存储与数据卷     ← 容器数据怎么持久化
5. K8s 架构总览           ← 6 大组件 mental model
6. Pod 与生命周期         ← 最小调度单元
7. 工作负载               ← 6 种 Workload
8. Service 与 kube-proxy  ← 服务发现底层
9. Ingress 与网关         ← 流量入口
10. 存储与持久化           ← PV/PVC/CSI
11. ConfigMap 与 Secret   ← 配置注入
12. 调度与资源管理         ← 调度策略 + QoS
13. 发布与弹性伸缩         ← 滚动 + HPA + 优雅停机
```

### 面试速通路径（30 分钟刷答题模板）

每篇都已（或将要）配 **答题模板（60 秒话术）**——直接复述即可。

按高频度排序：

- [Docker 容器原理](./Docker容器原理.md)——三件套是命题作文
- [K8s 架构总览](./K8s架构总览.md)——开篇必问"画一下 K8s 架构"
- [Pod 与生命周期](./Pod与生命周期.md)——CrashLoopBackOff 排障必考
- [工作负载](./工作负载.md)——Deployment vs StatefulSet
- [Service 与 kube-proxy](./Service与kube-proxy.md)——iptables vs IPVS
- [调度与资源管理](./调度与资源管理.md)——QoS / OOMKill 是大厂运维题
- [发布与弹性伸缩](./发布与弹性伸缩.md)——滚动更新参数 / HPA / 优雅停机
- 其它按需补足

---

## 六、关键速记表

### Docker vs 虚拟机

| 维度 | 容器 | 虚拟机 |
| --- | --- | --- |
| 隔离层 | 内核 Namespace + Cgroups（共享内核） | Hypervisor + 完整 Guest OS |
| 启动时间 | 秒级（毫秒级） | 分钟级 |
| 资源开销 | 几十 MB | 几百 MB ~ 几 GB |
| 安全隔离 | 弱（共享内核，存在逃逸风险） | 强（硬件虚拟化） |
| 镜像大小 | MB ~ 百 MB | GB |
| 典型用途 | 微服务、CI/CD、应用打包 | 多租户、跨 OS 运行 |

### K8s 6 大核心组件

| 组件 | 角色 | 关键能力 |
| --- | --- | --- |
| **apiserver** | 唯一入口 | 鉴权 / 准入 / 持久化到 etcd / 提供 REST + Watch |
| **etcd** | 唯一存储 | Raft 一致性、所有 K8s 状态 |
| **scheduler** | Pod 调度 | Filter（过滤）+ Score（打分）→ 选节点 |
| **controller-manager** | 控制循环 | Deployment / ReplicaSet / Node 等控制器 reconcile |
| **kubelet** | 节点代理 | Pod 创建 / Probe / 上报状态 |
| **kube-proxy** | Service 实现 | iptables / IPVS 转发规则 |

### Probe 三种类型

| Probe | 失败行为 | 用途 |
| --- | --- | --- |
| **Liveness** | 重启容器 | 检测进程死锁 / 假死 |
| **Readiness** | 从 Endpoint 摘除 | 检测能否接流量（启动慢 / 依赖未就绪） |
| **Startup** | 在它通过前不跑 Liveness/Readiness | 启动很慢的应用（如 JVM 大堆） |

### Service 4 种类型

| 类型 | 暴露范围 | 用途 |
| --- | --- | --- |
| **ClusterIP** | 集群内 | 默认值，集群内服务发现 |
| **NodePort** | 节点 IP:30000-32767 | 外部直连节点端口（开发 / 简单暴露） |
| **LoadBalancer** | 云厂商 LB | 生产对外暴露（依赖云厂商） |
| **ExternalName** | DNS CNAME | Service 别名指向外部 DNS |

### QoS 三档（决定 OOMKill 优先级）

| QoS | 条件 | OOM 优先级 |
| --- | --- | --- |
| **Guaranteed** | 所有容器 requests==limits 且都设置 | 最低（最后被杀） |
| **Burstable** | 至少一个容器设置了 requests 或 limits | 中等 |
| **BestEffort** | 完全不设置 | 最高（最先被杀） |

### HPA 触发与冷却

| 维度 | 默认值 | 说明 |
| --- | --- | --- |
| 同步周期 | 15s | controller-manager 拉指标周期 |
| 扩容冷却 | 0s（v1.18+） | 越快扩越好 |
| 缩容冷却 | 5min | 防抖动，避免反复缩扩 |
| 触发阈值 | CPU 利用率（默认）/ 自定义指标 | 实际值 ÷ requests 做百分比 |

### 镜像优化"三件套"

| 手段 | 收益 | 代价 |
| --- | --- | --- |
| 多阶段构建 | 镜像 1.5G → 200M | Dockerfile 略复杂 |
| Alpine / distroless | 200M → 50M | musl libc 兼容性问题（少数库需 glibc） |
| `.dockerignore` 干净构建上下文 | 构建快 / 缓存稳 | 几乎无 |

---

## 七、生产踩坑 TOP 10

1. **JVM 容器内不识别 cgroup 内存上限**：堆内存按宿主机计算 → OOMKill。修复：`-XX:+UseContainerSupport`（JDK 8u191+ / 10+ 默认开启）。→ [调度与资源管理](./调度与资源管理.md)
2. **Liveness Probe 配得太严**：偶发 GC stop-the-world 触发重启 → 雪崩。修复：用 Readiness 摘流量、不用 Liveness 重启；或调大 `failureThreshold`。→ [Pod 与生命周期](./Pod与生命周期.md)
3. **优雅停机没做**：SIGTERM 后 30s 强杀，连接突然断 → 客户端报错。修复：preStop 等 sleep / 业务 hook + `terminationGracePeriodSeconds: 60`。→ [发布与弹性伸缩](./发布与弹性伸缩.md)
4. **CrashLoopBackOff 看 logs 看不到**：容器启动就挂，logs 空。修复：`kubectl logs --previous`、`kubectl describe pod`、init 容器 / image pull 错误。→ [Pod 与生命周期](./Pod与生命周期.md)
5. **大集群 iptables 规则爆炸**：Service 上万 → kube-proxy 同步规则秒级 → 切 IPVS。→ [Service 与 kube-proxy](./Service与kube-proxy.md)
6. **ConfigMap 改完不生效**：env 注入是不可变的，必须重启 Pod；volume 注入有~分钟级延迟。→ [ConfigMap 与 Secret](./ConfigMap与Secret.md)
7. **HPA 抖动**：requests 设得太低导致 CPU 利用率虚高 → 反复扩缩。修复：合理 requests + 加大缩容冷却 + `behavior` 字段限速。→ [发布与弹性伸缩](./发布与弹性伸缩.md)
8. **PV 回收策略 Delete 误删数据**：StorageClass 默认 Delete，PVC 一删 PV 跟着删。修复：生产用 Retain。→ [存储与持久化](./存储与持久化.md)
9. **镜像层 RUN 顺序错**：变化频繁的 COPY 放第一行 → 缓存全失效，构建从 30s 涨到 5min。→ [Dockerfile 与镜像优化](./Dockerfile与镜像优化.md)
10. **滚动更新没配 PDB**：节点维护 drain 时一次性把所有副本 evict 掉 → 业务中断。修复：`PodDisruptionBudget: minAvailable: 1`。→ [发布与弹性伸缩](./发布与弹性伸缩.md)

---

## 八、相关模块

- [Microservice 模块](../Microservice/README.md) — Spring Cloud 全家桶在 K8s 上跑（Nacos vs ConfigMap、Sentinel vs Ingress 限流、Gateway vs Ingress）
- [Network 模块](../Network/README.md) — CNI / Service IP / iptables / IPVS 全靠网络栈底层
- [Distributed 模块](../Distributed/README.md) — etcd 用 Raft、Service 是分布式服务发现、Lease 是分布式锁
- [JVM 模块](../JVM/README.md) — 容器化 JVM 必配 `-XX:+UseContainerSupport`、容器内 GC 调优
- Project 模块 — 上线发布流程 / 故障排查实战
