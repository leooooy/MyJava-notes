# Spring Cloud Gateway

> 微服务网关的官方答案（替代 Zuul）。
> 这道题的"段位差"在三点：
> ① 能不能讲清 **基于 Reactor + Netty 异步非阻塞** 比 Zuul 1 强在哪
> ② 能不能讲清 **Predicate + Filter + Route** 三大概念的协作
> ③ 能不能讲清网关的典型职责：**路由 / 鉴权 / 限流 / 灰度 / 熔断**

---

## 一、网关的位置和职责

```
                ┌──────────────────────────────┐
                │   客户端 / 浏览器 / App        │
                └──────────────┬───────────────┘
                                │
                                ▼
              ┌──────────────────────────────────┐
              │   API Gateway (网关)              │
              │   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
              │   · 路由（按路径/Header转发）       │
              │   · 鉴权（统一 Token 校验）         │
              │   · 限流（防刷、保护下游）           │
              │   · 灰度（按用户 / Header 分流）     │
              │   · 改写（CORS / 协议转换 / 加密）   │
              │   · 监控（统一日志、调用链）         │
              └─────┬───────────────┬─────────────┘
                    │               │
        ┌───────────▼───────┐ ┌─────▼─────────────┐
        │  user-service     │ │  order-service    │
        └───────────────────┘ └───────────────────┘
```

**为什么不让前端直连后端**：
- ① 前端要管理 N 个微服务地址 → 服务上下线前端跟不上
- ② 鉴权 / 限流 / CORS 每个服务都要做 → 重复劳动
- ③ 后端协议变化 → 前端跟着改
- ④ 安全暴露面大

**网关 = 统一入口、统一治理、屏蔽后端复杂度**。

---

## 二、Gateway vs Zuul vs Nginx

| 维度 | **Spring Cloud Gateway** | Zuul 1 | Zuul 2 | Nginx + Lua |
| --- | --- | --- | --- | --- |
| IO 模型 | **Reactor + Netty 异步非阻塞** | 同步 Servlet（每请求 1 线程） | Netty 异步 | 异步 |
| 性能 | **高**（5x Zuul 1） | 中 | 高 | **最高** |
| 路由配置 | YAML / Java DSL | YAML | 类似 | nginx.conf / Lua |
| 集成 Spring Cloud | ✅ 原生 | ✅（旧） | ❌ | ❌ |
| 动态路由 | ✅（Nacos 推送） | 需扩展 | / | OpenResty 扩展 |
| 现状 | **主流** | **已淘汰** | 未集成 SC | OpenResty / Kong 还在用 |

> **国内 Spring Cloud 项目结论**：99% 选 Gateway。Nginx + OpenResty 用于流量入口（Gateway 之前），不直接做业务网关。

---

## 三、三大核心概念

```
Predicate（断言）  +  Filter（过滤器）  =  Route（路由）

Predicate：什么样的请求走这条路由
Filter：怎么改写请求或响应
Route：完整路由规则
```

### 3.1 Predicate（断言）

匹配条件，常用 12 种：

| 断言 | 用法 | 含义 |
| --- | --- | --- |
| **Path** | `Path=/user/**` | 路径匹配 |
| Method | `Method=GET,POST` | HTTP method |
| Header | `Header=X-Trace-Id, ^\d+$` | Header 名 + 正则 |
| Query | `Query=foo, bar` | URL 参数匹配 |
| Cookie | `Cookie=session, ^abc$` | Cookie 匹配 |
| Host | `Host=*.example.com` | Host 头匹配 |
| RemoteAddr | `RemoteAddr=192.168.1.1/24` | 客户端 IP |
| Weight | `Weight=group1, 80` | 加权（灰度） |
| Before / After / Between | `After=2026-05-09T...` | 时间窗口 |

### 3.2 Filter（过滤器）

修改请求或响应，常用 30+ 种：

| Filter | 用法 | 含义 |
| --- | --- | --- |
| **StripPrefix** | `StripPrefix=1` | 去掉前 N 个路径段（`/user/123` → `/123`） |
| **PrefixPath** | `PrefixPath=/api` | 加前缀 |
| **AddRequestHeader** | `AddRequestHeader=X-Source, Gateway` | 加请求头 |
| **AddResponseHeader** | `AddResponseHeader=X-Time, ${T(System).currentTimeMillis()}` | 加响应头 |
| **RewritePath** | `RewritePath=/foo/(?<id>.*), /bar/${id}` | 重写路径 |
| **RequestRateLimiter** | 配 Redis | 限流 |
| **CircuitBreaker** | 配 Resilience4j | 熔断 |
| **Retry** | `Retry=3` | 重试 |
| **SetStatus** | `SetStatus=204` | 改状态码 |
| **DedupeResponseHeader** | 去重响应头 | CORS 重复时常用 |

