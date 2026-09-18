# Middleware 中间件 / 应用层网络框架

> Java 后端常用的**应用层中间件**——Netty、Nginx、RPC、Dubbo、Elasticsearch、MongoDB、XXL-JOB。
> 跟下面这两个相邻模块的边界：
>
> - **网络协议 + IO 基础**（TCP / HTTP / IO 模型 / 多路复用 / 零拷贝 / WebSocket）→ 拆出到 [Network 模块](../Network/README.md)，本模块默认你已经懂这些。
> - **缓存 / 消息 / 关系数据库**等同样属于"中间件"的核心存储 → 各自在 [Redis](../Redis/README.md) / [MQ](../MQ/README.md) / [MySQL](../MySQL/README.md) 模块单独成体系。
>
> 本模块特指**通信框架 + 反向代理 + 远程调用 + 搜索引擎 + NoSQL 文档库 + 分布式调度**这一类——Java 后端最常自建或选型的中间件。

---

## 一、模块导航

### 网络框架（2 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [Netty](./Netty.md) | 主从 Reactor / EventLoop / Pipeline / ByteBuf / 内存池 |
| [Nginx](./Nginx.md) | Master-Worker / epoll 异步 / 反代 LB / 限流 / HTTPS 卸载 |

### 远程通信（2 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [RPC 原理](./RPC原理.md) | 序列化对比 / 协议设计 / HTTP vs RPC / 主流框架横评 |
| [Dubbo](./dubbo.md) | 10 层架构 / SPI 微内核 / 集群容错 / Triple 协议 |

### 搜索中间件（1 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [Elasticsearch](./es.md) | 倒排索引 / DocValues / 写入流程 / 深分页 / 调优 |

### 文档型 NoSQL（1 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [MongoDB](./MongoDB.md) | WiredTiger / 副本集选举 + Oplog / 分片片键 / 4.0 事务 / 踩坑 |

### 任务调度（1 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [XXL-JOB](./xxl-job.md) | Admin + Executor / DB 行锁调度 / 9 路由 + 分片广播 / 失败处理 |

> WebSocket（HTTP Upgrade / 帧格式 / 心跳 / 长连接架构）已迁到 [Network 模块](../Network/README.md)，因为它本质是网络协议而非中间件框架。

---

## 二、面试高频题 → 文档映射

### Netty

| 高频题 | 跳转 |
| --- | --- |
| 为什么不用 JDK NIO？ | [Netty](./Netty.md) |
| Netty 线程模型 / EventLoop？ | [Netty](./Netty.md) |
| ByteBuf vs ByteBuffer？ | [Netty](./Netty.md) |
| Pipeline 的 Inbound/Outbound 顺序？ | [Netty](./Netty.md) |
| TCP 粘包/拆包怎么处理？ | [Netty](./Netty.md) |
| Netty 怎么做心跳？ | [Netty](./Netty.md) |
| Netty 内存泄漏怎么排查？ | [Netty](./Netty.md) |
| 业务慢怎么不阻塞 IO 线程？ | [Netty](./Netty.md) |
| FastThreadLocal 比 ThreadLocal 快在哪？ | [Netty](./Netty.md) |

### RPC 与 Dubbo

| 高频题 | 跳转 |
| --- | --- |
| RPC 跟 HTTP 区别？为什么内部用 RPC？ | [RPC 原理](./RPC原理.md) |
| 一次 RPC 调用完整流程？ | [RPC 原理](./RPC原理.md) |
| 序列化怎么选？Protobuf 为啥快？ | [RPC 原理](./RPC原理.md) |
| 怎么解决 TCP 粘包？ | [RPC 原理](./RPC原理.md) |
| Dubbo 10 层架构？ | [Dubbo](./dubbo.md) |
| Dubbo SPI 跟 JDK SPI 区别？ | [Dubbo](./dubbo.md) |
| Dubbo Adaptive 怎么实现？ | [Dubbo](./dubbo.md) |
| Cluster 跟 LoadBalance 区别？ | [Dubbo](./dubbo.md) |
| Dubbo 3 vs Dubbo 2 核心区别？ | [Dubbo](./dubbo.md) |
| 灰度发布怎么做？ | [Dubbo](./dubbo.md) |

### Nginx

| 高频题 | 跳转 |
| --- | --- |
| Nginx 为什么这么快？ | [Nginx](./Nginx.md) |
| Master + Worker 模型职责？ | [Nginx](./Nginx.md) |
| 单 Worker 怎么扛百万并发？ | [Nginx](./Nginx.md) |
| 怎么解决惊群？ | [Nginx](./Nginx.md) |
| reload 怎么平滑重启？ | [Nginx](./Nginx.md) |
| 负载均衡算法选型？ | [Nginx](./Nginx.md) |
| 怎么做限流？ | [Nginx](./Nginx.md) |
| upstream keepalive 默认开吗？ | [Nginx](./Nginx.md) |
| 反向代理 vs 正向代理？ | [Nginx](./Nginx.md) |

