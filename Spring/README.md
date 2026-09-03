# Spring 技术面试模块

> 大厂 Java 后端面试**必考四大件之一**（另三个：JVM / Concurrency / MySQL）。
> 本模块聚焦 **Spring Framework + Spring Boot**——**IoC / AOP / Bean 生命周期 / 循环依赖 / 事务 / Web 层 / SpringBoot 自动装配** 六大主题，每篇按"原理 + 取舍 + 面试追问 + 生产踩坑 + 答题模板"五件套结构。
>
> ⚠️ **Spring Cloud 全家桶**（Nacos/Feign/Sentinel/Gateway/Seata）已拆出到独立的微服务/分布式模块——见 [Microservice 模块](../Microservice/README.md) 和 [Distributed/Seata 分布式事务](../Distributed/Seata分布式事务.md)。这是为了让 Spring 模块只关注**单进程内的容器与编程模型**，把跨进程的微服务治理放到它该在的地方。

---

## 模块导航

### 一、Spring 核心（IoC + AOP + Bean）

> Spring 的"心脏"。面试 90% 的问题都从这里延伸。

| 文档 | 一句话定位 |
| --- | --- |
| [IoC 容器](IoC容器.md) | 控制反转 / DI 三种方式 / `BeanFactory` vs `ApplicationContext` / **`refresh()` 12 步** |
| [Bean 生命周期](Bean生命周期.md) | 实例化 → 属性注入 → Aware → BPP → 初始化 → 销毁 / 11 个扩展点 |
| [循环依赖](循环依赖.md) | **三级缓存**为什么必须三级 / 解不了的 4 种场景 |
| [AOP](AOP.md) | JDK 动态代理 vs CGLIB / `this` 调用失效 / 织入时机 |
| [设计模式](设计模式.md) | Spring 中的 11 种设计模式真实代码 |

### 二、Spring 事务 + Web 层

| 文档 | 一句话定位 |
| --- | --- |
| [Spring 事务](Spring事务.md) | `@Transactional` AOP 实现 / **7 种传播行为** / **失效 8 大场景** |
| [Spring 事件机制](Spring事件机制.md) | `ApplicationEvent` + `@EventListener` + `@TransactionalEventListener` 事务感知事件 |
| [Spring Async 与 Scheduling](SpringAsync与Scheduling.md) | `@Async` 线程池坑 / `@Scheduled` cron / **分布式定时任务方案** |
| [Spring Cache](SpringCache.md) | `@Cacheable` 原理 / 二级缓存 / 与穿透雪崩击穿的关系 |
| [Spring Security](SpringSecurity.md) | **15 个过滤器链** / 认证授权 / JWT / OAuth2 |
| [Spring MVC](SpringMVC.md) | DispatcherServlet 9 大组件 / 13 步流程 / Filter vs Interceptor vs AOP |
| [WebFlux](WebFlux.md) | 响应式编程 / Mono Flux / **不适合什么场景** |

### 三、Spring Boot

> 让 Spring 真正"开箱即用"的工具集。

| 文档 | 一句话定位 |
| --- | --- |
| [SpringBoot 启动流程](SpringBoot启动流程.md) | `SpringApplication.run()` 12 步 / 8 个事件钩子 / Tomcat 在哪步启动 |
| [SpringBoot 自动装配](SpringBoot自动装配.md) | `@EnableAutoConfiguration` 原理 / `@Conditional` 系列 / Spring Boot 2.7+ 配置迁移 |
| [Starter 机制](Starter机制.md) | 如何写一个自定义 Starter / 命名规约 / 设计原则 |
| [InitializingBean vs SmartInitializingSingleton](InitializingBean和SmartInitializingSingleton.md) | 单 bean 维度 vs 全局维度的初始化时机 |

---

## 学习依赖图（自下而上）

```
                 ┌────────────────────────────────────────────┐
                 │  Spring Boot 层（自动装配 / Starter）        │
                 │   SpringBoot启动流程                       │
                 │   ├─ SpringBoot自动装配                    │
                 │   ├─ Starter机制                           │
                 │   └─ InitializingBean vs SmartInit...      │
                 └────────────────┬───────────────────────────┘
                                  │ 基于
                                  ▼
                 ┌────────────────────────────────────────────┐
                 │  Spring 应用层（事务 / Web / 工具）          │
                 │   Spring事务                               │
                 │   ├─ Spring事件机制                        │
                 │   ├─ SpringAsync与Scheduling               │
                 │   ├─ SpringCache                           │
                 │   ├─ SpringSecurity                        │
                 │   ├─ SpringMVC                             │
                 │   └─ WebFlux（响应式）                     │
                 └────────────────┬───────────────────────────┘
                                  │ 基于
                                  ▼
                 ┌────────────────────────────────────────────┐
                 │  Spring 核心（IoC / AOP）                  │
                 │   IoC容器 ← 一切的起点                     │
                 │   ├─ Bean生命周期                          │
                 │   ├─ 循环依赖                              │
                 │   ├─ AOP                                   │
                 │   └─ 设计模式                              │
                 └────────────────────────────────────────────┘

                 ⬆ 跨进程的微服务治理（注册中心/网关/限流/熔断/分布式事务）
                   见 ../Microservice/  和 ../Distributed/Seata分布式事务.md
```

