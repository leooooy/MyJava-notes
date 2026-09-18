# Pod 与生命周期

> **Pod 是 K8s 的最小调度单元**——一个 Pod 里多个容器**共享 Network/IPC/UTS Namespace + Volume**（PID Namespace 默认不共享），由一个隐形的 **Pause 容器**做"占位 + 持有 Namespace"。生命周期 5 阶段（Pending → Running → Succeeded / Failed / Unknown），加 3 种 Probe（**Liveness 重启 / Readiness 摘流 / Startup 慢启动豁免**）。
>
> 本篇要解决面试官四个连环追问：
>
> ① **为什么不直接调度容器、要再造 Pod 这一层？**——Sidecar 模式 + 共享 Volume + 同生死的强耦合
> ② **Pause 容器是干嘛的？为什么每 Pod 都有？**——占位 PID 1 + 持有 Namespace
> ③ **Liveness 和 Readiness 区别？**——一个重启 / 一个摘流，混用是经典坑
> ④ **CrashLoopBackOff 怎么排查？**——容器一启动就挂的 5 个根因
>
> 跟其它模块的关系：
> - 前置：[Docker 容器原理](./Docker容器原理.md)（Namespace 共享是 Pod 的物理基础）
> - 上层：[工作负载](./工作负载.md) 都是 Pod 的管理器
> - 配套：[发布与弹性伸缩](./发布与弹性伸缩.md) 中优雅停机依赖 preStop hook

---

## 一、为什么 K8s 要造 Pod 这一层？

容器是单进程模型——但实际场景常常需要**多个容器同生共死、共享网络和存储**：

```
日志收集场景：
    主容器（业务 nginx）                Sidecar（日志收集 fluentd）
       │  日志写 /var/log/nginx       │  读 /var/log/nginx 发 Kafka
       └──── 必须共享 Volume ────────┘
       同时这俩还共享网络（fluentd 走 localhost 监控主容器）

服务网格场景：
    主容器（业务 java）                Sidecar（Envoy 代理）
       │  访问 localhost:15001       │  拦截全部出口流量
       └──── 共享 Network Namespace ─┘
```

如果直接调度容器，K8s 要**为每个容器单独算调度 + 协调它们生死 + 协调网络**——复杂且易错。**Pod 把这组容器打包**，K8s 调度的最小单位是 Pod 不是容器：
- 一组容器**一起调度到同一节点**（scheduler 视角）
- **一起启动 / 一起销毁**（kubelet 视角）
- **共享 Volume / 网络**（容器运行时视角）

这就是 Pod 的设计哲学——**单 Pod 通常一容器（业务），多容器才用 sidecar 模式**，而不是把多个独立服务塞进一个 Pod。

---

## 二、Pod 的物理实现：Pause 容器 + Namespace 共享

### 2.1 Pause 容器是什么

Pod 启动时**先起一个 Pause 容器**（隐形，`kubectl get pod` 看不到，`docker ps -a` 能看到 `k8s_POD_xxx` 镜像 = `registry.k8s.io/pause:3.9`），它有两个职责：

| 职责 | 详解 |
| --- | --- |
| **持有 Namespace** | Pause 创建出 Network / IPC / UTS Namespace，业务容器以 `--network=container:<pause>` 加入这些 Namespace |
| **PID 1 善后** | Pause 是 Pod 内的 init 进程（PID 1），收回僵尸进程；业务容器死 → kubelet 重启，但 Namespace 还在 Pause 上不丢 |

**Pause 镜像超小（~700KB）**——它的源码就是死循环 `pause(2)` syscall + 处理 SIGCHLD 收尸：

```c
// pause.c 简化版
int main() {
    signal(SIGCHLD, sigreap);   // 收僵尸子进程
    while(1) pause();            // 永远阻塞
}
```

### 2.2 Pod 内 Namespace 共享情况

| Namespace | 默认共享？ | 含义 |
| --- | --- | --- |
| **Network** | ✅ | Pod 内容器同 IP，能用 localhost 互通，端口不能冲突 |
| **IPC** | ✅ | 共享 SysV 信号量 / 消息队列 / 共享内存 |
| **UTS** | ✅ | 同 hostname |
| **PID** | ❌（默认） | 每容器自己的 PID 1 |
| **MNT** | ❌ | 各自的根文件系统（但可挂同一 Volume） |
| **User** | ❌ | 各自的用户视图 |

