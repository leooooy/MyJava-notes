# Feign / OpenFeign

> Spring Cloud 微服务间通信的标配。这道题面试官想听的不是"用法"——大家都会用，而是：
> ① 一个普通接口为什么 `@Resource` 进来就能直接调远程？**底层动态代理 + 负载均衡**怎么串起来的？
> ② Feign vs RestTemplate vs WebClient 的取舍？
> ③ 生产里的 **超时、重试、熔断、连接池** 怎么调？

---

## 一、Feign 是什么

**声明式 HTTP 客户端**——把远程调用写成像调本地接口一样：

```java
// 服务提供方（user-service）
@RestController
public class UserController {
    @GetMapping("/user/{id}")
    public User getById(@PathVariable Long id) { ... }
}

// 服务消费方
@FeignClient(name = "user-service")
public interface UserClient {
    @GetMapping("/user/{id}")
    User getById(@PathVariable Long id);
}

@Service
public class OrderService {
    @Resource private UserClient userClient;
    
    public Order createOrder(Long userId) {
        User user = userClient.getById(userId);     // ← 看起来像本地调用，实际是 HTTP
        ...
    }
}
```

> **核心价值**：把 "URL + HTTP method + 参数序列化 + 响应反序列化 + 负载均衡 + 重试" 这一串 boilerplate 全消掉，业务只剩**接口签名**。

---

## 二、Feign 演进

| 版本 | 出品 | 现状 |
| --- | --- | --- |
| **Netflix Feign** | Netflix（早期） | 基础能力 |
| **Spring Cloud Netflix Feign** | Netflix + Spring 整合 | **已弃用**（Spring Cloud 2020+） |
| **Spring Cloud OpenFeign** | Spring Cloud 官方维护 | **现在用的** |

依赖：

```xml
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-openfeign</artifactId>
</dependency>
```

启用：

```java
@SpringBootApplication
@EnableFeignClients(basePackages = "com.foo.client")
public class App { }
```

---

## 三、底层原理：从注解到 HTTP 请求

### 3.1 启动期：扫描 + 注册

```
@EnableFeignClients
└─ @Import(FeignClientsRegistrar)
   └─ 扫描 basePackages 下所有 @FeignClient 接口
   └─ 为每个接口注册一个 BeanDefinition
      └─ beanClass = FeignClientFactoryBean    ★ FactoryBean 模式
      └─ 当 @Resource 注入时，FactoryBean.getObject() 返回动态代理
```

**关键设计**：用 `FactoryBean` 让"生产接口代理对象"也成为容器里的 bean。

### 3.2 代理对象生成（`Feign.builder().target(...)`）

```
FeignClientFactoryBean.getObject()
└─ 用 Feign Builder 构建：
   ├─ Encoder：参数 → HTTP request body（默认 SpringEncoder + Jackson）
   ├─ Decoder：HTTP response → Java 对象（默认 SpringDecoder + Jackson）
   ├─ Contract：解析 Feign / Spring MVC 注解（@GetMapping / @RequestParam）
   ├─ Logger：日志
   ├─ Client：实际发 HTTP 的客户端（默认 JDK URLConnection，可换 OkHttp / Apache HttpClient）
   ├─ RequestInterceptor：请求拦截器（加 token / traceId）
   └─ ErrorDecoder：异常处理
└─ 返回 JDK 动态代理（Proxy.newProxyInstance）
```

### 3.3 运行期：调用流程

```
userClient.getById(123L)
  ↓
JDK 动态代理 InvocationHandler.invoke()
  ↓
ReflectiveFeign$FeignInvocationHandler.invoke()
  ↓
SynchronousMethodHandler.invoke()
  ├─ ① 用 @GetMapping("/user/{id}") 模板生成 URL：/user/123
  ├─ ② Encoder 把参数序列化（这里没 body）
  ├─ ③ RequestInterceptor 链：加 Authorization 头、traceId 等
  ├─ ④ Client.execute(request)
  │     ├─ 默认走 spring-cloud-loadbalancer：
  │     │     用 service-id "user-service" 查注册中心拿实例列表
  │     │     按算法选一个：192.168.1.5:8080
  │     ├─ 实际发 HTTP：GET http://192.168.1.5:8080/user/123
  │     └─ 拿到 HTTP Response
  ├─ ⑤ Decoder 反序列化 response body 为 User 对象
  └─ ⑥ 返回 User 实例
```

