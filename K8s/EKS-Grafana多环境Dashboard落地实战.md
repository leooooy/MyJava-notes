# EKS Grafana 多环境 Dashboard 落地实战

> 在 [EKS 可观测性 LGTM 栈](./EKS可观测性LGTM栈部署实战.md) 已部署（Prometheus/Loki/Tempo/Grafana）的基础上，把本地 dev 的 4 个 Grafana dashboard 搬到 EKS，并让**同一套栈服务 test/staging/prod 三环境**、按 `namespace` 一键切换。看似只是"导几个盘"，实际踩了 5 个真实的坑——**变量正则捕获组吞值 / RWO 卷升级死锁 / 持久化盖住新 uid / sidecar 文件夹全局污染 / Windows 路径**。本篇是那篇部署实战的续集。

案例来自 metaxsire：EKS 集群 `EKSmetaxsire`(us-west-1)，`observability` 命名空间跑一套 kube-prometheus-stack，`metaxsire-{test,staging,prod}` 三个命名空间跑同名业务服务。

---

## 一、核心难点：dev 单环境 vs EKS 三环境同栈

| 维度 | 本地 dev | EKS |
| --- | --- | --- |
| 指标来源 | `prometheus.yml` 静态 scrape，每服务一个 job，`job=服务名` | PodMonitor 抓取，跨三命名空间 |
| 环境维度 | 无（单环境） | `namespace=metaxsire-{test,staging,prod}` |
| dashboard 过滤 | 靠 `job=服务名` | 需 `job` + `namespace` 双维度 |

所以搬盘不是复制 JSON，而是要做两件事：**(1) 让 EKS 指标的标签模型对齐 dev（补 `job`）；(2) 给每个盘注入 `namespace` 环境变量并改写查询**。dev 的盘一个字不改（dev 无 namespace 标签，加了反而坏），EKS 版由脚本从 dev 版**确定性派生**。

---

## 二、标签对齐：PodMonitor 必须补 `job` relabel

PodMonitor 若不设 `jobLabel`，prometheus-operator 默认把**所有被抓 pod** 的 `job` 标签统一写成 `<podmonitor命名空间>/<podmonitor名>`——本例即 `observability/metaxsire-services`。三环境所有服务挤成一个 job，dev 盘里 `job=~"$job"`、`job="social-service"` 全部失效。

补一条 relabel，把 `job` 设成 pod 的 `app.kubernetes.io/name`（=服务名）：

```yaml
# podmonitors/metaxsire-services.yaml
relabelings:
  - sourceLabels: [__meta_kubernetes_namespace]
    targetLabel: namespace
  - sourceLabels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]  # 新增
    targetLabel: job
```

效果：`job=social-service` / `user-service`…，`namespace=metaxsire-test/...`。dev 的查询逻辑几乎原样可用，只需再叠一层 namespace 过滤。

> 副作用：改 `job` 会改变量标签，若已有基于旧 job 的告警要一起改（本例无业务告警，风险低）。

---

## 三、dashboard 派生：一个确定性脚本，别手改 2000 行 JSON

用一个只依赖标准库的 Python 脚本，从 dev JSON 生成 EKS 版，做三件事：

1. **注入 `namespace` 模板变量**（`label_values(up, namespace)` + 正则白名单）；
2. **所有选择器叠 `namespace=~"$namespace"`**——用"在开头子串上做 replace"覆盖所有变体：

```python
replace_in_exprs(d, [
    ('{job=~"$job"',  '{namespace=~"$namespace",job=~"$job"'),   # 覆盖 {job=~"$job"} 和 {job=~"$job",status=~"5.."}
    ('{job="social-service"', '{namespace=~"$namespace",job="social-service"'),
])
```

3. **变量查询链式收窄**：`label_values(up, job)` → `label_values(up{namespace=~"$namespace"}, job)`。

好处：dev 盘一改，重跑脚本即可再生成，diff 干净、可评审。faro-rum（前端 RUM，EKS 暂无 Faro receiver）只加变量、verbatim 落盘，属预期空盘。

配一个**离线校验脚本**做 TDD 护栏——关键：**必须 `json.loads` 后遍历真实 expr 值再比对，别对磁盘 JSON 文本做裸字符串匹配**（JSON 会把内层 `"` 转义成 `\"`，裸匹配永远 FAIL）：

