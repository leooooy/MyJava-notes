# InnoDB 存储引擎

> InnoDB 是 MySQL 5.5+ 的默认引擎，几乎承担了所有互联网 OLTP 场景。它的特性多且互相串联——面试要分清"存储结构层 / 内存结构层 / 后台线程层 / 关键特性层"四块怎么协同。
>
> 本篇解决：① InnoDB 物理存储是什么样 → ② 内存里 Buffer Pool / Change Buffer / Log Buffer 各自的作用 → ③ 后台线程在干什么 → ④ Insert Buffer / Double Write / AHI 这些高频特性的设计动机和坑。

---

## 一、InnoDB 总体架构

```
┌─ 内存结构（In-Memory）─────────────────────────────────┐
│  ┌──────────────────────────────────────────────┐     │
│  │  Buffer Pool                                  │     │
│  │   ├ 数据页 / 索引页缓存（LRU 双链）            │     │
│  │   ├ Change Buffer（二级索引写优化）            │     │
│  │   ├ Adaptive Hash Index（热点页哈希）          │     │
│  │   └ Lock Info / Data Dictionary 区             │     │
│  └──────────────────────────────────────────────┘     │
│  ┌──────────────────────────────────────────────┐     │
│  │  Log Buffer（redo log buffer，默认 16MB）     │     │
│  └──────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────┘
                       │  fsync / 刷盘
┌─ 磁盘结构（On-Disk）────────────────────────────────────┐
│   ibdata1                共享表空间（系统数据 + 部分 undo）│
│   ib_logfile0/1          redo log（环形写）              │
│   undo_001 / undo_002    undo 表空间（5.7+ 可独立）      │
│   <db>/<table>.ibd       独占表空间（数据 + 索引）       │
└────────────────────────────────────────────────────────┘
                       ↑
┌─ 后台线程 ──────────────────────────────────────────────┐
│   Master Thread / IO Thread / Purge Thread / Page Cleaner│
└────────────────────────────────────────────────────────┘
```

---

## 二、磁盘结构

### 2.1 表空间（Tablespace）

| 类型 | 文件 | 内容 | 配置 |
| --- | --- | --- | --- |
| 系统表空间 | `ibdata1` | 数据字典（5.7）/ Change Buffer / Double Write Buffer / 部分 undo | 5.7 默认 |
| 独立表空间 | `<db>/<table>.ibd` | **每张表自己的数据 + 索引** | `innodb_file_per_table=ON`（5.6+ 默认） |
| undo 表空间 | `undo_NNN` | undo log | 5.7+ 可独立，回收方便 |
| 临时表空间 | `ibtmp1` | 临时表 / 排序临时数据 | 5.7+ 独立 |

> **强烈建议**：保持 `innodb_file_per_table=ON`。否则 `DROP TABLE` 不会真正释放磁盘（ibdata1 只增不减），生产事故重灾区。

### 2.2 段（Segment）→ 区（Extent）→ 页（Page）→ 行（Row）

```
表空间 (Tablespace)
  ├─ 段 (Segment)        每个索引一个段（数据段 + 索引段）
  │    ├─ 区 (Extent)    1 区 = 64 个页 = 1MB
  │    │    ├─ 页 (Page) 默认 16KB，InnoDB 最小 IO 单位
  │    │    │    └─ 行 (Row)
```

**关键参数**：
- 一页 16KB，InnoDB 加载和刷盘都以**页**为单位
- 一区 1MB（64 页），保证连续磁盘空间
- B+Tree 一层节点对应若干页

### 2.3 行格式

InnoDB 5.7+ 默认 **DYNAMIC** 行格式：

```
[变长字段长度列表][NULL 标志位][记录头][列1][列2]...[trx_id][roll_ptr]
```

要点：
- 变长字段 ≤768 字节存行内，超过用**溢出页**（off-page）
- 一行最大 8KB（半页）——超出会拒绝插入或某些列变溢出页
- 三个隐藏列：`DB_TRX_ID`（6B）+ `DB_ROLL_PTR`（7B）+ `DB_ROW_ID`（6B，无主键时才有）

> **生产坑**：单行超过 8KB 会报错 `Row size too large`。常见于 VARCHAR(65535) 大量列、或 utf8mb4 下 VARCHAR 长度被 ×4。

### 2.4 页结构

每个 16KB 页内部：

```
File Header (38B)        页号、前后页指针、校验和
Page Header (56B)        页内行数、空闲空间、最大 trx_id
Infimum + Supremum       哨兵记录（最小/最大）
User Records             实际数据，按主键有序，单链表
Free Space               空闲区
Page Directory           稀疏索引，4~8 行一个 slot，二分查找
File Trailer (8B)        校验和（与 Header 对应）
```

