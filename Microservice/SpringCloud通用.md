# Spring Cloud 通用

> 微服务架构面试必考。这道题的"段位差"在两点：
> ① 能不能讲清 **注册中心 / 服务发现 / 负载均衡 / 熔断 / 网关 / 配置中心** 各组件的"分工"，而不是只罗列名词
> ② 能不能讲清 **Eureka vs Nacos vs Consul vs ZooKeeper** 在 CAP 取舍上的差异
> 答得清这两块就是高级。

---

## 一、Spring Cloud 解决什么

单体架构的"通讯方式"是**进程内方法调用**，所有问题都是 JVM 内的事——拿对象、调方法、回数据。

微服务把单体拆成 N 个独立进程，每个跑在不同机器上，通讯方式变成 **网络调用**。一下冒出 N 个新问题：

| 问题 | 单体里 | 微服务里 |
| --- | --- | --- |
| 怎么找到对方服务 | `@Autowired` | **服务发现** / 注册中心 |
| 多个实例选哪一个 | 没这问题 | **负载均衡** |
| 对方挂了怎么办 | NPE | **熔断 / 降级 / 重试** |
| 配置怎么集中管理 | application.yml | **配置中心** |
| 外部请求路由 / 鉴权 | Spring MVC | **网关** |
| 跨服务调用问题排查 | 一个堆栈搞定 | **链路追踪** |
| 跨服务一致性 | DB 事务 | **分布式事务** / 最终一致 |

Spring Cloud = 把以上每个问题都做一个组件 + 一套 starter 黏起来。

---

## 二、Spring Cloud 组件全景

```
                                 ┌────────────────────────────┐
                                 │       客户端 / 前端          │
                                 └─────────────┬──────────────┘
                                                │
                                                ▼
                          ┌─────────────────────────────────────────┐
                          │   网关  Spring Cloud Gateway / Zuul      │
                          │   · 路由 · 鉴权 · 限流 · 灰度 · 改写       │
                          └────────┬─────────────────────┬──────────┘
                                    │                     │
                                    ▼                     ▼
              ┌──────────── 服务 A ─────────────┐  ┌──── 服务 B ─────┐
              │ @FeignClient / RestTemplate     │  │                │
              │       │                         │  │                │
              │       │ ① 找谁？                │  │                │
              │       ▼                         │  │                │
              │  ┌──── 服务发现 ────┐            │  │                │
              │  │ Nacos / Eureka /│            │  │                │
              │  │ Consul / ZK     │ ◀──────────│──│── 注册        │
              │  └─────────────────┘            │  │                │
              │       │                         │  │                │
              │       │ ② 选哪个实例？          │  │                │
              │       ▼                         │  │                │
              │  ┌── 负载均衡 ──┐                │  │                │
              │  │ LoadBalancer│                │  │                │
              │  │ (Ribbon 已弃)│               │  │                │
              │  └─────────────┘                │  │                │
              │       │                         │  │                │
              │       │ ③ 调用，可能挂          │  │                │
              │       ▼                         │  │                │
              │  ┌── 熔断 / 降级 ──┐             │  │                │
              │  │ Sentinel /     │             │  │                │
              │  │ Resilience4j   │             │  │                │
              │  └────────────────┘             │  │                │
              │                                  │  │                │
              │  ┌── 配置 ─────────┐ ◀───── 推 ──│──│── 配置中心     │
              │  │ @ConfigurationP│             │  │ Nacos /        │
              │  │ roperties      │             │  │ Apollo / Config│
              │  └────────────────┘             │  │                │
              │                                  │  │                │
              │  ┌── 链路追踪 ────┐               │  │                │
              │  │ Sleuth + Zipkin│              │  │                │
              │  │ / SkyWalking   │              │  │                │
              │  └────────────────┘              │  │                │
              └──────────────────────────────────┘  └────────────────┘
```

---

## 三、注册中心 / 服务发现

### 3.1 解决的问题

服务 A 怎么调到服务 B？硬编码 IP：服务 B 实例上下线时 A 看不到。**注册中心**负责：
- 服务**注册**：B 实例启动后告诉注册中心"我在 192.168.1.5:8080，名字叫 user-service"
- 服务**发现**：A 启动后向注册中心查"user-service 现在有哪些活着的实例"
- **健康检查**：B 挂了之后，A 不要再调它

