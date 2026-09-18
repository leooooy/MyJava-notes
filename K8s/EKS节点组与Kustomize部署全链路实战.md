# EKS 节点组与 Kustomize 部署全链路实战

> 从「EKS 上有哪些机器」一路追到「一个服务怎么落到某台机器上跑」，把 **节点(Node) → 节点组(NodeGroup) → 调度(nodeSelector+taint) → 组织(Kustomize base/overlay) → 工作负载(Deployment) → 网络(Service)** 六层串成一条真实部署链。核心收获：**EKS 节点是成组管理的（NodeGroup=ASG），非生产负载靠「节点打标签 + Pod 选标签 + 污点兜底」隔离到独立的 Spot 节点，而这套隔离规则是用 Kustomize overlay 打 patch 注入的，base 完全不感知。**

案例来自 metaxsire：EKS 集群 `EKSmetaxsire`(us-west-1)，用 social 服务（`infra/k8s/social/`）走通一次从节点到访问的完整部署。

---

## 一、先建立 mental model：节点是「成组的机器」

在 EKS 里，**Node = 一台 EC2 虚拟机**，是 Pod 最终运行的地方（提供 CPU/内存/磁盘/网络）。但你几乎从不单台建节点，而是按 **NodeGroup（节点组）** 管理——一组规格相同的节点，背后是一个 AWS **Auto Scaling Group(ASG)**，设个 min/desired/max 让它自动增减。

```
集群 Cluster        ≈ 机房
  └─ 节点组 NodeGroup ≈ 一批同规格机器(背后是 ASG)
       └─ 节点 Node    ≈ 单台 EC2
            └─ Pod      ≈ 机器上跑的一个应用实例
```

看节点 / 节点组的命令（Windows/Git Bash 记得加 `MSYS_NO_PATHCONV=1`）：

```bash
kubectl get nodes -L workload            # 看节点 + workload 标签那一列
aws eks list-nodegroups --cluster-name EKSmetaxsire --region us-west-1
aws eks describe-nodegroup --cluster-name EKSmetaxsire \
  --nodegroup-name metaxsire-ng-nonprod --region us-west-1
```

metaxsire 集群实测有 2 个节点组，**规格/计费/标签/版本都不一样**——这本身就是个坑（见第五节）：

| 节点组 | 机型 | 计费 | 伸缩(min/desired/max) | k8s 版本 | 标签 |
| --- | --- | --- | --- | --- | --- |
| `metaxsire-ng-nonprod` | t3a.large | **SPOT**(竞价,省钱易回收) | 1/2/3 | 1.34 | `workload=nonprod` |
| `metaxsire-ng-preprod` | m5.xlarge | ON_DEMAND(稳定) | 1/1/3 | 1.31 | `environment=preprod`,`role=worker` |

> `describe-nodegroup` 里 `alpha.eksctl.io/*` 前缀的标签是 **eksctl 建组时自动打的元数据**，一看就知道这个组当初是 eksctl 建的。

---

## 二、调度隔离：nodeSelector + taint/toleration 三件套

「让非生产 Pod 只落到 Spot 节点、且别的 Pod 别乱进这台 Spot 节点」——这是**双向**约束，要两个机制配合：

| 机制 | 方向 | 作用 |
| --- | --- | --- |
| **节点标签 + `nodeSelector`** | Pod → 挑节点 | Pod 声明「我只去带 `workload=nonprod` 标签的节点」 |
| **污点 `taint` + `toleration`** | 节点 → 拒 Pod | 节点声明「没有对应容忍的 Pod 一律不准调度进来」 |

social 的 staging overlay 里两者一起出现（`infra/k8s/social/overlays/staging/kustomization.yaml`）：

```yaml
spec:
  template:
    spec:
      nodeSelector:            # 我只去 workload=nonprod 的节点
        workload: nonprod
      tolerations:             # 且我容忍它身上的 workload=nonprod:NoSchedule 污点
        - key: workload
          operator: Equal
          value: nonprod
          effect: NoSchedule
```

