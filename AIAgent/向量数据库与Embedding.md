# 向量数据库与 Embedding

> 引子：向量库选型是大厂面试 RAG 题的"第二个高地"——前面 [RAG](RAG检索增强生成.md) 讲完了，紧跟着就是：
>
> ① **Milvus / pgvector / ES dense_vector / Redis 怎么选**？数据量 100 万、1 亿、10 亿三个档位边界在哪？
> ② **HNSW / IVF / DiskANN 三个索引算法**到底什么原理、什么场景用哪个？参数 `ef`、`M`、`nlist`、`nprobe` 怎么调？
> ③ **1000 万 × 1024 维要多少内存**？怎么用量化（PQ / SQ / BQ）压到 1/4？
> ④ **元数据过滤**（pre-filter vs post-filter）的性能陷阱在哪？
>
> 这一篇是工程师问"你们生产怎么部署的"必答内容。

---

## 一、向量库的本质问题：高维近邻搜索

### 1.1 为什么不能 SQL 查找

向量检索的目标是：在 **N 个 d 维向量** 中找出与 Query 向量最接近的 Top-K（按余弦 / 欧氏距离）。

**朴素方案**：暴力计算所有 N 个向量与 Query 的距离。
- 100 万 × 1024 维 → 10 亿次浮点乘加 / 秒，**单次查询 200-500ms**
- 1 亿 × 1024 维 → 单次 20-50 秒，**生产不可用**

**ANN（Approximate Nearest Neighbor）** 算法：用空间换时间，建索引让查询从 `O(N)` 降到 `O(log N)` 或更优，**牺牲少量精度**（典型 95-99% 召回率）。

### 1.2 距离度量

| 度量 | 公式 | 适用 |
|---|---|---|
| **余弦相似度** | `cos(θ) = a·b / (|a||b|)` | 文本 Embedding（最常用） |
| **欧氏距离** | `√Σ(aᵢ-bᵢ)²` | 图像 / 推荐系统 |
| **内积** | `Σ aᵢbᵢ` | **归一化后等价余弦** / 性能最优 |

> ⚠️ **生产坑**：所有向量必须**归一化**到单位长度（`norm=1`）后存储 + 查询，这样**内积 = 余弦**，向量库可以用更快的内积算法。OpenAI / BGE 默认都是归一化的，但**自部署模型必须显式 `normalize_embeddings=True`**。

---

## 二、三大索引算法

### 2.1 HNSW（Hierarchical Navigable Small World）

**原理**：多层图结构，每层是一个稀疏图。从顶层入口开始，贪心走到最近邻；在每层递归下沉，直到底层（包含全量节点）。

```
                  入口
                    ●
                  / | \
        Layer 2  ●   ●   ●          ← 稀疏，长跳
                / \ / \ / \
        Layer 1 ● ● ● ● ● ● ●         ← 中等密度
               /\/\/\/\/\/\/\
        Layer 0 ●●●●●●●●●●●●●●●  ← 全量节点
```

**参数**：
| 参数 | 含义 | 默认 | 调优 |
|---|---|---|---|
| `M` | 每层每节点的最大邻居数 | 16 | **16-32**：值大召回高、索引大 |
| `ef_construction` | 建索引时探索数 | 200 | 200-500：建得越细查询越准 |
| `ef_search` | 查询时探索数 | 100 | **50-200**：在线可调，召回 vs 延迟权衡 |

**优点**：召回率高（95%+）、查询快、支持动态增量插入。

**缺点**：内存开销大（图结构常驻），单节点容量受限。

**适用**：< 1 亿向量、内存够用、需要高召回率。**主流向量库默认算法**（Milvus / Qdrant / pgvector / Weaviate）。

### 2.2 IVF（Inverted File Index）

**原理**：先对全量向量做 K-means 聚类（典型 `nlist=4096` 个簇），查询时只检索最近的 `nprobe` 个簇。

```
全量向量 → K-means → 4096 个聚类中心
                        │
查询时：  Query → 计算与 4096 中心的距离 → 选最近的 32 个簇
                                              ↓
                              只在这 32 簇内做精确搜索
```

**参数**：
| 参数 | 含义 | 调优 |
|---|---|---|
| `nlist` | 聚类簇数 | √N（10M 取 4096） |
| `nprobe` | 查询时探索簇数 | nlist 的 1-5%（涨召回） |