---

## 四、Feign vs RestTemplate vs WebClient

| 维度 | **Feign** | RestTemplate | WebClient |
| --- | --- | --- | --- |
| 编程范式 | **声明式** | 命令式 | 响应式（Reactor） |
| 类型 | 接口 | 客户端对象 | 客户端对象 |
| 异步 | 默认同步（可配 CompletableFuture） | 同步 | 异步 |
| 集成 LB | ✅（自动） | ✅（`@LoadBalanced`） | ✅ |
| 集成熔断 | ✅（Sentinel / Resilience4j） | 需自己加 | 需自己加 |
| 序列化 | 自动（同 Spring MVC 配置） | 自动 | 自动 |
| 学习曲线 | 低（写接口） | 中 | **高**（响应式） |
| 性能 | 中 | 中 | **高**（高并发场景） |
| 现状 | **微服务首选** | 已被 Spring 6 标记弃用 | 响应式项目首选 |

**选型决策**：
- **Spring Cloud 微服务内部调用** → Feign（声明式 + 自动 LB + 自动熔断）
- **少量外部 HTTP 调用、传统 MVC 项目** → RestTemplate
- **WebFlux / 高并发响应式应用** → WebClient

---

## 五、生产配置

### 5.1 超时（必配）

Feign 默认超时 1 秒（旧版） / 10 秒（新版）。**生产强制显式配**：

```yaml
feign:
  client:
    config:
      default:                       # 全局默认
        connect-timeout: 2000        # 连接超时（ms）
        read-timeout: 5000           # 读超时（ms）
        logger-level: BASIC          # NONE / BASIC / HEADERS / FULL
      
      user-service:                  # 针对特定服务覆盖
        connect-timeout: 1000
        read-timeout: 3000
```

> **教训**：不配超时，下游慢响应直接导致调用方线程池打满 → 雪崩。

### 5.2 连接池（必配）

JDK 默认 URLConnection 性能差，生产换成 Apache HttpClient 或 OkHttp：

```xml
<dependency>
    <groupId>io.github.openfeign</groupId>
    <artifactId>feign-okhttp</artifactId>
</dependency>
```

```yaml
feign:
  okhttp:
    enabled: true
  httpclient:
    enabled: false                   # 二选一
    max-connections: 200             # 总连接数
    max-connections-per-route: 50    # 单 host 连接数
```

### 5.3 重试

**默认不重试**。开启：

```java
@Bean
public Retryer retryer() {
    return new Retryer.Default(100, 1000, 3);    // period, maxPeriod, maxAttempts
}
```

> ⚠️ **危险**：重试要配合**幂等设计**——POST / 写操作不要重试，否则可能重复扣款 / 重复下单。GET 类查询接口才适合重试。

### 5.4 日志

```yaml
feign:
  client:
    config:
      default:
        logger-level: BASIC
logging:
  level:
    com.foo.client.UserClient: DEBUG    # 针对接口的 logger 设 DEBUG 才生效
```

| 级别 | 输出 |
| --- | --- |
| **NONE** | 不打日志（生产常用） |
| **BASIC** | URL、HTTP method、status code、耗时 |
| **HEADERS** | BASIC + 请求/响应 header |
| **FULL** | 全部（含 body）—— 调试用，生产慎用（log 容量爆炸） |

### 5.5 请求拦截器（加 traceId / 鉴权头）

```java
@Component
public class TraceFeignInterceptor implements RequestInterceptor {
    @Override
    public void apply(RequestTemplate template) {
        String traceId = MDC.get("traceId");
        if (traceId != null) {
            template.header("X-Trace-Id", traceId);
        }
        template.header("Authorization", "Bearer " + getToken());
    }
}
```

被自动注册（标 `@Component`），所有 Feign 调用都会经过。

---

## 六、与熔断器集成

### 6.1 Sentinel 集成（国内主流）

```yaml
feign:
  sentinel:
    enabled: true
```

```java
@FeignClient(name = "user-service", fallback = UserClientFallback.class)
public interface UserClient {
    @GetMapping("/user/{id}")
    User getById(@PathVariable Long id);
}

@Component
public class UserClientFallback implements UserClient {
    @Override
    public User getById(Long id) {
        return User.UNKNOWN;        // 降级返回
    }
}
```

### 6.2 拿到异常的 fallback

`fallback` 拿不到异常对象。要拿到用 `fallbackFactory`：

