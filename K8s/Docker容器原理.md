# Docker 容器原理

> **容器不是轻量级虚拟机，而是被"圈养"的进程。** 容器 = **Linux Namespace（隔离视图）+ Cgroups（限制资源）+ UnionFS（镜像分层）**——三件套全是 Linux 内核能力，Docker 只是把它们打了个包并加上镜像分发，把"打包应用 + 隔离运行 + 资源限额"这件事从虚拟机的**分钟级 GB 级**压到了**秒级 MB 级**。
>
> 本篇要解决面试官四个连环追问：
>
> ① **容器跟虚拟机本质区别？**——共享内核 vs 各自跑 OS
> ② **怎么实现隔离？**——Namespace 6 类各管一摊（PID / NET / MNT / UTS / IPC / USER）
> ③ **怎么实现资源限额？**——Cgroups v1 / v2 子系统逐项控制（CPU / 内存 / IO / pids）
> ④ **镜像凭什么共享分层？**——UnionFS / OverlayFS 联合挂载 + 写时复制（CoW）
>
> 跟其它模块的关系：
> - 本篇是 [K8s 架构总览](./K8s架构总览.md) 与 [Pod 与生命周期](./Pod与生命周期.md) 的前置——K8s 不会再讲一遍 Namespace
> - [JVM/jvm 参数](../JVM/jvm参数.md) 中"容器化 JVM 必配 `-XX:+UseContainerSupport`"的根因在本篇
> - [Network/TCP 协议](../Network/TCP协议.md) / [Network/多路复用](../Network/多路复用.md) 是 Network Namespace 之上的应用层

---

## 一、容器演进史：从 chroot 到 runc

容器不是 2013 年 Docker 的发明——它是 Linux 内核 30 年隔离能力沉淀的"产品化"。

```
1979  chroot          切换文件系统根目录（最早的"隔离"，但 root 能逃出去）
2002  Namespace 引入  Linux 2.4.19 加入 mount namespace
2008  LXC             第一个完整的容器工具集，用起来太复杂
2013  Docker 1.0      封装 LXC + 镜像分层 + 镜像仓库 → 一夜爆红
2014  Docker 自研 libcontainer  抛弃 LXC，直接调内核
2015  OCI / runc      Docker 把 libcontainer 捐给社区 → runc，制定 OCI 镜像/运行时规范
2016  containerd      Docker 把守护进程拆出来 → containerd
2016  K8s 引入 CRI    Container Runtime Interface 标准
2020  dockershim 弃用 K8s 1.20 宣布、1.24（2022）正式删除
```

**关键洞察**：Docker 真正的创新不是隔离技术（早就有了），而是**镜像分层 + Docker Hub 分发模型**——让"build once, run anywhere"从口号变现实。隔离技术之后被 K8s + containerd + runc 拆得越来越薄，Docker 在 K8s 里反而是"被淘汰"的那个。

---

## 二、核心原理：三件套（Namespace + Cgroups + UnionFS）

```
       ┌────────────────────────────────────┐
       │            容器 = 被圈养的进程         │
       │  ┌──────────────────────────────┐  │
       │  │  应用进程（PID 1，实际是 nginx）│  │
       │  └──────────────────────────────┘  │
       │           ↑           ↑           │
       │   ┌───────┴───┐   ┌───┴───────┐   │
       │   │ Namespace │   │ Cgroups   │   │
       │   │ 看不到外界  │   │ 用不超额度  │   │
       │   └───────────┘   └───────────┘   │
       │           ↑                       │
       │   ┌───────┴────────┐              │
       │   │   UnionFS      │ 镜像分层 + CoW │
       │   │  (OverlayFS)   │              │
       │   └────────────────┘              │
       └────────────────────────────────────┘
                  ↓ 共享同一个内核
       ┌────────────────────────────────────┐
       │         Host Linux Kernel          │
       └────────────────────────────────────┘
```

### 2.1 Namespace：让进程看不到外界

Linux Namespace 给进程一份"独立视图"——进程以为自己看到的是全部，其实只是一小块。**6 类 Namespace 各管一摊**：

