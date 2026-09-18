# MongoDB

> NoSQL 三巨头里**文档型数据库**的代表，互联网公司处理"半结构化数据 + 高写入 + 弹性 schema"场景的默认选项——日志埋点、用户画像、订单履约、IoT 设备数据、内容平台。
> 本篇要解决：
> ① **跟 MySQL / Redis / ES 的边界**——什么时候该用 MongoDB，什么时候不该
> ② **WiredTiger 存储引擎** + **B+ Tree 索引**——跟 InnoDB 的相同与不同
> ③ **副本集 (Replica Set)** 选举 + Oplog 复制 + 读写关注（Read/Write Concern）
> ④ **分片集群 (Sharded Cluster)**——片键怎么选才不踩"热点 / Jumbo Chunk / 单分片热写"三大坑
> ⑤ **多文档事务**（4.0 单分片 / 4.2 跨分片）—— 性能代价跟正确用法
> ⑥ 生产高频踩坑：连接风暴、内存爆、Oplog 追不上、片键选错只能重建集群

---

## 一、MongoDB 是什么 / 为什么要用

**MongoDB 是分布式文档型 NoSQL 数据库**——存储单元是 **BSON 文档**（类似 JSON，但带类型 + 二进制扩展），天生支持嵌套对象、数组、动态字段。

**vs MySQL（行存关系库）**：
- 关系库：固定 schema、强类型、JOIN 关联、ACID 事务。
- 文档库：动态 schema、嵌套结构（一次查询拿全）、水平分片更容易、4.0 才支持事务且代价高。

**vs Redis（KV 内存库）**：
- Redis：纯内存 + 单线程，主打缓存 / 计数 / 队列，非主存储。
- MongoDB：磁盘持久化 + 多线程，可作主存储，单机几 TB 没问题。

**vs Elasticsearch（搜索引擎）**：
- ES：倒排索引主打全文检索 + 聚合分析，事务弱、写入有 1s 延迟。
- MongoDB：B+ Tree 主打 OLTP 写入 + 简单查询，全文搜索弱（虽有 text 索引但不及 ES）。

**典型适用场景**：
- **日志 / 埋点 / 监控**：写多读少 + schema 飘忽（每次上线加字段）。
- **内容平台**：文章、评论、动态 → 嵌套结构天然契合。
- **商品 / SKU / 用户画像**：属性千变万化 → 用文档比 EAV 表干净。
- **IoT / 时序**（5.0 起有专门的 timeseries collection）。
- **游戏存档 / 订单状态机**：嵌套数组 + 子文档。

**不该用的场景**：
- **强一致 + 复杂事务**（银行账户、库存扣减）→ 用 MySQL。
- **跨表/跨集合 JOIN 多** → 用 MySQL。
- **极致 KV 缓存** → 用 Redis。
- **全文检索 / 复杂聚合分析** → 用 ES / ClickHouse。

---

## 二、数据模型

### 2.1 BSON 文档

```javascript
// MongoDB 文档示例
{
  "_id": ObjectId("65a1b2c3d4e5f6a7b8c9d0e1"),  // 主键，默认自动生成
  "user_id": NumberLong(100023),
  "name": "张三",
  "tags": ["VIP", "blue"],                        // 数组
  "address": {                                    // 嵌套对象
    "city": "上海",
    "geo": [121.4737, 31.2304]
  },
  "created_at": ISODate("2026-05-09T10:00:00Z")
}
```

**BSON vs JSON**：
- **B = Binary**：二进制编码，比 JSON 节省空间。
- 多了 `ObjectId / Date / NumberLong / Decimal128 / Binary` 等强类型。
- 单文档**最大 16 MB**（生产基本用不到这个上限，超过这个数说明数据建模错了）。

### 2.2 ObjectId（默认主键）

```
   4 字节 timestamp  +  5 字节 random  +  3 字节 counter
   ───────────────    ────────────       ──────────────
       秒级时间戳      机器+进程随机值    单调递增计数器
```

**特点**：
- **趋近递增**（高位是时间戳）→ B+ Tree 写入热点在最右节点（**写友好**），但**不严格单调**。
- 包含时间戳 → `_id.getTimestamp()` 能反推创建时间，省一个 created_at 字段。
- 12 字节固定长度，比 UUID(36) 紧凑。

### 2.3 集合 (Collection) 与数据库

```
Cluster
  └── Database (类似 MySQL 的 schema)
        └── Collection (类似 table，但无固定 schema)
              └── Document (类似 row)
```

**关键区别**：MongoDB 没有 schema 强约束，同一 collection 里的文档字段可以不一样（**但生产必须用 Schema Validation 锁住**，否则字段乱飞）。

```javascript
// 强 Schema 校验（4.0+）
db.createCollection("orders", {
   validator: {
      $jsonSchema: {
         bsonType: "object",
         required: ["order_id", "user_id", "amount"],
         properties: {
            amount: { bsonType: "decimal", minimum: 0 }
         }
      }
   },
   validationLevel: "strict",       // 写入必须通过
   validationAction: "error"        // 不通过直接拒绝
})
```

