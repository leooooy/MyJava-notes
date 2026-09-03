# Spring WebFlux

> Spring 5 引入的响应式 Web 框架。
> 这道题面试的"段位差"在三点：
> ① 能不能讲清 **响应式编程解决什么问题**（不是"快"，是"少线程支撑高并发"）
> ② 能不能讲清 **Mono / Flux 操作符** 的核心几个（map / flatMap / zip / subscribe）
> ③ 能不能讲清 **WebFlux 不适合什么场景** —— 答得出短板才是高级
> 答得清这三块就是高级。

---

## 一、为什么需要响应式

### 1.1 传统 Servlet 的瓶颈

```
传统 Spring MVC（Servlet）
─────────────────────────
请求 1 ──→ 线程 1（占用） ──→ 调 DB ──→ 等响应（线程阻塞） ──→ 释放
请求 2 ──→ 线程 2
请求 3 ──→ 线程 3
...
请求 N ──→ 线程池满 ──→ 拒绝

问题：每个请求独占 1 线程；高并发场景线程数 = 并发数；线程切换开销大
```

每个 Tomcat 工作线程 1MB 栈——1 万并发要 10GB 栈内存。

### 1.2 WebFlux 的解法

```
WebFlux（Reactor + Netty）
─────────────────────────
请求 1 ──→ EventLoop（不占）──→ 提交 IO 操作 ──→ 立即返回
请求 2 ──→ EventLoop（同一组线程）
请求 3 ──→ ...
IO 完成 ──→ 回调 ──→ 继续处理 ──→ 写响应

关键：少量线程（CPU * 2）支撑高并发
```

**用 4 个 EventLoop 线程支撑 10 万并发不是问题**——只要别有任何阻塞操作。

### 1.3 真实案例

WebFlux 不是"更快"——单请求耗时和 MVC 差不多。它是 **资源利用率高**：

| 维度 | Spring MVC | WebFlux |
| --- | --- | --- |
| 单请求 RT | 50ms | 50ms（差不多） |
| 1k 并发 QPS | 5k | 5k（差不多） |
| 10k 并发 | **OOM** 或拒绝（线程数限制） | 仍然 5k QPS |
| 内存占用 | 高（线程栈） | 低（少线程） |

> **核心收益**：**应对 IO 密集 + 极高并发** 的场景，少机器搞定。计算密集型业务收益小（CPU 才是瓶颈）。

---

## 二、Reactor：响应式核心库

### 2.1 两个核心类型

| 类型 | 含义 | 类比 |
| --- | --- | --- |
| **`Mono<T>`** | 0 或 1 个元素 | `Optional<T>` / `CompletableFuture<T>` |
| **`Flux<T>`** | 0 到 N 个元素 | `Stream<T>` / `Iterable<T>` |

```java
Mono<User> userMono = Mono.just(new User(1L, "Alice"));
Mono<User> empty = Mono.empty();
Mono<User> err = Mono.error(new RuntimeException("oops"));

Flux<Integer> nums = Flux.just(1, 2, 3, 4, 5);
Flux<Integer> range = Flux.range(1, 100);
Flux<String> fromStream = Flux.fromStream(Stream.of("a", "b", "c"));
```

### 2.2 关键概念：发布者-订阅者 + 拉模型

Reactor 实现的是 **Reactive Streams 规范**：

```
Publisher (发布者)    ──订阅──→  Subscriber (订阅者)
                                     │
                                     │ request(N)
                                     ▼
                      ←──onNext(item)──── 推送 N 个元素
                      ←──onComplete()─── 完成
                      ←──onError(e)──── 出错
```

**关键**：订阅者用 `request(n)` **拉式** 控制速率（背压 backpressure）——发布者不会盲目推送压垮订阅者。

### 2.3 必须订阅才执行（懒）

```java
Mono<String> mono = Mono.just("hello").map(s -> {
    System.out.println("processing: " + s);
    return s.toUpperCase();
});
// 此时 print 没输出！

mono.subscribe(System.out::println);    // 此时才执行
```