| Namespace | 隔离什么 | 内核常量 | 容器内典型现象 |
| --- | --- | --- | --- |
| **PID** | 进程 ID | `CLONE_NEWPID` | `ps` 看到自己是 PID 1（其实宿主上是 12345） |
| **NET** | 网络栈（网卡 / 路由表 / iptables） | `CLONE_NEWNET` | 容器内 `ifconfig` 只看到 eth0 + lo |
| **MNT** | 挂载点（文件系统视图） | `CLONE_NEWNS` | 容器看到的根目录 = 镜像内容，不是宿主 / |
| **UTS** | 主机名 + 域名 | `CLONE_NEWUTS` | `hostname` 显示容器 ID 而非宿主名 |
| **IPC** | System V IPC + POSIX 消息队列 | `CLONE_NEWIPC` | 容器内进程间共享内存不影响宿主 |
| **USER** | UID / GID 映射 | `CLONE_NEWUSER` | 容器内 root（UID=0）映射到宿主非 root（如 100000） |

> **Linux 4.6 之后还多了 Cgroup Namespace、Time Namespace（5.6+）**——面试不常考，知道有就行。

**关键 API**：3 个系统调用

```c
clone(fn, stack, CLONE_NEWPID | CLONE_NEWNET | ..., arg);  // 创建新进程 + 新 Namespace
unshare(CLONE_NEWNS);                                       // 当前进程脱离原 Namespace
setns(fd, CLONE_NEWPID);                                    // 当前进程加入指定 Namespace
```

`docker exec` 进容器，本质就是 `setns()` 加入容器的全部 6 个 Namespace。

**实操验证（宿主机执行）**：

```bash
# 启动一个容器
docker run -d --name nginx-demo nginx
PID=$(docker inspect --format '{{.State.Pid}}' nginx-demo)

# 看容器进程的 Namespace（每个文件代表一个 Namespace）
ls -l /proc/$PID/ns/
# lrwxrwxrwx 1 root root 0 ... ipc -> 'ipc:[4026532567]'
# lrwxrwxrwx 1 root root 0 ... mnt -> 'mnt:[4026532565]'
# lrwxrwxrwx 1 root root 0 ... net -> 'net:[4026532570]'
# lrwxrwxrwx 1 root root 0 ... pid -> 'pid:[4026532568]'
# lrwxrwxrwx 1 root root 0 ... uts -> 'uts:[4026532566]'

# 同一个 Namespace 文件 inode 相同 → 共享，不同 → 隔离
nsenter -t $PID -n ip addr   # 在宿主机进入容器的 NET Namespace 看网卡
```

**为什么 PID Namespace 在 Pod 多容器间默认不共享？**——K8s 默认让 Pod 内各容器**共享 NET / IPC / UTS** 但不共享 PID（每个容器是自己的 PID 1）。原因：很多镜像里的应用假设自己是 PID 1（处理信号），共享 PID 会让 sidecar 看到主容器进程，破坏假设。Pod 可显式开 `shareProcessNamespace: true` 共享，调试场景常用。

### 2.2 Cgroups：限制资源用量

Namespace 解决"看不到"，Cgroups（Control Groups）解决"用不超"。**核心是文件系统接口**——每个 cgroup 是 `/sys/fs/cgroup/` 下一个目录，写文件即生效。

**Cgroups v1（默认 / 大多数生产环境）**：每个**子系统（subsystem）独立挂载**，互不影响。

| 子系统 | 控制什么 | 关键文件 |
| --- | --- | --- |
| **cpu** | CPU 时间片占比 | `cpu.cfs_quota_us` / `cpu.cfs_period_us`（默认 100ms 周期）、`cpu.shares`（相对权重） |
| **cpuset** | 绑定到指定 CPU 核 | `cpuset.cpus` |
| **memory** | 内存上限 + OOM | `memory.limit_in_bytes`、`memory.oom_control` |
| **blkio** | 块设备 IO 带宽 | `blkio.throttle.read_bps_device` |
| **pids** | 进程数上限 | `pids.max`（防 fork 炸弹） |
| **net_cls** | 网络包打 classid（配合 tc） | `net_cls.classid` |
| **devices** | 允许 / 禁用设备访问 | `devices.allow` |