**为什么 PID 不共享？**——很多镜像里的应用假设自己是 PID 1（处理 SIGTERM、收子进程），共享会让 sidecar 看到主容器进程，破坏假设。

**显式共享 PID**（调试场景）：

```yaml
spec:
  shareProcessNamespace: true
  containers: [...]
# 这时 sidecar 用 ps 能看到主容器进程，方便排查
```

---

## 三、initContainer 与 Sidecar 模式

### 3.1 initContainer：顺序执行，跑完才放业务容器

```yaml
spec:
  initContainers:
  - name: wait-db
    image: busybox
    command: ["sh", "-c", "until nc -z mysql 3306; do sleep 2; done"]
  - name: db-migrate
    image: myapp:latest
    command: ["./migrate.sh"]
  containers:                          # initContainer 全部成功后才起
  - name: app
    image: myapp:latest
```

**3 个特性**：
1. **顺序执行**——一个跑完成功才下一个；任意失败整个 Pod 重启
2. **跑完即退**——不会一直运行；不需要 Probe
3. **共享 Pod 网络 + Volume**——可读写共享卷给业务容器

**典型用途**：
- 等待依赖（数据库 / 配置中心）就绪
- 跑数据库迁移 / 数据预热
- 给共享卷下载初始内容（如 git clone 代码到 emptyDir）

### 3.2 Sidecar 模式

跟主容器一起跑、辅助主容器：

| Sidecar 类型 | 例子 |
| --- | --- |
| **日志收集** | fluentd / vector 读主容器日志发 Kafka |
| **网络代理** | Envoy / Linkerd（Service Mesh 数据面） |
| **配置同步** | git-sync 拉 git 仓库内容到共享 Volume |
| **监控指标** | jmx_exporter 转 Java JMX 为 Prometheus |
| **守护进程** | TLS 证书轮换 / 凭证刷新 |

**K8s 1.29 GA 的 Sidecar Container 特性**：在 `initContainers` 里加 `restartPolicy: Always` 标记 sidecar——`initContainer` 顺序启动 + 主容器结束时 sidecar 才退，解决了"主容器死了 sidecar 还活着浪费资源"的老问题。

---

## 四、生命周期 5 阶段

### 4.1 Pod Phase 状态机

```
                 创建
                  │
                  ▼
         ┌─────── Pending ──────┐
         │     - 调度中           │
         │     - 镜像拉取中        │
         │     - initContainer 中 │
         │                       │
         │                       │ (容器至少有一个跑起来)
         │                       ▼
         │                    Running
         │                       │
         │            ┌──────────┼──────────┐
         │            │          │          │
         │            ▼          ▼          ▼
         │       Succeeded    Failed      Unknown
         │      (完成成功)    (退出 != 0)  (kubelet 失联)
         │
         │ (失败立即回 Pending 重试 / Job 看 backoffLimit)
```

**注意**：`Phase` 只是粗粒度状态——精确状态看 `Conditions` 字段：

```bash
kubectl get pod xxx -o yaml | grep -A 10 conditions
```

| Condition | 含义 |
| --- | --- |
| **PodScheduled** | scheduler 已 Bind 节点 |
| **Initialized** | 全部 initContainer 跑完 |
| **ContainersReady** | 全部容器 Ready（Probe 通过） |
| **Ready** | Pod 整体 Ready（= ContainersReady && readinessGates 全通过） |

### 4.2 容器状态（细于 Pod Phase）

```yaml
containerStatuses:
- name: app
  state:
    running:           # 只能是 waiting / running / terminated 之一
      startedAt: ...
  lastState:
    terminated:
      reason: OOMKilled    # 上次死的原因
      exitCode: 137
  restartCount: 3
  ready: true
```

**关键 Reason 字段**：
- `ContainerCreating` —— 创建中（镜像拉取 / Volume 挂载）
- `ImagePullBackOff` —— 镜像拉不到（404 / 私有仓未授权）
- `CrashLoopBackOff` —— 反复 crash 退避中
- `OOMKilled` —— 内存超限被内核杀（exit 137）
- `Error` —— 容器主进程 exit != 0
- `Completed` —— 容器主进程 exit 0（Job 正常）

---

## 五、Probe 三件套

### 5.1 三种 Probe 的角色

