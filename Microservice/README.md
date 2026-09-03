# Microservice 微服务面试模块

> **微服务工程模式 + 工业实现**——把单体应用拆成多个独立部署的服务后，需要的一整套工程模式与 Spring Cloud 工业实现。
>
> 本模块聚焦 **微服务专属问题**，跟 [Distributed 模块](../Distributed/README.md)（分布式理论 + 通用基础设施）形成两层关系：
>
> ① 解决三个核心问题：
>   - **服务怎么互相找到** → 注册与发现（Nacos/Eureka/Consul/ZK/etcd）
>   - **下游挂了怎么不连累自己** → 治理（限流/熔断/降级/重试/超时/隔离/兜底）
>   - **出问题怎么定位** → 链路追踪（SkyWalking/Zipkin/Jaeger/OTel）
> ② 跟其它模块的关系：
>   - 理论根基 → [Distributed](../Distributed/README.md)（CAP / Raft / 分布式锁 / 分布式 ID / 分布式事务理论 / **Seata**）
>   - 框架基础 → [Spring](../Spring/README.md)（IoC / AOP / 事务 / SpringBoot 自动装配——Spring Cloud 建立在此之上）

---

## 一、模块导航

### 1. 模式与原理（4 篇）

> 与具体框架解耦的微服务工程模式与算法。

| 文档 | 一句话定位 |
| --- | --- |
| [服务注册与发现](./服务注册与发现.md) | Eureka/Nacos/Consul/ZK/etcd 横向对比、阿里弃 ZK 根因、AP/CP 选型 |
| [服务治理](./服务治理.md) | 七板斧（限流/熔断/降级/重试/超时/隔离/兜底）、熔断三态机、Hystrix/Sentinel/Resilience4j/Istio 对比 |
| [限流算法](./限流算法.md) | 固定窗口/滑动窗口/漏桶/令牌桶、Guava RateLimiter/Sentinel/Redis+Lua 集群限流 |
| [链路追踪](./链路追踪.md) | Dapper 模型、TraceId 透传、SkyWalking/Zipkin/Jaeger/OTel 对比、采样策略 |

### 2. Spring Cloud 工业实现（5 篇）

> 把上面的"模式"落地到代码——Spring Cloud 全家桶。

| 文档 | 一句话定位 |
| --- | --- |
| [SpringCloud 通用](./SpringCloud通用.md) | 注册中心 / 负载均衡 / 熔断 / 网关 / 配置中心 / 链路追踪 全景图 + 选型对比 |
| [Nacos](./Nacos.md) | 服务发现 + 配置中心二合一 / **AP/CP 双模式** / 临时 vs 永久实例 / gRPC 长连接 |
| [Feign](./Feign.md) | 声明式 HTTP 客户端 / 动态代理原理 / 生产配置必备项 |
| [Sentinel](./Sentinel.md) | **滑动窗口 + LeapArray** 限流 / 熔断三态 / 与 Hystrix 对比 |
| [Spring Cloud Gateway](./SpringCloudGateway.md) | Predicate + Filter + Route / **Reactor + Netty 异步**架构 / 限流 / 灰度 |

> Seata 分布式事务（Spring Cloud 体系下的分布式事务实现）参见 [Distributed/Seata 分布式事务](../Distributed/Seata分布式事务.md)——它跟分布式事务理论篇放一起更合适。

---

## 二、面试高频题 → 文档映射

### 服务注册与发现

| 高频题 | 跳转 |
| --- | --- |
| 注册中心选 Nacos 还是 ZK？ | [服务注册与发现](./服务注册与发现.md) |
| 阿里为什么放弃 ZK 改用 Nacos？ | [服务注册与发现](./服务注册与发现.md) |
| Nacos 临时实例 vs 永久实例？ | [Nacos](./Nacos.md) |
| 客户端发现 vs 服务端发现？ | [服务注册与发现](./服务注册与发现.md) |
| Nacos AP/CP 切换原理？ | [Nacos](./Nacos.md) |
| Feign 怎么实现的？ | [Feign](./Feign.md) |
| 客户端 LB vs 服务端 LB？ | [SpringCloud 通用](./SpringCloud通用.md) |