**Cgroups v2（Linux 4.5+，systemd 默认）**：**统一层级**——所有子系统挂在同一棵树上，配置更一致；K8s 1.25+ 全面拥抱 v2。

```
v1 多挂载点：                    v2 单挂载点：
/sys/fs/cgroup/cpu/             /sys/fs/cgroup/
/sys/fs/cgroup/memory/          ├── cgroup.controllers   ← 统一控制
/sys/fs/cgroup/blkio/           └── docker/
                                    ├── cpu.max
                                    ├── memory.max
                                    └── io.max
```

**Docker 实操**：`docker run -m 512m --cpus 1.5 nginx` 实际等价于：

```bash
# v1 等价命令（Docker 帮你做的）
echo 536870912 > /sys/fs/cgroup/memory/docker/<id>/memory.limit_in_bytes
echo 150000   > /sys/fs/cgroup/cpu/docker/<id>/cpu.cfs_quota_us   # 1.5 核 = 150ms / 100ms
echo 100000   > /sys/fs/cgroup/cpu/docker/<id>/cpu.cfs_period_us
```

**关键现象**：超内存限额 → **OOMKill**（内核杀进程，不是 SIGTERM）；超 CPU 限额 → **CPU 限速（throttle）**而非 kill，表现为应用变慢。

### 2.3 UnionFS / OverlayFS：镜像分层 + 写时复制

镜像不是 tar 包——它是**一摞只读层叠起来联合挂载（union mount）**，容器启动时再叠一个**可写层（CoW）**在最上面。

```
容器视角（合并视图）：             实际磁盘上：
┌──────────────────┐               ┌──────────────────┐
│ /                │ ←合并后的根    │ 容器可写层（CoW）   │ ← /var/lib/docker/overlay2/<container>/diff/
│  ├─ etc/         │               ├──────────────────┤
│  ├─ usr/         │               │ Layer N: nginx    │ ← 镜像层（只读，多容器共享）
│  ├─ var/         │               ├──────────────────┤
│  └─ tmp/         │               │ Layer 2: deps     │
└──────────────────┘               ├──────────────────┤
                                   │ Layer 1: ubuntu   │
                                   └──────────────────┘
```

**OverlayFS 三层概念**：
- **lowerdir**：只读层（可多个，按顺序叠）
- **upperdir**：可写层（写时复制目标）
- **merged**：合并视图（容器看到的根目录）

**写时复制（Copy-on-Write）**：

```
1. 容器尝试改 /etc/nginx.conf
2. OverlayFS 在 lowerdir 找到该文件（位于 Layer 2 nginx 层，只读）
3. 把整个文件复制到 upperdir
4. 修改在 upperdir 的副本上完成
5. 容器看到的还是 merged 视图（自动用上层覆盖下层）
6. 容器删除时 upperdir 跟着删 → 修改丢失
```

**关键收益**：

- **存储**：100 个容器共享同一个 nginx 镜像（500MB），每个容器只占自己的可写层（一般 < 10MB）
- **拉取**：增量传输——只下没有的层
- **构建**：缓存命中——上一行没变就复用上一层

**关键代价**：
- **写性能差**：第一次写大文件要先 CoW 整文件复制（GB 级文件可能卡住）
- **inode 翻倍**：merged 层和 upper 层都占 inode，密集小文件场景容易爆 inode
- **遗留页缓存**：CoW 后老文件还在 lower 层，page cache 浪费

> **生产准则**：**容器内禁止写大量数据 / 大文件**——必须挂 Volume。Java 应用日志写到容器层是经典反模式（详见 [Docker 存储与数据卷](./Docker存储与数据卷.md)）。

---

## 三、容器运行时演进：dockershim → containerd → runc