---

## 面试高频题 → 文档映射（30 题）

### IoC / Bean

1. **IoC 是什么？反转的是什么？** → [IoC容器.md](IoC容器.md)
2. **BeanFactory 和 ApplicationContext 区别？** → [IoC容器.md](IoC容器.md)
3. **`refresh()` 12 步详解** → [IoC容器.md](IoC容器.md)
4. **构造器 / setter / 字段注入选哪个？** → [IoC容器.md](IoC容器.md)
5. **`@Autowired` vs `@Resource`** → [IoC容器.md](IoC容器.md)
6. **Bean 生命周期完整描述** → [Bean生命周期.md](Bean生命周期.md)
7. **`InitializingBean` vs `@PostConstruct`** → [InitializingBean和SmartInitializingSingleton.md](InitializingBean和SmartInitializingSingleton.md)
8. **`BeanFactory` vs `FactoryBean`** → [设计模式.md](设计模式.md)
9. **单例 bean 是线程安全的吗？** → [IoC容器.md](IoC容器.md)

### 循环依赖

10. **Spring 怎么解决循环依赖？** → [循环依赖.md](循环依赖.md)
11. **为什么必须三级缓存？二级不行吗？** → [循环依赖.md](循环依赖.md)
12. **构造器循环依赖能解吗？** → [循环依赖.md](循环依赖.md)
13. **`@Async` 循环依赖为什么报错？** → [循环依赖.md](循环依赖.md)

### AOP

14. **AOP 实现方式？JDK 动态代理 vs CGLIB？** → [AOP.md](AOP.md)
15. **AOP 织入发生在生命周期哪一步？** → [AOP.md](AOP.md)
16. **`this` 调用 AOP 失效怎么办？** → [AOP.md](AOP.md)
17. **`@Around` 和 `@Before` 区别？** → [AOP.md](AOP.md)

### 事务

18. **`@Transactional` 怎么实现？** → [Spring事务.md](Spring事务.md)
19. **7 种传播行为？** → [Spring事务.md](Spring事务.md)
20. **`@Transactional` 失效场景？** → [Spring事务.md](Spring事务.md)
21. **REQUIRED vs REQUIRES_NEW vs NESTED** → [Spring事务.md](Spring事务.md)

### Spring Boot

22. **`@SpringBootApplication` 等价于什么？** → [SpringBoot自动装配.md](SpringBoot自动装配.md)
23. **自动装配原理？** → [SpringBoot自动装配.md](SpringBoot自动装配.md)
24. **`@Conditional` 系列怎么实现？** → [SpringBoot自动装配.md](SpringBoot自动装配.md)
25. **怎么写一个自定义 Starter？** → [Starter机制.md](Starter机制.md)
26. **Spring Boot 启动流程？** → [SpringBoot启动流程.md](SpringBoot启动流程.md)
27. **Tomcat 在哪步启动的？** → [SpringBoot启动流程.md](SpringBoot启动流程.md)

### Spring MVC / 应用层

28. **DispatcherServlet 处理流程？** → [SpringMVC.md](SpringMVC.md)
29. **Filter vs Interceptor vs AOP 怎么选？** → [SpringMVC.md](SpringMVC.md)
30. **WebFlux 适合什么场景？不适合什么场景？** → [WebFlux.md](WebFlux.md)

> Spring Cloud 相关高频题（Nacos/Feign/Sentinel/Gateway/Seata）见 [Microservice 模块](../Microservice/README.md) 与 [Distributed/Seata 分布式事务](../Distributed/Seata分布式事务.md)。

---

## 推荐学习路径

### 新手路径（按依赖顺序，约 10 天）

```
Day 1   : IoC容器                         （核心、必读）
Day 2   : Bean生命周期                    （配 IoC 一起看）
Day 3   : 循环依赖                        （理解三级缓存）
Day 4   : AOP                             （和 Bean 生命周期串起来）
Day 5   : 设计模式                        （巩固前面）
Day 6-7 : Spring事务 + SpringMVC         （应用层）
Day 8   : SpringBoot启动流程              （把 IoC + 自动装配串起来）
Day 9   : SpringBoot自动装配              （核心机制）
Day 10  : Starter机制 + InitializingBean
   ↓ 进入微服务
转到 Microservice 模块继续学注册发现/治理/限流/网关
```