| Probe | 失败动作 | 用途 |
| --- | --- | --- |
| **Liveness** | **重启容器** | 检测进程死锁 / 假死（端口在但不响应） |
| **Readiness** | **从 Endpoint 摘除**（流量不打过来） | 检测能否接流量（启动慢 / 依赖未就绪） |
| **Startup** | 在它通过前不跑 Liveness/Readiness | 启动很慢的应用（JVM 大堆 / Spring 上下文加载） |

**关键直觉**：
- Liveness 失败 → 重启（破坏性）
- Readiness 失败 → 摘流量（不影响进程）
- Startup 失败 → 重启（直到通过或 failureThreshold 用完）

**Readiness 不通过的 Pod**：进程还在跑、但 Endpoint Controller 把它从 Service Endpoint 摘掉，流量不打过来。Pod 自愈后自动加回。

### 5.2 三种检测方式

```yaml
livenessProbe:
  httpGet:                    # HTTP GET（最常用）
    path: /healthz
    port: 8080
    httpHeaders:
    - name: X-Custom
      value: probe
  initialDelaySeconds: 30     # 启动后等 30s 再开始探测
  periodSeconds: 10           # 每 10s 探一次
  timeoutSeconds: 3           # 单次探测 3s 超时
  failureThreshold: 3         # 连续失败 3 次才算死
  successThreshold: 1         # 1 次成功就算活

# 或：tcp 探测（端口能不能连上）
readinessProbe:
  tcpSocket:
    port: 5432

# 或：exec 命令（兜底）
livenessProbe:
  exec:
    command: ["cat", "/tmp/healthy"]
```

### 5.3 实战配置

**Java SpringBoot 应用标配**：

```yaml
startupProbe:                 # JVM 启动 30~60s，先靠它
  httpGet:
    path: /actuator/health
    port: 8080
  failureThreshold: 30        # 30 * 10s = 5min 兜底
  periodSeconds: 10

livenessProbe:                # 启动通过后才生效
  httpGet:
    path: /actuator/health/liveness
    port: 8080
  periodSeconds: 30           # 频率低一点，避免 GC 误杀
  failureThreshold: 5

readinessProbe:               # 频率高，快速摘流
  httpGet:
    path: /actuator/health/readiness
    port: 8080
  periodSeconds: 10
  failureThreshold: 3
```

**关键设计**：
- Liveness 用 `/liveness`——只检查进程死锁（不查依赖，否则 DB 一抖全部容器重启）
- Readiness 用 `/readiness`——检查依赖（DB 连不上摘流，依赖恢复自动加回）
- Spring Boot 2.3+ 内置区分两个端点，配 `management.endpoint.health.probes.enabled=true`

---

## 六、生命周期钩子（postStart / preStop）

```yaml
lifecycle:
  postStart:
    exec:
      command: ["sh", "-c", "echo started > /tmp/started"]
  preStop:
    exec:
      command: ["sh", "-c", "sleep 15"]    # 优雅停机典型用法
```

| 钩子 | 时机 | 关键陷阱 |
| --- | --- | --- |
| **postStart** | 容器**主进程刚启动后**立即并发执行 | **不保证在 ENTRYPOINT 之前还是之后**——不能依赖业务进程已就绪 |
| **preStop** | 收到 SIGTERM **之前** 同步执行 | 是优雅停机的核心，详见下文 |

### 6.1 优雅停机：preStop 标准用法

K8s 终止 Pod 的步骤：

```
1. apiserver 标记 Pod 为 Terminating
2. Endpoint Controller 把 Pod 从 EndpointSlice 摘掉（开始）
3. kubelet 调 preStop hook（同步执行，业务可在此完成收尾）
4. preStop 完成 → kubelet 发 SIGTERM 给容器主进程
5. 等待 terminationGracePeriodSeconds（默认 30s）
6. 还没退 → 发 SIGKILL 强杀
```

**关键陷阱**：步骤 2 和步骤 3 是**并行**——Endpoint 还没真正传播到所有节点的 kube-proxy（最多几秒延迟），preStop 已经开始了。所以 preStop 要 **sleep 几秒**让流量摘干净：

```yaml
preStop:
  exec:
    command: ["sh", "-c", "sleep 15 && /app/graceful-shutdown.sh"]
terminationGracePeriodSeconds: 60     # 至少 = preStop sleep + 业务收尾时间 + 余量
```

详见 [发布与弹性伸缩](./发布与弹性伸缩.md)。

---

## 七、生产踩坑

### 坑 1：Liveness 太严 + JVM GC → 抖死

