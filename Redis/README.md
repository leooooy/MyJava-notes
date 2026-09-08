# Redis 面试模块

> 大厂后端面试的"必考四大件"之一（Redis / MySQL / JVM / 并发）。
> 本模块按 **数据结构 → 内部机制 → 复制与集群 → 应用场景 → 性能与运维** 五层组织，每篇都按 senior 标准写：原理 + 取舍 + 面试追问 + 生产踩坑 + 答题模板。

---

## 一、模块导航

### 数据结构（6 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [Redis 数据结构总览](./数据结构总览.md) | 全景图、版本演进、底层结构对照、选型决策树 |
| [字符串 String](./字符串-String.md) | int/embstr/raw 编码、SDS、Bitmap |
| [哈希 Hash](./哈希-Hash.md) | listpack/hashtable、渐进式 rehash |
| [列表 List](./列表-List.md) | quicklist 演进、ziplist→listpack、连锁更新 |
| [集合 Set](./集合-Set.md) | intset/listpack/hashtable 三态、集合运算 |
| [有序集合 ZSet](./有序集合-ZSet.md) | 跳表原理、dict+skiplist 双结构、为什么不用红黑树 |

### 内部机制（6 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [Redis 工作流程](./工作流程.md) | 单线程 + IO 多路复用、epoll、6.0 多线程边界 |
| [Redis 持久化](./持久化.md) | RDB/AOF/混合持久化、fork+COW、AOF 重写 |
| [Redis 过期策略与内存淘汰](./过期策略.md) | 惰性+定期过期、LRU/LFU 内存淘汰、近似 LRU |
| [Redis 事务](./事务.md) | MULTI/EXEC/WATCH、为什么不支持回滚 |
| [管道与批量优化](./管道与批量优化.md) | RTT 优化、Pipeline vs MULTI vs Lua |
| [Lua 脚本](./Lua%20脚本.md) | 原子性 + 复杂逻辑、EVALSHA、Cluster 限制 |

### 复制与集群部署（2 篇）

> **层次关系**：主从复制是"协议层"（数据怎么从主流到从），集群部署是"拓扑层"（多实例怎么组织）。
> 哨兵 / Cluster 都构建在主从复制之上——先读主从，再读集群，才能讲清"为什么 Cluster 故障转移时未同步数据会丢失"这种深度题。
>
> ```
> [Redis 主从一致性]   ← 协议层（基础，被下层复用）
>          ↓
> [Redis 集群部署]
>   ├─ 单机
>   ├─ 主从复制         ← 直接用主从一致性
>   ├─ 哨兵             ← 主从 + 自动故障转移
>   └─ Cluster          ← 主从 + 分片 + Gossip
> ```

| 文档 | 层次 | 一句话定位 |
| --- | --- | --- |
| [Redis 主从一致性](./主从一致性.md) | 协议层（基础） | PSYNC 协议、全量 vs 增量、repl_backlog、异步复制延迟 |
| [Redis 集群部署](./集群部署.md) | 拓扑层（演进） | 单机→主从→哨兵→Cluster、Gossip、MOVED/ASK、脑裂 |

### 应用场景（6 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [缓存雪崩、击穿、穿透](./缓存雪崩，击穿，穿透.md) | 三大缓存问题对比、综合防护体系 |
| [布隆过滤器](./布隆过滤器.md) | 位数组 + 多哈希、误判率公式、4 种实现 |
| [缓存与数据库双写一致性](./双写一致性.md) | Cache Aside 模式、Binlog+Canal 异步删除 |
| [Redis 分布式锁](./分布式锁.md) | SETNX → Redisson 演进、看门狗、Redlock 之争 |
| [Redis 消息队列方案](./消息队列方案.md) | List / Pub-Sub / Stream 三方对比 |
| [秒杀场景 - Redis 故障应对](./秒杀场景-Redis故障应对.md) | 预防/降级/恢复三层、本地缓存兜底 |

### 性能与运维（2 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [大 key 与热 key 治理](./大key与热key治理.md) | 识别、危害、UNLINK、本地缓存、多副本 key |
| [Java Redis 客户端选型](./客户端选型.md) | Jedis / Lettuce / Redisson 架构与取舍 |

---

## 二、面试高频题 → 文档映射

被问到这些题，直接跳到对应文档：

