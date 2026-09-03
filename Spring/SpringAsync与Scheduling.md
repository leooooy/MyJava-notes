# Spring Async 与 Scheduling

> 异步编程和定时任务两件事面试经常一起问。
> 这道题的"段位差"在三点：
> ① 能不能讲清 **`@Async` 默认线程池的坑** —— 90% 的事故都是这一个原因
> ② 能不能讲清 **`@Async` 失效的根因** —— 和 `@Transactional` 同源
> ③ 能不能讲清 **`@Scheduled` 单实例多实例的坑**和分布式定时任务的解决方案
> 答得清这三块就是高级。

---

## 一、`@Async`：异步执行

### 1.1 解决的问题

```java
// 同步：必须等下游全部返回
public ApiResp<?> sendNotice(Long userId) {
    smsService.send(userId);             // 200ms
    emailService.send(userId);           // 500ms
    pushService.send(userId);            // 300ms
    return ApiResp.success();            // 总耗时 1000ms
}

// 异步：发布即返回
@Async public void sendSms(Long uid) { ... }
@Async public void sendEmail(Long uid) { ... }
@Async public void sendPush(Long uid) { ... }

public ApiResp<?> sendNotice(Long userId) {
    sendSms(userId); sendEmail(userId); sendPush(userId);   // 三个并行
    return ApiResp.success();            // 总耗时 ~10ms
}
```

### 1.2 启用 + 用法

```java
@EnableAsync                                // ★ 启动类加
@SpringBootApplication
public class App { }

@Service
public class NotifyService {
    @Async
    public void send(Long userId) { ... }              // void 返回
    
    @Async
    public CompletableFuture<String> query(Long id) {  // 有返回值用 Future
        return CompletableFuture.completedFuture("done");
    }
}
```

### 1.3 底层原理

```
@EnableAsync
└─ @Import(AsyncConfigurationSelector)
   └─ ProxyAsyncConfiguration / AspectJAsyncConfiguration
      └─ AsyncAnnotationBeanPostProcessor (BPP)
         └─ 给标了 @Async 的方法生成代理（JDK 或 CGLIB）

调用流程
└─ 业务调 service.send(uid)
   └─ 经过 AsyncExecutionInterceptor.invoke()
      ├─ 找到方法对应的 Executor（默认 / @Async("xxx") 指定）
      ├─ 把 invocation 包成 Runnable 提交到 Executor
      └─ 立即返回 null（void）或 Future
```

### 1.4 默认线程池的坑（**致命**）

Spring Boot 2.x 之前 / 没显式配置时，默认 `Executor` 是 **`SimpleAsyncTaskExecutor`**：

```java
// SimpleAsyncTaskExecutor 内部
public void execute(Runnable task) {
    Thread thread = new Thread(task);     // ❌ 每次新建！
    thread.start();
}
```

**每次都 new 一个线程，不复用**——并发高时会爆：
- ① 内存：每个线程默认 1MB 栈，1 万个并发 → 10GB 直接 OOM
- ② CPU：上下文切换爆炸
- ③ 线程数太多 → JVM 拒绝创建 → `OutOfMemoryError: unable to create new native thread`

**生产必须显式配 `ThreadPoolTaskExecutor`**。

---

## 二、生产配置 `@Async` 线程池

### 2.1 推荐配置

```java
@Configuration
@EnableAsync
public class AsyncConfig implements AsyncConfigurer {
    
    @Override
    public Executor getAsyncExecutor() {
        ThreadPoolTaskExecutor exec = new ThreadPoolTaskExecutor();
        exec.setCorePoolSize(10);                                              // 核心线程数
        exec.setMaxPoolSize(50);                                               // 最大线程数
        exec.setQueueCapacity(500);                                            // 队列容量
        exec.setKeepAliveSeconds(60);                                          // 空闲存活
        exec.setThreadNamePrefix("async-");                                    // 线程名前缀（排查必备）
        exec.setRejectedExecutionHandler(new ThreadPoolExecutor.CallerRunsPolicy());  // 拒绝策略
        exec.setWaitForTasksToCompleteOnShutdown(true);                        // 优雅停机
        exec.setAwaitTerminationSeconds(60);                                   // 等待时长
        exec.initialize();
        return exec;
    }
    
    @Override
    public AsyncUncaughtExceptionHandler getAsyncUncaughtExceptionHandler() {
        return (ex, method, params) -> log.error("async err in {}: {}", method.getName(), ex.getMessage(), ex);
    }
}
```