---

## 三、WiredTiger 存储引擎 ⭐

MongoDB 3.2 起默认存储引擎是 **WiredTiger**（替代了原来烂掉的 MMAPv1，老版本面试已经不考了）。

### 3.1 整体结构

```
   Application Thread
        │ insert/update/find
        ▼
   ┌──────────────────────────────────┐
   │  WiredTiger Cache (内存)          │  ← 默认 = (RAM - 1GB) × 50%
   │  ─────────────────────            │     生产再调
   │  - 数据 page（B+ Tree node）      │
   │  - 索引 page                      │
   │  - 锁表                           │
   └──────────────┬───────────────────┘
                  │ 脏页 dirty
                  │ 后台 evict / checkpoint
                  ▼
   ┌──────────────────────────────────┐
   │  Journal (WAL)                    │  ← 类似 InnoDB redo log
   │  顺序写文件，100ms / 100MB 触发    │
   │  fsync 决定 durability             │
   └──────────────┬───────────────────┘
                  │ Checkpoint (60s)
                  ▼
   ┌──────────────────────────────────┐
   │  Data Files (磁盘)                │
   │  collection-*.wt / index-*.wt     │
   │  (B+ Tree + Snappy/Zstd 压缩)     │
   └──────────────────────────────────┘
                  │
                  ▼
              OS PageCache
                  │
                  ▼
                磁盘
```

### 3.2 关键机制

**① B+ Tree 索引** —— 跟 InnoDB 一样：
- 数据页（leaf）按主键 `_id` 有序组织。
- 二级索引存的是 `_id`（不是物理偏移），跟 InnoDB **回表**机制一致。

**② Document Level 锁**（3.0+ 起）：
- 不再像老版本的 collection 锁、库锁、全局锁。
- WiredTiger 用 **MVCC + 乐观并发控制**——多个写操作只要不冲突就并发。

**③ 压缩**：
- 数据：`snappy`（默认，CPU 低） / `zstd`（4.2+，压得更狠）/ `zlib`。
- 索引：`prefix compression`（压公共前缀）。
- 比 InnoDB 默认无压缩省 60~70% 空间。

**④ Journal (WAL)**：
- 类似 redo log，所有写操作先追加到 journal。
- `j: true` 写关注下，**fsync 后**才返回客户端 → durability。
- 异常重启时回放 journal。

**⑤ Checkpoint**：
- 默认 60 秒一次（或 journal 满 2GB），把 dirty page 刷到数据文件。
- Checkpoint 之间的数据靠 journal 保证不丢。

### 3.3 内存管理（生产重灾区）

WiredTiger Cache **默认 = (RAM - 1GB) × 0.5**——一台 64G 机器只用 31.5G 给 Cache。

**为什么不全用？因为 MongoDB 严重依赖 OS PageCache**：
- WT Cache 装最热的数据 + 索引。
- 冷数据 evict 后落到 OS PageCache（mmap）—— 双层缓存。
- Heap / 网络 buffer / 排序临时文件 也吃内存。

**配置**：
```yaml
storage:
  wiredTiger:
    engineConfig:
      cacheSizeGB: 24            # 显式给定，别让它自动算
      directoryForIndexes: true  # 索引/数据分目录（可挂不同盘）
    collectionConfig:
      blockCompressor: snappy    # 默认
    indexConfig:
      prefixCompression: true
```

---

## 四、索引

### 4.1 索引类型

| 类型 | 命令示例 | 适用场景 |
| --- | --- | --- |
| **单字段** | `{user_id: 1}` | 等值/范围查询 |
| **复合 (Compound)** ⭐ | `{user_id: 1, created_at: -1}` | 多条件 + 排序 |
| **多键 (Multikey)** | 字段是数组时自动建 | `tags: ["a","b"]` 类查询 |
| **文本 (Text)** | `{content: "text"}` | 简单全文搜索（不如 ES） |
| **地理 (2dsphere)** | `{loc: "2dsphere"}` | 经纬度 / 范围 / 邻近 |
| **TTL** | `{created_at: 1}, {expireAfterSeconds: 86400}` | 自动过期（日志/会话） |
| **哈希** | `{user_id: "hashed"}` | 分片键（避免热点） |
| **唯一** | `{email: 1}, {unique: true}` | 唯一约束 |
| **部分 (Partial)** | `{partialFilterExpression: {status: "active"}}` | 只索引部分文档（省空间） |
| **稀疏 (Sparse)** | `{sparse: true}` | 只索引存在该字段的文档 |

### 4.2 复合索引 ESR 法则（**面试高频**）

复合索引字段顺序遵循 **Equality → Sort → Range**：

```
查询: user_id = 100 AND created_at > "2026-01-01" SORT BY created_at DESC

✅ 正确索引: { user_id: 1, created_at: -1 }
              └ Equality   └ Sort = Range（同字段）

❌ 错误索引: { created_at: -1, user_id: 1 }   // 范围在前，等值用不上
```

