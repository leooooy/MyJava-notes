# MQ（RocketMQ）面试模块

> 大厂后端面试的核心中间件之一——业务消息场景几乎必问。
> 本模块按 **架构 → 存储/复制 → 客户端 → 高级特性 → 故障应对** 五层组织，每篇都按 senior 标准写：原理 + 取舍 + 面试追问 + 生产踩坑 + 答题模板。

---

## 一、模块导航

### 架构基础（1 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [RocketMQ 架构](./RocketMQ架构.md) | NameServer/Broker/Producer/Consumer 四角色、Topic/Queue/Tag 模型、为什么不用 ZK |

### 存储与复制（2 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [存储机制](./存储机制.md) | CommitLog / ConsumeQueue / IndexFile、mmap、PageCache、零拷贝 |
| [刷盘与复制](./刷盘与复制.md) | 同步/异步刷盘、同步/异步复制、Dledger Raft 自动主备切换 |

### 客户端（2 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [生产者](./生产者.md) | Sync/Async/Oneway、负载均衡、故障规避（MQFaultStrategy）、重试 |
| [消费者](./消费者.md) | Push 长轮询、Rebalance、消费失败 16 次重试、死信队列、offset 异步提交 |

### 可靠性（2 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [消息可靠性](./消息可靠性.md) | 端到端三阶段防丢失（生产/存储/消费）+ 业务对账兜底 |
| [重复消费与幂等](./重复消费与幂等.md) | At Least Once + 业务幂等的工程范式、5 种幂等实现取舍 |

### 高级特性（3 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [顺序消息](./顺序消息.md) | 全局 vs 部分顺序、MessageQueueSelector、消费端三把锁 |
| [事务消息](./事务消息.md) | half 消息 + 事务回查、解决业务事务与 MQ 一致性 |
| [延迟消息](./延迟消息.md) | 4.x 18 个延迟级别、5.x 时间轮任意时间延迟 |

### 故障应对（1 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [消息堆积处理](./消息堆积处理.md) | 5 分钟止血 / 1 小时消化 / 长期预防、扩 Queue+临时 Consumer 转发方案 |

### 选型对比（1 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [MQ 对比与选型](./MQ对比与选型.md) | RocketMQ / Kafka / RabbitMQ / Pulsar 五大维度横向对比、选型决策树 |

---

## 二、面试高频题 → 文档映射

被问到这些题，直接跳到对应文档：