### 2.2 多线程池

不同业务用不同线程池，避免互相干扰：

```java
@Bean("smsExecutor")
public Executor smsExecutor() {
    ThreadPoolTaskExecutor e = new ThreadPoolTaskExecutor();
    e.setCorePoolSize(5); e.setMaxPoolSize(20);
    e.setThreadNamePrefix("sms-"); e.initialize();
    return e;
}

@Bean("dbExecutor")
public Executor dbExecutor() { ... }

// 使用
@Async("smsExecutor")
public void sendSms(...) { ... }
```

### 2.3 Spring Boot 2.1+ 自动配置

Spring Boot 2.1+ 提供 `TaskExecutionAutoConfiguration`，可通过配置文件直接定义：

```yaml
spring:
  task:
    execution:
      pool:
        core-size: 10
        max-size: 50
        queue-capacity: 500
        keep-alive: 60s
      thread-name-prefix: async-
```

**仍然推荐显式配 Java Bean**——配置项有限，自定义异常处理器要 Java。

---

## 三、`@Async` 失效的常见场景

和 `@Transactional` 同源（都是 AOP）：

### 失效 1：自调用

```java
@Service
public class A {
    public void outer() {
        inner();           // ❌ this.inner 不走代理，同步执行
    }
    @Async
    public void inner() { ... }
}
```

### 失效 2：方法非 public

`@Async` 走代理——private / package-private 不能被代理。

### 失效 3：`final` / `static` 方法

CGLIB 代理子类重写不了 final；static 不属于实例。

### 失效 4：bean 没被 Spring 管理

`new A()` 出来的对象没经过 BPP——没代理。

### 失效 5：`@EnableAsync` 没加

启动类忘了加 `@EnableAsync`，所有 `@Async` 都失效——**且不报错**。

### 失效 6：返回值类型不对

`@Async` 方法的返回值只能是 `void` / `Future` / `CompletableFuture`。返回 `String` 等被静默退化为同步执行。

修法详见 [AOP.md](AOP.md) 的失效场景节。

---

## 四、`@Async` 与事务的坑

### 4.1 子线程拿不到事务上下文

```java
@Transactional
public void outer() {
    asyncMethod();    // ❌ @Async 跨线程，事务上下文丢失
}

@Async
public void asyncMethod() {
    dao.insert(...);   // 不在外层事务里
}
```

事务通过 `ThreadLocal` 绑定 Connection，跨线程后子线程独立 ThreadLocal，看不到外层事务。

**修法**：
- 子线程独立开事务：`@Async @Transactional`（但是新事务，与外层无关）
- 或者**先 commit 再异步**——把 `@Async` 调用放在外层事务方法**外面**：

```java
@Service
public class A {
    @Resource private B b;
    @Resource private AsyncService async;
    
    public void outer() {
        b.doInTx();             // 走完整事务
        async.sendNotify();     // 事务 commit 后再异步
    }
}
```

### 4.2 异步事件 + 事务

更推荐组合：`@TransactionalEventListener(AFTER_COMMIT) + @Async`：

```java
@Transactional
public void createOrder(...) {
    Order o = ...;
    publisher.publishEvent(new OrderCreatedEvent(this, o));
}

@TransactionalEventListener(phase = AFTER_COMMIT)
@Async
public void onOrderCreated(OrderCreatedEvent e) {
    smsService.send(e.getOrder());
}
```

详见 [Spring事件机制.md](Spring事件机制.md)。

---

## 五、上下文传递：MDC / TraceId / 用户上下文

