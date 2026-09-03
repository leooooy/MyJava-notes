# ConfigMap 与 Secret

> **ConfigMap 装明文配置、Secret 装敏感数据**（base64 编码 ≠ 加密！），都是 K8s 内置的 KV 对象，靠 **env 注入**（不可变 / 改完要重启 Pod）或 **volume 挂载**（自动同步 / 约 1min 延迟）注入到 Pod。Secret 真正的加密要靠 **etcd 加密 + KMS / Sealed Secret / Vault**。
>
> 本篇要解决面试官四个连环追问：
>
> ① **env vs volume 注入怎么选？**——不可变 vs 自动同步
> ② **改完 ConfigMap 会自动生效吗？**——env 不会，volume 会但有延迟
> ③ **Secret 真的加密吗？**——base64 不是加密，etcd 默认明文存
> ④ **K8s ConfigMap 跟 Nacos 配置中心怎么选？**——平台原生 vs 应用层
>
> 跟其它模块的关系：
> - 前置：[存储与持久化](./存储与持久化.md)（volume 挂载机制）
> - 联动：[Microservice/Nacos](../Microservice/Nacos.md)（Nacos Config 选型对比）
> - 配套：[Pod 与生命周期](./Pod与生命周期.md)（Pod 配置注入）

---

## 一、为什么需要 ConfigMap / Secret？

12-Factor 应用准则之一：**配置外部化** ——配置不能写死在镜像里。原因：

```
1. 同一镜像跑多环境（dev/test/prod）→ 配置不同
   写死在镜像 → 每环境都打一份镜像（违反"build once, run anywhere"）

2. 改配置不应重新打镜像
   写死 → 改一行配置就 docker build → 推仓 → 拉镜像 → 重启
   外部化 → 改 ConfigMap → 重启 Pod 即可（甚至不重启）

3. 密钥不能进镜像
   镜像可能被分享 / 扫描 / 公开
   密钥写死 → docker history 能看到
```

K8s 提供两个内置对象解决：
- **ConfigMap**：明文配置（数据库 URL / 日志级别 / Feature Flag）
- **Secret**：敏感数据（密码 / API Key / TLS 证书）

---

## 二、ConfigMap 详解

### 2.1 创建方式

```bash
# 方式 1：从字面值
kubectl create configmap app-config \
  --from-literal=LOG_LEVEL=INFO \
  --from-literal=DB_HOST=mysql.default

# 方式 2：从文件
kubectl create configmap nginx-config --from-file=nginx.conf

# 方式 3：从目录（每个文件一个 KV）
kubectl create configmap configs --from-file=./conf-dir/

# 方式 4：从 env 文件
kubectl create configmap envs --from-env-file=app.env
```

YAML 形式：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  LOG_LEVEL: "INFO"
  DB_HOST: "mysql.default"
  application.yml: |               # 多行内容用 |
    server:
      port: 8080
    logging:
      level:
        root: INFO
binaryData:                        # 二进制数据用 binaryData（base64）
  cert.bin: <base64>
```

**ConfigMap 大小限制：1MB**（etcd 单对象限制）。超过要拆分或挂 PVC。

### 2.2 三种注入方式

#### 方式 A：env（环境变量）

```yaml
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: app
    image: myapp
    env:
    - name: LOG_LEVEL
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: LOG_LEVEL
    # 或一次性注入所有 key
    envFrom:
    - configMapRef:
        name: app-config
```

**特点**：
- 进程启动时读 → **改 ConfigMap 不影响已运行 Pod**（必须重启 Pod 才生效）
- 用法接近系统环境变量（`System.getenv("LOG_LEVEL")`）

#### 方式 B：volume mount

```yaml
spec:
  containers:
  - name: app
    volumeMounts:
    - name: config
      mountPath: /etc/app
      readOnly: true
  volumes:
  - name: config
    configMap:
      name: app-config
      items:                      # 可选，挑选部分 key
      - key: application.yml
        path: application.yml
