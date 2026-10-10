# EKS 可观测性 LGTM 栈部署实战

> **一套自建可观测性栈 = 日志(Loki) + 链路(Tempo) + 指标(Prometheus) + 统一 UI(Grafana)**，业界叫 **LGTM**（Loki / Grafana / Tempo / Mimir，指标这里用更轻的 Prometheus TSDB 替代 Mimir）。三类信号各有独立采集链路，最后都汇到 Grafana 一个界面查。本篇从一次真实的 EKS 上从零部署出发，串起 **调度约束、EBS 持久化、DaemonSet、Ingress/ALB、Helm 版本治理**，把生产部署里最容易踩的坑记全。
>
> 本篇讲清一次部署里踩到的 8 个坑：
>
> ① **中心组件调度**：怎么用 `nodeSelector + toleration` 把重组件锁到指定节点组，DaemonSet 又为什么只给 toleration
> ② **存储选型**：EBS gp2 兜底 vs S3，单二进制模式的坑
> ③ **otel-collector preset 注入**：管道里凭空多出个 `k8s_attributes` 处理器
> ④ **Tempo memBallast 撑爆内存 limit**
> ⑤ **PodMonitor 抓取**：怎么用端口名 + selector 精准圈业务服务、排除中间件
> ⑥ **日志 trace_id 高基数**：为什么不能设成 Loki label
> ⑦ **Grafana 数据源 uid 自动生成**：健康检查查错 uid 的乌龙
> ⑧ **复用现有 ALB**：TargetGroupBinding + 手工放行安全组的连环坑
>
> 跟其它篇的关系：
> - 调度：[调度与资源管理](./调度与资源管理.md)（污点容忍 / nodeSelector / QoS / OOMKill 是①④的底层）
> - 存储：[存储与持久化](./存储与持久化.md)（PV/PVC/StorageClass/StatefulSet 存储是②的底层）
> - 工作负载：[工作负载](./工作负载.md)（DaemonSet 为什么适合日志/指标采集，对应⑤⑦）
> - 网络：[Ingress 与网关](./Ingress与网关.md)（Ingress vs 直接绑目标组，对应⑧）
> - 链路：[链路追踪](../Microservice/链路追踪.md)（OTLP / TraceID 传播 / 采样，是③⑥的上游概念）

---

## 一、总体架构：三条信号管道

三类信号，采集方式完全不同，别混为一谈：

| 信号 | 产生方式 | 采集链路 | 落库 |
| --- | --- | --- | --- |
| **指标 Metrics** | 应用暴露 `/metrics`（Prometheus 文本格式） | Prometheus **主动拉**（scrape） | Prometheus TSDB |
| **日志 Logs** | 应用打到 stdout/stderr | Alloy（DaemonSet）**采集节点日志** → 推 | Loki |
| **链路 Traces** | 应用 SDK 生成 span，OTLP 导出 | 应用 → **otel-collector**（推）→ 转发 | Tempo |

```
                      ┌─────────── Grafana(统一查询 UI) ───────────┐
                      │              ▲          ▲          ▲        │
业务 Pod /metrics ◄──scrape── Prometheus      Loki       Tempo     │
业务 Pod stdout ──► Alloy(DaemonSet) ─────────►│          ▲        │
业务 Pod SDK ─OTLP─► otel-collector ──────────────────────┘        │
                      └────────────────────────────────────────────┘
```

**关键点**：指标是"拉"，日志和链路是"推"。所以 Prometheus 要能主动访问业务 Pod（PodMonitor 声明抓谁），而 Alloy/otel-collector 是数据往它们那儿送。

**版本一律 pin**（避免 `helm upgrade` 时 chart 漂移导致行为突变）：

| 组件 | chart | 版本 | app |
| --- | --- | --- | --- |
| Loki | grafana/loki | 6.55.0 | 3.6.7 |
| Tempo | grafana/tempo | 1.24.4 | 2.9.0 |
| otel-collector | open-telemetry/opentelemetry-collector | 0.162.0 | 0.154.0 |
| kube-prometheus-stack | prometheus-community/kube-prometheus-stack | 87.5.1 | v0.92.1 |
| Alloy | grafana/alloy | 1.10.0 | v1.17.0 |

---

## 二、坑①：中心组件调度——nodeSelector + toleration 组合拳

集群有两个节点组：
- `nonprod`（2×t3a.large）带污点 `workload=nonprod:NoSchedule`，跑 test/staging；
- `preprod`（1×m5.xlarge，无污点）跑 prod。