子线程没有父线程的 ThreadLocal——MDC 日志、用户上下文、Sleuth TraceId 都丢失。

### 5.1 用 `TaskDecorator` 装饰任务

```java
public class ContextCopyingDecorator implements TaskDecorator {
    @Override
    public Runnable decorate(Runnable runnable) {
        Map<String, String> mdc = MDC.getCopyOfContextMap();        // 复制
        UserContext userCtx = UserContextHolder.get();
        return () -> {
            try {
                if (mdc != null) MDC.setContextMap(mdc);             // 子线程恢复
                if (userCtx != null) UserContextHolder.set(userCtx);
                runnable.run();
            } finally {
                MDC.clear();                                          // 清理
                UserContextHolder.clear();
            }
        };
    }
}

// 注入到 Executor
@Bean
public Executor asyncExecutor() {
    ThreadPoolTaskExecutor e = new ThreadPoolTaskExecutor();
    e.setTaskDecorator(new ContextCopyingDecorator());     // ★
    ...
    return e;
}
```

### 5.2 阿里 TTL（TransmittableThreadLocal）

更优雅的方案：

```xml
<dependency>
    <groupId>com.alibaba</groupId>
    <artifactId>transmittable-thread-local</artifactId>
</dependency>
```

```java
private static final TransmittableThreadLocal<UserContext> CTX = new TransmittableThreadLocal<>();

// 包装 Executor
Executor exec = TtlExecutors.getTtlExecutor(originalExecutor);
```

TTL 自动在提交任务时捕获、执行时恢复——完全透明。

---

## 六、`@Scheduled`：定时任务

### 6.1 启用 + 用法

```java
@EnableScheduling                  // 启动类加
@SpringBootApplication
public class App { }

@Component
public class CronJob {
    @Scheduled(cron = "0 0 2 * * ?")             // 每天凌晨 2 点
    public void daily() { ... }
    
    @Scheduled(fixedRate = 60_000)               // 每 60 秒（不等上次结束）
    public void everyMinute() { ... }
    
    @Scheduled(fixedDelay = 60_000)              // 上次结束后 60 秒（等上次结束）
    public void afterEach() { ... }
    
    @Scheduled(initialDelay = 10_000, fixedDelay = 60_000)   // 启动后 10s 第一次
    public void delayed() { ... }
}
```

### 6.2 Cron 表达式

Spring Cron 6 段（**和 Linux Cron 不同**）：

```
秒 分 时 日 月 周
0  0  2  *  *  ?
```

| 字段 | 范围 | 特殊字符 |
| --- | --- | --- |
| 秒 | 0-59 | `, - * /` |
| 分 | 0-59 | `, - * /` |
| 时 | 0-23 | `, - * /` |
| 日 | 1-31 | `, - * / ? L W` |
| 月 | 1-12 / JAN-DEC | `, - * /` |
| 周 | 0-7 / SUN-SAT | `, - * / ? L #` |

`?` 用于"日"和"周"互斥（这两个不能同时用具体值）。

### 6.3 fixedRate vs fixedDelay vs cron

```
fixedRate=60s
  ┌─T1─┐                        T1 = 5s 后结束
  └────┴───────T2 启动──────────  T2 在 60s 时启动（不管 T1 是否结束）
        
fixedDelay=60s
  ┌─T1─┐                        T1 = 5s 后结束
        └─60s 间隔──┬─T2─┐       T2 在 65s 启动（T1 结束 + 60s）
                    └────┘
                    
cron="0 0 2 * * ?"
  ┌─每天 02:00 触发─┐
```

**生产选择**：
- 定时报表 / 每天 / 每周 → `cron`
- 心跳 / 状态轮询 → `fixedRate`
- 任务有先后依赖、不能并发 → `fixedDelay`

### 6.4 默认是单线程

`@Scheduled` 默认所有任务用 **同一个单线程** `TaskScheduler`——**一个任务慢拖累所有任务**。

**修法**：配置专用线程池：