### 3.2 主流注册中心对比

| 维度 | **Eureka** | **Nacos** | **Consul** | **ZooKeeper** |
| --- | --- | --- | --- | --- |
| 出品 | Netflix（已停止维护） | 阿里 | HashiCorp | Apache |
| **CAP** | **AP** | **CP/AP 可切换** | CP（默认） | **CP** |
| 协议 | HTTP REST | HTTP + gRPC（2.x） | HTTP + DNS | TCP（自定义） |
| 健康检查 | Client 心跳 | Client 心跳 + 主动探测 | 多种（HTTP/TCP/Script/Docker） | 会话超时 |
| 集群一致性 | 去中心化 P2P 复制 | Raft（CP）/ Distro（AP） | Raft | ZAB |
| 支持配置中心 | ❌ | ✅ | ✅（KV 存储） | ❌（需另搭） |
| Spring Cloud 集成 | `spring-cloud-starter-netflix-eureka-*` | `spring-cloud-starter-alibaba-nacos-discovery` | `spring-cloud-starter-consul-discovery` | `spring-cloud-starter-zookeeper-discovery` |
| 性能（注册容量） | 中 | **高**（数十万实例） | 中 | 中（节点数受限） |
| 多语言支持 | Java 为主 | 多语言（Java/Go/Python/...） | 多语言 | 多语言 |
| 现状 | **已停更**，慎选新项目 | 主流（Spring Cloud Alibaba） | 海外常用 | 老项目存在 |

### 3.3 怎么选

| 业务场景 | 推荐 |
| --- | --- |
| 国内 Java 微服务、需要配置中心一站式 | **Nacos** |
| 海外、多语言、需要 KV 配置 | Consul |
| 老项目已经在用 ZK | 沿用 ZK，**注意 watch 风暴问题** |
| 已经在 Eureka，没特殊问题 | 沿用（但不推荐新项目用） |

### 3.4 CAP 取舍

**为什么 Nacos 默认 AP，可切 CP**：
- AP（默认 Distro 协议）：节点间最终一致，但保证可用性。**适合服务发现**——服务列表过期几秒不致命。
- CP（Raft）：强一致但少数派节点不可用。**适合配置中心**——配置必须强一致，否则 A 节点读到旧配置。

**为什么 ZooKeeper 是 CP 不适合服务发现**：网络分区时少数派会拒绝写——服务实例的注册和发现会**直接失败**。Eureka 的设计哲学相反："**服务发现宁可拿到旧数据，不能没有数据**"。

> **生产追问**：网络抖动时大量服务从 ZK"消失"造成雪崩——这是 ZK 做注册中心的著名坑。Spring Cloud 早期推 Eureka 就是这个原因。

### 3.5 Spring Cloud 通用集成步骤

```xml
<!-- 选一个 -->
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-nacos-discovery</artifactId>
</dependency>
```

```yaml
spring:
  application:
    name: user-service       # 服务名（注册时用）
  cloud:
    nacos:
      discovery:
        server-addr: 127.0.0.1:8848
```

```java
@SpringBootApplication
@EnableDiscoveryClient        // 启用服务发现（Spring Cloud 2020+ 可省略）
public class App { }
```

详见 [Nacos.md](Nacos.md)。

---

## 四、负载均衡

### 4.1 客户端负载均衡 vs 服务端负载均衡

| 维度 | 客户端 LB（Ribbon / Spring Cloud LoadBalancer） | 服务端 LB（Nginx / F5 / LVS） |
| --- | --- | --- |
| 实例列表来源 | 注册中心 | 配置文件 / DNS |
| 选择算法 | 客户端本地决策 | 服务端转发 |
| 性能 | **少一跳网络**（直接调目标） | 多一跳（先到 LB） |
| 故障感知 | 实时（注册中心推送） | 慢（配置或健康检查） |
| 复杂度 | 高（每个客户端都要装 LB 库） | 低（透明） |
| 典型场景 | **微服务内部调用** | 入口网关 / 跨语言 |

### 4.2 Spring Cloud 的负载均衡演进

| 时代 | 实现 | 现状 |
| --- | --- | --- |
| Spring Cloud 1.x ~ Hoxton | Netflix Ribbon | **已弃用** |
| Spring Cloud 2020+ | **Spring Cloud LoadBalancer** | **现在用的** |

