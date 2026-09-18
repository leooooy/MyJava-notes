# CompletableFuture（含 Future）

> JDK 8 引入，Java 异步编程的现代答案。本篇讲清：
> ① Future 的局限：阻塞 get、不能链式、不能合并
> ② CompletableFuture 三大能力：异步任务编排 / 结果合并 / 异常处理
> ③ 4 大类核心 API：supplyAsync / thenApply / thenCompose / allOf 等
> ④ 默认线程池 ForkJoinPool.commonPool 的坑
> ⑤ 实战：并行调用 N 个微服务，合并返回；超时控制；降级
> ⑥ 与 Reactor / Kotlin Coroutine / 虚拟线程的对比

> 前置：[线程池](./线程池.md)、[Lock 原理](./Lock原理.md)

---

## 一、Future 为什么不够用

### 1.1 Future 接口

```java
public interface Future<V> {
    boolean cancel(boolean mayInterruptIfRunning);
    boolean isCancelled();
    boolean isDone();
    V get() throws InterruptedException, ExecutionException;
    V get(long timeout, TimeUnit unit) throws ...;
}
```

**典型用法**：
```java
ExecutorService pool = Executors.newFixedThreadPool(10);
Future<Integer> f = pool.submit(() -> { Thread.sleep(1000); return 42; });
Integer result = f.get();   // 阻塞 1 秒
```

### 1.2 4 大局限

| 局限 | 说明 |
| --- | --- |
| **get 必须阻塞** | 没有"完成时回调"机制，要么阻塞要么轮询 isDone |
| **不能链式** | `f1.then(f2)` 这种"f1 完成后做 f2" 写不出来 |
| **不能合并** | 要等 N 个 Future 全部完成，只能 for 循环 get（串行等待） |
| **异常处理弱** | get 抛 ExecutionException 包了一层，要 unwrap 拿原异常 |

### 1.3 Future 的"伪并行"

```java
List<Future<Integer>> futures = ...;
int sum = 0;
for (Future<Integer> f : futures) sum += f.get();   // 串行 get
```
理论上 futures 在并行执行，但 get 是阻塞的——每次都等当前 future 完成才看下一个。**P99 延迟 = 最慢那个**，不是真正"按完成顺序拿结果"。

### 1.4 FutureTask

`FutureTask` 实现了 `RunnableFuture`（既是 Runnable 又是 Future），是 ExecutorService 提交任务时**实际包装类**。它内部用 AQS 实现状态机：
```
NEW → COMPLETING → NORMAL / EXCEPTIONAL
NEW → CANCELLED / INTERRUPTING → INTERRUPTED
```

业务很少直接用 FutureTask，了解即可。

---

## 二、CompletableFuture（CF）

### 2.1 总览

CompletableFuture 实现了 `Future` + `CompletionStage`：
- 仍然是 Future，可以 get
- 多了 50+ 个**编排方法**：thenApply / thenCompose / allOf / anyOf / exceptionally / handle ...

### 2.2 三大能力

| 能力 | API |
| --- | --- |
| **异步执行** | `runAsync` / `supplyAsync` |
| **链式编排** | `thenApply` / `thenCompose` / `thenCombine` |
| **合并 + 等待** | `allOf` / `anyOf` |
| **异常处理** | `exceptionally` / `handle` / `whenComplete` |

---

## 三、核心 API 详解

### 3.1 创建

```java
// 无返回值
CompletableFuture<Void> f1 = CompletableFuture.runAsync(() -> log("done"));

// 有返回值
CompletableFuture<Integer> f2 = CompletableFuture.supplyAsync(() -> 42);

// 用指定线程池（推荐！）★
CompletableFuture<Integer> f3 = CompletableFuture.supplyAsync(() -> 42, myPool);

// 已知结果直接构造
CompletableFuture<String> f4 = CompletableFuture.completedFuture("hello");
```

### 3.2 链式（单流）

```java
CompletableFuture.supplyAsync(() -> "abc")
    .thenApply(s -> s.toUpperCase())          // 转换：String → String
    .thenApply(s -> s.length())               // 转换：String → Integer
    .thenAccept(n -> System.out.println(n))   // 消费：Integer → void
    .thenRun(() -> log("all done"));          // 接着跑：无入参无出参
```

