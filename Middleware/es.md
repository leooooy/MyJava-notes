# Elasticsearch

> 大厂中间件面试 **TOP 3** 必考——日志检索、商品搜索、APM、风控、推荐召回、向量检索全用它。
> 本篇要解决：
> ① ES 的 **集群架构 + 角色分工**——Master / Data / Coordinator / Ingest 各管什么
> ② **倒排索引 + Term Index + DocValues** 三件套，搜索为什么快、聚合为什么快
> ③ 一次 **写入 / 查询** 的完整流程（路由 → 主分片 → 副本 → refresh → flush）
> ④ **必/should/filter/term/match** 真正的差异，为什么 filter 能用缓存
> ⑤ ES 性能调优、生产踩坑（脑裂、慢查询、深分页、热分片、写入瓶颈）

---

## 一、Elasticsearch 是什么 / 为什么要用

**ES 是分布式搜索 + 分析引擎**，基于 **Apache Lucene** 之上做了集群化、RESTful API、JSON 文档模型。

**为什么不用 MySQL 做搜索**：
- MySQL `LIKE '%word%'` 不走索引 → 全表扫描，10w 行就慢。
- MySQL 没有分词、相关性评分、模糊匹配、聚合分析能力。
- ES：分词 + 倒排索引 + TF-IDF/BM25 评分，亿级文档毫秒响应。

**典型应用**：
- **日志/可观测**：ELK Stack / EFK（最广用）。
- **全文搜索**：商品搜索、文章搜索、知识库。
- **聚合分析**：实时报表、指标统计、APM（Skywalking、Elastic APM）。
- **向量检索**（ES 8.x 起）：RAG、相似商品推荐。

**vs 同类产品**：

| 维度 | Elasticsearch | Solr | OpenSearch | ClickHouse |
| --- | --- | --- | --- | --- |
| 定位 | 搜索 + 分析 | 搜索 | ES 7.10 fork（AWS） | OLAP 分析 |
| 实时写入 | 近实时（1s refresh） | 近实时 | 近实时 | 批量友好 |
| 全文检索 | **强** | 强 | 强 | 弱 |
| 聚合分析 | 中 | 弱 | 中 | **极强** |
| License | Elastic License 2.0 / SSPL | Apache 2.0 | Apache 2.0 | Apache 2.0 |
| 生态 | **极广** | 中 | AWS 生态 | 数仓主流 |

---

## 二、集群架构

### 2.1 节点角色（**面试必问**）

| 角色 | 配置 | 职责 |
| --- | --- | --- |
| **Master-eligible** ⭐ | `node.master: true` | 候选主节点。当选 Master 后管理集群状态（创建/删除索引、分片分配、节点上下线） |
| **Data** | `node.data: true` | **存储数据 + CRUD + 搜索 + 聚合** 实际计算 |
| **Ingest** | `node.ingest: true` | 写入前预处理（类似 Logstash 的 pipeline） |
| **Coordinator** | 上面三个全 false | 路由请求 + 收敛结果（无数据无管理） |
| **ML / Transform**（X-Pack） | — | 机器学习专用 |

**生产部署模式**：
- **小集群**（< 10 节点）：所有节点全角色。
- **中集群**（10-30）：3 个 Master-only 节点（避免脑裂） + N 个 Data 节点。
- **大集群**（30+）：3 Master + N Data + M Coordinator（专门做请求收敛）+ Ingest 独立。

### 2.2 集群状态

```
       ┌─────────────────────────────┐
       │   Master Node               │
       │   维护 Cluster State:        │
       │     - 索引 mapping           │
       │     - 分片位置 routing table │
       │     - 节点列表               │
       └────────┬────────────────────┘
                │ 同步广播
       ┌────────┴────────────┬────────────┐
       ▼                     ▼            ▼
   Data Node 1          Data Node 2   Coord Node
   ┌──────────┐         ┌──────────┐  ┌──────────┐
   │ Shard 0P │         │ Shard 0R │  │ 路由层    │
   │ Shard 1R │         │ Shard 1P │  │           │
   └──────────┘         └──────────┘  └──────────┘
   P=Primary 主分片  R=Replica 副本
```