**优点**：内存比 HNSW 省（簇中心 + 倒排表）、磁盘存储友好。

**缺点**：召回率次于 HNSW（90-95%）、需要重建（数据分布变化时）。

**适用**：> 1 亿向量、内存敏感、可接受略低召回率。

### 2.3 DiskANN

**原理**：HNSW 思想 + 设计上把图存磁盘 / SSD，用 SSD 随机 IO 替代内存。

**优点**：单节点支持 10 亿+ 向量、内存消耗 1/10。

**缺点**：依赖 NVMe SSD、查询延迟比纯内存方案高（10-50ms）、生态不如 HNSW 成熟。

**适用**：超大规模（10 亿+）、内存预算紧张、可接受 10ms+ 延迟。

### 2.4 三者对比

| 维度 | HNSW | IVF | DiskANN |
|---|---|---|---|
| 数据规模 | < 1 亿 | 1 亿 - 10 亿 | 10 亿+ |
| 召回率 (Recall@10) | 95-99% | 90-95% | 92-97% |
| 单查询延迟 | 1-10ms | 5-30ms | 10-50ms |
| 内存占用（10M × 1024d） | ~50GB | ~10GB | ~5GB |
| 增量插入 | ✅ | ✅（rebuild 周期重建） | ✅ |
| 生态成熟度 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ |

---

## 三、向量库选型决策

### 3.1 主流方案对比

| 方案 | 类型 | 数据量 | 索引 | 部署 | 优势 | 劣势 |
|---|---|---|---|---|---|---|
| **Milvus** | 专业向量库 | 1M-10B+ | HNSW/IVF/DiskANN | 集群 | 性能强 / 生态好 / 标量过滤优 | 部署复杂 / 资源吃 |
| **Qdrant** | 专业向量库 | 1M-1B | HNSW | 单机/集群 | Rust 性能好 / API 简洁 | 中文社区相对小 |
| **Weaviate** | 专业向量库 | 1M-1B | HNSW | 集群 | GraphQL / 内置 vectorizer | Schema 复杂 |
| **pgvector** | PG 扩展 | < 100M | HNSW/IVFFlat | 已有 PG 直接加 | 不引入新组件 / 事务一致 | 性能 / 容量受 PG 限 |
| **Elasticsearch dense_vector** | ES 扩展 | < 100M | HNSW | 已有 ES 直接加 | 与全文检索同一栈 | ES 内存消耗高 |
| **Redis Search** | Redis 模块 | < 1M | HNSW/Flat | 已有 Redis 直接加 | 极低延迟 / 与缓存同栈 | 容量受 Redis 内存限 |
| **Chroma** | 嵌入式 | < 100K | HNSW | 单进程 | 本地 PoC / 极简 | 不适合生产 |
| **Pinecone** | SaaS | 1M-1B | 私有算法 | 完全托管 | 0 运维 / Serverless | 贵 / 数据出境 |

### 3.2 决策树

```
                      数据量？
                         │
        ┌────────────────┼────────────────┐
       <1M             1M-100M           >100M
        │                │                  │
   ┌────┴────┐      ┌────┴─────┐      ┌────┴────┐
   PoC?     已有 Redis?  已有 PG/ES?   预算？
   │           │            │           │
  Chroma    Redis      pgvector       ┌──┴──┐
   /        Search     /ES dense    丰   紧
  Qdrant 单机           vector       │    │
                                   Milvus  Milvus
                                  (HNSW)  (IVF/DiskANN)
                                          + 量化
```

### 3.3 选型核心问题

**Q：已有 ES 集群，要不要再上 Milvus？**
- 总向量数 < 1000 万 + ES 集群有富余资源 → **直接用 ES dense_vector**，不引入新组件
- 总向量数 > 5000 万 / 元数据过滤复杂 / 召回质量要求高 → 上 Milvus

**Q：pgvector 真能撑生产吗？**
- 100 万级 + 元数据过滤多（业务 SQL 和向量同库事务一致） → ✅ 能撑
- 1000 万级 + 简单向量检索 → 性能勉强（HNSW + 调参），可考虑
- 1 亿+ → 不行，必须专业向量库

**Q：什么时候上 Pinecone / 不自部署？**
- 团队没有运维向量库的能力
- 数据量预期增长不超过 1 亿
- 数据可出境 / 不敏感
- 预算充足（Pinecone 1B 向量 / 月 ~$3000+）

