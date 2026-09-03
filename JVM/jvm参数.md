# JVM 参数

> 面试常问"你知道哪些 JVM 参数？"——纯背诵不是 senior 风格，要能区分**开发默认 / 生产推荐 / 调优探索**三档，并讲清每个参数解决的实际问题。
>
> 本篇结构：① 三类参数语法；② 内存参数；③ GC 参数（按 GC 收集器分组）；④ 监控 / 诊断参数；⑤ 真实生产配置模板（4 种典型场景）；⑥ JDK 8 / 11 / 17 默认值差异。

---

## 一、参数三大类

```
-标准参数              -X 非标准              -XX 非 stable
   ├─ -version           ├─ -Xms              ├─ -XX:+/-FeatureName  布尔
   ├─ -classpath         ├─ -Xmx              └─ -XX:Key=Value       键值
   └─ -verbose:gc        ├─ -Xmn
                         ├─ -Xss
                         └─ -Xloggc
```

| 类型 | 含义 | 兼容性 |
| --- | --- | --- |
| **`-`** 标准 | 所有 JVM 实现必须支持 | 严格保证向后兼容 |
| **`-X`** 非标准 | 默认 HotSpot 实现，但不强制 | 不保证向后兼容 |
| **`-XX:`** 非 stable | 实验/可调，可能随版本变化 | 不保证向后兼容 |

**`-XX:` 两种语法**：
```bash
-XX:+UseG1GC                # Boolean 开关：+ 表示开，- 表示关
-XX:MaxGCPauseMillis=200    # Key=Value
```

---

## 二、内存参数

### 2.1 堆

| 参数 | 含义 | 默认 | 生产建议 |
| --- | --- | --- | --- |
| `-Xms<size>` | 初始堆大小（= `-XX:InitialHeapSize`） | 物理内存 1/64 | 与 Xmx 相同 |
| `-Xmx<size>` | 最大堆大小（= `-XX:MaxHeapSize`） | 物理内存 1/4 | 容器内存 50%~70% |
| `-Xmn<size>` | 新生代大小（= `-XX:NewSize` + `-XX:MaxNewSize`） | 自动 | 不和 G1 一起用 |
| `-XX:NewRatio=2` | 老:新 = 2:1 | 2 | 一般默认 |
| `-XX:SurvivorRatio=8` | Eden:S0:S1 = 8:1:1 | 8 | 一般默认 |
| `-XX:MaxTenuringThreshold=15` | 晋升年龄 | 15 | 一般默认 |
| `-XX:PretenureSizeThreshold=1m` | 大对象直进老年代 | 0（不启用） | 大对象多时设 |

**关键经验**：
- **Xms = Xmx**：避免运行时堆动态伸缩 STW
- **G1 不要设 -Xmn**：G1 自动调新生代大小，手动设会限制 G1 弹性

### 2.2 栈

```bash
-Xss256k       # 单线程栈大小，默认 1m（32 位）/ 1m（64 位）
```

线程多的服务（Tomcat、Netty）调小到 `256k` 可以省大量内存：
- 1000 线程 × 1MB = 1GB；调到 256k = 256MB → 省 750MB

### 2.3 元空间（JDK 8+）

```bash
-XX:MetaspaceSize=256m            # 初次触发 GC 阈值
-XX:MaxMetaspaceSize=512m         # 上限（必设！）
-XX:CompressedClassSpaceSize=128m # 压缩类指针空间
-XX:MinMetaspaceFreeRatio=40      # 扩容下限
-XX:MaxMetaspaceFreeRatio=70      # 扩容上限
```

**强烈建议必设 MaxMetaspaceSize** —— 否则元空间无限涨，被 OS OOM Killer 杀。

### 2.4 直接内存

```bash
-XX:MaxDirectMemorySize=1g
```

不设默认 = -Xmx，容易掩盖直接内存泄漏。生产**显式设**便于排查。

### 2.5 压缩指针（默认开）

```bash
-XX:+UseCompressedOops             # 对象指针压缩（默认开）
-XX:+UseCompressedClassPointers    # 类指针压缩（默认开）
```

堆 > 32GB 自动关闭。**经验**：堆设 31GB 或 ≥ 48GB，避开 32-48GB 负优化区间。

---

## 三、GC 参数

### 3.1 启用 GC

```bash
-XX:+UseSerialGC          # 客户端单核
-XX:+UseParallelGC        # 吞吐优先（JDK 8 默认）
-XX:+UseG1GC              # G1（JDK 9+ 默认）
-XX:+UseZGC               # ZGC（JDK 11+ 实验，JDK 15+ 生产）
-XX:+UseShenandoahGC      # Shenandoah（OpenJDK 12+）
```

### 3.2 G1 参数（生产最常用）