目标：**可观测性中心组件全部锁到 nonprod，绝不落到 prod 节点**（Prometheus 是内存大头，落到 prod 节点会挤占业务）。

**污点 + 节点组标签双管齐下**：

```yaml
# Prometheus / Grafana / Tempo / Loki 等中心组件
tolerations:                                    # 1) 容忍污点，才能"进得去"nonprod
  - key: workload
    value: nonprod
    effect: NoSchedule
nodeSelector:                                   # 2) 指定节点组，才能"只落"nonprod
  eks.amazonaws.com/nodegroup: metaxsire-ng-nonprod
```

> **为什么两个都要**：污点容忍只是"允许被调度到有污点的节点"，但不排斥无污点的 prod 节点——只加 toleration，Prometheus 照样可能落到 prod。必须再加 `nodeSelector` 把落点钉死到 nonprod 节点组。这就是[调度与资源管理](./调度与资源管理.md)里"污点是节点排斥 Pod、亲和是 Pod 选择节点"两个方向要配合用的实例。

**DaemonSet 例外：只给 toleration，不加 nodeSelector**：

```yaml
# Alloy(日志采集) / node-exporter(节点指标) —— 每个节点都要有一个
tolerations:
  - operator: Exists          # 容忍一切污点 → 3 个节点(含 prod)全覆盖
```

> DaemonSet 的语义就是"每节点一个"。日志采集、节点指标必须覆盖**所有**节点（包括 prod），所以不能用 nodeSelector 限制，反而要 `operator: Exists` 容忍所有污点，才能落到带污点的 nonprod 节点上。这是[工作负载](./工作负载.md)里 DaemonSet 典型用途的真实写照。

**验证落点**：

```bash
kubectl -n observability get pods -o wide       # 看 NODE 列
# 中心组件都在 nonprod 两台;alloy/node-exporter 三台各一个
```

---

## 三、坑②：存储——EBS gp2 兜底，单二进制模式

生产级方案是把 Loki/Tempo 的数据放对象存储（S3），但初期为了简单，先用 **Path B：EBS gp2 + 本地文件后端**，日后再迁 S3。

```yaml
# Loki: 单二进制模式(SingleBinary) + filesystem 后端
deploymentMode: SingleBinary
loki:
  storage: { type: filesystem }
singleBinary:
  replicas: 1
  persistence: { storageClassName: gp2, size: 50Gi }
# backend/read/write 三副本组件全部 replicas: 0(单二进制模式下不用)
```

```yaml
# Tempo: local 后端，挂在 EBS PVC 上
tempo:
  storage:
    trace: { backend: local, local: { path: /var/tempo/traces } }
persistence: { enabled: true, storageClassName: gp2, size: 10Gi }
```

> gp2 是 `ReadWriteOnce`（单节点挂载），配合 StatefulSet/单副本正好；这就是[存储与持久化](./存储与持久化.md)里 StatefulSet + 动态供应（StorageClass 自动建 EBS 卷）的落地。迁 S3 时 Loki/Tempo 改 `backend: s3` + IRSA（给 ServiceAccount 挂 IAM 角色）即可，无需动应用。

**保留策略：14 天自动删，防撑爆那 50Gi 盘**。本地盘容量固定，必须配保留期让老日志自动清，否则迟早写满：

```yaml
loki:
  limits_config:
    retention_period: 336h        # ① 保留 14 天(336÷24)
  compactor:
    retention_enabled: true       # ② 必须开!只设 retention_period 不删,这个才真删
    delete_request_store: filesystem
```

三个易错点：

1. **`retention_period` 单设不会删**——它只声明保留期，真正执行删除靠 `compactor.retention_enabled: true`，两者缺一不删。
2. **不是到点即删，是 compactor 周期扫**（默认每 10min 一轮），按 **chunk 粒度**删过期块并释放 EBS 空间。所以实际可能比 14 天多留几分钟到几小时。
3. **filesystem 后端删了不可恢复**，无备份、物理删除。想留更久改 `retention_period`（注意盘够不够）；想按服务分级用 `retention_stream` 按 label 配（如 prod 30 天/test 3 天）；想永久留存只能迁 S3 + 生命周期策略。

---

## 四、坑③：otel-collector 的 preset 会凭空注入处理器

otel-collector 的 Helm chart 有个 `presets` 机制，开一个开关会自动改管道：