### Elasticsearch

| 高频题 | 跳转 |
| --- | --- |
| ES 为什么这么快？ | [ES](./es.md) |
| 倒排索引 / Term Index / DocValues 是啥？ | [ES](./es.md) |
| ES 写入流程？ | [ES](./es.md) |
| refresh / flush / merge 区别？ | [ES](./es.md) |
| ES 是实时的吗？ | [ES](./es.md) |
| term vs match 区别？ | [ES](./es.md) |
| filter vs must 区别？ | [ES](./es.md) |
| 怎么解决深分页？ | [ES](./es.md) |
| text 字段聚合 OOM 怎么办？ | [ES](./es.md) |
| 怎么避免脑裂？ | [ES](./es.md) |

### MongoDB

| 高频题 | 跳转 |
| --- | --- |
| MongoDB 跟 MySQL 怎么选？ | [MongoDB](./MongoDB.md) |
| WiredTiger 跟 InnoDB 啥关系？ | [MongoDB](./MongoDB.md) |
| 副本集选举怎么发起？多久不可写？ | [MongoDB](./MongoDB.md) |
| Oplog 是啥？大小怎么定？ | [MongoDB](./MongoDB.md) |
| Write Concern majority 保证啥？ | [MongoDB](./MongoDB.md) |
| 分片片键怎么选？选错怎么办？ | [MongoDB](./MongoDB.md) |
| 复合索引 ESR 法则？ | [MongoDB](./MongoDB.md) |
| 4.0 单分片 vs 4.2 跨分片事务？ | [MongoDB](./MongoDB.md) |
| `$lookup` 能像 SQL JOIN 用吗？ | [MongoDB](./MongoDB.md) |
| MongoDB + ES 怎么分工？ | [MongoDB](./MongoDB.md) |

### XXL-JOB

| 高频题 | 跳转 |
| --- | --- |
| xxl-job 跟 Quartz 啥区别？ | [XXL-JOB](./xxl-job.md) |
| 调度中心多实例怎么不重复调度？ | [XXL-JOB](./xxl-job.md) |
| 9 种路由策略怎么选？ | [XXL-JOB](./xxl-job.md) |
| 分片广播怎么实现？vs MQ 分片消费？ | [XXL-JOB](./xxl-job.md) |
| 阻塞策略 SERIAL/DISCARD/COVER？ | [XXL-JOB](./xxl-job.md) |
| 任务超时怎么 kill？ | [XXL-JOB](./xxl-job.md) |
| 调度日志爆库怎么办？ | [XXL-JOB](./xxl-job.md) |
| 订单 30 分钟未付款关闭，扫表 vs MQ 延迟消息？ | [XXL-JOB](./xxl-job.md) |
| xxl-job vs DolphinScheduler 怎么选？ | [XXL-JOB](./xxl-job.md) |

---

## 三、依赖关系图

```
              [Network 模块]                ← 前置：协议、IO 模型、零拷贝
              TCP / HTTP / epoll
              IO 模型 / 零拷贝
                      │
                      │ 提供基础设施
                      ▼
              ┌───────┴───────┐
              ▼               ▼
          [Netty]          [Nginx]
        主从 Reactor     Master-Worker
        ByteBuf+Pipeline   epoll 异步
              │               │
              ├──────┬────────┼─────────┐
              ▼      ▼        ▼         ▼
         [RPC原理]  [ES]   [MongoDB]  (Web 入口)
         序列化+协议 Lucene  WiredTiger
              │              + 副本集 + 分片
              ▼
          [Dubbo]                 [XXL-JOB]
          SPI + Cluster           Admin + Executor
          Triple 协议             DB 行锁调度
                                  ↑
                                  └ 依赖 MySQL 行锁
                                    （见 MySQL 模块）
```

**核心传导**：

- **Java 中间件的网络底盘**：几乎都是 Netty（Dubbo / RocketMQ / ES Transport / Spring Cloud Gateway）。
- **流量入口**：Nginx 是 Web 网关事实标准，应用层网关用 Spring Cloud Gateway（[Microservice 模块](../Microservice/README.md)）。
- **微服务调用**：HTTP RPC（Feign / Spring Cloud）vs 二进制 RPC（Dubbo）—— 选型见 [RPC 原理](./RPC原理.md)。
- **存储分工**：MySQL（强事务 OLTP）/ MongoDB（半结构化 + 弹性 schema）/ ES（检索分析）/ Redis（缓存）—— 典型架构 MySQL+MongoDB 主存，CDC 同步到 ES 检索，Redis 顶热。
- **调度 vs 事件驱动**：周期定时（凌晨对账、批处理）用 xxl-job；事件触发（订单超时关闭）用 MQ 延迟消息别用 xxl-job 扫表。

