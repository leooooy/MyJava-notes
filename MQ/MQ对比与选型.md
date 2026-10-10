# 主流 MQ 对比与选型（RocketMQ / Kafka / RabbitMQ / Pulsar）

> "为什么选 RocketMQ 不选 Kafka？"——选型题永远在问，但 90% 的回答只会说"业务消息"和"日志"。
> 本篇要解决：
> ① 四款主流 MQ 的架构差异到底在哪？为什么决定了它们的适用场景？
> ② 存储模型 / 高可用 / 顺序 / 事务 / 延迟 这 5 个核心维度怎么横向对比？
> ③ 性能数字背后的本质差异是什么？
> ④ 真实场景下怎么决策？典型的"用错了"是什么样？
> ⑤ Pulsar 这种新生代值不值得跟进？

---

## 一、四款 MQ 的"出身"

理解选型差异之前，先要理解每款 MQ 是**为什么诞生的**——它的设计取舍由此决定。

| MQ | 出身 | 解决的核心问题 | 主导思想 |
| --- | --- | --- | --- |
| **RocketMQ** | 阿里 2012，2016 捐 Apache | 双 11 业务消息可靠传递 | 业务可靠 > 极致吞吐 |
| **Kafka** | LinkedIn 2010，2011 开源 | 海量日志的实时管道 | 极致吞吐 > 业务功能 |
| **RabbitMQ** | Rabbit Tech 2007，VMware/Pivotal 维护 | AMQP 协议的标准实现 | 协议丰富 > 性能 |
| **Pulsar** | Yahoo 2016，2018 Apache 顶级 | 云原生 + 计算存储分离 | 弹性 + 流批一体 |

```
RocketMQ:    "我要保证订单消息一条都不能丢，但 10w TPS 够用了"
Kafka:       "我要每秒处理百万条日志，丢一点儿没事"
RabbitMQ:    "我要支持各种协议、各种交换机、各种路由"
Pulsar:      "我要做云上的下一代统一消息平台"
```

---

## 二、整体架构对比

### 2.1 RocketMQ 架构

```
[Producer]    [NameServer 集群]
    │              ▲
    │              │ 路由查询/心跳
    ▼              │
[Broker Master] ─sync/async─► [Broker Slave]
       ▲ (写入消息)
       │
[Consumer]
```

**特点**：
- **NameServer** 无状态、节点互不通信、AP 模型
- Master/Slave 主备，4.x 不自动切，Dledger 支持自动选主
- Producer/Consumer 走 NameServer 拉路由 → 直连 Broker

### 2.2 Kafka 架构

```
[Producer]     [ZooKeeper / KRaft]
    │              ▲
    │              │ 元数据
    ▼              │
[Broker-0] ◄── replica ──► [Broker-1] ◄── replica ──► [Broker-2]
   ▲                            ▲
   │                            │
[Consumer Group: poll]
```

**特点**：
- **ZooKeeper（旧）/ KRaft（3.0+）** 存储元数据 + 协调 controller
- **Partition 多副本**（Leader / Follower），Leader 处理读写，Follower 同步
- Controller 监听副本状态，故障时自动选 Leader（ISR 机制）
- 没有"Master/Slave Broker"概念——同一 Broker 上既有某 Topic 的 Leader 也有其他 Topic 的 Follower

### 2.3 RabbitMQ 架构

```
[Producer]
    │ AMQP 协议
    ▼
+------------------+
|   Exchange       |   ← 发布交换机（Direct/Topic/Fanout/Headers）
+------------------+
        │ 路由规则（routing key + binding）
        ▼
+------------------+
|     Queue        |   ← 队列
+------------------+
        │
        ▼
[Consumer]
```

**特点**：
- **AMQP 协议** 中心，Exchange + Queue 是核心抽象
- 节点间通过 **Erlang 集群** 同步元数据；队列默认在某一节点（镜像队列复制到其他节点）
- 4.x 引入 Quorum Queue（基于 Raft）替代镜像队列

### 2.4 Pulsar 架构

```
[Producer]            [ZooKeeper / etcd]
    │                       ▲
    │                       │ 元数据
    ▼                       │
[Broker（无状态）] ──────► [Bookie 集群（BookKeeper）]
    ▲                       存储分片
    │
[Consumer]
```

