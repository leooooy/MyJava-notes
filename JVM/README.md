# JVM 面试模块

> 大厂后端面试的"必考四大件"之一（Redis / MySQL / **JVM** / 并发）。
>
> 本模块按 **内存 → 类加载 → GC → 编译优化 → 调优实战** 五层组织，每篇都按 senior 标准写：原理 + 取舍 + 面试追问 + 生产踩坑 + 答题模板。
>
> 共 14 篇。可以按"推荐学习路径"按序读，也可以按"高频题映射"直接跳。

---

## 一、模块导航

### 内存（5 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [JVM 运行时数据区](./内存区域.md) | 5 大区 + 直接内存、PermGen→Metaspace 演进、字符串常量池搬家史 |
| [对象在内存中的布局](./对象在内存中的布局.md) | 三段式（头/数据/填充）、Mark Word 64 位结构、压缩指针、对象创建 7 步 |
| [JVM 内存与 OS：MMU / 虚拟内存](./JVM内存与OS-MMU虚拟内存.md) | MMU + TLB（cache）、缺页中断、RSS/VSZ/Committed/Reserved 四指标、HugePage 直觉 |
| [Java 内存模型 JMM](./内存模型.md) | 主内存/工作内存、三大特性、重排序、happens-before 8 条规则 |
| [内存屏障](./内存屏障.md) | 4 种屏障语义、x86 vs ARM、volatile/synchronized/final 的屏障落点 |

### 类加载（2 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [类加载机制](./类加载机制.md) | 5 阶段（加载/验证/准备/解析/初始化）、`<clinit>` vs `<init>`、初始化顺序 |
| [双亲委派机制](./双亲委派机制.md) | 流程 + 设计动机、SPI / Tomcat / OSGi 三大打破场景 |

### 垃圾回收（3 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [垃圾回收](./垃圾回收.md) | 可达性分析、四种引用、三大算法、分代假说、卡表、三色标记、漏标 |
| [G1 垃圾回收器](./G1垃圾回收器.md) | Region 化、Mixed GC、可预测停顿、RSet、SATB、生产坑 |
| [收集器全景](./收集器全景.md) | 9 大收集器、演进时间轴、ZGC 染色指针、选型决策树 |

### 编译与运行时优化（1 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [JIT 与逃逸分析](./JIT与逃逸分析.md) | C1/C2/Graal 分层编译、热点探测、OSR、内联、逃逸分析、标量替换、锁消除、Code Cache、反优化、AOT |

### 参数与实战（3 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [JVM 参数](./jvm参数.md) | 三类语法、内存/GC/监控参数全清单、4 种生产配置模板 |
| [JVM 调优](./jvm调优.md) | 三大指标、6 步调优流程、OOM/FullGC/延迟抖动/CPU 飙高案例 |
| [线上问题排查](./线上问题排查.md) | jcmd/jstat/jmap/jstack 速查、arthas/JFR/火焰图、6 类故障排查 |

---

## 二、面试高频题 → 文档映射

被问到这些题，直接跳到对应文档：

### 内存

