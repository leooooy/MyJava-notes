# Spring 事件机制

> 解耦"发布方"和"订阅方"的标准 Spring 工具。
> 这道题的"段位差"在两点：
> ① 能不能讲清 **`@TransactionalEventListener` 解决的真实问题** —— 事务里发事件、事件里写库的经典坑
> ② 能不能讲清 **同步事件 / 异步事件 / 跨服务事件** 各自适合什么
> 答得清这两块就是高级。

---

## 一、为什么需要事件机制

用户下单后要做 5 件事：

```java
@Transactional
public void createOrder(OrderReq req) {
    Order order = orderDao.insert(req);
    
    inventoryService.deduct(order);      // 扣库存
    couponService.consume(order);        // 用优惠券
    pointsService.award(order);          // 加积分
    smsService.send(order);              // 发短信
    statisticService.record(order);      // 写统计
}
```

**痛点**：
- ① OrderService 依赖 5 个下游 → **耦合严重**
- ② 加一个新业务（如"赠送会员天数"）要改 OrderService → **违反开闭原则**
- ③ 短信 / 统计这种**非核心流程** 不应该和下单事务绑死

事件机制把"主动调用"反转成"广播 + 订阅"：

```java
@Transactional
public void createOrder(OrderReq req) {
    Order order = orderDao.insert(req);
    publisher.publishEvent(new OrderCreatedEvent(this, order));   // ← 一行搞定
}

// 各下游各自订阅
@EventListener public void onOrderInventory(OrderCreatedEvent e) { ... }
@EventListener public void onOrderCoupon(OrderCreatedEvent e) { ... }
@EventListener public void onOrderPoints(OrderCreatedEvent e) { ... }
```

> **核心**：发布方不知道有谁在听，订阅方加新的不需要改发布方——**完全的开闭原则**。

---

## 二、核心概念与流程

```
                 ApplicationEvent (事件本身)
                         │
                         ▼
        ┌────────────────────────────────────┐
        │  ApplicationEventPublisher         │  发布器（ApplicationContext 自身实现）
        │  publishEvent(event)               │
        └────────────────┬───────────────────┘
                         │
                         ▼
        ┌────────────────────────────────────┐
        │  ApplicationEventMulticaster       │  事件多播器（默认 SimpleApplicationEventMulticaster）
        │  · 维护所有 listener 的注册表        │
        │  · 按事件类型匹配                    │
        │  · 同步或异步分发                    │
        └────────────────┬───────────────────┘
                         │
            ┌────────────┼─────────────┐
            ▼            ▼             ▼
        Listener1     Listener2     Listener3
       (实现接口)    (@EventListener)
```

### 2.1 三大角色

| 角色 | 接口 / 注解 | 职责 |
| --- | --- | --- |
| **事件** | `ApplicationEvent` 子类 | 携带数据 |
| **发布方** | `ApplicationEventPublisher` | 调 `publishEvent` |
| **订阅方** | `ApplicationListener` 或 `@EventListener` | 收到事件后执行逻辑 |

---

## 三、4 种监听写法

### 3.1 方法 1：实现 `ApplicationListener` 接口（古老写法）

```java
@Component
public class OrderListener implements ApplicationListener<OrderCreatedEvent> {
    @Override
    public void onApplicationEvent(OrderCreatedEvent event) { ... }
}
```

### 3.2 方法 2：`@EventListener`（现代写法，推荐）

```java
@Component
public class OrderListener {
    @EventListener
    public void onOrderCreated(OrderCreatedEvent event) { ... }
    
    @EventListener
    public void onMultiple(OrderCreatedEvent e) { ... }   // 一个 bean 可以有多个监听方法
    
    @EventListener(condition = "#root.event.amount > 1000")
    public void onBigOrder(OrderCreatedEvent e) { ... }   // SpEL 条件过滤
}
```

### 3.3 方法 3：`@Async` + `@EventListener`（异步）

```java
@Component
public class OrderListener {
    @Async
    @EventListener
    public void onOrderCreated(OrderCreatedEvent event) {
        smsService.send(event.getOrder());      // 在独立线程池执行
    }
}
```

### 3.4 方法 4：`@TransactionalEventListener`（事务感知）

```java
@Component
public class OrderListener {
    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void onOrderCreated(OrderCreatedEvent event) {
        notificationService.send(event.getOrder());   // 只在事务 commit 成功后执行
    }
}
```

---

## 四、`@TransactionalEventListener` 解决的问题（重点）

### 4.1 普通 `@EventListener` 的问题