**为什么 Sort 必须紧跟 Equality**：
- B+ Tree 内同一 user_id 下的数据按 created_at 已经有序 → 直接顺序扫，无需排序。
- 如果中间夹了 range，sort 会触发**内存排序**（且默认 32MB 限制，超了报错）。

### 4.3 索引交叉 vs 覆盖索引

- **索引交叉 (Index Intersection)**：MongoDB 优化器有时会用两个独立索引求交集——但**通常比复合索引慢**，生产建议直接建复合索引。
- **覆盖索引 (Covered Query)**：查询字段全在索引里 + 不要 `_id` → 不回表，性能最高。

```javascript
// 索引: { user_id: 1, status: 1 }
db.orders.find(
  { user_id: 100, status: "paid" },
  { user_id: 1, status: 1, _id: 0 }     // _id: 0 关键，否则要回表
)
```

### 4.4 explain 必看字段

```javascript
db.orders.find({ user_id: 100 }).explain("executionStats")
```

| 字段 | 含义 |
| --- | --- |
| `winningPlan.stage` | `IXSCAN`（走索引）/ `COLLSCAN`（全表扫，**红线**） |
| `nReturned` | 实际返回的文档数 |
| `totalKeysExamined` | 扫描索引项数 |
| `totalDocsExamined` | 扫描的文档数（**回表数**） |
| `executionTimeMillis` | 总耗时 |

**理想情况**：`nReturned ≈ totalKeysExamined ≈ totalDocsExamined`。如果 `totalDocsExamined >> nReturned`，说明索引选择性差。

---

## 五、副本集 (Replica Set) ⭐

### 5.1 拓扑

```
                 ┌────────────────┐
                 │   Primary      │  ← 唯一接受写入
                 │   192.168.1.1  │
                 └───┬─────────┬──┘
              异步复制│         │ 异步复制
                     ▼         ▼
            ┌────────────┐  ┌────────────┐
            │ Secondary  │  │ Secondary  │  ← 可读（开 readPreference）
            │ 192.168.1.2│  │ 192.168.1.3│
            └────────────┘  └────────────┘

   或加 Arbiter（不存数据，只投票，省机器但不推荐金融场景）
```

**节点角色**：
- **Primary**：唯一可写。
- **Secondary**：异步从 Primary 拉 oplog 重放，可读（默认不可读，需配置 readPreference）。
- **Arbiter**：只参与选举投票，不存数据，不接受请求。**生产不建议用**——投票数对了但缺一份数据冗余。
- **Hidden / Delayed**：隐藏节点（不参与负载，做备份/分析）/ 延迟节点（晚 N 小时复制，防误操作）。

**奇数 + ≥3**：避免脑裂、保证 majority。

### 5.2 Oplog（操作日志）

**oplog 是副本集的命脉**——存在 `local.oplog.rs` 这个**capped collection**（固定大小，环形覆盖）。

```javascript
// oplog 一条记录
{
  ts: Timestamp(1715000000, 1),       // 操作时间戳（用于复制位点）
  t: NumberLong(5),                    // term（选举轮次）
  op: "u",                             // 操作类型 i/u/d/c/n
  ns: "shop.orders",                   // 命名空间
  o: { $set: { status: "paid" }},      // 操作内容
  o2: { _id: ObjectId(...) }           // 定位条件
}
```

**关键特性**：
- **幂等**：oplog 经过转换是幂等的（`update` 转成基于 `_id` 的 set）→ 重放安全。
- **顺序应用**：Secondary 按 ts 顺序重放。
- **容量决定容灾窗口**：oplog 容量 / 写入速率 = Secondary **能离线多久还追得回来**。

```yaml
# 默认值是磁盘 5%，生产至少要保证 24~72 小时窗口
replication:
  oplogSizeMB: 51200      # 50GB
```

### 5.3 选举（Raft 思想）

MongoDB 3.2 起选举协议升级为 **PV1（基于 Raft）**：
- Primary 失联超过 `electionTimeoutMillis`（默认 10s） → Secondary 发起选举。
- 候选人需获得 **majority** 投票（节点数过半 + 数据最新）。
- 数据更新（更高 ts）的优先当选 → 减少回滚。

**不可写窗口**：选举期间集群**短暂不可写**（典型 10~30s）。这是为什么所有客户端都需要支持**自动重连 + 重试**。

### 5.4 Read / Write Concern（必考）

#### Write Concern（写关注）—— 写到哪算成功

| 级别 | 含义 | 用途 |
| --- | --- | --- |
| `{w: 0}` | 不等任何确认 | 极少用，会丢数据 |
| `{w: 1}`（默认） | Primary 写入即返回 | 性能优先 |
| `{w: "majority"}` ⭐ | **多数节点确认** | **金融/订单必用** |
| `{w: "majority", j: true}` | 多数节点 + Journal fsync | 最强 |
| `{wtimeout: 5000}` | 等待超时（ms），超了报错但**不回滚** | 生产必带 |

**踩坑**：`majority` 没配 `wtimeout` → 副本集挂了 secondary，写阻塞**永远**。