### 3.3 Route（路由）= Predicate + Filter + URI

```yaml
spring:
  cloud:
    gateway:
      routes:
        - id: user-route
          uri: lb://user-service                # lb:// 走负载均衡
          predicates:
            - Path=/user/**
            - Method=GET,POST
          filters:
            - StripPrefix=1
            - AddRequestHeader=X-Gateway, true
        
        - id: order-route
          uri: lb://order-service
          predicates:
            - Path=/order/**
          filters:
            - StripPrefix=1
            - name: RequestRateLimiter
              args:
                redis-rate-limiter.replenishRate: 100   # 每秒 100 个令牌
                redis-rate-limiter.burstCapacity: 200   # 桶容量 200
                key-resolver: '#{@userKeyResolver}'
```

`uri` 三种格式：
- `http://example.com:8080` —— 直接转发
- `lb://service-name` —— **走负载均衡（最常用）**
- `forward:/local-handler` —— 本地处理器

---

## 四、底层架构：Reactor + Netty

### 4.1 流程

```
Netty EventLoop 线程接收请求
   │
   ▼
DispatcherHandler                    （类似 Spring MVC 的 DispatcherServlet）
   │
   ▼
RoutePredicateHandlerMapping         ★ 找匹配的 Route
   │
   ▼
FilteringWebHandler                  组装 Filter 链
   │
   ▼
GatewayFilterChain.filter()
   │
   ├─ ① 全局 GlobalFilter（按顺序）
   ├─ ② 路由级 GatewayFilter（YAML 配的）
   └─ ③ NettyRoutingFilter (★ 最后一个，发起后端请求)
   │
   ▼
HttpClient（Netty 客户端）
   │
   ▼
后端服务
```

### 4.2 为什么比 Zuul 1 性能高

```
Zuul 1：同步 Servlet
─────────────────────────
请求 1 → 线程 1（占用） ───→ 调下游 ───→ 等响应 ───→ 释放
请求 2 → 线程 2
...
请求 N → 线程池满 → 拒绝

问题：每个请求独占一个线程，线程数 = 并发数

Gateway：异步非阻塞
─────────────────────────
请求 1 → EventLoop（不占）→ 提交 IO → 立即返回
请求 2 → EventLoop（同上）
...
IO 完成 → 回调 → 写响应

优势：少量线程（CPU 核数 * 2）支撑高并发
```

> **测试数据**：单实例 8C16G，Gateway 能稳定 5w QPS；Zuul 1 大约 1w QPS。

---

## 五、自定义全局过滤器

最常见的需求：统一鉴权 / 日志 / 黑名单。

```java
@Component
@Slf4j
public class AuthFilter implements GlobalFilter, Ordered {
    
    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        ServerHttpRequest req = exchange.getRequest();
        String path = req.getURI().getPath();
        
        // 白名单
        if (path.startsWith("/auth/login") || path.startsWith("/public")) {
            return chain.filter(exchange);
        }
        
        String token = req.getHeaders().getFirst("Authorization");
        if (token == null) {
            return write401(exchange, "未携带 token");
        }
        
        Long userId = jwtUtils.parse(token);
        if (userId == null) {
            return write401(exchange, "token 无效");
        }
        
        // 把 userId 透传给后端服务
        ServerHttpRequest mutated = req.mutate()
            .header("X-User-Id", String.valueOf(userId))
            .build();
        return chain.filter(exchange.mutate().request(mutated).build());
    }
    
    private Mono<Void> write401(ServerWebExchange exchange, String msg) {
        ServerHttpResponse resp = exchange.getResponse();
        resp.setStatusCode(HttpStatus.UNAUTHORIZED);
        resp.getHeaders().setContentType(MediaType.APPLICATION_JSON);
        DataBuffer buffer = resp.bufferFactory().wrap(msg.getBytes(StandardCharsets.UTF_8));
        return resp.writeWith(Mono.just(buffer));
    }
    
    @Override
    public int getOrder() { return -100; }   // 越小越先
}
```

---

## 六、网关限流

### 6.1 内置 RequestRateLimiter

```yaml
filters:
  - name: RequestRateLimiter
    args:
      redis-rate-limiter.replenishRate: 100    # 每秒补充 100 个令牌
      redis-rate-limiter.burstCapacity: 200    # 桶容量 200（突发）
      key-resolver: '#{@userKeyResolver}'
```