```java
@FeignClient(name = "user-service", fallbackFactory = UserClientFallbackFactory.class)
public interface UserClient { ... }

@Component
public class UserClientFallbackFactory implements FallbackFactory<UserClient> {
    @Override
    public UserClient create(Throwable cause) {
        return new UserClient() {
            @Override
            public User getById(Long id) {
                log.warn("user-service fallback, id={}, cause={}", id, cause.getMessage());
                return User.UNKNOWN;
            }
        };
    }
}
```

---

## 七、生产踩坑

### 坑 1：Feign 调用 Controller 返回的不是 ResponseEntity 但调用方反序列化失败

服务方：

```java
@GetMapping("/user/{id}")
public ApiResp<User> getById(@PathVariable Long id) {
    return ApiResp.success(...);   // 包了一层
}
```

调用方：

```java
@FeignClient(name = "user-service")
public interface UserClient {
    @GetMapping("/user/{id}")
    User getById(@PathVariable Long id);   // ❌ 类型对不上
}
```

**修法**：调用方用 `ApiResp<User>` 接收，或服务方提供一套裸返回的内部接口。

### 坑 2：Feign 没设超时，慢调用打满线程池

下游 30 秒响应，调用方 200 个 Tomcat 线程全部卡住，整个服务不可用。
**修法**：见 5.1，必须配。

### 坑 3：循环依赖：Feign 接口注入到拦截器

```java
@Component
public class AuthInterceptor implements HandlerInterceptor {
    @Resource private UserClient userClient;     // ❌ Feign 客户端启动比拦截器早
    ...
}
```

启动报循环依赖。
**修法**：① `@Lazy` 注入；② 把权限校验拆到独立 service。

### 坑 4：`@RequestParam` / `@PathVariable` 不写参数名

```java
@GetMapping("/user")
User getByName(@RequestParam String name);   // ❌ 编译时丢失参数名（除非加 -parameters）
```

Feign 解析参数依赖参数名，不写明显式名字时容易出错。
**修法**：始终写名字 `@RequestParam("name") String name`。

### 坑 5：日志没生效

`feign.client.config.default.logger-level=FULL` 设了，但日志没出来。
**根因**：Feign 默认用 SLF4J，需要 logger 级别也设到 DEBUG：`logging.level.com.foo.client=DEBUG`。

### 坑 6：拼接 URL 时把斜杠搞错

```java
@FeignClient(name = "user-service", path = "/api")
public interface UserClient {
    @GetMapping("/user/{id}")     // 实际请求：http://user-service/api/user/123
    User getById(@PathVariable Long id);
}
```

`path` 和方法上的 path 拼起来要小心，多一个斜杠或少一个都会 404。

### 坑 7：HttpClient 连接池没释放

调用某个 host 的 Feign 客户端越来越慢——连接池满了。
**根因**：服务端关闭连接但客户端没及时回收，或 max-connections 太小。
**修法**：① 调大连接池；② 监控连接池指标（HttpClient 的 metric）；③ 升级到 OkHttp（连接池管理更好）。

---

## 八、面试高频追问

**Q1：Feign 怎么实现的？写一个接口怎么就能调远程？**
A：① 启动期：`@EnableFeignClients` 触发 `FeignClientsRegistrar` 扫描 `@FeignClient` 接口，为每个接口注册一个 `FeignClientFactoryBean`（FactoryBean 模式）；② 注入时：FactoryBean 用 Feign Builder 构造 JDK 动态代理；③ 调用时：代理 InvocationHandler 解析 `@GetMapping` 等注解，构造 HTTP 请求模板，经 Encoder / RequestInterceptor / LoadBalancer / Client 链路最终发 HTTP，Decoder 把 response 反序列化成方法返回类型。

**Q2：Feign 默认用什么 HTTP 客户端？怎么换？**
A：默认 JDK `HttpURLConnection`（无连接池、性能差）。生产换 Apache HttpClient 或 OkHttp：

```xml
<dependency>
    <groupId>io.github.openfeign</groupId>
    <artifactId>feign-okhttp</artifactId>
</dependency>
```

```yaml
feign:
  okhttp:
    enabled: true
```

**Q3：Feign 和 RestTemplate 区别？**
A：① 范式：声明式 vs 命令式；② Feign 自动集成 LoadBalancer 和熔断器；③ Feign 写接口（IDE 跳转友好），RestTemplate 写代码；④ Spring 6 已标记 RestTemplate 弃用，新项目用 Feign / WebClient。

