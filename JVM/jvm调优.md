# JVM 调优实战

> 调优 = **指标驱动**——不是凭感觉调，是按吞吐 / 延迟 / 内存占用三大指标逐步逼近目标。
>
> 本篇解决：① 调优心法（什么时候不该调）；② 三大指标与权衡；③ 6 步调优流程；④ 真实案例（OOM / FullGC 频繁 / GC 延迟抖动 / CPU 飙高）；⑤ 配置基线模板。
>
> 配套：[线上问题排查](./线上问题排查.md)（jstack / jmap / arthas）、[JVM 参数](./jvm参数.md)、[垃圾回收](./垃圾回收.md)。

---

## 一、调优心法

### 1.1 不要为了调优而调优

> **80% 的"GC 问题"实际上是代码问题**——内存泄漏、大对象、线程数失控、序列化爆炸——**先排查业务代码**。

调优的正确姿势：
1. 先**度量**（指标 + 日志 + dump）
2. 再**找瓶颈**（FullGC？YGC 频繁？哪段代码？）
3. 最后**改参数**

调参数前必须能回答：
- 当前指标是什么？
- 目标指标是什么？
- 为什么这个参数能改善？

### 1.2 默认配置已经很好

JDK 9+ 的 G1 + 默认参数能 cover 80% 业务场景。**没问题不要乱动 GC 参数**——尤其是 IHOP、Region 大小这种深水区。

调整顺序（保守 → 激进）：
1. 堆大小（-Xmx / -Xms）
2. GC 选型（默认 G1 → 极致延迟 ZGC）
3. 元空间上限（-XX:MaxMetaspaceSize）
4. 监控 / 诊断参数
5. **才是** GC 内部参数（IHOP / MaxGCPauseMillis）

---

## 二、三大调优指标

```
吞吐量 (Throughput)
   定义：用户代码运行时间 / 总时间
   公式：1 - GC时间 / 总时间
   目标：≥ 99% （GC 占比 < 1%）
   
延迟 (Latency / Pause Time)
   定义：单次 STW 时长
   目标：P99 < 200ms（一般业务）/ < 10ms（金融实时）
   
内存占用 (Footprint)
   定义：JVM 占的物理内存
   含堆 + 元空间 + 直接内存 + 线程栈 + Code Cache + GC 元数据
```

**三角不可能**：吞吐 / 延迟 / 内存——通常只能优先两个。

| 业务 | 优先 |
| --- | --- |
| 批处理 / 离线 | 吞吐 + 内存 |
| Web 服务 | 延迟 + 吞吐 |
| 金融实时 | 延迟 + 内存 |
| 大缓存 | 内存 + 延迟 |

---

## 三、调优 6 步流程

```
1. 监控 → 看指标
   ├─ jstat -gcutil <pid> 1000        实时 GC
   ├─ Prometheus + Grafana            长期趋势
   └─ APM (SkyWalking / Pinpoint)     业务延迟分布
       │
       ▼
2. 收集 → GC 日志 + dump
   ├─ -Xlog:gc*=info:file=gc.log
   └─ jmap -dump:format=b,file=heap.hprof
       │
       ▼
3. 分析 → 找瓶颈
   ├─ GCViewer / GCEasy: GC 日志可视化
   ├─ MAT / JProfiler: heap dump 分析支配树
   └─ Arthas: 在线诊断
       │
       ▼
4. 假设 → 写下根因
   "XX 类对象太多，原因是缓存没设上限"
       │
       ▼
5. 修复 → 改代码 or 改参数
   ├─ 优先改代码（修内存泄漏 / 拆大对象）
   └─ 必要时改参数（堆增大 / 换 GC）
       │
       ▼
6. 验证 → 灰度 + 压测
   ├─ 灰度发布 1 个实例对比指标
   └─ 压测对比 P99 / 吞吐 / 内存曲线
```

> 不要跳步——见过太多"直接改 IHOP" 然后老年代堵死 FullGC 的事故。

---

## 四、典型场景实战

### 4.1 OOM：Java heap space

#### 现象
```
Exception in thread "main" java.lang.OutOfMemoryError: Java heap space
```

#### 排查链路

```bash
# ① 看是不是有 dump
ls -la /data/log/heap.hprof
# 没有 → 设 -XX:+HeapDumpOnOutOfMemoryError 等下次

# ② 看类直方图（live 只算可达对象）
jmap -histo:live <pid> | head -30
#  num     #instances         #bytes  class name
#    1:       2456789      590049336  byte[]
#    2:        923456       73876480  java.lang.String

# ③ dump
jmap -dump:format=b,file=/data/log/heap.hprof <pid>

# ④ 用 MAT 打开
#   - Leak Suspects 报告：自动列嫌疑大对象
#   - Dominator Tree：看支配关系
#   - Histogram → 按类排序 → Path to GC Roots
```

