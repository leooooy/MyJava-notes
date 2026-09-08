# Patterns 跨模块同构设计

> 大厂面试最爱问的一句是："你还见过哪些类似的设计？"
> 本模块专门收**跨模块的同构设计模式**——比如长轮询既出现在 Nacos Config 又出现在 RocketMQ Pull，两阶段提交既出现在 MySQL redo+binlog 又出现在 RocketMQ 事务消息。
>
> 单独学每个模块时这些设计是"零散的实现细节"，集中横向看才是"通用的工程范式"。面试时能说出"这本质上是 XX 模式，在 A 系统里是 ……，在 B 系统里是 ……，差别在 ……" — 立刻拉开和初/中级的差距。

---

## 一、为什么单独建一个模块

每个模块的笔记按"系统视角"组织——MySQL 的 redo log 写在 `MySQL/日志.md`，RocketMQ 的事务消息写在 `MQ/事务消息.md`。但**这些设计的"骨架"是共通的**，分散在各模块意味着：

- 复习一遍 RocketMQ → 只看到 RocketMQ 的长轮询；复习 Nacos → 又看到 Nacos 的长轮询；没人帮你把两者拼到一起。
- 面试官追问"你还在哪见过这种设计"时大脑卡壳——明明都学过，但没建立横向连接。
- 同一个 trade-off（hold 时长怎么选、谁释放、惊群怎么处理）在多个文章里都讲一遍，浪费精力。

本模块的写法是：**只讲共性骨架 + 差异点对比表 + 面试横向追问**，具体实现细节链回原模块，不复制粘贴。

---

## 二、模块导航

### 通信与协调范式

| 文档 | 状态 | 横跨的系统 |
| --- | --- | --- |
| [长轮询 Long Polling](./长轮询.md) | ✅ 已完成 | Nacos Config / RocketMQ Pull / Apollo / Kafka poll |
| [心跳与租约（Heartbeat & Lease）](./心跳与租约.md) | ✅ 已完成 | ZK session / Nacos 临时实例 / Redisson 看门狗 / Raft 心跳 / K8s 探针 / 连接池保活 |
| [反应式 I/O（Reactor / 单线程事件循环）](./反应式IO.md) | ✅ 已完成 | Redis / Netty / Nginx / Node.js |

### 数据持久与可靠范式

| 文档 | 状态 | 横跨的系统 |
| --- | --- | --- |
| [WAL 预写日志](./WAL预写日志.md) | ✅ 已完成 | MySQL redo / Redis AOF / RocketMQ CommitLog / Raft Log / ZK txn log |
| [两阶段提交与事务消息](./两阶段提交.md) | ✅ 已完成 | MySQL redo+binlog 内部 XA / 跨实例 XA / RocketMQ 事务消息 / TCC / Seata AT |
| [主从复制范式](./主从复制范式.md) | ✅ 已完成 | MySQL binlog / Redis PSYNC / Kafka ISR / RocketMQ HA / Raft & ZAB |

### 并发与一致性范式

| 文档 | 状态 | 横跨的系统 |
| --- | --- | --- |
| [版本号与 CAS（乐观并发控制）](./版本号与CAS.md) | ✅ 已完成 | Java CAS / MySQL MVCC / 业务乐观锁 / HTTP ETag / Raft term / Nacos MD5 |
| [一致性哈希的应用](./一致性哈希应用.md) | ✅ 已完成 | Memcached / Dubbo LB / Nginx hash / CDN / Redis Cluster slot |
| [限流范式：计数器 / 滑动窗口 / 漏桶 / 令牌桶](./限流范式.md) | ✅ 已完成 | Sentinel / Guava RateLimiter / Nginx / Redis Lua |
| [幂等与重试](./幂等与重试.md) | ✅ 已完成 | DB 唯一约束 / 乐观锁 / 状态机 / Token / Feign 重试 / MQ 消费去重 |

### 扩展性范式

| 文档 | 状态 | 横跨的系统 |
| --- | --- | --- |
| [分片 + 副本（Sharding + Replica）](./分片与副本.md) | ✅ 已完成 | Redis Cluster / Kafka / ES / MongoDB / MySQL 分库分表 |