---

## 四、容量与成本估算（必背模板）

### 4.1 内存计算公式

```
裸向量内存 = N × d × 4 bytes (float32)
HNSW 索引开销 ≈ 1.5 × 裸向量
总内存 ≈ 2.5 × N × d × 4
```

### 4.2 实战估算

**场景**：1000 万文档，每篇切 5 段，向量维度 1024。

```
N = 1000 万 × 5 = 5000 万 chunks
裸向量 = 5e7 × 1024 × 4 = 200 GB
HNSW 总开销 ≈ 500 GB

如果用 PQ 量化（压缩比 1/8）：
量化后 ≈ 60 GB

机器配置：
- 单节点 Milvus + 64 GB 内存 → 8 节点集群（量化后单节点 8GB）
- 加副本 + 索引文件 → 实际部署 16 节点
- 月成本（云上 c5.4xlarge ~ $400/月）≈ $6500/月
```

### 4.3 量化（Quantization）压缩

| 算法 | 压缩比 | 召回损失 | 适用 |
|---|---|---|---|
| **SQ8**（Scalar Quantization） | 1/4（float32 → int8） | 1-2% | 通用，最稳 |
| **PQ**（Product Quantization） | 1/8 ~ 1/32 | 5-10% | 大规模 / 内存紧 |
| **BQ**（Binary Quantization） | 1/32（float32 → 1bit） | 10-20% | 极致压缩 / 精度可接受 |

**生产推荐**：默认 SQ8（5000 万以下），1 亿+ 上 PQ，金融 / 高质量场景仍用 float32。

```python
# Milvus 建 HNSW + SQ8 量化索引
collection.create_index(
    field_name="vector",
    index_params={
        "index_type": "HNSW",
        "metric_type": "IP",                     # 内积（向量已归一化）
        "params": {
            "M": 16,
            "ef_construction": 200
        }
    }
)
collection.create_index(
    field_name="vector",
    index_params={
        "index_type": "IVF_SQ8",                 # 或 HNSW_SQ8
        "metric_type": "IP",
        "params": {"nlist": 4096}
    }
)
```

---

## 五、元数据过滤：性能陷阱重灾区

### 5.1 三种过滤策略

```
用户 Query: "查 2026 年发布的、产品类的政策文档，相关性 Top-5"
向量 = embed(query)
filter = "category='policy' AND product_category='product' AND publish_year=2026"
```

| 策略 | 流程 | 优劣 |
|---|---|---|
| **Pre-filter**（先过滤再检索） | SQL 过滤 → 候选集 → 向量检索 | 候选集小时快，过滤后没几条向量 → HNSW 走崩（图断了） |
| **Post-filter**（先检索再过滤） | 向量检索 Top-K → 元数据过滤 | 过滤掉太多 → Top-K 变 Top-1，丢失结果 |
| **Filtered Search**（向量库原生支持） | 边走图边过滤 | Milvus / Qdrant / pgvector 都已支持，最优解 |

### 5.2 过滤陷阱真实案例

```
场景：1000 万向量，元数据 tenant_id 有 1000 个租户，平均每租户 1 万向量。

Naive Pre-filter：
SELECT * FROM vectors WHERE tenant_id = 'T001' ORDER BY vec <-> query LIMIT 5
→ 每次拉 1 万行进内存做向量计算，慢

Naive Post-filter：
向量检索 Top-100 → WHERE tenant_id = 'T001'
→ 100 个里可能只剩 0-1 个匹配，召回严重缺失

Filtered Search（Milvus 原生）：
HNSW 走图时跳过不满足 tenant_id='T001' 的节点
→ 召回率正常 + 性能好
```

**关键认知**：选向量库时**必须验证它对元数据过滤的实现**——是 Pre/Post 还是 Filtered Search。

### 5.3 高基数 vs 低基数过滤

| 过滤选择性 | 例子 | 推荐 |
|---|---|---|
| 高选择性（过滤后 < 1% 数据） | tenant_id, doc_id | Pre-filter（先 SQL 拿候选 ID 再向量） |
| 中选择性（过滤后 1-50%） | category, publish_year | Filtered Search（向量库原生） |
| 低选择性（过滤后 > 50%） | language='zh' | Post-filter |

---

## 六、向量库部署最佳实践