### 服务治理 / 限流熔断

| 高频题 | 跳转 |
| --- | --- |
| 限流/熔断/降级到底什么关系？ | [服务治理](./服务治理.md) |
| 熔断三态怎么转换？ | [服务治理](./服务治理.md) |
| 重试为什么会引发雪崩？ | [服务治理](./服务治理.md) |
| 重试和熔断怎么配合？ | [服务治理](./服务治理.md) |
| 线程池隔离 vs 信号量隔离怎么选？ | [服务治理](./服务治理.md) |
| 调用链超时怎么递减？ | [服务治理](./服务治理.md) |
| Hystrix/Sentinel/Resilience4j 怎么选？ | [服务治理](./服务治理.md) |
| 限流四大算法的取舍？ | [限流算法](./限流算法.md) |
| 漏桶和令牌桶区别？怎么选？ | [限流算法](./限流算法.md) |
| Sentinel 限流算法？滑动窗口怎么实现？ | [Sentinel](./Sentinel.md) |
| Sentinel 熔断三态？ | [Sentinel](./Sentinel.md) |
| 集群限流怎么做？ | [限流算法](./限流算法.md) |

### 网关

| 高频题 | 跳转 |
| --- | --- |
| Spring Cloud Gateway vs Zuul 区别？ | [SpringCloudGateway](./SpringCloudGateway.md) |
| Gateway 三大概念（Predicate / Filter / Route） | [SpringCloudGateway](./SpringCloudGateway.md) |

### 链路追踪

| 高频题 | 跳转 |
| --- | --- |
| TraceId 怎么跨进程透传？ | [链路追踪](./链路追踪.md) |
| 异步任务 TraceId 丢失怎么办？ | [链路追踪](./链路追踪.md) |
| OpenTelemetry 是什么？ | [链路追踪](./链路追踪.md) |
| SkyWalking 怎么做到无侵入？ | [链路追踪](./链路追踪.md) |
| 链路追踪采样策略怎么定？ | [链路追踪](./链路追踪.md) |

---

## 三、依赖关系图

```
        [SpringCloud 通用]   ← 全景图，先建立 mental model
                ↓
        ┌───────┼───────┬─────────────┐
        ▼       ▼       ▼             ▼
   [Nacos]   [Feign]  [Sentinel]  [Gateway]
   注册+配置  声明RPC  限流熔断    网关
        │       │       │             │
        ▼       ▼       ▼             ▼
  [服务注册   [服务治理]    [限流算法]    [链路追踪]
   与发现]    熔断/降级     4 种算法     全链路
   AP/CP 选型 重试/隔离     令牌桶      SkyWalking/OTel
        │       │             │             │
        └───────┴──────┬──────┴─────────────┘
                       ▼
                [Distributed 模块]
                CAP/Raft/Seata/分布式锁/ID
```

**面试高频追问主线**：

1. **服务发现**：注册流程 → 心跳 → 健康检查 → AP/CP 选型 → Nacos/ZK 对比 → 阿里弃 ZK
2. **服务治理**：限流（4 种算法 + Sentinel）→ 熔断（三态机）→ 降级（业务/系统）→ 重试（指数退避）→ 超时（递减）→ 隔离（线程池/信号量）
3. **链路追踪**：Dapper（Trace + Span 树）→ TraceId 透传（Header/MDC）→ 采样（头部/尾部）→ OTel 统一标准
4. **网关**：Predicate + Filter + Route → Reactor Netty 异步 → 限流 → 灰度

---

## 四、跨模块联动