```

**特点**：
- 容器内 `/etc/app/application.yml` 是 ConfigMap 内容
- **改 ConfigMap 自动同步到 Pod**——但有延迟（kubelet 周期同步，约 1min）
- 应用要监听文件变化（Spring Boot `@ConfigurationProperties` + Actuator refresh、或 Viper 等库）

#### 方式 C：subPath 挂载（坑！）

```yaml
volumeMounts:
- name: config
  mountPath: /etc/nginx/nginx.conf
  subPath: nginx.conf             # 只挂某一个 key 到指定文件
```

**特点**：
- 适合**只挂某个文件**到容器某路径（不覆盖整个目录）
- **副作用：subPath 不会自动同步**——ConfigMap 改了 Pod 内不变（必须重启 Pod）

---

## 三、Secret 详解

### 3.1 创建方式

```bash
# 通用 Secret
kubectl create secret generic db-secret \
  --from-literal=username=admin \
  --from-literal=password='S!B\\*d$zDsb='

# TLS 证书
kubectl create secret tls my-tls \
  --cert=tls.crt --key=tls.key

# Docker 拉私有仓凭证
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=admin --docker-password=xxx
```

YAML（注意 base64）：

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
type: Opaque
data:
  username: YWRtaW4=                  # base64("admin")
  password: UyFCXFwqZCRTQiBhVA==      # base64
stringData:                            # 不要 base64，K8s 自动转
  api_key: "raw-string-here"
```

### 3.2 Secret 类型

| 类型 | 用途 |
| --- | --- |
| **Opaque**（默认） | 通用密钥 |
| **kubernetes.io/dockerconfigjson** | 拉镜像凭证（Pod 配 `imagePullSecrets`） |
| **kubernetes.io/tls** | TLS 证书 + 私钥（Ingress 用） |
| **kubernetes.io/service-account-token** | ServiceAccount 自动生成的 token（K8s 1.24+ 不再自动创） |
| **bootstrap.kubernetes.io/token** | 集群 bootstrap token |

### 3.3 注入方式（与 ConfigMap 一致）

env / volume / subPath 都和 ConfigMap 一样。

```yaml
env:
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: db-secret
      key: password

volumes:
- name: secret
  secret:
    secretName: db-secret
    defaultMode: 0400              # 文件权限（默认 0644 → 改成 0400 限制读）
```

---

## 四、Secret 不是加密！怎么真正加密？

### 4.1 base64 ≠ 加密

```bash
echo -n "S3cret_P@ss" | base64
# UzNjcmV0X1BAc3M=

echo "UzNjcmV0X1BAc3M=" | base64 -d
# S3cret_P@ss      ← 谁都能解
```

**Secret 仅做了 base64 编码**——是为了支持二进制内容，**不是为了加密**。任何能读 etcd 或调 apiserver get secret 的人都能拿明文。

### 4.2 etcd 默认明文存

```bash
# 直接读 etcd
ETCDCTL_API=3 etcdctl get /registry/secrets/default/db-secret
# 看到的就是明文（base64 解一下）
```

### 4.3 真正的加密方案

#### 方案 A：etcd 加密（apiserver 加密 Secret 后再存 etcd）

```yaml
# /etc/kubernetes/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - aescbc:                          # AES-CBC 加密
      keys:
      - name: key1
        secret: <32-byte-base64-key>
  - identity: {}                     # 兜底（向后兼容）
```

启动 apiserver 加 `--encryption-provider-config=/etc/kubernetes/encryption-config.yaml`。**生产建议接 KMS**：

```yaml
- kms:
    name: aws-kms
    endpoint: unix:///var/run/aws-kms.sock
    cachesize: 100
```

加密后 etcd 里看到的是密文，apiserver 加密机内存里有 KMS 拉来的 KEK——更安全。

#### 方案 B：External Secrets Operator

把外部 Secret 管理服务（HashiCorp Vault / AWS Secrets Manager / Azure Key Vault）同步到 K8s Secret。**优点**：密钥实际存外部专业系统；K8s 只是镜像。