| 高频题 | 跳转 |
| --- | --- |
| RocketMQ 架构是什么？四个角色？ | [RocketMQ 架构](./RocketMQ架构.md) |
| 为什么 RocketMQ 不用 ZooKeeper 而自己写 NameServer？ | [RocketMQ 架构 - NameServer](./RocketMQ架构.md#21-nameserver路由注册中心) |
| Topic 和 Queue 是什么关系？ | [RocketMQ 架构 - 消息模型](./RocketMQ架构.md#三消息模型topic--queue--tag) |
| RocketMQ 单机为什么能跑 10w+ TPS？ | [存储机制](./存储机制.md) |
| 为什么所有 Topic 共用一个 CommitLog？Kafka 不是反着来吗？ | [存储机制 - 为什么共用](./存储机制.md#23-关键设计为什么所有-topic-共用) |
| ConsumeQueue 和 IndexFile 区别？ | [存储机制](./存储机制.md#三consumequeue消费索引关键) |
| mmap 和 sendfile 区别？为什么 RocketMQ 用 mmap？ | [存储机制 - mmap](./存储机制.md#54-为什么-rocketmq-用-mmap不用-sendfile) |
| 同步刷盘 vs 异步刷盘的取舍？ | [刷盘与复制 - 刷盘](./刷盘与复制.md#二刷盘机制flushdisktype) |
| 同步复制 vs 异步复制？ | [刷盘与复制 - 复制](./刷盘与复制.md#三复制机制brokerrole) |
| Dledger 和 SYNC_MASTER 区别？ | [刷盘与复制 - Dledger](./刷盘与复制.md#四dledger-模式45-自动主备切换) |
| Producer 怎么选 Queue？故障规避机制？ | [生产者 - 负载均衡](./生产者.md#四负载均衡选哪个-queue) |
| 同步发送的"假同步"怎么实现的？ | [生产者 - opaque](./生产者.md#22-同步发送的假同步opaque--responsefuture) |
| Producer 重试机制？ | [生产者 - 重试](./生产者.md#五重试机制) |
| Push 模式底层是 Pull 吗？长轮询怎么实现？ | [消费者 - 长轮询](./消费者.md#二push-模式长轮询的真相) |
| Rebalance 是什么？什么时候触发？ | [消费者 - Rebalance](./消费者.md#三rebalance消费者重平衡) |
| 消费失败重试 16 次什么逻辑？ | [消费者 - 重试](./消费者.md#五消费失败重试) |
| Consumer offset 怎么管理？ | [消费者 - offset](./消费者.md#六消费-offset-管理) |
| 集群消费 vs 广播消费？ | [消费者 - 模式](./消费者.md#四消费模式集群-vs-广播) |
| 消息会丢吗？怎么保证不丢？ | [消息可靠性](./消息可靠性.md) |
| MQ 怎么保证不重复消费？（错误问法） | [重复消费与幂等](./重复消费与幂等.md) |
| 怎么实现幂等？msgId 还是业务 ID？ | [重复消费与幂等 - 幂等键](./重复消费与幂等.md#四幂等键怎么选) |
| Exactly Once 真能实现吗？ | [重复消费与幂等 - 追问 Q6](./重复消费与幂等.md#八面试高频追问) |
| 顺序消息怎么实现？三把锁是什么？ | [顺序消息 - 三把锁](./顺序消息.md#33-三把锁详解) |
| 顺序消费失败怎么处理？为什么会卡死 Queue？ | [顺序消息 - 失败处理](./顺序消息.md#四顺序消费的失败处理) |
| 全局顺序为什么没人用？ | [顺序消息 - 为什么](./顺序消息.md#12-为什么全局顺序几乎没人用) |
| 事务消息原理？half 消息怎么对消费者不可见？ | [事务消息 - half](./事务消息.md#二核心设计half-消息--事务回查) |
| 事务回查机制？什么时候触发？ | [事务消息 - 回查](./事务消息.md#23-关键阶段拆解) |
| 事务消息能强一致吗？ | [事务消息 - 局限](./事务消息.md#四为什么是最终一致而不是强一致) |
| 延迟消息原理？4.x 和 5.x 区别？ | [延迟消息](./延迟消息.md) |
| 时间轮算法是什么？ | [延迟消息 - 时间轮](./延迟消息.md#三rocketmq-5x任意时间延迟时间轮) |
| 堆积 500 万消息怎么处理？ | [消息堆积处理](./消息堆积处理.md) |
| 扩 Consumer 实例为什么要先扩 Queue？ | [消息堆积处理 - 反模式](./消息堆积处理.md#53--加-consumer-实例但-queue-数不够) |
| RocketMQ vs Kafka 选型？ | [MQ 对比与选型](./MQ对比与选型.md) |
| Kafka 的 ISR 和 RocketMQ 的 Dledger 哪个强？ | [MQ 对比与选型 - 高可用](./MQ对比与选型.md#四高可用方案) |
| RabbitMQ 是不是过时了？ | [MQ 对比与选型 - 追问 Q4](./MQ对比与选型.md#十四面试高频追问) |
| Pulsar 值得跟进吗？ | [MQ 对比与选型 - Pulsar](./MQ对比与选型.md#24-pulsar-架构) |
| 百万级 Topic 怎么选？ | [MQ 对比与选型 - 追问 Q5](./MQ对比与选型.md#十四面试高频追问) |
| Kafka 事务和 RocketMQ 事务区别？ | [MQ 对比与选型 - 事务](./MQ对比与选型.md#71-rocketmq-vs-kafka-事务的本质差异) |

---

## 三、推荐学习路径

### 新手路径（按依赖顺序）

```
1. RocketMQ 架构              ← 先建立全局视图
2. 存储机制                    ← 理解为什么这么快
3. 刷盘与复制                  ← 可靠性的两个旋钮
4. 生产者                      ← 客户端基础（一）
5. 消费者                      ← 客户端基础（二）
6. 消息可靠性                  ← 综合应用前 5 篇
7. 重复消费与幂等              ← 配套必学
8. 顺序消息                    ← 高级特性（一）
9. 事务消息                    ← 高级特性（二）
10. 延迟消息                   ← 高级特性（三）
11. 消息堆积处理               ← 故障应对压轴
12. MQ 对比与选型              ← 选型决策（横向视野）
```

### 面试速通路径（30 分钟刷一遍）

每篇都已配 **答题模板（60 秒话术）**——直接复述就是 senior 级回答：

**架构与存储**
- [RocketMQ 架构](./RocketMQ架构.md#八答题模板60-秒话术)
- [存储机制](./存储机制.md#十答题模板60-秒话术)
- [刷盘与复制](./刷盘与复制.md#九答题模板60-秒话术)

**客户端**
- [生产者](./生产者.md#九答题模板60-秒话术)
- [消费者](./消费者.md#十答题模板60-秒话术)

**可靠性**
- [消息可靠性](./消息可靠性.md#九答题模板60-秒话术)
- [重复消费与幂等](./重复消费与幂等.md#九答题模板60-秒话术)

**高级特性**
- [顺序消息](./顺序消息.md#九答题模板60-秒话术)
- [事务消息](./事务消息.md#十答题模板60-秒话术)
- [延迟消息](./延迟消息.md#八答题模板60-秒话术)

**故障应对**
- [消息堆积处理](./消息堆积处理.md#八答题模板60-秒话术)

**选型对比**
- [MQ 对比与选型](./MQ对比与选型.md#十五答题模板60-秒话术)

---

## 四、应用场景速查表

被问"项目里 MQ 怎么用的"，按场景找方案：

| 业务需求 | 推荐方案 | 详见 |
| --- | --- | --- |
| 订单创建 → 库存扣减（跨服务事务） | 事务消息 + Consumer 幂等 | [事务消息](./事务消息.md) |
| 订单 30 分钟未支付关单 | 4.x 延迟级别 30min | [延迟消息](./延迟消息.md) |
| 任意时间延迟（如 35 分钟） | 5.x 时间轮 | [延迟消息](./延迟消息.md#三rocketmq-5x任意时间延迟时间轮) |
| 同一订单状态消息严格顺序 | MessageQueueSelector hash + MessageListenerOrderly | [顺序消息](./顺序消息.md) |
| 短信/通知（可丢失） | 异步发送 + 失败回调入库 | [生产者](./生产者.md#三三种发送方式对比) |
| 日志/埋点（极致性能） | Oneway + 接受少量丢失 | [生产者](./生产者.md#三三种发送方式对比) |
| 多副本通知（每个实例都收） | 广播消费（BROADCASTING） | [消费者](./消费者.md#四消费模式集群-vs-广播) |
| 消费失败兜底 | DLQ Topic 单独订阅 + 监控告警 | [消费者](./消费者.md#五消费失败重试) |
| 高吞吐场景 | 异步刷盘 + 异步复制（默认） | [刷盘与复制](./刷盘与复制.md#51-互联网典型业务默认) |
| 高可靠（订单/支付） | SYNC_MASTER + ASYNC_FLUSH | [刷盘与复制](./刷盘与复制.md#52-高可靠业务订单支付) |
| 金融级（钱相关） | SYNC_MASTER + SYNC_FLUSH 或 Dledger | [刷盘与复制](./刷盘与复制.md#53-金融级钱相关) |
| 自动主备切换 | Dledger（3 节点起步） | [刷盘与复制 - Dledger](./刷盘与复制.md#四dledger-模式45-自动主备切换) |

---

## 五、选型决策树

### MQ 选型

```
日志 / 流处理（百万级 TPS）？
├─ 是 → Kafka
└─ 否 →
    业务消息（订单、支付、事务）？
    ├─ 是 → RocketMQ ✓
    └─ 否 →
        协议复杂（AMQP/STOMP）/规模小？
        ├─ 是 → RabbitMQ
        └─ 否 → RocketMQ
```

### 可靠性配置选型

```
吞吐 vs 可靠性？
├─ 互联网默认（性价比）→ ASYNC_FLUSH + ASYNC_MASTER
├─ 订单支付（高可靠）  → ASYNC_FLUSH + SYNC_MASTER  ← 推荐
├─ 金融级（不允许丢）  → SYNC_FLUSH + SYNC_MASTER
└─ 要自动主备切换      → Dledger（3 节点起步）
```

### 部署形态

```
单 Master              ─→ 测试 / 低优先级
多 Master 无 Slave     ─→ 高吞吐，可容忍故障期间不可消费
多 Master 多 Slave 异步 ─→ 生产主流（默认）
多 Master 多 Slave 同步 ─→ 高可靠业务
Dledger（Raft）        ─→ 自动故障切换的金融级方案
```

---

## 六、关键速记表

### RocketMQ 版本演进

| 版本 | 关键特性 |
| --- | --- |
| 4.0 | 第一个稳定版本 |
| 4.3 | 事务消息正式发布 |
| 4.5 | **Dledger（Raft）多副本** |
| 4.6 | LitePullConsumer（拉模式简化版） |
| 4.7 | SQL92 过滤、ACL 权限 |
| 4.9 | 容器优化、批量索引 |
| 5.0 | **任意时间延迟（时间轮）** + 分级存储 + Streaming + 客户端协议升级 |

### 默认参数速查

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| `flushDiskType` | ASYNC_FLUSH | 异步刷盘 |
| `brokerRole` | ASYNC_MASTER | 异步复制 |
| `mappedFileSizeCommitLog` | 1G | CommitLog 单文件 |
| `fileReservedTime` | 72h | 消息保留 |
| `maxMessageSize` | 4MB | 单条消息上限 |
| `consumeThreadMin/Max` | 20 | Consumer 线程池 |
| `pullBatchSize` | 32 | 单次 Pull 最多条数 |
| `pullThresholdForQueue` | 1000 | 单 Queue 缓存条数 |
| `maxReconsumeTimes` | 16 | 消费重试次数 |
| `messageDelayLevel` | 1s 5s 10s 30s 1m 2m 3m 4m 5m 6m 7m 8m 9m 10m 20m 30m 1h 2h | 18 个延迟级别 |
| `transactionTimeOut` | 6000ms | 事务消息超时 |
| `transactionCheckMax` | 15 | 事务回查最大次数 |
| `pollNameServerInterval` | 30s | 拉路由间隔 |
| `heartbeatBrokerInterval` | 30s | Broker 心跳间隔 |
| `brokerSuspendMaxTimeMillis` | 15s | 长轮询 hold 时长 |
| `rebalanceInterval` | 20s | Rebalance 周期 |

### RocketMQ vs Kafka vs RabbitMQ

| 维度 | RocketMQ | Kafka | RabbitMQ |
| --- | --- | --- | --- |
| 定位 | 业务消息 | 日志/流处理 | 协议丰富的传统 MQ |
| 单机 TPS | 10w | 17w | 万级 |
| 注册中心 | NameServer | ZK / KRaft | 内置 Erlang 集群 |
| 存储模型 | 混合 CommitLog | 每 Topic-Partition 独立 | 内存 + 磁盘混合 |
| 顺序消息 | Queue 内严格顺序 | Partition 内有序 | 单队列单消费者 |
| 延迟消息 | 4.x 18 级 / 5.x 任意 | 不支持 | 死信交换机模拟 |
| 事务消息 | half + 回查 | 仅 Producer 端事务 | 不支持 |
| 协议 | 私有 + REST | 私有 | AMQP / STOMP / MQTT |

---

## 七、生产踩坑 TOP 10

跨文档汇总最高频的 10 个坑：

1. **同步发送配成 Async 丢消息**（[消息可靠性](./消息可靠性.md#71-sync-发送配置成-async-引发丢消息)）
2. **大消息引发 OOM**（>4MB 走对象存储）（[生产者](./生产者.md#72-大消息引发-oom)）
3. **顺序消费抛异常卡 Queue**（必须设 maxReconsumeTimes）（[顺序消息](./顺序消息.md#72-顺序消费里抛异常没处理)）
4. **大促前没扩 Queue**（先扩 Queue 再扩 Consumer）（[消息堆积处理](./消息堆积处理.md#61-大促前没扩-queue)）
5. **Topic 扩 Queue 破坏顺序**（业务低峰期扩）（[顺序消息](./顺序消息.md#73-topic-扩容-queue-数后乱序)）
6. **DLQ 堆积无人发现**（必须监控告警）（[消费者](./消费者.md#83-死信队列堆积无人处理)）
7. **下游 DB 抖动导致重试雪崩**（Consumer 加熔断）（[消息堆积处理](./消息堆积处理.md#62-下游-db-抖动导致雪崩)）
8. **Redis SETNX 后业务异常永久丢消息**（catch 后 delete 回滚）（[重复消费与幂等](./重复消费与幂等.md#71-setnx-后业务异常导致永久丢消息)）
9. **事务消息回查接口异常返回 ROLLBACK**（应返回 UNKNOWN）（[事务消息](./事务消息.md#81-回查接口异常导致消息全部-rollback)）
10. **Rebalance 抖动重复消费**（业务必须幂等）（[消费者](./消费者.md#82-rebalance-抖动导致重复消费)）

---

## 八、相关模块

- [Redis 消息队列方案](../Redis/消息队列方案.md) — Redis Stream / List / PubSub 三方案对比
- [分布式 - 幂等](../Distributed/幂等.md) — 通用幂等设计（不限于 MQ）
- [MySQL - 唯一约束](../MySQL/索引.md) — DB 唯一约束实现幂等
- [并发 - 线程池](../Concurrency/线程池.md) — Consumer 线程池调优