```java
@Bean
public KeyResolver userKeyResolver() {
    return exchange -> {
        String userId = exchange.getRequest().getHeaders().getFirst("X-User-Id");
        return Mono.just(userId == null ? "anonymous" : userId);
    };
}
```

底层是 **Redis + Lua 脚本** 的令牌桶（高效 + 跨实例）。

### 6.2 Sentinel 集成（推荐生产）

```xml
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-sentinel-gateway</artifactId>
</dependency>
```

直接在 Sentinel 控制台配规则——比 YAML 灵活。详见 [Sentinel.md](Sentinel.md)。

---

## 七、灰度发布

### 7.1 按 Header 灰度

```yaml
- id: user-gray
  uri: lb://user-service-v2          # 新版本服务
  predicates:
    - Path=/user/**
    - Header=X-Version, gray
- id: user-prod
  uri: lb://user-service             # 老版本
  predicates:
    - Path=/user/**
```

QA / 内部用户 Header 加 `X-Version: gray` 走新版，其他走老版。

### 7.2 按权重灰度

```yaml
- id: user-v2
  uri: lb://user-service-v2
  predicates:
    - Path=/user/**
    - Weight=user-group, 20      # 20% 流量
- id: user-v1
  uri: lb://user-service
  predicates:
    - Path=/user/**
    - Weight=user-group, 80      # 80% 流量
```

### 7.3 按用户灰度（自定义 Predicate）

```java
@Component
public class UserIdRoutePredicateFactory extends AbstractRoutePredicateFactory<UserIdRoutePredicateFactory.Config> {
    public UserIdRoutePredicateFactory() { super(Config.class); }
    
    @Override
    public Predicate<ServerWebExchange> apply(Config config) {
        return exchange -> {
            String userId = exchange.getRequest().getHeaders().getFirst("X-User-Id");
            return userId != null && config.getUserIds().contains(userId);
        };
    }
    
    @Data
    public static class Config {
        private List<String> userIds;
    }
}
```

---

## 八、CORS 配置

```yaml
spring:
  cloud:
    gateway:
      globalcors:
        cors-configurations:
          '[/**]':
            allowedOrigins:
              - "https://example.com"
            allowedMethods: ["GET", "POST", "PUT", "DELETE"]
            allowedHeaders: "*"
            allowCredentials: true
            maxAge: 3600
```

**注意**：CORS 必须在所有鉴权之前生效（OPTIONS 预检不带 token）。

---

## 九、生产踩坑

### 坑 1：内存泄漏（DataBuffer 没 release）

```java
@Override
public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
    Flux<DataBuffer> body = exchange.getRequest().getBody();
    return body.collectList().flatMap(buffers -> {
        // ❌ 没 release，内存泄漏
        ...
    });
}
```

WebFlux 用堆外内存（Netty `ByteBuf`），必须手动 release：

```java
return body.collectList().flatMap(buffers -> {
    try {
        // 用数据
        return chain.filter(exchange);
    } finally {
        buffers.forEach(DataBufferUtils::release);
    }
});
```

或用 `ServerWebExchangeUtils.cacheRequestBody`（Spring 提供的安全封装）。

### 坑 2：响应头被多次写入

```
Header 'Access-Control-Allow-Origin' has multiple values: 'a', 'b'
```

**根因**：网关 + 后端服务都加了 CORS。
**修法**：① 后端不加 CORS（统一让网关加）；② 用 `DedupeResponseHeader` Filter 去重。

### 坑 3：Block 操作阻塞 Netty 线程

```java
public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
    User u = userDao.findById(uid);   // ❌ JDBC 同步阻塞
    ...
}
```

WebFlux 的 EventLoop 线程池只有 CPU 核数那么多——一个阻塞操作就让全部请求卡住。
**修法**：① 网关里别做同步 IO；② 必须做的话用 `Mono.fromCallable(...).subscribeOn(Schedulers.boundedElastic())` 切到 IO 线程池。

### 坑 4：路由不生效

YAML 配了路由但请求 404。
**排查清单**：
1. ❌ predicates 写错（Path 大小写、缺斜杠）
2. ❌ `lb://service-name` 但 service-name 不在注册中心
3. ❌ 多个路由都匹配，被前一个先消化
4. ❌ Gateway 自身没启动（健康检查通了吗）

### 坑 5：连接池打满

下游慢响应 → 网关连接池打满 → 后续请求全部 503。
**修法**：