```bash
# 停顿目标
-XX:MaxGCPauseMillis=200                    # 期望最大 STW（默认 200，不要 < 100）

# 并发线程
-XX:ParallelGCThreads=8                     # STW 阶段并行数（默认 = CPU 核数 ≤ 8）
-XX:ConcGCThreads=2                         # 并发标记线程（默认 ParallelGCThreads/4）

# Region
-XX:G1HeapRegionSize=4m                     # 1~32MB，2 的幂；不设自动算

# Mixed GC 触发
-XX:InitiatingHeapOccupancyPercent=45       # 老年代占比触发并发标记（默认 45）
-XX:+G1UseAdaptiveIHOP                      # 自适应 IHOP（默认开）

# Mixed GC 单次回收 Region
-XX:G1MixedGCCountTarget=8                  # 一轮 Mixed GC 分几次（默认 8）
-XX:G1OldCSetRegionThresholdPercent=10      # 单次最多回收老年代比例

# 新生代
-XX:G1NewSizePercent=5                      # 新生代最小占比
-XX:G1MaxNewSizePercent=60                  # 新生代最大占比

# evacuation 预留
-XX:G1ReservePercent=10                     # 预留 Region 比例（默认 10）

# 字符串去重
-XX:+UseStringDeduplication                 # 重复 String 共用 char[]
```

### 3.3 ZGC 参数

```bash
-XX:+UseZGC
-XX:ConcGCThreads=4
-XX:ZCollectionInterval=120                 # 主动 GC 间隔（秒）
-XX:+UseLargePages                          # 大页内存
```

### 3.4 GC 通用参数

```bash
-XX:+DisableExplicitGC                       # 禁用 System.gc() （默认未禁）
-XX:+ExplicitGCInvokesConcurrent             # System.gc() 改用并发模式（不禁的话用这个）
```

---

## 四、监控诊断参数

### 4.1 GC 日志

#### JDK 8（旧格式）

```bash
-XX:+PrintGCDetails
-XX:+PrintGCDateStamps
-XX:+PrintGCTimeStamps
-XX:+PrintGCApplicationStoppedTime
-Xloggc:/data/log/gc.log
-XX:+UseGCLogFileRotation
-XX:NumberOfGCLogFiles=10
-XX:GCLogFileSize=100M
```

#### JDK 9+（统一日志框架 Xlog）

```bash
# 标准生产配置
-Xlog:gc*,gc+heap=info,gc+phases=trace:file=/data/log/gc.log:time,uptime,level,tags:filecount=10,filesize=100M

# 简化版
-Xlog:gc*=info:file=/data/log/gc.log:time:filecount=10,filesize=100M

# 看更多细节
-Xlog:gc*=debug:file=/data/log/gc.log:time:filecount=10,filesize=100M
```

### 4.2 OOM 处理

```bash
-XX:+HeapDumpOnOutOfMemoryError                # OOM 时自动 dump
-XX:HeapDumpPath=/data/log/heap.hprof          # dump 路径
-XX:OnOutOfMemoryError="kill -9 %p"            # OOM 时执行命令（如杀进程让 Pod 重启）
-XX:+ExitOnOutOfMemoryError                    # OOM 直接退出（K8s 健康检查会重启）
-XX:+CrashOnOutOfMemoryError                   # OOM 写 core dump
```

### 4.3 飞行记录器（JFR，JDK 11+ 免费）

```bash
-XX:StartFlightRecording=duration=60s,filename=/tmp/recording.jfr
```

或运行时启动：
```bash
jcmd <pid> JFR.start duration=60s filename=/tmp/myrecording.jfr
```

→ 用 JDK Mission Control（JMC）打开分析。

### 4.4 NMT（Native Memory Tracking）

```bash
-XX:NativeMemoryTracking=summary           # 或 detail
```

运行时查看：
```bash
jcmd <pid> VM.native_memory summary
```

→ 排查直接内存 / 元空间 / Code Cache 等堆外内存。

### 4.5 JIT 诊断

```bash
-XX:+PrintCompilation                # 打印 JIT 编译信息
-XX:+UnlockDiagnosticVMOptions
-XX:+PrintInlining                   # 打印内联决策
-XX:+PrintAssembly                   # 打印汇编（需 hsdis）
```

---

## 五、生产配置模板

### 5.1 Spring Boot 微服务（4 核 / 4GB）

```bash
java \
  -server \
  -Xms4g -Xmx4g \
  -Xss512k \
  -XX:MetaspaceSize=256m -XX:MaxMetaspaceSize=512m \
  -XX:MaxDirectMemorySize=1g \
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=200 \
  -XX:ParallelGCThreads=4 \
  -XX:+UseStringDeduplication \
  -XX:+HeapDumpOnOutOfMemoryError \
  -XX:HeapDumpPath=/data/log/heap.hprof \
  -XX:+ExitOnOutOfMemoryError \
  -Xlog:gc*=info:file=/data/log/gc.log:time:filecount=10,filesize=100M \
  -jar app.jar
```