#### Read Concern（读关注）—— 读到的数据可见性

| 级别 | 含义 |
| --- | --- |
| `local`（默认） | 读 Primary 最新（可能未复制到 majority，回滚后会消失） |
| `available` | 分片场景下读最新可见（可能脏读） |
| `majority` | 只读多数节点已确认的数据（**事务标配**） |
| `linearizable` | 线性一致性（性能差，少用） |
| `snapshot` | 事务专用，多文档快照 |

#### Read Preference（读偏好）—— 读哪个节点

```javascript
// 业务侧配置
db.orders.find().readPref("secondaryPreferred")
```

| 偏好 | 含义 |
| --- | --- |
| `primary`（默认） | 只读 Primary（强一致） |
| `primaryPreferred` | 优先 Primary，挂了读 Secondary |
| `secondary` | 只读 Secondary（**用于报表/分析卸载**） |
| `secondaryPreferred` | 优先 Secondary |
| `nearest` | 网络最近（多机房） |

**金句**：写 `w:majority` + 读 `primary + readConcern majority` = **强一致**；读 secondary = 性能但**最终一致**（**可能读到 1~5 秒前数据**）。

---

## 六、分片集群 (Sharded Cluster)

副本集解决**单机容量 + 高可用**，分片解决**水平扩展容量与吞吐**。

### 6.1 架构

```
                    ┌──────────────┐
                    │  Application │
                    └──────┬───────┘
                           │
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
    ┌──────────┐     ┌──────────┐     ┌──────────┐
    │  mongos  │     │  mongos  │     │  mongos  │  ← 路由层（无状态，可横扩）
    └─────┬────┘     └─────┬────┘     └─────┬────┘
          │                │                │
          └────────┬───────┴────────────────┘
                   │
          ┌────────┴────────────────────┐
          │                             │
          ▼                             ▼
   ┌─────────────────┐           ┌──────────────────┐
   │ Config Server   │           │  Shard 1..N      │
   │ (副本集)         │           │  每个 = 副本集    │
   │ 元数据：         │           │  - Primary       │
   │  - chunk 分布   │           │  - Secondary x2  │
   │  - 集群配置      │           │  存实际数据       │
   └─────────────────┘           └──────────────────┘
```

**三大组件**：
- **mongos**：路由层（无状态），收到请求→查 config server→路由到对应 shard。客户端连 mongos。
- **Config Server**（必须副本集）：存元数据（chunk 范围、集合 → shard 映射、平衡器锁）。**3.4 起强制副本集**，挂了集群没法路由新请求。
- **Shard**：真正存数据，每个 shard 必须是个副本集（除非测试单 mongod）。

### 6.2 片键 (Shard Key) —— 选错就全完

**Shard Key 决定数据如何分布到各个 shard**。一旦选定，4.4 之前**永久不能改**（4.4+ 才支持 reshardCollection 但代价巨大）。

#### 选片键三大目标

1. **基数高**（cardinality）—— 不同值多，否则切不开（如 `gender` 只有 M/F，不能当片键）。
2. **写入分散**（write distribution）—— 避免某个 shard 写爆，其他闲。
3. **查询尽量带片键**（targeted query）—— 不带片键的查询 = `scatter-gather`（广播给所有 shard），慢且贵。

#### 三种主流策略

**① Hashed Shard Key**（哈希片键）⭐

```javascript
sh.shardCollection("shop.orders", { user_id: "hashed" })
```

- 优点：写入完全均匀，无热点。
- 缺点：**范围查询变全广播**（`created_at > X` 要扫所有 shard）。
- 适用：用户表、订单表（按用户隔离查询）。

**② Ranged Shard Key**（范围片键）

```javascript
sh.shardCollection("logs.access", { create_at: 1, app_id: 1 })
```

- 优点：范围查询走单 shard。
- 缺点：**单调递增的片键 = 写热点**（所有新数据进最后一个 chunk）→ ObjectId / timestamp / 自增 ID **绝对不能直接当片键**。
- 修复：加一个高基数字段做组合，如 `{tenant_id: 1, create_at: 1}`。

**③ Compound Shard Key**（复合片键，**生产首选**）

```javascript
sh.shardCollection("shop.orders", { tenant_id: 1, user_id: 1, _id: 1 })
```

- 既能针对租户 / 用户做 targeted query，又避开了单字段热点。
- ESR 法则同样适用。

### 6.3 Chunk 与 Balancer

数据按片键被切成 **chunk**（默认 128MB，5.0 起从 64MB 调大），mongos 按 chunk 范围路由。

```
chunk-1:  user_id  [-∞, 1000)     → Shard A
chunk-2:  user_id  [1000, 2000)   → Shard A
chunk-3:  user_id  [2000, 3000)   → Shard B
...
```

**Balancer**（后台进程）周期检查各 shard chunk 数差异，触发迁移：
- 差异 ≥ 阈值（小集群 2 个 chunk，大集群 8 个）→ 迁移。
- 迁移期间源 + 目标都接受写，迁完再切元数据。