K8s 启动 Pod 不直接调 Docker，中间隔了一层 **CRI（Container Runtime Interface）** 标准——这是为什么 K8s 1.24 能"删掉 Docker"的关键。

### 3.1 完整调用链

```
kubectl apply
   ↓
apiserver → etcd
   ↓ (kubelet watch)
kubelet
   ↓ gRPC（CRI 标准）
containerd（高层运行时，管镜像 / 容器生命周期）
   ↓
runc（低层运行时，OCI 规范，实际调用 clone() + Namespace + Cgroups）
   ↓
内核 syscall
```

**OCI（Open Container Initiative）** 定义两个规范：
- **runtime-spec**：怎么运行容器（runc 实现）
- **image-spec**：镜像格式（layers / config / manifest）

### 3.2 dockershim 的故事

K8s 早期直接对接 Docker，但 Docker 不实现 CRI——K8s 写了个 **dockershim** 适配器：

```
[K8s 1.5 ~ 1.23]
kubelet → dockershim → dockerd → containerd → runc
                       ↑ 多了 2 层，每个都是单点

[K8s 1.24+]
kubelet → containerd → runc           ← 直接对接 CRI
```

**为什么删 dockershim？**
1. **多余的链路**：dockerd 本质就是 containerd 的封装，绕了一圈
2. **维护负担**：dockershim 是 K8s 团队维护的"为了 Docker 一家写的代码"
3. **Docker 不实现 CRI**：Mirantis 维护的 cri-dockerd 项目接管了用户兼容需求

> **常见误解**：很多人以为"K8s 1.24 不支持 Docker 镜像了"——**镜像格式是 OCI 标准，跟 Docker / containerd 没关系**。删的是运行时 dockerd，镜像继续兼容。

### 3.3 containerd vs CRI-O 选型

| 维度 | **containerd** | CRI-O |
| --- | --- | --- |
| 来源 | Docker 拆分出来 | Red Hat 为 K8s 量身定做 |
| 通用性 | 通用容器运行时 | **只服务 K8s** |
| 功能 | 完整（镜像 / 容器 / 任务 / 快照） | 精简（够 K8s 用就行） |
| 国内主流 | **是** | OpenShift 用 |
| 性能 | 几乎一致（都是 runc 之上的薄壳） | 几乎一致 |

**生产建议**：新集群默认 containerd，OpenShift 体系用 CRI-O。两者切换对应用透明。

---

## 四、容器化 JVM / Go 必坑

### 4.1 JVM：必须开 `-XX:+UseContainerSupport`

**症状**：容器配 `-m 1g` 内存上限，JVM 启动后 `Runtime.maxMemory()` 显示 7G（宿主总内存的 1/4）→ 实际用量很快超 1G → **OOMKill**。日志里看不到任何 OOM 报错（内核杀的，没机会打印）。

**根因**：JVM 默认通过 `/proc/meminfo` 看总内存——容器内 `/proc` 默认是宿主机的视图（Cgroup Namespace 默认不挂载）。

**修复**：

```bash
# JDK 8u191+ / JDK 10+ 默认开启
java -XX:+UseContainerSupport -XX:MaxRAMPercentage=75 -jar app.jar

# 关键：用 MaxRAMPercentage 不要写死 -Xmx
# -Xmx512m  ❌  容器扩容不跟着变
# -XX:MaxRAMPercentage=75  ✅  按 Cgroup 限额比例
```

**深拆**：JVM 怎么"看到"Cgroup 限额？

- 读 `/sys/fs/cgroup/memory/memory.limit_in_bytes`（v1）或 `/sys/fs/cgroup/memory.max`（v2）
- 比 `/proc/meminfo` 优先（容器场景 /proc 视图是宿主，不可信）

### 4.2 Go：GOMAXPROCS 与 CPU 限额

**症状**：容器配 `--cpus 2`，Go 服务跑在 64 核宿主上，`runtime.NumCPU()` 返回 64 → Go 起 64 个 P → 频繁上下文切换 → 性能反而比单核还差。

**根因**：Go runtime 默认按 `/proc/cpuinfo` 看 CPU 数。