### 5.2 Kafka Broker（16 核 / 32GB）

```bash
KAFKA_JVM_PERFORMANCE_OPTS="\
  -Xms16g -Xmx16g \
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=20 \
  -XX:InitiatingHeapOccupancyPercent=35 \
  -XX:G1HeapRegionSize=16m \
  -XX:+ExplicitGCInvokesConcurrent \
  -XX:MaxInlineLevel=15 \
  -Djava.awt.headless=true"
```

### 5.3 Elasticsearch（数据节点，16GB 堆）

```bash
-Xms16g                                  # 必须 ≤ 31GB（压缩指针）
-Xmx16g
-XX:+UseG1GC                             # JDK 11+
-XX:G1ReservePercent=25
-XX:InitiatingHeapOccupancyPercent=30
-XX:+AlwaysPreTouch                      # 启动预触摸全部内存
-Djava.io.tmpdir=/tmp
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/data/heap.hprof
```

### 5.4 容器化部署（K8s + Pod 1GB 内存）

```bash
# JDK 10+ 自动识别容器内存
-XX:MaxRAMPercentage=75.0                 # 用 Pod 内存的 75%
-XX:InitialRAMPercentage=75.0
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200
-XX:+ExitOnOutOfMemoryError               # OOM 退出 → Pod 自愈
-XX:NativeMemoryTracking=summary
```

⚠️ **JDK 8 早期不识别容器** —— 必须显式 `-Xmx` 或升 8u191+。

---

## 六、版本默认值差异

| 参数 | JDK 8 | JDK 11 | JDK 17 |
| --- | --- | --- | --- |
| 默认 GC | Parallel | G1 | G1 |
| -Xmx 默认 | 物理内存 1/4 | 同 | 同 |
| MetaspaceSize 默认 | 21m | 21m | 21m |
| 容器感知 | 8u131+ 部分；8u191+ 完整 | ✅ | ✅ |
| ZGC | 无 | 实验 | 生产 |
| 偏向锁 | 默认开 | 默认开 | **默认关** |
| PrintGCDetails | 旧格式 | deprecated | 移除 |
| Xlog 统一日志 | 无 | ✅ | ✅ |
| JFR | 商业版 | **免费** | ✅ |

---

## 七、常用 jcmd / jinfo 命令

```bash
# jcmd 是瑞士军刀
jcmd <pid> VM.flags                    # 看所有 flag
jcmd <pid> VM.system_properties        # 系统属性
jcmd <pid> GC.heap_info                # 堆信息
jcmd <pid> GC.run                      # 触发 FullGC（慎用）
jcmd <pid> GC.class_histogram          # 类直方图
jcmd <pid> Thread.print                # 等价 jstack
jcmd <pid> JFR.start ...               # 启动 JFR
jcmd <pid> VM.native_memory summary    # NMT

# jinfo 看 / 改部分参数
jinfo -flags <pid>
jinfo -flag MaxGCPauseMillis <pid>
jinfo -flag +PrintGC <pid>             # 运行时开 GC 日志（仅可改的 flag）
```

---

## 八、生产踩坑

### 8.1 -Xms 与 -Xmx 不一致

启动时堆只到 -Xms，运行中需要扩容时频繁 STW。**生产恒等**。

### 8.2 -XX:MaxMetaspaceSize 不设

类加载泄漏 → 元空间无上限涨 → 进程被 OS OOM Killer 杀，**进程没留 hprof**。
**必设上限**：通常 256m~1g 起步。

### 8.3 K8s Pod 没设 Xmx

JDK 8u131 之前完全不识别容器，按宿主机内存算 → Pod 限 4GB，JVM 拿物理 64GB 的 1/4 = 16GB → OOM 被 K8s 杀。
**JDK 10+ 用 -XX:MaxRAMPercentage=75.0 自动适配**。

### 8.4 JDK 8 升 JDK 11 GC 日志参数全废

JDK 9 引入 `-Xlog`，JDK 11 把 `-XX:+PrintGCDetails` 等老参数 deprecated。**升级时必须改写日志参数**。

### 8.5 OnOutOfMemoryError 命令风险

```bash
-XX:OnOutOfMemoryError="kill -9 %p"
```

OOM 后 JVM 立刻 fork shell 执行命令——**fork 时如果堆 + 副本超过物理内存，会立刻被 OS 杀**，命令根本来不及执行。

→ K8s 环境用 `-XX:+ExitOnOutOfMemoryError` + Pod 重启更稳。