**特点**：
- **计算 / 存储分离**：Broker 无状态，存储在 BookKeeper（Bookie）
- Broker 故障：路由到其他 Broker，秒级恢复，无数据迁移
- Topic 分 **Bundle**（一组 Topic 分组到同一 Broker），Broker 间负载均衡
- 多副本写入由 BookKeeper 完成（Quorum 机制）

---

## 三、存储模型：决定性能上限

### 3.1 五种存储模型

| MQ | 存储模型 | 单条消息流向 |
| --- | --- | --- |
| **RocketMQ** | 混合 CommitLog | 所有 Topic 共写一个 1G CommitLog 顺序追加 + 异步生成 ConsumeQueue 索引 |
| **Kafka** | 每 Partition 独立 | 每 Topic-Partition 一个目录，独立顺序写 |
| **RabbitMQ** | 内存优先 + 持久化可选 | 队列内消息存内存，Lazy Queue 模式存磁盘 |
| **Pulsar** | BookKeeper 分布式日志 | 消息按 Ledger（段）写入多个 Bookie，存储与计算解耦 |

### 3.2 RocketMQ vs Kafka 的根本差异

```
RocketMQ：所有 Topic 共写 1 个 CommitLog
+--------------------------+
|  CommitLog (顺序追加)    |
|   topic-a, topic-b,      |
|   topic-c, topic-d ...   |   ← 永远顺序写
+--------------------------+
       │
       ▼
+--------------------------+
| ConsumeQueue (异步生成索引) |
|  topic-a/queue-0          |
|  topic-b/queue-0          |
+--------------------------+

Kafka：每 Partition 独立文件
+----------------+   +----------------+   +----------------+
| topic-a/p-0    |   | topic-a/p-1    |   | topic-b/p-0    |
| 顺序写         |   | 顺序写         |   | 顺序写         |
+----------------+   +----------------+   +----------------+
```

**关键差异**：

| 场景 | RocketMQ | Kafka |
| --- | --- | --- |
| 单 Topic 极限吞吐 | 10w TPS | **17w TPS** |
| 数百 Topic 并发 | **10w TPS（不掉）** | 急剧下降（多文件随机写） |
| 单 Topic 多分区扩展 | Queue 数仅做并发度 | Partition 是 **物理文件**，扩 Partition 直接扩磁盘 |
| 存储紧凑度 | 高（共用文件） | 较低（多个小文件 metadata 开销） |

**结论**：
- **大量 Topic 的业务场景** → RocketMQ 不掉性能
- **少量 Topic 的日志场景** → Kafka 极限吞吐更高

### 3.3 Pulsar 的"分片存储"

```
Topic 的消息流被切分成 Ledger（段）：
Ledger-1 (closed) ──► Ledger-2 (closed) ──► Ledger-3 (writing)

每个 Ledger 复制到 N 个 Bookie 上：
Ledger-1 → Bookie-1, Bookie-2, Bookie-3
Ledger-2 → Bookie-2, Bookie-3, Bookie-4   ← 自动负载均衡
Ledger-3 → Bookie-1, Bookie-3, Bookie-5
```

**优势**：
- **Broker 无状态** → 故障秒级切换，无数据迁移
- **存储弹性扩容** → Bookie 横向加机器，不需要 reblance Topic
- **冷热分离** → 老 Ledger 卸载到对象存储（S3）

**代价**：
- 架构复杂度高（多了 BookKeeper 这一层）
- 端到端延迟略高（多一跳）
- 运维门槛高

---

## 四、高可用方案

### 4.1 副本机制对比

| MQ | 副本协议 | 写入语义 | 故障切换 |
| --- | --- | --- | --- |
| **RocketMQ 4.x** | Master/Slave 主从 | SYNC_MASTER 等 1 个 Slave | **手动**（运维介入） |
| **RocketMQ Dledger** | Raft（多数派） | 多数派 ACK | 自动（10s 内） |
| **Kafka** | ISR（In-Sync Replicas） | acks=all 等所有 ISR | 自动（Controller 选主） |
| **RabbitMQ Mirror** | 主从全副本（已 deprecated） | 同步到所有镜像 | 自动 |
| **RabbitMQ Quorum** | Raft | 多数派 ACK | 自动 |
| **Pulsar** | BookKeeper Quorum | Quorum 写（如 3-2-2）| Broker 秒级切换 |