**修复**：

```go
import _ "go.uber.org/automaxprocs"  // import 即生效

// 自动读 cgroup CPU 限额，设置 GOMAXPROCS = ceil(cpu_quota / cpu_period)
```

**生产建议**：所有容器化 Go 服务标配 `automaxprocs`。

### 4.3 时区不一致

```bash
# 容器内
$ date
Mon Mar  4 03:00:00 UTC 2024     ← UTC，不是 CST

# 修复（Dockerfile）
RUN ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
 && echo 'Asia/Shanghai' > /etc/timezone
```

或运行时挂载：`-v /etc/localtime:/etc/localtime:ro`。

---

## 五、Docker vs 虚拟机

| 维度 | **容器** | 虚拟机 |
| --- | --- | --- |
| 隔离层 | Namespace + Cgroups（共享内核） | Hypervisor + 完整 Guest OS |
| 启动时间 | **秒级（典型 50ms ~ 2s）** | 分钟级（30s ~ 2min） |
| 资源开销 | 几十 MB（应用本身大小） | 几百 MB ~ 几 GB（OS 本身） |
| 镜像大小 | MB 级（Alpine 5MB / distroless 20MB / 标准 200MB） | GB 级 |
| 安全隔离 | 弱（共享内核 → 内核漏洞 = 容器逃逸） | 强（硬件虚拟化边界） |
| 性能开销 | 接近原生（Namespace 几乎零成本，Cgroup < 1%） | 5% ~ 20% |
| 跨 OS | 不能（Linux 容器只能跑 Linux） | 能（Win 上跑 Linux VM） |
| 典型用途 | 微服务、CI/CD、应用打包 | 多租户、跨 OS、强隔离需求 |

**性能直觉**：容器只是被"圈住"的普通 Linux 进程——syscall、调度、内存分配走的都是宿主内核同一套路径，所以跟原生几乎一样。VM 每一次 syscall 都要从 Guest OS 转到 Host OS，开销在 Hypervisor 这一层。

**安全选择**：金融 / 多租户场景对容器逃逸顾虑大——可以选 **gVisor**（Google，用户态内核）或 **Kata Containers**（轻量 VM，微秒级启动），兼顾容器接口 + VM 安全。

---

## 六、生产踩坑

### 坑 1：JVM 容器内不识别 cgroup → OOMKill 反复重启

**现象**：Pod 配 `limits.memory: 2Gi`，JVM 启动几分钟后 `Killed`，K8s 重启 → 又被 Killed → CrashLoopBackOff。`kubectl logs` 看不到任何 OOM 异常。

**排查**：`kubectl describe pod` → `Last State: Terminated, Reason: OOMKilled, Exit Code: 137`（137 = 128 + 9 = SIGKILL）。

**根因**：`-Xmx` 没设、`UseContainerSupport` 没开（旧版 JDK 8u131）→ JVM 按宿主内存的 1/4 设默认堆 → 远超 cgroup 限额 → 内核 OOMKill。

**修复**：升 JDK 到 8u191+ + `-XX:MaxRAMPercentage=75` + 监控容器内存。**还要给 limits 留出非堆内存**（Metaspace / DirectByteBuffer / JIT codecache / 线程栈），生产建议 `MaxRAMPercentage=70~75` 留 25%~30% 给非堆。

### 坑 2：runc CVE-2019-5736 容器逃逸

**事件**：runc < 1.0-rc6 版本，攻击者在容器内覆写 `/proc/self/exe`（指向宿主上的 runc 二进制）→ 宿主下次执行 runc 时跑了攻击者代码 → **完整宿主 root 权限**。

**影响**：所有用旧 runc 的 Docker / containerd / Podman 全中招。

**修复**：升级 runc 到 1.0-rc6+；运行时启用 USER Namespace（容器内 root != 宿主 root）；用只读根文件系统（`--read-only`）。

**启示**：**容器隔离不是安全边界**——只是"进程边界"。多租户必须叠 gVisor / Kata / VM。

### 坑 3：容器内 `/proc/meminfo` 是宿主视图