### 8.6 -Xmx 设了 32GB 反而比 31GB 内存少

压缩指针在堆 ≤ 32GB 时启用。设 32GB 临界，所有引用从 4B 变 8B → 内存膨胀，可用空间反而少。
**经验**：要么 ≤ 31GB，要么 ≥ 48GB。

---

## 九、面试高频追问

### Q1：-Xms 和 -Xmx 为什么要相同？

避免运行时堆动态伸缩——每次扩容 / 缩容触发 STW。生产恒等保证内存占用稳定。

### Q2：MetaspaceSize 不是上限？

不是！**MetaspaceSize 是初次触发 GC 的阈值，MaxMetaspaceSize 才是上限**。
不设 Max → 元空间可以涨到 OS 内存上限 → 进程被杀。

### Q3：怎么让 JVM 容器感知？

JDK 8u131+ 加 `-XX:+UseContainerSupport`（8u191+ 默认开）。
JDK 10+ 默认开，配 `-XX:MaxRAMPercentage` 设占比。

### Q4：为什么用 Xss256k 不用默认 1m？

线程多时省大量内存——每线程栈 1m × 1000 线程 = 1GB；256k × 1000 = 256MB。Web 服务器、消息队列实例非常划算。

### Q5：怎么排查直接内存泄漏？

```bash
-XX:NativeMemoryTracking=detail
jcmd <pid> VM.native_memory baseline
# 跑一段时间
jcmd <pid> VM.native_memory diff
```

### Q6：System.gc() 该不该禁用？

看场景：
- 直接内存大量使用（DirectByteBuffer），DirectByteBuffer 的 Cleaner 依赖 FullGC 触发——禁了堆外不释放
- **推荐**：`-XX:+ExplicitGCInvokesConcurrent` 改用并发，不全 STW

### Q7：JDK 17 默认 GC 还是 G1？

是。JDK 9 起 G1 默认，目前 JDK 17 / 21 仍是 G1 默认。
**ZGC** 在 JDK 15 才生产可用，JDK 21 引入分代 ZGC 但**不是默认**。

### Q8：GC 日志怎么开？

JDK 8：`-Xloggc:/path/gc.log -XX:+PrintGCDetails -XX:+PrintGCDateStamps`
JDK 9+：`-Xlog:gc*=info:file=/path/gc.log:time:filecount=10,filesize=100M`

### Q9：什么是 JFR？

Java Flight Recorder，低开销的运行时数据采集（GC、JIT、线程、堆、IO 等）。
JDK 11+ 完全免费，启动加 `-XX:StartFlightRecording=...` 或运行时 `jcmd ... JFR.start`。
用 JDK Mission Control（JMC）分析。

### Q10：怎么禁用偏向锁？JDK 17 默认怎么做？

```bash
-XX:-UseBiasedLocking
```

JDK 15+ **默认关闭** —— 生产 JIT 优化进步 + 代码大量用 ConcurrentXxx 后，偏向锁收益越来越小。

---

## 十、答题模板（60 秒话术）

> JVM 参数分三类：**`-` 标准 / `-X` 非标准 / `-XX:` 实验**。常用三个语法：开关 `-XX:+/-Name`、键值 `-XX:Key=Value`、带单位 `-Xmx2g`。
>
> **内存核心**：`-Xms`/`-Xmx`（堆大小恒等）、`-Xss`（栈，线程多调小）、`-XX:MaxMetaspaceSize`（**必设上限**防类泄漏）、`-XX:MaxDirectMemorySize`（堆外）。
>
> **GC**：JDK 8 默认 Parallel，**JDK 9+ 默认 G1**——`-XX:+UseG1GC -XX:MaxGCPauseMillis=200` 三件套。大堆低延迟用 ZGC。
>
> **必备线上配置**：`-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=...` + `-XX:+ExitOnOutOfMemoryError`（K8s 自愈）+ GC 日志（`-Xlog` JDK 9+）。
>
> **容器化**：JDK 10+ 用 `-XX:MaxRAMPercentage=75.0` 自动按 Pod 内存算；JDK 8u191+ 才完整支持容器感知。
>
> **诊断神器**：`jcmd` 一把梭——VM.flags、GC.heap_info、Thread.print、JFR.start、VM.native_memory。

---

## 十一、相关文档

- [内存区域](./内存区域.md) — 内存参数对应的区域
- [垃圾回收](./垃圾回收.md) — GC 算法基础
- [G1垃圾回收器](./G1垃圾回收器.md) — G1 参数详解
- [收集器全景](./收集器全景.md) — 不同 GC 选型
- [JVM 调优](./jvm调优.md) — OOM 排查实战
- [线上问题排查](./线上问题排查.md) — jcmd / jstack / jmap 命令
