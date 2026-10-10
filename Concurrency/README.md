# Concurrency 并发面试模块

> 大厂后端面试的"必考四大件"之一（Redis / MySQL / JVM / **并发**）。
>
> 本模块按 **基础理论 → 硬件底层 → 同步原语 → 并发工具 → 容器 → 任务调度 → 进阶 → 兜底排查** 八层组织，每篇都按 senior 标准写：原理 + 取舍 + 面试追问 + 生产踩坑 + 答题模板。

---

## 一、模块导航

### 基础理论（3 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [进程与线程](./进程与线程.md) | 进程 / 线程 / 协程对比 + 6 状态 + interrupt 协作 |
| [JMM 内存模型](./JMM内存模型.md) | 主内存 / 工作内存 + 三大特性 + happens-before 8 大规则 + 内存屏障 |
| [Volatile](./Volatile.md) | 三大语义 + 屏障实现 + DCL 必备 + ARM/x86 性能差异 |

### 硬件底层（1 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [伪共享与缓存一致性](./伪共享与缓存一致性.md) | CPU 缓存行 + MESI + @Contended + Disruptor padding 套路 |

### 同步原语（4 篇）

> **层次关系**：CAS（无锁基石）→ Synchronized（JVM 内置锁）+ AQS（JDK 类库锁基础）+ Lock（基于 AQS 的高层组件）。
>
> ```
> [CAS]  ────────► 无锁原语
>    ├─ AtomicInteger / LongAdder
>    └─ Synchronized 锁升级中的 CAS
>
> [Synchronized]  ────────► JVM 内置锁
>    └─ 锁升级：偏向 → 轻量 → 重量
>
> [AQS]  ────────► JUC 锁框架基石
>    ├─ state + CLH 队列
>    └─ 模板方法
>             ↓
> [Lock]  ────────► ReentrantLock / RW / StampedLock
>          + Semaphore / CountDownLatch / CyclicBarrier
> ```

| 文档 | 一句话定位 |
| --- | --- |
| [Synchronized](./Synchronized.md) | monitorenter / Monitor + 锁升级 4 阶段 + Mark Word |
| [CAS 与原子类](./CAS与原子类.md) | CAS / ABA 三大问题 + Atomic 全家桶 + LongAdder 高竞争利器 |
| [AQS 原理](./AQS原理.md) | state + CLH 队列 + 独占 / 共享 + Condition |
| [Lock 原理](./Lock原理.md) | ReentrantLock / ReadWriteLock / StampedLock 三剑客 |

### 等待唤醒 + 线程隔离（2 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [等待唤醒机制](./等待唤醒机制.md) | wait/notify / await/signal / park/unpark 三机制对比 |
| [ThreadLocal](./ThreadLocal.md) | 线程隔离 + 弱引用泄漏 + InheritableThreadLocal + TTL |

### 并发容器（2 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [ConcurrentHashMap](./ConcurrentHashMap.md) | JDK 7 分段锁 vs JDK 8 CAS+synchronized + 并发扩容 |
| [阻塞队列](./阻塞队列.md) | ABQ/LBQ/SQ/PBQ/DQ 7 种 + COW + ConcurrentSkipListMap |

### 任务调度（3 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [线程池](./线程池.md) | 7 大参数 + 工作流程 + ctl 位运算 + Tomcat 改造 + 监控调参 |
| [ForkJoinPool](./ForkJoinPool.md) | 分治并行 + Work Stealing + commonPool + parallelStream 坑 |
| [CompletableFuture](./CompletableFuture.md) | Future 缺陷 + 链式编排 + allOf/anyOf + commonPool 坑 |

### 进阶（1 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [虚拟线程](./虚拟线程.md) | JDK 21 Loom + M:N 调度 + Continuation + pin 问题 + ScopedValue |

### 死锁兜底（1 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [死锁分析](./死锁分析.md) | 四要素 + 5 大模式 + jstack/Arthas 排查 + 6 大预防 |