**现象**：容器内跑 `top` / `free`，看到的是宿主机几百 G 内存而非 limits 的 2Gi。导致：
- JVM 错配堆（坑 1 的根因）
- Nginx `worker_connections` 按宿主 CPU 算（限不住）
- Go runtime 起 64 个 P（坑同 4.2）

**根因**：`/proc` 是 procfs，容器默认共享宿主的（Cgroup Namespace 隔的是 cgroup 路径，不是 /proc 内容）。

**修复**：
- JVM / Go 用 cgroup 感知库（UseContainerSupport / automaxprocs）
- 装 `lxcfs`：把 cgroup 限额"伪装"成 /proc 内容，对老应用透明（Nginx / Apache 这些不感知 cgroup 的）

### 坑 4：cgroup v1 内存统计不含 page cache

**现象**：监控显示容器内存 1.5G（接近 2Gi 限额）→ 业务报警 → 实际堆只用了 800M，剩下都是 page cache。但 v1 默认把 page cache 算进 `memory.usage_in_bytes`，且**回收 page cache 慢于内核 OOMKill 决策**——结果还是被 OOMKill。

**修复**：v1 看 `memory.stat` 里 `rss` + `swap`（排除 cache）；升 cgroup v2，统计更精确；监控用 container_memory_working_set_bytes（K8s OOMKill 真正参考的指标）。

### 坑 5：容器内时区错 / 日志全 UTC

**现象**：服务部署到 K8s 后，所有日志时间晚 8 小时，跟下游对账对不上。

**根因**：基础镜像（如 alpine / openjdk）默认时区 UTC。

**修复**：

```dockerfile
# 方案 A：镜像里固化（Alpine 需先装 tzdata）
RUN apk add --no-cache tzdata \
 && cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
 && echo "Asia/Shanghai" > /etc/timezone \
 && apk del tzdata     # 用完删，不增加镜像

# 方案 B：K8s yaml 注入环境变量（部分 JDK 应用够用）
env:
  - name: TZ
    value: Asia/Shanghai
```

---

## 七、面试高频追问

**Q1：容器和虚拟机的本质区别？**

A：**容器共享宿主内核，VM 各跑一份内核**。容器是"被 Namespace + Cgroups 圈起来的普通 Linux 进程"，syscall 直接走宿主内核；VM 是 Hypervisor 之上跑完整 Guest OS，每次 syscall 都要 Guest OS → Host OS。所以容器启动快（毫秒到秒级 vs 分钟级）、资源轻（MB vs GB），但隔离弱（共享内核 → 内核漏洞 = 容器逃逸）。**安全敏感场景上 gVisor / Kata 弥补**。

**Q2：Linux Namespace 有几种？容器各用了哪些？**

A：常用 6 种：**PID（进程号）/ NET（网络栈）/ MNT（挂载点）/ UTS（主机名）/ IPC（进程间通信）/ USER（用户 ID 映射）**。Linux 4.6+ 还加了 Cgroup Namespace、5.6+ 加 Time Namespace。Docker 默认开前 5 种；USER Namespace 默认不开（兼容性问题），生产强安全可手动开。**K8s Pod 内多容器默认共享 NET/IPC/UTS，不共享 PID 和 MNT**——这是 sidecar 模式可行的基础。

**Q3：Cgroups v1 和 v2 区别？**

A：**v1 多挂载点（每子系统独立）、v2 单一统一层级**。v2 解决了 v1 的几个痛点：① 子系统在不同层级里互不相关（v1 一个进程同时属于不同 cgroup 路径，难管理）；② 内存统计更准（v2 把 sock 内存也算进来）；③ 接口一致（cgroup.controllers 统一）。**K8s 1.25 GA 全面拥抱 v2，生产新集群默认 v2**。

**Q4：UnionFS / OverlayFS 怎么实现镜像分层？**