```xml
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-loadbalancer</artifactId>
</dependency>
```

### 4.3 常用算法

| 算法 | 含义 | 适用 |
| --- | --- | --- |
| **轮询**（默认） | 顺序分配 | 无状态、实例性能均衡 |
| **随机** | 随机选 | 简单、效果接近轮询 |
| **加权轮询** | 按权重比例 | 实例性能不均 |
| **一致性 Hash** | 同一参数路由到同一实例 | 缓存命中、有状态 |
| **最小连接** | 选连接数最少的 | 长连接场景 |
| **Response Time** | 选响应最快的 | 实例性能波动大 |

### 4.4 自定义算法（生产示例）

```java
@Configuration
public class CustomLBConfig {
    @Bean
    public ReactorLoadBalancer<ServiceInstance> randomLoadBalancer(
            Environment env, LoadBalancerClientFactory factory) {
        String name = env.getProperty(LoadBalancerClientFactory.PROPERTY_NAME);
        return new RandomLoadBalancer(factory.getLazyProvider(name, ServiceInstanceListSupplier.class), name);
    }
}

// 应用到特定服务
@LoadBalancerClient(name = "user-service", configuration = CustomLBConfig.class)
public class App { }
```

---

## 五、声明式调用：Feign / OpenFeign

详见 [Feign.md](Feign.md)。

```java
@FeignClient(name = "user-service")
public interface UserClient {
    @GetMapping("/user/{id}")
    User getById(@PathVariable Long id);
}

// 业务里直接当本地 bean 用
@Resource private UserClient userClient;
```

Feign 内部把接口动态代理 → 走 LoadBalancer 选实例 → 用 RestTemplate / WebClient 发 HTTP。

---

## 六、熔断 / 降级 / 限流

### 6.1 三个概念

| 概念 | 含义 | 时机 |
| --- | --- | --- |
| **熔断**（Circuit Breaker） | 短时间内大量失败 → 直接拒绝后续请求一段时间 | 下游服务不可用时 |
| **降级**（Fallback） | 主流程失败 → 走兜底逻辑（返回默认值 / 缓存） | 熔断触发时、超时时 |
| **限流**（Rate Limiting） | 单位时间内请求数超阈值 → 拒绝 | **保护自己**不被打挂 |

### 6.2 主流方案

| 方案 | 出品 | 特点 |
| --- | --- | --- |
| **Hystrix** | Netflix | 已停止维护 |
| **Sentinel** | 阿里 | 国内主流，控制台强大 |
| **Resilience4j** | Spring Cloud 推荐 | 函数式 API，轻量 |

### 6.3 熔断器三种状态

```
       [CLOSED 闭合]
       正常放行
            │
            │  失败率 > 阈值
            ▼
        [OPEN 打开]
        直接拒绝（快速失败）
            │
            │  等待 N 秒
            ▼
       [HALF_OPEN 半开]
       放少量请求探测
            │
            │  成功率 > 阈值 → CLOSED
            │  失败率 > 阈值 → OPEN
```

### 6.4 Sentinel 配置示例

```java
@SentinelResource(value = "getUser", fallback = "getUserFallback", blockHandler = "blockHandler")
public User getUser(Long id) {
    return userClient.getById(id);
}

public User getUserFallback(Long id, Throwable e) {
    return User.UNKNOWN;          // 降级返回
}

public User blockHandler(Long id, BlockException e) {
    throw new BizException(429, "请求过载");   // 限流处理
}
```

> **Sentinel vs Hystrix**：① Sentinel 更轻量（不强依赖线程池隔离）；② 控制台支持热更新规则；③ 限流维度更丰富（QPS / 并发数 / 调用关系 / 热点参数）。

---

## 七、网关

### 7.1 解决什么

外部请求进入微服务集群的 **统一入口**。承担：
- **路由**：把 `/user/**` 转到 user-service，`/order/**` 转到 order-service
- **鉴权**：统一登录态校验
- **限流**：防刷、防雪崩
- **灰度**：按 Header / 用户分流到新版本
- **改写**：跨域、加密、日志、协议转换

### 7.2 主流方案