---

## 二、面试高频题 → 文档映射

被问到这些题，直接跳到对应文档：

| 高频题 | 跳转 |
| --- | --- |
| 进程和线程的区别？ | [进程与线程](./进程与线程.md#一进程-vs-线程-vs-协程) |
| 线程的 6 种状态？BLOCKED 和 WAITING 区别？ | [进程与线程 - 6 状态](./进程与线程.md#三线程的-6-种状态必背) |
| 创建线程的几种方式？为什么禁用 new Thread？ | [进程与线程 - 创建](./进程与线程.md#二创建线程的方式4-种) |
| 如何优雅停止线程？为什么 stop() 废弃？ | [进程与线程 - interrupt](./进程与线程.md#六优雅地停止线程) |
| 什么是 JMM？主内存和工作内存什么关系？ | [JMM 内存模型](./JMM内存模型.md) |
| happens-before 8 大规则是什么？ | [JMM - happens-before](./JMM内存模型.md#四happens-before-规则jmm-灵魂) |
| volatile 怎么保证可见性 / 有序性？ | [Volatile](./Volatile.md) |
| volatile 能保证 i++ 原子吗？ | [Volatile - 三大语义](./Volatile.md#一volatile-三大语义) |
| DCL 单例为什么必须 volatile？ | [JMM - DCL](./JMM内存模型.md#33-有序性ordering) |
| synchronized 字节码怎么实现？ | [Synchronized - 字节码](./Synchronized.md#二字节码层面) |
| Monitor / ObjectMonitor 是什么？ | [Synchronized - Monitor](./Synchronized.md#三monitor-与对象头核心) |
| 偏向锁 / 轻量级锁 / 重量级锁怎么升级？ | [Synchronized - 锁升级](./Synchronized.md#四锁升级jdk-6-关键优化) |
| Mark Word 长什么样？ | [Synchronized - Mark Word](./Synchronized.md#31-mark-word对象头中的-64-bit) |
| 偏向锁为什么 JDK 15 默认关了？ | [Synchronized - 偏向锁](./Synchronized.md#42-偏向锁) |
| synchronized 和 ReentrantLock 区别？ | [Lock - 对比](./Lock原理.md#21-vs-synchronized) |
| CAS 是什么？CPU 怎么实现？ | [CAS](./CAS与原子类.md) |
| ABA 问题怎么解？ | [CAS - ABA](./CAS与原子类.md#21-aba-问题) |
| AtomicLong 和 LongAdder 区别？ | [CAS - LongAdder](./CAS与原子类.md#四longadder高竞争利器jdk-8) |
| AQS 的核心数据结构？ | [AQS](./AQS原理.md#二aqs-核心数据结构) |
| ReentrantLock 是怎么基于 AQS 实现的？ | [AQS - ReentrantLock 链路](./AQS原理.md#44-reentrantlocklock-完整链路必背) |
| 公平锁和非公平锁差在哪？ | [AQS - 公平 vs 非公平](./AQS原理.md#44-reentrantlocklock-完整链路必背) |
| Condition 怎么实现 await/signal？ | [AQS - Condition](./AQS原理.md#六conditionaqs-上的-waitnotify) |
| ReadWriteLock state 怎么拆？为什么不支持升级？ | [Lock - RW](./Lock原理.md#三reentrantreadwritelock) |
| StampedLock 乐观读怎么实现？ | [Lock - StampedLock](./Lock原理.md#四stampedlockjdk-8-引入) |
| Semaphore / CountDownLatch / CyclicBarrier 区别？ | [Lock - 其他](./Lock原理.md#五其他-lock-简述) |
| wait 和 sleep 区别？ | [等待唤醒](./等待唤醒机制.md#六wait-vs-sleep-vs-yield-vs-join高频陷阱) |
| 为什么 wait 必须用 while 不能用 if？ | [等待唤醒 - 虚假唤醒](./等待唤醒机制.md#三虚假唤醒必须用-while) |
| park/unpark 和 wait/notify 的本质区别？ | [等待唤醒 - LockSupport](./等待唤醒机制.md#五locksupportparkunpark底层原语) |
| ThreadLocal 怎么实现线程隔离？ | [ThreadLocal](./ThreadLocal.md#二内部实现数据存哪了) |
| ThreadLocal 内存泄漏的根因？ | [ThreadLocal - 泄漏](./ThreadLocal.md#三内存泄漏最重要的考点) |
| ThreadLocal 的 key 为什么用弱引用？ | [ThreadLocal - 弱引用](./ThreadLocal.md#35-为什么-key-设计成弱引用而不是强引用) |
| InheritableThreadLocal 在线程池下为什么失效？ | [ThreadLocal - ITL](./ThreadLocal.md#五inheritablethreadlocal) |
| HashMap 多线程问题？为什么死循环？ | [ConcurrentHashMap - 痛点](./ConcurrentHashMap.md#一hashmap-多线程问题) |
| ConcurrentHashMap JDK 7 / 8 区别？ | [CHM - 对比](./ConcurrentHashMap.md#六jdk-7-vs-8-全方位对比) |
| CHM 为什么禁止 null？ | [CHM - null](./ConcurrentHashMap.md#五为什么禁止-null) |
| CHM 怎么并发扩容？ | [CHM - 扩容](./ConcurrentHashMap.md#43-扩容最复杂) |
| ABQ 和 LBQ 区别？为什么 LBQ 用两把锁？ | [阻塞队列 - 对比](./阻塞队列.md#33-lbq-vs-abq) |
| SynchronousQueue 怎么实现 0 容量？ | [阻塞队列 - SQ](./阻塞队列.md#四synchronousqueuesq) |
| DelayQueue 延迟原理？ | [阻塞队列 - DQ](./阻塞队列.md#六delayqueue) |
| 线程池 7 大参数？ | [线程池 - 参数](./线程池.md#二7-大核心参数必背) |
| 线程池工作流程？ | [线程池 - 流程](./线程池.md#三工作流程必背) |
| 4 种拒绝策略各自适用？ | [线程池 - 拒绝](./线程池.md#26-handler拒绝策略) |
| 阿里为什么禁用 Executors？ | [线程池 - Executors 坑](./线程池.md#五executors-工厂方法的坑) |
| 核心线程数怎么算？ | [线程池 - 核心数](./线程池.md#六核心线程数怎么算) |
| 线程池 5 种状态怎么转换？ctl 怎么用？ | [线程池 - 状态机](./线程池.md#四生命周期5-种状态) |
| Tomcat 线程池有什么改造？ | [线程池 - Tomcat](./线程池.md#73-tomcat-线程池的特殊改造) |
| Future 和 CompletableFuture 区别？ | [CompletableFuture - 对比](./CompletableFuture.md#一future-为什么不够用) |
| thenApply 和 thenCompose 区别？ | [CF - thenCompose](./CompletableFuture.md#33-thenapply-vs-thencompose必懂) |
| CompletableFuture 默认线程池有什么坑？ | [CF - commonPool](./CompletableFuture.md#四默认线程池的坑) |
| 死锁的四要素？ | [死锁](./死锁分析.md#一死锁四要素coffman-条件) |
| 怎么排查线上死锁？ | [死锁 - 排查](./死锁分析.md#三排查死锁生产标准流程) |
| 怎么预防死锁？ | [死锁 - 预防](./死锁分析.md#四6-大预防策略) |
| 缓存行多大？MESI 4 个状态？ | [伪共享 - MESI](./伪共享与缓存一致性.md#二mesi-协议缓存一致性) |
| 什么是伪共享？怎么解决？ | [伪共享 - false sharing](./伪共享与缓存一致性.md#三伪共享false-sharing) |
| @Contended 注解怎么用？为什么默认 128 字节？ | [伪共享 - @Contended](./伪共享与缓存一致性.md#四contended-注解jdk-8) |
| Disruptor 为什么这么快？ | [伪共享 - Disruptor](./伪共享与缓存一致性.md#六disruptor-的极致优化) |
| ForkJoinPool 和 ThreadPoolExecutor 区别？ | [ForkJoinPool - 对比](./ForkJoinPool.md#三-work-stealing-算法) |
| Work Stealing 怎么实现？ | [ForkJoinPool - WS](./ForkJoinPool.md#三-work-stealing-算法) |
| commonPool 默认多少线程？ | [ForkJoinPool - commonPool](./ForkJoinPool.md#四commonpool) |
| parallelStream 慢 / 卡住的原因？ | [ForkJoinPool - parallelStream](./ForkJoinPool.md#六parallelstream-实战) |
| ManagedBlocker 解决什么？ | [ForkJoinPool - ManagedBlocker](./ForkJoinPool.md#五managedblocker阻塞也能不饿死) |
| 虚拟线程和平台线程区别？ | [虚拟线程 - 对比](./虚拟线程.md#二原理mn-调度) |
| 虚拟线程怎么实现"阻塞不占线程"？ | [虚拟线程 - Continuation](./虚拟线程.md#22-continuationjvm-的暂停--恢复机制) |
| synchronized 为什么 pin 载体线程？ | [虚拟线程 - pin](./虚拟线程.md#四pin-问题最大的坑) |
| 虚拟线程适合 / 不适合什么场景？ | [虚拟线程 - 适用](./虚拟线程.md#五适用--不适用场景) |
| ScopedValue 是什么？怎么替代 ThreadLocal？ | [虚拟线程 - ScopedValue](./虚拟线程.md#六scopedvalue搭档) |
| StructuredConcurrency 解决什么？ | [虚拟线程 - StructuredTaskScope](./虚拟线程.md#七structuredconcurrency结构化并发jdk-21-incubator) |
| 虚拟线程能完全替代 WebFlux 吗？ | [虚拟线程 - 对比 Reactor](./虚拟线程.md#八与-reactor--coroutine-的对比) |

---

## 三、推荐学习路径

### 新手路径（按依赖顺序）

```
基础层
 1. 进程与线程              ← 全局视图 + 状态机
 2. JMM 内存模型            ← 并发问题的"宪法"
 3. Volatile               ← JMM 落地的最轻原语

同步原语
 4. CAS 与原子类            ← 无锁基石
 5. Synchronized           ← JVM 内置锁 + 锁升级
 6. AQS 原理               ← JUC 锁框架基石（核心）
 7. Lock 原理              ← ReentrantLock / RW / StampedLock

等待 / 隔离
 8. 等待唤醒机制            ← wait/notify/await/signal/park
 9. ThreadLocal           ← 线程隔离 + 内存泄漏

并发容器
10. ConcurrentHashMap     ← 必考
11. 阻塞队列               ← 7 种 + COW + 跳表

任务调度
12. 线程池                ← 后端面试 Top 1
13. ForkJoinPool         ← 分治并行 + Work Stealing
14. CompletableFuture    ← 现代异步编程

进阶
15. 虚拟线程              ← JDK 21 Loom，2024 起必考
16. 伪共享与缓存一致性    ← 中间件 / 高性能岗位高频

兜底
17. 死锁分析              ← 排查工具链
```

### 面试速通路径（30 分钟刷一遍）

每篇看 **答题模板** 一节就够：

**基础**
- [进程与线程 - 答题模板](./进程与线程.md#九答题模板30-秒话术)
- [JMM - 答题模板](./JMM内存模型.md#八答题模板60-秒话术)
- [Volatile - 答题模板](./Volatile.md#八答题模板60-秒话术)

**同步**
- [Synchronized - 答题模板](./Synchronized.md#十答题模板90-秒话术)
- [CAS - 答题模板](./CAS与原子类.md#九答题模板60-秒话术)
- [AQS - 答题模板](./AQS原理.md#九答题模板90-秒话术)
- [Lock - 答题模板](./Lock原理.md#八答题模板90-秒话术)

**等待唤醒 / 隔离**
- [等待唤醒 - 答题模板](./等待唤醒机制.md#九答题模板90-秒话术)
- [ThreadLocal - 答题模板](./ThreadLocal.md#九答题模板90-秒话术)

**容器**
- [ConcurrentHashMap - 答题模板](./ConcurrentHashMap.md#九答题模板90-秒话术)
- [阻塞队列 - 答题模板](./阻塞队列.md#十四答题模板90-秒话术)

**调度**
- [线程池 - 答题模板](./线程池.md#十答题模板120-秒话术)
- [ForkJoinPool - 答题模板](./ForkJoinPool.md#十答题模板90-秒话术)
- [CompletableFuture - 答题模板](./CompletableFuture.md#九答题模板90-秒话术)

**进阶**
- [虚拟线程 - 答题模板](./虚拟线程.md#十一答题模板120-秒话术)
- [伪共享 - 答题模板](./伪共享与缓存一致性.md#十答题模板90-秒话术)

**兜底**
- [死锁分析 - 答题模板](./死锁分析.md#八答题模板90-秒话术)

---

## 四、关键速记

### 4.1 三大特性 + 落地

| 特性 | volatile | synchronized | Atomic | final |
| --- | --- | --- | --- | --- |
| 可见性 | ✅ | ✅ | ✅ | ✅（构造完成后）|
| 原子性 | ⚠️ 单变量 | ✅ | ✅ CAS | n/a |
| 有序性 | ✅ 屏障 | ✅ 互斥内 | ✅ | ✅ 构造期屏障 |
| 阻塞 | ❌ | ✅ | ❌ | n/a |

### 4.2 happens-before 8 大规则

```
1. 程序顺序：单线程内代码先后
2. 监视器锁：unlock → 后续 lock
3. volatile：写 → 后续读
4. 传递性：A→B 且 B→C ⟹ A→C
5. start：start() → 新线程内任意操作
6. join：被 join 线程内操作 → join 返回后
7. interrupt：interrupt() → 检测到中断
8. finalizer：构造完成 → finalize()
```

### 4.3 锁升级状态机

```
无锁 ─► 偏向锁 ─► 轻量级锁 ─► 重量级锁
 (01)    (01+id)    (00+ptr)     (10+ptr)
        单线程       少竞争自旋    阻塞挂起
```

### 4.4 线程池工作流程

```
submit ─► 核心未满 ─► 创建核心线程
            │ NO
            ▼
         队列未满 ─► 入队
            │ NO
            ▼
         总数<max ─► 创建临时线程
            │ NO
            ▼
         RejectedHandler
```

### 4.5 BlockingQueue 4 组方法

| 操作 | 抛异常 | 返回值 | **阻塞** | 超时 |
| --- | --- | --- | --- | --- |
| 入队 | add | offer | **put** | offer(t,u) |
| 出队 | remove | poll | **take** | poll(t,u) |

### 4.6 4 种拒绝策略

| | 行为 | 推荐 |
| --- | --- | --- |
| AbortPolicy（默认） | 抛 RejectedExecutionException | 内部业务能 catch |
| **CallerRunsPolicy** | 调用线程自己跑（背压）| **生产推荐** |
| DiscardPolicy | 静默丢弃 | 禁用 |
| DiscardOldestPolicy | 丢老的，再 offer | 慎用 |

### 4.7 死锁四要素

```
互斥 + 持有等待 + 不可剥夺 + 循环等待 = 死锁
破坏任一 = 不死锁
```

### 4.8 排查工具速查

| 问题 | 工具 |
| --- | --- |
| 死锁 | `jstack -l` / `arthas thread -b` / ThreadMXBean |
| CPU 高 | `top -Hp <pid>` + `jstack` 找占 CPU 的 nid |
| 内存 / GC | `jmap` / `jstat -gcutil` |
| 线程池堆积 | 看 `getQueue().size()` 监控 |

---

## 五、生产踩坑 TOP 10

| # | 坑 | 文档 |
| --- | --- | --- |
| 1 | DCL 单例不加 volatile → NPE | [JMM](./JMM内存模型.md#33-有序性ordering) |
| 2 | newFixedThreadPool 任务堆积 OOM | [线程池](./线程池.md#五executors-工厂方法的坑) |
| 3 | ThreadLocal 在线程池泄漏 → OOM | [ThreadLocal](./ThreadLocal.md#71-线程池里忘-remove--oom) |
| 4 | InheritableThreadLocal 串数据 | [ThreadLocal](./ThreadLocal.md#72-线程池--inheritablethreadlocal-串数据) |
| 5 | volatile 误以为能保证 i++ 原子 | [Volatile](./Volatile.md#五volatile-不能保证原子的陷阱代码) |
| 6 | AtomicLong 高竞争 CPU 100% | [CAS](./CAS与原子类.md#71-用-atomiclong-做高-qps-计数器cpu-飚到-100) |
| 7 | 锁顺序不一致死锁 | [死锁](./死锁分析.md#21-模式-1嵌套锁顺序不一致最常见) |
| 8 | CompletableFuture 不传 pool 打爆 commonPool | [CF](./CompletableFuture.md#四默认线程池的坑) |
| 9 | submit 任务异常被 Future 吞 | [线程池](./线程池.md#82-任务里抛异常无人知) |
| 10 | 偏向锁撤销 STW 卡顿 | [Synchronized](./Synchronized.md#84-偏向锁撤销-stw-卡顿) |

---

## 六、面试常被一连串追问的话题

按出现频率列出：

1. **synchronized**：用法 → 字节码 → Monitor → Mark Word → 锁升级 → 偏向 / 轻量 / 重量
2. **AQS**：state → CLH → tryAcquire → addWaiter → acquireQueued → ReentrantLock 链路
3. **CAS**：cmpxchg → ABA → 自旋 → AtomicLong / LongAdder → 缓存行伪共享
4. **JMM**：主 / 工作内存 → 三大特性 → happens-before → 内存屏障 → DCL
5. **ConcurrentHashMap**：HashMap 死循环 → JDK7 分段锁 → JDK8 CAS+sync → 并发扩容 → size 估值
6. **ThreadLocal**：实现 → 弱引用 → 内存泄漏 → ITL → TTL
7. **线程池**：7 参数 → 工作流程 → ctl 位运算 → 拒绝策略 → 状态机 → 监控 → Tomcat 改造
8. **volatile**：可见 / 有序 / 单变量原子 → 屏障 → DCL → 不解决 i++
9. **Lock**：synchronized vs Lock → 公平 / 非公平 → ReadWriteLock state 拆位 → StampedLock 乐观读 → Condition
10. **死锁**：四要素 → 排查（jstack/Arthas）→ 5 种典型 → 6 大预防

每条主线对应一篇深度文档，按上方"高频题映射"快速跳转。

---

## 七、相关模块

- [Java 集合类](../Java/集合类.md) — HashMap / ArrayList 单线程版
- [JVM](../JVM/README.md) — JMM、内存屏障、对象头、Mark Word 在 JVM 视角
- [MySQL 锁机制](../MySQL/锁机制.md) — 数据库层的锁
- [MySQL 死锁分析](../MySQL/死锁分析.md) — InnoDB 死锁排查
- [Redis 分布式锁](../Redis/分布式锁.md) — 跨进程锁
- [Spring AOP](../Spring/aop.md) — @Async 异步方法的实现
- [JVM 线上问题排查](../JVM/线上问题排查.md) — 线程相关问题排查通用流程