---

## 四、跨模块联动

| 主题 | Middleware（中间件） | 网络/IO 基础 | 应用 / 实现 |
| --- | --- | --- | --- |
| Netty 线程模型 | [Netty](./Netty.md) | [Network/网络IO模型](../Network/网络IO模型.md) | [MQ/RocketMQ 架构](../MQ/RocketMQ架构.md)（Remoting）<br>[Microservice/SpringCloudGateway](../Microservice/SpringCloudGateway.md)（基于 Reactor Netty） |
| 零拷贝 | — | [Network/零拷贝](../Network/零拷贝.md) | [MQ/存储机制](../MQ/存储机制.md)（CommitLog mmap+sendfile） |
| epoll 多路复用 | [Nginx](./Nginx.md) | [Network/多路复用](../Network/多路复用.md) | [Redis/工作流程](../Redis/工作流程.md)（单线程+epoll） |
| RPC 框架 | [RPC 原理](./RPC原理.md) / [Dubbo](./dubbo.md) | [Network/TCP](../Network/TCP协议.md) | [Microservice/Feign](../Microservice/Feign.md)（HTTP RPC）<br>[Microservice 模块](../Microservice/README.md)（注册发现+治理） |
| 序列化 | [RPC 原理](./RPC原理.md) | — | [MQ/重复消费与幂等](../MQ/重复消费与幂等.md)（消息序列化） |
| 集群一致性 | [Elasticsearch](./es.md) / [MongoDB](./MongoDB.md) | — | [Distributed/一致性算法](../Distributed/一致性算法.md)（Raft / PV1） |
| 一致性哈希 | [Dubbo LoadBalance](./dubbo.md) / [XXL-JOB](./xxl-job.md) | — | [Distributed/一致性哈希](../Distributed/一致性哈希.md) |
| B+ Tree 存储引擎 | [MongoDB WiredTiger](./MongoDB.md) | — | [MySQL/InnDB](../MySQL/InnDB.md)（InnoDB 对照） |
| 分库分表 / 分片 | [MongoDB 分片集群](./MongoDB.md) | — | [MySQL/分库分表](../MySQL/分库分表.md)（关系库分片对照） |
| 分布式调度 | [XXL-JOB](./xxl-job.md) | — | [Distributed/分布式锁](../Distributed/分布式锁.md)（DB 锁 vs Redis/ZK 锁）<br>[MQ/延迟消息](../MQ/延迟消息.md)（事件触发 vs 周期扫表选型） |

---

## 五、推荐学习路径

### 新手路径（按依赖顺序）

```
0. 先看 Network 模块                     ← 必修：TCP/HTTP/IO 模型/epoll/零拷贝
1. Netty                                ← Java 网络框架天花板
2. Nginx                                ← Web 入口 / 网关基础
3. RPC 原理                             ← 远程调用通用原理
4. Dubbo                                ← Java RPC 工业实现
5. Elasticsearch                        ← 搜索引擎专题
6. MongoDB                              ← NoSQL 文档库（建议先看 MySQL/InnDB 做对照）
7. XXL-JOB                              ← 分布式任务调度（先看 MySQL/锁机制 + Distributed/分布式锁）
   ↓ 进入应用层
8. Microservice/Feign + SpringCloudGateway  ← 微服务侧 RPC + 网关
```

### 面试速通路径（30 分钟刷答题模板）

每篇都已配 **答题模板（60 秒话术）**——直接复述就是 senior 级回答：

- [Netty - 答题模板](./Netty.md)
- [Nginx - 答题模板](./Nginx.md)
- [RPC 原理 - 答题模板](./RPC原理.md)
- [Dubbo - 答题模板](./dubbo.md)
- [Elasticsearch - 答题模板](./es.md)
- [MongoDB - 答题模板](./MongoDB.md)
- [XXL-JOB - 答题模板](./xxl-job.md)

---

## 六、关键速记表

### 序列化对比

| 序列化 | 大小 | 速度 | 跨语言 | 字段兼容 | 备注 |
| --- | --- | --- | --- | --- | --- |
| JSON | ★ | ★★ | ✅ | 强 | HTTP 默认、可读性好 |
| Hessian2 | ★★★ | ★★★ | ✅（弱） | 中 | Dubbo 默认 |
| Kryo | ★★★★ | ★★★★ | ❌ | 弱 | Spark 用 |
| **Protobuf** ⭐ | **★★★★★** | ★★★★ | ✅ | **强** | gRPC 标配 |
| FlatBuffers | ★★★★★ | ★★★★★ | ✅ | 强 | 零拷贝反序列化 |

### Dubbo 集群容错