```java
@Configuration
public class ScheduleConfig implements SchedulingConfigurer {
    @Override
    public void configureTasks(ScheduledTaskRegistrar registrar) {
        ThreadPoolTaskScheduler scheduler = new ThreadPoolTaskScheduler();
        scheduler.setPoolSize(10);
        scheduler.setThreadNamePrefix("schedule-");
        scheduler.setWaitForTasksToCompleteOnShutdown(true);
        scheduler.initialize();
        registrar.setTaskScheduler(scheduler);
    }
}
```

或简单点用 Spring Boot 自动配置：

```yaml
spring:
  task:
    scheduling:
      pool:
        size: 10
      thread-name-prefix: schedule-
```

---

## 七、分布式定时任务（生产必备）

### 7.1 痛点

```java
@Scheduled(cron = "0 0 2 * * ?")
public void dailyJob() {
    // ❌ 部署 3 个实例 → 同时跑 3 次 → 数据重复 / 事故
}
```

### 7.2 方案 1：ShedLock（轻量推荐）

加分布式锁，同一时刻只允许一个实例跑：

```xml
<dependency>
    <groupId>net.javacrumbs.shedlock</groupId>
    <artifactId>shedlock-spring</artifactId>
</dependency>
<dependency>
    <groupId>net.javacrumbs.shedlock</groupId>
    <artifactId>shedlock-provider-redis-spring</artifactId>
</dependency>
```

```java
@EnableSchedulerLock(defaultLockAtMostFor = "10m")
@Configuration
public class ShedLockConfig {
    @Bean
    public LockProvider lockProvider(RedisConnectionFactory cf) {
        return new RedisLockProvider(cf);
    }
}

@Component
public class CronJob {
    @Scheduled(cron = "0 0 2 * * ?")
    @SchedulerLock(name = "dailyJob", lockAtLeastFor = "5m", lockAtMostFor = "30m")
    public void dailyJob() { ... }
}
```

**原理**：每次执行前往 Redis / DB 写一个 lock 记录，`lockAtMostFor` 是锁过期（防止异常时锁不释放），`lockAtLeastFor` 是最少持有（防止快速跑完后被其他实例又抢到）。

### 7.3 方案 2：XXL-Job（功能完备）

国内大厂主流——独立调度中心 + 执行器：

```
[XXL-Job 调度中心]   ←─ 触发 ──→   [Executor 1]
       │                          [Executor 2]
       │                          [Executor 3]
   按调度策略选一台执行（路由策略：随机 / 轮询 / 一致性 Hash / 故障转移）
```

**特点**：① UI 配置任务；② 失败重试；③ 任务编排；④ 日志查看。

### 7.4 方案 3：Quartz / Elastic-Job

| 方案 | 特点 |
| --- | --- |
| **Quartz** | 老牌，集群模式靠 DB 表锁，运维复杂 |
| **Elastic-Job**（当当开源） | 分片调度，超大数据量场景 |
| **PowerJob** | 较新，功能完整、轻量 |

### 7.5 选型决策

| 场景 | 推荐 |
| --- | --- |
| 单实例 + 简单定时 | `@Scheduled` |
| 多实例 + 简单需求 | **ShedLock** |
| 大数据量需要分片 | Elastic-Job / XXL-Job 分片模式 |
| 需要 UI 管理任务 | **XXL-Job** / PowerJob |
| 复杂任务编排 | XXL-Job / Airflow（重型） |

---

## 八、生产踩坑

### 坑 1：`@Async` 用默认 Executor 导致线程爆炸（前面详述）

线上某次大促，没显式配线程池——并发 10 万 → JVM 创建 10 万线程 → OOM。

**修法**：每个项目模板都强制要求显式配 `ThreadPoolTaskExecutor` + 拒绝策略。

### 坑 2：`@Scheduled` 单线程被慢任务拖死

```java
@Scheduled(fixedRate = 60_000) public void task1() { /* 5 分钟 */ }
@Scheduled(fixedRate = 60_000) public void task2() { /* 1 秒 */ }
```