**只有 nodeSelector 不够**：Spot 节点带了 `workload=nonprod:NoSchedule` 污点，不加 toleration 的 Pod 就算 nodeSelector 匹配也进不去；反过来只有 toleration 没有 nodeSelector，Pod 可能被调度到别的节点。两者是「必须去 + 允许进」的组合。理论详见 [调度与资源管理](./调度与资源管理.md)。

验证节点标签是否真的存在（不存在 → Pod 永远 `Pending`）：

```bash
kubectl get nodes -l workload=nonprod       # 按标签过滤
kubectl describe node <name> | grep -A5 -iE "labels|taints"
```

---

## 三、组织方式：Kustomize base/overlay 分层

上面那段 `nodeSelector` patch 不是写死在 Deployment 里的，而是 **Kustomize overlay 在部署时打进去的**。social 目录是标准的 base+overlay 结构：

```
infra/k8s/social/
├── base/                    ← 三环境共用的骨架
│   ├── kustomization.yaml   ← 「装配清单」:声明把下面三件套拼一起
│   ├── deployment.yaml      ← 跑什么/几个副本/配置/探针/资源
│   ├── service.yaml         ← 集群内访问入口
│   └── serviceaccount.yaml  ← Pod 身份
└── overlays/                ← 每个环境只写「跟 base 的差异」
    ├── test/  staging/  prod/
```

**base/kustomization.yaml 本身不定义资源**，只是个目录索引（类比 Maven 的 `<modules>` 聚合入口）：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - serviceaccount.yaml
  - deployment.yaml
  - service.yaml
```

overlay 做四件事，把通用骨架「特化」到某个环境（`overlays/staging/kustomization.yaml`）：

```yaml
namespace: metaxsire-staging       # ① 塞命名空间
resources:
  - ../../base                     # ② 引用 base 那三件套
  - configmap.yaml                 #    + 本环境专属 configmap
images:
  - name: social-service           # ③ 把占位镜像换成 ECR 真实地址
    newName: 590183963422.dkr.ecr.us-west-1.amazonaws.com/metaxsire/social-service
    newTag: latest                 #    (部署脚本再 set image 钉具体 sha)
patches:                           # ④ 给 base 的 Deployment 打 nodeSelector+toleration
  - target: { kind: Deployment }
    patch: |- ...