#### 常见根因

| 根因 | 现象 | 修复 |
| --- | --- | --- |
| 集合无界增长 | HashMap / ArrayList 越堆越多 | 加 LRU + 上限（Caffeine） |
| ThreadLocal 不清理 | 线程池里 entry 永生 | finally 中 remove() |
| 缓存无上限 | 全量数据进 ConcurrentHashMap | 改 Caffeine + maximumSize |
| 监听器 / 回调泄漏 | 每次注册不注销 | dispose 时 unregister |
| 静态集合持有大对象 | static List 不清理 | 重构持有方式 |
| 大对象 / 一次性查询 | 一次 select 100w 行 | 分页 + 流式处理 |

#### 案例：缓存没上限

```java
private static final Map<String, User> CACHE = new ConcurrentHashMap<>();

public User get(String id) {
    return CACHE.computeIfAbsent(id, k -> loadFromDB(k));   // ⚠️ 永久增长
}
```

**修复**（用 Caffeine）：
```java
private static final Cache<String, User> CACHE = Caffeine.newBuilder()
    .maximumSize(10_000)
    .expireAfterWrite(10, TimeUnit.MINUTES)
    .build();
```

### 4.2 OOM：Metaspace

#### 现象
```
java.lang.OutOfMemoryError: Metaspace
```

#### 排查
```bash
# 看类加载情况
jcmd <pid> GC.class_stats | head -30
jcmd <pid> VM.classloader_stats

# 看是不是反复加载
-XX:+TraceClassLoading
-XX:+TraceClassUnloading
```

#### 常见根因

1. **CGLIB / Javassist** 大量动态生成代理类（Spring AOP / MyBatis）
2. **Groovy / Nashorn** 脚本反复编译
3. **Tomcat 热部署** ClassLoader 泄漏
4. **MaxMetaspaceSize 不设** + 业务自然类加载多

#### 修复

```bash
-XX:MaxMetaspaceSize=512m              # 必设上限
-XX:+CMSClassUnloadingEnabled          # CMS 时启用类卸载
```

代码层：
- 反射 / Class.forName 缓存 Class，避免重复加载
- 减少动态代理（用编译时代码生成替代）

### 4.3 频繁 FullGC

#### 现象
```bash
jstat -gcutil <pid> 1000
# S0     S1     E      O      M      CCS    YGC   YGCT   FGC   FGCT     GCT
# 0.00  85.71  100.00  98.34  92.45  88.12  450   12.345  120  45.678   58.023
                              ↑                          ↑
                            老年代爆满                 FullGC 120 次
```

#### 排查
```bash
# ① GC 日志
tail -f /data/log/gc.log
# 看 FullGC 间隔、回收前后老年代占用

# ② 看大对象
jmap -histo:live <pid> | head -30

# ③ dump 分析
jmap -dump:format=b,file=heap.hprof <pid>
```

#### 三种典型根因

**① 内存泄漏**
- FullGC 后老年代回收不下去（前 95% 后 90%）
- → MAT 找泄漏

**② 老年代不够 / 大对象多**
- FullGC 后老年代回收充分（前 95% 后 30%），但一会儿又满
- → 增大 -Xmx 或调 PretenureSizeThreshold

**③ System.gc() 调用**
- 固定时间 FullGC，与业务无关
- → `-XX:+DisableExplicitGC` 或 `-XX:+ExplicitGCInvokesConcurrent`

### 4.4 GC 延迟抖动（P99 飙到秒级）

#### 现象
- 大多数请求 < 50ms
- P99 突然 1-3s
- 业务无突发

#### 排查
```bash
-Xlog:gc*,gc+phases=trace:file=gc.log:time
# 看哪个阶段超长——
# Initial Mark / Remark / Cleanup 都不应该长
# Evacuation 长 → 大对象 / Region 设小
```

#### 常见根因

| 根因 | 表现 | 修复 |
| --- | --- | --- |
| Humongous 大对象 | 频繁 Humongous Allocation | -XX:G1HeapRegionSize=16m |
| MaxGCPauseMillis 太小 | GC 频繁 | 调到 200ms（默认） |
| 老年代涨太快 | Mixed GC 跟不上 | 降低 IHOP / 升 JDK 17+ |
| 大对象进 Survivor | YGC 时长 | 增大 Survivor / PretenureSizeThreshold |
| Swap 触发 | 进程瞬间冻结 | 关 swap / 设 swappiness=0 |