```yaml
presets:
  kubernetesAttributes:
    enabled: true       # 自动:加 k8s.namespace.name/pod 等属性 + 配 RBAC
                        #      + 往每条管道前置注入一个处理器 k8s_attributes
```

**坑**：这个自动注入的处理器名叫 `k8s_attributes`（**下划线**）。如果你在 `service.pipelines.traces.processors` 里又手动写了 `k8sattributes`（无下划线，官方组件名），启动会报 "processor not configured"——因为你写的那个没在 `processors:` 段定义。

**正解**：开了 preset 就**别在管道里手写它**，让 preset 自己前置注入：

```yaml
config:
  service:
    pipelines:
      traces:
        processors: [transform/env, batch]   # k8s_attributes 由 preset 自动前置
```

验证渲染结果（部署前一定 `helm template` 看一眼）：

```bash
helm template otel-collector open-telemetry/opentelemetry-collector \
  --version 0.162.0 -f values/otel-collector.yaml | grep -A3 "traces:"
# 渲染出的 processors 应是 [k8s_attributes, transform/env, batch]
```

> 另一个相关坑：Service 名要精确。6 个业务 overlay 里写死了 `otel-collector.observability:4317`，所以 chart 必须 `fullnameOverride: otel-collector`，否则 Service 名会变成 `otel-collector-opentelemetry-collector`，业务端连不上。

---

## 五、坑④：Tempo 的 memBallast 撑爆内存 limit

Tempo chart 默认 `memBallastSizeMbs: 1024`（1G 内存 ballast，老式 GC 优化手段）。如果你给 Tempo 设了 `limits.memory: 512Mi`，**ballast 一上来就要 1G，直接 OOMKilled**。

```yaml
tempo:
  memBallastSizeMbs: 0          # 关掉,用 cgroup 内存约束即可
  resources:
    limits: { memory: 512Mi }
```

> 这是[调度与资源管理](./调度与资源管理.md)里 **limits 与 OOMKill** 的经典случае：容器实际内存需求（含 ballast）必须小于 limit，否则 QoS 再高也会被内核 OOM 杀。部署前要核对每个组件的默认内存行为，别只看 requests。

---

## 六、坑⑤：PodMonitor 精准圈业务服务

Prometheus Operator 用 **PodMonitor** CRD 声明"抓哪些 Pod 的 /metrics"。难点：业务命名空间里既有业务服务，也有 redis/milvus/openim 等中间件，还有 nginx 网关——不能全抓。

**关键机制：`port` 按端口名匹配，只有声明了该端口名的 Pod 才生成抓取目标**：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: metaxsire-services
  namespace: observability          # 只在 observability 建对象
  labels: { release: kube-prometheus-stack }   # 供 Prometheus 的 selector 识别
spec:
  namespaceSelector:
    matchNames: [metaxsire-test, metaxsire-staging, metaxsire-prod]   # 跨命名空间抓
  selector:
    matchExpressions:
      - { key: app.kubernetes.io/name, operator: NotIn, values: [api-gateway] }  # 排除 nginx 网关
  podMetricsEndpoints:
    - port: http                    # 业务服务端口名统一是 http;中间件端口名是 redis/无名 → 天然排除
      path: /metrics
      interval: 15s