### 6.1 Milvus 集群拓扑

```
┌─────────────────────────────────────────────┐
│              Coordinator                     │
│   (Root / Data / Query / Index Coord)        │
├─────────────────────────────────────────────┤
│   Proxy（接 SDK 请求）                        │
├─────────────────────────────────────────────┤
│   Query Node × N        │   Data Node × N   │
│   (in-memory shards)    │   (写入持久化)     │
├─────────────────────────────────────────────┤
│   Index Node × M（异步建索引）               │
├─────────────────────────────────────────────┤
│   存储：S3/MinIO（segments）+ etcd（meta） │
│         + Pulsar/Kafka（消息流）              │
└─────────────────────────────────────────────┘
```

**资源配置经验值**：
- Query Node 内存 = 总向量数据 × 索引膨胀系数（HNSW 1.5x）+ 1.5x buffer
- 写入 QPS > 1000 时 Data Node 单独部署
- Index Node 用大内存机器（建索引内存峰值高）

### 6.2 关键参数

```yaml
# Milvus collection 参数
collection:
  shards_num: 4                # 分片数：QPS 高时增加
  ttl: 0                       # 不过期；客服场景可设 30 天

index:
  type: HNSW
  metric: IP                   # 内积（vec 已归一化）
  M: 24                        # 16-32 之间，召回 vs 内存平衡
  ef_construction: 360         # 200-500，建索引质量

search:
  ef: 96                       # 50-200，在线可调
  consistency_level: Bounded   # 写入到查询的延迟容忍（影响新写文档可见性）
```

### 6.3 容量规划检查清单

```
□ 数据量预估（1 年内峰值）
□ 维度选择（768 / 1024 / 1536）
□ 索引算法选择（HNSW / IVF）
□ 量化方案（SQ8 / PQ / 不量化）
□ 元数据字段定义 + 过滤模式
□ 多租户隔离方案（按 collection / 按 partition / 字段过滤）
□ 备份与恢复（S3 snapshot 周期）
□ 索引重建计划（Embedding 模型升级时）
□ 监控指标（召回率 / 延迟 / 内存 / 写入吞吐）
```

---

## 七、生产踩坑

### 坑 1：忘记归一化，召回完全不准

**现象**：用 BGE-M3 自部署，召回结果看起来都不相关。

**根因**：`SentenceTransformer.encode()` 默认 `normalize_embeddings=False`，写入向量库时长度不一；查询时也没归一化；向量库用内积算分（IP）相当于在算未归一化向量的内积，与余弦相似度差异巨大。

**修复**：
- 写入时强制 `normalize_embeddings=True`
- 查询时同样归一化
- 向量库的 metric_type 选 `IP`（内积，配合归一化等价余弦，最快）
- **建索引前先抽样 100 条向量算 norm，必须接近 1.0**

```python
# 写入和查询都必须保持一致
vec = model.encode(text, normalize_embeddings=True)
assert abs(np.linalg.norm(vec) - 1.0) < 1e-5
```

### 坑 2：Pre-filter 把 HNSW 图打断，召回率从 95% 跌到 30%

**现象**：上线多租户后，按 `tenant_id` 过滤的查询召回率断崖下跌。

**根因**：用了某向量库的 Naive Pre-filter——先 SQL 把租户的 1 万向量捞出来，再在这 1 万里建临时图做 HNSW，**1 万向量 + M=16 的图非常稀疏，几乎是退化的暴力搜索**。

**修复**：
- 切换到 Milvus 的 Filtered Search（边走图边过滤）
- 大租户独立 partition，物理隔离索引
- 小租户共享 collection 用 filter
- 监控召回率：建评估集，对每个租户跑一次 Hit@5

**指标**：`metric: vector_recall_at_k{tenant, k=5}`

### 坑 3：1 亿向量直接上 HNSW，内存爆炸

**现象**：1 亿 × 1024 维 + HNSW，内存需求 ~600GB，单节点装不下，集群成本飞升。

**根因**：没规划量化方案 / 没做容量估算。

**修复**：
- 切换到 IVF_PQ：`nlist=8192, m=64, nbits=8`，压缩比 1/8 → 80GB
- 召回率从 96% 降到 92%，可接受
- 加 Rerank 弥补召回精度损失
- 评估通过后全量重建索引

**对比**：