```python
def collect_exprs(d):          # 遍历 target expr + 模板 query（已反序列化，无转义）
    ...
# 每盘校验：不得残留未加 namespace 的裸选择器，且必须注入 namespace
```

---

## 四、下发：sidecar + ConfigMap，用注解分文件夹

kube-prometheus-stack 的 Grafana 自带 dashboard sidecar：监听带 `grafana_dashboard=1` 标签的 ConfigMap，热加载其中 JSON。下发脚本把每个 JSON 打标签做成 ConfigMap：

```bash
kubectl create configmap grafana-dash-overview --from-file=overview.json=... --dry-run=client -o yaml \
| kubectl label  --local -f - grafana_dashboard=1        --dry-run=client -o yaml \
| kubectl annotate --local -f - grafana_folder=metaXsire --dry-run=client -o yaml \
| kubectl apply -f -
```

改盘只需重跑这步，秒级热加载，**不动 helm**。

---

## 五、踩坑合集（5 个真实坑）

### 坑①：namespace 变量正则用了**捕获组**，值被吞→全盘 No data ⭐最隐蔽

变量正则本想做白名单：`/^metaxsire-(test|staging|prod)$/`。结果**所有面板 No data**，顶部环境 chip 显示的是 `test` 而不是 `metaxsire-test`。

根因：**Grafana 模板变量正则里只要有捕获组 `(...)`，就把变量值取成捕获到的那部分**。于是 `$namespace = "test"`，查询变成 `up{namespace=~"test"}`——真实命名空间是 `metaxsire-test`，匹配不到。

```promql
sum(up{namespace=~"test"})            # -> No data（被捕获组吞成 test）
sum(up{namespace=~"metaxsire-test"})  # -> 4（正确）
```

修复：改**非捕获组** `(?:...)`，只过滤、不改值：

```diff
- "regex": "/^metaxsire-(test|staging|prod)$/"
+ "regex": "/^metaxsire-(?:test|staging|prod)$/"
```

> 记忆点：**Grafana 变量正则里，捕获组 = 提取值，非捕获组 = 纯过滤**。想过滤别用 `(...)`。

### 坑②：Grafana 持久化用 gp2(RWO) 卷，升级时 **Multi-Attach 死锁**

`helm upgrade` 后新 Grafana pod 卡在 `Init:0/1` 十几分钟。`describe pod` 事件：

```
Warning FailedAttachVolume  Multi-Attach error for volume "pvc-..." Volume is already used by pod(s) kube-prometheus-stack-grafana-<old>
```

根因：gp2 是 **RWO（ReadWriteOnce）单挂载**，Deployment 默认 `RollingUpdate` 会让新 pod 先起、旧 pod 后终止，两者同时抢一个 EBS 卷 → 死锁。

修复：Grafana 用 `Recreate` 策略（先杀旧释放卷，再起新）：

```yaml
grafana:
  deploymentStrategy:
    type: Recreate
```

恢复卡住的 release（helm 被打断会留 `pending-upgrade`）：`helm rollback <release> <上一稳定rev>` 清锁 → 带 Recreate 重新 `helm upgrade`。

> 通则：**任何挂 RWO 卷的 Deployment 都要 `Recreate`**，否则升级必死锁。StatefulSet 无此问题（它本就是逐个替换）。

### 坑③：Loki 数据源 `uid: loki` 写了却不生效——**旧 PVC 盖住了新 uid**

dashboard 引用 `uid: loki`，values 里也写了 `uid: loki`，但运行时 Loki 数据源 uid 仍是随机的 `P8E80F9...` → Loki 面板断链。

根因：这是 [LGTM 篇「坑⑧：数据源 uid 自动生成」](./EKS可观测性LGTM栈部署实战.md) 的**升级版**——首次部署时 Loki 没写 uid，Grafana 生成随机 uid 存进**持久化 PVC**里的 `grafana.db`；后来 values 补了 `uid: loki`，但 **provisioning 更新已存在的数据源时不会改它的 uid**，且 `name=Loki` 唯一约束又挡住新 uid 的插入。