#### 方案 C：Sealed Secret

让你**把加密后的密钥提交到 Git**——SealedSecret Controller 在集群里解密成普通 Secret。**优点**：GitOps 流程友好（可以提交配置到仓库不泄露）；缺点：还是要管理 SealedSecret 私钥。

#### 方案 D：CSI Secret Driver

直接用 Vault / AWS Secrets Manager 等 CSI Driver——Pod 启动时 CSI 从外部拉密钥挂载到 tmpfs（**不进 etcd 也不进 K8s Secret**）。最安全。

---

## 五、热更新机制详解

### 5.1 env 注入：不更新

```
Pod 启动 → kubelet 把 env 变量传给容器进程
进程读 env 后存内存
ConfigMap 改了 → kubelet 不会主动通知容器进程
进程的 env 还是老值
```

**唯一办法**：删 Pod 重启（Deployment rollout）。

### 5.2 volume mount：自动同步（有延迟）

```
ConfigMap 改了 → apiserver 写 etcd
kubelet watch 到变化（每个节点的 kubelet）
kubelet 周期同步（默认 60s）→ 把新内容写到 Pod 挂载目录
进程要监听文件变化（如 Spring Boot Actuator refresh）
```

**延迟**：默认最大 60s（kubelet `--sync-frequency`）；还要加 60s 缓存（kubelet ConfigMap watch 缓存）→ **最坏 2 分钟**。

**应用层配合**：
- Spring Boot：`spring.config.import=configtree:/etc/app/` + `@RefreshScope`
- Nginx：`SIGHUP` 触发 reload
- 自研：`fsnotify`（Go） / `WatchService`（Java）监听文件

### 5.3 subPath 挂载：不更新（坑！）

subPath 是把单个文件挂到容器路径——**ConfigMap 改了 subPath 内的不会自动同步**。

**修复**：① 不用 subPath（挂整个 ConfigMap 到目录）；② 用 projected volume；③ 接受限制 + 必须重启 Pod。

---

## 六、ConfigMap vs Nacos / Apollo 配置中心

| 维度 | **K8s ConfigMap** | **Nacos / Apollo** |
| --- | --- | --- |
| **粒度** | 命名空间级（namespace 隔离） | 应用 / 环境 / 集群多维度 |
| **热更新** | volume 挂载约 1 分钟延迟 | 长轮询，**秒级** |
| **变更追踪** | etcd revision，但 UI 弱 | **完整变更历史 + 回滚 UI** |
| **灰度发布** | ❌ 没有 | **支持**（按 IP / 标签灰度配置） |
| **配置类型** | KV + 文本（任意） | 结构化（YAML / Properties / JSON） |
| **跨集群** | ❌ 单 K8s 集群内 | **跨集群共享**（多集群 / 多机房） |
| **客户端 SDK** | ❌（要应用层做文件监听） | **官方 SDK + 监听回调** |
| **依赖** | K8s 自带（etcd） | 独立部署 Nacos 集群 |
| **典型用途** | K8s 平台配置（数据库连接串等） | **应用业务配置 + 动态开关** |

**生产架构常见组合**：
- **平台层用 ConfigMap**：DB URL / Redis 地址 / Pod 资源限制（启动时一次性 env 注入）
- **业务层用 Nacos / Apollo**：业务规则 / 限流阈值 / 功能开关（要秒级生效 + 灰度）

详见 [Microservice/Nacos](../Microservice/Nacos.md)。

---

## 七、生产踩坑

### 坑 1：env 注入改完没重启 Pod 不生效

**现象**：改了 ConfigMap，业务说没生效。

**根因**：env 注入是 Pod 启动时读取，运行时不感知 ConfigMap 变化。

