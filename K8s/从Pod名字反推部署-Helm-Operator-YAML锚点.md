# 从 Pod 名字反推部署：Helm / Operator / YAML 锚点

> **给你一屏 `kubectl get pod`，你能不能倒推出「谁装的、几个副本、名字为什么长这样」？**——这是把 [工作负载](./工作负载.md) / [调度与资源管理](./调度与资源管理.md) / [K8s 架构总览](./K8s架构总览.md) 三篇串起来的「读栈」能力。本篇用一套真实 EKS 可观测性栈（kube-prometheus-stack + Loki/Tempo/otel/alloy）做标本，讲清四件反直觉的事：
>
> ① **一个 values 文件 = 一个 Helm release** —— 十几个 pod 其实来自 5 个 release
> ② **Pod 名字 = release 名 + chart fullname + 控制器后缀** —— 三层拼出来的
> ③ **Operator 模式** —— Prometheus/Alertmanager 的 pod 不是 Helm 建的，是「CR → operator → StatefulSet → Pod」两层控制器接力建的
> ④ **YAML 锚点 `&` / `*` / `<<:`** —— Helm values 里复用配置的语法
>
> 前置：[工作负载](./工作负载.md)（Deployment/StatefulSet/DaemonSet 的控制器语义）、[调度与资源管理](./调度与资源管理.md)（nodeSelector/toleration）。
> 承接：[EKS 可观测性 LGTM 栈部署实战](./EKS可观测性LGTM栈部署实战.md)（本篇标本就是那套栈，那篇讲怎么装，本篇讲装完怎么读）。

---

## 一、标本：一屏 pod

`kubectl -n observability get pod` 大致是这样（3 节点集群：2 台 nonprod + 1 台 preprod）：

```
alertmanager-kube-prometheus-stack-alertmanager-0        # StatefulSet
alloy-f76l6 / alloy-mk7js / alloy-tqwjl                  # DaemonSet ×3
kube-prometheus-stack-grafana-84cc65588-skvch           # Deployment
kube-prometheus-stack-kube-state-metrics-6485f858bd-... # Deployment
kube-prometheus-stack-operator-6b865ddd68-fss9k         # Deployment
kube-prometheus-stack-prometheus-node-exporter-g9jp9    # DaemonSet ×3
  (+ kv6xn + qxkhd)
loki-0                                                  # StatefulSet
otel-collector-56944bc4dc-x577t                         # Deployment
prometheus-kube-prometheus-stack-prometheus-0           # StatefulSet
tempo-0                                                 # StatefulSet
```

面试/排障现场的问题永远是：**这堆东西谁装的？为什么有的带 `kube-prometheus-stack` 前缀有的不带？为什么 node-exporter 有 3 个而 grafana 只有 1 个？**

---

## 二、心智模型：一个 values 文件 = 一个 Helm release

第一层前缀来自**装它的 Helm release 名**，也就是 `helm upgrade --install <release名>` 的那个名字。这套栈的 `install.sh` 跑了 **5 个独立 release**：

| Helm release 名 | chart | 产出的 pod 前缀 |
| --- | --- | --- |
| `kube-prometheus-stack` | prometheus-community/kube-prometheus-stack | `kube-prometheus-stack-*`（含 prometheus/alertmanager/grafana/operator/kube-state-metrics/node-exporter） |
| `loki` | grafana/loki | `loki-*` |
| `tempo` | grafana/tempo | `tempo-*` |
| `otel-collector` | open-telemetry/opentelemetry-collector | `otel-collector-*` |
| `alloy` | grafana/alloy | `alloy-*` |

**关键点**：`kube-prometheus-stack` 是个「伞形 chart」（umbrella / 子 chart 集合），一个 release 里塞了 6 个组件；而 loki/tempo/otel/alloy 各是独立 chart、独立 release。所以：

- 带 `kube-prometheus-stack-` 前缀 = 属于那**一个** release 的子 chart。
- 不带 = 是**另外 4 个** release，各自 release 名就是全名前缀。

> 📌 **心智模型**：看到一个 pod，先看前缀 → 反推是哪个 `helm install` 装的 → 去找对应的 `values/<name>.yaml`。「一个 values 文件对一个 release」是读栈的第一把钥匙。

---

## 三、Pod 名字 = 三层拼接

一个 Pod 名可以机械拆成三段：

```
<Helm release/fullname 前缀>  -  <中段>  -  <控制器后缀>
```

### 3.1 第一层：Helm fullname 前缀

- 子 chart 命名规则一般是 `<release名>-<子chart名>`：`kube-prometheus-stack` + `grafana` = `kube-prometheus-stack-grafana`。
- 独立 chart 若 release 名已含 chart 名，Helm 的 `fullname` helper 会**去重**，直接用 release 名：所以是 `loki-0` 而不是 `loki-loki-0`。