| 方法 | 作用 | 返回 |
| --- | --- | --- |
| `thenApply(Function)` | 转换值 | CF<U> |
| `thenAccept(Consumer)` | 消费值 | CF<Void> |
| `thenRun(Runnable)` | 接着跑（不关心结果）| CF<Void> |
| `thenCompose(Function returning CF)` | **扁平化**（避免 CF<CF<X>>） | CF<U> |

### 3.3 thenApply vs thenCompose（必懂）

```java
// thenApply：函数返回 X → CF<X>
CF<X> r1 = cf.thenApply(s -> getX(s));

// thenCompose：函数返回 CF<X> → CF<X>（扁平化）
CF<X> r2 = cf.thenCompose(s -> getXAsync(s));   // getXAsync 返回 CF<X>

// 如果用 thenApply 包 CF：
CF<CF<X>> wrong = cf.thenApply(s -> getXAsync(s));   // ❌ 嵌套 CF
```

**类比**：等同 Stream 的 `map` vs `flatMap`，或 Optional 的 `map` vs `flatMap`。

### 3.4 合并多个 CF

```java
// thenCombine：等两个都完成，合并结果
CF<Integer> price = supplyAsync(() -> queryPrice());
CF<Integer> stock = supplyAsync(() -> queryStock());
CF<Integer> total = price.thenCombine(stock, (p, s) -> p * s);

// allOf：等所有完成（结果都丢弃，自己 join 取）
CF<Void> all = CompletableFuture.allOf(f1, f2, f3);
all.join();   // 全部完成

// 取所有结果
List<CF<X>> futures = ...;
CF<Void> all = CompletableFuture.allOf(futures.toArray(new CF[0]));
List<X> results = all.thenApply(v ->
    futures.stream().map(CompletableFuture::join).collect(toList())).join();

// anyOf：任意一个完成
CF<Object> any = CompletableFuture.anyOf(f1, f2, f3);
```

### 3.5 异常处理

```java
// (a) exceptionally：上游抛异常时执行（拿到异常 → 返回兜底值）
cf.exceptionally(ex -> { log.error("err", ex); return "default"; });

// (b) handle：成功 / 失败都拿到 (result, throwable)
cf.handle((r, ex) -> ex == null ? r.toUpperCase() : "ERR");

// (c) whenComplete：消费侧（不返回新值，只是观察）
cf.whenComplete((r, ex) -> log.info("done r={}, ex={}", r, ex));
```

### 3.6 同步 / 异步变体

每个方法都有 3 个版本：
```java
.thenApply(fn)              // 同步：上游完成所在线程继续跑
.thenApplyAsync(fn)         // 异步：扔到 ForkJoinPool.commonPool 跑
.thenApplyAsync(fn, pool)   // 异步：扔到指定线程池
```

**生产强烈建议**：**所有 Async 都传 pool 参数**——commonPool 是全局共享的，会被各种 CF / Stream.parallel() 抢，互相影响。

---

## 四、默认线程池的坑

### 4.1 commonPool 是什么

`ForkJoinPool.commonPool()`——全 JVM 共享，线程数 = `CPU 核数 - 1`。

```bash
# 查看默认线程数（4 核机器）
$ java -XshowSettings:properties 2>&1 | grep parallelism
java.util.concurrent.ForkJoinPool.common.parallelism = 3
```

### 4.2 坑 1：阻塞任务把 commonPool 跑死

```java
CompletableFuture.supplyAsync(() -> {
    return restTemplate.getForObject(url, X.class);   // 阻塞 IO！
});
```
4 核机器 commonPool 只有 3 个线程，几个 HTTP 慢调用就把 commonPool 占完。后续所有 supplyAsync / parallelStream / CF 编排都卡住。

**修复**：
```java
ExecutorService ioPool = new ThreadPoolExecutor(50, 200, ...);
CompletableFuture.supplyAsync(() -> restTemplate.getForObject(url, X.class), ioPool);
```

### 4.3 坑 2：异步链路 ThreadLocal 丢失