**Q4：Feign 怎么集成熔断？**
A：早期靠 Hystrix（已停更），现在主流 Sentinel：

```yaml
feign:
  sentinel:
    enabled: true
```

`@FeignClient(fallback=...)` 或 `fallbackFactory=...` 提供降级。后者能拿到异常对象。

**Q5：Feign 调用是否有重试？**
A：**默认不重试**。可以注入 `Retryer` bean 开启。但**开启重试要配合幂等设计**——写操作（POST / PUT / DELETE）一般不开，否则重试可能造成重复扣款。GET 类查询可以开。

**Q6：Feign 怎么传递 token / traceId？**
A：写 `RequestInterceptor`：

```java
@Component
public class TokenInterceptor implements RequestInterceptor {
    @Override
    public void apply(RequestTemplate template) {
        template.header("Authorization", "Bearer " + getToken());
    }
}
```

被 Spring 自动装配到所有 Feign 客户端。

**Q7：Feign 接口能继承吗？**
A：能。父接口定义通用方法，子接口添加业务方法。但**不推荐**——会让接口职责模糊，且服务方和客户方共用接口耦合度高。**官方建议接口契约用 OpenAPI / Protobuf 等专用工具，不要用 Java 接口共享**。

**Q8：调用同一个服务，多个 Feign 客户端怎么办？**
A：用 `@FeignClient(contextId="xxx")` 指定不同的 contextId，避免 bean 重名：

```java
@FeignClient(name = "user-service", contextId = "userClient", path = "/user")
public interface UserClient { ... }

@FeignClient(name = "user-service", contextId = "adminClient", path = "/admin")
public interface AdminClient { ... }
```

**Q9：Feign 性能怎么优化？**
A：① 换连接池实现（OkHttp / Apache HttpClient）；② 配大连接池；③ 关掉冗长日志（生产 NONE 或 BASIC）；④ 减少 Encoder/Decoder 重 CPU 操作（避免大对象传输）；⑤ 并发场景用 `WebClient` 异步替代。

**Q10：Feign 调用如何在调用方做参数校验？**
A：JSR-303 注解 + `@Validated`：

```java
@Validated
@FeignClient(name = "user-service")
public interface UserClient {
    @GetMapping("/user/{id}")
    User getById(@PathVariable @Min(1) Long id);
}
```

调用方校验失败抛 `ConstraintViolationException`——不发出 HTTP 请求。

---

## 九、答题模板（60 秒）

> Feign（OpenFeign）是 Spring Cloud 推荐的 **声明式 HTTP 客户端**——把远程调用写成像调本地接口一样。
>
> **底层原理**：① 启动期 `@EnableFeignClients` 触发扫描，每个 `@FeignClient` 接口注册成一个 `FactoryBean`；② 注入时 `FactoryBean.getObject()` 返回 JDK 动态代理；③ 调用时代理 InvocationHandler 解析 `@GetMapping` 等注解构造 HTTP 请求模板，经 **Encoder → RequestInterceptor → LoadBalancer 选实例 → HTTP Client 发请求 → Decoder 反序列化** 链路返回结果。
>
> **生产必配**：① 超时（`connect-timeout` + `read-timeout`，不配会被慢调用拖死）；② 换连接池（默认 JDK URLConnection 性能差，换 OkHttp 或 Apache HttpClient）；③ 配 logger-level（生产 BASIC，调试 FULL）；④ `RequestInterceptor` 加 token / traceId；⑤ 熔断降级（Sentinel + `fallbackFactory` 拿到异常）；⑥ 重试只对幂等接口开。
>
> **常见坑**：① 没配超时拖死调用方线程池；② Feign 注入到拦截器导致循环依赖（用 `@Lazy`）；③ 多 Feign 调同服务要 `contextId` 区分；④ 序列化类型不匹配（服务方包了 ApiResp 调用方没接住）；⑤ JDK URLConnection 没连接池，并发场景必须换。

---

## 十、相关文档

- 上层：[SpringCloud通用.md](SpringCloud通用.md) — Feign 在微服务架构中的位置
- 配套：[Nacos.md](Nacos.md) — Feign 通过 Nacos 发现服务实例
- 配套：[AOP.md](AOP.md) — JDK 动态代理原理
