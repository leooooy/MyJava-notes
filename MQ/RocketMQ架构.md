# RocketMQ 架构

> RocketMQ 面试基本盘——四个角色（NameServer / Broker / Producer / Consumer）+ 一套消息模型（Topic / Queue / Tag）。
> 本篇要解决：
> ① 为什么 RocketMQ 不用 ZooKeeper，自己写 NameServer？
> ② Topic / Queue / Broker 的多对多关系怎么影响并发与顺序？
> ③ 集群是怎么从"乞丐版"演化到生产可用的高可用拓扑的？
> 弄懂这三点，存储/刷盘/事务等深入题都有了根基。

---

## 一、为什么需要这套架构？

消息队列要解决三件事：**异步解耦、削峰填谷、最终一致**。但中间件本身首先要扛住三大需求：

| 需求 | 设计要点 |
| --- | --- |
| **高吞吐**（10w+ TPS/单机） | 顺序写磁盘、零拷贝、Page Cache |
| **高可用**（Broker 任意一台挂不影响生产消费） | 主从、注册中心、动态路由 |
| **可扩展**（水平加机器即可扩容） | Topic 分布在多台 Broker、Queue 均匀分片 |

```
+----------+     +-----------+     +----------+     +----------+
| Producer | --> | NameServer | --> |  Broker  | --> | Consumer |
+----------+     +-----------+     +----------+     +----------+
   生产者          路由注册中心       存储+转发节点        消费者
   - 拉路由        - 无状态            - 主从冗余          - 拉路由
   - 选 queue      - 互不通信          - 顺序写            - 拉消息
   - 轮询写        - 内存存储          - 同步从从          - rebalance
```

---

## 二、四大角色

### 2.1 NameServer：路由注册中心

```
特点：轻量、无状态、节点间互不通信
功能：① Broker 管理（接收 Broker 心跳，维护存活列表）
      ② 路由信息管理（Topic → Queue → Broker 的映射）
```

**为什么不用 ZooKeeper？**

| 维度 | ZooKeeper | NameServer |
| --- | --- | --- |
| 一致性模型 | CP（Zab 协议、强一致） | AP（最终一致、内存存储） |
| 节点间通信 | 主从 + Quorum 选主 | 互不通信，每台都是完整副本 |
| 部署复杂度 | 高（要保证奇数节点、Leader 选举） | 极低（启动即可，等价 HTTP 路由） |
| 适配场景 | 元数据/配置/选主 | 仅 Topic 路由表 |

**核心动机**：MQ 的路由信息变化不频繁，而对**写性能极度敏感**——每次路由查询走 ZK 的 Watch + 同步等待会成为瓶颈。RocketMQ 设计上接受短暂的"路由不一致"（旧 Broker 列表里有个挂掉的实例），由客户端的发送重试 + Broker 故障规避来兜底。这是一个**典型的 AP 选择**。

**关键时序**：

```
Broker 启动 → 向所有 NameServer 发心跳（每 30s 一次，包含 IP/Port/TopicConfig）
NameServer → 每 10s 扫描，120s 没心跳就剔除（HeartBeat = 30s, Timeout = 120s = 4 个心跳周期）
Producer/Consumer → 每 30s 从某台 NameServer 拉一次最新路由，缓存在本地
```

**踩坑**：Broker 物理掉电瞬间，NameServer 要 120s 才发现，期间 Producer 仍可能向死节点发消息——所以 Producer 必须有 **故障规避** 机制（见生产者章节）。

### 2.2 Broker：消息存储与转发

```
功能：① 接收 Producer 消息，顺序写入 CommitLog
      ② 异步生成 ConsumeQueue 索引，供 Consumer 拉取
      ③ 主从复制（Master 接写，Slave 接读）
      ④ 向所有 NameServer 注册自己 + 上报 Topic 配置
```

**部署形态**：

| 模式 | 说明 | 适用场景 |
| --- | --- | --- |
| 单 Master | 1 个 Broker，无冗余 | 测试/低优先级业务 |
| 多 Master | N 个独立 Master，无 Slave | 高吞吐，可容忍故障期间消息不可消费 |
| 多 Master 多 Slave 异步 | 主从异步复制 | **生产主流方案**，性能与可靠性折中 |
| 多 Master 多 Slave 同步双写 | 主从同步复制 | 金融级，吞吐下降 ~30% |
| Dledger（Raft） | 自动主从切换 | 4.5+ 高可用方案 |

**注意**：传统主从模式下，**Master 挂了不会自动切**，Slave 只能继续提供消费、不能写——直到运维介入或重启 Master。要做到自动切换必须用 Dledger 或 5.0 的 Controller 模式。