**现象**：服务跑得好好的，偶发 Pod 重启，频率随流量上涨而增加。

**根因**：JVM Full GC stop-the-world 几秒；这几秒 Liveness Probe 不响应；连续 3 次失败 → kubelet 杀容器重启 → JVM 冷启动 → 流量倾斜到其他副本 → 它们 GC → 雪崩。

**修复**：
- Liveness 别检查依赖（DB 慢就跟着死了）
- 调大 `failureThreshold`（10+）和 `periodSeconds`（30s+）
- 用 Readiness 摘流量（GC 期间不接新请求），Liveness 只看进程是否真死
- JVM 调优减少 STW 时间（G1 / ZGC）

### 坑 2：CrashLoopBackOff 看 logs 看不到

**现象**：`kubectl get pod` 显示 `CrashLoopBackOff`，`kubectl logs xxx` 输出为空。

**根因**：容器启动就挂——logs 默认显示**当前**容器的日志，挂掉的容器已经退出。

**排查**：

```bash
kubectl logs xxx --previous              # 看上一次容器的日志（关键！）
kubectl describe pod xxx                 # 看 Events 和 lastState.terminated.reason
kubectl get pod xxx -o yaml | grep -A 10 lastState
```

**5 大根因**：
1. ENTRYPOINT 错误（找不到命令、参数错）→ Reason: Error
2. 应用启动失败（配置错、端口被占）→ logs --previous 看
3. OOMKilled（exit 137）→ 提高 limits.memory
4. 镜像拉不到 → ImagePullBackOff（不是 CrashLoopBackOff）
5. PID 1 不响应 SIGTERM → 详见坑 5

### 坑 3：postStart 和 ENTRYPOINT 竞争

**现象**：postStart 里 `curl localhost:8080/init` → 偶发失败，因为 ENTRYPOINT 启动的应用还没监听端口。

**根因**：postStart 跟 ENTRYPOINT **并发执行**，时序不保证。

**修复**：
- postStart 里加重试 / 等待逻辑
- 或用 initContainer 替代（顺序保证）
- 或应用启动时主动调 init 接口

### 坑 4：preStop sleep 太短 / terminationGracePeriodSeconds 太短

**现象**：滚动更新时客户端报 connection reset / 502。

**根因**：Endpoint 摘除有传播延迟；客户端请求还在路上时容器已经被 SIGKILL。

**修复**：

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "sleep 15"]   # 让流量摘干净
terminationGracePeriodSeconds: 60         # >= sleep + 业务收尾 + 余量

# Spring Boot 2.3+ 加配置
spring:
  lifecycle:
    timeout-per-shutdown-phase: 30s
server:
  shutdown: graceful