```

两层过滤，圈得干干净净：
- **`port: http`**：业务 Go 服务端口名都叫 `http`；redis 端口名是 `redis`、milvus/openim 端口无名——它们不生成抓取目标。
- **`NotIn [api-gateway]`**：网关虽也有 `http:80`，但它是 nginx，`/metrics` 返回 404，会变成永久 down target，用 selector 排除。

> **重要约束**：PodMonitor 的 `namespaceSelector` 能跨命名空间抓取，所以对象只建在 observability，**完全不用动业务命名空间**。验证：`kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090` 后查 `/api/v1/targets`，业务 target 应全 `up`。

---

## 七、坑⑥：日志 trace_id 不能设成 Loki label

想让日志能按 trace_id 过滤、并从日志跳到链路。Alloy 采集时从 JSON 日志里提取 trace_id，**但绝不能设成 Loki 的 label**：

```river
loki.process "parse" {
  stage.json { expressions = { trace_id = "trace_id" } }
  // ❌ stage.labels    → trace_id 做 label:基数无上限,索引爆炸
  // ✅ structured_metadata:可查询,不进索引
  stage.structured_metadata { values = { trace_id = "" } }
  forward_to = [loki.write.default.receiver]
}
```

> **为什么**：Loki 按 label 组合建索引流（stream）。trace_id 每条请求都不同、基数无上限，做成 label 会瞬间产生天量 stream，把 Loki 索引撑爆。**低基数的（namespace/pod/container/app）才做 label，高基数的（trace_id/user_id）用 structured_metadata**（Loki 3.x 特性，schema v13 默认开）。
>
> 而且 Grafana 的 "日志跳链路"（derived field）是用正则从**日志原文**里抓 trace_id 的，根本不依赖 label：
> ```yaml
> derivedFields:
>   - matcherRegex: '"trace_id":"(\w+)"'
>     datasourceUid: tempo        # 抓到就给一个跳 Tempo 的链接
> ```

日志采集本身覆盖全部 Pod（含中间件，排障有用），这跟只抓业务指标的策略不同——**日志要全、指标要精**。

---

## 八、坑⑦：Grafana 数据源 uid 是自动生成的

用 `additionalDataSources` 预置 Loki/Tempo 数据源时，**没显式写 `uid` 的数据源，uid 会自动生成一串随机码**（如 `P8E80F9AEF21F6940`）。

排障时我用 `/api/datasources/uid/loki/health` 去查，一直返回 "Unable to load datasource meta data"，以为 Loki 连不通——**其实是 uid 根本不是 `loki`**。用真实 uid 查就 OK。

```yaml
additionalDataSources:
  - name: Loki
    type: loki
    uid: loki               # 显式指定!否则自动生成随机 uid,别处引用会断
    url: http://loki.observability:3100
  - name: Tempo
    type: tempo
    uid: tempo              # derived field 的 datasourceUid: tempo 就靠这个
    url: http://tempo.observability:3200
```

> **教训**：凡是会被别处按 uid 引用的数据源（尤其 Tempo，被 Loki 的 derived field 引用），一定显式写 `uid`。查数据源健康前先 `GET /api/datasources` 确认真实 uid，别想当然。

---

## 九、坑⑧：复用现有 ALB——TargetGroupBinding + 手工放行安全组

需求：Grafana 要能从浏览器访问，但**不新建 ALB**（省成本），复用集群已有的 `alb-gate-test`。

集群现状很关键：**没有 Ingress，也没有 LoadBalancer Service**。现有 ALB 是"**手工建 ALB + `TargetGroupBinding` CRD 绑 Pod IP**"的套路（不是 Ingress Controller 管的）。所以照此套路挂 Grafana：

**① 应用侧：Grafana 配子路径**（复用现有域名的 `/grafana` 路径，无需新 DNS）

```yaml
grafana:
  grafana.ini:
    server:
      root_url: "https://api-test.metaxsire.com/grafana"
      serve_from_sub_path: true    # Grafana 全路由挂 /grafana 前缀
```

**② AWS 侧：建 IP 目标组 → TargetGroupBinding 绑 Service**

```yaml
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata: { name: grafana, namespace: observability }
spec:
  serviceRef: { name: kube-prometheus-stack-grafana, port: 80 }
  targetGroupARN: <目标组 ARN>
  targetType: ip
```

**③ 连环坑（血泪）**：

| 现象 | 原因 | 解法 |
| --- | --- | --- |
| target 一直 `unused` | 目标组没被任何监听规则引用，ELB 不健康检查 | 先加监听规则，健康检查才激活 → **调整顺序：先挂规则再等健康** |
| target `Target.Timeout` | ALB 安全组只放行了业务的 80，Grafana 在 3000 端口 | 手工给节点 SG 加一条 `tcp/3000` 入站，源=ALB 流量 SG |
| 以为 Controller 自动放行 | AWS LB Controller **只自动管它自己建的 ALB**；手工建的 ALB 后端 SG 它不碰 | 手工 ALB 就得手工 `authorize-security-group-ingress` |

```bash
# 手工放行(镜像现有 80 规则)
aws ec2 authorize-security-group-ingress --group-id <节点SG> \
  --ip-permissions 'IpProtocol=tcp,FromPort=3000,ToPort=3000,UserIdGroupPairs=[{GroupId=<ALB流量SG>}]'