集群健康状态：
- **Green**：所有 P + R 都可用。
- **Yellow**：P 都可用，部分 R 缺失。
- **Red**：有 P 不可用，**有数据丢失风险**。

### 2.3 分片（Shard）

**索引（Index）= 数据的逻辑容器**。物理上一个 Index 切成 N 个 **Shard**（默认 1，老版本 5），每个 Shard 是一个**完整的 Lucene 索引**。

```
Index "logs"  (8 primary shards × 1 replica)
   ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐
   │ P0  │ │ P1  │ │ P2  │ │ P3  │ │ P4  │ │ P5  │ │ P6  │ │ P7  │
   └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘
   ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐
   │ R0  │ │ R1  │ │ R2  │ │ R3  │ │ R4  │ │ R5  │ │ R6  │ │ R7  │
   └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘
```

**关键约束**：
- **Primary Shard 数量创建时定死**（写入路由用 `hash(_routing) % primary_count`，改了 routing 全乱）。
- **Replica 可动态调整**。
- 单 Shard 推荐 **10~50GB**，超过 50GB 查询/恢复都会变慢。

### 2.4 Master 选举

ES 7.x 起用 **Raft-like 协议**（取代老的 Zen Discovery）：
- `discovery.seed_hosts`：初始候选列表。
- `cluster.initial_master_nodes`：首次启动的 Master 候选名单。
- 选举条件：超过半数 Master-eligible 节点投票。

**脑裂预防**：必须 Master-eligible 节点 ≥ 3 且为奇数（quorum = N/2+1）。

---

## 三、底层数据结构（Lucene 三件套）⭐

ES 写入文档 → 生成多种数据结构存到 Segment 文件，每种结构服务一类查询。

### 3.1 倒排索引（Inverted Index）—— 全文检索的基石

**正排索引**（普通 DB）：`docId → 内容`，"找文档 100 的内容"快。
**倒排索引**：`词 → docId 列表`，"找包含 'java' 的文档"才快。

```
分词后:
  doc 1: "elasticsearch is fast"     →  ["elasticsearch", "fast"]
  doc 2: "java is fast"               →  ["java", "fast"]
  doc 3: "elasticsearch and java"     →  ["elasticsearch", "java"]

倒排索引:
  term            posting list
  ─────────────  ────────────────────────
  elasticsearch  [doc1, doc3]
  java           [doc2, doc3]
  fast           [doc1, doc2]
```

**posting list 内容**：除了 docId，还存：
- 词频（TF）—— 用于 BM25 评分。
- 位置（Position）—— 短语查询。
- 偏移（Offset）—— 高亮。
- payload —— 自定义信息。

### 3.2 Term Index（FST）—— 加速 term 查找

**问题**：百万 term 在 term dictionary 里找太慢。
**解法**：把所有 term 的**前缀**抽出来构建 **FST（Finite State Transducer）**——一种压缩前缀树，**全部驻留 JVM 内存**。

```
查询 "elastic":
  ① Term Index (FST 内存) → 定位到磁盘 block 偏移
  ② Term Dictionary (磁盘) → 精确找到 "elasticsearch"
  ③ Posting List (磁盘) → 拿到 docId 列表
```

FST 比 Trie 节省 5-10 倍内存，是 Lucene 的核心优化点。

### 3.3 DocValues —— 列式存储，聚合/排序加速器

**问题**：倒排索引按 term 组织，但**聚合 / 排序**要按字段值访问（"按 price 升序" / "groupby category"），倒排索引很慢。

**解法**：DocValues = **按字段的列式存储**（类似 ClickHouse / Parquet），文档→字段值的反向映射。

```
正排存储 (DocValues):
  field "price":
    doc1 → 100
    doc2 → 200
    doc3 → 150
  field "category":
    doc1 → "book"
    doc2 → "phone"
    doc3 → "book"
```

**用 mmap 映射磁盘**，操作系统 PageCache 命中后接近内存速度。

**坑**：`text` 字段默认不开 DocValues（要开 `fielddata`，吃 JVM 堆，**生产禁用**）。聚合用 `keyword` 字段。

### 3.4 Stored Fields —— 原始文档存档