```yaml
spring:
  cloud:
    gateway:
      httpclient:
        connect-timeout: 2000
        response-timeout: 5s
        pool:
          max-connections: 500
          acquire-timeout: 1000
```

### 坑 6：白名单泄漏

```java
if (path.startsWith("/api/public")) return chain.filter(exchange);
```

攻击者构造 `/api/public/../admin/users` ——绕过鉴权。
**修法**：用 `AntPathMatcher` 严格匹配，不要简单 `startsWith`。

### 坑 7：JWT 解析放在 Gateway 同步执行

```java
Long userId = jwtUtils.parse(token);    // 解析慢（RSA 校验）
```

每个请求耗时 5-20ms（看密钥长度），网关 QPS 直接折半。
**修法**：① JWT 用 HS256（对称、快）；② 解析结果缓存（Caffeine 短 TTL）；③ 把校验异步化。

### 坑 8：`retrieve()` 对非 2xx 抛异常，让降级分支变成死代码

网关缓存 miss 时回源问后端"这个 token 还有效吗"，写法通常长这样：

```java
Mono<String> resp = webClient.post().uri("/user/getBySecretKey")
        .body(...).retrieve().bodyToMono(String.class);   // ← 对 4xx/5xx 直接抛异常
return resp.flatMap(r -> {
    if (parse(r).getData() == null) {
        return returnError(exchange.getResponse());       // ← 本以为"查不到就拦截"
    }
    ...
});
```

**`retrieve()` 遇到非 2xx 会抛 `WebClientResponseException`，根本不进 `flatMap`。** 一旦下游因为空指针之类的原因返回 500，"查不到用户就拦截"这条降级路径**一次都不会执行**——它只是在下游始终返回 200 的日子里岁月静好。表现是客户端收到网关抛出的错误，而不是预期的"登录失效"，**不会弹登录页**。

**修法**：① 显式 `.onStatus(HttpStatus::isError, r -> Mono.empty())` 把错误码也归并到同一分支；② 或用 `exchangeToMono` 自己处理状态码；③ 或约定下游"查不到"返回 `200 + data=null` 而不是异常。**关键是降级分支必须有测试**——没被执行过的兜底代码等于没有。

### 坑 9：鉴权缓存参与放行判定，却按"普通缓存"维护

网关鉴权常见做法：Redis Hash 存 `token -> 用户信息`，命中直接放行、miss 才回源。这时缓存已经**不是加速器而是会话白名单**：

| | 缓存当加速器 | 缓存当会话白名单 |
| --- | --- | --- |
| miss 的后果 | 慢一点，结论相同 | 走另一条判定路径，**结论可能不同** |
| 源数据删除时 | 可以不管，等 TTL 淘汰 | **必须同步删**，否则等于没删 |
| TTL = -1 | 顶多占内存 | **失去自愈能力**，漏清一次 = 永久有效 |

判断标准就一句：**miss 和 hit 会得出不同结论吗？** 会，它就得按数据源标准维护生命周期。

**修法**：① 后台注销/封禁用户时，**同一个方法里**同步清除该用户所有 token 的缓存；② 会话缓存一律设 TTL（哪怕 7 天），把"漏清一次"的影响面从"永远"压到"最长一个 TTL"；③ 清理动作封装进 Service 复用，别在每个调用点各写一遍。

> 真实事故见 Project/事故 #14 — 后台注销用户不解除登录态：注销只删了用户表、没清这份 TTL=-1 的缓存，已登录设备**永久在线**；缓存偶然失效的那批则撞上坑 8，报 500 但仍不弹登录页。

---

## 十、面试高频追问

**Q1：Spring Cloud Gateway 和 Zuul 1 区别？**
A：① IO 模型：Gateway Reactor + Netty 异步非阻塞、Zuul 1 同步 Servlet（每请求 1 线程）；② 性能：Gateway 是 Zuul 1 的 5x；③ 维护：Gateway 是 Spring 官方、Zuul 1 已弃用、Zuul 2 没集成进 Spring Cloud；④ 路由配置：Gateway YAML / Java DSL，Zuul 1 主要 YAML。**新项目都用 Gateway**。

**Q2：三大核心概念？**
A：**Predicate + Filter + Route**。Predicate 决定"什么请求走这条路由"（Path / Method / Header / Cookie / Weight 等 12 种）；Filter 决定"怎么改写请求和响应"（StripPrefix / RewritePath / AddHeader / RateLimiter 等 30+ 种）；Route 是 Predicate + Filter + URI 的组合。