```

**④ 加监听规则**（只新增，不碰现有规则）：`host=api-test.metaxsire.com AND path=/grafana*` → 转发到 Grafana 目标组。先摸清现有规则确认不冲突（现有网关规则只匹配 `/v2/*`）。

> **对比 [Ingress 与网关](./Ingress与网关.md)**：如果集群用 Ingress Controller（如 AWS LB Controller 管 Ingress），加个 `Ingress` 对象、`group.name` 注解就能共享 ALB，安全组也自动管。这里因为 ALB 是手工建的历史包袱，才要手工绑目标组 + 手工放行 SG。**Ingress 是声明式托管，TargetGroupBinding + 手工 ALB 是半手工**——理解这个区别，才知道两种模式各自要维护什么。
>
> 安全提醒：复用的是 internet-facing（公网）ALB，Grafana 因此暴露公网（仅 admin 密码保护）。要收紧可在监听规则加 `source-ip` 条件限定出口 IP，或前置 OIDC。

---

## 十、日志全流程：从 stdout 到 Loki（原理补充）

前面几坑讲的是"部署时怎么配"，这里补一条**"日志到底怎么流"**的主线——云原生日志的核心思想一句话：**应用只管往 stdout 打，收集/落盘/轮转全甩给平台。**

### EKS 里一条日志的完整旅程

```
应用 → stdout ──► containerd 捕获 ──► 节点 /var/log/pods/<pod>/<container>/*.log
                                              ↑ 读文件(每节点本地)
                              Alloy(DaemonSet,每节点一个)
                                              │ 打低基数标签 namespace/pod/container/app
                                              ▼
                                   Loki(loki.observability:3100)
                                              ↑ 查询
                                   Grafana 按 {namespace,pod,container,app}
```

**关键：应用零改造**。容器运行时（containerd）自动把每个容器的 stdout/stderr 落到节点本地 `/var/log/pods/`，Alloy 去读这些文件。所以「日志采集」根本不侵入业务代码——这跟 [Docker 存储与数据卷](./Docker存储与数据卷.md) 里容器 stdout 由运行时接管是同一回事。

Alloy 的 EKS 配置（`values/alloy.yaml`）三个要点：

1. **DaemonSet + `toleration: Exists`**：日志文件在各节点本地，必须每台一个采集器；故意不加 nodeSelector，连 prod 节点也覆盖（只读日志、50m/128Mi 极小）。呼应坑①的"DaemonSet 只给 toleration"。
2. **只发现三个业务命名空间的 Pod**（`discovery.kubernetes` + `namespaces`），经 k8s API 发现而非瞎扫。
3. **只打低基数标签** `namespace/pod/container/app`——其中 `app` 取自 `app.kubernetes.io/name`，**又是那个被 Deployment/Service 反复复用的标签**（见 [EKS 节点组与 Kustomize 部署全链路实战](./EKS节点组与Kustomize部署全链路实战.md)）；trace_id 走 structured_metadata（坑⑥）。

### dev 环境为什么不一样：混合来源

本地无 k8s，Alloy 走 **Docker socket** 发现容器，还要额外处理"宿主进程"：

| 日志来源 | 采集方式 |
| --- | --- |
| 容器化服务（livekit/openim/app） | 挂 `/var/run/docker.sock`，`loki.source.docker` 收所有容器 stdout |
| 宿主 `go run` 的后端（dev.log） | Docker socket **采不到**！只读挂 repo，`loki.source.file` tail `apps/*/*-service/dev.log`，正则从路径提 `<svc>` 当标签 |

> 这解释了本地开发一条约定：`go run` 服务的 `dev.log` 必须落在服务根目录，否则 Alloy 的 `local.file_match` glob 匹配不到。

### 反模式对比：别把日志写进 PVC

| | 云原生做法（本项目） | 传统做法（写文件挂 PVC） |
| --- | --- | --- |
| 日志去向 | **stdout** → 平台采集 | 写文件 → 挂 PVC 持久化 |
| 应用职责 | 只打 stdout | 自管文件/路径/轮转 |
| 多副本 | 无冲突（各 Pod stdout 独立收） | **RWO PVC 多副本 Multi-Attach 争用** |
| 查询 | Grafana/Loki 统一查 | 进 Pod / 翻卷看文件 |

> Java 服务尤其容易掉进"日志挂 PVC"的坑（`logback` 默认写文件）。云原生正解是让 logback 输出到 `ConsoleAppender`（stdout），交给 Alloy，别挂 PVC——否则多副本时 RWO 卷争用，正是 [EKS Grafana 多环境 Dashboard 实战](./EKS-Grafana多环境Dashboard落地实战.md) 里 Multi-Attach 死锁的同源问题。

### 配置文件对照（按图索骥）

采集器是 **Grafana Alloy**（Promtail 后继者），dev / EKS 两套形态，核心就 4 个文件：

| 环境 | 采集配置 | 采集器形态 | push 目标 |
| --- | --- | --- | --- |
| **dev** | `infra/dev/alloy-config.alloy`（独立 River 文件） | compose 容器 `alloy`（`infra/dev/docker-compose.yml`，`profiles:[monitor]`） | `loki:3100` |
| **EKS** | `values/alloy.yaml` 的 `configMap.content`（内联） | Helm **DaemonSet**（由 `install.sh` 部署，`ALLOY_VER` pin） | `loki.observability:3100` |

```
dev:  alloy-config.alloy   →  compose 容器  →  loki:3100
EKS:  values/alloy.yaml     →  Helm DaemonSet →  loki.observability:3100
              ↑ install.sh: helm upgrade --install alloy grafana/alloy