**生产常见踩坑**：
- **迁移影响线上**：白天关 balancer（设置 active window），夜间再开。
- **Jumbo Chunk**：单条记录或同片键值聚集 > 128MB → 不能迁 → 单 shard 越来越胖。修复：换片键（粒度更细）。

---

## 七、多文档事务

MongoDB 4.0 起支持**多文档 ACID 事务**（**单分片**），4.2 起支持**分布式事务**（跨 shard）。

### 7.1 用法

```javascript
const session = db.getMongo().startSession()
session.startTransaction({
  readConcern: { level: "snapshot" },
  writeConcern: { w: "majority" }
})
try {
  const orders   = session.getDatabase("shop").orders
  const accounts = session.getDatabase("shop").accounts

  orders.insertOne({ user_id: 100, amount: 100 })
  accounts.updateOne({ user_id: 100 }, { $inc: { balance: -100 }})

  session.commitTransaction()
} catch (e) {
  session.abortTransaction()
  throw e
}
```

### 7.2 代价（**很大**）

- 默认事务**最大 60 秒**（`transactionLifetimeLimitSeconds`）—— 跑不完直接 abort。
- 事务期间**持有写锁**，其它写阻塞。
- 跨分片事务用 **2PC（两阶段提交）** + 协调者（mongos），延迟翻倍。
- WiredTiger 维护事务快照（snapshot read concern），**Cache 内存压力大**。

### 7.3 用 vs 不用

✅ **用**：
- 必须保证多文档原子性的金融操作（账户转账）。
- 偶发的、明确的强一致需求。

❌ **不用**（90% 场景）：
- 高并发场景（事务性能远低于单文档操作）。
- 能用**单文档**搞定的（一个文档内嵌套子文档/数组，单文档天然原子）。
- 能用**应用层补偿/Saga**搞定的。

**资深建议**：MongoDB 事务是**兜底能力**，不是**主用模式**。能用单文档原子性 + 应用幂等就别开事务。

---

## 八、聚合管道 (Aggregation Pipeline)

MongoDB 的 SQL，**所有复杂查询/统计的核心**。

```javascript
db.orders.aggregate([
  { $match: { status: "paid", created_at: { $gte: ISODate("2026-05-01") }}},  // 过滤（先做，少数据）
  { $group: {                                                                  // 分组聚合
      _id: "$user_id",
      total: { $sum: "$amount" },
      cnt:   { $sum: 1 }
  }},
  { $sort:  { total: -1 }},                                                    // 排序
  { $limit: 100 },                                                             // Top N
  { $lookup: {                                                                 // 关联 users 表
      from: "users",
      localField: "_id",
      foreignField: "_id",
      as: "user"
  }},
  { $project: { user_id: "$_id", total: 1, cnt: 1, name: "$user.name" }}      // 整形字段
])
```

**核心 stage**：
| Stage | 含义 |
| --- | --- |
| `$match` ⭐ | 过滤（**永远放管道最前**，越早过滤越快） |
| `$project` | 选字段、改字段 |
| `$group` | 分组 + 聚合 |
| `$sort` / `$limit` / `$skip` | 排序/分页 |
| `$lookup` | 关联（**类似 LEFT JOIN，但很慢**，慎用） |
| `$unwind` | 展开数组（一行变多行） |
| `$facet` | 多管道并行（一次查询出多个统计维度） |

**性能要点**：
- `$match` + `$sort` 在管道开头时能用上索引，到了 `$group / $project` 之后就用不了了。
- `$lookup` 性能差（小表内存哈希连接），数据量大宁可改成两次查询应用层拼装。
- 32MB 内存限制——超出加 `allowDiskUse: true`（会很慢）。

---

## 九、参数 / 配置 / 取舍

### 9.1 生产 mongod.conf 推荐

```yaml
storage:
  dbPath: /data/mongo
  journal:
    enabled: true                # 必开
  wiredTiger:
    engineConfig:
      cacheSizeGB: 24            # 物理 64G，留 OS PageCache + 系统
      directoryForIndexes: true
    collectionConfig:
      blockCompressor: snappy    # CPU 友好；冷数据可换 zstd
    indexConfig:
      prefixCompression: true

systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logRotate: reopen
  verbosity: 0

net:
  bindIp: 0.0.0.0
  port: 27017
  maxIncomingConnections: 10000  # 默认 65536，连接数风暴源头，按客户端 pool 总和估

replication:
  replSetName: rs0
  oplogSizeMB: 51200             # 50GB，金融级 100GB

security:
  authorization: enabled         # 必开！不开 = 裸奔
  keyFile: /etc/mongo.key

operationProfiling:
  slowOpThresholdMs: 100         # 慢日志阈值
  mode: slowOp
```

### 9.2 客户端连接池（业务侧重灾区）