task1 跑 5 分钟，task2 整整 5 分钟没机会跑——**单线程被堵**。

**修法**：配置 `ThreadPoolTaskScheduler`，每个任务独立线程。

### 坑 3：分布式部署导致定时任务重复执行

3 个实例、同一个 `@Scheduled` → 凌晨 2 点同时执行 3 次。线上事故。

**修法**：用 ShedLock 加锁，或用 XXL-Job 等调度中心。

### 坑 4：`@Async` 抛异常没人看

线上几个月一直丢消息——异步方法 NPE 默认被吞。
**修法**：实现 `AsyncUncaughtExceptionHandler` 接口打日志或上报。

### 坑 5：拒绝策略默认抛异常导致任务丢

`ThreadPoolTaskExecutor` 默认 `AbortPolicy` 拒绝时抛 `RejectedExecutionException`——业务里如果调用方不处理，**任务直接被吞掉**。
**修法**：根据业务选拒绝策略：
- `CallerRunsPolicy`：由调用方线程执行（**推荐**——给业务回压）
- `DiscardPolicy`：静默丢弃（**生产慎用**）
- `DiscardOldestPolicy`：丢最老的
- 自定义：写到 MQ 重试 / 写日志告警

### 坑 6：`@Async` 方法在同一个 bean 里调用，事务和异步同时失效

```java
@Service
public class A {
    @Transactional
    public void outer() {
        this.inner();    // ❌ 既不异步也不在新事务
    }
    @Async @Transactional(propagation = REQUIRES_NEW)
    public void inner() { ... }
}
```

self-invocation 直接绕过代理。修法：见 [AOP.md](AOP.md)。

### 坑 7：定时任务的分布式锁没释放

ShedLock 程序异常崩溃 / Kill -9 没机会释放锁——下次执行会等到 `lockAtMostFor` 过期才能再跑。
**修法**：`lockAtMostFor` 设合理（任务最大耗时的 2 倍），别设太长。

### 坑 8：MDC 跨线程丢失

异步任务里日志没 traceId——排查时根本串不起来。
**修法**：用 `TaskDecorator` 复制 MDC，或用 TTL（TransmittableThreadLocal）。

---

## 九、面试高频追问

**Q1：`@Async` 怎么实现的？**
A：本质 AOP。`@EnableAsync` 注册 `AsyncAnnotationBeanPostProcessor`，BPP 在 `postProcessAfterInitialization` 给标注 `@Async` 的方法生成代理。调用时进入 `AsyncExecutionInterceptor`，把 invocation 包成 Runnable 提交到 Executor，立即返回 null/Future。

**Q2：`@Async` 为什么默认线程池有坑？**
A：早期默认 `SimpleAsyncTaskExecutor` **每次新建线程不复用**——并发高时线程数爆炸，JVM 拒绝创建 → OOM 或 `unable to create new native thread`。生产必须显式配 `ThreadPoolTaskExecutor`。Spring Boot 2.1+ 提供自动配置 `spring.task.execution.*`，但建议自己写 Bean 以便配异常处理器和 TaskDecorator。

**Q3：`@Async` 失效场景？**
A：和 `@Transactional` 同源：① this 自调用；② 非 public 方法；③ final / static；④ bean 没纳入 Spring；⑤ `@EnableAsync` 没加；⑥ 返回值类型不对（必须 void / Future / CompletableFuture）。

**Q4：`@Async` 能拿到外层事务吗？**
A：**不能**。事务通过 `ThreadLocal` 绑定 Connection，子线程独立 ThreadLocal——拿不到。子线程要写库要么独立开新事务，要么用 `@TransactionalEventListener(AFTER_COMMIT) + @Async` 组合（事务 commit 后才异步发送）。

**Q5：`fixedRate` 和 `fixedDelay` 区别？**
A：① `fixedRate`：以**任务开始**为基准的固定间隔——上次没结束下次也会启（到时间就跑）；② `fixedDelay`：以**上次结束**为基准——必须等上次跑完才开始计时。心跳类用 fixedRate，串行依赖类用 fixedDelay。