| 主题 | 模式（本模块） | 实现（本模块） | 理论根基（Distributed） |
| --- | --- | --- | --- |
| 注册中心 | [服务注册与发现](./服务注册与发现.md) | [Nacos](./Nacos.md) / [Feign](./Feign.md) | [CAP 与 BASE](../Distributed/CAP与BASE.md) / [一致性算法](../Distributed/一致性算法.md) |
| 限流 | [限流算法](./限流算法.md) | [Sentinel](./Sentinel.md) | — |
| 熔断/降级/治理 | [服务治理](./服务治理.md) | [Sentinel](./Sentinel.md) / [SpringCloudGateway](./SpringCloudGateway.md) | — |
| 链路追踪 | [链路追踪](./链路追踪.md) | [SpringCloud 通用](./SpringCloud通用.md) | — |
| 分布式事务 | — | [Distributed/Seata](../Distributed/Seata分布式事务.md) | [Distributed/分布式事务](../Distributed/分布式事务.md) |

---

## 五、推荐学习路径

### 新手路径（按依赖顺序）

```
1. 先看 Distributed/CAP与BASE     ← AP/CP 取舍是注册中心的根
2. 服务注册与发现                  ← 微服务起点
3. SpringCloud 通用                ← 建立全家桶 mental model
4. Nacos                           ← 注册中心 + 配置中心实现
5. Feign                           ← 声明式 RPC 调用
6. 服务治理（先看限流/熔断/降级）   ← 容错三件事
7. Sentinel                        ← 治理框架的工业实现
8. 限流算法                        ← 限流深入
9. SpringCloudGateway              ← 网关
10. 链路追踪                       ← 排障必备
```

### 面试速通路径（30 分钟刷答题模板）

每篇都已配 **答题模板（60 秒话术）** ——直接复述就是 senior 级回答：

- [服务注册与发现](./服务注册与发现.md)
- [服务治理](./服务治理.md)
- [限流算法](./限流算法.md)
- [链路追踪](./链路追踪.md)
- [SpringCloud 通用](./SpringCloud通用.md)
- [Nacos](./Nacos.md)
- [Feign](./Feign.md)
- [Sentinel](./Sentinel.md)
- [SpringCloudGateway](./SpringCloudGateway.md)

---

## 六、关键速记表

### 服务发现五大方案对比

| 维度 | **Nacos** | Eureka | Consul | ZooKeeper | etcd |
| --- | --- | --- | --- | --- | --- |
| **CAP** | **AP / CP 可切** | AP | CP | CP | CP |
| **配置中心** | ✅ 一体 | ❌ | ✅ KV | ❌ | ✅ KV |
| **维护现状** | 阿里活跃 | **已停更** | HashiCorp | Apache | CNCF |
| **多语言** | 较好 | Java 为主 | 多语言 | 多语言 | 多语言 |
| **国内主流** | **是** | 否 | 否 | 老项目 | K8s |

### Spring Cloud 组件演进

| 能力 | 旧（已弃用） | 新（推荐） |
| --- | --- | --- |
| 注册中心 | Eureka | **Nacos** |
| 负载均衡 | Ribbon | **Spring Cloud LoadBalancer** |
| 熔断 | Hystrix | **Sentinel** / Resilience4j |
| 网关 | Zuul 1 | **Spring Cloud Gateway** |
| 配置中心 | Spring Cloud Config | **Nacos Config** / Apollo |
| 分布式事务 | — | **Seata**（见 Distributed） |

### 服务治理"七板斧"

| 模式 | 触发 | 行为 |
| --- | --- | --- |
| 限流 | 入口超阈值 | 拒绝部分请求 |
| 熔断 | 下游故障率高 | 快速失败 + 周期性试探 |
| 降级 | 主流程失败 | 返回兜底数据 |
| 重试 | 偶发失败 | 指数退避 + 限次 |
| 超时 | 调用太慢 | 主动断开 + 递减式约束 |
| 隔离 | 资源争抢 | 线程池/信号量分组 |
| 兜底 | 终极保护 | 缓存/默认值/静态页 |

### 限流四大算法对比