**Page Directory 的作用**：行内单链表查找是 O(N)，加上 Page Directory 后变 O(log N)——这是页内查找快的关键。

---

## 三、内存结构

### 3.1 Buffer Pool（缓冲池）

> InnoDB 性能的核心。**没有 Buffer Pool，每次查询都要随机 IO，吞吐量直接除以 100**。

```sql
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
```

**生产配置**：物理内存的 50%~75%（DB 专用机）。

**多实例**：
```sql
SHOW VARIABLES LIKE 'innodb_buffer_pool_instances';
```
默认 8 个，减少 mutex 争用。每实例独立 LRU、独立锁。

#### 3.1.1 改良版 LRU（必背）

普通 LRU 的两大问题：
1. **预读污染**：InnoDB 一次预读 64 页，多数用不到 → 把热点页挤掉
2. **全表扫描污染**：一次大表扫描把 Buffer Pool 全冲刷

InnoDB 的**两段式 LRU**：

```
LRU 链表
├─ Young 区（默认 5/8）   ← 真正的热点
│
└─ Old 区（默认 3/8）     ← 新加载/预读的页先进这里
   ↑
   新加载页插入 Old 区头部
```

**晋升规则**：页在 Old 区被再次访问，且**距首次访问 > `innodb_old_blocks_time`**（默认 1000ms），才晋升到 Young 区头部。

> **设计意图**：全表扫描时，同一页通常在毫秒内被多次访问，不会满足 1000ms 条件 → 一直停留 Old 区 → 不污染 Young。

#### 3.1.2 三大链表

| 链表 | 作用 |
| --- | --- |
| Free List | 空闲页链表 |
| LRU List | 已使用页（含脏页 + 干净页），管淘汰 |
| Flush List | 仅脏页，按 LSN 排序，管刷盘 |

**关键点**：脏页同时挂在 LRU 和 Flush List 上——LRU 决定它能不能被淘汰（脏页淘汰前必须先刷），Flush List 决定它什么时候刷。

### 3.2 Change Buffer（写优化）

> **Change Buffer**：解决"二级索引页不在 Buffer Pool 时，写操作的磁盘随机 IO 开销"。

#### 3.2.1 问题场景

```
INSERT INTO t (id, name) VALUES (1, '张三');
-- 主键索引：id 顺序插入，页基本在 Buffer Pool（命中率高）
-- 二级索引（如 idx_name）：name 是离散值，对应索引页大概率不在内存 → 随机 IO
```

#### 3.2.2 Change Buffer 的解法

```
写操作 → 二级索引页在 Buffer Pool 吗？
           ├─ 在 → 直接改
           └─ 不在 → 暂存到 Change Buffer（不读盘）
                       │
                       ▼
                   未来某次该页被读时（merge）
                   或后台线程定期 merge
                       │
                       ▼
                   合并应用所有缓冲的变更
```

**收益**：把**随机读** 变成 **顺序写 + 一次合并 IO**，IOPS 节省 5 倍以上。

#### 3.2.3 适用条件（高频追问）

✅ 必须满足：
- **二级索引**（聚簇索引按主键顺序，本来就快）
- **非唯一索引**（唯一索引必须读页验证唯一性）

❌ 不适用：
- 主键索引
- 唯一索引（INSERT 必须查冲突，必须读盘）
- 变更后立即被读的页（没时间累积，merge 提前）

### 3.3 Adaptive Hash Index（AHI，读优化）

> 自适应哈希索引：对**反复访问同一种条件**的热点页建哈希。

```
B+Tree 三层 → 每次查 3 次 IO
↓
建好 AHI 后 → 1 次哈希查找
```

**触发条件**：
- 同一页用同种 WHERE 模式被访问 ≥100 次
- 模式必须固定（`WHERE a=?` 和 `WHERE a=? AND b=?` 算两种模式，会让该页失去 AHI）

**生产坑**：
- 访问模式不规律时，AHI 反而是开销（哈希维护成本）
- 高并发场景下 AHI 锁竞争是瓶颈，需考虑关闭：
  ```sql
  SET GLOBAL innodb_adaptive_hash_index = OFF;
  ```

### 3.4 Log Buffer

```sql
SHOW VARIABLES LIKE 'innodb_log_buffer_size';  -- 默认 16MB
```

写 redo log 的内存缓冲。增大它减少大事务的刷盘次数，但占内存。**通常默认够用**——异常增大要先排查是否有大事务。

---

## 四、关键特性

### 4.1 Insert Buffer / Change Buffer 演进

历史名字叫 **Insert Buffer**，5.5 后扩展支持 update/delete，改名 **Change Buffer**——网上老资料还会用 Insert Buffer，是同一个东西。

