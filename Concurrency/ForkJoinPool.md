# ForkJoinPool 与 Work Stealing

> JUC 专为**分治并行**和**任务窃取**设计的线程池，CompletableFuture / parallelStream / 虚拟线程调度全靠它。本篇讲清：
> ① 分治并行模型：fork + join + RecursiveTask / RecursiveAction
> ② 工作窃取（Work Stealing）算法：每 Worker 一个 Deque，自己头部取、被偷尾部偷
> ③ vs ThreadPoolExecutor：提交策略 / 队列模型 / 适用场景全面不同
> ④ commonPool 是什么？为什么默认线程数 = N - 1？
> ⑤ parallelStream 慢的根因
> ⑥ ManagedBlocker：阻塞任务也能不饿死载体

> 前置：[线程池](./线程池.md)、[阻塞队列](./阻塞队列.md)、[CompletableFuture](./CompletableFuture.md)

---

## 一、为什么需要 ForkJoinPool

### 1.1 ThreadPoolExecutor 的不足

```
经典 ThreadPoolExecutor：
                  共享 BlockingQueue
                 ┌───────────────────┐
                 │ T1 → T2 → T3 → T4 │
                 └─────────┬─────────┘
        所有 worker  ┌─────┼─────┐  抢一个全局队列
                    W1    W2    W3
```

**痛点**：
- 所有 worker 抢一个共享队列 → **锁竞争激烈**（高频 take/put 时缓存行乒乓）
- 不适合**递归分治**：父任务调 join 等子任务结果时，自己就把 worker 占住，子任务在队列里排队 → 容易**饥饿死锁**
- 没有"任务窃取"——某个 worker 闲了不会主动找活干

### 1.2 ForkJoinPool 的设计

```
ForkJoinPool：
   每个 Worker 一个本地 Deque（双端队列）
        Worker 1                 Worker 2                Worker 3
   ┌──────────────┐         ┌──────────────┐        ┌──────────────┐
   │head ─ T1 ─ T2│         │head ─ T5 ─ T6│        │head ─ T8 ─ T9│
   │      tail ─T3│         │      tail ─T7│        │      tail   │
   └──────────────┘         └──────────────┘        └──────────────┘
        ▲ 自己 push/pop          ▲ 自己 push/pop         ↓ 没活
        从 head 取                从 head 取               │
                                                          │ steal
                                  ◄───── 从尾部窃取 ─────┘
```

**核心创新**：
- **每 Worker 一个本地 Deque**，自己 push / pop 走 head（LIFO，cache 友好）
- 别的 Worker 窃取走 tail（FIFO，避开和本人竞争）
- 减少 95% 以上的锁竞争
- 闲下来主动**找活**，让 CPU 利用率最大化

---

## 二、Fork/Join 编程模型

### 2.1 RecursiveTask（带返回值）

经典：并行求数组和

```java
class SumTask extends RecursiveTask<Long> {
    private static final int THRESHOLD = 1000;
    private final long[] arr;
    private final int from, to;

    SumTask(long[] arr, int from, int to) {
        this.arr = arr; this.from = from; this.to = to;
    }

    @Override
    protected Long compute() {
        if (to - from <= THRESHOLD) {
            // 小到一定程度直接顺序算
            long sum = 0;
            for (int i = from; i < to; i++) sum += arr[i];
            return sum;
        }
        int mid = (from + to) >>> 1;
        SumTask left  = new SumTask(arr, from, mid);
        SumTask right = new SumTask(arr, mid, to);
        left.fork();              // ★ 异步提交左半（推到当前 worker 的 Deque）
        long r = right.compute();  // ★ 当前线程直接跑右半
        long l = left.join();      // ★ 等左半完成
        return l + r;
    }
}

// 使用
ForkJoinPool pool = new ForkJoinPool();
long sum = pool.invoke(new SumTask(bigArray, 0, bigArray.length));
```

### 2.2 RecursiveAction（无返回值）

```java
class FillTask extends RecursiveAction {
    @Override
    protected void compute() {
        if (size <= THRESHOLD) doWork();
        else invokeAll(splitLeft, splitRight);   // 同时 fork 两个子任务等完成
    }
}
```

### 2.3 关键 API

| 方法 | 作用 |
| --- | --- |
| `fork()` | 异步提交到当前 Worker 的 Deque |
| `join()` | 等待结果（worker 在等的过程中**会去帮别的任务跑**，不是死等）|
| `invoke()` | 同步提交并等待（外部线程提交时用）|
| `invokeAll(tasks...)` | 一次提交多个任务并等齐 |
| `compute()` | 子类实现的具体逻辑 |
| `getRawResult()` | 取结果 |