### 2.3 Producer：消息生产者

```
启动流程：
① 选一台 NameServer 建立长连接，拉取 Topic 路由
② 缓存 topicPublishInfoTable（Topic → Queue 列表 → Broker 地址）
③ 向所有相关 Master Broker 建立长连接 + 每 30s 心跳
④ 发消息时按负载均衡策略选一个 Queue 写入
```

**topicPublishInfoTable 结构示例**：

| Topic | Broker | QueueId |
| --- | --- | --- |
| order_topic | broker-a | 0, 1, 2, 3 |
| order_topic | broker-b | 0, 1, 2, 3 |

8 个 Queue 分布在 2 个 Broker 上——并发度 = 8，单 Broker 故障还有 4 个 Queue 可写。

### 2.4 Consumer：消息消费者

```
特点：
- Consumer 与 Master/Slave 都建立连接（Master 挂了也能读 Slave）
- 同一 ConsumerGroup 共享消费进度（offset 在 Broker 端维护）
- 支持 Push（默认，本质是长轮询）和 Pull 两种模式
```

**push vs pull**：

| 维度 | Push | Pull |
| --- | --- | --- |
| 实时性 | 高（消息一到就推） | 取决于轮询间隔 |
| 流控 | Broker 推太快可能压垮 Consumer | Consumer 自主控制 |
| 实现 | 长轮询模拟（Broker hold 住请求 15s） | 主动 Pull |
| RocketMQ 默认 | ✅ Push（长轮询底层是 Pull） | 需手动开启 |

**长轮询关键点**：Consumer 发起 Pull 请求，如果 Broker 没有新消息，**不立即返回**，而是 hold 住请求最多 15s（`brokerSuspendMaxTimeMillis`）；新消息到达时立即唤醒推送。等价于 Push 的实时性 + Pull 的流控能力。

---

## 三、消息模型：Topic / Queue / Tag

### 3.1 队列模型 vs 主题模型

```
队列模型（最朴素）：
  Producer → Queue → Consumer
  问题：广播怎么办？复制 N 份消息？违反解耦原则。

主题模型（发布订阅）：
  Producer → Topic（多个 Queue）→ ConsumerGroup1 / ConsumerGroup2 / ...
  每个 ConsumerGroup 独立维护 offset，互不干扰。
```

RocketMQ 用 **Topic + Queue** 实现主题模型：

- **Topic**：一类消息的逻辑分组，跨 Broker 分布
- **Queue**：Topic 的物理分片单元，**单 Queue 内严格有序**
- **Tag**：Topic 内部的二级过滤器（消费端按 Tag 订阅）

### 3.2 Topic / Queue / Broker 多对多关系

```
                  +-------- broker-a (master) --------+
                  |   Topic-A: queue-0, queue-1       |
                  |   Topic-B: queue-0, queue-1       |
                  +-----------------------------------+
                  +-------- broker-b (master) --------+
                  |   Topic-A: queue-2, queue-3       |
                  |   Topic-B: queue-2, queue-3       |
                  +-----------------------------------+
```

- 一个 Topic 分布在 N 个 Broker 上 → 写吞吐扩展
- 一个 Broker 承载 N 个 Topic → 资源利用率高
- 大流量 Topic 多分配 Queue + 分散到多 Broker

### 3.3 Queue 数量怎么定？

| 场景 | 推荐 Queue 数 |
| --- | --- |
| 普通业务 | 4 ~ 16（per Broker）|
| 顺序消息 | 与业务键基数匹配（订单 ID hash） |
| 高吞吐日志 | 16 ~ 64 |
| 严格全局有序 | **必须 1**（损失并发） |

**算法**：单 Topic 总 Queue 数 = max(Consumer 实例数, 期望并发度)，否则多余的 Consumer 会空闲（一个 Queue 只能被同组一个 Consumer 消费）。

### 3.4 ConsumerGroup 与广播 vs 集群

```
集群消费（CLUSTERING，默认）：
  ConsumerGroup-A 内有 3 个 Consumer，每条消息只被其中 1 个消费
  → 实现负载均衡

广播消费（BROADCASTING）：
  ConsumerGroup-A 内每个 Consumer 都收到全量消息
  → 适合本地缓存刷新等场景；offset 存本地（client 端）
```

---

## 四、核心流程：发一条消息要经过什么？