> **关键陷阱**：忘记 subscribe 整段代码不执行——和 Stream 的 `terminal operation` 类似。

---

## 三、常用操作符（必须掌握）

### 3.1 转换：`map` / `flatMap`

```java
Mono<String> name = userMono.map(User::getName);                            // 同步转换

Mono<List<Order>> orders = userMono.flatMap(user ->
    orderRepo.findByUserId(user.getId())                                    // 异步转换：返回 Mono
);
```

**核心区别**：
- `map`：同步转换，`T → R`
- `flatMap`：**异步转换**，`T → Mono<R>` 或 `T → Flux<R>`——把内部 Mono 解开

> **判断用哪个**：返回值是 `Mono`/`Flux` → 用 `flatMap`；返回普通对象 → 用 `map`。

### 3.2 组合：`zip` / `merge` / `concat`

```java
// zip：并行执行多个 Mono，结果组合
Mono<UserDetail> result = Mono.zip(
    userRepo.findById(uid),
    orderRepo.countByUserId(uid),
    pointsRepo.findByUserId(uid)
).map(tuple -> {
    User u = tuple.getT1();
    Long orderCount = tuple.getT2();
    Points p = tuple.getT3();
    return new UserDetail(u, orderCount, p);
});

// merge：多个 Flux 合并（不保序，按到达顺序）
Flux.merge(flux1, flux2, flux3);

// concat：多个 Flux 串行（保序）
Flux.concat(flux1, flux2, flux3);
```

### 3.3 错误处理

```java
Mono<User> u = userRepo.findById(id)
    .switchIfEmpty(Mono.error(new NotFoundException()))      // 空 → 错
    .onErrorReturn(User.UNKNOWN)                              // 错 → 默认值
    .onErrorResume(e -> Mono.just(User.fromCache(id)))        // 错 → 兜底
    .timeout(Duration.ofSeconds(3))                           // 超时
    .retry(3);                                                // 重试
```

### 3.4 调度：`subscribeOn` / `publishOn`

```java
mono
    .subscribeOn(Schedulers.boundedElastic())     // 整个链路在 elastic 线程池
    .map(this::heavyComputation)
    .publishOn(Schedulers.parallel())              // 切换到 parallel 线程池
    .map(this::format);
```

| Scheduler | 适用 |
| --- | --- |
| `Schedulers.parallel()` | CPU 密集（线程数 = CPU 核数） |
| `Schedulers.boundedElastic()` | **IO 阻塞操作**（弹性扩容到 10 * CPU） |
| `Schedulers.single()` | 单线程顺序执行 |
| `Schedulers.immediate()` | 当前线程 |

---

## 四、WebFlux 编程模型

### 4.1 注解式（迁移成本低）

```java
@RestController
@RequestMapping("/user")
public class UserController {
    @Resource private ReactiveUserRepository repo;
    
    @GetMapping("/{id}")
    public Mono<User> getById(@PathVariable Long id) {
        return repo.findById(id);
    }
    
    @GetMapping
    public Flux<User> list() {
        return repo.findAll();
    }
    
    @PostMapping
    public Mono<User> create(@RequestBody Mono<User> user) {
        return user.flatMap(repo::save);
    }
}
```

**和 Spring MVC 的差别**：返回类型变成 `Mono<X>` / `Flux<X>`，业务代码改动很小。

### 4.2 函数式（RouterFunction）

```java
@Configuration
public class UserRouter {
    @Bean
    public RouterFunction<ServerResponse> route(UserHandler handler) {
        return RouterFunctions.route()
            .GET("/user/{id}", handler::getById)
            .GET("/user",      handler::list)
            .POST("/user",     handler::create)
            .build();
    }
}

@Component
public class UserHandler {
    @Resource private ReactiveUserRepository repo;
    
    public Mono<ServerResponse> getById(ServerRequest req) {
        Long id = Long.valueOf(req.pathVariable("id"));
        return repo.findById(id)
            .flatMap(u -> ServerResponse.ok().bodyValue(u))
            .switchIfEmpty(ServerResponse.notFound().build());
    }
}
```