| 方案 | 时代 | 状态 |
| --- | --- | --- |
| **Zuul 1** | Spring Cloud Netflix | 已淘汰（同步 Servlet 模型，性能差） |
| **Zuul 2** | Netflix | 未集成 Spring Cloud，少用 |
| **Spring Cloud Gateway** | Spring Cloud 官方 | **主流**（Reactor + Netty 异步） |

### 7.3 Spring Cloud Gateway 三大概念

```
Predicate（断言）  +  Filter（过滤器）  →  Route（路由）

Predicate：什么样的请求走这条路由（路径、Header、Method、Host、Cookie...）
Filter：怎么改写这个请求或响应
Route：完整路由规则
```

```yaml
spring:
  cloud:
    gateway:
      routes:
        - id: user-route
          uri: lb://user-service                    # lb:// 前缀走负载均衡
          predicates:
            - Path=/user/**                          # 路径匹配
            - Method=GET,POST
          filters:
            - StripPrefix=1                          # /user/123 → /123
            - AddRequestHeader=X-Source,Gateway
```

### 7.4 自定义全局过滤器

```java
@Component
@Slf4j
public class AuthFilter implements GlobalFilter, Ordered {
    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        String token = exchange.getRequest().getHeaders().getFirst("Authorization");
        if (!isValid(token)) {
            exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
            return exchange.getResponse().setComplete();
        }
        return chain.filter(exchange);
    }
    
    @Override
    public int getOrder() { return -100; }   // 越小越先执行
}
```

---

## 八、配置中心

### 8.1 解决什么

`application.yml` 写在 jar 里——改一行配置要重新打包发布。**配置中心**做：
- **集中管理**：所有服务的配置在一处
- **环境隔离**：dev / test / prod 不同环境
- **动态刷新**：改配置后服务实时感知，**不重启**
- **审计**：谁改的、改了什么、什么时候改的

### 8.2 主流方案

| 方案 | 出品 | 特点 |
| --- | --- | --- |
| **Spring Cloud Config** | Spring 官方 | 基于 Git，简单但功能弱 |
| **Nacos Config** | 阿里 | 注册 + 配置一站式 |
| **Apollo** | 携程 | **功能最完整**：环境隔离、灰度、审计、推送 |
| **Consul KV** | HashiCorp | KV 存储，简单 |

### 8.3 动态刷新的原理

```
     业务 bean
        │
        ▼
   @RefreshScope      ← 关键注解
        │
        ▼
配置中心推送变更（长轮询 / WebSocket / gRPC stream）
        │
        ▼
ConfigurationPropertiesRebinder 重新绑定 @ConfigurationProperties
        │
        ▼
@RefreshScope bean 销毁重建（拿最新配置）
```

```java
@RestController
@RefreshScope                              // 配置变更时这个 bean 会被重建
public class FooController {
    @Value("${myapp.feature.enabled}")
    private boolean enabled;
    
    @GetMapping("/foo")
    public String foo() { return enabled ? "on" : "off"; }
}
```

### 8.4 Nacos Config 示例

```yaml
spring:
  application:
    name: user-service
  cloud:
    nacos:
      config:
        server-addr: 127.0.0.1:8848
        file-extension: yaml
        namespace: prod                         # 环境隔离
```

Nacos 上配置 dataId 为 `user-service.yaml` 的内容自动加载。修改并发布后，所有 user-service 实例 1 秒内拿到新配置。

---

## 九、链路追踪

### 9.1 解决什么

服务 A 调 B 调 C 调 D，请求在 D 失败——**怎么定位是哪一层出的问题**？日志查 4 个服务、对时间戳——抓瞎。

链路追踪通过 **TraceId / SpanId** 把一次请求在所有服务的执行串起来：

```
请求进入网关 → trace_id=abc, span_id=001
  │
  ├── 调 service-A → trace_id=abc, span_id=002, parent=001
  │     │
  │     └── 调 service-B → trace_id=abc, span_id=003, parent=002
  │
  └── 调 service-C → trace_id=abc, span_id=004, parent=001
```

### 9.2 主流方案

| 方案 | 出品 | 特点 |
| --- | --- | --- |
| **Spring Cloud Sleuth + Zipkin** | Spring 官方 | 入门简单 |
| **SkyWalking** | Apache | **国内主流**，无侵入字节码增强 |
| **Pinpoint** | Naver | 字节码增强 |
| **Jaeger** | Uber | OpenTracing 标准 |