```java
@Service
public class OrderService {
    @Transactional
    public void createOrder(OrderReq req) {
        Order order = orderDao.insert(req);
        publisher.publishEvent(new OrderCreatedEvent(this, order));   // 默认同步
        // ↓ 此时事件已经被 listener 处理完
        // ↓ 但事务还没 commit！
        if (...) throw new BizException();   // 事务回滚
    }
}

@EventListener
public void onOrderCreated(OrderCreatedEvent e) {
    smsService.send(e.getOrder());     // ❌ 已发短信但订单回滚 → 用户收到不存在订单的短信
}
```

**根因**：默认同步事件在**发布点**立即执行——此时事务还没 commit。

### 4.2 `@TransactionalEventListener` 的 4 个 phase

| Phase | 含义 | 适用 |
| --- | --- | --- |
| `BEFORE_COMMIT` | 事务 commit **前** | 想随事务一起提交的最后操作 |
| `AFTER_COMMIT`（默认） | 事务 commit **后** | **最常用**——非核心流程（短信、积分、统计） |
| `AFTER_ROLLBACK` | 事务回滚后 | 失败补偿（写失败日志、告警） |
| `AFTER_COMPLETION` | 事务完成后（不管 commit / rollback） | 资源清理 |

### 4.3 没有事务怎么办

```java
@TransactionalEventListener(
    phase = TransactionPhase.AFTER_COMMIT,
    fallbackExecution = true                  // 没有事务也执行
)
public void onEvent(OrderCreatedEvent e) { ... }
```

默认 `fallbackExecution = false` —— 没事务时**直接跳过**（不报错）。所以一定要确认调用方在事务里！

### 4.4 内部实现

```
事务里调 publishEvent
   ↓
Spring 检查当前线程是否有活跃事务
   ↓ 有
通过 TransactionSynchronizationManager.registerSynchronization 注册一个回调
   ↓
事务 commit / rollback 时由 TransactionSynchronization 触发回调
   ↓
回调里执行 listener 方法
```

---

## 五、Spring Boot 内置事件

| 事件 | 触发时机 |
| --- | --- |
| `ApplicationStartingEvent` | run 入口最早 |
| `ApplicationEnvironmentPreparedEvent` | Environment 准备好（**加载 application.yml 时机**） |
| `ApplicationContextInitializedEvent` | Initializer 执行后 |
| `ApplicationPreparedEvent` | 主配置类加载后、refresh 前 |
| `ContextRefreshedEvent` | refresh 完成（业务"启动好了"） |
| `ApplicationStartedEvent` | refresh 完成、Runner 调用前 |
| `ApplicationReadyEvent` | **Runner 调用后，应用真正可用**（对外注册的最佳时机） |
| `ApplicationFailedEvent` | 启动失败 |
| `ContextClosedEvent` | 容器关闭 |

详见 [SpringBoot启动流程.md](SpringBoot启动流程.md)。

---

## 六、异步事件

### 6.1 启用

```java
@EnableAsync
@SpringBootApplication
public class App { }

@Component
public class AsyncListener {
    @Async
    @EventListener
    public void onEvent(OrderCreatedEvent e) { ... }
}
```

### 6.2 配置专用线程池（必备）

```java
@Configuration
public class AsyncConfig implements AsyncConfigurer {
    @Override
    public Executor getAsyncExecutor() {
        ThreadPoolTaskExecutor exec = new ThreadPoolTaskExecutor();
        exec.setCorePoolSize(10);
        exec.setMaxPoolSize(50);
        exec.setQueueCapacity(500);
        exec.setThreadNamePrefix("async-event-");
        exec.setRejectedExecutionHandler(new ThreadPoolExecutor.CallerRunsPolicy());
        exec.initialize();
        return exec;
    }
}
```

> **重要**：默认 `SimpleAsyncTaskExecutor` 每次都新建线程，**不复用**——并发高时会爆。生产必须显式配 `ThreadPoolTaskExecutor`。

### 6.3 多 Executor 区分

```java
@Async("smsExecutor")      // 指定 Executor bean
@EventListener
public void onEvent(...) { ... }
```

---

## 七、事件传递（事件返回值）

```java
@Component
public class L1 {
    @EventListener
    public NotifyEvent onOrder(OrderCreatedEvent e) {
        return new NotifyEvent(...);     // 返回值会被自动作为新事件发布
    }
}

@Component
public class L2 {
    @EventListener
    public void onNotify(NotifyEvent e) { ... }
}
```

**用途**：事件链——A 触发 B，B 触发 C。但**链长容易乱**，超过 2 层就别用了。

---