```

### 坑 5：CMD 用 shell 形式 → SIGTERM 收不到

**现象**：preStop 配了，terminationGracePeriodSeconds 60s，但 Pod 还是 30s 后被强杀。

**根因**：Dockerfile 里 `CMD java -jar app.jar`（shell 形式）→ 实际跑 `/bin/sh -c "java -jar app.jar"`：sh 是 PID 1，java 是子进程；K8s 发 SIGTERM 给 PID 1（sh），sh 不转发，java 永远收不到。

**修复**：
- Dockerfile 改 exec 形式：`CMD ["java", "-jar", "app.jar"]`
- 或装 `tini` 作为 init：`ENTRYPOINT ["/tini", "--", "java", ...]`

### 坑 6：initContainer 拉不到镜像卡 Pending

**现象**：Pod 卡 Pending 几小时，`describe` 显示 initContainer ImagePullBackOff。

**根因**：initContainer 用了打错 tag 的镜像；拉不到 → 整个 Pod 永远不到 Running。

**修复**：① 修镜像；② 加 `imagePullPolicy: IfNotPresent` 用本地缓存；③ 私有仓配 `imagePullSecrets`。

---

## 八、面试高频追问

**Q1：为什么 K8s 要造 Pod 这一层抽象？**

A：因为现实中常需要**多个容器同生死、共享网络和存储**——sidecar 模式（日志收集 / 服务网格代理）、initContainer（依赖检查）、共享 Volume。如果直接调度容器，K8s 要为每容器单独算调度、协调生死、协调网络——复杂且易错。**Pod 把一组容器打包**，调度 / 启停 / 网络 / 存储以 Pod 为单位——简洁且与现实场景对齐。

**Q2：Pause 容器是干什么的？为什么每个 Pod 都有？**

A：**两个职责**：① **持有 Namespace**——Pause 创建 Network/IPC/UTS Namespace，业务容器以 `--network=container:<pause>` 加入。业务容器死了 Namespace 还在 Pause 上，重启的业务容器能加入同一个 Namespace（IP 不变）；② **PID 1 善后**——Pause 是 Pod 内 init 进程，收子进程僵尸；业务容器异常时 Pause 不死，让 kubelet 能继续管理 Pod。Pause 镜像才 700KB，开销可忽略。

**Q3：Pod 内多容器共享什么？**

A：**默认共享 Network / IPC / UTS Namespace + Volume**；**默认不共享 PID / MNT / USER**。所以：① 同 IP，互相用 localhost 通信，端口不能冲突；② 同 hostname；③ 共享 SysV 信号量；④ 各自的根文件系统但能挂到同一个 Volume；⑤ 各自的 PID 1（互看不到对方进程）；⑥ 显式 `shareProcessNamespace: true` 共享 PID（调试场景）。

**Q4：initContainer 跟普通 Container 区别？**

A：① **顺序执行**——一个跑完成功才下一个，全部成功业务容器才启动；② **跑完即退**——不需要 Probe；③ **共享 Pod 网络和 Volume**——可读写共享卷；④ **失败重启整个 Pod**（受 restartPolicy 控制）。**典型用途**：等依赖（DB / 配置中心）、跑迁移、下载初始化数据到 emptyDir。**注意**：K8s 1.29 GA 的 Sidecar Container 用 `initContainer + restartPolicy: Always` 实现"顺序启 + 主容器死时一起退"。

**Q5：Pod 状态机有哪些 Phase？怎么排障 Pending？**

A：**5 个 Phase**：Pending（调度中 / 拉镜像中 / initContainer 中）→ Running → Succeeded（exit 0）/ Failed（exit != 0）/ Unknown（kubelet 失联）。**Pending 排障 4 步**：① `kubectl describe pod` 看 Events——常见 Insufficient cpu/memory（节点资源不够）、FailedScheduling（亲和约束 / 污点）；② `kubectl get nodes` 看节点状态；③ `kubectl describe nodes` 看 allocatable；④ 检查 PVC 是否 Bound（PVC 没 Bound Pod 起不来）。

**Q6：Liveness 和 Readiness 区别？混用会怎样？**

A：**Liveness 失败 → 重启容器**（破坏性，杀进程）；**Readiness 失败 → 摘流量**（不杀进程，从 Endpoint 移除）。**混用经典坑**：Liveness 检查依赖（如 DB），DB 一抖全部 Pod 被杀重启 → DB 恢复后所有 Pod 同时冷启动 → 雪崩。**正确分工**：Liveness 只看进程死锁（路径返回 200 即可，不查任何依赖）；Readiness 检查依赖（DB / 缓存连不上摘流量，恢复自动加回）。

**Q7：Startup Probe 解决什么问题？**

A：**慢启动应用**（JVM 大堆 / Spring 上下文加载 30~60s）的痛点：要么 Liveness `initialDelaySeconds` 设很大（响应不及时）；要么设小了启动期还没就绪就被杀重启。**Startup Probe 的设计**：在它通过前不跑 Liveness / Readiness；通过后才启用另两者。所以可以给 Startup 设 `failureThreshold: 30 + periodSeconds: 10`（5 分钟兜底），Liveness 保持敏感配置（30s 失败 5 次重启）。

**Q8：CrashLoopBackOff 怎么排查？**

A：**5 步**：① `kubectl get pod` 看 lastState.terminated.reason / exitCode；② `kubectl logs --previous`（关键！默认看不到挂掉的容器日志）；③ `kubectl describe pod` 看 Events；④ 检查 OOMKilled（exit 137 → 加 limits.memory）；⑤ 检查 ENTRYPOINT 是不是 shell 形式导致 SIGTERM 收不到。**5 大根因**：① ENTRYPOINT 错（找不到命令）；② 应用启动失败（配置错）；③ OOMKilled；④ 镜像拉不到（ImagePullBackOff，不算 CrashLoop）；⑤ Liveness 太严抖死。

**Q9：Pod 怎么优雅停机？**

A：**链路**：① apiserver 标 Terminating；② Endpoint Controller 摘除（**异步**，传播延迟几秒）；③ kubelet 调 **preStop hook**（同步阻塞）；④ preStop 完发 SIGTERM；⑤ 等 `terminationGracePeriodSeconds`（默认 30s）；⑥ 还没退发 SIGKILL。**关键**：preStop 要 `sleep 15` 让 Endpoint 传播 + 业务收尾；总时长 = sleep + 业务收尾 + 余量；CMD/ENTRYPOINT 用 exec 形式（数组）让业务进程是 PID 1 收得到 SIGTERM。Spring Boot 加 `server.shutdown: graceful` + `spring.lifecycle.timeout-per-shutdown-phase`。

**Q10：postStart 跟 ENTRYPOINT 谁先执行？**

A：**并发，时序不保证**——可能 postStart 先跑、可能 ENTRYPOINT 先跑。所以 postStart **不能依赖业务进程已就绪**——加重试 / 等待逻辑，或用 initContainer 替代（顺序保证）。常见错误：postStart 里 `curl localhost:8080/init` 偶发失败，因为应用还没监听端口。

**Q11：Pod 怎么共享 Volume？**

A：在 Pod spec 里定义一次 Volume，多容器各自挂载：

```yaml
spec:
  volumes:
  - name: shared-logs
    emptyDir: {}
  containers:
  - name: app
    volumeMounts:
    - name: shared-logs
      mountPath: /var/log/app
  - name: log-collector
    volumeMounts:
    - name: shared-logs
      mountPath: /logs        # 路径可不同
      readOnly: true