CF 链上的每个 thenApplyAsync 都可能换线程跑——主线程 set 的 ThreadLocal 在 supplyAsync 里看不到。
**修复**：用阿里 `TransmittableThreadLocal` + `TtlExecutors.getTtlExecutor(pool)` 包装。详见 [ThreadLocal](./ThreadLocal.md#四inheritablethreadlocal)。

---

## 五、实战模式

### 5.1 并行调用多个微服务

```java
// 串行：1500ms
User user = userService.get(uid);
Address addr = addrService.get(uid);
List<Order> orders = orderService.get(uid);

// 并行：max(500, 600, 800) = 800ms
ExecutorService pool = ...;
CF<User> fu = CompletableFuture.supplyAsync(() -> userService.get(uid), pool);
CF<Address> fa = CompletableFuture.supplyAsync(() -> addrService.get(uid), pool);
CF<List<Order>> fo = CompletableFuture.supplyAsync(() -> orderService.get(uid), pool);

CompletableFuture.allOf(fu, fa, fo).join();
DTO dto = new DTO(fu.join(), fa.join(), fo.join());
```

**这是 CF 在生产里最高频的用法**——网关 / BFF 层聚合下游服务。

### 5.2 超时控制（JDK 9+）

```java
// JDK 8：用 ScheduledExecutorService 定时器辅助
// JDK 9+：直接 API
CF<Integer> result = supplyAsync(() -> slowService())
    .orTimeout(500, TimeUnit.MILLISECONDS)               // 超时抛 TimeoutException
    .completeOnTimeout(0, 500, TimeUnit.MILLISECONDS);   // 或超时给默认值
```

### 5.3 降级 / 兜底

```java
CompletableFuture.supplyAsync(() -> remoteService())
    .completeOnTimeout(defaultValue, 500, MS)
    .exceptionally(ex -> { log.warn("fallback", ex); return defaultValue; });
```

### 5.4 失败重试

```java
public <T> CF<T> retry(Supplier<CF<T>> taskFactory, int times) {
    CF<T> task = taskFactory.get();
    return times <= 0 ? task : task.exceptionallyCompose(ex -> retry(taskFactory, times - 1));
}
```

### 5.5 Pipeline（生产者-消费者-加工）

```java
fetchData()                          // CF<Raw>
    .thenComposeAsync(this::clean)   // CF<Clean>  (扁平化)
    .thenApplyAsync(this::enrich)    // CF<Enriched>
    .thenAcceptAsync(this::save);    // CF<Void>
```

---

## 六、CF vs Reactor / Coroutine / 虚拟线程

| | CompletableFuture | Reactor (Mono/Flux) | Kotlin 协程 | Java 21 虚拟线程 |
| --- | --- | --- | --- | --- |
| **写法** | 链式 + lambda | 链式（操作符）| 顺序代码（suspend）| 顺序代码 |
| **线程模型** | 异步回调 | 异步回调 | 协程调度 | 虚拟线程 |
| **背压** | ❌ | ✅ Reactive Streams | ✅ Channel | n/a |
| **学习曲线** | 中 | 陡 | 中 | 平 |
| **诊断** | 链式栈跟踪难 | 难 | 中 | 易（栈是顺序的）|
| **典型场景** | Spring MVC / 网关 | Spring WebFlux 全异步 | Android / Kotlin 后端 | Loom 项目 |

**JDK 21 虚拟线程出现后，CF 在 IO 密集场景的优势削弱**——直接顺序写阻塞代码就能高并发。但 CF **依然适合任务编排**（多个并行调用合并）。

---

## 七、生产踩坑

### 7.1 没传线程池，commonPool 被打爆

详见 4.2。**生产规则**：所有 `*Async` 必须传自己的线程池。

### 7.2 join() 抛 CompletionException 包装异常

```java
try {
    return future.join();   // 异常被包成 CompletionException
} catch (CompletionException e) {
    throw e.getCause();      // 拿原始异常
}
```
`get()` 抛 ExecutionException，`join()` 抛 CompletionException——两个不同的包装。

### 7.3 链式中 ThreadLocal 丢失

详见 4.3。换 TTL。

### 7.4 链式异常没处理 → 静默失败

```java
cf.thenApply(...).thenAccept(...);   // 中途抛异常没人 log
```
**修复**：链尾必须 `.exceptionally(ex -> { log.error("", ex); return null; })` 或 `.whenComplete((r,e) -> if (e!=null) log.error("",e))`

### 7.5 thenCompose 写成 thenApply

```java
// 想链式调两个异步服务，写成：
CF<CF<X>> wrong = serviceA().thenApply(a -> serviceB(a));   // CF<CF<X>> 嵌套！
// 业务以为拿 CF<X>，结果拿了套娃，调用 .get() 得到的是个 CF 不是 X

// 正确：
CF<X> right = serviceA().thenCompose(a -> serviceB(a));     // 扁平化
```

### 7.6 allOf + 大量 CF → 性能塌缩

allOf 内部建一棵二叉树，每个非叶子节点是一个 CF。**几百个 CF 时这棵树深度可观，链路长**。
**修复**：超过 100 个 CF 考虑分批 + parallelStream，或换 ForkJoin。

---

## 八、面试高频追问

**Q1：Future 和 CompletableFuture 区别？**
- Future：只能 get（阻塞）+ cancel + isDone，无法编排
- CompletableFuture：50+ 编排方法（链式、合并、异常处理、超时）

**Q2：thenApply 和 thenCompose 区别？**
- thenApply 的函数返回普通值 X → CF<X>
- thenCompose 的函数返回 CF<X> → CF<X>（扁平化，避免 CF<CF<X>>）
类比 Stream.map vs flatMap。

**Q3：thenApply 和 thenApplyAsync 区别？**
- 同步：上游完成所在线程继续跑（可能是上游 supplyAsync 的线程，可能是当前线程）
- Async：扔到 ForkJoinPool.commonPool（不传 pool）或指定 pool 跑

**Q4：默认线程池有什么坑？**
ForkJoinPool.commonPool 是全 JVM 共享的，线程数 = CPU 核数 - 1。**阻塞任务（IO / DB）会把它占满**，连累其他 CF / parallelStream。生产必须传自己的线程池。

**Q5：怎么实现"等所有 N 个 CF 完成"？**
```java
CF<Void> all = CompletableFuture.allOf(futures.toArray(new CF[0]));
all.join();
List<X> results = futures.stream().map(CF::join).collect(toList());
```
allOf 返回 CF<Void>，结果丢弃，自己 join 取。

**Q6：怎么实现超时？**
- JDK 9+：`orTimeout(t,u)` / `completeOnTimeout(v,t,u)`
- JDK 8：自己用 ScheduledExecutorService 触发 `cf.completeExceptionally(...)`

**Q7：CF 链上抛异常会怎样？**
直接传播——后续 thenApply 不会执行，最终在 `exceptionally` / `handle` / `whenComplete` 处理。如果链尾没处理，**静默失败**——所以链尾必须显式异常处理。

**Q8：CompletableFuture 还需要吗？JDK 21 有了虚拟线程之后？**
还需要——**任务编排**（并行调用 N 个服务再聚合）虚拟线程不直接给。虚拟线程让 IO 阻塞代码"自动并行"，但显式编排仍要 CF 或类似框架。

**Q9：CF 的实现原理（高难度）？**
内部维护一个 `Completion` 链表（栈结构）：每次 thenApply / thenCompose 创建一个 Completion 节点入栈。当上游 complete（值或异常）时，遍历栈触发所有依赖。CAS 维护栈头。基于无锁队列 + 任务依赖图。

---

## 九、答题模板（90 秒话术）

> CompletableFuture 是 JDK 8 引入的现代异步编程接口，弥补 Future 的"阻塞 get + 不能编排 + 不能合并 + 异常包装"四大缺陷。
>
> 三大能力：
> - **异步执行**：runAsync / supplyAsync
> - **链式编排**：thenApply（同步转换） / thenCompose（扁平化嵌套 CF） / thenCombine（合并两个 CF）
> - **合并多个**：allOf（等所有）/ anyOf（任意一个）
> - **异常处理**：exceptionally / handle / whenComplete
>
> 每个方法都有 sync / Async / Async(pool) 三个版本。**生产必须传 pool**——不传走 ForkJoinPool.commonPool（全 JVM 共享，阻塞 IO 任务会打爆）。
>
> 经典坑：
> - **commonPool 被阻塞任务占满**——必传线程池
> - **thenCompose 误写 thenApply**——CF<CF<X>> 嵌套
> - **链尾未处理异常**——静默失败
> - **链路 ThreadLocal 丢失**——换 TTL
>
> 业务最高频用法：**网关 / BFF 并行调用 N 个微服务，allOf + join 聚合**——把 1500ms 串行降到 800ms 并行。

---

## 十、相关文档

- [线程池](./线程池.md) — CF 必备的执行器
- [ThreadLocal](./ThreadLocal.md) — CF 链路上下文传递
- [进程与线程](./进程与线程.md) — 虚拟线程与 CF 的关系
- [阻塞队列](./阻塞队列.md) — ForkJoinPool 内部用 Deque