**Q6：Spring Cron 表达式几段？**
A：**6 段**（秒 分 时 日 月 周）——和 Linux Cron 5 段不同。`?` 用于日和周互斥。

**Q7：`@Scheduled` 默认多少线程？怎么改？**
A：默认**单线程**——一个任务慢拖累所有。修法：实现 `SchedulingConfigurer`，注册 `ThreadPoolTaskScheduler`；或 `spring.task.scheduling.pool.size=10`。

**Q8：分布式部署怎么避免定时任务重复执行？**
A：① **ShedLock**（轻量）：基于 Redis / DB 加锁，同一时刻只一个实例跑；② **XXL-Job / PowerJob**（功能全）：独立调度中心 + 执行器路由；③ Elastic-Job：大数据量分片场景。中小项目用 ShedLock，复杂业务用 XXL-Job。

**Q9：怎么把 MDC / TraceId 传到 `@Async` 子线程？**
A：① 实现 `TaskDecorator` 在提交时捕获 MDC、执行时恢复；② 或用阿里 **TTL（TransmittableThreadLocal）** —— 把 ThreadLocal 替换成 TTL，配合 `TtlExecutors.getTtlExecutor` 包装线程池，自动透明传递。

**Q10：`@Async` 有返回值怎么用？**
A：返回 `CompletableFuture<T>`：

```java
@Async public CompletableFuture<User> queryUser(Long id) {
    return CompletableFuture.completedFuture(...);
}

CompletableFuture<User> f1 = svc.queryUser(1L);
CompletableFuture<User> f2 = svc.queryUser(2L);
CompletableFuture.allOf(f1, f2).join();
```

并发调多个异步方法、用 `allOf` / `anyOf` 编排——比手写线程池更简洁。

---

## 十、答题模板（60 秒）

> **`@Async`**：基于 AOP 的异步执行机制。`@EnableAsync` 启用 + `AsyncAnnotationBeanPostProcessor` 给方法生成代理，调用时把任务提交到 Executor 立即返回。
>
> **生产必踩坑**：默认 `SimpleAsyncTaskExecutor` 每次新建线程不复用——并发高时 OOM。**必须显式配 `ThreadPoolTaskExecutor`**：核心/最大线程数、队列容量、线程名前缀（排查必备）、拒绝策略（推荐 `CallerRunsPolicy`）、`AsyncUncaughtExceptionHandler`（默认吞异常）。
>
> **失效场景** 和 `@Transactional` 同源：this 自调用、private/final/static、bean 没纳入 Spring、`@EnableAsync` 漏加、返回值类型错。**事务上下文跨线程丢失**——子线程要写库独立开事务，或用 `@TransactionalEventListener(AFTER_COMMIT) + @Async` 组合。**MDC / TraceId 跨线程丢失** 用 `TaskDecorator` 或 TTL 解决。
>
> **`@Scheduled`**：`fixedRate`（开始时间基准、可并发）、`fixedDelay`（结束时间基准、串行）、`cron`（6 段：秒分时日月周）。**默认单线程**——配 `ThreadPoolTaskScheduler` 或 `spring.task.scheduling.pool.size`。
>
> **分布式重复执行问题**：3 个实例同时跑相同 `@Scheduled` → 数据重复。修法：① **ShedLock**（轻量、Redis/DB 锁）；② **XXL-Job / PowerJob**（独立调度中心、UI 管理、路由策略）；③ Elastic-Job（分片场景）。

---

## 十一、相关文档

- 前置：[AOP.md](AOP.md) — `@Async` 失效场景的根因
- 前置：[Spring事务.md](Spring事务.md) — 事务跨线程的限制
- 配套：[Spring事件机制.md](Spring事件机制.md) — `@Async + @EventListener` 组合
- 配套：[../Concurrency/线程池.md](../Concurrency/线程池.md) — ThreadPoolExecutor 参数详解