### 4.2 Kafka 的 ISR 机制

```
ISR = In-Sync Replicas（与 Leader 保持同步的副本集合）

Leader: P-0
Replicas: [P-0, P-1, P-2]
ISR: [P-0, P-1, P-2]  ← P-1, P-2 落后 < replica.lag.time.max.ms (默认 10s)

如果 P-1 落后超 10s:
ISR: [P-0, P-2]

acks=all 时 Producer 等到所有 ISR 副本写完才返回成功
```

**关键参数**：
- `acks=0` ─ 不等任何副本，最快但可能丢
- `acks=1` ─ 等 Leader 写入即返回，Leader 挂可能丢
- `acks=all` ─ 等所有 ISR 写完，**最可靠**
- `min.insync.replicas=2` ─ 配合 acks=all，确保 ISR 至少有 2 个，否则拒写

**故障切换**：Leader 挂 → Controller 从 ISR 中选最快追上的副本作新 Leader → 客户端自动重连。

### 4.3 RocketMQ vs Kafka 副本对比

| 维度 | RocketMQ Dledger | Kafka ISR |
| --- | --- | --- |
| 协议 | Raft | 自研 ISR |
| 副本数 | 必须奇数（3/5）| 任意（一般 3） |
| 一致性 | 强一致（多数派） | acks=all + min.insync 时强一致 |
| 节点宕机容忍 | 多数派存活 | ISR 至少 1 个 |
| 选主期不可写 | ~10s | ~10s |

### 4.4 Pulsar 的 Quorum 写入

```
3-2-2 配置：
- Ensemble Size = 3   （选 3 个 Bookie）
- Write Quorum = 2     （写 2 个成功就 OK）
- Ack Quorum = 2       （等 2 个 ACK）

写入：
Broker ──► Bookie-1 ┐
       ──► Bookie-2 ├─ 任 2 个 ACK 即返回成功
       ──► Bookie-3 ┘
```

容忍 1 台 Bookie 挂；自动选另一台 Bookie 重组 Ensemble。

---

## 五、消息可靠性对比

| 维度 | RocketMQ | Kafka | RabbitMQ | Pulsar |
| --- | --- | --- | --- | --- |
| 默认是否丢消息 | 异步刷盘可能丢 < 500ms | acks=1 默认，可能丢 | 默认内存（可能丢）| 默认 Quorum，不丢 |
| 强可靠配置 | SYNC_FLUSH + SYNC_MASTER 或 Dledger | acks=all + min.insync=2 + flush=true | 持久化 + 镜像 + publisher confirms | 默认即强可靠 |
| 端到端可靠保证 | At Least Once | At Least Once（默认）/ Exactly Once（事务） | At Least Once | At Least Once / Exactly Once |
| 极端场景丢失 | OS 崩溃可能丢 | 同 | 同 | BookKeeper 多数派宕机 |
| Producer 端确认 | SendResult.SEND_OK | acks 机制 | publisher confirms | sendAsync().get() |
| Consumer 端确认 | 业务返回 SUCCESS | offset commit | basicAck | acknowledge() |

### 5.1 Kafka 的可靠性配置坑

```properties
# Producer 端
acks=all
retries=Integer.MAX_VALUE
enable.idempotence=true   # 5.0+ 默认 true，避免重试导致重复

# Broker 端
min.insync.replicas=2     # 至少 2 个 ISR 才允许写
unclean.leader.election.enable=false   # 禁止 OutOfSync 副本当 Leader（防丢）
log.flush.interval.messages=1
log.flush.interval.ms=1000   # 同步刷盘频率
```

**坑**：`unclean.leader.election.enable=true`（旧版默认） → Leader 挂时若 ISR 全挂，会从 OutOfSync 副本选主 → **可能丢失大量数据**。新版默认 false 后才安全。

---

## 六、顺序消息对比