### 面试速通路径（30 分钟）

打开每篇的 **答题模板（最后一节）** 和 **生产踩坑** 节，跳过原理深挖。

按重要性优先级：
1. **必背**：IoC容器、Bean生命周期、循环依赖、AOP、Spring事务（这五篇是 50% 的提问）
2. **建议背**：SpringBoot自动装配、SpringMVC
3. **了解**：Starter机制、设计模式、WebFlux

---

## 关键速记表

### 核心生命周期顺序

```
@PostConstruct → InitializingBean.afterPropertiesSet → init-method → AOP 代理生成
       → SmartInitializingSingleton.afterSingletonsInstantiated → ContextRefreshedEvent
       → ApplicationStartedEvent → CommandLineRunner → ApplicationReadyEvent
```

### 三级缓存

| 层级 | 名称 | 存什么 |
| --- | --- | --- |
| 1 | `singletonObjects` | 完整 bean |
| 2 | `earlySingletonObjects` | 早期引用（原始或代理） |
| 3 | `singletonFactories` | ObjectFactory（按需生成早期引用 + 触发 AOP 代理） |

### 7 种事务传播行为

| 名称 | 外层有事务 | 外层无事务 |
| --- | --- | --- |
| **REQUIRED**（默认） | 加入 | 新建 |
| **REQUIRES_NEW** | 挂起，新建 | 新建 |
| **NESTED** | SAVEPOINT | 新建 |
| SUPPORTS | 加入 | 不开 |
| NOT_SUPPORTED | 挂起 | 不开 |
| MANDATORY | 加入 | 抛异常 |
| NEVER | 抛异常 | 不开 |

### `@Transactional` 失效 8 场景

1. `this` 自调用
2. private / final / static 方法
3. checked 异常没声明 `rollbackFor`
4. 异常被 catch 吃了
5. bean 没被 Spring 管理
6. 跨线程调用 / `@Async`
7. 多数据源 TM 错配
8. JDK 代理强转实现类

---

## 生产踩坑 TOP 10

| # | 现象 | 根因 / 文档 |
| --- | --- | --- |
| 1 | `@Transactional` 不回滚 | 异常吃了 / `this` 调用 / private 方法 → [Spring事务.md](Spring事务.md) |
| 2 | `@PostConstruct` 里调本类被代理方法不生效 | 此时 AOP 代理还没生成 → [Bean生命周期.md](Bean生命周期.md) |
| 3 | 升级 Spring Boot 2.6+ 启动失败 | 默认禁止循环依赖 → [循环依赖.md](循环依赖.md) |
| 4 | `@Async` 循环依赖 NPE | 早期引用与代理对象不一致 → [循环依赖.md](循环依赖.md) |
| 5 | `@Autowired` 注入静态字段 / 构造器里 NPE | 注入是实例级，字段注入晚于构造器 → [IoC容器.md](IoC容器.md) |
| 6 | 自定义 Starter 不生效 | imports 文件路径错 → [Starter机制.md](Starter机制.md) |
| 7 | CORS 配置冲突 | 必须在 Security 之前生效 → [SpringMVC.md](SpringMVC.md) |
| 8 | 长事务拖死连接池 | 事务里调 RPC 阻塞 → [Spring事务.md](Spring事务.md) |
| 9 | 事务里发事件 listener 提前执行 | 用 `@TransactionalEventListener(AFTER_COMMIT)` → [Spring事件机制.md](Spring事件机制.md) |
| 10 | `@Async` 默认线程池 OOM | 必须显式配 `ThreadPoolTaskExecutor` → [SpringAsync与Scheduling.md](SpringAsync与Scheduling.md) |

> Spring Cloud 相关踩坑（Feign 超时、Nacos 防火墙、Sentinel 阈值、Seata 全局锁等）见 [Microservice 模块](../Microservice/README.md)。

---

## 相关模块

- [Microservice](../Microservice/README.md) — **Spring Cloud 全家桶迁居于此**：Nacos / Feign / Sentinel / Gateway + 服务注册/治理/限流/链路追踪
- [Distributed](../Distributed/README.md) — CAP / Raft / 一致性理论；**Seata 分布式事务**也在这里
- [JVM](../JVM/README.md) — 类加载、内存模型、GC（Spring 启动慢、内存高的根因排查）
- [Concurrency](../Concurrency/README.md) — `@Async`、线程池、AQS
- [MySQL](../MySQL/README.md) — Spring 事务底层依赖的 RDBMS 事务和锁机制
- [Redis](../Redis/README.md) — `RedisTemplate` / Spring Cache 抽象
- [MQ](../MQ/README.md) — 分布式事务最终一致方案