`_source` 字段存原始 JSON，用 LZ4 压缩。返回原文档时读这里。

### 3.5 Segment（段）

**Lucene 写入的物理单元**：每次 refresh 生成一个**不可变** Segment，包含上面所有结构。

```
Index Shard:
  └── Lucene Index
        ├── segment_1   (倒排 + Term Index + DocValues + Stored)
        ├── segment_2
        ├── segment_3
        └── ...
```

**Segment 不可变**带来的好处：
- ✅ 无锁读（读不需要并发控制）。
- ✅ 缓存友好（segment 一旦生成不会变）。

**带来的坑**：
- 文档**删除/更新** = 标记 + 新 segment（**不真删**）。
- Segment 越来越多 → **Segment Merge**（合并小段为大段，回收已删除）。

---

## 四、写入流程（**面试必问**）

```
   Client
     │
     │ POST /logs/_doc/123 {"msg":"hello"}
     ▼
   Coordinator Node
     │ 1. 算路由：shard = hash(_routing or _id) % primary_count
     │ 2. 找到 Primary Shard 在哪个 Data Node
     ▼
   Primary Shard (Node A)
     │ 3. 写 Translog (顺序写磁盘，保证 durability)
     │ 4. 写 In-Memory Buffer
     │ 5. 并发同步给所有 Replica
     │
     ├──────────────► Replica Shard (Node B)
     │                   ├── 写 Translog
     │                   └── 写 In-Memory Buffer
     │
     ◄────────────── Replica ack
     │
     │ 6. 返回 Coordinator
     ▼
   Client (200 OK)

   ─── 异步后台 ───
   ① refresh (默认 1s)：In-Memory Buffer → 新 Segment（OS PageCache）
                        → 此时数据可被搜索（"近实时" 1s）
   ② flush  (默认 30 min 或 translog 满 512MB):
                        → fsync segment 到磁盘
                        → 清空 translog
   ③ merge  (后台合并小 segment → 大 segment)
```

### 4.1 Refresh：1 秒"近实时"的奥秘

ES 不是实时的，写入到能搜到默认 **1 秒**。原因：
- 频繁 fsync 性能极差。
- ES 每秒把 In-Memory Buffer 数据**写到 Page Cache**（生成 Segment）→ 立即可搜。
- Page Cache 数据丢失风险低（OS 崩溃才会，ES 异常不会）。

**调整 refresh_interval**：

```json
PUT logs/_settings
{ "refresh_interval": "30s" }       // 写入吞吐 ↑↑，但搜索可见延迟到 30s
```

**写入大量数据时建议关闭**（`-1`），完成后再打开 + 主动 refresh。

### 4.2 Translog：保证 durability

像 MySQL 的 redo log。写入 Primary 立即顺序追加 translog → 即使进程崩，重启时回放 translog 恢复。

**translog flush 策略**：
- `index.translog.durability: request`（默认）：每个请求 fsync translog，最强但最慢。
- `index.translog.durability: async`：每 5s 异步 fsync，性能 ↑ 但可能丢 5s 数据。

### 4.3 Flush：真正落盘

- 内存 segment → 磁盘 fsync。
- 清空 translog。
- 默认 30 分钟或 translog 达到 512MB 触发。

### 4.4 Segment Merge

后台线程合并小 segment 为大 segment：
- 回收已标记删除的文档。
- 减少 segment 数量（segment 越多查询越慢，因为要查每个 segment 后合并）。
- 高 IO 操作，限制 merge 并发避免影响线上：
  ```json
  index.merge.scheduler.max_thread_count: 1     // SSD 用 cpu/2，HDD 用 1
  ```

---

## 五、查询流程

### 5.1 Query Then Fetch（标准两阶段）

```
   Client
     │ GET /logs/_search {"query":...}
     ▼
   Coordinator
     │ ① Query 阶段：分发请求到所有相关分片（每个 P 或 R 选一个）
     │
     ├─► Shard 0 ──► 返回 [docId, _score, sort_value] (Top N，无原文)
     ├─► Shard 1 ──► 返回 [docId, _score, sort_value]
     └─► Shard N ──► 返回 [docId, _score, sort_value]
     │
     │ ② Coordinator 合并所有 shard 结果，全局排序，截取最终 Top N
     │
     │ ③ Fetch 阶段：根据最终 docId 列表，回各 shard 拉 _source
     │
     ├─► Shard 0 ──► 返回完整文档
     ├─► Shard 1 ──► 返回完整文档
     │
     ▼
   返回 Client
```