```

**思路**：公共部分只写一遍放 base，环境差异（命名空间/镜像/调度约束）用 overlay 叠加，避免三份几乎一样的 YAML 各维护一套。渲染：`kubectl apply -k overlays/staging` 或 `kustomize build overlays/staging`。这套「dev 一份 base，多环境派生」的玩法和 [EKS Grafana 多环境 Dashboard](./EKS-Grafana多环境Dashboard落地实战.md) 里 dashboard 从 dev 确定性派生是同一种工程思想。

#### `kubectl apply -f` vs `-k`：应用「死文件」还是「活目录」

两种部署方式对应两种输入来源：

| | `apply -f`（`--filename`） | `apply -k`（`--kustomize`） |
| --- | --- | --- |
| 参数指向 | 现成的 **YAML 文件 / 目录 / URL** | 含 `kustomization.yaml` 的**目录** |
| 行为 | **直接**把 YAML 发给 apiserver（所见即所得） | **先本地 Kustomize 渲染**（合 base+overlay+打 patch）再发 |
| 内容来源 | 你写好的最终清单 | 动态拼出来的清单（文件里看不到） |
| 适用 | 单文件平铺（一个 `.yaml` 用 `---` 拼多资源） | base/overlay 分层 |

```
-f:  写好的 YAML ─────────────────────────► apiserver（所见即所得）
-k:  kustomization.yaml ─[本地渲染]─► 最终 YAML ─► apiserver（算出来的）
```

**`-k` 本质 = 先跑 `kustomize build` 生成 YAML，再 `-f` 应用**，是 `-f` 的带预处理增强版。两个要点：① `-k` 是 kubectl 1.14+ 内置的，不必单装 `kustomize` CLI；② 上线前务必 `kubectl kustomize <目录>`（或 `apply -k --dry-run=client -o yaml`）**先预览渲染结果**，防 patch 打歪。对照另一个项目：`metaxsire-cloud/cms` 单文件用 `kubectl apply -f cms-deploy.yaml`，social 的 overlay 用 `kubectl apply -k overlays/staging`——各自匹配自己的组织方式。

---

## 四、workload 本体 + 网络出口

### Deployment（`base/deployment.yaml`）——声明「怎么跑」

关键字段速记：

| 字段 | 含义 |
| --- | --- |
| `replicas: 1` | 维持 1 个 Pod 副本(base 默认,prod overlay 可调大) |
| `selector.matchLabels` ↔ `template.labels` | 靠标签认领「哪些 Pod 是我的」,两边必须对上 |
| `image: social-service` | **占位符**,被 overlay 的 `images:` 换成 ECR+sha |
| `envFrom: [configMapRef, secretRef]` | 把 ConfigMap/Secret 整批灌成环境变量 |
| `readinessProbe` /health | 探过了才把流量转进来(不过不重启) |
| `livenessProbe` /health | 探不过就**重启容器** |
| `requests: {cpu:50m,mem:128Mi}` | 调度按它找节点(至少保证) |
| `limits: {cpu:500m,mem:512Mi}` | 运行时硬上限,超内存 OOMKilled |

`social-secrets` 不入 git，部署时从 `.secrets` 文件现建（EKS secrets 命令式手建、不进 git，是 metaxsire 的既定做法）。Probe 三种区别详见 [Pod 与生命周期](./Pod与生命周期.md)。

#### 一个高频细节：`selector.matchLabels` 与 `template.labels` 为什么写两遍

Deployment 里同一个 `app.kubernetes.io/name: social-service` 出现两次，长得一样但**角色相反**：

| 位置 | 角色 | 类比 |
| --- | --- | --- |
| `spec.selector.matchLabels` | **查询条件**：认领「哪些 Pod 归我管」 | SQL 的 `WHERE label='xxx'` |
| `spec.template.metadata.labels` | **盖章**：造出的 Pod 打上这些标签 | 给新 Pod 贴身份标签 |

因为 **Deployment 不直接记住自己建了哪些 Pod，而是靠标签动态认领**：`template` 给 Pod 盖章 → `selector` 拿同样的标签去集群里搜 → 搜到的就认作自己的副本，数不够就再造。所以两者**必须对得上**（对不上 k8s 直接拒绝该配置）。两条铁律：

- **`selector` 创建后不可变**（immutable）——它是身份契约，改了会产生孤儿 Pod；
- **`template.labels` 必须是 `selector` 的超集**——Pod 至少带 selector 要求的标签，可以再多打别的。

而 `service.yaml` 的 `selector`（下一段）又**复用同一个标签**去收 Pod 当转发后端。于是同一标签被三方共用，Pod 标签是「真相源」：

```
        template.labels 给 Pod 盖章 (真相源)
              ↓ 带此标签的 Pod
     ┌────────┴────────┐
Deployment.selector   Service.selector
认领它当副本          收它当转发后端
```

这就是 k8s **「一切靠标签松耦合」** 的核心设计——组件间不靠硬引用，全靠标签选择器对号入座（`nodeSelector` 选节点、Deployment/Service selector 选 Pod，都是同一套思想）。

### Service（`base/service.yaml`）——声明「怎么被访问」

```yaml
kind: Service
spec:
  type: ClusterIP                  # 只在集群内网可达
  selector:
    app.kubernetes.io/name: social-service   # 又是标签:收编带此标签的 Pod
  ports:
    - port: 8300                   # Service 监听端口
      targetPort: http             # 转发到 Pod 的 http 端口(=容器 8300)