### 3.2 第三层：控制器后缀（决定名字尾巴）

Pod 是控制器造的，不同控制器加的尾巴不同——**这一段能反推出工作负载类型**：

| 控制器 | 后缀规则 | 例子 | 反推 |
| --- | --- | --- | --- |
| **Deployment** | `-<ReplicaSet 哈希>-<随机5位>` | `grafana-84cc65588-skvch` | 两段乱码 → Deployment |
| **StatefulSet** | `-<序号>`（从 0 递增） | `loki-0`、`tempo-0` | 结尾是纯数字 → StatefulSet |
| **DaemonSet** | `-<随机5位>` | `alloy-f76l6` | 一段乱码、且每节点一个 → DaemonSet |

> Deployment 的 pod 名里那段 `84cc65588` 是它下层 **ReplicaSet 的哈希**（Deployment → ReplicaSet → Pod，见 [工作负载 §2.1](./工作负载.md)），最后 5 位才是 pod 自己的随机串。

### 3.3 数量从哪来（接「node-exporter 3 个、grafana 1 个」）

**数量由「工作负载类型 + 副本数」决定，跟 nodeSelector/toleration 无关**：

| 组件 | 类型 | 数量来源 | pod 数 |
| --- | --- | --- | --- |
| grafana / operator / kube-state-metrics / otel | Deployment | chart 默认 `replicas: 1`（values 没改） | 1 |
| prometheus / alertmanager / loki / tempo | StatefulSet | 默认 `replicas: 1` | 1 |
| node-exporter / alloy | **DaemonSet** | 无副本数，**= 可调度节点数** | 3 |

- **要「每台一份」** → DaemonSet，数量随节点数变（加一台节点立刻补一个）。
- **要「固定 N 个」** → Deployment/StatefulSet 的 `replicas`，跟节点几台无关。
- **nodeSelector / toleration 只筛「候选节点」，从不加减 pod 数量**。中心组件（prometheus/grafana…）都锁 `nodeSelector: nonprod`，只是把那**唯一 1 个** pod 限定到 nonprod 的 2 台里挑一台落；node-exporter/alloy 故意**不设 nodeSelector**、只给 `tolerations: [{operator: Exists}]`，才能铺满全部 3 台（含被打了 `workload=nonprod` 污点的节点）。详见 [调度与资源管理](./调度与资源管理.md)。

> ⚠️ **口径陷阱**：values 注释「DaemonSet 覆盖全部 3 节点」里的「3」是**集群总节点数**（nonprod 2 + preprod 1），不是 nonprod 节点数（2）。DaemonSet 的覆盖面永远是「整个集群的可调度节点」，跟节点组无关。

---

## 四、Operator 模式：pod 是「间接」被造出来的

看这两个名字，会觉得别扭：

```
prometheus-kube-prometheus-stack-prometheus-0      # prometheus 出现了两次
alertmanager-kube-prometheus-stack-alertmanager-0  # alertmanager 出现了两次
```

原因：**它们不是 Helm 直接建的，是 Prometheus Operator 建的**。这是 K8s 最重要的扩展范式——**Operator 模式（CRD + 自定义 Controller）**，整个云原生生态（Istio / Argo / cert-manager…）都建立在此（见 [K8s 架构总览 §扩展点](./K8s架构总览.md)）。

### 4.1 调谐链：一条「控制器套控制器」的接力

```
①  helm install kube-prometheus-stack
      └─ 只往集群写了几样"声明"（此刻还没有任何 prometheus pod）：
         · CRD           —— 定义 Prometheus/Alertmanager 这种"自定义资源类型"
         · operator 的 Deployment
         · 一个 Prometheus CR    (name: kube-prometheus-stack-prometheus)
         · 一个 Alertmanager CR  (name: kube-prometheus-stack-alertmanager)
                     │
②  operator pod 起来，watch 这两个 CR
      "有个 Prometheus CR 期望 replicas=1，但还没有对应 StatefulSet"
                     ▼
③  operator 调谐(reconcile) → 创建 StatefulSet
      statefulset/prometheus-kube-prometheus-stack-prometheus
                     │
④  StatefulSet 控制器(k8s 内置，不是 operator) 看到 replicas=1 但 0 个 pod
                     ▼
⑤  真正创建 pod：prometheus-...-prometheus-0     ← pod 在这一步才诞生
```

**两个反直觉点**：

1. **operator 自己不建 pod**，它只建 StatefulSet；真正拉起 pod 的是 k8s **内置的** StatefulSet 控制器。所以是「operator 控制器 + 内置控制器」两层接力。
2. **触发时机是声明式的**：只要 CR 被创建**或修改**，operator 就重新调谐。改 `values` 里的 `retention`/`replicas` 再 `helm upgrade` → CR 变 → operator 感知 → 改 StatefulSet → 触发 pod 重建。你只改「期望」，增删 pod 由控制器链自动完成。