**为什么两阶段**：避免每个分片都返回完整文档（`_source` 大）→ 第一阶段只传元数据。

### 5.2 GET by ID（单文档查询）

直接用 `_routing` 算分片 → 单分片查询，无需 scatter-gather。

---

## 六、查询语法核心（**面试必问**）

### 6.1 must / must_not / filter / should

| 子句 | 行为 | 评分 | 缓存 |
| --- | --- | --- | --- |
| **must** | 必须匹配（AND） | ✅ 计算并影响总分 | ❌ |
| **must_not** | 必须不匹配（NOT） | — | ❌ |
| **filter** ⭐ | 必须匹配，但**不评分** | ❌ 不参与 | ✅ **缓存（Bitset）** |
| **should** | 至少匹配 N 个（OR / 加分） | ✅ | ❌ |

**面试重点**：
- 不需要相关性评分的过滤条件（如 `status=active`、`age>18`）**永远用 filter**，享受缓存 + 性能高。
- `must` 用在需要算评分的全文匹配。

```json
{
  "bool": {
    "must":   [{ "match": { "title": "elasticsearch" }}],   // 评分
    "filter": [
      { "term":  { "status": "active" }},                   // 不评分，缓存
      { "range": { "price": { "gte": 100 }}}
    ]
  }
}
```

### 6.2 term vs match（**必问**）

| 维度 | term | match |
| --- | --- | --- |
| 分词 | ❌ 不分词，字面匹配 | ✅ 用字段的 analyzer 分词 |
| 字段类型 | `keyword` / 精确字段 | `text` / 全文字段 |
| 用途 | 状态、ID、tag、标签 | 文章正文、标题搜索 |

**踩坑**：`term` 查 `text` 字段经常查不到——因为存的是分词后的 token，而 term 不分词。

```
text "Hello World" → analyzer 分词 → ["hello", "world"]
term: "Hello World"  ❌ 找不到（小写化 + 字面）
term: "hello"        ✅ 找到
match: "Hello World" ✅ 分词后查 hello / world
```

### 6.3 query_string / multi_match / dis_max

- `multi_match`：一个 query 查多字段。
- `dis_max`：取最高分字段（避免多字段重复加分）。
- `query_string`：Lucene 语法直查（支持 AND/OR/NOT）—— 给运维/开发用，不要直接暴露给前端（注入风险）。

### 6.4 聚合（Aggregation）

```json
{
  "size": 0,                                  // 不要文档，只要聚合
  "aggs": {
    "by_category": {
      "terms": { "field": "category.keyword" },
      "aggs": {
        "avg_price": { "avg": { "field": "price" } }
      }
    }
  }
}
```

ES 聚合分两种：
- **Bucket**（分组）：terms / range / date_histogram。
- **Metric**（计算）：sum / avg / min / max / cardinality / percentile。

---

## 七、生产调优

### 7.1 Mapping 设计

```json
{
  "mappings": {
    "properties": {
      "log_msg":  { "type": "text", "analyzer": "ik_max_word" },
      "user_id":  { "type": "keyword" },                              // 不分词，能 term/aggregation
      "level":    { "type": "keyword" },
      "ts":       { "type": "date", "format": "epoch_millis" },
      "ip":       { "type": "ip" },
      "geo":      { "type": "geo_point" }
    }
  }
}
```

**关键决策**：
- 全文搜索 → `text` + analyzer。
- 精确匹配/聚合/排序 → `keyword`。
- 数字范围 → `long` / `double` / `date`。
- **关闭无用功能省空间**：`"index": false`（不索引）、`"doc_values": false`（无聚合需求）。
- 用 `dynamic: strict` 禁止动态字段爆炸。

### 7.2 分片规划