### 9.3 Spring Cloud Sleuth 自动埋点

```xml
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-sleuth</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-sleuth-zipkin</artifactId>
</dependency>
```

引入后日志自动带上 `[traceId, spanId]`：

```
2026-05-09 ... [user-service,abc1234,567def] INFO  ... user query: id=123
```

---

## 十、生产踩坑

### 坑 1：Eureka 自我保护把"已下线"实例显示为正常

线上下掉一个实例，但 Eureka 仪表盘显示它还在 → 流量打到挂掉的实例 → 大量 Connection Refused。
**根因**：Eureka 自我保护机制——15 分钟内心跳丢失比例超过阈值时进入保护，**不剔除任何实例**。
**修法**：测试环境 `eureka.server.enable-self-preservation=false`；生产环境保留但优化超时阈值。

### 坑 2：Nacos 1.x → 2.x 升级 client / server 版本不匹配

升级后注册成功但**找不到服务**。
**根因**：2.x 默认走 gRPC（端口 9848 / 9849），需要防火墙额外放开。
**修法**：① 防火墙放开 9848 / 9849；② 临时降级用 1.x 的 HTTP 协议（`naming.local.snapshot.useHttpToFetch=true`）。

### 坑 3：Feign 调用没设超时，一个慢接口拖死整个网关

Feign 默认超时 1 秒（旧版）或没超时——下游慢响应导致 Feign 调用线程全部阻塞，网关线程池打满。
**修法**：每个 FeignClient 都必须配超时：

```yaml
feign:
  client:
    config:
      default:
        connectTimeout: 2000
        readTimeout: 5000
```

### 坑 4：Sentinel 规则在重启后丢失

Sentinel 默认规则存在内存——服务重启后所有限流规则消失。
**修法**：用 Sentinel + Nacos 持久化规则。

### 坑 5：Spring Cloud Gateway 内存泄漏

WebFlux + Netty 模式下，错误处理写得不规范导致内存泄漏。例如：在 GlobalFilter 里 read 了 body 但没 release。
**修法**：用 `DataBufferUtils.release(buffer)` 显式释放；或用 Spring 提供的 `ServerWebExchangeUtils.cacheRequestBody`。

---

## 十一、面试高频追问

**Q1：Spring Cloud 都有哪些核心组件？**
A：① 注册中心（Eureka/Nacos/Consul/ZK）；② 负载均衡（LoadBalancer，旧版 Ribbon）；③ 声明式调用（OpenFeign）；④ 熔断降级（Sentinel/Resilience4j，旧版 Hystrix）；⑤ 网关（Gateway，旧版 Zuul）；⑥ 配置中心（Nacos Config / Apollo / Spring Cloud Config）；⑦ 链路追踪（Sleuth + Zipkin / SkyWalking）。

**Q2：Eureka 和 Nacos 区别？**
A：① CAP：Eureka 纯 AP；Nacos AP/CP 可切。② 协议：Eureka HTTP；Nacos HTTP+gRPC。③ 配置中心：Eureka 不带；Nacos 一站式。④ 健康检查：Eureka 心跳；Nacos 心跳+主动探测。⑤ 维护：Eureka 已停更；Nacos 主流维护中。**新项目优先 Nacos**。

**Q3：为什么 ZooKeeper 不适合做服务注册中心？**
A：ZK 是 CP 系统——网络分区时少数派节点拒绝写。**而服务发现允许"拿到旧数据"，不允许"完全没数据"**——AP 才合适。Eureka 的设计哲学就是反 ZK。CAP 取舍上 ZK 适合配置中心、分布式锁，不适合服务注册中心（除非业务能容忍短暂"找不到任何服务"）。

**Q4：客户端负载均衡 vs 服务端负载均衡选哪个？**
A：① 入口网关（外部进来）→ 服务端 LB（Nginx/F5）；② 微服务内部调用 → 客户端 LB（Spring Cloud LoadBalancer）。客户端 LB 少一跳、故障感知快，但每个客户端都要带 LB 库。

**Q5：熔断和限流有什么区别？**
A：
- 熔断：保护**调用方**——下游服务不可用时快速失败，避免线程池耗尽
- 限流：保护**自己**——防止流量超过容量被打垮
两者经常配合：限流挡掉一波流量，剩下的请求里如果下游挂了再熔断。