| 算法 | 突发友好 | 实现 | 典型用途 |
| --- | --- | --- | --- |
| 固定窗口 | ❌（边界突刺） | 计数器 + 时间窗 | 简单场景 |
| 滑动窗口 | 中 | 多格子滑动统计 | Sentinel LeapArray |
| 漏桶 | ❌（强制平滑） | FIFO + 固定出水 | 控制下游速率 |
| **令牌桶** | ✅ | 匀速生令牌 + 消费 | **应用层限流首选** |

### 链路追踪四大框架对比

| 维度 | SkyWalking | Zipkin | Jaeger | OpenTelemetry |
| --- | --- | --- | --- | --- |
| 探针 | **字节码增强**（无侵入） | 代码埋点 | 代码埋点 | SDK + 自动探针 |
| 拓扑图 | ✅ | ❌ | 中 | — |
| 告警 | ✅ | ❌ | ❌ | — |
| 多语言 | Java 强 | 多语言 | 多语言 | **全语言** |
| 国内主流 | **是** | — | — | 趋势 |

---

## 七、生产踩坑 TOP 14

1. **MyBatis 不配 SQL 超时**：慢 SQL 把连接池打满 → 整服务 503。→ [服务治理](./服务治理.md)
2. **Feign 默认 1s 超时**：业务调用 2-3s 经常误超时。→ [Feign](./Feign.md)
3. **重试不加指数退避**：故障期间立即重试 → 雪崩。→ [服务治理](./服务治理.md)
4. **熔断打开后没监控**：故障 30 分钟才发现。→ [服务治理](./服务治理.md)
5. **降级返回错误数据**：余额降级返回 0 → 用户以为账户被清空。→ [服务治理](./服务治理.md)
6. **Nacos 控制台公网暴露**：默认 `nacos/nacos` 被扫到。→ [Nacos](./Nacos.md)
7. **临时/永久实例混用**：MySQL 注册成临时实例 → 30s 被剔除。→ [Nacos](./Nacos.md)
8. **Nacos 1.x → 2.x 升级注册不上**：防火墙没开 9848/9849。→ [Nacos](./Nacos.md)
9. **Sentinel 夜间误熔断**：`minRequestAmount` 漏配。→ [Sentinel](./Sentinel.md)
10. **异步任务 TraceId 丢失**：MDC 不跨线程传递。→ [链路追踪](./链路追踪.md)
11. **Gateway 全局 Filter 优先级错误**：鉴权 Filter 在限流之后执行 → 攻击放大。→ [SpringCloudGateway](./SpringCloudGateway.md)
12. **Feign 没设超时拖死调用方**：必须配 connect/read timeout。→ [Feign](./Feign.md)
13. **`WebClient.retrieve()` 对非 2xx 抛异常**：网关回源拿到 500 时直接抛出，"查不到就拦截"的降级分支从未执行。→ [SpringCloudGateway 坑 8](./SpringCloudGateway.md)
14. **网关鉴权缓存 TTL=-1 且删用户不清缓存**：命中即放行，已注销账号永久在线。→ [SpringCloudGateway 坑 9](./SpringCloudGateway.md)

---

## 八、相关模块

- [Distributed 模块](../Distributed/README.md) — 分布式理论与通用基础设施（CAP/Raft/事务/锁/ID/哈希），**Seata 在此**
- [Spring 模块](../Spring/README.md) — Spring Framework + Spring Boot 单进程基础（IoC/AOP/事务/SpringBoot 自动装配）
- [MQ 模块](../MQ/README.md) — RocketMQ 也是微服务架构的一部分
- [Redis 模块](../Redis/README.md) — 缓存中间件，集群限流的存储层
- [Middleware 模块](../Middleware/README.md) — Netty / Dubbo（另一套 RPC 体系）/ Nginx（前置网关）
- [Network 模块](../Network/README.md) — TCP / HTTP / IO 模型（微服务通信底层）
- Project 模块 — 高并发实战、性能优化