| 场景 | 分片数 | 备注 |
| --- | --- | --- |
| 日志（按天滚动） | 1 P + 1 R | 按 `logs-2026.05.01` 命名，按天/月分索引 |
| 商品搜索 | 3-5 P + 1 R | 按业务量预估总数据，每分片 < 50GB |
| 大数据量分析 | 总数据 / 30GB | 不要超过 1024 分片 |

**经验法则**：
- 每个分片 10~50 GB（深分页/恢复友好）。
- 每节点 < 600 个分片（Cluster State 元数据成本）。
- Heap 1GB 大约支撑 20 个分片。

### 7.3 写入吞吐优化

```yaml
# 索引级
index.refresh_interval: 30s            # 牺牲实时性换吞吐
index.number_of_replicas: 0            # 大批量导入时先关副本，导完再开
index.translog.durability: async       # 5s 异步 fsync（接受丢 5s）
index.translog.flush_threshold_size: 2gb

# Bulk 请求
POST _bulk                             # 单次 5-15MB，10~30 文档/批
```

### 7.4 查询性能

- **filter 替代 must**（不需评分时）。
- **routing 优化**：写入和查询用同 routing key（如 user_id），查询只打一个分片。
- **避免 wildcard "*xxx*"**：开头通配符不走索引。
- **避免 deep pagination**（详见踩坑）。
- **聚合用 keyword 字段**，禁用 fielddata。

### 7.5 JVM 与机器配置

- **Heap 不超过 30GB**（compressed oops 阈值 + 堆越大 GC 越慢）。
- **Heap = 物理内存 50%**（其余给 OS PageCache，DocValues / Segment 全靠它）。
- 用 G1GC（ES 8.x 默认）。
- SSD 必备。

---

## 八、生产踩坑

### 坑 1：脑裂（Split Brain）

**场景**：集群网络分区，两边各选 Master → 数据不一致。
**修复**：
- Master-eligible 节点 ≥ 3 且**奇数**（quorum = N/2+1）。
- ES 7+ 用 Raft 已大幅缓解，但 `discovery.seed_hosts` 配错仍可能脑裂。

### 坑 2：深分页（from + size）撑爆内存

**场景**：`GET /logs/_search?from=10000&size=10`。
**根因**：每个 Shard 都返回 from+size=10010 条 → Coordinator 收 10010×N 条 → OOM。
**修复**：
- ES 默认禁止 from + size > 10000（`index.max_result_window`）。
- 用 **`search_after`**（基于 sort 的 cursor，支持深翻）。
- 用 **`scroll`**（导出场景，会持有快照）。
- 用 **PIT (Point In Time)** + search_after（ES 7.10+ 推荐）。

### 坑 3：mapping 爆炸（Field 数太多）

**场景**：`dynamic: true` + 业务给 ES 写动态字段（如 `attr_key1, attr_key2, ...`）→ 字段数千、Cluster State 巨大、Master 卡死。
**修复**：
- `index.mapping.total_fields.limit: 1000`（默认 1000，监控告警）。
- `dynamic: strict` 禁止动态字段。
- KV 数据用 nested 类型或扁平化。

### 坑 4：热点分片（Hot Shard）

**场景**：日志按天 routing，但今天的 shard 写入量 100x 历史 → 单分片 IO 打爆。
**修复**：
- 用 ILM（Index Lifecycle Management）+ Rollover：滚动到新索引而不是堆积到一个分片。
- routing 别用时间，用业务 key（user_id）。

### 坑 5：fielddata 撑爆 Heap

**场景**：text 字段做聚合 → ES 用 fielddata（堆内存里搞列式数据）→ Heap 爆 → OOM。
**修复**：
- 聚合永远用 `keyword` 字段（自动启用 DocValues，磁盘 + PageCache）。
- 实在要 text 聚合，用 `multi_field`：`title.text` + `title.keyword`。

### 坑 6：慢查询拖死整个集群

**场景**：一个高 cardinality 聚合 → CPU 100% → 整个 Data Node 失联 → 雪崩。
**修复**：
- **Search 队列拒绝**：`thread_pool.search.queue_size: 1000`（满了拒绝新请求）。
- **断路器**：`indices.breaker.request.limit: 60%`（请求级别内存上限）。
- 慢查询日志：`index.search.slowlog.threshold.query.warn: 1s`。