```yaml
# Java MongoClient
mongodb:
  uri: mongodb://user:pwd@host1:27017,host2:27017,host3:27017/?
       replicaSet=rs0
       &readPreference=primary
       &readConcernLevel=majority
       &w=majority
       &wtimeoutMS=5000
       &maxPoolSize=100          # 单实例最大连接数（默认 100）
       &minPoolSize=10
       &maxIdleTimeMS=60000
       &serverSelectionTimeoutMS=5000
       &connectTimeoutMS=3000
       &socketTimeoutMS=30000
       &retryWrites=true         # 4.0+ 默认开，必须 majority
```

**生产经验值**：单服务实例 maxPoolSize 100，10 个服务实例 = 1000 连接，加上别的业务方 → 容易把 mongod 怼到 `maxIncomingConnections` 上限。**部署 mongos 时一定要算总和**。

---

## 十、对比 / 选型

### 10.1 主流 NoSQL 横评

| 维度 | MongoDB | Cassandra | HBase | DynamoDB | TiDB |
| --- | --- | --- | --- | --- | --- |
| 数据模型 | 文档 | 宽列 | 宽列 | KV/文档 | 关系（NewSQL） |
| 一致性 | 强一致（默认）/可配 | 最终一致（默认） | 强一致 | 可配 | 强一致 |
| 事务 | 4.0 起 ACID | 仅轻量级 | 行级 | TX API | 完整 ACID |
| 水平扩展 | shard | DHT 自动 | Region 自动 | 自动 | Region 自动 |
| 写入吞吐 | 中高 | **极高** | 高 | 高 | 中 |
| 主用场景 | 通用文档/OLTP | 时序/物联网 | 海量分析 | 云原生 | 关系迁移 |

### 10.2 vs MySQL 决策表

| 决策因素 | 选 MongoDB | 选 MySQL |
| --- | --- | --- |
| schema 是否稳定 | 经常变 ✅ | 稳定 ✅ |
| 关联查询 | 少 ✅ | 多 ✅ |
| 事务复杂度 | 简单/无 ✅ | 复杂 ✅ |
| 嵌套结构 | 多 ✅ | 扁平 ✅ |
| 水平扩展 | 必须 ✅ | 可中途改造 ✅ |
| 运维生态 | 团队熟悉 MongoDB ✅ | 团队熟悉 MySQL ✅（占绝大多数） |

---

## 十一、生产踩坑（强制必有）

### 坑 1：片键选错，集群从此残废
**场景**：上线初期 `_id` 当片键（默认 ObjectId 趋近递增）→ 写入永远集中在最后一个 shard，其他 shard 闲。
**根因**：单调递增片键 = 写热点。
**修复**：
- 4.4 前：`mongodump` → 删 collection → 用新 hashed 片键重建 → `mongorestore`（停机数小时）。
- 4.4+：`reshardCollection`（仍然要数小时全量迁移 + 双写）。
**监控**：`sh.status()` 看每个 shard 的 chunk 数差异；`db.serverStatus().opcounters` 看每节点 QPS。

### 坑 2：Oplog 容量太小，Secondary 失联追不回来
**场景**：promotion 期间写入翻 10 倍 → Secondary 短暂网络抖动 30min 没追上 → oplog 已经被覆盖 → Secondary 进入 RECOVERING **永远回不来**。
**修复**：
- `db.printReplicationInfo()` 经常看 oplog 时间窗口（生产至少 24~72 小时）。
- 失联 secondary 用 `initial sync`（全量）或从其他 secondary 物理拷贝。
**监控**：oplog window < 12h 告警；replication lag > 60s 告警。

### 坑 3：内存爆，WT Cache 设错或没设
**场景**：默认 `cacheSizeGB` 自动算 = (64-1)/2 = 31.5G，但容器只给 mongod 16GB → 严重 OOM Kill。
**根因**：MongoDB 不感知 cgroup 内存（老版本），自动算用宿主机内存。
**修复**：
- 容器化部署**必须显式**配 `cacheSizeGB`（建议留 50% 给 OS PageCache）。
- 5.0+ 才正确感知 cgroup。

### 坑 4：连接风暴
**场景**：业务大版本发布同时 100 实例同时启动 → 每实例 maxPoolSize 100 → 一瞬间 10000 连接撞 mongos → mongos / mongod CPU 100%、文件描述符耗尽。
**修复**：
- 客户端 `minPoolSize` 别太大，启动时不预热满。
- `maxIncomingConnections` + `ulimit -n 1048576`。
- 部署多个 mongos（前面挂 LB），把连接打散。

### 坑 5：`$lookup` JOIN 拖死集群
**场景**：一个夜间报表任务 `$lookup users` 关联两亿条订单 → mongod CPU 跑满 6 小时。
**根因**：MongoDB `$lookup` 是 nested loop，没法并行（5.0 才优化但效果有限）。
**修复**：
- 对单次量大的 join，用 SQL on 数仓（**MongoDB → CDC → ClickHouse / Hive**）做。
- 业务侧分批拉两次再 merge。

### 坑 6：慢查询 / Missing Index
**场景**：上线新功能后某接口 P99 从 50ms 涨到 5s。
**排查**：`db.currentOp({ secs_running: { $gt: 1 }})` 抓现场；`db.collection.explain("executionStats")` 看 `COLLSCAN`；MongoDB Profiler 开 `slowOpThresholdMs: 100` 把慢 SQL 落库。
**修复**：建索引 + 注意 ESR 法则。