> **实际项目用注解式**，函数式略繁琐。

---

## 五、WebFlux + R2DBC（响应式数据库）

JPA / JDBC 都是阻塞 IO——在 WebFlux 里用就把整个 EventLoop 卡住。

**响应式 DB 驱动**：**R2DBC**（Reactive Relational Database Connectivity）。

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-r2dbc</artifactId>
</dependency>
<dependency>
    <groupId>io.asyncer</groupId>
    <artifactId>r2dbc-mysql</artifactId>
</dependency>
```

```yaml
spring:
  r2dbc:
    url: r2dbc:mysql://localhost/db
    username: root
    password: root
```

```java
public interface ReactiveUserRepository extends ReactiveCrudRepository<User, Long> {
    Mono<User> findByName(String name);
    Flux<User> findByAgeGreaterThan(int age);
}
```

> **MongoDB / Redis 也有响应式驱动**：`spring-boot-starter-data-mongodb-reactive` / `spring-boot-starter-data-redis-reactive`。

---

## 六、WebClient：响应式 HTTP 客户端

替代 `RestTemplate`：

```java
@Bean
public WebClient webClient() {
    return WebClient.builder()
        .baseUrl("http://api.example.com")
        .defaultHeader(HttpHeaders.AUTHORIZATION, "Bearer xxx")
        .build();
}

// 使用
Mono<User> user = webClient.get()
    .uri("/user/{id}", 123)
    .retrieve()
    .bodyToMono(User.class);

Flux<Order> orders = webClient.get()
    .uri("/order")
    .retrieve()
    .bodyToFlux(Order.class);
```

**优势**：异步、不阻塞、链式 API、内置重试 / 超时。

---

## 七、WebFlux 不适合的场景（**必看**）

很多人盲目上 WebFlux —— 性能反而下降。**WebFlux 不是银弹**。

### 7.1 不适合：业务依赖大量阻塞库

```
JPA / MyBatis（同步）       ❌ 必须切线程池才能用
Servlet API（HttpSession）   ❌ 不兼容
ThreadLocal                  ❌ 跨线程切换会丢
传统连接池（DBCP / Druid）   ❌ 不响应式
传统第三方 SDK（OSS / 邮件）  ❌ 大多同步
```

业务里只要有一个同步阻塞点——整条链路就要切线程池——抵消了 WebFlux 的优势。

### 7.2 不适合：CPU 密集计算

WebFlux 优势在 IO 密集——CPU 密集场景核心瓶颈是 CPU 算力，IO 模型不影响。

### 7.3 不适合：团队不熟悉

响应式编程心智负担高：
- 调试难（堆栈跨线程，看不到完整调用链）
- 操作符多，新手容易写错（`flatMap` vs `map`）
- 出错隐蔽（漏 subscribe / block 卡死）

> **建议**：默认用 Spring MVC；除非确认是 **IO 密集 + 高并发 + 团队懂响应式** 场景，才考虑 WebFlux。

### 7.4 适合的场景

- ✅ API 网关（典型：Spring Cloud Gateway）
- ✅ 高并发 IO 转发服务（聚合多个下游）
- ✅ Server-Sent Events / WebSocket 长连接
- ✅ 流式数据处理

---

## 八、生产踩坑

### 坑 1：阻塞操作导致 EventLoop 卡死

```java
@GetMapping("/user/{id}")
public Mono<User> getById(@PathVariable Long id) {
    User u = userDao.findById(id);    // ❌ JDBC 阻塞，EventLoop 全部卡死
    return Mono.just(u);
}
```

`userDao.findById` 是 JDBC——同步阻塞。EventLoop 线程被一个请求占用，其他请求全卡。
**修法**：① 改 R2DBC；② 必须用 JDBC 时切线程池：

```java
return Mono.fromCallable(() -> userDao.findById(id))
    .subscribeOn(Schedulers.boundedElastic());