修复（一次性）：Grafana 的 dashboard/datasource/admin **全是 provisioning 来的、PVC 无用户数据**，直接重置 PVC 让 DB 干净重建：

```bash
kubectl scale deploy <grafana> --replicas=0        # 释放卷
kubectl delete pvc <grafana-pvc>
helm upgrade ...                                    # 重建 PVC + 拉起，DB 空 → provisioning 建出 uid=loki
```

> 教训：**被引用的数据源，首次部署就要写死 uid**。一旦 Grafana 带持久化跑过、生成了随机 uid，后补 uid 不生效，只能重置 DB。对纯 provisioning 的 Grafana，持久化价值不大、反而添乱。

### 坑④：sidecar 的 `provider.folder` 是**全局**的，把内置盘也拽进来了

想让我们的 4 个盘进 `metaXsire` 文件夹，于是设了 `provider.folder: metaXsire`。结果 kps 自带的 ~30 个盘（Alertmanager / Node Exporter / Kubernetes/*）**全被塞进** `metaXsire`——因为该配置对 sidecar 加载的**所有** ConfigMap 生效。

修复：改用**按注解分文件夹**——只有我们的盘带 `grafana_folder` 注解：

```yaml
sidecar:
  dashboards:
    folderAnnotation: grafana_folder      # 读每个 CM 的此注解决定文件夹
    provider:
      foldersFromFilesStructure: true     # 从(注解生成的)目录结构建文件夹
```

配合坑④对应的下发脚本 `kubectl annotate ... grafana_folder=metaXsire`：我们的盘 → `metaXsire`，内置盘（无注解）→ 默认 `General`。

### 坑⑤：Windows Git Bash 下 `kubectl.exe` 读不了 MSYS 路径

EKS 的 context 是带冒号的 ARN，Git Bash 里必须 `MSYS_NO_PATHCONV=1` 防止路径 mangle。但这一来 `--from-file=xxx=/d/mxs/.../overview.json` 的 MSYS 路径又没被转成 Windows 原生路径，`kubectl.exe`（Windows 二进制）报 `The system cannot find the path specified`。

修复：对文件路径显式 `cygpath -w` 转原生路径（有 cygpath 才转，Linux 不受影响）：

```bash
src="$f"
command -v cygpath >/dev/null 2>&1 && src="$(cygpath -w "$f")"
kubectl ... --from-file="$base=$src" ...
```

> ARN context 要 `MSYS_NO_PATHCONV=1`、文件路径要原生格式——**同一条命令里两个需求冲突，用 cygpath 只转路径那一段**。

---

## 六、复盘要点

1. **多环境同栈的钥匙是一个标签**：`namespace` 贯穿指标(PodMonitor relabel)/日志(Alloy)/链路(otel resource)。盘里加一个 `namespace` 变量 + 查询叠 `namespace=~"$namespace"` 就能一键切环境。
2. **Grafana 变量正则：捕获组提取值、非捕获组纯过滤**。想白名单过滤用 `(?:...)`，否则值被吞、查询全空——最隐蔽的坑。
3. **RWO 卷 + Deployment = 必须 Recreate**。gp2/EBS 单挂载，RollingUpdate 升级必 Multi-Attach 死锁。
4. **被引用的数据源首次就写死 uid**。带持久化的 Grafana 一旦生成随机 uid，后补不生效，只能重置 DB；纯 provisioning 的 Grafana 持久化收益低。
5. **sidecar 文件夹要按注解分**（`folderAnnotation`），`provider.folder` 是全局的会污染内置盘。
6. **派生优于手改**：大 JSON 用确定性脚本从源生成，可重跑、可评审；校验脚本要解析 JSON 比对真实值，别对转义文本裸匹配。
7. **Windows kubectl 双坑**：ARN 要 `MSYS_NO_PATHCONV=1`，文件路径要 `cygpath -w`。

---

**关联**：[EKS 可观测性 LGTM 栈部署实战](./EKS可观测性LGTM栈部署实战.md)（本篇前传）· [存储与持久化](./存储与持久化.md)（PV/PVC/RWO）· [发布与弹性伸缩](./发布与弹性伸缩.md)（RollingUpdate vs Recreate）· [ConfigMap 与 Secret](./ConfigMap与Secret.md)（sidecar 挂载）· 运维事故记录