### 坑 7：事务长跑 60s 后被杀
**场景**：批量数据修复脚本开了一个事务跑 5 分钟 → 默认 60s 直接 abort，重试 3 次每次都白干。
**修复**：
- 调大 `transactionLifetimeLimitSeconds`（注意：开大了会让 WT Cache 长时间持有 snapshot，内存压力上升）。
- **拆批**：一批一千条，事务关，应用层幂等。

### 坑 8：写关注 wtimeout 没设，Primary 一直 hang
**场景**：副本集 1 个 secondary 挂了，剩 Primary + 1 secondary，`w: majority` = 2 → Primary 持续等不到第 3 个 ack → 业务写入超时雪崩。
**修复**：写关注**永远带** `wtimeoutMS`，超时报错让客户端兜底。

### 坑 9：Schema 不约束字段乱飞
**场景**：早期没开 Schema Validation → 几个团队不同写法（`amount` / `Amount` / `total`）共存于同一 collection → 报表全错。
**修复**：上线前一定开 `$jsonSchema validator`，新字段走评审。

### 坑 10：备份策略错误（mongodump 在分片集群上不一致）
**场景**：用 `mongodump` 备份分片集群 → 各个 shard 不是同一时间点的快照 → 恢复后跨 shard 数据对不上。
**修复**：
- 分片集群备份只能用：① 文件系统快照（LVM/EBS）+ 停 balancer；② Ops Manager / Cloud Backup（商业）；③ 各 shard secondary `mongodump` 然后协调时间点（弱方案）。
- **副本集**用 mongodump 没问题。

---

## 十二、面试高频追问

**Q1：MongoDB 跟 MySQL 怎么选？**
看：① schema 稳不稳；② 关联多不多；③ 事务复杂度；④ 嵌套结构多不多。文档型数据 + 弱事务 + schema 飘 → MongoDB；强事务 + 复杂关联 → MySQL。互联网业务订单/账户走 MySQL，日志/埋点/内容走 MongoDB 是最常见的分工。

**Q2：WiredTiger 跟 InnoDB 啥关系？**
都是 B+ Tree + WAL（InnoDB 叫 redo log，WT 叫 journal）+ MVCC。区别：① WT 默认开压缩（snappy），InnoDB 默认不开；② WT 用文档级锁 + MVCC 乐观并发，InnoDB 用行锁；③ WT cache 只装热数据 + 重度依赖 OS PageCache。

**Q3：副本集选举怎么发起？多久不可写？**
Primary 心跳超时（默认 10s 内 secondary 收不到心跳）→ Secondary 发起选举 → 拿到 majority 投票当选。期间集群**不可写**（典型 10~30s）。客户端必须配 `retryWrites=true` + 有重试逻辑。

**Q4：Oplog 是啥？大小怎么定？**
local 库下 capped collection，记录所有写操作。Secondary 拉取重放实现复制。容量 = 写入速率 × 容灾窗口（生产 24~72 小时）。`db.printReplicationInfo()` 看时间窗。

**Q5：写关注 majority + journal:true 实际上保证啥？**
**majority** = 多数节点 ack（即使 Primary 挂了，新 Primary 也有这条数据，不会回滚）；**j:true** = journal 已 fsync 落盘。两者一起 = **数据真的不会丢**。代价是延迟从 1ms 涨到 5~10ms。

**Q6：Read Preference secondary 会读到啥？**
**最终一致**——可能读到 1~5 秒前的旧数据（取决于复制延迟）。报表/分析负载卸载到 secondary 没问题；账户余额查询绝对不能 secondary。

**Q7：分片片键三大目标？**
① 基数高；② 写入分散；③ 查询带得上片键。单字段递增 ID 当片键 = 必爆。Hash 片键解决热点但牺牲范围查询。复合片键 `{tenant, user_id}` 是大多数场景平衡解。

**Q8：mongos 的角色？没了能跑吗？**
mongos 是无状态路由层，连客户端 + 查 config server + 路由到 shard。挂一个不影响（前置 LB），全挂集群没法用。**业务侧**永远连 mongos，不要直连 shard mongod。

**Q9：Config Server 挂了会咋样？**
3.4+ 必须副本集，挂一个没事。全挂：**已有 chunk 分布读元数据用本地缓存可以用一阵**，但**新的 chunk 迁移、新 collection 创建全部不行**。

**Q10：4.0 事务跟 4.2 分布式事务区别？**
- 4.0：副本集多文档事务（同一 shard 内）。基于 snapshot read concern + WT MVCC。
- 4.2：跨 shard 分布式事务，用 **2PC 两阶段提交**——协调者（mongos）发 prepare，所有 shard 锁住，全 OK 后 commit；任一 abort 全回滚。
- 性能：单 shard < 跨 shard 一个数量级（**所以非必要不开**）。