### 坑 7：写入翻倍（refresh 频繁）

**场景**：refresh_interval=1s + 持续高写入 → segment 数爆炸 → merge 跟不上 → IO 打爆。
**修复**：调大 refresh 到 30s 或 60s。

### 坑 8：translog 设 async 导致丢数据

**场景**：`index.translog.durability: async` 提升写入速度，但断电丢 5s 数据。
**修复**：金融业务保持 `request`（默认）。日志 / 监控可接受 async。

### 坑 9：升级跨大版本崩

**场景**：从 6.x 直升 8.x → mapping 类型变化（type 移除）、API 不兼容。
**修复**：必须按 `6.x → 7.最新 → 8.x` 路径升级，每步重启验证。

### 坑 10：分片数定死后改不动

**场景**：上线后发现分片不够 → 不能直接改 number_of_shards。
**修复**：
- **Reindex API**：建新索引（更多分片）+ 数据迁移 + 别名切换。
- **Split / Shrink API**：按倍数拆/合（限制比较多）。

---

## 九、面试高频追问

**Q1：ES 为什么这么快？**
- **倒排索引**：term → docId 列表 O(1)，不像 SQL `LIKE` 全表扫。
- **Term Index (FST)**：term 查找索引常驻内存。
- **DocValues**：聚合/排序用列式存储，操作系统 PageCache 命中。
- **分布式分片**：水平扩展，并行查询。
- **Segment 不可变**：无锁读、缓存友好。

**Q2：ES 集群有哪些节点角色？**
Master（管理）/ Data（存储+计算）/ Coordinator（路由+合并结果）/ Ingest（预处理）。生产中 Master-only 节点要 3 个奇数防脑裂。

**Q3：ES 是不是实时的？**
**近实时（NRT，1 秒）**。写入 → In-Memory Buffer → 1s 后 refresh 到 OS PageCache（Segment）→ 可被搜索。不是真实时是因为频繁 fsync 性能太差。

**Q4：分片是什么？分片数怎么定？**
分片 = 索引水平切分单元，物理上是一个 Lucene 索引。Primary 数创建时定死（写入路由依赖），Replica 可动态调。建议 10~50GB/分片。

**Q5：写入流程？怎么保证可靠性？**
Coordinator 路由 → Primary 写 translog + buffer → 同步 Replica → 都 ack 后返回。可靠性靠 **translog**（顺序追加 + fsync），即使崩了重启回放。

**Q6：refresh / flush / merge 区别？**
- refresh：内存 buffer → Segment（OS PageCache），1s 默认，可搜索但未落盘。
- flush：Segment fsync 到磁盘 + 清 translog，30min 或 translog 满 512MB。
- merge：后台合并小段为大段，回收已删除文档。

**Q7：term 和 match 区别？**
- term：不分词字面匹配，用 keyword 字段，精确查。
- match：用字段的 analyzer 分词后匹配，用 text 字段，全文搜索。

**Q8：filter vs must？**
- must：必须匹配 + 算评分 + 不缓存。
- filter：必须匹配 + **不评分** + **缓存（Bitset）**。**不需评分一定用 filter**（性能高 + 缓存）。

**Q9：怎么解决深分页？**
- 业务限制 from + size < 10000。
- 用 `search_after`（基于上次最后一个 sort value 翻页）。
- 用 PIT (Point In Time) + search_after。
- 导出用 scroll。

**Q10：怎么避免脑裂？**
Master-eligible ≥ 3 且奇数；ES 7+ 用 Raft 选举（quorum）；7.x 起强制 `cluster.initial_master_nodes` 显式指定首次启动的候选名单。

**Q11：text 字段怎么聚合？**
text 字段聚合需 fielddata（吃 Heap）。生产做法：定义为 **multi_field**：

```json
{
  "title": {
    "type": "text",
    "fields": { "keyword": { "type": "keyword", "ignore_above": 256 }}
  }
}
```

聚合用 `title.keyword`，搜索用 `title`。