```

emptyDir 类型 Pod 内共享、Pod 删则消失；持久化用 PVC。

**Q12：Pod 重启 IP 会变吗？**

A：**容器重启 IP 不变**（Pause 容器持有 Network Namespace，业务容器死掉重启加入同一 Namespace）；**Pod 重建 IP 会变**（Deployment 滚动更新创新 Pod，Pause 也是新的）。所以**直接用 Pod IP 通信不可靠**——必须用 Service ClusterIP（稳定）或 Headless Service + Pod 域名（StatefulSet）。

---

## 九、答题模板（60 秒话术）

> Pod 是 K8s **最小调度单元**——一组容器同生共死、共享 Network / IPC / UTS Namespace + Volume，物理上靠一个隐形的 **Pause 容器**持有 Namespace + 收子进程僵尸。Pod 内多容器**默认共享网络和 IPC，不共享 PID 和 MNT**——所以容器间用 localhost 互通、端口不能冲突，但各自的 PID 1。
>
> **生命周期 5 阶段**：Pending → Running → Succeeded/Failed/Unknown；细节看 Conditions（PodScheduled / Initialized / ContainersReady / Ready）。**容器状态精到 Reason**：CrashLoopBackOff / ImagePullBackOff / OOMKilled / Error / Completed。
>
> **Probe 三件套分工**：① **Liveness 失败重启容器**——只看进程死锁，不查依赖（否则 DB 抖全雪崩）；② **Readiness 失败摘 Endpoint** ——检查依赖，不通过流量不打过来；③ **Startup 通过前不跑另两者**——慢启动应用（JVM）兜底。Spring Boot 标配 `/actuator/health/liveness` + `/readiness` 两个端点。
>
> **生命周期钩子**：postStart 跟 ENTRYPOINT **并发执行**（时序不保证，避免依赖业务就绪）；**preStop 是优雅停机核心**——`sleep 15` 让 Endpoint 传播 + 业务收尾，配合 `terminationGracePeriodSeconds: 60`。CMD 必须用 exec 形式数组，否则 sh 是 PID 1 收不到 SIGTERM。
>
> **5 大生产坑**：① Liveness 太严 + JVM Full GC 抖死；② CrashLoopBackOff 要看 `logs --previous` 不是当前 logs；③ OOMKilled 退出码 137 加 limits 或调 JVM；④ preStop sleep 太短客户端报 502；⑤ shell 形式 CMD 导致 SIGTERM 失效优雅停机失败。

---

## 十、相关文档

- 前置：[Docker 容器原理](./Docker容器原理.md) — Namespace 共享是 Pod 基础
- 前置：[K8s 架构总览](./K8s架构总览.md) — Pod 创建 25 步全链路
- 上层：[工作负载](./工作负载.md) — Deployment / StatefulSet 是 Pod 的管理器
- 配套：[发布与弹性伸缩](./发布与弹性伸缩.md) — 优雅停机详解
- 配套：[调度与资源管理](./调度与资源管理.md) — Pod 调度详解