**Q6：Hystrix 和 Sentinel 选哪个？**
A：新项目 **Sentinel**——Hystrix 已停更，Sentinel 控制台和规则更强大。Resilience4j 是 Spring 官方推荐，更轻量但功能不如 Sentinel。国内项目 95% 选 Sentinel。

**Q7：Spring Cloud Gateway 和 Zuul 区别？**
A：底层 IO 模型完全不同——Zuul 1 是同步 Servlet，每请求一个线程；Spring Cloud Gateway 用 Reactor + Netty 异步非阻塞。**Gateway 性能高 3-5 倍**，且支持 WebFlux。Zuul 1 已淘汰，Zuul 2 没集成进 Spring Cloud。新项目用 Gateway。

**Q8：Spring Cloud Config 和 Nacos Config 区别？**
A：
- Spring Cloud Config：基于 Git，需要触发 `/actuator/refresh` 才刷新（或装 Spring Cloud Bus）；功能弱
- Nacos Config：原生支持长连接推送，秒级生效；带 namespace 隔离环境；带历史版本和回滚
- Apollo：功能最强（环境/集群/灰度/审计），运维复杂度也最高

国内 90% 项目选 Nacos 或 Apollo。

**Q9：链路追踪原理？**
A：① 入口生成全局 `TraceId`；② 每个 span（一次方法/RPC 调用）有自己的 `SpanId` 和 `parentSpanId`；③ 跨进程通过 HTTP Header（B3 / W3C TraceContext 标准）传递；④ 各服务把 span 异步上报给 collector（Zipkin/Jaeger）；⑤ collector 按 TraceId 聚合成完整链路。

**Q10：分布式事务在 Spring Cloud 里怎么搞？**
A：四类方案：① **XA**（JtaTransactionManager + Atomikos）——强一致但性能差；② **TCC**（Try-Confirm-Cancel，业务侵入）；③ **Seata AT 模式**——阿里开源，自动补偿，无侵入；④ **最终一致性**（本地消息表 / RocketMQ 事务消息）——业务最常用。生产 90% 用方案 ④。

---

## 十二、答题模板（60 秒）

> Spring Cloud 是 **微服务架构的工具集**，把单体拆分微服务后冒出的 7 类问题各做一个组件解决：
>
> ① **服务发现**（Nacos / Eureka / Consul / ZK）—— Nacos 主流，AP/CP 可切；ZK 是 CP 不适合服务发现（网络分区时拒绝写）。
> ② **负载均衡**（Spring Cloud LoadBalancer，旧版 Ribbon）—— 客户端 LB 少一跳、故障感知快。
> ③ **声明式调用**（OpenFeign）—— 接口动态代理 + LoadBalancer。
> ④ **熔断降级**（Sentinel / Resilience4j，旧版 Hystrix）—— 熔断三态：CLOSED → OPEN → HALF_OPEN。
> ⑤ **网关**（Spring Cloud Gateway，Reactor + Netty 异步）—— 路由 / 鉴权 / 限流 / 灰度。
> ⑥ **配置中心**（Nacos Config / Apollo / Spring Cloud Config）—— `@RefreshScope` 实现动态刷新。
> ⑦ **链路追踪**（Sleuth + Zipkin / SkyWalking）—— TraceId / SpanId 跨进程传递。
>
> **CAP 取舍**：服务发现走 AP（允许旧数据，不能没数据）；配置中心走 CP（强一致，不能读到旧配置）。Nacos 默认 AP 做服务发现、CP 做配置中心，一站式。
>
> **生产高频坑**：① Eureka 自我保护把已挂实例显示正常；② Feign 没设超时拖死调用方；③ Nacos 2.x gRPC 端口防火墙；④ Sentinel 规则不持久化；⑤ Gateway WebFlux 下 buffer 没 release 内存泄漏。

---

## 十三、相关文档

- 详细：[Nacos.md](Nacos.md) — 注册中心 + 配置中心实现细节
- 详细：[Feign.md](Feign.md) — 声明式调用底层
- 配套：[../Distributed/](../Distributed/README.md) — 分布式系统理论（CAP / 一致性）
- 配套：[../MQ/](../MQ/) — 消息队列 / 分布式事务最终一致