### 2.4 为什么 `right.compute() + left.join()` 而不是 `left.fork(); right.fork(); left.join() + right.join()`？

后者会让两个任务都进队列，当前 worker 闲着等——**浪费一个线程**。
正确做法：当前线程直接跑一半（不入队），另一半 fork 出去，**两个 CPU 都在干活**。这是 fork/join 的标准模式。

---

## 三、Work Stealing 算法

### 3.1 核心规则

1. Worker 自己 push / pop 在 Deque 的**头部**（LIFO）—— 利用缓存局部性，刚 push 的任务最热
2. 其他 Worker 窃取在 Deque 的**尾部**（FIFO）—— 偷"老"任务，减少和本人竞争头部
3. 头部 / 尾部用不同的 CAS 操作，**几乎无锁**

### 3.2 LIFO + FIFO 双端策略的好处

**LIFO 在自己的视角**：刚 fork 的子任务大概率还在 CPU cache 里 → pop 出来跑命中率高 → 性能好。
**FIFO 在偷的视角**：偷"老"任务，老任务通常**任务量更大**（递归靠前，还没拆分）→ 一次窃取干很多活，**减少窃取频率**。

### 3.3 当 Worker 没活干时

```
1. 自己 Deque 空了？
2. → 随机选一个其他 Worker，去他 Deque 尾部偷一个
3. 偷到了：执行
4. 偷不到：让出 CPU（Thread.yield 或 LockSupport.park）等被唤醒
```

### 3.4 vs ThreadPoolExecutor

| 维度 | ThreadPoolExecutor | ForkJoinPool |
| --- | --- | --- |
| 队列模型 | 共享 BlockingQueue | 每 Worker 一个 Deque |
| 任务粒度 | 平等的独立任务 | 通常是分治子任务 |
| 等待结果 | 工作线程提交后阻塞外部 | join 时 worker **去跑别的任务** |
| 锁竞争 | 高（共享队列） | 低（本地队列 + 偶尔 steal） |
| 适合 | 业务请求处理 | CPU 密集分治 / 并行计算 / 虚拟线程调度 |

---

## 四、commonPool

### 4.1 全 JVM 共享的池子

```java
ForkJoinPool common = ForkJoinPool.commonPool();
```

- JVM 启动时延迟创建（首次使用才创建）
- 默认线程数 = `Runtime.getRuntime().availableProcessors() - 1`
- **为什么 -1**：避免和"提交任务的主线程"抢 CPU——主线程也在贡献算力

### 4.2 谁在用 commonPool

- `parallelStream` / `Arrays.parallelSort` 等并行 API 默认用它
- `CompletableFuture.supplyAsync(...)` 不传 pool 时用它（**生产严禁** —— 全 JVM 共享，互相干扰）
- JDK 21 虚拟线程的默认调度器**不是** commonPool —— 是另外一个专用的 ForkJoinPool

### 4.3 调参

```bash
# 显式指定并发度
-Djava.util.concurrent.ForkJoinPool.common.parallelism=8

# 自定义 ForkJoinWorkerThreadFactory
-Djava.util.concurrent.ForkJoinPool.common.threadFactory=...

# 异常处理
-Djava.util.concurrent.ForkJoinPool.common.exceptionHandler=...
```

### 4.4 commonPool 的坑

**坑 1：阻塞任务把它打死**
```java
parallelStream().forEach(item -> jdbcCall(item));
```
parallelStream 默认 commonPool（N-1 线程），JDBC 阻塞把所有线程占满 → 后续 parallelStream / CompletableFuture 全部卡住。

**修复**：用业务自己的线程池跑：
```java
ForkJoinPool myPool = new ForkJoinPool(20);
myPool.submit(() -> list.parallelStream().forEach(...)).get();
```