**Q12：怎么做日志按天切分？**
- ILM（Index Lifecycle Management）+ Rollover：定义滚动条件（大小/时间/文档数），到期自动建新索引。
- 别名固定写入入口：`logs-write` → 当前活跃索引；`logs-read` → 所有历史索引。

**Q13：DocValues 是什么？为什么能加速聚合？**
DocValues 是**按列存储**的数据结构（mmap 文件），文档→字段值的反向映射。聚合/排序需要按字段访问所有文档的值，列式存储顺序读 PageCache 命中率高，比倒排索引适合。

**Q14：怎么排查慢查询？**
- 开慢查询日志：`index.search.slowlog.threshold.query.warn: 1s`。
- `_search?profile=true`：返回每个 shard 各阶段耗时。
- `_nodes/hot_threads`：看哪个线程在烧 CPU。
- 检查 mapping、查询语句、分片数、PageCache 命中率。

**Q15：ES 的事务怎么搞？**
**ES 不支持事务**——只支持单文档原子性（_version 乐观锁）。需要事务请用 RDBMS。

**Q16：怎么做主从同步（双中心）？**
- CCR (Cross-Cluster Replication)：商业版功能，A 集群同步到 B 集群。
- 应用层双写。
- Logstash / 自研双写。

**Q17：ES 8.x 的向量检索？**
ES 8.x 内置 **dense_vector** 字段 + kNN search（近似算法 HNSW）→ RAG / 推荐召回。性能不如专用向量库（Milvus / Pinecone）但够用。

---

## 十、答题模板（60 秒话术）

> "ES 是基于 Lucene 的分布式搜索 + 分析引擎，亿级文档毫秒响应，全文搜索、日志分析、实时聚合、向量检索都用它。
>
> **架构**：节点角色 Master（管元数据）/ Data（存数据）/ Coordinator（路由+合并）/ Ingest（预处理）。索引切成 N 个 Primary Shard（创建定死）+ Replica（可动态加），每个 Shard 是一个完整 Lucene 索引。
>
> **底层数据结构**有三件套：
> ① **倒排索引**：term → docId 列表，全文检索的核心。
> ② **Term Index (FST)**：常驻内存的前缀树，加速 term 查找。
> ③ **DocValues**：列式存储的字段值，加速聚合排序，靠 mmap + PageCache。
>
> **写入流程**：路由到 Primary Shard → 顺序写 translog（保 durability）+ In-Memory Buffer → 同步到 Replica → ack。后台异步：**1s refresh** 把 buffer 变 Segment 到 PageCache（即可搜索，**近实时**），**30min flush** fsync 到磁盘清 translog，后台 **merge** 合并小段。
>
> **查询流程**：Query Then Fetch 两阶段。Query 阶段广播所有相关分片返回 [docId, score]，Coordinator 合并排序取 Top N，Fetch 阶段拉完整 _source。
>
> **查询语法关键**：
> - **filter** 不评分 + 缓存 → 不需评分一定用它（status / range / term 等）。
> - **must** 评分 + 不缓存 → 全文匹配。
> - **term** 不分词，配 keyword；**match** 分词，配 text。
>
> **生产踩坑 TOP 3**：
> ① **深分页**：from+size 默认上限 10000，用 search_after 或 PIT。
> ② **fielddata 爆 Heap**：text 字段不要聚合，用 keyword + DocValues。
> ③ **mapping 爆炸**：动态字段不控制 → Cluster State 巨大 → Master 卡死。`dynamic: strict` + `total_fields.limit`。"

---

## 十一、相关文档

- [Middleware / 网络IO模型](../Network/网络IO模型.md) — ES 集群节点用 Netty 通信
- [MQ / 存储机制](../MQ/存储机制.md) — Segment / mmap 思路类似 RocketMQ CommitLog
- [Distributed / CAP 与 BASE](../Distributed/CAP与BASE.md) — ES 是 AP（默认）
- [Distributed / 一致性算法](../Distributed/一致性算法.md) — ES 7+ Master 选举类 Raft
- [Distributed / 一致性哈希](../Distributed/一致性哈希.md) — 跟 ES `hash(routing) % shard` 的区别
- Project / 性能优化 — ES 慢查询排查实战