| 方案 | 内存 | 召回率 | 延迟 |
|---|---|---|---|
| HNSW float32 | 600GB | 96% | 10ms |
| IVF_PQ (1/8) | 80GB | 92% | 25ms |
| HNSW + 加 Rerank | 80GB | 95% | 80ms |

### 坑 4：索引建到一半 OOM，集群挂了

**现象**：导入 5000 万向量后，Milvus 后台开始建 HNSW 索引，Index Node OOM 重启，反复循环。

**根因**：HNSW 建索引内存峰值是数据本身的 2-3 倍。Index Node 给了 32GB 内存试图建 100GB 数据的索引。

**修复**：
- Index Node 给到 128GB 大内存机器
- 分批建索引：每批 1000 万向量 / segment
- 监控 Index Node 内存峰值告警
- 大集群上 IVF（建索引内存峰值低）

### 坑 5：动态写入 + 实时查询，新文档查不到

**现象**：客服 Agent 新上传政策文档，立即在 Agent 里测试，搜不到。10 分钟后才能搜到。

**根因**：Milvus 默认 `consistency_level=Bounded`，新写入数据有 30s-几分钟可见性延迟（segment 还没 flush + 索引还没建好）。

**修复**：
- 急用场景设 `consistency_level=Strong`（牺牲写入吞吐）
- 业务侧：上传文档后**立即同步插入 + 主动 flush**
- 用临时索引（小集合 + Flat 暴力搜）兜底新文档查询

```python
# 强一致查询
collection.search(
    data=[query_vec],
    anns_field="vector",
    param={"metric_type": "IP", "ef": 96},
    limit=10,
    consistency_level="Strong"  # 等到所有写入可见
)
```

---

## 八、面试高频追问

**Q1：为什么向量库不能用 SQL 直接查？**

向量检索本质是**高维近邻搜索**。N 个 d 维向量找 Top-K 距离最小的，朴素遍历 `O(N×d)`，1 亿 × 1024 维要 20-50 秒，生产不可用。向量库的核心价值是 ANN 索引（HNSW / IVF / DiskANN），把查询从 `O(N)` 降到 `O(log N)` 或 `O(√N)`，牺牲少量精度换取毫秒级延迟。这是 SQL 数据库做不到的。

**Q2：HNSW 和 IVF 的本质区别？什么场景选哪个？**

HNSW 是**多层图**，从顶层入口贪心走到目标，召回率高、延迟低、内存吃；IVF 是**先聚类再倒排**，查询时只查最近的 nprobe 个簇，内存省、召回率次之。**经验**：< 1 亿用 HNSW（默认推荐），1-10 亿考虑 IVF + 量化，10 亿+ 上 DiskANN。

**Q3：HNSW 的 M 和 ef_search 怎么调？**

`M`：每节点最大邻居数，建索引时定，**16-32 之间**，越大召回越高 + 内存越大。`ef_search`：查询时探索数，**在线可调**，越大召回越高 + 延迟越大。生产经验：`M=24, ef_search=96` 是甜区，召回 95%+ + 延迟 < 10ms。压力测试时画 ef_search 的召回 / 延迟曲线，选拐点。

**Q4：1000 万 × 1024 维 HNSW 要多少内存？怎么压缩？**

裸向量 = 5e7 × 1024 × 4 = 40GB（注：1000 万文档 × 5 chunk = 5000 万向量）。HNSW 索引开销 1.5x → 60GB 左右。压缩方案：① **SQ8** float32 → int8，1/4 压缩，召回损失 1-2%；② **PQ** 1/8-1/32 压缩，损失 5-10%；③ **BQ** 1/32 压缩，损失 10-20%。生产默认 SQ8，1 亿+ 上 PQ。

**Q5：pgvector 真的能撑生产吗？**

100 万级别 + 元数据过滤多 + 业务和向量需要事务一致 → 能。1000 万级 + HNSW + 调参 → 勉强。1 亿+ 不要试。pgvector 优势是不引入新组件 + 事务一致 + SQL 友好，劣势是性能 / 容量受 PG 单机限。**如果你已经有 PG 集群，先用 pgvector 跑 PoC，性能不够再迁专业向量库**。

**Q6：Milvus / Qdrant / Weaviate 怎么选？**