```

**为什么要 Service**：Pod IP 会变（重建/扩缩/滚更就换 IP），Service 提供一个**固定虚拟 IP + 固定 DNS**(`social-service.metaxsire-staging.svc.cluster.local`)，自动负载均衡到后面所有健康 Pod。`selector` 靠标签把 Pod 收进 endpoints，**且只收 readinessProbe 通过的**——这就是就绪探针的意义。`ClusterIP` 意味着它是内部服务，外部流量得经 Ingress/网关再转进来（详见 [Service 与 kube-proxy](./Service与kube-proxy.md)、[Ingress 与网关](./Ingress与网关.md)）。

---

## 五、踩坑与易错点

1. **两个节点组标签体系不统一**：nonprod 组用 `workload=nonprod`，preprod 组用 `environment=preprod`+`role=worker`。后果：`nodeSelector: workload: nonprod` 的 Pod **永远调度不到 preprod 节点**（它没这个标签 key）。想按环境统一调度，得先把标签规范对齐。
2. **只写 nodeSelector 不写 toleration**：Spot 节点带 `NoSchedule` 污点，Pod 会卡 `Pending`。反之只写 toleration 不写 nodeSelector，Pod 可能跑到别的节点。两者必须成对。
3. **节点标签不存在 → 永远 Pending**：`nodeSelector` 是硬约束，没有匹配节点不会报错，只会一直 Pending。上线前先 `kubectl get nodes -l <label>` 确认。
4. **Spot 节点会被回收**：nonprod 用 SPOT 省钱，但 AWS 缺货时会强制回收（2 分钟通知）。只适合可中断的非关键负载；关键服务用 ON_DEMAND。
5. **节点组 k8s 版本漂移**：nonprod 已 1.34、preprod 还在 1.31，差 3 个小版本已到 EKS node/控制面兼容边界。升级：`aws eks update-nodegroup-version`。
6. **image 占位名忘了被 overlay 覆盖**：base 里 `image: social-service` 只是占位，若某 overlay 漏配 `images:`，会真的去拉名叫 `social-service:latest` 的镜像 → `ImagePullBackOff`。
7. **Windows kubectl 路径被 Git Bash 改写**：`-n`、路径类参数会被 mangling，命令前统一加 `MSYS_NO_PATHCONV=1`。

---

## 六、一条主线收官

```
kubectl get nodes                → 2 台 nonprod(Spot,v1.34) + 1 台 preprod(OnDemand,v1.31)
        │ describe-nodegroup
        ▼
节点组 metaxsire-ng-nonprod       打标签 workload=nonprod + 污点 workload=nonprod:NoSchedule
        │
        │  overlays/staging/kustomization.yaml 打 patch
        ▼
nodeSelector:workload=nonprod + toleration   → Pod 只落 nonprod 节点
        │
        │  Kustomize base/overlay 渲染
        ▼
Deployment(base) 换镜像/塞 namespace/注 config+secret/带探针/要资源
        │
        ▼
Pod 调度到 nonprod 那 2 台 Spot 节点
        │  Service(ClusterIP) selector 按标签收编健康 Pod
        ▼
别的服务用固定 DNS social-service:8300 访问 ← Ingress/网关 ← 外部用户
```

**六层闭环**：机器(Node) → 成组管理(NodeGroup) → 调度约束(nodeSelector+taint) → 组织复用(Kustomize) → 工作负载(Deployment) → 访问出口(Service)。这就是一个服务在 EKS 上「从机器到调度到运行到被访问」的完整链路。

---

## 七、相关笔记

- [调度与资源管理](./调度与资源管理.md) — nodeSelector / 亲和 / 污点容忍 / QoS / requests-limits 的理论全解
- [工作负载](./工作负载.md) — Deployment / StatefulSet / DaemonSet 等 6 种 Workload 取舍
- [Service 与 kube-proxy](./Service与kube-proxy.md) — ClusterIP 底层、Endpoint、iptables/IPVS
- [Pod 与生命周期](./Pod与生命周期.md) — Liveness/Readiness/Startup 三种 Probe
- [ConfigMap 与 Secret](./ConfigMap与Secret.md) — envFrom 注入、生产级密钥管理
- [EKS 可观测性 LGTM 栈部署实战](./EKS可观测性LGTM栈部署实战.md) — 同一个 EKSmetaxsire 集群的可观测栈
- [EKS Grafana 多环境 Dashboard 落地实战](./EKS-Grafana多环境Dashboard落地实战.md) — 同样是 base→多环境派生的工程思想