```

### 坑 2：忘记 subscribe

```java
@PostMapping("/order")
public Mono<Void> create(@RequestBody Order o) {
    Mono<Void> save = orderRepo.save(o).then();
    sendNotification(o);             // ❌ 这是 Mono<Void> 但没人 subscribe
    return save;
}
```

`sendNotification` 返回 Mono 但没订阅 → **永远不执行**。
**修法**：链起来 `save.then(sendNotification(o))` 或显式 `sendNotification(o).subscribe()`（注意异常被吞）。

### 坑 3：ThreadLocal 跨线程丢失

WebFlux 链路跨多个线程——MDC、SecurityContext、自定义 ThreadLocal 全部丢失。

**修法**：
- MDC：用 Reactor 的 `Context`（响应式的 ThreadLocal 替代）
- Security：用 `ReactiveSecurityContextHolder`
- 自定义：用 `Context.put` / `Context.get`

```java
return userRepo.findById(id)
    .contextWrite(Context.of("traceId", "abc"))
    .map(u -> {
        // ...
        return u;
    });
```

### 坑 4：背压处理不当

```java
Flux.range(1, 1_000_000)
    .doOnNext(i -> sendToSlowDb(i))      // ❌ 下游处理慢，内存堆积爆
    .subscribe();
```

**修法**：
- `onBackpressureBuffer(1000)` —— 缓冲限额
- `onBackpressureDrop()` —— 丢弃超量
- `onBackpressureLatest()` —— 只保留最新

### 坑 5：`block()` 滥用

```java
@GetMapping("/user/{id}")
public User getById(@PathVariable Long id) {
    return userRepo.findById(id).block();    // ❌ 在 EventLoop 里 block，阻塞 EventLoop
}
```

**修法**：永远不要在 WebFlux 链路中 `block()`。如果必须取值——重新设计代码或切线程池。

### 坑 6：调试困难——堆栈不全

错误日志里只看到 Reactor 内部的栈，看不到业务代码哪一行触发的。
**修法**：开 Reactor 调试模式：

```java
Hooks.onOperatorDebug();    // 启动时加（性能损失大，仅开发环境）
```

或用 Project Reactor 的 `checkpoint("...")` 在关键节点加标识。

### 坑 7：错误的 Schedulers

```java
.subscribeOn(Schedulers.parallel())     // ❌ parallel 是 CPU 密集，做 IO 会饿死其他任务
```

**修法**：IO 必须用 `Schedulers.boundedElastic()`。

---

## 九、面试高频追问

**Q1：WebFlux 和 Spring MVC 区别？**
A：① **IO 模型**：MVC 同步 Servlet（每请求 1 线程）；WebFlux 异步 Reactor + Netty（少量 EventLoop 线程）。② **API**：MVC 直接返回对象；WebFlux 返回 `Mono<T>` / `Flux<T>`。③ **数据访问**：MVC 用 JDBC / JPA；WebFlux 必须用响应式驱动（R2DBC）才能发挥优势。④ **性能**：单请求 RT 差不多；高并发场景 WebFlux **资源利用率高**——少机器支撑高并发。

**Q2：响应式编程的核心思想？**
A：**异步 + 非阻塞 + 背压**。Publisher 推数据，Subscriber 通过 `request(n)` 拉式控制速率（背压）；中间所有操作符（map / flatMap）都是异步的。**少线程支撑高并发**——核心收益不是更快，而是资源利用率高。

**Q3：`Mono` 和 `Flux` 区别？**
A：`Mono<T>` 是 0 或 1 个元素（类似 `Optional` / `CompletableFuture`）；`Flux<T>` 是 0 到 N 个元素（类似 `Stream`）。两者都是 `Publisher<T>`。

**Q4：`map` 和 `flatMap` 区别？**
A：`map` 同步转换 `T → R`；`flatMap` 异步转换 `T → Mono<R>` / `T → Flux<R>`——把内部 Mono 解开。**判断**：返回值本身是 Mono/Flux 用 `flatMap`，普通对象用 `map`。

**Q5：响应式编程必须订阅才执行？**
A：**对**——Mono / Flux 是声明式描述，不调 `subscribe()` 不执行。Spring WebFlux 框架自动订阅控制器返回的 Mono / Flux。手写代码漏 subscribe 是经典坑。

**Q6：WebFlux 为什么不能阻塞 EventLoop？**
A：EventLoop 线程数 = CPU 核数 * 2（约 8-16 个）。一个阻塞操作（JDBC、`Thread.sleep`、`block()`）占用一个 EventLoop——8 个并发阻塞调用就让所有 EventLoop 卡死，整个网关瘫痪。必须切到 `Schedulers.boundedElastic()` 这种弹性线程池。

**Q7：WebFlux + JDBC 怎么用？**
A：JDBC 是阻塞——必须 `subscribeOn(Schedulers.boundedElastic())` 切到弹性线程池。但这样就退化成 "WebFlux + 同步 IO + 线程池" 模式，**WebFlux 的优势大部分丢了**。要发挥优势必须用 R2DBC（响应式 JDBC 替代）。

**Q8：背压（backpressure）是什么？**
A：响应式流的 **流量控制机制** —— Subscriber 调 `request(n)` 告诉 Publisher "我能处理 n 个"。Publisher 按需推送，避免下游消化不过来导致 OOM。Reactor 提供 `onBackpressureBuffer / Drop / Latest` 处理超量。

**Q9：什么场景适合 WebFlux？**
A：**IO 密集 + 高并发**：① API 网关（Spring Cloud Gateway 内置就是 WebFlux）；② 流量聚合（一个请求调多个下游再合并）；③ SSE / WebSocket 长连接；④ 流式响应。**不适合**：JPA 重业务、CPU 密集、团队不熟悉响应式。

**Q10：WebFlux 怎么做请求级别的上下文（如 traceId）？**
A：不能用 `ThreadLocal`（跨线程丢失）。Reactor 提供 `Context`：`.contextWrite(Context.of("k", "v"))` 写入；`Mono.deferContextual(ctx -> ...)` 读取。或集成 Sleuth / Micrometer 的响应式扩展。Spring Security 用 `ReactiveSecurityContextHolder`。

---

## 十、答题模板（60 秒）

> WebFlux 是 Spring 5 引入的 **响应式 Web 框架**，基于 **Reactor + Netty 异步非阻塞**——核心收益不是单请求更快，而是 **少量线程支撑超高并发**（少机器、低资源）。
>
> **核心抽象**：`Mono<T>` 0/1 元素、`Flux<T>` 0~N 元素，都是 `Publisher<T>`。订阅者通过 `request(n)` 拉式控制速率（**背压**）避免压垮自己。**必须 `subscribe()` 才执行**——声明式描述、懒求值。
>
> **常用操作符**：`map`（同步转换 T→R）/ `flatMap`（异步转换 T→Mono<R>，**判断关键**）/ `zip`（并行组合多个 Mono）/ `subscribeOn`（指定执行线程池）。错误处理用 `onErrorResume` / `switchIfEmpty` / `timeout` / `retry`。
>
> **生产铁律**：① **绝不能在 EventLoop 阻塞**（JDBC、`block()`、`Thread.sleep` 都会让所有 EventLoop 卡死）—— 必须用 R2DBC，或切 `Schedulers.boundedElastic()`；② **ThreadLocal 跨线程丢失** —— 用 Reactor 的 `Context`；③ **漏 subscribe 不执行** —— 调试坑王。
>
> **适合场景**：API 网关（Spring Cloud Gateway）、高并发 IO 转发、SSE / WebSocket。
> **不适合**：JPA 重业务（必须切线程池抵消优势）、CPU 密集、团队不熟悉响应式（调试难）。**默认用 Spring MVC，除非有充分理由才上 WebFlux**。

---

## 十一、相关文档

- 配套：[SpringMVC.md](SpringMVC.md) — 同步 Web 模型对比
- 配套：[SpringCloudGateway.md](SpringCloudGateway.md) — 网关本质就是 WebFlux 应用
- 配套：[SpringAsync与Scheduling.md](SpringAsync与Scheduling.md) — 异步编程对比
- 配套：[../Concurrency/CompletableFuture.md](../Concurrency/CompletableFuture.md) — JDK 异步编程