```
[Producer]                  [NameServer]                    [Broker-Master]      [Broker-Slave]
    |                            |                                |                    |
    |---(1) 拉取 Topic 路由---->|                                |                    |
    |<--(2) 返回 broker+queue---|                                |                    |
    |                                                                                  |
    |--(3) selectQueue 负载均衡--→ 选定 broker-a, queue-1                              |
    |                                                                                  |
    |---(4) 发送 SEND_MESSAGE 请求 ---------------> Netty 长连接                       |
    |                                                |                                 |
    |                                                |--(5) 写 PageCache (mmap)        |
    |                                                |--(6) 同步/异步刷盘              |
    |                                                |--(7) 同步/异步复制 -----------> |
    |<-----------------(8) 返回 SendResult-----------|                                 |
    |                                                                                  |
    |   (sendStatus, msgId, offsetMsgId, queueOffset)                                  |
```

**关键点**：
- 第 (4) 步同步发送时，Producer 用 `CountDownLatch` + `responseTable<opaque, Future>` 实现"假同步"——底层仍是 Netty 异步 `writeAndFlush`，收到响应后才 `countDown` 解阻塞
- 第 (5)~(7) 是 Broker 内部的关键路径，决定消息可靠性（详见 [刷盘与复制](./刷盘与复制.md)）
- 第 (8) 的 `offsetMsgId` 长 16 字节：前 8 字节 = Broker 地址，后 8 字节 = CommitLog 物理偏移量，可用来快速定位

---

## 五、生产部署的演进

### 5.1 乞丐版（不可用）

```
Producer ──► Broker ──► Consumer
              （单点）
```

Broker 挂 = 业务挂。

### 5.2 单 Master 主从（基础高可用）

```
            Producer
               |
      +--------+--------+
      |                 |
   Broker-M --同步--> Broker-S
                (Slave 只读)
      |
   Consumer
```

Master 挂了：Producer 写不了，Consumer 仍可从 Slave 读 → 可用性提升但不完整。

### 5.3 多 Master 多 Slave + NameServer 集群（生产主流）

```
NameServer-1   NameServer-2   NameServer-3   （互不通信，每台都有完整路由）
       \            |             /
        +-----------+------------+
                    |
       +------------+------------+
       |                         |
   Broker-Group-A           Broker-Group-B
   M-A1 ──► S-A1            M-B1 ──► S-B1
   M-A2 ──► S-A2            M-B2 ──► S-B2
       |                         |
       +-----+--------------+----+
             |              |
         Producer       Consumer
```

- Topic 的 Queue 分布在 2 个 Broker Group → 单 Group 故障还能用一半队列
- NameServer 集群任挂一台不影响（无状态）
- Slave 在 Master 挂时只能读不能写 → 需 Dledger 才能自动主从切

### 5.4 Dledger 模式（4.5+ 自动故障切换）

```
Broker-Group 内 3 节点（必须奇数）：N1 (Leader)  N2  N3
                                          \      |     /
                                           Raft (Dledger)
```

写入需要至少半数节点 ACK 才返回成功。Leader 挂了自动选主。

**代价**：
- 至少 3 节点（不能 1 主 1 从）
- 选举期间（10s 内）不可写
- 多数派 ACK 比异步复制慢 ~20%

---

## 六、对比：RocketMQ vs Kafka vs RabbitMQ

| 维度 | RocketMQ | Kafka | RabbitMQ |
| --- | --- | --- | --- |
| 定位 | 业务消息 | 日志/流处理 | 协议丰富的传统 MQ |
| 单机 TPS | ~10w | ~17w | ~万级 |
| 注册中心 | NameServer | ZK / KRaft | 无（内置 Erlang 集群） |
| 存储模型 | **混合 CommitLog**，所有 Topic 共用 | **每 Topic-Partition 独立文件** | 内存 + 磁盘混合 |
| 顺序消息 | 严格顺序（Queue 内）| Partition 内有序，宕机后乱序 | 单队列单消费者 |
| 延迟消息 | 4.x 18 个固定级别 / 5.x 任意时间 | 不支持（需外部插件） | 死信交换机模拟 |
| 事务消息 | half + 事务回查 | 仅 producer 事务（broker 端） | 不支持 |
| 消息回溯 | 按时间戳 | 按 offset | 不支持 |
| 死信处理 | 内置 DLQ topic | 不支持 | DLX 死信交换机 |
| 协议 | 私有 + REST | 私有 | AMQP / STOMP / MQTT |

**选型口诀**：
- **业务消息**（订单、支付、事务） → RocketMQ
- **日志/埋点/流处理**（百万级吞吐） → Kafka
- **协议复杂、规模小**（金融遗留系统） → RabbitMQ

---

## 七、面试高频追问

**Q1：为什么 NameServer 节点之间互不通信？这样不会脑裂吗？**