**Q11：什么时候用 `$lookup`？什么时候不用？**
小表 + 低 QPS + 偶发关联可以。**绝对不要**对两个大集合做 $lookup（nested loop，没并行），数据量大宁可应用层拼装或 ETL 到数仓。

**Q12：聚合管道 32MB 限制怎么办？**
`{ allowDiskUse: true }` —— 落盘临时文件，性能下降但不会失败。生产建议先 `$match` 过滤 + 合理 `$project` 减字段，从源头上少。

**Q13：怎么定位线上慢查询？**
- `db.currentOp()` 抓正在执行的慢操作。
- Profiler：`db.setProfilingLevel(1, { slowms: 100 })` → `db.system.profile` 落库。
- `mongotop` / `mongostat` 看实例负载。
- explain executionStats 看 `COLLSCAN` / 回表数。

**Q14：MongoDB 怎么备份？**
- 副本集：`mongodump` 即可（在 secondary 上跑，不影响线上）。
- 分片集群：必须 ① 文件系统快照（最佳）；② Ops Manager Cloud Backup；③ 各 shard 单独 dump 但要协调时间点。
- 大库恢复 = 灾难，建议**异地副本集 + Delayed 节点 24 小时**当软备份。

**Q15：MongoDB 跟 ES 一起用怎么分工？**
典型架构：**MongoDB 做主存储 + 写入入口**，CDC（Debezium / Mongo Stream）同步到 **ES 做全文搜索 / 复杂聚合**。MongoDB 强 OLTP，ES 强检索分析。两边职责分明。

**Q16：MongoDB 5.0 的 Time Series collection 解决了啥？**
专门优化时序数据：列存压缩（10x 节省）、自动桶聚合（按时间窗口压缩成一行）、TTL 自动过期。对比通用 collection，写入性能 2~3x、空间 10x。给 IoT / 监控指标用。

**Q17：复合索引 ESR 法则解释下？**
Equality → Sort → Range。等值字段在前（精确定位），排序字段紧跟（B+ Tree 内已排好），范围在后（范围缩小后还能走索引）。颠倒顺序就要内存排序或全表扫。

---

## 十三、答题模板（60 秒话术）

> "MongoDB 是分布式文档型 NoSQL 数据库，存储 BSON 文档，主打 schema 灵活 + 嵌套结构 + 水平扩展。互联网公司日志、埋点、内容、用户画像主要用它，强事务场景还是 MySQL。
>
> **存储引擎 WiredTiger**：B+ Tree + Journal（WAL）+ MVCC + 文档级锁，跟 InnoDB 思路一致；默认 snappy 压缩，**严重依赖 OS PageCache**——生产 cacheSizeGB 显式给 50% 物理内存。
>
> **副本集**：1 Primary + N Secondary，**异步**复制（拉 oplog 重放）。Primary 挂掉 10 秒内 Raft-like 选举，期间不可写。**写关注 w:majority + j:true** = 数据不会丢；**读关注 majority** = 读多数确认数据；**Read Preference secondary** = 最终一致，可读 1~5s 前数据。
>
> **分片集群**：mongos 路由层 + Config Server 元数据 + Shard 数据。**片键**选择决定一切——hash 片键避热点但失范围；范围片键能走范围查询但单调递增爆热点；**生产首选复合片键** {tenant_id, user_id}。Chunk 默认 128MB，Balancer 自动迁移。
>
> **索引**：B+ Tree，复合索引 **ESR 法则**（Equality → Sort → Range）。explain 重点看 IXSCAN/COLLSCAN 和 totalDocsExamined。
>
> **事务**：4.0 单分片 + 4.2 分布式 2PC，**默认 60 秒**上限，性能远低于单文档操作——**能用单文档原子性 + 应用幂等就别开事务**。
>
> **生产踩坑 TOP 3**：
> ① **片键选错**：单调递增 ID 当片键 = 写热点，重建集群代价巨大；
> ② **Oplog 太小**：Secondary 失联追不回来 → 必须保证 24~72 小时窗口；
> ③ **WT Cache 没显式设**：容器内自动算用宿主机内存 → OOM Kill。"

---

## 十四、相关文档

- [Middleware / RPC 原理](./RPC原理.md) — 跟 MongoDB Wire Protocol 的对比
- [MySQL / 架构总览](../MySQL/架构总览.md) — InnoDB vs WiredTiger 对照
- [MySQL / InnoDB 存储引擎](../MySQL/InnDB.md) — B+ Tree / 行锁
- [MySQL / 分库分表](../MySQL/分库分表.md) — 跟 MongoDB 分片选型对比
- [Distributed / CAP 与 BASE](../Distributed/CAP与BASE.md) — MongoDB 默认 CP，可调 AP
- [Distributed / 一致性算法](../Distributed/一致性算法.md) — MongoDB Raft（PV1）
- [Redis / 缓存与数据库双写一致性](../Redis/双写一致性.md) — MongoDB + Redis 缓存方案
- [Middleware / Elasticsearch](./es.md) — MongoDB CDC → ES 检索分工