| MQ | 顺序粒度 | 实现 | 故障容忍 |
| --- | --- | --- | --- |
| **RocketMQ** | Queue 内严格 | MessageQueueSelector + 三把锁（Broker 锁/MQ 锁/ProcessQueue 锁） | Master 切换可能短暂乱序 |
| **Kafka** | Partition 内严格 | Producer key hash + 单 Partition 单 Consumer | Leader 切换可能乱序（acks=1 时） |
| **RabbitMQ** | 单队列 | 单队列单消费者单线程 | 镜像切换可能乱序 |
| **Pulsar** | Key_Shared 模式 | Producer 用 key 分配；Subscription 用 Key_Shared 类型 | Broker 切换由 BookKeeper 保障 |

### 6.1 Kafka 的顺序最简单但有坑

```java
// Producer：相同 key 发到同一 Partition
producer.send(new ProducerRecord<>("topic", orderId, msg));

// Consumer：单 Partition 单 Consumer 实例自动有序
```

**坑 1**：Producer 端 `max.in.flight.requests.per.connection > 1` + 重试 → 可能乱序
- 5.0+ `enable.idempotence=true` 限制 ≤ 5 且自动保序
- 旧版本必须设为 1 才能保序

**坑 2**：扩 Partition 后 hash 取模结果变 → 同 key 可能落不同 Partition

### 6.2 Pulsar 的 Key_Shared

最灵活的顺序模式：
- Producer 不用关心分区，直接发
- Consumer Subscription 设为 `Key_Shared` 类型
- Pulsar 自动按 key 分配给固定 Consumer，**无需手动管理分区**

代价：复杂度高，性能略低于 Exclusive 模式。

---

## 七、事务消息对比

| MQ | 事务支持 | 适用场景 |
| --- | --- | --- |
| **RocketMQ** | half 消息 + 事务回查 | **业务事务 + MQ 一致性** |
| **Kafka** | Producer 事务（多 Partition / 多消息原子） | **Kafka Streams 内部 Exactly Once** |
| **RabbitMQ** | tx.select / tx.commit（性能差，不推荐） | 几乎无人用 |
| **Pulsar** | 类似 Kafka 的 Producer 事务（2.7+） | 流处理 |

### 7.1 RocketMQ vs Kafka 事务的本质差异

```
RocketMQ 事务消息：
- 解决 "本地 DB 事务" + "MQ 发送" 一致性
- Producer 调用 sendMessageInTransaction
- Broker 提供 half 消息 + 反查机制
- Consumer 端不参与事务（只能靠幂等）
- 业务场景：订单创建后通知库存系统

Kafka 事务：
- 解决 "Kafka 内部 多 Partition / 多消息" 原子性
- Producer initTransactions / beginTransaction / commitTransaction
- Consumer 端 isolation.level=read_committed
- 流处理场景：从 Topic-A 消费 → 转换 → 写 Topic-B 的原子性
- 不解决 "DB 事务 + MQ 发送" 一致性
```

**典型用错**：用 Kafka 事务想保证"下单 + 发消息"一致——做不到，要用 outbox 模式（本地消息表）。

---

## 八、延迟消息对比

| MQ | 支持 | 实现 |
| --- | --- | --- |
| **RocketMQ 4.x** | ✅ 18 个固定级别（1s ~ 2h） | SCHEDULE_TOPIC_XXXX 内部转发 |
| **RocketMQ 5.x** | ✅ 任意时间（最大 7 天） | 时间轮 + TimerLog |
| **Kafka** | ❌ 不原生支持 | 需要外部实现（多 Topic 阶梯）|
| **RabbitMQ** | ⚠️ 需插件（rabbitmq-delayed-message-exchange）| 死信交换机 + TTL |
| **Pulsar** | ✅ 任意时间 | deliverAfter / deliverAt API |

### 8.1 Kafka 没有延迟消息怎么办？

业界三种方案：

```
方案 A：阶梯 Topic
   topic-delay-1s, topic-delay-10s, topic-delay-1m, topic-delay-5m
   消费者读取后判断时间，未到则转发到下一阶梯
   → 缺点：实现复杂，多次写入
   
方案 B：外部调度器
   消息进 topic-pending → Quartz / Redis 调度 → 到期投递 topic-real
   → 缺点：依赖外部组件
   
方案 C：直接用 RocketMQ / Pulsar
   → 推荐
```

---

## 九、性能对比

> ⚠️ 性能数字仅供参考，具体取决于硬件、配置、消息大小、刷盘策略等。

### 9.1 单机参考性能（普通 SSD，1KB 消息）