## 八、生产踩坑

### 坑 1：事务里发事件，listener 在事务前执行（前面详述）

**修法**：用 `@TransactionalEventListener(phase = AFTER_COMMIT)`。

### 坑 2：异步事件吞异常

```java
@Async
@EventListener
public void onEvent(...) {
    throw new RuntimeException();    // ❌ 默认被默默吞掉
}
```

`@Async` 默认异常没人接住。**修法**：实现 `AsyncUncaughtExceptionHandler`：

```java
@Configuration
public class AsyncConfig implements AsyncConfigurer {
    @Override
    public AsyncUncaughtExceptionHandler getAsyncUncaughtExceptionHandler() {
        return (ex, method, params) -> log.error("async err in {}", method, ex);
    }
}
```

### 坑 3：自调用 `@EventListener` 失效

```java
@Service
public class A {
    public void doSomething() {
        publisher.publishEvent(new MyEvent());     // ✅ 正常
        this.onEvent(new MyEvent());                // ❌ 直接调用，没经过事件机制
    }
    @EventListener public void onEvent(MyEvent e) { ... }
}
```

`@EventListener` 不是 AOP，**自调用本身没问题**——但和"用事件解耦"的初心相悖。如果代码里直接 `this.onEvent` 不走 publisher，就失去了事件的意义。

### 坑 4：`@TransactionalEventListener` 在没事务时不执行

```java
public void noTransactionalMethod() {
    publisher.publishEvent(new MyEvent());     // 没事务
}
```

默认 listener **不执行**（被静默跳过，**不报错**）。
**修法**：要么确保发布在事务里；要么 `@TransactionalEventListener(fallbackExecution = true)`。

### 坑 5：异步事件 + 数据库操作 + 事务

```java
@Transactional
public void outer() {
    publisher.publishEvent(...);          // 异步事件
    // 事务还在进行
}

@Async @EventListener @Transactional
public void onEvent(MyEvent e) {
    dao.insert(...);            // 在新线程的新事务里
}
```

`@Async` 跨线程——事务上下文丢失。listener 里如果要写库，必须是**新事务**（`@Transactional` 在新线程开新事务，不会复用外层）。

### 坑 6：事件类设计为可变对象

```java
public class OrderCreatedEvent extends ApplicationEvent {
    private Order order;
    public void setOrder(Order o) { this.order = o; }   // ❌ listener 改了影响其他 listener
}
```

**规约**：事件对象做成 **不可变**（final 字段、无 setter）。

### 坑 7：`@TransactionalEventListener` 用错 phase

```java
@TransactionalEventListener(phase = BEFORE_COMMIT)
public void onEvent(...) {
    smsService.send(...);    // ❌ commit 前发短信，commit 失败用户照样收到
}
```

非补偿性操作（短信、推送）必须用 `AFTER_COMMIT`；只有"和事务一起提交"的强一致需求才用 `BEFORE_COMMIT`。

### 坑 8：监听 `ContextRefreshedEvent` 在父子容器场景被多次触发

Web 项目（非 Spring Boot）有 Root 和 Servlet 两个 ApplicationContext，每个都会触发 `ContextRefreshedEvent`。监听器写在 Root 的 bean 里，**会被触发两次**。

**修法**：判断事件源 `if (event.getApplicationContext().getParent() == null)`，只处理 Root 的事件。Spring Boot 单上下文不存在这问题。

---

## 九、面试高频追问

**Q1：Spring 事件机制是什么模式？**
A：**观察者模式**（Observer）。`ApplicationEvent` 是被观察对象的状态变化，`ApplicationListener` 是观察者，`ApplicationEventMulticaster` 负责通知。

**Q2：`ApplicationEventPublisher` 和 `ApplicationEventMulticaster` 区别？**
A：
- **Publisher**：业务接口，业务调 `publishEvent`
- **Multicaster**：内部实现，维护 listener 注册表 + 分发逻辑

`ApplicationContext` 自身实现 `Publisher` 接口；内部聚合一个 `Multicaster` 实际干活。

**Q3：`@EventListener` 和实现 `ApplicationListener` 接口区别？**
A：① 写法：注解派 vs 接口派；② 灵活度：注解可以多个、可加 SpEL `condition`；③ 多事件：注解派一个方法可以监听多种事件 `@EventListener({A.class, B.class})`；④ 推荐：**注解派**。

**Q4：事件默认是同步还是异步？**
A：**同步**——在调用 `publishEvent` 的线程里直接执行所有 listener。要异步加 `@Async`，并 `@EnableAsync`。