| 策略 | 行为 | 适用 |
| --- | --- | --- |
| **Failover**（默认） | 失败重试其他节点 | **读** + 幂等 |
| **Failfast** | 失败立即抛异常 | **写**（避免重复扣款） |
| Failsafe | 异常吞掉 | 日志类 |
| Failback | 异步重试 | 通知类 |
| Forking | 并行多节点取最快 | 读 + 强一致 |
| Broadcast | 广播全部 | 配置同步 |

### Dubbo 负载均衡

| 算法 | 说明 |
| --- | --- |
| Random（默认） | 加权随机 |
| RoundRobin | 加权轮询 |
| **LeastActive** ⭐ | 最少活跃数，自动避开慢节点 |
| ConsistentHash | 一致性哈希，用户粘性 |
| ShortestResponse | 最短响应时间，更激进避慢 |

### ES 查询子句

| 子句 | 评分 | 缓存 | 用途 |
| --- | --- | --- | --- |
| **must** | ✅ | ❌ | 全文匹配 |
| must_not | — | ❌ | 排除 |
| **filter** ⭐ | ❌ | **✅** | **不需评分必用**（status / range） |
| should | ✅ | ❌ | OR / 加分 |
| **term** | — | — | **不分词**精确匹配（keyword） |
| **match** | ✅ | ❌ | **分词**全文搜索（text） |

---

## 七、生产踩坑 TOP 12（跨文档汇总）

1. **Netty 内存泄漏**：ByteBuf 没 release → 堆外内存爆。开 PARANOID 检测，用 SimpleChannelInboundHandler 自动 release。→ [Netty](./Netty.md)
2. **业务阻塞 EventLoop**：DB/RPC 直接在 Handler 调 → IO 线程卡死全员超时。必派发独立线程池。→ [Netty](./Netty.md)
3. **Dubbo retries 用在写接口**：Failover 重试 3 次 → 重复扣款。写接口必 `cluster=failfast` + 幂等。→ [Dubbo](./dubbo.md)
4. **Dubbo 优雅下线丢请求**：发版必先反注册再等 30s。→ [Dubbo](./dubbo.md)
5. **超时设置错误雪崩**：下游超时 ≥ 上游 → 上游已超时下游还在跑，连接池打满。→ [Dubbo](./dubbo.md) / [RPC 原理](./RPC原理.md)
6. **ES 深分页 OOM**：from + size 上限 10000，用 search_after / PIT。→ [ES](./es.md)
7. **ES fielddata 爆 Heap**：text 字段聚合 → 用 keyword + DocValues。→ [ES](./es.md)
8. **ES mapping 爆炸**：dynamic: true + 动态字段 → Cluster State 巨大、Master 卡死。`dynamic: strict` + `total_fields.limit`。→ [ES](./es.md)
9. **MongoDB 片键选错**：单调递增 ID 当片键 = 写热点，4.4 前重建集群代价巨大。→ [MongoDB](./MongoDB.md)
10. **MongoDB Oplog 太小 Secondary 追不回来**：失联超 oplog 窗口 → 永远 RECOVERING。生产保 24~72h。→ [MongoDB](./MongoDB.md)
11. **xxl-job 调度日志爆库**：默认保留 30 天，海量任务一周撑爆 MySQL。`logretentiondays:7` + 独立 DB。→ [XXL-JOB](./xxl-job.md)
12. **xxl-job 任务超时 kill 不掉**：业务代码必须响应 `Thread.interrupt()`，否则 kill 命令无效。→ [XXL-JOB](./xxl-job.md)

---

## 八、相关模块

- [Network 模块](../Network/README.md) — TCP / HTTP / IO 模型 / 多路复用 / 零拷贝 / WebSocket（**前置必修**）
- [Microservice 模块](../Microservice/README.md) — Spring Cloud Feign / Gateway 是另一套 HTTP RPC + 网关方案
- [Distributed 模块](../Distributed/README.md) — Raft / Gossip / 一致性哈希 / 分布式锁（ES / MongoDB / Dubbo / xxl-job 实现层引用）
- [MQ 模块](../MQ/README.md) — RocketMQ Remoting 基于 Netty；延迟消息是 xxl-job 周期扫表的更优替代方案
- [Redis 模块](../Redis/README.md) — Redis 单 Reactor + epoll 极致案例；MongoDB + Redis 缓存常见双写一致性方案
- [MySQL 模块](../MySQL/README.md) — InnoDB B+ Tree 与 MongoDB WiredTiger 对照；行锁原理是 xxl-job 调度协调的根基
- [JVM 模块](../JVM/README.md) — 堆外内存（Netty Direct Buffer）/ GC / 调优
- [Concurrency 模块](../Concurrency/README.md) — 线程模型 / FastThreadLocal / 任务线程池（xxl-job Executor 基础）