| MQ | 吞吐 | 延迟 P99 | 可靠性配置 |
| --- | --- | --- | --- |
| **Kafka** | 17w TPS | < 10ms | acks=all + 异步刷盘 |
| **RocketMQ** | 10w TPS | < 5ms | ASYNC_FLUSH + ASYNC_MASTER |
| **Pulsar** | 8w TPS | < 10ms | 默认 Quorum 3-2-2 |
| **RabbitMQ Classic** | 万级 | < 5ms | 镜像队列 |
| **RabbitMQ Quorum** | 千级 ~ 万级 | 较高 | Raft |

### 9.2 性能差异的本质

**Kafka 单机吞吐高**：
- ① 每 Partition 独立顺序写（无锁竞争）
- ② sendfile 零拷贝（消费侧不经过用户态）
- ③ 批量压缩（多条消息合并 batch）
- ④ Linger.ms 累积小消息

**RocketMQ 业务吞吐稳**：
- ① 共用 CommitLog，多 Topic 不掉性能
- ② mmap（写消息可在用户态过滤）
- ③ 默认配置即可达 10w TPS

**RabbitMQ 性能差**：
- ① Erlang VM 性能不及 JVM
- ② AMQP 协议复杂（多次确认）
- ③ Mirror Queue 同步开销

**Pulsar 性能略低于 Kafka**：
- 多一层 BookKeeper 网络往返
- 但**横向扩展能力极强**（Bookie 加机器即可）

---

## 十、运维与生态

| 维度 | RocketMQ | Kafka | RabbitMQ | Pulsar |
| --- | --- | --- | --- | --- |
| 部署复杂度 | 中（NameServer + Broker） | 中（ZK/KRaft + Broker） | 低（单节点即可） | **高**（ZK + Bookie + Broker） |
| 客户端语言 | Java 主，多语言较弱 | **多语言全面** | 多语言全面 | 多语言全面 |
| 社区活跃度 | 阿里 + Apache | **顶级活跃** | 活跃 | Apache 活跃 |
| 中文资料 | **极丰富** | 丰富 | 一般 | 较少 |
| 监控生态 | RocketMQ Dashboard | **JMX + Prometheus + Grafana 标杆** | Management Plugin | Pulsar Manager |
| 云厂商支持 | 阿里云原生 | AWS MSK / Confluent | 各家都有 | StreamNative 商业版 |
| 学习曲线 | 中 | 中 | 低 | **陡** |

---

## 十一、典型选型场景

### 11.1 选 Kafka 的场景

```
✅ 日志收集（ELK 栈核心）
✅ 大数据流处理（Spark Streaming / Flink 标配）
✅ 用户行为埋点（每秒百万级）
✅ 数据库 binlog 同步（Canal → Kafka）
✅ 监控指标管道
```

### 11.2 选 RocketMQ 的场景

```
✅ 电商订单链路（创建 → 支付 → 发货 → 评价）
✅ 金融交易通知（支付/到账/结算）
✅ 跨服务最终一致性（事务消息）
✅ 任务调度（延迟消息）
✅ 中文社区为主的国内业务
```

### 11.3 选 RabbitMQ 的场景

```
✅ 企业 IT 系统集成（多协议：AMQP / STOMP / MQTT）
✅ 路由复杂的场景（topic exchange + 多绑定）
✅ 规模较小（< 万级 TPS）
✅ 已有 Spring AMQP 技术栈
✅ 微服务间事件通知（吞吐要求不高）
```

### 11.4 选 Pulsar 的场景

```
✅ 云原生架构（K8s + 弹性伸缩）
✅ 流批一体处理（Pulsar Functions）
✅ 跨地域复制（geo-replication 内置）
✅ 海量 Topic（百万级 Topic 不掉性能）
✅ 冷热分离存储（自动卸载到对象存储）
```

### 11.5 决策树

```
是不是日志/流处理？
├─ 是 → Kafka
└─ 否
    │
    需要复杂路由 / 协议丰富？
    ├─ 是 → RabbitMQ
    └─ 否
        │
        云原生 + 弹性 + 流批一体？
        ├─ 是 → Pulsar（成本高，慎选）
        └─ 否 → RocketMQ ✓（业务消息默认选）
```

---

## 十二、五大维度对比矩阵（速记）