```

> 落库端 Loki 配置分别在 dev 的 `docker-compose.yml`（`loki` 服务）和 EKS 的 `values/loki.yaml`。其余 `podmonitors/`、`values/tempo.yaml`、`values/otel-collector.yaml` 属于指标/链路管道，不在「日志采集」这条线上。dev 启动采集：`docker compose --profile monitor up -d alloy`。

### dev 与 EKS 两份 Alloy 配置：功能对等，实现各异

同是 Alloy、同是"日志→Loki"，但两份配置**不等价**——像「同一个 App 的桌面版和手机版」，为各自平台的能力做了不同适配，不能互换：

| 维度 | dev `alloy-config.alloy` | EKS `values/alloy.yaml` |
| --- | --- | --- |
| 文件性质 | 纯 River 配置 | **Helm values**，River 内嵌 `configMap.content` |
| 额外内容 | 只有采集逻辑 | 还包 `controller`(DaemonSet)/`tolerations`/`rbac`/`resources` |
| 发现机制 | **Docker socket** + tail 宿主文件 | **k8s API**（`discovery.kubernetes`） |
| 采集范围 | **所有容器**（含中间件，本地排障用） | **只 3 个业务命名空间** |
| 数据源数量 | 2 个（容器 stdout + 宿主 `dev.log`） | 1 个（k8s pod） |
| 日志加工 | ❌ 无 | ✅ 提 `trace_id` → structured_metadata |
| 标签 | `container` / `service` | `namespace` / `pod` / `container` / `app` |
| push 目标 | `http://loki:3100` | `http://loki.observability:3100` |

**最核心的差异是发现机制**：dev 是「容器视角」（问 Docker），EKS 是「Pod 视角」（问 apiserver）——底层编排不同，发现日志的方式必然不同。**副作用**：标签不同 → **同一 Grafana 查询两环境不通用**（dev `{service="social"}` vs EKS `{app="social-service",namespace="metaxsire-staging"}`），这正是 [Grafana 多环境 Dashboard 实战](./EKS-Grafana多环境Dashboard落地实战.md) 里 dev 盘与 EKS 盘必须分别派生的根因。

---

## 十一、复盘要点

1. **三类信号三条链路**：指标"拉"（Prometheus scrape）、日志/链路"推"（Alloy/otel-collector）。别用一个机制套所有。
2. **调度**：中心组件 `nodeSelector + toleration` 双管钉死落点；DaemonSet 只给 `toleration: Exists` 求全覆盖。方向相反，别搞混。
3. **部署前 `helm template` 看渲染**：preset 注入、Service 名、默认内存行为（memBallast）这些坑，模板阶段就能发现，别等 OOM/连不上才查。
4. **基数意识**：Loki label / Prometheus label 都怕高基数。trace_id/user_id 这类进 structured_metadata，别进 label。
5. **数据源显式写 uid**：被引用的（尤其 Tempo）必须显式，否则随机 uid 断链。
6. **复用手工 ALB 的代价**：TargetGroupBinding 能绑，但后端安全组要手工放行（Controller 不管手工 ALB）；目标组被规则引用后才健康检查。能用 Ingress 托管就别手工。
7. **只动自己的命名空间**：PodMonitor 的 `namespaceSelector` 跨命名空间抓取、日志靠 DaemonSet 采集——对象全建在 observability，业务命名空间零改动，是"可观测性栈不侵入业务"的正确姿势。