**修复**：
- 改完 ConfigMap 后 `kubectl rollout restart deployment/myapp`
- 装 [stakater/Reloader](https://github.com/stakater/Reloader) Operator——监控 ConfigMap/Secret 变化自动重启关联 Deployment（生产标配）

### 坑 2：base64 当加密用泄露密钥

**现象**：把 `kubectl get secret -o yaml` 截图发到群里——以为是密文，实际 base64 解就是明文密码。

**根因**：误把 base64 当加密。

**修复**：
- 团队培训 + 文档明示
- 装 etcd 加密 + KMS（apiserver 解密前明文不进网络）
- 用 External Secrets / Vault 把密钥放外部
- 严格 RBAC：限制谁能 get secret

### 坑 3：ConfigMap 大小超 1MB

**现象**：apply 大配置（如完整 nginx.conf 包含模板）报 `Request entity too large`。

**根因**：ConfigMap 单对象 1MB 上限（etcd 限制）。

**修复**：
- 拆分多个 ConfigMap
- 大文件挂 PVC
- ConfigMap 只放配置 KV，模板内容塞镜像

### 坑 4：subPath 挂载更新失效

**现象**：用 subPath 挂 nginx.conf，改 ConfigMap 后 Pod 内文件没变。

**根因**：subPath 不支持自动同步（设计如此）。

**修复**：
- 挂整个 ConfigMap 到目录（不用 subPath）+ Nginx 命令行 `-c` 指定文件
- 用 projected volume
- 配 Reloader 重启 Pod

### 坑 5：Secret 文件权限 0644 → 同 Pod 别的容器能读

**现象**：业务容器用 1000 用户，sidecar 容器用 root。Secret volume 默认 0644 → 业务容器内 1000 也能读 sidecar 不该看的密钥。

**根因**：Secret volume 默认权限 0644（所有用户可读）。

**修复**：

```yaml
volumes:
- name: secret
  secret:
    secretName: db-secret
    defaultMode: 0400              # owner 只读
```

并配 `securityContext.fsGroup: 1000` 让 1000 是 owner。

### 坑 6：ConfigMap 改 sub-key 影响整个对象 watch

**现象**：ConfigMap 有 100 个 key，改了 1 个，所有 watch 这个 ConfigMap 的 Pod 都会触发 reload（即使它只用其中一个 key）。

**根因**：ConfigMap 是单对象，watch 粒度是整个对象。

**修复**：
- 拆成多个细粒度 ConfigMap（按订阅者拆）
- 或用 Operator 模式管理（CRD 粒度更细）

---

## 八、面试高频追问

**Q1：ConfigMap 和 Secret 区别？**

A：**目的不同**：ConfigMap 装明文配置，Secret 装敏感数据。**实现几乎一样**：① 都是 K8s 内置 KV 对象；② 注入方式相同（env / volume / subPath）；③ 都从 etcd 存。**关键差异**：① Secret 自动 base64 编码（**不是加密**！只是为了支持二进制）；② Secret 在 kubectl 输出里默认隐藏；③ Secret 文件 volume 用 tmpfs（不写磁盘）；④ apiserver 可以配置加密 Secret 存 etcd（ConfigMap 不加密）。

**Q2：ConfigMap 改完会自动生效吗？**

A：**取决于注入方式**：① **env 注入**：不会。env 是进程启动时读取，运行时不感知，必须重启 Pod；② **volume 挂载**：会，但有延迟——kubelet 周期同步（默认 60s）+ Watch 缓存延迟（最坏 2 分钟）；③ **subPath 挂载**：不会（设计如此，是 subPath 的特性 / 坑）。**生产做法**：env 注入用 [Reloader](https://github.com/stakater/Reloader) Operator 自动重启；volume 注入应用要监听文件变化（Spring Boot @RefreshScope / fsnotify）。

**Q3：Secret 真的加密吗？**

A：**不加密——只是 base64 编码**。`echo "UzNjcmV0" | base64 -d` 谁都能解出明文。etcd 默认也是明文存——能 SSH 到 etcd 节点 / 能调 apiserver get secret 的人都能拿明文。**真正的加密 4 招**：① **etcd 加密 + KMS**——apiserver 加密 Secret 后存 etcd（`--encryption-provider-config`）；② **External Secrets Operator**——密钥实际放 Vault / AWS Secrets Manager，K8s 只同步过来；③ **Sealed Secret**——加密后的 Secret 可以提交 Git；④ **CSI Secret Driver**——Pod 启动时直接从外部拉到 tmpfs，**根本不进 K8s**。

**Q4：env 注入和 volume 注入怎么选？**

A：**env**：① 写法简单；② 应用兼容好（任何应用都认 env）；③ **不可热更新**。**volume**：① 应用要读文件；② **支持热更新**（约 1min 延迟）；③ 一次注入多个文件方便（比如完整的 application.yml）。**生产建议**：① **数据库地址 / Redis 地址等启动期固定的用 env**——简单可靠；② **业务配置 / 限流阈值要热更新的用 volume**（或干脆上 Nacos）。

**Q5：K8s ConfigMap 跟 Nacos / Apollo 配置中心怎么选？**

A：**两层不同职责**：
- **K8s ConfigMap**：K8s 平台原生 KV，**namespace 隔离**，**热更新约 1min 延迟**，**没有变更历史 / 灰度 / 跨集群**。
- **Nacos / Apollo**：应用层配置中心，**长轮询秒级热更新**，**完整变更历史 + UI + 灰度发布 + 跨集群**。

**生产架构**：① 启动期固定的"基础设施配置"（DB 连接串 / 日志路径）→ ConfigMap；② 业务规则 / 限流阈值 / 功能开关（要秒级生效 + 灰度）→ Nacos / Apollo。**别让 ConfigMap 干配置中心的事**。

**Q6：Secret 怎么挂得安全？**

A：**5 件事**：① **文件权限**：`defaultMode: 0400`（只 owner 读）；② **fsGroup**：让 owner 是业务 UID 而非 root；③ **tmpfs 挂载**（Secret volume 默认 tmpfs，不写磁盘）；④ **限制 RBAC**：只允许少数 ServiceAccount 读 Secret；⑤ **etcd 加密**或 **External Secrets**。**额外**：CI / 日志里**永远不要 print Secret 内容**；`kubectl get secret -o yaml` 不要截图分享。

**Q7：怎么实现 K8s Secret 的版本管理？**

A：① **Git Ops 流派用 Sealed Secret**——加密后的 SealedSecret YAML 可以提交 Git，集群里 Controller 解密成 Secret。变更走 Git 流程（PR / Review / Tag）。② **集中管理流派用 External Secrets + Vault**——Secret 都在 Vault，K8s 通过 ExternalSecret CR 同步。Vault 自带版本管理和审计。③ **不要直接把 Secret YAML（哪怕 base64）提 Git**——base64 不是加密。

**Q8：ConfigMap 大小限制是多少？超了怎么办？**

A：**1MB 上限**（etcd 单对象限制；apiserver 默认 `--max-request-bytes=1572864`）。超了 apply 报 `Request entity too large`。**修复**：① **拆分**——按用途拆成多个 ConfigMap（不要把所有配置塞一个）；② **大文件用 PVC**——CA 证书包 / 模型文件等本身不该用 ConfigMap；③ **GZip 压缩**（应用层解压）——勉强可用但不推荐。**经验**：ConfigMap 单文件超 100KB 就该警惕，几百 KB 一般是设计错了。

**Q9：Secret 拉镜像凭证怎么用？**

A：

```bash
# 创建凭证 Secret
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=admin \
  --docker-password=xxx \
  --docker-email=ops@x.com

# Pod 里引用
spec:
  imagePullSecrets:
  - name: regcred
  containers:
  - image: registry.example.com/myapp:v1
```

**或绑定到 ServiceAccount 自动用**（这个 SA 起的所有 Pod 自动有这个 imagePullSecret，不用每 Pod 写）：

```bash
kubectl patch sa default -p '{"imagePullSecrets":[{"name":"regcred"}]}'
```

**Q10：能让 ConfigMap immutable 吗？**

A：**能，K8s 1.21+ 默认开 immutable Secret/ConfigMap 特性**：

```yaml
apiVersion: v1
kind: ConfigMap
immutable: true             # 不可改
data: { ... }
```

**收益**：① **保护数据**——防误改；② **性能**——apiserver 不用 watch 不可变对象，节省 watch 流量（大集群可观）。**代价**：要改只能删了重建；不可变意味着不能滚动更新（要新 ConfigMap + 改 Deployment 引用）。**生产用法**：高频访问的 ConfigMap（每节点的 Pod 都挂）设 immutable 减负载；要灵活改的不设。

**Q11：怎么在多个命名空间共享 ConfigMap？**

A：**K8s 不支持跨命名空间共享 ConfigMap**——必须在每个 ns 里创建一份。**3 种应对**：① **手动 / GitOps 多份维护**——简单但重复；② **Kyverno / Reflector Controller**——自动把 ConfigMap 复制到指定 ns；③ **External Secrets**——共享密钥可以同步到多 ns。

**Q12：ConfigMap 改了能马上回滚吗？**

A：**K8s ConfigMap 没有内置版本历史**——改完上一版就没了（不像 Deployment 有 ReplicaSet 历史）。**生产做法**：① **GitOps**——所有 ConfigMap YAML 在 Git，回滚 = git revert + apply；② **加版本后缀**：`app-config-v1`、`app-config-v2`，Pod 引用具体版本，要回滚改引用即可（Sealed Secrets 推荐这做法）；③ **配置中心代替**——Nacos 自带变更历史 + 一键回滚 UI。

---

## 九、答题模板（60 秒话术）

> ConfigMap / Secret 都是 K8s 内置的 KV 对象——**ConfigMap 装明文配置，Secret 装敏感数据**。注入 Pod 三种方式：① **env**（启动时读，**不可热更新**）；② **volume**（挂目录，**自动同步约 1 分钟延迟**）；③ **subPath**（挂单文件，**不会同步是坑**）。
>
> **Secret 不是加密**——只是 base64 编码（解出来就是明文），etcd 默认也明文存。**真正的加密 4 招**：① etcd 加密 + KMS（`--encryption-provider-config`）；② External Secrets + Vault；③ Sealed Secret（GitOps 友好）；④ CSI Secret Driver（密钥根本不进 K8s）。
>
> **ConfigMap 限制**：① **单对象 1MB**（etcd 限制），超了拆分或挂 PVC；② **没有版本历史**，回滚靠 GitOps；③ **跨命名空间不共享**，要么多份维护要么 Reflector 同步；④ **K8s 1.21+ 支持 immutable** ——高频读的设上节省 apiserver watch 压力。
>
> **改了不生效经典坑**：① env 注入改完不重启 Pod 永远不生效——装 [Reloader](https://github.com/stakater/Reloader) 自动重启；② volume 用 subPath 不会同步——挂整个目录或用 projected；③ kubelet 同步周期默认 60s，最坏 2min 才同步到。
>
> **跟 Nacos / Apollo 怎么分**：K8s ConfigMap 干"基础设施配置"（DB URL / Redis 地址，启动期固定）；**Nacos / Apollo 干"应用业务配置"**（限流阈值 / 功能开关，要秒级热更新 + 灰度 + 变更历史）。两层职责不同，生产经常并存。
>
> **5 大生产坑**：① env 改了不重启 Pod 不生效；② base64 当加密用泄密；③ ConfigMap 超 1MB；④ subPath 不同步；⑤ Secret volume 默认权限 0644 同 Pod 容器能互读。

---

## 十、相关文档

- 前置：[存储与持久化](./存储与持久化.md) — volume 挂载机制
- 配套：[Pod 与生命周期](./Pod与生命周期.md) — Pod 配置注入
- 配套：[Ingress 与网关](./Ingress与网关.md) — Secret 装 TLS 证书
- 联动：[Microservice/Nacos](../Microservice/Nacos.md) — 应用层配置中心