**Q3：`uri: lb://service-name` 是什么意思？**
A：`lb` = LoadBalancer。请求转发到 service-name 这个服务（从 Nacos / Eureka 拿实例列表，按算法选一个）。等价于客户端负载均衡。

**Q4：怎么写一个全局过滤器？**
A：实现 `GlobalFilter` + `Ordered`，注册成 Spring Bean。`order` 越小越先执行。返回 `Mono<Void>` 或 `chain.filter(exchange)` 继续后续 filter。注意是 WebFlux 响应式 API——不能阻塞 EventLoop。

**Q5：网关层限流怎么做？**
A：① 内置 `RequestRateLimiter`（Redis + Lua 令牌桶）；② **Sentinel + spring-cloud-starter-alibaba-sentinel-gateway**（推荐，控制台动态规则）；③ 自定义 GlobalFilter + Redis 计数。生产 90% 用 Sentinel。

**Q6：怎么实现灰度发布？**
A：① 按 Header（如 `X-Version: gray`）走新版本路由；② 按 Weight 配权重（80/20 分流）；③ 按用户（自定义 Predicate Factory，从 Header 提取 userId 判断是否在灰度名单）。配合服务的多版本部署。

**Q7：网关里能做同步 IO 吗？**
A：**不能**。WebFlux 用 Netty EventLoop（线程数 = CPU 核数 * 2），一个阻塞操作就让所有请求卡住。必须 IO 时用 `Mono.fromCallable(...).subscribeOn(Schedulers.boundedElastic())` 切到弹性线程池。**最佳做法是网关里别做 IO**——把鉴权放在 Redis（异步 ReactiveRedisTemplate）或本地缓存。

**Q8：网关怎么把当前用户传给后端？**
A：在过滤器里 `request.mutate().header("X-User-Id", uid).build()` 改写请求，后端 Controller 里 `@RequestHeader("X-User-Id")` 接收。**不要让后端再次解析 JWT**——网关解析一次就够。

**Q9：网关 + Spring Security 怎么配合？**
A：网关层做 **粗粒度鉴权**（登录态、API 黑白名单）；后端服务做 **细粒度授权**（业务权限、数据权限）。网关用 GlobalFilter 检查 token，后端用 `@PreAuthorize` 检查角色。

**Q10：网关性能瓶颈怎么排查？**
A：① 看是否有阻塞操作（同步 JDBC、`block()` 调用）—— Reactor 监控有 `BlockHound`；② 连接池配置（max-connections / acquire-timeout）；③ JVM 监控（堆外内存——Netty 用 DirectBuffer 容易泄漏）；④ 下游响应时间（response-timeout）。

---

## 十一、答题模板（60 秒）

> Spring Cloud Gateway 是 Spring 官方的微服务网关，基于 **Reactor + Netty 异步非阻塞**——比 Zuul 1（同步 Servlet）性能高 5 倍。
>
> **核心**：**Predicate + Filter + Route**——Predicate 匹配请求（Path / Method / Header / Weight 等 12 种），Filter 改写请求响应（StripPrefix / RewritePath / RateLimiter 等 30+ 种），Route 把两者绑到 URI（`lb://service-name` 走负载均衡）。
>
> **典型职责**：① 路由分发；② 统一鉴权（GlobalFilter 解析 JWT 透传 X-User-Id）；③ 限流（内置 RequestRateLimiter / Sentinel）；④ 灰度（Header / Weight / 用户名单）；⑤ CORS / 协议转换；⑥ 监控埋点。
>
> **架构**：请求 → Netty EventLoop → DispatcherHandler → RoutePredicateHandlerMapping 找路由 → FilteringWebHandler 组装 Filter 链（GlobalFilter + 路由级 GatewayFilter）→ NettyRoutingFilter 发起后端请求。
>
> **生产高频坑**：① **不能在网关里做同步 IO**（阻塞 EventLoop 整个网关挂）—— 必要时用 `Schedulers.boundedElastic()`；② DataBuffer 没 release 内存泄漏；③ CORS 必须在鉴权前；④ 白名单用 `startsWith` 被路径穿越绕过（用 AntPathMatcher）；⑤ JWT 用 RSA 慢——改 HS256 + 缓存解析结果。

---

## 十二、相关文档

- 上层：[SpringCloud通用.md](SpringCloud通用.md) — 网关在微服务中的位置
- 配套：[Sentinel.md](Sentinel.md) — 网关层限流熔断
- 配套：[SpringSecurity.md](SpringSecurity.md) — 网关 + Security 分层
- 配套：[WebFlux.md](WebFlux.md) — Reactor / Mono / Flux 编程模型