| 高频题 | 跳转 |
| --- | --- |
| Redis 单线程为什么这么快？ | [Redis 工作流程](./工作流程.md) |
| Redis 6.0 多线程改了什么？ | [Redis 工作流程](./工作流程.md#五redis-60-多线程) |
| Redis 有几种数据结构？底层呢？ | [Redis 数据结构总览](./数据结构总览.md) |
| 跳表 vs 红黑树？为什么 Redis 选跳表？ | [有序集合 ZSet](./有序集合-ZSet.md#六为什么用跳表而不是红黑树) |
| ZSet 怎么实现 O(log N) 查排名？ | [有序集合 ZSet](./有序集合-ZSet.md#55-排名rank怎么算) |
| ziplist 的连锁更新是什么？ | [列表 List](./列表-List.md#32-ziplist-的连锁更新致命缺陷) |
| 7.0 用 listpack 替代 ziplist 解决什么？ | [列表 List](./列表-List.md#34-listpack70-终极方案) |
| 渐进式 rehash 原理？ | [哈希 Hash](./哈希-Hash.md#五渐进式-rehash核心面试点) |
| RDB 和 AOF 怎么选？ | [Redis 持久化](./持久化.md) |
| fork 阻塞主线程吗？COW 怎么工作？ | [Redis 持久化](./持久化.md#23-bgsave-的核心机制fork--cow) |
| 过期策略和内存淘汰是一回事吗？ | [Redis 过期策略与内存淘汰](./过期策略.md#一先分清两个独立机制) |
| LRU 和 LFU 怎么选？ | [Redis 过期策略与内存淘汰](./过期策略.md#32-关键算法详解) |
| Redis 事务能回滚吗？ | [Redis 事务](./事务.md#三为什么-redis-不支持回滚) |
| Pipeline 和 MULTI/EXEC 区别？ | [管道与批量优化](./管道与批量优化.md#四pipeline-vs-multiexec高频对比题) |
| Lua 脚本怎么保证原子性？ | [Lua 脚本](./Lua%20脚本.md#二lua-脚本核心特性) |
| Redis 主从是同步还是异步？ | [Redis 主从一致性](./主从一致性.md#一为什么要主从) |
| 全量同步 vs 增量同步触发条件？ | [Redis 主从一致性](./主从一致性.md#32-全量同步-vs-增量同步的判断逻辑) |
| 主从延迟读到旧数据怎么办？ | [Redis 主从一致性](./主从一致性.md#52-写后立即读问题) |
| 哨兵的 SDOWN 和 ODOWN 区别？ | [Redis 集群部署](./集群部署.md#34-主观下线-vs-客观下线必考) |
| Cluster 为什么是 16384 个 slot？ | [Redis 集群部署](./集群部署.md#43-哈希槽slot) |
| MOVED 和 ASK 重定向区别？ | [Redis 集群部署](./集群部署.md#44-客户端路由智能客户端) |
| 缓存穿透/击穿/雪崩区别？ | [缓存雪崩、击穿、穿透](./缓存雪崩，击穿，穿透.md#一三者本质区别先记牢这张表) |
| 布隆过滤器原理？ | [布隆过滤器](./布隆过滤器.md) |
| 缓存和数据库怎么保证一致？ | [缓存与数据库双写一致性](./双写一致性.md) |
| 分布式锁怎么实现？看门狗呢？ | [Redis 分布式锁](./分布式锁.md) |
| Redlock 为啥有争议？ | [Redis 分布式锁](./分布式锁.md#四redlock跨实例的强一致方案) |
| Redis 怎么做消息队列？ | [Redis 消息队列方案](./消息队列方案.md) |
| Pub/Sub 为什么不能当 MQ？ | [Redis 消息队列方案](./消息队列方案.md#三方式-2pubsub发布订阅) |
| Stream 的消费者组和 PEL？ | [Redis 消息队列方案](./消息队列方案.md#43-消费者组模型) |
| 秒杀系统 Redis 挂了怎么办？ | [秒杀场景 - Redis 故障应对](./秒杀场景-Redis故障应对.md) |
| 大 key / 热 key 怎么发现治理？ | [大 key 与热 key 治理](./大key与热key治理.md) |
| DEL 和 UNLINK 区别？ | [大 key 与热 key 治理](./大key与热key治理.md#25-怎么治理大-key) |
| Jedis / Lettuce / Redisson 怎么选？ | [Java Redis 客户端选型](./客户端选型.md) |

---

## 三、推荐学习路径

### 新手路径（按依赖顺序）

```
1.  Redis 数据结构总览                       ← 先建立全局视图
2.  字符串 String                            ← 最常用，最简单
3.  哈希 Hash / 列表 List                    ← 任选其一深入
4.  集合 Set / 有序集合 ZSet                 ← 跳表是大头
5.  Redis 工作流程                           ← 单线程模型
6.  Redis 持久化                             ← RDB/AOF 必考
7.  Redis 过期策略与内存淘汰                 ← 内存淘汰
8.  Redis 事务 / 管道 / Lua 脚本             ← 原子性三件套（重点 Lua）
9.  Redis 主从一致性 → Redis 集群部署        ← 协议层 → 拓扑层
10. 缓存雪崩、击穿、穿透                     ← 应用基础
11. 缓存与数据库双写一致性 / Redis 分布式锁  ← 实战
12. Redis 消息队列方案                       ← Stream 是首选
13. 布隆过滤器 / 秒杀场景-Redis故障应对      ← 加分项
14. 大 key 与热 key 治理 / 客户端选型        ← 性能与运维（生产经验）
```

### 面试速通路径（30 分钟刷一遍）

每篇都已配 **答题模板（60 秒话术）**——直接复述就是 senior 级回答：

**数据结构（6）**
- [Redis 数据结构总览](./数据结构总览.md#十答题模板60-秒话术)
- [字符串 String](./字符串-String.md#八答题模板60-秒话术)
- [哈希 Hash](./哈希-Hash.md#九答题模板60-秒话术)
- [列表 List](./列表-List.md#八答题模板60-秒话术)
- [集合 Set](./集合-Set.md#九答题模板60-秒话术)
- [有序集合 ZSet](./有序集合-ZSet.md#十一答题模板60-秒话术)

**内部机制（6）**
- [Redis 工作流程](./工作流程.md#九答题模板60-秒话术)
- [Redis 持久化](./持久化.md#九答题模板60-秒话术)
- [Redis 过期策略与内存淘汰](./过期策略.md#七答题模板60-秒话术)
- [Redis 事务](./事务.md#九答题模板60-秒话术)
- [管道与批量优化](./管道与批量优化.md#十答题模板60-秒话术)
- [Lua 脚本](./Lua%20脚本.md#十二答题模板60-秒话术)

**复制与集群（2）**
- [Redis 主从一致性](./主从一致性.md#十一答题模板60-秒话术)
- [Redis 集群部署](./集群部署.md#十一答题模板60-秒话术)

**应用场景（6）**
- [缓存雪崩、击穿、穿透](./缓存雪崩，击穿，穿透.md#九答题模板60-秒话术)
- [布隆过滤器](./布隆过滤器.md#七答题模板60-秒话术)
- [缓存与数据库双写一致性](./双写一致性.md#七答题模板60-秒话术)
- [Redis 分布式锁](./分布式锁.md#八答题模板60-秒话术)
- [Redis 消息队列方案](./消息队列方案.md#九答题模板60-秒话术)
- [秒杀场景 - Redis 故障应对](./秒杀场景-Redis故障应对.md#九答题模板60-秒话术)

**性能与运维（2）**
- [大 key 与热 key 治理](./大key与热key治理.md#八答题模板60-秒话术)
- [Java Redis 客户端选型](./客户端选型.md#十答题模板60-秒话术)

---

## 四、应用场景速查表

被问"项目里 Redis 怎么用的"，按场景找用法：

| 业务需求 | 推荐数据类型 | 详见 |
| --- | --- | --- |
| 简单 KV 缓存 | String | [字符串 String](./字符串-String.md#二常用命令速查) |
| 计数器（点赞/阅读） | String + INCR | [字符串 String](./字符串-String.md#53-计数器点赞阅读量) |
| 全局唯一 ID | String + INCRBY | [字符串 String](./字符串-String.md#54-全局-id-生成) |
| 分布式锁 | String + SET NX EX | [Redis 分布式锁](./分布式锁.md) |
| 限流 | String / ZSet 滑动窗口 | [字符串 String](./字符串-String.md#q9怎么用-string-做限流) / [有序集合 ZSet](./有序集合-ZSet.md#83-滑动窗口限流) |
| 对象缓存 | Hash | [哈希 Hash](./哈希-Hash.md#61-对象缓存替代-json) |
| 购物车 | Hash | [哈希 Hash](./哈希-Hash.md#62-购物车) |
| 时间线 / 朋友圈 | List + LTRIM | [列表 List](./列表-List.md#43-时间线最新-n-条) |
| 简单消息队列 | List + BRPOP | [列表 List](./列表-List.md#41-简单消息队列生产慎用建议用-stream) |
| 完整 MQ | Stream（5.0+） | [列表 List - List vs Stream](./列表-List.md#六list-vs-stream面试常问) |
| 抽奖 | Set + SPOP | [集合 Set](./集合-Set.md#51-抽奖不重复中奖) |
| 点赞 / 收藏 | Set | [集合 Set](./集合-Set.md#52-点赞--收藏) |
| 共同关注 | Set + SINTER | [集合 Set](./集合-Set.md#53-共同关注社交) |
| 标签系统 | Set + Hash | [集合 Set](./集合-Set.md#54-标签系统) |
| 排行榜 | ZSet | [有序集合 ZSet](./有序集合-ZSet.md#81-排行榜最经典) |
| 延时队列 | ZSet（score=时间戳） | [有序集合 ZSet](./有序集合-ZSet.md#82-延时队列) |
| 优先级队列 | ZSet + ZPOPMIN | [有序集合 ZSet](./有序集合-ZSet.md#84-优先级队列) |
| 签到 / 活跃统计 | Bitmap | [字符串 String](./字符串-String.md#55-bitmap日活签到) |
| 海量 UV 去重计数 | HyperLogLog | [Redis 数据结构总览](./数据结构总览.md#二5-种高级数据类型) |
| 附近的人 | Geo（底层 ZSet） | [Redis 数据结构总览](./数据结构总览.md#二5-种高级数据类型) |
| 黑名单 / 白名单 | Set / 布隆过滤器 | [布隆过滤器](./布隆过滤器.md) |
| 防缓存穿透 | 布隆过滤器 + 空值缓存 | [缓存雪崩、击穿、穿透 - 缓存穿透](./缓存雪崩，击穿，穿透.md#二缓存穿透cache-penetration) |
| 幂等校验 | String + SETNX | [字符串 String](./字符串-String.md) / [幂等](../Distributed/幂等.md) |

---

## 五、选型决策树

### 部署形态选型

```
单机能扛？            ─→ 单 Redis（不推荐生产）
                         │
读写分离 + 数据冗余？ ─→ 主从复制
                         │
要自动故障转移？      ─→ 哨兵（容量仍单机）
                         │
要写扩展 / 大容量？   ─→ Cluster（16384 slot）
                         │
要金融级容灾？        ─→ 多机房双活 / 异地多活
```

### 缓存策略选型

```
能容忍数据短暂不一致？
├─ 是 → Cache Aside（先更 DB 再删 Cache）+ Binlog 异步兜底
└─ 否 → 分布式锁 + 双写（性能差）/ 不用缓存
```

### 防雪崩防护层

```
层 1: 网关限流 + 风控
层 2: 布隆过滤器（防穿透）
层 3: 本地缓存 Caffeine（防 Redis 整挂）
层 4: Redis 集群（高可用 + 多副本 key 防热点）
层 5: 熔断 + 限流 + 降级（保 DB）
```

→ 详见 [缓存雪崩、击穿、穿透 - 综合防护体系](./缓存雪崩，击穿，穿透.md#五综合防护体系生产环境必备)

---

## 六、关键速记表

### Redis 版本演进

| 版本 | 关键特性 |
| --- | --- |
| 2.8 | PSYNC 部分重同步 |
| 3.0 | Cluster 集群发布 |
| 3.2 | List 改 quicklist；Geo |
| 4.0 | 模块系统、混合持久化、LFU、UNLINK |
| 5.0 | **Stream** 类型 |
| 6.0 | **多线程网络 IO**、ACL、客户端缓存 |
| 6.2 | 命令大量增强 |
| 7.0 | **listpack 替代 ziplist**、Functions、多 AOF |
| 7.2 | Set 也支持 listpack |

### 底层编码切换条件

| 类型 | 小集合（紧凑） | 大集合 |
| --- | --- | --- |
| String | int / embstr（≤44B） | raw |
| Hash | listpack / ziplist（≤128 字段且 ≤64B） | hashtable |
| List | quicklist 节点 ≤8KB | quicklist |
| Set（全数字） | intset（≤512） | hashtable |
| Set（非数字，7.2+） | listpack | hashtable |
| ZSet | listpack / ziplist（≤128 元素且 ≤64B） | skiplist + dict |

### 命令复杂度速查

| 命令 | 复杂度 | 备注 |
| --- | --- | --- |
| GET / SET | O(1) | |
| HGET / HSET | O(1) | |
| LPUSH / RPUSH | O(1) | |
| SADD / SISMEMBER | O(1) | hashtable 时 |
| ZADD | O(log N) | |
| ZRANGE / ZRANGEBYSCORE | O(log N + M) | M = 返回元素数 |
| ZRANK | O(log N) | 通过 span 字段 |
| KEYS * | O(N) | **生产严禁** |
| HGETALL | O(N) | 大 Hash 慎用 |
| SMEMBERS | O(N) | 大 Set 慎用 |
| LRANGE 0 -1 | O(N) | 大 List 慎用 |

### 生产配置建议

```ini
# 持久化
save 900 1
save 300 10
appendonly yes
appendfsync everysec
aof-use-rdb-preamble yes

# 内存淘汰
maxmemory 4gb
maxmemory-policy allkeys-lru
maxmemory-samples 5

# 主从 / 复制
repl-backlog-size 100mb       # 默认 1MB 太小
min-slaves-to-write 1
min-slaves-max-lag 10

# Cluster
cluster-node-timeout 5000
cluster-require-full-coverage no

# 慢日志
slowlog-log-slower-than 10000  # 10ms

# 客户端
timeout 0                      # 永久连接
tcp-keepalive 300
```

### 危险命令黑名单

```bash
# 生产严禁或重命名
KEYS *                # O(N) 卡主线程
FLUSHALL / FLUSHDB    # 清空所有数据
CONFIG SET            # 在线改配置
DEBUG                 # 调试命令
SHUTDOWN              # 关机

# 推荐重命名
rename-command KEYS ""
rename-command FLUSHALL ""
```

---

## 七、Redis vs Memcached 速查

经典对比题。两者都是开源内存 KV 缓存：

| 维度 | Redis | Memcached |
| --- | --- | --- |
| **数据类型** | 5 基础 + 5 高级 | 仅 string |
| **持久化** | RDB / AOF | 无 |
| **集群** | Cluster 原生 | 客户端分片 |
| **主从复制** | 原生支持 | 需中间件 |
| **多线程** | 6.0+ 网络 IO | 全多线程 |
| **内存管理** | 自带碎片整理 | slab 分配 |
| **复杂数据** | 跳表 / Bitmap / Geo | 不支持 |
| **场景** | 缓存 + 存储 + MQ + 排序... | 纯简单缓存 |

→ 现在做缓存几乎一律选 Redis，Memcached 只在极简场景或老系统里出现。

---

## 八、相关模块

- [幂等](../Distributed/幂等.md) — 配合分布式锁使用
- [分布式事务](../Distributed/分布式事务.md) — 双写一致性的扩展
- [限流算法](../Microservice/限流算法.md) — Redis 滑动窗口/令牌桶实现
- [一致性哈希](../Distributed/一致性哈希.md) — Cluster 哈希槽对比
- 项目中是如何处理高并发的 — 抽奖/秒杀实战

---

## 九、面试常被一连串追问的话题

按出现频率列出：

1. **跳表**：原理 → P=0.25 → 期望层数 → vs 红黑树 → 排名怎么算
2. **持久化**：RDB / AOF → fork → COW → 混合持久化
3. **分布式锁**：SETNX → 误删 → UUID+Lua → Redisson → 看门狗 → Redlock
4. **缓存一致性**：Cache Aside → 删除失败 → MQ 重试 → Binlog+Canal
5. **缓存三大问题**：穿透 → 布隆过滤器 → 击穿 → 互斥锁/逻辑过期 → 雪崩 → 多级缓存
6. **集群**：主从 → 哨兵 → Cluster → 16384 slot → Gossip → MOVED/ASK
7. **过期策略**：惰性 + 定期 → 抽样 → 内存淘汰 → LRU/LFU → 近似 LRU
8. **单线程**：为什么快 → epoll → 6.0 多线程 → 慢命令
9. **原子操作**：MULTI/EXEC（不回滚）→ Pipeline（不原子）→ Lua（最强）→ Cluster 限制
10. **消息队列**：List → Pub/Sub（不可靠）→ Stream（消费者组 + PEL + ACK）→ vs Kafka
11. **大 key / 热 key**：识别 → 危害 → 治理（拆分/UNLINK/本地缓存/多副本）
12. **客户端选型**：Jedis 同步 → Lettuce 异步 → Redisson 工具集

每条主线都对应至少一篇深度文档，按上方"高频题映射"快速跳转。