**Q5：`@TransactionalEventListener` 解决什么问题？**
A：解决"在事务里发事件、listener 在事务 commit 前就执行"导致的不一致。比如订单事务里发"已下单"事件，listener 发短信——如果用普通 `@EventListener`，事务回滚时短信已发。改用 `@TransactionalEventListener(phase = AFTER_COMMIT)`，commit 后才执行。

**Q6：`@TransactionalEventListener` 的 4 个 phase？**
A：`BEFORE_COMMIT` / `AFTER_COMMIT`（默认） / `AFTER_ROLLBACK` / `AFTER_COMPLETION`。最常用 `AFTER_COMMIT`——非核心流程；`AFTER_ROLLBACK` 用于失败补偿；`BEFORE_COMMIT` 用于强一致最后操作。

**Q7：异步事件的线程池怎么配？**
A：默认 `SimpleAsyncTaskExecutor` **每次新建线程不复用**——必须显式配 `ThreadPoolTaskExecutor`。配置项：corePoolSize / maxPoolSize / queueCapacity / 拒绝策略 / 异常处理器（`AsyncUncaughtExceptionHandler`）。

**Q8：跨服务事件怎么发？**
A：Spring 事件**只在单 JVM 内**有效。跨服务用 MQ（RocketMQ / Kafka）：发布方发到 MQ topic，订阅方从 topic 消费——和事件机制语义一致，跨进程版本。Spring Cloud Bus 是这套机制的简化封装。

**Q9：`@EventListener(condition = "...")` 的 SpEL 怎么写？**
A：`#root.event` 是事件对象，`#root.args` 是参数数组。常用：

```java
@EventListener(condition = "#event.amount > 1000")
@EventListener(condition = "#root.event.userType == 'VIP'")
```

注意 SpEL 编译期不报错——拼错只在运行时静默不触发。

**Q10：事件机制和 MQ 的差别？**
A：
- **作用域**：事件在 JVM 内，MQ 跨进程
- **可靠性**：事件丢了就丢了，MQ 持久化保证至少一次
- **顺序**：事件按注册顺序，MQ 取决于 topic 分区
- **削峰填谷**：事件不能（同步线程池），MQ 能
- **选型**：**JVM 内解耦用事件，跨服务异步用 MQ**

---

## 十、答题模板（60 秒）

> Spring 事件机制是 **观察者模式** 的实现：发布方调 `ApplicationEventPublisher.publishEvent`，订阅方实现 `ApplicationListener` 或加 `@EventListener` 注解，由 `ApplicationEventMulticaster` 按事件类型分发。
>
> **4 种监听方式**：① 实现 `ApplicationListener`（古老）；② **`@EventListener`（推荐，可加 SpEL `condition`）**；③ `@Async + @EventListener` 异步；④ `@TransactionalEventListener(phase = AFTER_COMMIT)` 事务感知。
>
> **`@TransactionalEventListener` 解决的真实问题**：默认事件在 publishEvent **同线程同步**执行，事务还没 commit；如果在事务里发事件、listener 发短信——事务回滚时短信已发，数据不一致。改用 `AFTER_COMMIT` phase 在 commit 后才执行。phase 还有 `BEFORE_COMMIT` / `AFTER_ROLLBACK`（失败补偿） / `AFTER_COMPLETION`（清理）。
>
> **异步事件**：`@EnableAsync` + `@Async`，**必须显式配 ThreadPoolTaskExecutor**（默认 SimpleAsyncTaskExecutor 不复用线程，并发高会爆）。
>
> **事件 vs MQ**：JVM 内解耦用事件，跨服务异步用 MQ。事件丢了就丢了，MQ 有持久化、削峰、顺序保证。
>
> **生产高频坑**：① 事务里发事件 listener 提前执行（用 `@TransactionalEventListener`）；② `@Async` 默认吞异常（配 `AsyncUncaughtExceptionHandler`）；③ `fallbackExecution=false` 默认无事务时不执行；④ 异步线程池没配导致线程爆炸；⑤ 事件对象做成可变带 setter（应不可变）。

---

## 十一、相关文档

- 前置：[设计模式.md](设计模式.md) — 观察者模式
- 前置：[Spring事务.md](Spring事务.md) — `@TransactionalEventListener` 依赖事务管理
- 配套：[SpringAsync与Scheduling.md](SpringAsync与Scheduling.md) — `@Async` 详解
- 配套：[SpringBoot启动流程.md](SpringBoot启动流程.md) — Spring Boot 启动期 8 个事件
- 配套：[../MQ/](../MQ/) — 跨服务事件用 MQ