### 4.2 名字为什么「反过来」

拆 `prometheus-kube-prometheus-stack-prometheus-0`：

| 片段 | 来源 |
| --- | --- |
| `prometheus-` | Operator **硬编码的资源类型前缀**（Alertmanager 就是 `alertmanager-`） |
| `kube-prometheus-stack-prometheus` | **CR 的名字**（= release 名 + chart 给 CR 起的后缀 `prometheus`） |
| `-0` | StatefulSet 序号 |

所以「prometheus 一头一尾各一次」：一个是 operator 加的类型前缀，一个是 CR 名字里的。这也是**判断「一个 pod 是不是 operator 代管」的经验法则**：名字被套了一层 `<资源类型>-` 前缀（`prometheus-` / `alertmanager-`），八成是某个 operator 建的，去 `kubectl get <crd>` 能找到对应 CR。

### 4.3 现场三连查（沿调谐链逐层核对）

```bash
kubectl -n observability get prometheus          # ① CR：RECONCILED=True 说明 operator 已调谐到位
kubectl -n observability get statefulset          # ② operator 建的 StatefulSet
kubectl -n observability get pod                   # ③ StatefulSet 控制器建的 Pod（名带 -0）
# 看某 pod 精确创建时间 / 事件链（被谁建、调度到哪、拉镜像）：
kubectl -n observability describe pod prometheus-kube-prometheus-stack-prometheus-0
```

CR 那行的 `RECONCILED: True` = operator 在说「我已把这个 CR 的期望落实了」。链上任一环缺失（有 CR 没 StatefulSet / 有 StatefulSet 没 Pod）就能定位卡在 operator 还是内置控制器。

---

## 五、YAML 锚点 & 合并键：Helm values 里的「抽公共变量」

Helm values / 原生 K8s YAML 里常见这三个符号，本质是 YAML 原生的**复用机制**（不是 Helm 特有）：

```yaml
# 顶部定义一次公共块（& 定义锚点，取名 nonprodSched）
_nonprodSched: &nonprodSched
  nodeSelector:
    eks.amazonaws.com/nodegroup: metaxsire-ng-nonprod
  tolerations:
    - key: workload
      value: nonprod
      effect: NoSchedule

grafana:
  service: { type: ClusterIP }
  <<: *nonprodSched          # 把公共块的键"合并"进 grafana 这一层
kube-state-metrics:
  <<: *nonprodSched          # 复用同一份，改锚点即三处同步
```

| 符号 | 名字 | 作用 | 类比 |
| --- | --- | --- | --- |
| `&name` | 锚点 anchor | 给一段内容起名 | 定义变量 |
| `*name` | 别名 alias | 引用锚点 | 取变量值 |
| `<<:` | 合并键 merge key | 把引用到的 **map 的键值对合并进当前层** | 展开/继承 |

`grafana` 里那句 `<<: *nonprodSched` 等价于原地贴上 `nodeSelector` + `tolerations` 两个键，同时 grafana 还能保留自己的 `service` 等键。

**两个坑**：

1. **`_nonprodSched` 前的下划线纯属约定**：表示「这是只为复用而存在的私有键，不是真实配置」。Helm/chart 不认识这个顶层键会忽略它，它唯一价值是挂住锚点。
2. **`<<:`（合并）≠ 直接 `*`（整体替换）**：`<<` 是把键**并进来**、当前 map 还能写别的键；直接 `key: *anchor` 是整块替换。若公共块的层级和目标层级对不上（比如调度键要塞进更深的 `prometheusSpec:` 里），合并键会失配——这种地方通常只能**手写展开**一遍（这就是为什么同一个文件里 grafana 用了 `<<:` 而 prometheus 那段是照抄的）。

---

## 六、Helm 与 kubectl：谁装的、谁管的

上面 §二 说「一个 values 文件 = 一个 Helm release」，那 Helm 和 kubectl 到底啥关系？本套栈的 `install.sh` 里两者**混用**：`helm upgrade --install` 装 Loki/Tempo/kube-prometheus-stack，`kubectl apply` 建 namespace/PodMonitor/Secret。它们不是二选一，而是**上下层**。

> **一句话**：kubectl 是「原子操作」——直接对 apiserver 增删改查**单个资源**；Helm 是「包管理器」——把一堆资源打成模板包(chart)，一条命令**批量渲染 + 下发**，底层还是走 apiserver。类比：kubectl ≈ 手写配置 / `dpkg -i` 单包；Helm ≈ `apt install` 一键装整套。

### 6.1 Helm 站在 kubectl 之上（同一个 apiserver）