不会，因为 NameServer **不存储一致性数据**——它的状态是"哪些 Broker 还活着"，由 Broker **主动向所有 NameServer 上报**得到。每台 NameServer 都是完整副本。客户端轮询任一台 NameServer 拉路由都能拿到全部信息。代价是某台 NameServer 短暂网络分区时，分区内的客户端可能拿到稍旧的路由——但 RocketMQ 容忍这种最终一致，由客户端故障规避兜底。

**Q2：Broker 挂了之后，发出去的消息会丢吗？**

分情况：
- **同步发送 + 同步刷盘 + 同步复制**：消息已落盘到 Master 和 Slave，Broker 挂了不丢
- **同步发送 + 异步刷盘**：可能丢失 PageCache 里未刷盘的数据（断电丢、Broker 进程挂不丢，因为 PageCache 由 OS 管理）
- **异步发送**：客户端 buffer 还没发出去就挂了 → 丢

**Q3：Producer 选 Queue 的负载均衡策略有哪些？**

默认 **轮询**，并自带 **故障规避**（`MQFaultStrategy`）：每次选完 queue 记录 latency，下次选 broker 时绕开"近期延迟过高/不可用"的 broker（默认规避时长根据 latency 动态计算，30ms 延迟 → 0ms 规避，3000ms 延迟 → 18 万 ms 规避）。

**Q4：一个 Queue 能被同组的多个 Consumer 同时消费吗？**

不能。**一个 Queue 同一时刻只能被同组的一个 Consumer 消费**——通过 Broker 端的分布式锁保证（顺序消费场景）或通过 Rebalance 机制保证（普通消费场景）。这是 RocketMQ 实现"队列内有序消费"的物理基础。

**Q5：Consumer 数量 > Queue 数量会怎样？**

**多余的 Consumer 永远收不到消息**（空闲）。所以扩容 Consumer 之前要先扩 Queue：`mqadmin updateTopic -n nameserver -c clusterName -t topic -r 32 -w 32`。

**Q6：Push 模式的"推"是真推吗？**

不是。RocketMQ 的 Push 底层是**长轮询的 Pull**：Consumer 发起 Pull，如果 Broker 没新消息就 hold 住请求最多 15s 不返回；新消息到达立即唤醒。这样既有 Push 的实时性，又能让 Consumer 自主控制速率（不会被压垮）。

**Q7：发送一条消息的耗时主要花在哪？**

```
1. 路由查询（命中本地缓存 ≈ 0；首次拉路由 ~5ms）
2. selectQueue（本地计算 ~0.1ms）
3. 网络往返（同机房 ~0.5ms）
4. Broker 写 PageCache（mmap，~0.1ms）
5. 刷盘等待（异步 ~0；同步 ~5~10ms）
6. 主从复制等待（异步 ~0；同步 ~1~3ms）
7. 网络回包 + 客户端解析（~0.5ms）
```

**总耗时**：异步刷盘异步复制 ≈ 1~2ms，同步刷盘同步双写 ≈ 10~15ms。

---

## 八、答题模板（60 秒话术）

> RocketMQ 架构有四个核心角色：**NameServer 是无状态的路由注册中心**，每台都是完整副本，节点之间互不通信，靠 Broker 主动心跳上报数据；**Broker 是消息存储与转发节点**，所有消息顺序写到 CommitLog，再异步生成 ConsumeQueue 索引，主从架构保证可靠性；**Producer 启动时拉一次路由缓存到本地**，发消息时按轮询 + 故障规避选 Queue，底层用 Netty 长连接 + opaque 假同步；**Consumer 默认 Push 模式，本质是长轮询的 Pull**，单 Queue 同组只能被一个消费者消费，offset 由 Broker 维护。
>
> 整套设计的核心权衡是：**用 AP 的 NameServer 换路由查询的低延迟**，**用混合存储 CommitLog 换写入吞吐**，**用主从异步复制换可用性**——金融级才会启用同步双写 + Dledger Raft，吞吐下降 30% 但能自动故障切换。

---

## 九、相关文档

- [存储机制](./存储机制.md) — CommitLog / ConsumeQueue / IndexFile / mmap / 零拷贝
- [刷盘与复制](./刷盘与复制.md) — 同步/异步刷盘 + 主从复制 + Dledger
- [生产者](./生产者.md) — Producer 启动、发送模式、重试、故障规避
- [消费者](./消费者.md) — Consumer 启动、Push/Pull、长轮询、Rebalance
- [消息可靠性](./消息可靠性.md) — 三阶段防丢失（生产/存储/消费）