| 高频题 | 跳转 |
| --- | --- |
| JVM 内存模型？画一下？ | [运行时数据区](./内存区域.md#一全景图) |
| 哪些区线程私有？哪些共享？ | [运行时数据区](./内存区域.md#一全景图) |
| 程序计数器为什么不抛 OOM？ | [运行时数据区 - PC](./内存区域.md#21-程序计数器pc-register) |
| StackOverflowError 和 OOM 区别？ | [运行时数据区 - 异常类型](./内存区域.md#222-异常类型) |
| 永久代和元空间区别？为什么要换？ | [运行时数据区 - 演进](./内存区域.md#43-永久代--元空间的演进必考) |
| 字符串常量池在哪？JDK 7 为什么搬到堆？ | [运行时数据区 - 字符串常量池](./内存区域.md#52-字符串常量池搬家史) |
| 直接内存属于堆吗？怎么释放？ | [运行时数据区 - 直接内存](./内存区域.md#六直接内存direct-memory) |
| 一个 Object 对象多大？ | [对象布局](./对象在内存中的布局.md#一对象的三段式布局hotspot-64-位) |
| Mark Word 里都存什么？ | [对象布局 - Mark Word](./对象在内存中的布局.md#21-mark-word8-字节) |
| 调过 hashCode 还能用偏向锁吗？ | [对象布局](./对象在内存中的布局.md#213-调-hashcode-之后的副作用高频追问) |
| 压缩指针为什么 4B 能寻址 32GB？ | [对象布局 - 压缩指针](./对象在内存中的布局.md#三压缩指针compressedoops) |
| 对象怎么创建？new 的字节码做什么？ | [对象布局 - 创建](./对象在内存中的布局.md#五对象创建的-7-步必背) |
| 对象访问用句柄还是直接指针？ | [对象布局](./对象在内存中的布局.md#六对象的访问定位) |
| MMU / TLB / 页表是什么？ | [MMU / 虚拟内存](./JVM内存与OS-MMU虚拟内存.md#二mmu硬件地址翻译单元) |
| 什么是局部性原理？为什么 cache 都靠它？ | [MMU / 虚拟内存](./JVM内存与OS-MMU虚拟内存.md#三局部性原理所有-cache-能-work-的根本) |
| TLB 和 CPU 的 L1/L2/L3 cache 是一回事吗？ | [MMU / 虚拟内存](./JVM内存与OS-MMU虚拟内存.md#四tlbmmu-的-cache) |
| 缺页中断有几种？major / minor 区别？ | [MMU / 虚拟内存](./JVM内存与OS-MMU虚拟内存.md#五缺页中断page-fault) |
| RSS / VSZ / Committed / Reserved 怎么区分？ | [MMU / 虚拟内存](./JVM内存与OS-MMU虚拟内存.md#六jvm-内存四指标高频混淆) |
| 为什么 JVM RSS 经常大于 -Xmx？ | [MMU / 虚拟内存 - Q9](./JVM内存与OS-MMU虚拟内存.md#q9jvm-rss-经常大于--xmx钱去哪了) |
| HugePage 为什么能提速？ | [MMU / 虚拟内存 - Q6](./JVM内存与OS-MMU虚拟内存.md#q6hugepage-为什么能提速) |
| -Xms=-Xmx 会立刻占满物理内存吗？ | [MMU / 虚拟内存 - Q7](./JVM内存与OS-MMU虚拟内存.md#q7-xms---xmx-设相等会立即占满物理内存吗) |

### 内存模型 / 并发

| 高频题 | 跳转 |
| --- | --- |
| JMM 是什么？和内存区域区别？ | [JMM](./内存模型.md#一为什么要有-jmm) |
| 什么是 happens-before？8 条规则？ | [JMM](./内存模型.md#五happens-before核心) |
| volatile 原理？保证什么不保证什么？ | [JMM](./内存模型.md#六volatile-完整语义) |
| 为什么 i++ 不是原子的？ | [运行时数据区](./内存区域.md#222-i-不是原子操作高频追问) |
| DCL 单例为什么要 volatile？ | [JMM](./内存模型.md#41-经典反例dcl-单例必须用-volatile) |
| 重排序有几种？怎么禁止？ | [JMM](./内存模型.md#四重排序的三种来源) |
| synchronized 怎么保证可见性？ | [JMM](./内存模型.md#七synchronized-的-jmm-语义) |
| final 字段为什么不需要 volatile？ | [JMM](./内存模型.md#八final-的-jmm-语义高频追问) |
| 内存屏障有几种？ | [内存屏障](./内存屏障.md#二四种内存屏障) |
| x86 和 ARM 内存模型差别？ | [内存屏障](./内存屏障.md#三不同-cpu-的屏障强度) |
| volatile 写后为什么要 StoreLoad？ | [内存屏障](./内存屏障.md#51-volatile-读--写) |

### 类加载

| 高频题 | 跳转 |
| --- | --- |
| 类加载分几个阶段？ | [类加载](./类加载机制.md#一类的生命周期) |
| 准备阶段会赋值吗？ | [类加载 - 准备](./类加载机制.md#23-准备preparation) |
| 哪些场景触发类初始化？ | [类加载 - 触发](./类加载机制.md#252-类初始化的-6-种触发场景主动引用) |
| `<clinit>` 和 `<init>` 区别？ | [类加载](./类加载机制.md#三clinit-vs-init) |
| 父子类静态块、构造器执行顺序？ | [类加载](./类加载机制.md#31-完整初始化顺序必背) |
| 双亲委派？为什么要这样？ | [双亲委派](./双亲委派机制.md#二为什么需要双亲委派) |
| 哪些场景打破了双亲委派？ | [双亲委派](./双亲委派机制.md#三双亲委派的三个例外必考) |
| Tomcat 为什么打破双亲委派？ | [双亲委派 - Tomcat](./双亲委派机制.md#32-tomcat-的-webapp-classloader) |
| JDBC 驱动怎么加载？ | [双亲委派 - SPI](./双亲委派机制.md#31-jdbc-驱动--spi-机制) |
| Class.forName 和 ClassLoader.loadClass 区别？ | [类加载](./类加载机制.md#63-classforname-vs-classloaderloadclass) |
| 两个 ClassLoader 加载的同一个类是同一个吗？ | [类加载](./类加载机制.md#43-类的唯一性) |

### 垃圾回收

| 高频题 | 跳转 |
| --- | --- |
| 怎么判断对象是垃圾？ | [GC - 可达性分析](./垃圾回收.md#一判断对象存活引用计数-vs-可达性分析) |
| GC Roots 包括哪些？ | [GC](./垃圾回收.md#13-gc-roots-包括哪些必背) |
| 为什么不用引用计数？ | [GC](./垃圾回收.md#11-引用计数reference-counting) |
| 强软弱虚四种引用区别？ | [GC](./垃圾回收.md#二四种引用强度高频题) |
| ThreadLocal 为什么用弱引用？ | [GC - 弱引用](./垃圾回收.md#22-弱引用weakreference) |
| 三大算法？怎么用在新生代和老年代？ | [GC](./垃圾回收.md#三三大经典-gc-算法) |
| 为什么 Eden:S0:S1 = 8:1:1？ | [GC](./垃圾回收.md#321-eden--2-survivor-优化) |
| 卡表是什么？解决什么问题？ | [GC](./垃圾回收.md#42-跨代引用假说) |
| 什么是 Stop The World？为什么要安全点？ | [GC](./垃圾回收.md#五stop-the-worldstw) |
| 三色标记法的漏标怎么解决？ | [GC](./垃圾回收.md#63-漏标问题必考) |
| FullGC 触发条件？ | [GC](./垃圾回收.md#触发-fullgc-的常见原因) |
| CMS 为什么被淘汰？ | [GC](./垃圾回收.md#71-cms-的问题为什么被淘汰) |
| G1 和 CMS 区别？ | [G1](./G1垃圾回收器.md#九g1-vs-cms-对比必考) |
| 什么是 Mixed GC？ | [G1](./G1垃圾回收器.md#四mixed-gc-流程必背) |
| Region 大小怎么定？ | [G1](./G1垃圾回收器.md#一g1-是什么) |
| 什么是 Humongous Region？ | [G1](./G1垃圾回收器.md#22-大对象处理humongous) |
| G1 怎么处理跨 Region 引用？ | [G1 - RSet](./G1垃圾回收器.md#六remember-setrset-g1-跨代引用机制) |
| G1 怎么实现可预测停顿？ | [G1](./G1垃圾回收器.md#五可预测停顿模型) |
| ZGC 染色指针是什么？ | [收集器全景](./收集器全景.md#82-染色指针原理) |
| ZGC 和 G1 区别？ | [收集器全景](./收集器全景.md#八zgcz-garbage-collector-未来) |
| 怎么选择 GC？ | [收集器全景 - 选型](./收集器全景.md#十收集器选型决策树) |

### 编译优化(JIT)

| 高频题 | 跳转 |
| --- | --- |
| 为什么 Java 跑久了反而变快？ | [JIT - 是什么](./JIT与逃逸分析.md#一为什么需要-jit) |
| 解释执行和 JIT 怎么切换？ | [JIT - 分层编译](./JIT与逃逸分析.md#二分层编译tiered-compilation) |
| C1 和 C2 区别？ | [JIT - C1 vs C2](./JIT与逃逸分析.md#22-c1-vs-c2) |
| 什么是 OSR 栈上替换？ | [JIT - OSR](./JIT与逃逸分析.md#32-osron-stack-replacement-栈上替换) |
| 方法内联是什么？多态能内联吗？ | [JIT - 内联](./JIT与逃逸分析.md#四方法内联inlining) |
| 什么是逃逸分析？三种状态？ | [JIT - 逃逸分析](./JIT与逃逸分析.md#五逃逸分析escape-analysis) |
| HotSpot 真有栈上分配吗？ | [JIT - 标量替换](./JIT与逃逸分析.md#62-标量替换scalar-replacement) |
| StringBuffer 和 StringBuilder 性能差距还有吗？ | [JIT - 锁消除](./JIT与逃逸分析.md#63-锁消除lock-elimination) |
| Code Cache 是什么？满了会怎样？ | [JIT - Code Cache](./JIT与逃逸分析.md#七code-cache--jit-编译产物的家) |
| 什么是反优化？ | [JIT - 反优化](./JIT与逃逸分析.md#八反优化deoptimization) |
| AOT 和 JIT 区别？GraalVM Native Image？ | [JIT - AOT](./JIT与逃逸分析.md#九aot-与-graalvm-native-image) |
| 加 final 能提升性能吗？ | [JIT - Q13](./JIT与逃逸分析.md#q13加-final-能提升性能吗) |
| 服务上线第一波超时怎么办？ | [JIT - 预热](./JIT与逃逸分析.md#101-服务上线第一波请求超时) |

### 参数与调优

| 高频题 | 跳转 |
| --- | --- |
| -Xms 和 -Xmx 为什么要相等？ | [参数](./jvm参数.md#八生产踩坑) |
| MetaspaceSize 是上限吗？ | [参数](./jvm参数.md#23-元空间jdk-8) |
| JDK 8 / 11 / 17 默认 GC 是什么？ | [参数](./jvm参数.md#六版本默认值差异) |
| GC 日志怎么开？ | [参数](./jvm参数.md#41-gc-日志) |
| 怎么让 JVM 容器感知？ | [参数](./jvm参数.md#83-k8s-pod-没设-xmx) |
| 怎么调优？心法？ | [调优](./jvm调优.md#一调优心法) |
| OOM Java heap space 怎么排查？ | [调优](./jvm调优.md#41-oomjava-heap-space) |
| 频繁 FullGC 怎么办？ | [调优](./jvm调优.md#43-频繁-fullgc) |
| GC 延迟 P99 飙高怎么办？ | [调优](./jvm调优.md#44-gc-延迟抖动p99-飙到秒级) |
| 元空间 OOM 怎么排查？ | [调优](./jvm调优.md#42-oommetaspace) |

### 线上排查

| 高频题 | 跳转 |
| --- | --- |
| CPU 飙高怎么排查？ | [线上排查](./线上问题排查.md#一cpu-飙高排查标准三连) |
| 内存泄漏怎么定位？ | [线上排查](./线上问题排查.md#二内存泄漏--频繁-fullgc) |
| 死锁怎么排查？ | [线上排查](./线上问题排查.md#三死锁) |
| 进程突然消失怎么办？ | [线上排查](./线上问题排查.md#六进程消失oom-killer) |
| jstack 检测得到 ReentrantLock 死锁吗？ | [线上排查](./线上问题排查.md#33-reentrantlock-死锁) |
| arthas 和 jstack 区别？ | [线上排查](./线上问题排查.md#八arthas-必学命令) |
| 接口慢怎么定位？ | [线上排查](./线上问题排查.md#五接口慢--响应延迟高) |

---

## 三、推荐学习路径

### 新手路径（按依赖序）

```
基础层
 1. 运行时数据区              ← 全局视角
 2. 对象在内存中的布局         ← Mark Word + 压缩指针
 3. JVM 内存与 OS（MMU）       ← 虚拟内存 / TLB / RSS-VSZ-Committed 的硬件层心智模型

并发基础（与 Concurrency 模块联动）
 3. JMM                       ← happens-before 是核心
 4. 内存屏障                   ← JMM 落地的硬件机制

类加载
 5. 类加载机制                 ← 5 阶段
 6. 双亲委派机制               ← ClassLoader 协作

垃圾回收（最高频考区）
 7. 垃圾回收                   ← 算法 + 三色标记
 8. G1 垃圾回收器              ← 现在主流
 9. 收集器全景                 ← 演进 + 选型

编译优化
10. JIT 与逃逸分析             ← 分层编译 / 内联 / 标量替换 / 锁消除

参数与实战
11. JVM 参数                   ← 完整参数 + 配置模板
12. JVM 调优                   ← 心法 + 案例
13. 线上问题排查               ← 工具 + 命令
```

### 面试速通路径（30 分钟刷一遍）

每篇看 **答题模板** 一节就够：

**内存**
- [运行时数据区 - 答题模板](./内存区域.md#十一答题模板60-秒话术)
- [对象布局 - 答题模板](./对象在内存中的布局.md#九答题模板60-秒话术)
- [MMU / 虚拟内存 - 答题模板](./JVM内存与OS-MMU虚拟内存.md#九答题模板60-秒话术)
- [JMM - 答题模板](./内存模型.md#十一答题模板60-秒话术)
- [内存屏障 - 答题模板](./内存屏障.md#十答题模板30-秒话术)

**类加载**
- [类加载 - 答题模板](./类加载机制.md#八答题模板60-秒话术)
- [双亲委派 - 答题模板](./双亲委派机制.md#八答题模板60-秒话术)

**GC**
- [垃圾回收 - 答题模板](./垃圾回收.md#十一答题模板90-秒话术)
- [G1 - 答题模板](./G1垃圾回收器.md#十二答题模板90-秒话术)
- [收集器全景 - 答题模板](./收集器全景.md#十三答题模板90-秒话术)

**编译优化**
- [JIT 与逃逸分析 - 答题模板](./JIT与逃逸分析.md#十三答题模板90-秒话术)

**实战**
- [JVM 参数 - 答题模板](./jvm参数.md#十答题模板60-秒话术)
- [JVM 调优 - 答题模板](./jvm调优.md#九答题模板90-秒话术)
- [线上排查 - 答题模板](./线上问题排查.md#十二答题模板90-秒话术)

---

## 四、关键速记表

### 4.1 内存区域 OOM 速查

| 异常 | 区域 | 排查方向 |
| --- | --- | --- |
| `Java heap space` | 堆 | jmap dump + MAT |
| `Metaspace` | 方法区 | 类加载泄漏 |
| `Direct buffer memory` | 直接内存 | NMT + Netty 泄漏检测 |
| `unable to create new native thread` | 线程栈（OS 限制） | 线程数 / -Xss |
| `StackOverflowError` | JVM 栈 | 深递归 |
| `GC overhead limit exceeded` | 堆 | GC 占 98% 但回收 < 2% |

### 4.2 GC 收集器速查

| 收集器 | 特点 | JDK |
| --- | --- | --- |
| Serial | 单线程，客户端 | 一直在 |
| Parallel | 吞吐优先 | JDK 8 默认 |
| **CMS** | 低延迟先驱，已删 | JDK 14 删除 |
| **G1** | 分区软实时 | **JDK 9+ 默认** |
| **ZGC** | 亚毫秒级 | JDK 11 实验，JDK 15 生产 |
| Shenandoah | OpenJDK only | OpenJDK 12+ |

### 4.3 三色标记 + 漏标

| 颜色 | 含义 |
| --- | --- |
| 白 | 未访问（候选垃圾） |
| 灰 | 已访问，引用未遍历完 |
| 黑 | 已访问，引用全遍历 |

漏标条件（同时满足）：
1. 黑→白新引用
2. 灰→白旧引用断开

解法：
- **CMS 增量更新**：写屏障关注条件 1
- **G1 SATB**：写屏障关注条件 2

### 4.4 标准生产参数

```bash
# 4 核 4GB Pod 的 Spring Boot 服务
-Xms3g -Xmx3g
-Xss512k
-XX:MaxMetaspaceSize=256m
-XX:MaxDirectMemorySize=512m
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200
-XX:+UseStringDeduplication
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/data/log/heap.hprof
-XX:+ExitOnOutOfMemoryError
-Xlog:gc*=info:file=/data/log/gc.log:time:filecount=10,filesize=100M
```

### 4.5 jcmd 一把梭命令

```bash
jcmd <pid> VM.flags                    # 启动参数
jcmd <pid> GC.heap_info                # 堆信息
jcmd <pid> GC.class_histogram          # 类直方图
jcmd <pid> Thread.print                # 线程栈
jcmd <pid> VM.native_memory summary    # NMT
jcmd <pid> JFR.start duration=60s ...  # 飞行记录
```

### 4.6 32GB 堆陷阱

```
≤ 31GB → 压缩指针生效，引用 4B
32-48GB → 压缩失效，引用 8B，可用空间反而少
≥ 48GB → 压缩失效但内存够多，绝对可用 > 48GB

经验：要么 ≤ 31GB，要么 ≥ 48GB，避开中间负优化区间
```

---

## 五、生产踩坑 TOP 10

| 坑 | 文档 |
| --- | --- |
| 元空间 OOM（动态类生成 / Tomcat 热部署） | [运行时数据区 - 元空间 OOM](./内存区域.md#91-元空间-oom最常见) |
| 直接内存泄漏（Netty / NIO） | [线上排查 - Netty 泄漏](./线上问题排查.md#104-案例堆外内存泄漏netty) |
| ThreadLocal 不清理 | [线上排查 - ThreadLocal](./线上问题排查.md#102-案例threadlocal-内存泄漏) |
| 线程数失控（unable to create new native thread） | [运行时数据区](./内存区域.md#93-线程栈把内存吃光unable-to-create-new-native-thread) |
| MaxMetaspaceSize 不设 | [JVM 参数](./jvm参数.md#82--xxmaxmetaspacesize-不设) |
| 32-48GB 堆负优化 | [对象布局 - 32GB 陷阱](./对象在内存中的布局.md#33--xmx-31gb-比-33gb-内存利用率还高生产经验) |
| 大对象触发 PromotionFailed | [垃圾回收](./垃圾回收.md#91-大对象触发-promotionfailed) |
| Humongous Region 频繁 Mixed GC | [G1](./G1垃圾回收器.md#101-humongous-大对象触发频繁-mixed-gc) |
| K8s Pod 没设容器感知 | [JVM 参数](./jvm参数.md#83-k8s-pod-没设-xmx) |
| OOM Killer 杀进程没留 hprof | [线上排查](./线上问题排查.md#六进程消失oom-killer) |

---

## 六、面试连环追问的话题

按出现频率列出：

1. **内存区域**：5 大区 → 线程私有 vs 共享 → 各区 OOM → 永久代→元空间 → 字符串常量池搬家
2. **JMM**：主内存/工作内存 → 三大特性 → 重排序三种来源 → happens-before 8 条 → volatile 语义 → DCL
3. **对象布局**：三段式 → Mark Word → 锁状态机 → 压缩指针 → 32GB 陷阱
4. **类加载**：5 阶段 → \<clinit\> 顺序 → 双亲委派 → 三大打破 → SPI / Tomcat
5. **垃圾回收**：可达性 → 四种引用 → 三大算法 → 分代假说 → 卡表 → 三色标记 → 漏标
6. **G1**：Region → Mixed GC → 可预测停顿 → RSet → SATB → Humongous
7. **收集器演进**：Serial → Parallel → CMS（已删）→ G1 → ZGC（染色指针）
8. **JIT 编译**：解释 vs 编译 → C1/C2 分层 → OSR → 内联 → 逃逸分析 → 标量替换/锁消除 → Code Cache → 反优化 → AOT
9. **调优**：监控指标 → 度量 → dump → MAT → 改代码 / 参数 → 灰度
10. **线上排查**：CPU 三连 → 内存四步 → 死锁 jstack → arthas / JFR

每条主线对应至少一篇深度文档，按上方"高频题映射"快速跳转。

---

## 七、相关模块

- [Concurrency 并发](../Concurrency/README.md) — JMM / volatile / synchronized / 锁的应用层
- [MySQL 面试模块](../MySQL/README.md) — InnoDB Buffer Pool 也是内存治理
- [Redis 面试模块](../Redis/README.md) — Redis fork + COW 类似 JVM GC fork
- [Spring](../Spring/README.md) — 类加载与 Bean 生命周期
- 项目 - 线上问题排查思路 — 业务侧排查
- 项目 - 性能优化 — JVM 调优在系统层