A：每个镜像层是一个**只读目录**（lowerdir，/var/lib/docker/overlay2/<id>/diff），多层按顺序叠（上覆盖下）；容器启动时再加一个**可写层**（upperdir）；OverlayFS 把它们 union mount 成 merged 视图。容器写文件时**写时复制（CoW）**：从 lower 复制整文件到 upper，改动在 upper 上完成。**收益**：N 个容器共享同一个镜像；**代价**：第一次写大文件慢、密集小文件 inode 爆。

**Q5：Docker 镜像 1.5G 怎么瘦身到 200M？**

A：① **多阶段构建**——Maven 镜像编译，最终镜像只用 jre-slim 拷 jar，丢掉构建期产物（最大头）；② **基础镜像换 Alpine / distroless**（Alpine 5MB / distroless 20MB / 标准 ubuntu 70MB）；③ **合并 RUN**（`RUN apt update && apt install ... && rm -rf /var/lib/apt/lists/*`，避免缓存进层）；④ **`.dockerignore`** 不要 COPY 整个项目；⑤ 删 `apt-get` 缓存、删测试文件。详见 [Dockerfile 与镜像优化](./Dockerfile与镜像优化.md)。

**Q6：容器逃逸有哪些途径？**

A：① **runc CVE-2019-5736** 这类运行时漏洞；② **特权容器**（`--privileged`）= 容器内有几乎全部 capability，能直接挂宿主磁盘 / 改宿主内核参数；③ **挂载宿主敏感路径**（如 `-v /:/host`）；④ **共享宿主 Namespace**（`--pid=host` / `--net=host`）；⑤ **内核漏洞**（共享内核 → 内核 0day = 全部容器沦陷）。**防御**：升级 runc / 关 privileged / 用 USER Namespace / 加 seccomp / AppArmor / 多租户上 gVisor 或 Kata。

**Q7：K8s 1.24 弃用 Docker，意味着什么？**

A：弃用的是 **dockerd 这个守护进程**作为 K8s 的运行时——K8s 直接通过 CRI 对接 containerd（dockerd 本质就是 containerd 的封装，绕了一圈）。**镜像不受影响**——OCI 标准跟 Docker / containerd 解耦，已有 Docker 镜像能直接跑。Docker 命令行（docker build / push）也没消失，只是 K8s 节点上不再运行 dockerd。**实际生产**：containerd 1.6+ 已经成为绝大多数 K8s 集群的运行时。

**Q8：Pod 里多个容器共享 PID Namespace 吗？**

A：**默认不共享**——K8s 设计上每个容器有自己的 PID 1，避免 sidecar 看到主容器进程破坏假设。可以通过 `spec.shareProcessNamespace: true` 显式共享，常用于：① 调试（用 sidecar exec 进去查主容器进程）；② 用 sidecar 做信号转发（解决 PID 1 不响应 SIGTERM 问题）。**默认共享的是 NET / IPC / UTS** —— 所以 Pod 内容器能用 localhost 互通、共享 SysV IPC、看到同一个 hostname。

**Q9：能在容器里再跑容器（DinD）吗？**

A：**能**，但有 trade-off：
- **Docker-in-Docker（DinD）**：父容器装 dockerd（需 `--privileged` 或 mount /var/run/docker.sock）。问题：嵌套 OverlayFS 性能差、安全风险大（特权容器）。CI 场景常用（GitLab CI、Jenkins）。
- **更优方案**：直接把宿主的 `/var/run/docker.sock` 挂进去（实际是"借用宿主 dockerd"，不是真嵌套）。
- **K8s 替代方案**：用 **kaniko / buildah / img** 在不需要特权的 Pod 里直接构建镜像，不依赖 dockerd。

**Q10：containerd / runc / Docker 怎么协作？**

A：**runc 是底层（OCI runtime-spec 实现），containerd 是上层**：
- runc：单个容器的实际"启动者"——调 `clone()` 创建 Namespace、写 cgroup 文件、`execve()` 跑应用，干完就退出
- containerd：长期守护进程——管镜像下载 / 解压、容器生命周期、快照（snapshotter）、批量调用 runc
- Docker（dockerd）：再上层——加 docker build / docker compose / docker push，本质委托 containerd 干活