---

## 三、怎么用本模块

### 场景 1：复习已学模块时，回到 Patterns 做横向连接

学完 `MQ/事务消息.md` → 翻 `Patterns/两阶段提交.md` → 同时回顾 MySQL 内部 XA、Seata。

### 场景 2：面试前一晚刷"举一反三"题

面试官最常用的延伸追问：

| 追问句式 | 翻这篇 |
| --- | --- |
| "你还在哪见过长轮询？" | [长轮询](./长轮询.md) |
| "类似 redo+binlog 的两阶段提交还有吗？" | [两阶段提交与事务消息](./两阶段提交.md) |
| "为什么这些中间件都用 WAL？" | [WAL 预写日志](./WAL预写日志.md) |
| "MySQL 半同步、Kafka ISR、Raft 多数派有什么共同点？" | [主从复制范式](./主从复制范式.md) |
| "MVCC 和乐观锁是同一个东西吗？Raft term 也算吗？" | [版本号与 CAS](./版本号与CAS.md) |
| "ZK session、Redisson 看门狗、K8s 探针的共同模式？" | [心跳与租约](./心跳与租约.md) |
| "Redis 单线程为啥这么快？Netty/Nginx 是一回事吗？" | [反应式 I/O](./反应式IO.md) |
| "Redis Cluster 用一致性哈希吗？为什么是 16384 slot？" | [一致性哈希的应用](./一致性哈希应用.md) / [分片 + 副本](./分片与副本.md) |
| "Sentinel 用滑动窗口还是令牌桶？为什么？" | [限流范式](./限流范式.md) |
| "MQ 至少一次怎么保证不重复消费？" | [幂等与重试](./幂等与重试.md) |

### 场景 3：系统设计题快速调用

被问"设计一个 XXX 系统"时，按本模块的范式套：
- 需要近实时通知 → [长轮询](./长轮询.md) / 长连接推送
- 需要保证消息或数据可靠 → [WAL](./WAL预写日志.md) + [主从复制](./主从复制范式.md)
- 跨服务事务 → [两阶段提交 / 事务消息 / TCC](./两阶段提交.md)
- 高并发读写扩展 → [分片 + 副本](./分片与副本.md) + [一致性哈希](./一致性哈希应用.md)
- 并发更新防丢失 → [版本号与 CAS](./版本号与CAS.md)（MVCC / 乐观锁）
- 接口防重 / MQ 消费 → [幂等与重试](./幂等与重试.md)
- 集群高可用故障感知 → [心跳与租约](./心跳与租约.md)
- 高并发服务器 → [反应式 I/O](./反应式IO.md)（Reactor + epoll）
- 接入层 / 应用层流量保护 → [限流](./限流范式.md)（漏桶 / 令牌桶）

---

## 四、写作约定（自用提醒）

本模块的每篇文章遵循通用规范（见根 `CLAUDE.md`），但有 3 条额外约束：

1. **不复制粘贴具体实现**——具体协议细节链回原模块（如 RocketMQ 长轮询的 hold 队列 → 链回 `MQ/消费者.md`）。本模块只负责"提炼骨架 + 横向对比"。
2. **必须有 ≥2 个系统的横向对比表**——这是本模块的存在意义。只讲一个系统就不该放这里。
3. **面试追问聚焦"为什么这些系统都选这个范式"**——而不是某个系统的内部参数细节。

---

## 五、相关模块

本模块是其它模块的横向索引层，不替代任何模块：

- [MySQL](../MySQL/README.md) — 事务/日志/MVCC 的"源头"
- [Redis](../Redis/README.md) — 单线程/AOF/Cluster 的"源头"
- [MQ](../MQ/README.md) — 长轮询/事务消息/顺序写的"源头"
- [Distributed](../Distributed/README.md) — 2PC/一致性/分布式锁的"源头"
- [Microservice](../Microservice/README.md) — Nacos 长轮询/限流/服务发现的"源头"
- [Network](../Network/README.md) — Reactor/多路复用的"源头"