Milvus 国内生态最强、社区活跃、性能优、支持丰富索引算法和量化、缺点是部署复杂（依赖 etcd / Pulsar / S3）。Qdrant Rust 写的、单机性能强、API 简洁、缺点是分布式相对弱。Weaviate 内置 vectorizer 和 GraphQL API、对 RAG 友好、缺点是 Schema 复杂、中文社区小。**国内生产首选 Milvus，海外 / 中小规模用 Qdrant**。

**Q7：元数据过滤为什么是性能陷阱？**

过滤策略错了会让召回率断崖。Naive Pre-filter（先 SQL 后向量）在过滤选择性高（过滤后剩下少量）时**让 HNSW 图变得稀疏退化**，召回从 95% 跌到 30%；Naive Post-filter（先向量后 SQL）则会**丢失被过滤掉的真正相关结果**。**正解：用向量库原生的 Filtered Search**——边走图边过滤，Milvus / Qdrant / pgvector 都已支持。

**Q8：多租户向量库怎么设计隔离？**

三种方案：① **Collection 隔离**——每个租户独立 collection，强隔离但管理成本高、租户多时元信息爆炸；② **Partition 隔离**——同一 collection 内分 partition（Milvus 支持），物理隔离索引段、过滤效率高；③ **字段过滤**——`tenant_id` 作为元数据字段，依赖 Filtered Search。**推荐**：大租户独立 partition、小租户共享 collection 用字段过滤，结合使用。

**Q9：Embedding 模型升级时怎么平滑迁移？**

四步：① **影子双写**——新增 `embedding_v2` 字段，新文档同时写两个版本；② **离线评估**——用 200-500 条标注集对比 v1/v2 的 Hit@5 / NDCG@5；③ **全量 reindex**——把存量文档用 v2 重建索引（独立 collection，避免影响线上）；④ **流量灰度切换** → 老索引下线。**关键监控**：向量空间漂移（新老向量的余弦分布是否偏移）、召回率对比、用户反馈。

**Q10：向量检索 P99 突然飙高，怎么排查？**

排查路径：① 查 ef_search 是否被调高了（在线参数）；② 查内存是否压满（向量库会触发 swap，性能崩）；③ 查段（segment）数是否过多（Milvus 段多查询 fan-out 大）；④ 查 GC / 索引重建是否在进行（影响查询线程）；⑤ 查写入 QPS 是否飙升导致 Coord 拥堵；⑥ 查机器资源（CPU / 网络 IO）。**生产经验**：80% 是段太多（设 compaction） + 内存压满（扩容 / 量化）。

---

## 九、答题模板（60 秒）

> "向量库的核心是 **ANN 索引把高维近邻搜索从 O(N) 降到 O(log N)**。"
>
> "**三大算法**：HNSW（多层图，< 1 亿首选，召回 95%+ / 延迟 < 10ms） / IVF（聚类倒排，1-10 亿，省内存）/ DiskANN（SSD，10 亿+）。**默认推荐 HNSW，参数 M=24、ef_search=96**。"
>
> "**主流方案**：< 1 亿用 Milvus / Qdrant，已有 PG/ES 直接 pgvector / dense_vector，预算紧 + 数据可出境用 Pinecone。**Redis Search 只做 < 100 万的低延迟场景**。"
>
> "**容量公式**：N × d × 4 字节裸向量 + 1.5x HNSW 索引开销。1 亿 × 1024 维 ~600GB，**用 PQ 压到 1/8** → 80GB，召回从 96% 降到 92%、加 Rerank 补回。"
>
> "**元数据过滤** Naive Pre/Post 都会踩坑，**必须用向量库原生 Filtered Search**。多租户用 partition + 字段过滤组合。**Embedding 升级要双写双查灰度 + 监控向量空间漂移**。"

---

## 十、相关文档

- [RAG 检索增强生成](RAG检索增强生成.md) — 向量库在 RAG 中的位置
- [LLM 基础与面试视角](LLM基础与面试视角.md) — Embedding 维度与上下文窗口
- [Redis](../Redis/README.md) — Redis Search 作为小规模向量库
- [Middleware/es](../Middleware/es.md) — ES dense_vector 选型背景
- [Distributed/CAP 与 BASE](../Distributed/CAP与BASE.md) — 向量库分布式一致性级别
- [Agent 评估与可观测性](Agent评估与可观测性.md) — 召回率 / NDCG 评估
- [LLM 应用工程化](LLM应用工程化.md) — 向量检索缓存