| 维度 | RocketMQ | Kafka | RabbitMQ | Pulsar |
| --- | --- | --- | --- | --- |
| 单机 TPS | 10w | **17w** | 万级 | 8w |
| 多 Topic 性能 | **稳定** | 急降 | 一般 | 稳定 |
| 顺序消息 | Queue 严格 | Partition 严格 | 单 Q 单 C | Key_Shared |
| 延迟消息 | **18 级 / 任意（5.x）** | ❌ | 插件 | ✅ 任意 |
| 事务消息 | **业务事务 + MQ** | Kafka 内部 | 几乎不用 | Kafka 类似 |
| 消息回溯 | 按时间戳 | 按 offset | ❌ | 按时间戳 |
| 消息查询 | msgId + key | offset only | ❌ | msgId |
| 死信处理 | 内置 DLQ | ❌ 业务自实现 | DLX 死信交换机 | 内置 DLQ |
| 自动主备切换 | Dledger | **ISR**（默认） | Quorum Queue | **默认**（Bookie 容错） |
| 部署节点数 | 至少 4（2 NS + 2 Broker）| 至少 4（3 ZK + 1 Broker） | 至少 1 | **至少 7**（3 ZK + 3 BK + 1 Broker） |
| 客户端语言 | Java 主 | **多语言** | 多语言 | 多语言 |
| 中文社区 | **顶级** | 好 | 一般 | 一般 |
| 学习曲线 | 中 | 中 | 低 | 陡 |

---

## 十三、生产踩坑横向对比

### 13.1 都会遇到的坑

| 坑 | 通用解决思路 |
| --- | --- |
| 消费堆积 | 扩 Queue/Partition + 扩 Consumer |
| 重复消费 | 业务侧幂等 |
| 消息丢失 | 按可靠性配置档位 |
| 消费阻塞（慢消费者）| 业务超时 + 拆短任务 |
| 大消息打爆 | 改用对象存储 + 消息只传 URL |

### 13.2 各家特色坑

**Kafka 特色坑**：
- `unclean.leader.election.enable=true`（旧版默认）→ 严重丢消息
- Consumer Group Rebalance 风暴（大集群启动时几分钟不可消费）
- ZooKeeper 抖动整个集群暂停服务
- Partition 数过多（万级）→ 小文件 IO 风暴

**RocketMQ 特色坑**：
- 4.x 主从手动切换（Master 挂可能 Topic 不可写几小时）
- 顺序消费抛异常永久卡 Queue
- 同步发送被错配为 Async
- DLQ 堆积无人发现

**RabbitMQ 特色坑**：
- 镜像队列性能急剧下降（已被 Quorum Queue 替代）
- 内存压力过高 → flow control 拒绝生产
- Erlang 集群 split-brain（脑裂恢复复杂）
- 队列单点故障（非镜像/Quorum 配置）

**Pulsar 特色坑**：
- BookKeeper 与 Broker 之间的网络抖动放大
- ZooKeeper 仍是单点风险
- 客户端断连重连复杂（subscription 类型语义）
- 文档/资料不如 Kafka 丰富

---

## 十四、面试高频追问

**Q1：为什么不直接选 Kafka 一个就够了？**

Kafka 的优化目标是**少量大 Topic 的极限吞吐**——LinkedIn 的日志埋点几个 Topic 打天下，每 Partition 独立顺序写最快。但业务消息场景（订单/支付/通知）是**大量小 Topic**，几百上千个 Topic 在 Kafka 里会退化为多文件随机写、Partition metadata 风暴。

而且 Kafka 不支持**延迟消息、事务消息（业务事务）、消息查询**——这些都是业务场景的硬需求。

**Q2：RocketMQ 会被 Pulsar 替代吗？**

短期内**不会**。原因：
- 中国大厂业务栈深度依赖 RocketMQ（阿里系都用）
- Pulsar 部署复杂（多了 BookKeeper），运维成本高
- Pulsar 优势"云原生 + 弹性"在自建机房场景不明显
- 中文社区资料少

但 Pulsar 的**计算存储分离**确实是更先进的架构，云上场景（特别是公有云客户）会逐渐增加。

**Q3：Kafka 的 ISR 和 RocketMQ 的 Dledger 哪个强？**