### 4.2 Double Write（防部分写失效）

> **问题**：InnoDB 页 16KB，OS 写盘最小单位 4KB，断电时可能只写了 4KB → **页损坏**（partial page write）。

**为什么 redo log 救不了**？  
redo log 是物理日志，记的是"在页 X 的偏移 Y 写 Z"——前提是**页 X 本身完整**。页都坏了，redo log 也无能为力。

#### 4.2.1 Double Write 流程

```
脏页要刷盘
    │
    ▼
1. 先 memcpy 到 Double Write Buffer（内存 2MB）
    │
    ▼
2. Double Write Buffer 顺序写入共享表空间（连续 128 页）
   ┌─ 第 1 次 fsync 写 1MB
   └─ 第 2 次 fsync 写 1MB
    │
    ▼
3. 再把脏页写到各自表空间（离散写）
```

#### 4.2.2 崩溃恢复

```
重启时检查页 checksum
   ├─ 页完整 → 正常恢复
   └─ 页损坏 → 从 Double Write Buffer 找副本 → 还原 → apply redo
```

#### 4.2.3 性能影响

每个脏页要写两次 → **写放大 2x**。但因为 Double Write 是顺序写，实际开销约 **+10%**——可以接受。

#### 4.2.4 什么时候关？

```sql
SET GLOBAL innodb_doublewrite = OFF;
```

仅以下场景：
- 文件系统/磁盘自身保证原子写（如 ZFS、某些 SSD）
- 极端写入压力 + 可容忍数据损坏（极少见）

> 默认开启不要关。生产 99% 的实例都开。

### 4.3 Async IO

InnoDB 用 **Linux Native AIO** 同时发起多个 IO 请求 + 自动合并相邻页（[1,2]+[2,3] → 连续读 1~3）。

```sql
SHOW VARIABLES LIKE 'innodb_use_native_aio';
```

### 4.4 Flush Neighbor Pages（相邻页刷新）

刷一脏页时，顺带刷它在同一**区**内的其它脏页。

| 场景 | 设置 |
| --- | --- |
| 机械盘 | 开（默认）— 利用顺序 IO |
| **SSD** | 关 (`innodb_flush_neighbors=0`)— SSD 随机 IO 已快，多刷反成开销 |

---

## 五、后台线程

### 5.1 Master Thread

**最核心**的线程，负责**协调**：每秒任务（合并 Change Buffer 5%、刷脏页 ≤10%、刷 redo），每 10 秒任务（刷脏页、合并 Insert Buffer、回收 undo）。

5.5 之后大量职责被拆出去给专门线程，但 Master 仍是节奏总指挥。

### 5.2 IO Thread

```sql
SHOW VARIABLES LIKE 'innodb_%io_threads';
```

- `read` 线程：处理读请求（默认 4 个）
- `write` 线程：处理写请求（默认 4 个）
- `insert buffer` 线程：合并 Change Buffer
- `log` 线程：刷 redo log

### 5.3 Purge Thread

回收 undo log。条件：**没有任何活跃 ReadView 还可能读到这个版本**。

```sql
SHOW VARIABLES LIKE 'innodb_purge_threads';   -- 默认 4
SHOW ENGINE INNODB STATUS\G   -- 看 History list length
```

> History list 长 → 大概率有长事务卡住 Purge → undo 不释放 → ibdata 膨胀（高频生产事故）。

### 5.4 Page Cleaner Thread

把脏页从 Buffer Pool 异步刷盘，5.6+ 从 Master 拆出来。

### 5.5 监控所有线程

```sql
SHOW ENGINE INNODB STATUS\G
```

输出里：
- `Pending normal aio reads/writes`：IO 队列
- `History list length`：未清理 undo 数
- `Modified db pages`：脏页数

---

## 六、生产配置建议

```ini
# 内存
innodb_buffer_pool_size       = 物理内存的 50%~75%
innodb_buffer_pool_instances  = 8
innodb_log_buffer_size        = 16M

# 文件
innodb_file_per_table         = ON      # 永远开
innodb_data_file_path         = ibdata1:1G:autoextend

# redo log
innodb_log_file_size          = 1G ~ 4G  # 太小频繁切换
innodb_log_files_in_group     = 2

# 可靠性
innodb_doublewrite            = ON       # 默认，不要关
innodb_flush_log_at_trx_commit = 1       # 双 1 高可靠
sync_binlog                   = 1

# IO
innodb_io_capacity            = 2000     # SSD 调高
innodb_io_capacity_max        = 4000
innodb_flush_neighbors        = 0        # SSD 关
innodb_use_native_aio         = ON

# 并发
innodb_purge_threads          = 4
innodb_thread_concurrency     = 0        # 默认不限制

# AHI
innodb_adaptive_hash_index    = ON       # 默认；高并发瓶颈时可关
```