```
helm install
   │ ① 读 chart 模板(templates/*.yaml) + values.yaml
   ▼
本地渲染成一大坨最终 YAML(Deployment/Service/CRD/...)
   │ ② 直接调 apiserver 下发这批(等价于 kubectl apply 一整组)
   ▼
apiserver ← 唯一入口，Helm 和 kubectl 最终都到这
   ▼
etcd 存期望 → 控制器 reconcile → 起 Pod
```

**两者最终都调 apiserver**，所以 Helm 装的东西，kubectl 一样能 `get/describe/delete`。

### 6.2 对照表

| 维度 | kubectl | Helm |
| --- | --- | --- |
| 定位 | k8s 官方 CLI，apiserver 直接客户端 | chart 包管理器，构建在同一套 API 之上 |
| 操作粒度 | 单个/多个**资源对象** | 一整个 **release**(一组资源 + 版本) |
| 输入 | 写死的 YAML / 命令行参数 | **模板** + **参数(values.yaml)** |
| 模板化 | 无(多环境靠复制或 Kustomize) | **有**(Go template，按环境注参) |
| 版本/回滚 | 无(`rollout undo` 只针对 Deployment) | **release 有版本历史**，`helm rollback` 整包回退 |
| 依赖管理 | 无 | chart 可声明子 chart(如 kube-prometheus-stack 伞形包) |
| 卸载 | 逐个删 / 按 label | `helm uninstall <release>` 一键删整组 |

### 6.3 分工原则（对回 install.sh）

- **成套第三方软件** → Helm：组件多、参数多、社区有现成 chart（Loki/Tempo/otel/kube-prometheus-stack/Alloy 各一个 release）。
- **零散的自己的小资源** → kubectl apply：namespace、PodMonitor CRD、grafana-admin Secret、TargetGroupBinding——就一两个对象，没必要打包。

### 6.4 坑：Helm 装的别用 kubectl 手改

Helm 装的都是普通 k8s 对象，`kubectl edit` 能改——但下次 `helm upgrade` 会**按 values 把你的手改覆盖回去**（Helm 以自己记录的 release 状态为准）。**最佳实践：Helm 装的只从 values.yaml 改**，别用 kubectl 手改，否则配置漂移。

> **口诀**：装/升/回滚整套用 **Helm**；查/删/排障单个用 **kubectl**（`get`/`describe`/`logs` 不可替代）。Helm 装完照样用 kubectl 看 Pod。

---

## 七、复盘要点（30 秒话术）

- **读栈第一步**：看 pod 前缀 → 反推 Helm release → 找对应 `values/<name>.yaml`。「一个 values 文件 = 一个 release」。
- **名字三层**：`<release/fullname 前缀> - <中段> - <控制器后缀>`。尾巴认类型：**纯数字 = StatefulSet、两段哈希 = Deployment、一段随机且每节点一个 = DaemonSet**。
- **数量三原则**：DaemonSet 数 = 节点数；Deployment/StatefulSet 数 = `replicas`（默认 1）；nodeSelector/toleration **只管落哪、不管几个**。
- **Operator 模式**：pod 不是 Helm 也不是 operator 直接建的——Helm 写 **CR** → operator 建 **StatefulSet** → 内置控制器建 **Pod**，两层控制器接力，声明式触发（改 CR 即重建）。名字被套 `<资源类型>-` 前缀（`prometheus-`/`alertmanager-`）是 operator 代管的标志。
- **YAML 复用**：`&` 定义、`*` 引用、`<<:` 合并；`_` 开头是私有锚点键；层级对不上就退化成手写展开。
- **Helm vs kubectl**：Helm 在 kubectl 之上、共用同一个 apiserver；装/升/回滚整套用 Helm，查/删/排障单个用 kubectl；Helm 装的只从 values 改，别 kubectl 手改（会被下次 upgrade 覆盖）。

---

## 八、相关

- [工作负载](./工作负载.md) —— Deployment / StatefulSet / DaemonSet 控制器语义、OwnerReference 级联
- [调度与资源管理](./调度与资源管理.md) —— nodeSelector / 亲和 / 污点容忍 / 为什么锁节点还要配 toleration
- [K8s 架构总览](./K8s架构总览.md) —— CRD + Operator 是 K8s 四大扩展点之首、声明式 API 与控制循环
- [EKS 可观测性 LGTM 栈部署实战](./EKS可观测性LGTM栈部署实战.md) —— 本篇标本栈的「怎么装」篇（PodMonitor CRD、锁节点、EBS 持久化、复用 ALB）
- [EKS 节点组与 Kustomize 部署全链路实战](./EKS节点组与Kustomize部署全链路实战.md) —— 节点组 / nodeSelector+taint 隔离 / Deployment→Service 全链路