**坑 2：CompletableFuture 默认走 commonPool**
详见 [CompletableFuture - commonPool 坑](./CompletableFuture.md#四默认线程池的坑)。**生产规则**：所有 `*Async` 必须传专用 pool。

---

## 五、ManagedBlocker：阻塞也能不饿死

### 5.1 痛点

ForkJoinPool 假设任务是"纯 CPU"——要是 worker 跑阻塞 IO，N 个线程全阻塞了，剩下的任务谁跑？

### 5.2 ManagedBlocker 接口

```java
public interface ManagedBlocker {
    boolean block() throws InterruptedException;   // 真正阻塞的逻辑
    boolean isReleasable();                        // 是否已经可以继续
}
```

业务封装成 ManagedBlocker，调 `ForkJoinPool.managedBlock(blocker)`：
- pool 检测到当前 worker 要阻塞，**临时多开一个补偿线程**
- 阻塞结束 worker 回来，补偿线程逐渐回收

```java
class JdbcBlocker implements ForkJoinPool.ManagedBlocker {
    private Result result;
    private boolean done;

    public boolean block() {
        result = jdbcCall();
        done = true;
        return true;
    }
    public boolean isReleasable() { return done; }
}

// 在 fork/join 任务里
ForkJoinPool.managedBlock(new JdbcBlocker());
```

`Phaser`、`CompletableFuture.get()` 内部都用了 ManagedBlocker。

### 5.3 局限

补偿开新线程不便宜，并发太高时仍然会卡。**ForkJoinPool 终归不是为阻塞 IO 设计的，IO 密集场景更适合虚拟线程**。

---

## 六、parallelStream 实战

### 6.1 默认行为

```java
list.parallelStream().filter(...).map(...).collect(...);
```

底层：把 list 切成多段，每段一个 ForkJoinTask 提交到 commonPool，结果合并。

### 6.2 适用 / 不适用

✅ **适合**：
- 数据量大（万级以上）
- 单项处理 CPU 密集（不是 IO）
- 数据源支持高效切分（ArrayList / 数组 ✅，LinkedList ❌ 切分要 O(N) 遍历）
- 操作无副作用 / 无锁

❌ **不适合**：
- 数据量小：fork/join 框架开销 > 收益（上千以下用串行更快）
- IO 阻塞：commonPool 几个线程被打死
- 有共享状态需要同步：锁竞争抵消并行收益
- 切分代价高：LinkedList 用 parallelStream 反而更慢

### 6.3 谨慎案例：HashMap.computeIfAbsent + parallelStream

```java
Map<K, V> cache = new HashMap<>();
list.parallelStream().forEach(k ->
    cache.computeIfAbsent(k, this::loadFromDB)
);
```
HashMap **不线程安全**——多线程 put 死循环 / 数据丢失。
**修复**：换 `ConcurrentHashMap`，或加同步。

### 6.4 改用自己的 pool

```java
ForkJoinPool customPool = new ForkJoinPool(16);
customPool.submit(() ->
    list.parallelStream().forEach(this::process)
).get();
```

JDK 8 起的"hack"——`parallelStream` 在哪个 ForkJoinPool 的 worker 里执行，就用哪个 pool。所以包一层 `submit().get()` 就把 commonPool 换成自己的。

---

## 七、虚拟线程调度器

JDK 21 的虚拟线程**不用 commonPool**，而是单独建一个 ForkJoinPool（专用调度器）：
- 默认线程数 = CPU 核数（不是 N-1）
- 不参与 parallelStream / CompletableFuture 的执行
- 通过 `-Djdk.virtualThreadScheduler.parallelism=N` 调

为什么独立：避免业务的 parallelStream 影响虚拟线程调度。详见 [虚拟线程](./虚拟线程.md#23-调度器forkjoinpool)。

---

## 八、生产踩坑

### 8.1 parallelStream 跑 IO 阻塞

**现象**：用 `list.parallelStream().forEach(restCall)` 加速调用，结果整个应用卡住，连无关业务的 parallelStream 也跑不动。
**根因**：commonPool 全 JVM 共享，IO 阻塞占满 4-7 个线程。
**修复**：用专用 pool 包一层，或者**直接换虚拟线程**（JDK 21+）。

### 8.2 fork/join 任务粒度过细

**现象**：本以为分治能加速，实测 parallelStream 比串行还慢。
**根因**：单项处理只有几纳秒，fork/join 的同步开销 + 任务对象创建 GC 反而成主要成本。
**修复**：粒度阈值（THRESHOLD）拉大，单项任务做的事越多越值得 fork。一般每个子任务包 1000+ 元素。

### 8.3 ForkJoinTask 异常被吞

```java
RecursiveTask<X> task = ...;
task.fork();
X result = task.join();   // 异常包装在 ExecutionException 里
```
join 不抛 checked 异常，但任务里抛的异常会被包成 RuntimeException。生产代码要 catch 后处理。

### 8.4 自己的 ForkJoinPool 没 shutdown

ForkJoinPool 是**非守护线程**，不 shutdown 进程不退出。
**修复**：try-with-resources（JDK 19+ 实现 AutoCloseable）或 finally shutdown。

### 8.5 共享可变状态导致结果错

```java
int[] sum = {0};
list.parallelStream().forEach(x -> sum[0] += x);   // ❌ 非原子
```
**修复**：用 reduce / collect / LongAdder。

### 8.6 ForkJoinPool 配 IO 密集任务

ForkJoinPool 设计假设**纯 CPU**——IO 阻塞会让 worker 干瞪眼。
**修复**：IO 密集场景换 ThreadPoolExecutor（大池）或虚拟线程。

---

## 九、面试高频追问

**Q1：ForkJoinPool 和 ThreadPoolExecutor 区别？**
- 队列：ForkJoinPool 每个 worker 一个 Deque（本地）；TPE 共享 BlockingQueue
- 调度：FJP 有 Work Stealing；TPE 没有
- 任务模型：FJP 适合分治（fork/join）；TPE 适合独立任务
- 阻塞处理：FJP 的 join **会去帮别的任务**（不是死等）；TPE worker 阻塞就阻塞

**Q2：Work Stealing 怎么实现？**
- 每 worker 一个双端队列
- 自己 push / pop 在 head（LIFO，cache 友好）
- 偷别人在 tail（FIFO，避免和本人竞争）
- 偷不到就 yield/park
两端用不同 CAS，几乎无锁。

**Q3：commonPool 默认多少线程？为什么 -1？**
默认 = `availableProcessors() - 1`。-1 是因为提交任务的主线程也参与算力（invoke 时主线程也跑），避免抢 CPU。

**Q4：parallelStream 默认用什么池？**
commonPool。这是大坑——全 JVM 共享，阻塞 IO 任务会污染。生产用 `customPool.submit(() -> list.parallelStream()....get()` 换池。

**Q5：fork() 和 invoke() 区别？**
- `fork()`：异步提交（push 到当前 worker 的 Deque），立即返回
- `invoke()`：同步提交并等结果——外部线程提交入口用 invoke
- `compute()`：子类自己实现的逻辑，不是 API

**Q6：join 时 worker 在干嘛？**
不是死等——会执行 deque 里的其他任务，或者去偷别人的任务。这避免了递归分治的饥饿死锁。

**Q7：ForkJoinPool 适合 IO 密集吗？**
不适合。设计假设纯 CPU，IO 阻塞 worker 直接卡住，剩余任务无人跑。**ManagedBlocker** 能补偿一点（开新线程），但仍然不是首选。**IO 密集用虚拟线程或大池 TPE**。

**Q8：parallelStream 比串行慢的原因有哪些？**
- 数据量太小，框架开销大于收益
- 数据源切分慢（LinkedList）
- 单项操作 IO（commonPool 被打满）
- 共享可变状态导致同步
- 自动装箱 / GC 压力

**Q9：JDK 21 虚拟线程的调度器是 commonPool 吗？**
**不是**。是另外一个专用的 ForkJoinPool，默认线程数 = CPU 核数，与 commonPool 隔离。

**Q10：Work Stealing 怎么避免线程饿死？**
- worker join 时去执行其他任务（包括偷其他 worker 的）
- ManagedBlocker 在阻塞时临时开补偿线程
- park/yield 时被新任务唤醒

---

## 十、答题模板（90 秒话术）

> ForkJoinPool 是 JUC 为**分治并行 + 任务窃取**设计的专用线程池。CompletableFuture 默认池、parallelStream、JDK 21 虚拟线程调度器都是它。
>
> 核心创新是 **Work Stealing**：每个 Worker 一个**本地 Deque**，自己 push/pop 在 head（LIFO，cache 友好），别人窃取在 tail（FIFO，减少争用）。两端不同 CAS 几乎无锁，相比共享 BlockingQueue 锁竞争降 95%+。
>
> 编程模型：**RecursiveTask / RecursiveAction**——`compute()` 里递归把任务拆小到阈值以下顺序执行，否则 `left.fork(); right.compute(); left.join()`——一半异步、一半本线程跑，CPU 都在干活。
>
> **commonPool** 是全 JVM 共享的 ForkJoinPool，默认 `cpus - 1`（留一个给主线程）。**最大坑：parallelStream 和 CompletableFuture 默认都用它，跑阻塞 IO 会把它打满**——生产必须包专用 pool。
>
> **vs ThreadPoolExecutor**：FJP 适合 CPU 密集分治（递归分治、并行计算）；TPE 适合独立任务（业务请求）；IO 密集 + 高并发用**虚拟线程**。
>
> ForkJoinPool 跑阻塞 IO 不友好（worker 卡死），可以用 **ManagedBlocker** 让 pool 开补偿线程，但仍非首选。

---

## 十一、相关文档

- [线程池](./线程池.md) — ThreadPoolExecutor 对比
- [CompletableFuture](./CompletableFuture.md) — 默认走 commonPool
- [虚拟线程](./虚拟线程.md) — 用专用 ForkJoinPool 调度
- [阻塞队列](./阻塞队列.md) — LinkedBlockingDeque 对比 FJP 的 Deque