```
Kafka ISR：
  优势：副本数任意（一般 3）；ISR 动态调整（落后副本自动剔除）
  劣势：依赖 ZK 协调；早期 unclean.leader 坑过

RocketMQ Dledger：
  优势：Raft 协议工业级；自带 controller，无需额外组件
  劣势：必须奇数节点；选举期不可写
```

实际生产中两者都已经是**经过千万级 TPS 验证**的方案，差距在工程细节而非协议本身。

**Q4：RabbitMQ 是不是过时了？**

不能说过时，但**适用场景明显收窄**了。它擅长的"复杂路由 + 多协议"在微服务时代变成了次要需求；性能上不如 Kafka/RocketMQ；分布式扩展能力差。**新项目**不建议选 RabbitMQ，除非：
- 已经深度集成 Spring AMQP 技术栈
- 路由复杂度极高（topic + headers exchange 大量绑定）
- 需要 STOMP / MQTT 等小众协议

**Q5：百万级 Topic 怎么选？**

只有 **Pulsar** 能扛百万级 Topic：
- RocketMQ：万级 Topic 后 NameServer 压力变大
- Kafka：万级 Topic 后 Partition 元数据爆炸
- RabbitMQ：万级 Queue 后内存吃紧
- Pulsar：百万级 Topic + Bundle 自动均衡（设计目标）

**Q6：本地消息表（outbox）和事务消息冲突吗？**

不冲突，**是两个层次的方案**：
```
本地消息表：业务侧实现，与 MQ 解耦，MQ 故障也能补偿
事务消息：MQ 提供能力，业务侧封装更轻

最完整方案 = 事务消息 + 本地消息表兜底
```

Kafka 的 outbox 模式（Debezium）就是数据库 → CDC → Kafka 的标准做法。

**Q7：消息中间件的未来趋势？**

```
1. 计算存储分离（Pulsar 引领，Kafka 也在跟进 Tiered Storage）
2. 流批一体（Pulsar Functions / Kafka Streams）
3. 云原生部署（K8s Operator + 弹性伸缩）
4. 跨地域 / 多活（geo-replication 内置）
5. Schema Registry 强约束（Avro / Protobuf）
6. KRaft 替代 ZK（Kafka 3.0+）
7. WebAssembly 函数（Pulsar / Kafka 都在试）
```

---

## 十五、答题模板（60 秒话术）

> 主流 MQ 选型本质是**"业务消息 vs 流处理"**两条路线：
>
> ① **Kafka** 是为日志/流处理而生——每 Partition 独立顺序写，单机 17w TPS，sendfile 零拷贝，acks=all + ISR 多副本机制做高可靠。但**不支持延迟消息、不支持业务事务消息、Topic 多了性能急降**。
>
> ② **RocketMQ** 是为业务消息而生——所有 Topic 共写一个 CommitLog 顺序追加，多 Topic 不掉性能；天然支持顺序、延迟、事务消息；4.x 主从手动切，Dledger 模式自动选主。
>
> ③ **RabbitMQ** 是 AMQP 协议标准实现，路由灵活、协议丰富，但单机吞吐只有万级，分布式能力弱，新项目慎选。
>
> ④ **Pulsar** 是新生代云原生方案——计算存储分离（Broker 无状态 + BookKeeper 存储），Broker 故障秒级切换，原生支持百万级 Topic 和 geo-replication；代价是部署复杂、学习曲线陡。
>
> 选型决策树：**日志/流处理 → Kafka；业务消息 → RocketMQ（默认）；复杂路由/小规模 → RabbitMQ；云原生 + 弹性 + 海量 Topic → Pulsar**。
>
> 国内电商/金融业务**默认 RocketMQ**，因为业务功能（事务/延迟/顺序）最契合，且中文资料和社区支持最好。

---

## 十六、相关文档

- [RocketMQ 架构](./RocketMQ架构.md) — RocketMQ 详细架构
- [存储机制](./存储机制.md) — RocketMQ 存储与 Kafka 的本质差异
- [刷盘与复制](./刷盘与复制.md) — Dledger 详解
- [事务消息](./事务消息.md) — RocketMQ 事务 vs Kafka 事务
- [延迟消息](./延迟消息.md) — RocketMQ 延迟实现
- [消息可靠性](./消息可靠性.md) — 通用可靠性方案