### 4.5 CPU 飙高

> 不一定是 GC 引起，但 GC 是常见嫌疑之一。

详见 [线上问题排查 - CPU 飙高](./线上问题排查.md#一cpu-飙高排查标准三连)。

```bash
# 1. 找占 CPU 高的线程
top -Hp <pid>           # 看哪条线程吃 CPU
printf '%x\n' <tid>     # 转 16 进制
jstack <pid> | grep <hex_tid> -A 30
# 看线程在干啥
# 如果都是 GC 线程 → GC 问题，按 4.3 / 4.4 排
# 如果是业务线程 → 看代码（死循环 / 复杂正则 / 大集合操作）
```

---

## 五、调优配置基线（按场景）

### 5.1 通用 Web 服务（4 核 / 4GB Pod）

```bash
-server
-Xms3g -Xmx3g
-Xss512k
-XX:MetaspaceSize=128m -XX:MaxMetaspaceSize=256m
-XX:MaxDirectMemorySize=512m
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200
-XX:+ParallelRefProcEnabled
-XX:+UseStringDeduplication
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/data/log/heap.hprof
-XX:+ExitOnOutOfMemoryError
-Xlog:gc*=info:file=/data/log/gc.log:time:filecount=10,filesize=100M
```

### 5.2 大堆缓存服务（16 核 / 32GB）

```bash
-server
-Xms31g -Xmx31g                          # 不超 32GB（压缩指针）
-Xss512k
-XX:MaxMetaspaceSize=512m
-XX:MaxDirectMemorySize=4g
-XX:+UseG1GC
-XX:MaxGCPauseMillis=100
-XX:G1HeapRegionSize=16m
-XX:InitiatingHeapOccupancyPercent=40
-XX:G1ReservePercent=15
-XX:+UseStringDeduplication
-XX:+ParallelRefProcEnabled
-XX:+HeapDumpOnOutOfMemoryError
-Xlog:gc*=info:file=/data/log/gc.log:time:filecount=20,filesize=100M
```

### 5.3 极致低延迟（高频交易，JDK 17+）

```bash
-Xms16g -Xmx16g
-XX:+UseZGC
-XX:+UnlockDiagnosticVMOptions
-XX:+UseLargePages
-XX:+AlwaysPreTouch                     # 启动预触摸内存
-XX:ConcGCThreads=4
-XX:NativeMemoryTracking=summary
-XX:+HeapDumpOnOutOfMemoryError
```

### 5.4 批处理 / Spark Driver

```bash
-Xms8g -Xmx8g
-XX:+UseParallelGC                      # 吞吐优先
-XX:ParallelGCThreads=8
-XX:+HeapDumpOnOutOfMemoryError
```

---

## 六、不要做的事

### 6.1 不要随便 -XX:+DisableExplicitGC

DirectByteBuffer 的 Cleaner 依赖 FullGC 触发——禁了 System.gc() 后，大量直接内存分配会撑爆。
**替代**：`-XX:+ExplicitGCInvokesConcurrent`（让 System.gc 走并发）。

### 6.2 不要把 MaxGCPauseMillis 设很小

`-XX:MaxGCPauseMillis=50` → G1 单次能回收的 Region 太少 → 频繁 GC → 总停顿反而长。
**默认 200 不要乱动**。

### 6.3 不要在 32-48GB 区间设堆

压缩指针 32GB 上限——堆 33GB → 引用从 4B 变 8B → 堆膨胀但可用空间不增。
**要么 ≤ 31GB，要么 ≥ 48GB**。

### 6.4 不要禁用 GC 日志

线上事故没 GC 日志 = 瞎子。**所有线上必开**。

### 6.5 不要忘记设元空间上限

类加载泄漏 → 元空间无限涨 → 进程被 OS Killer 杀（**没留 hprof**）。
`-XX:MaxMetaspaceSize=512m` 必设。

---

## 七、调优工具

| 工具 | 用途 | 推荐度 |
| --- | --- | --- |
| **jcmd** | 万能瑞士军刀（替代 jstack/jmap/jinfo） | ⭐⭐⭐⭐⭐ |
| **jstat** | 实时 GC 指标 | ⭐⭐⭐⭐⭐ |
| **MAT** | heap dump 分析 | ⭐⭐⭐⭐⭐ |
| **GCViewer / GCEasy** | GC 日志可视化 | ⭐⭐⭐⭐ |
| **JFR + JMC** | 飞行记录器（JDK 11+ 免费） | ⭐⭐⭐⭐⭐ |
| **Arthas** | 在线诊断（不重启） | ⭐⭐⭐⭐⭐ |
| **JProfiler** | 商业级 profiler | ⭐⭐⭐⭐ |
| **async-profiler** | 火焰图 | ⭐⭐⭐⭐ |

详见 [线上问题排查](./线上问题排查.md)。

---

## 八、面试高频追问

### Q1：怎么判断 JVM 需要调优？

看监控指标：
- 吞吐量 < 95% → 调
- P99 延迟超 SLA → 调
- 频繁 FullGC（> 每小时一次）→ 调
- OOM 已发生 → 必调

不满足以上不要乱动——默认配置往往最优。

### Q2：怎么发现内存泄漏？

四步：
1. 监控老年代占用趋势——FullGC 后回收不充分（前后差 < 30%）
2. jmap -histo 看是不是某类对象异常多
3. jmap dump + MAT
4. 看支配树 + Path to GC Roots 找根因

### Q3：FullGC 频繁怎么办？

按根因分三类：
- **内存泄漏** → MAT 找泄漏，修代码
- **老年代不够** → 增大 -Xmx 或换 G1
- **System.gc()** → `-XX:+ExplicitGCInvokesConcurrent`

### Q4：堆设多大合适？

- 用容器内存 50%~70%（留给元空间 / 直接内存 / 线程栈）
- 容器化用 `-XX:MaxRAMPercentage=75.0`
- 不超 31GB（压缩指针上限）

### Q5：线程数怎么估？

线程数 ≈ CPU × (1 + IO 时间 / CPU 时间)
- 计算密集（IO 少）：CPU + 1
- IO 密集（DB / RPC）：2 × CPU 起步
- 千线程级服务：调小 -Xss 到 256k 省内存

### Q6：GC 延迟抖动 P99 飙高怎么排查？

```bash
-Xlog:gc*,gc+phases=trace
```

看哪个 GC 阶段超长——Evacuation 长可能 Humongous 大对象，Mixed GC 慢可能老年代涨太快。

### Q7：怎么对比调优前后效果？

灰度 + 压测：
- 灰度：1 个实例新参数，对比 GC 日志、QPS、P99
- 压测：相同压力下对比 GC 总停顿、吞吐曲线
- **观察 24 小时以上**——某些问题（如老年代缓慢涨）短时间看不出

### Q8：JFR 和 jstack 区别？

- jstack：瞬时快照，看线程当前在做什么
- JFR：连续录制（GC、JIT、IO、线程切换、堆分配热点），开销 < 2%

JFR 更适合长期诊断。

---

## 九、答题模板（90 秒话术）

> JVM 调优**先度量再动手**——80% 的"GC 问题"实际是代码问题（内存泄漏、大对象、线程数失控）。
>
> 三大指标：**吞吐 / 延迟 / 内存占用**，三角不可能，按业务优先级取舍。
>
> 调优 6 步：**监控 → 收集（GC 日志 + dump）→ 分析（GCEasy / MAT）→ 假设根因 → 修复（先代码后参数）→ 灰度验证**。
>
> 典型场景：
> ① **OOM** → jmap -histo + dump + MAT 找泄漏类 → Path to GC Roots 找持有者；
> ② **频繁 FullGC** → 看 FullGC 后老年代回收率，区分内存泄漏 / 老年代不够 / System.gc()；
> ③ **GC 延迟抖动** → -Xlog:gc+phases=trace 看哪个阶段超长，Humongous 大对象是常见根因；
> ④ **元空间 OOM** → 必设 `-XX:MaxMetaspaceSize`，排查动态类生成。
>
> **必备线上参数**：堆恒等（Xms=Xmx）、元空间上限、HeapDumpOnOutOfMemoryError、ExitOnOutOfMemoryError（K8s 自愈）、GC 日志（-Xlog 滚动）。
>
> 不要踩的坑：MaxGCPauseMillis 设 < 100、堆设 32-48GB、忘设元空间上限、随手 DisableExplicitGC。

---

## 十、相关文档

- [线上问题排查](./线上问题排查.md) — jstack / jmap / arthas 命令手册
- [JVM 参数](./jvm参数.md) — 参数完整清单
- [垃圾回收](./垃圾回收.md) — GC 算法基础
- [G1垃圾回收器](./G1垃圾回收器.md) — G1 调优
- [收集器全景](./收集器全景.md) — GC 选型
- [内存区域](./内存区域.md) — 各区域 OOM