---

## 七、生产踩坑

### 7.1 ibdata 不收缩

DROP TABLE 后 ibdata1 不变小——`innodb_file_per_table=OFF` 的老库都有这病。

**根因**：共享表空间一旦扩大，文件大小不会缩小。  
**唯一解**：导出数据 → drop schema → 改 `file_per_table=ON` → 导回。

### 7.2 Buffer Pool 命中率突降

```sql
SHOW STATUS LIKE 'Innodb_buffer_pool_read%';
-- 1 - reads/read_requests = 命中率
```

低于 99% 时排查：
- Buffer Pool 太小
- 大全表扫描污染（看 `slow_log`）
- 某 SQL 走错索引扫海量页

### 7.3 长事务把 Purge 压垮

```sql
SHOW ENGINE INNODB STATUS\G
-- History list length: 50000000  ← 5000 万，警告
```

找慢事务 kill：
```sql
SELECT * FROM information_schema.innodb_trx
WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 60;
```

### 7.4 大量小事务把 Double Write 卡住

并发刷盘时 Double Write Buffer 是单点 → 高并发写场景见过 IO 瓶颈在 dblwr。8.0+ 的 `innodb_doublewrite_files` 可拆多文件缓解。

---

## 八、面试高频追问

### Q1：Change Buffer 为什么只对二级非唯一索引？

主键有序插入本来快，唯一索引必须读页查冲突——只有"非唯一二级索引"既离散又不需要立即读，最适合缓冲。

### Q2：Buffer Pool 的 LRU 为什么要分两段？

防止预读和全表扫描污染热点。新加载页先进 Old 区，1 秒后再次访问才进 Young——一次性扫描的页停留 Old 区，不挤掉真正热数据。

### Q3：Double Write 解决什么问题？为什么 redo log 不能解决？

Partial Page Write：OS 写 16KB 页时只写了 4KB 就断电，页损坏。redo log 是物理日志，依赖**页本身完整**——页坏了 redo 也没法 apply。Double Write 在共享表空间留一份完整页副本，恢复时先用副本还原页，再 apply redo。

### Q4：AHI 是 InnoDB 自动建的，那为什么不一直开？

热点访问模式必须**稳定**才有用。访问模式不规律时，维护 AHI 自身（哈希插入/查找/锁）开销大于收益；并发高时 AHI 锁还会成为瓶颈。

### Q5：脏页什么时候刷盘？

四个时机：
1. redo log 快写满（强制 checkpoint）
2. Buffer Pool 不够用（要淘汰脏页）
3. MySQL 空闲时
4. 正常关闭时（全部刷完才退出）

由 Page Cleaner 线程异步执行。

### Q6：innodb_flush_neighbors 为什么 SSD 要关？

机械盘随机 IO 慢、顺序 IO 快，多刷相邻页摊薄寻道成本——划算。SSD 没寻道开销，多刷反而增加写放大。

### Q7：单行最大多大？

8KB（半页）。超过就拒绝插入或某些大列变成溢出页。VARCHAR(65535) 一行只能放一列且要 utf8 字符集。

---

## 九、答题模板（60 秒话术）

> InnoDB 是 MySQL 默认引擎，提供事务、行锁、MVCC、崩溃恢复——OLTP 必选。
>
> **存储**上分**段→区→页→行**，页 16KB 是最小 IO 单位；行格式 DYNAMIC，含两个必有的隐藏列 trx_id、roll_pointer，用于 MVCC。
>
> **内存**最关键的是 Buffer Pool（缓存数据页 + 索引页，建议物理内存 50%~75%），用**两段式 LRU** 防全表扫描污染热点。Change Buffer 把"非唯一二级索引页不在内存"时的随机读优化成累积合并；AHI 给热点页建哈希。
>
> **可靠性**靠 Double Write Buffer 防部分写失效——共享表空间留完整页副本，崩溃时先还原页再 apply redo log。
>
> **后台**有 Master、IO、Purge、Page Cleaner 等线程协同：Master 调度、IO 处理读写、Purge 回收 undo（长事务会卡这个）、Page Cleaner 异步刷脏页。

---

## 十、相关文档

- [架构总览](./架构总览.md) — 引擎层定位
- [SQL 执行过程](./sql语句执行过程.md) — 上层怎么调进 InnoDB
- [索引](./索引.md) — B+Tree 数据结构
- [日志](./日志.md) — redo / undo 持久化
- [MVCC](./mvcc.md) — undo 链如何被读
- [锁机制](./行锁.md) — 行锁基于索引项