K8s 1.24 后链路是 **kubelet → CRI → containerd → runc**，dockerd 被踢出。

**Q11：容器为什么"启动快"？快在哪？**

A：本质上**容器只是 fork+exec 一个进程**——不需要：① 启 BIOS / bootloader / kernel（VM 要）；② 装文件系统（镜像层已 mount）；③ 启 init / systemd / 多个守护进程（容器只跑应用本身）。耗时几乎全在：a) 镜像下载（首次拉取慢，分层缓存后增量很快）；b) 应用本身启动（JVM warmup 才是大头）。**典型容器进程启动 50ms 内完成**，VM 要 30 秒到几分钟。

**Q12：Cgroups 限制 CPU 和内存的本质？**

A：**CPU 是限速（throttle），内存是限死（kill）**：
- CPU 超了 → 进程被内核 CFS 调度器暂停，等下一个调度周期（典型 100ms）才能继续 → 表现为"应用变慢"，不会挂
- 内存超了 → 内核走 OOM 路径，按 oom_score 选最该杀的进程发 SIGKILL（137 退出码）→ 没机会清理资源、没日志
- **生产经验**：宁可让 CPU 限速也别让内存被 OOM——OOM 是"突然死亡"，CPU 只是"变慢"，告警有缓冲

---

## 八、答题模板（60 秒话术）

> 容器本质是 **被 Linux Namespace 和 Cgroups 圈起来的普通进程**，加上 UnionFS 做镜像分层——三件套全是内核能力，Docker 只是封装 + 镜像分发。
>
> **隔离靠 Namespace 6 类**：PID / NET / MNT / UTS / IPC / USER 各管一摊，让进程"看不到"外面。**资源限额靠 Cgroups**：v1 多挂载点、v2 统一层级；CPU 超了限速、内存超了 OOMKill（137 退出码）。**镜像分层靠 OverlayFS**：lowerdir 只读层 + upperdir 可写层 union mount，写时复制，N 个容器共享同一个镜像。
>
> **跟虚拟机的根本差别**：容器**共享宿主内核**，启动毫秒到秒级、镜像 MB 级、性能接近原生；VM 各跑一份 Guest OS，启动分钟级、镜像 GB 级、隔离更强。代价是**容器隔离不是安全边界**——内核漏洞 = 容器逃逸（runc CVE-2019-5736），多租户敏感场景叠 gVisor / Kata。
>
> **容器化生产 4 大坑**：① JVM 不识别 cgroup → 必加 `-XX:+UseContainerSupport -XX:MaxRAMPercentage=75`；② Go 不识别 cgroup CPU → 加 `automaxprocs` 库；③ 时区基础镜像默认 UTC → Dockerfile 里固化 Asia/Shanghai；④ 容器内 `/proc/meminfo` 是宿主视图，老应用要装 lxcfs 兜底。
>
> **运行时演进**：早期 dockershim 强行让 K8s 调 Docker；K8s 1.24 (2022) 删除 dockershim，直接走 **CRI → containerd → runc**——dockerd 退出 K8s 数据面，但镜像格式是 OCI 标准，原有镜像照跑不误。

---

## 九、相关文档

- 配套：[Dockerfile 与镜像优化](./Dockerfile与镜像优化.md) — 镜像分层与多阶段构建实操
- 配套：[Docker 网络](./Docker网络.md) — Network Namespace 之上的 bridge / veth / iptables
- 配套：[Docker 存储与数据卷](./Docker存储与数据卷.md) — UnionFS 之上的持久化方案
- 上层：[K8s 架构总览](./K8s架构总览.md) — kubelet 通过 CRI 调容器运行时
- 上层：[Pod 与生命周期](./Pod与生命周期.md) — Pause 容器 + Pod 内 Namespace 共享
- 联动：[JVM/jvm 参数](../JVM/jvm参数.md) — `UseContainerSupport` / `MaxRAMPercentage` 取舍
- 联动：[Network/网络 IO 模型](../Network/网络IO模型.md) — Network Namespace 之上的 epoll
