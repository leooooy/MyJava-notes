# WAL 预写日志 — redo / AOF / CommitLog / Raft Log 同构设计

> 引子：
> ① **是什么**：Write-Ahead Logging——**修改数据结构之前先把变更顺序追加到日志**，崩溃后重放日志恢复。这条朴素的规则是几乎所有持久化系统的地基：MySQL redo / Redis AOF / RocketMQ CommitLog / Raft Log / ZK txn log / Kafka log / etcd WAL 全是它。
> ② **面试为什么必考**：上一篇《两阶段提交》的 Prepare 阶段靠它实现、《长轮询》的"变化事件"是从它派生的、所有"崩溃不丢数据"的承诺都要落到它身上——讲不清 WAL，整个数据可靠性体系就是飘的。
> ③ **本篇要解决**：① 为什么所有系统都选 WAL 这一种范式 ② fsync 时机怎么决定可靠性 ③ PageCache 在中间起什么作用 ④ 日志会无限增长，每个系统怎么治理（checkpoint / 重写 / 快照 / 截断）。

---

## 一、为什么需要 WAL

### 1.1 原始问题：写盘太慢，但崩溃不能丢

数据结构（B+ 树、HashMap、跳表、PageCache 中的页）在内存里改一下是纳秒级，但要确保**断电不丢**只能落到磁盘。直接让每次业务写入都同步写到磁盘的最终位置：

```
更新一行 → 找到 B+ 树叶节点页 → 磁盘随机定位 → fsync
机械盘随机写 ≈ 5~10ms / 次     →  TPS 上限 100~200
SSD 随机写 ≈ 100µs / 次         →  TPS 上限 ~10000
```

这扛不住任何严肃的业务。**但顺序写的速度是另一个量级**：

| 操作 | 机械盘 | SSD |
| --- | --- | --- |
| 随机写 4KB | ~5ms | ~100µs |
| 顺序写 4KB | ~10µs（500x 快） | ~10µs（10x 快） |

**WAL 的核心 idea**：业务的真实数据结构（B+ 树等）**不立即更新到磁盘**，只在内存里改；变更操作**追加到一个顺序写的日志文件**——日志一旦落盘就承诺"不丢"，崩溃后重放日志即可。把 100 次随机写换成 100 次顺序写——TPS 提升一个数量级。

### 1.2 一句话定义 WAL

> **修改任何持久化数据结构（页、索引、状态机）之前，先把这次变更追加写到一个只增的日志文件，且必须保证日志落盘后才返回成功。**

三个关键词缺一不可：
- **预（Write-Ahead）**：日志先于数据结构写入，否则崩溃可能丢
- **顺序追加（Append-Only）**：永不修改历史日志，永远只在尾部加
- **落盘承诺（fsync）**：write 只到 PageCache，必须 fsync 才能算"持久化"

---

## 二、共性骨架：五种 WAL 在做同一件事

### 2.1 通用流程

```
业务请求（写）
    │
    ▼
① 内存中准备变更（构造 log entry）
    │
    ▼
② 顺序追加到日志文件（write → PageCache）
    │
    ▼
③ 视可靠性需求决定何时 fsync 到磁盘
    │  ├─ 每次 fsync：金融级，TPS 低
    │  ├─ 定时 fsync：互联网通用，最多丢 N ms
    │  └─ 由 OS 决定：极致性能，崩溃可能丢
    │
    ▼
④ 应用到内存数据结构（B+ 树 / Hash / 状态机）
    │
    ▼
⑤ 异步 / 定期把内存数据 flush 到主存储（checkpoint）
    │
    ▼
⑥ 截断已 checkpoint 之前的日志（防无限增长）

       崩溃恢复：
       从最后一个 checkpoint 起，重放日志到末尾
```

注意 **②、③ 必须在 ④ 之前**——这就是 "Write-**Ahead**" 的字面含义。

### 2.2 五种系统的同构对照

| 维度 | **MySQL redo** | **Redis AOF** | **RocketMQ CommitLog** | **Raft Log** | **ZK txn log** |
| --- | --- | --- | --- | --- | --- |
| **日志记什么** | 页 + 偏移 + 改后内容（物理）| 写命令文本（逻辑）| 整条消息体 | 状态机命令（逻辑）| ZK 操作（创建/更新节点等）|
| **顺序写文件** | `ib_logfile0/1`（环形）| `appendonly.aof` | CommitLog（1G/文件，滚动）| Raft log 段文件 | log.X 文件 |
| **PageCache 中转** | ✅ | ✅ | ✅（mmap）| ✅ | ✅ |
| **fsync 策略** | `innodb_flush_log_at_trx_commit` 0/1/2 | `appendfsync` always/everysec/no | `SYNC_FLUSH` / `ASYNC_FLUSH` | 每次 commit 前必须落盘 | 每次事务必 fsync |
| **主存储数据结构** | InnoDB B+ 树（buffer pool 中的页）| 内存中的字典 / 跳表 | 内存中的 ConsumeQueue + IndexFile | 状态机（KV / 业务对象）| ZK in-memory data tree |
| **Checkpoint / 截断方式** | buffer pool 脏页刷盘 → 推进 LSN，老 redo 可覆盖 | AOF 重写（fork 子进程生成精简日志）| 老 CommitLog 文件按时间删除（默认 72h）| Snapshot 状态机 + 截断已快照的日志 | Snapshot 内存树 + 删旧 txn log |
| **崩溃恢复** | 扫 redo 重放未刷盘的页 | 加载 RDB + replay AOF | 启动时扫 CommitLog 重建 ConsumeQueue | 加载 snapshot + replay 后续 log | 加载 snapshot + replay 后续 txn log |
| **是否环形覆盖** | ✅ 环形 | ❌ 追加新文件 | ❌ 滚动新文件 | ❌ 段文件滚动 | ❌ 段文件滚动 |
| **能否做主从复制源** | ❌（用 binlog）| ✅（PSYNC 也用 backlog）| ✅（Slave 拉 CommitLog）| ✅（Leader 推 log）| ✅（ZAB 推 txn log）|

### 2.3 一张图理解"为什么都长一样"

```
                  共性骨架：顺序追加 + fsync + Checkpoint
                                  │
        ┌─────────────────────────┼─────────────────────────────┐
        │                         │                             │
    单机持久化              消息中间件                     共识协议
        │                         │                             │
   ┌────┴────┐               ┌────┴────┐                   ┌────┴────┐
MySQL redo              RocketMQ CommitLog                Raft Log
Redis AOF                Kafka log                        ZK txn log

  每种系统的日志格式不同（页改动/命令/消息/状态机命令），但
  "先写日志再改内存数据结构" 的骨架完全一致——这就是 WAL 范式。
```

---

## 三、关键机制详解

### 3.1 顺序追加 vs 随机写：100 倍的差距从哪来

磁盘（机械盘最明显）的耗时分布：

```
寻道（Seek）        ~5ms        机械臂移动到目标磁道
旋转延迟（Rotation） ~2ms       等盘片转到正确扇区
传输（Transfer）     ~0.1ms      实际读写
```

随机写：每次都付寻道+旋转 ≈ 7ms。顺序写：只有第一次寻道，后面持续传输 → 平均 ~10µs/次。

SSD 没有机械寻道但有"写放大"问题——SSD 内部是按 page（4KB）写、按 block（256KB）擦除，随机写触发垃圾回收抖动；顺序写让 GC 友好得多。

**所有用 WAL 的系统都暗暗依赖这条物理事实**：
- 数据可以散落在 B+ 树、跳表、Hash 表里（随机分布）
- **但写到日志一定是顺序追加**，性能上限由日志的顺序写决定

### 3.2 PageCache：write() ≠ 落盘

应用层调 `write(fd, buf, len)` 后，数据其实只到了 **PageCache（内核页缓存）**：

```
   应用 buffer ───write()───► PageCache（内核） ───fsync()───► 磁盘
                                  │
                                  │ 默认 OS 30s 才异步 flush
                                  │ 或 dirty_ratio 触发回写
                                  ▼
                              （不调 fsync，断电这部分就丢）
```

**两条关键事实**：

1. **进程崩溃 PageCache 不丢**（OS 还在管理它）—— 这是 RocketMQ ASYNC_FLUSH 敢于"写完 PageCache 立即返回"的依据
2. **OS 崩溃或断电，PageCache 就丢了**—— 只有 fsync 走到磁盘的部分才安全

所以"性能 vs 可靠性"的 trade-off 本质是 **fsync 的频率**：

| 频率 | 性能 | 安全性 |
| --- | --- | --- |
| 每次 write 都 fsync | 差（TPS 几千）| 不丢 |
| 每秒 fsync 一次 | 好 | 最多丢 1 秒 |
| 让 OS 自己定（不调 fsync）| 最好 | 崩溃丢几十秒 |

### 3.3 fsync 时机：每个系统怎么选

| 系统 | 参数 | 默认 / 推荐 | 说明 |
| --- | --- | --- | --- |
| MySQL redo | `innodb_flush_log_at_trx_commit` | 1（每事务 fsync）| 双 1 配置的"1"之一；金融必选 1 |
| Redis AOF | `appendfsync` | everysec（每秒 fsync）| 互联网典型，最多丢 1 秒 |
| RocketMQ | `flushDiskType` | ASYNC_FLUSH（500ms 一次）| 同步主从 + 异步刷盘是主流取舍 |
| Raft（etcd）| `wal-fsync` | 每次 commit 前 | 共识协议要求强一致，不能省 |
| ZK txn log | 默认每次事务 fsync | 强制每次 | ZK 强一致语义保证 |

**为什么 Raft / ZK 不能"每秒 fsync 一次"**：共识协议要在多数派**承诺持久化**之后才向客户端返回成功。如果"承诺"的只是 PageCache 里的数据，节点重启它就丢了——多数派的"日志已复制"假设崩塌，整个 Raft 不变式被破坏。所以 **共识协议的 WAL 必须是同步刷盘**，没有"最终一致"的选项。

### 3.4 物理日志 vs 逻辑日志

| 类型 | 内容 | 优点 | 缺点 | 代表 |
| --- | --- | --- | --- | --- |
| **物理日志** | 页 X 偏移 Y 改成 Z | 幂等（重放多少次结果都一样）；快 | 日志体积大；只能恢复本系统格式 | MySQL redo |
| **逻辑日志** | 操作命令本身 | 体积小；可移植（如可发到从库回放） | 重放需要满足"幂等性"前提；恢复慢 | Redis AOF / MySQL binlog |
| **物理 + 逻辑** | 业务消息 / 状态机命令 | 体积适中；可复用为复制源 | 重放需要状态机幂等 | RocketMQ CommitLog / Raft Log / ZK txn log |

**MySQL 为什么需要 redo + binlog 两份日志**：redo 是物理日志（崩溃恢复快、但和 InnoDB 绑死无法做主从），binlog 是逻辑日志（可做主从复制、PITR，但崩溃恢复慢）。两者职责不重叠也无法合并——这就是上一篇《两阶段提交》的根本起源。

### 3.5 日志无限增长怎么办：五种压缩策略

WAL 一直追加，磁盘迟早撑爆。每个系统有自己的"压缩"机制：

| 系统 | 机制 | 触发 |
| --- | --- | --- |
| MySQL redo | **环形覆盖**：固定大小 `ib_logfile`，写满回头覆盖；前提是被覆盖部分对应的脏页已 checkpoint | 写指针追上 checkpoint 指针时阻塞业务，强制 flush 脏页 |
| Redis AOF | **AOF 重写**：fork 子进程基于当前内存生成精简日志（`SET key val × 100` 合成一条）| `auto-aof-rewrite-percentage 100` 默认翻倍后 |
| RocketMQ CommitLog | **过期删除**：按文件保留 72h，整文件删（不切单条消息）| 后台定时任务，凌晨 4 点执行 |
| Raft Log | **Snapshot + 截断**：状态机拍快照，删快照之前的所有 log entry | 配置 entry 数量或字节阈值 |
| ZK txn log | **Snapshot + 滚动**：定期 snapshot in-memory tree，删老 txn log | `autopurge.snapRetainCount` / `autopurge.purgeInterval` |

**核心范式**：**"最终态"持久化（checkpoint / snapshot / 重写）+ 增量日志**。WAL 不是日志单干，而是日志 + 周期性的全量快照搭配——前者保证最近变化不丢，后者控制日志体积。

---

## 四、关键场景：崩溃恢复

WAL 的存在意义就是崩溃恢复。这是各系统的恢复流程：

### 4.1 五种系统的恢复对比

| 系统 | 起点 | 重放内容 | 终点 |
| --- | --- | --- | --- |
| MySQL redo | checkpoint LSN | redo log 到末尾 | 重做未刷盘的脏页 |
| Redis AOF | 启动时 | 整个 AOF（或 RDB 快照 + 增量 AOF）| 重建内存数据 |
| RocketMQ CommitLog | 启动时 | 扫 CommitLog 重建 ConsumeQueue 索引 | 索引追平 |
| Raft Log | 加载 snapshot | snapshot 之后的 log entry 重放到状态机 | 状态机与 leader 一致 |
| ZK txn log | 加载 snapshot | snapshot 之后的 txn log 重放 | 内存 tree 一致 |

### 4.2 共同模式

```
启动
  │
  ├─ ① 加载最后一个完整的快照（如有）
  │
  ├─ ② 找到快照对应的日志位置（LSN / offset / log index）
  │
  ├─ ③ 从该位置开始顺序读后续日志条目
  │
  ├─ ④ 校验每条日志的完整性（CRC / 长度字段 / 魔数）
  │   └─ 第一个损坏的位置 → 截断到此（最后一条可能没写完）
  │
  ├─ ⑤ 重放每条日志到内存数据结构
  │
  └─ ⑥ 恢复完成，对外可服务
```

**关键设计点**：
- 日志**条目级 CRC**：能识别"写到一半崩溃"导致的最后一条不完整
- 日志**条目自描述长度**：扫描时能跳过条目找下一个起点
- **幂等重放**：每条日志重放多次结果一致（物理日志天然幂等；逻辑日志要靠 ID/版本号保证）

### 4.3 部分写问题（Torn Page）

磁盘的原子写入单位是扇区（512B 或 4KB），但日志条目可能跨多个扇区。崩溃时可能写入一半：

| 系统 | 应对 |
| --- | --- |
| MySQL | redo + double write buffer（先写双写缓冲区再写真实位置）|
| Redis AOF | 启动时检测尾部异常，截断不完整的最后一条；`redis-check-aof --fix` 修复 |
| RocketMQ | 每条消息有 magic code + CRC，损坏的从该位置截断 |
| Raft / ZK | 同上，CRC + 长度字段 + 截断 |

---

## 五、为什么所有系统都选 WAL

总结一下 WAL 提供的"工程红利"：

| 能力 | 怎么实现的 |
| --- | --- |
| **高写入 TPS** | 把随机写换成顺序写 |
| **崩溃不丢已确认数据** | fsync 后才返回成功；恢复时重放日志 |
| **快速恢复** | 只重放最后一段日志（配合 checkpoint）|
| **天然的复制源** | 把日志拷贝到副本节点重放，状态就一致（Raft / ZAB / binlog / Redis PSYNC）|
| **快照能力（PITR）** | 任意时刻的全量 = 起始快照 + 截至该时刻的日志 |
| **审计与溯源** | 日志本身就是变更的完整记录 |

→ **同一个范式同时解决"性能 + 可靠 + 复制 + 恢复"四件事**——这是 WAL 几乎统治持久化存储的根本原因。

---

## 六、生产踩坑

### 踩坑 1：以为 `write()` 就持久化了

**现象**：服务挂了再起来，数据丢了一段——明明业务代码看着是写完了的。

**根因**：业务用了某框架的"异步日志"或"批量缓冲"，写到 PageCache 后没 fsync。机器一断电，PageCache 全丢。

**修复**：明确知道每一层缓冲——业务 buffer → kernel PageCache → 磁盘控制器 cache → 盘片。**只有 fsync 走完到磁盘**才能承诺持久化。带电池/电容的 RAID 卡和 SSD 内部 cache 有"假 fsync"的概念，金融场景要禁掉 disk write cache 或确保有 BBU/电容保护。

### 踩坑 2：MySQL 双 1 关掉换性能，断电丢事务

**现象**：DBA 改成 `innodb_flush_log_at_trx_commit=2` + `sync_binlog=1000`，TPS 翻倍——结果机房断电后业务系统少了 2000 笔交易。

**根因**：`innodb_flush_log_at_trx_commit=2` 意味着 redo 只 write 到 OS PageCache，不每次 fsync。断电 PageCache 丢。

**修复**：核心交易表必须双 1（`innodb_flush_log_at_trx_commit=1` + `sync_binlog=1`）。互联网容许少量丢失的业务可改 `=2 + sync_binlog=100~1000`，但要做好"丢几秒交易"的预期管理。

### 踩坑 3：Redis AOF 重写期间内存翻倍 OOM

**现象**：Redis 实例运行半年好好的，某天定时重写 AOF 时 OOM。

**根因**：AOF 重写 fork 子进程，COW 机制下父进程持续写入引发大量页复制，瞬间内存翻倍。`maxmemory` 设到了机器 80%，重写一来就崩。

**修复**：① `maxmemory` 设到机器内存 50% 以下，给 fork 留余地；② 关闭 THP（Transparent HugePage），否则 COW 触发的是 2MB 而不是 4KB 的复制；③ 写入压力大的实例考虑关 AOF 只用 RDB，或用混合持久化降低重写频率。

### 踩坑 4：RocketMQ ASYNC_FLUSH 下断电丢消息

**现象**：宣传"消息可靠"的业务系统，机房断电后丢了若干分钟消息。

**根因**：默认 `ASYNC_FLUSH` 是写 PageCache 立即返回，后台 500ms 才 fsync 一次。机房整体断电时 PageCache 那 500ms 的数据全丢。

**修复**：① 选 `SYNC_FLUSH`（性能下降 50%）；② 或保持 ASYNC_FLUSH 但配 `SYNC_MASTER`（主从同步复制，本地丢从机还有）；③ 业务侧 Producer 收到失败必须重试 + 幂等消费兜底。

→ 细节见 [MQ/刷盘与复制](../MQ/刷盘与复制.md)

### 踩坑 5：Raft 节点磁盘满后整个集群不可写

**现象**：etcd 集群 3 节点，一个节点磁盘满了，整个集群对外停止接受写入。

**根因**：Raft 要求 commit 必须多数派持久化。3 节点集群一个磁盘满 → 写不进 WAL → 这个节点不会回复 ACK → 但 Leader 必须等多数派（2/3）ACK 才能 commit；这个节点的"超时不响应"被识别后还会触发 leader election，集群震荡。

**修复**：① 磁盘容量监控告警阈值设到 70% 而不是 90%；② Snapshot + Log compaction 配置合理，别让日志无限增长；③ 关键集群单独挂 SSD，不要和其它 IO 密集服务混部。

### 踩坑 6：ZK txn log 和 snapshot 都写在同一块盘上，IO 抖动选主失败

**现象**：ZK 集群偶发"选不出 Leader"，业务的 Dubbo 服务发现完全瘫痪。

**根因**：ZK 默认 `dataDir` 同时存 snapshot 和 txn log，写盘抖动时事务 fsync 卡住 → 心跳超时 → 触发 leader election → 选举期间也写不动 → 雪崩。

**修复**：`dataDir` 和 `dataLogDir` 分到**不同物理盘**，让 txn log 顺序写不被 snapshot 的大块写阻塞。

---

## 七、面试高频追问

### Q1：为什么所有数据库/MQ/共识协议都用 WAL？

四个工程红利同时满足，且代价小：① 顺序写比随机写快 100x，解决性能；② 日志持久化即承诺，解决可靠；③ 日志重放即恢复，解决崩溃；④ 日志拷贝即复制，解决主从。这是单一范式解决多个问题的极致案例——所以几乎没人发明别的方案。

### Q2：MySQL 已经有 buffer pool 了为什么还要 redo？

buffer pool 是"快"的数据结构（内存中的页），但**断电就丢**。WAL（redo）解决"持久化"——commit 时不需要把脏页随机写到磁盘，只需要把这次变更顺序追加到 redo，业务返回就立即成功；脏页可以慢慢异步 flush。**redo 让"快"和"不丢"同时成立**。

### Q3：write 和 fsync 区别？为什么 write 不够？

`write` 把数据从应用 buffer 拷到内核 PageCache 就返回——速度快但只在内存里。**OS 崩溃或断电，PageCache 那段数据没了**。`fsync` 强制把对应 PageCache 的脏页写到磁盘并等待磁盘返回——这才是真正的"持久化"承诺。

延伸：`fdatasync` 类似 fsync 但只刷数据不刷元数据，开销略小。MySQL/Redis 用 fdatasync 优化。

### Q4：物理日志和逻辑日志怎么选？

- **物理日志**（redo）：体积大但重放幂等 + 恢复快；缺点是和存储引擎绑死，无法跨引擎复制
- **逻辑日志**（binlog / AOF）：体积小、可复制、可跨版本；缺点是恢复慢、重放要求幂等

数据库引擎自身的崩溃恢复用物理日志；做主从复制 / PITR 用逻辑日志。MySQL 两个都用就是这个原因。

### Q5：Redis AOF 重写时为什么 fork 子进程，会卡主线程吗？

fork 时 OS 通过 COW（Copy-On-Write）共享父子进程内存——fork 本身只复制页表，**毫秒级**。但页表如果有几十 GB 数据要 copy（大实例），fork 也可能阻塞 1~2 秒。

重写期间父进程继续接收写入：① 把命令写到原 AOF（兜底）；② 写到 `aof_rewrite_buffer`。子进程重写完通知父进程，父进程把 buffer 追到新 AOF，atomic rename 替换。**主线程除了 fork 那一瞬间，几乎不被阻塞**。

→ 细节见 [Redis/持久化.md](../Redis/持久化.md)

### Q6：Raft Log 和数据库 redo 是同一个概念吗？

**骨架是的，目的不一样**：

- 数据库 redo：解决**单机崩溃恢复**
- Raft Log：解决**多机一致性**（Leader 把 log 复制到多数派后才 commit）

但都是 WAL：都是顺序追加 + fsync + 重放 + 快照截断。区别在 Raft Log 的"承诺"要等多数派落盘，所以**Raft 必须每次 fsync**，不能用"每秒一次"那种取舍。

### Q7：为什么 PageCache 在 WAL 这套体系里这么重要？

WAL 性能的真正秘密：① 应用 `write` 顺序追加到 mmap 区域（实际是 PageCache）→ 完全内存操作，纳秒级；② 后台慢慢 fsync 落盘——把磁盘写从同步路径上**移到异步路径**。

如果没有 PageCache：每次写都要等磁盘 fsync 返回 ≈ ms 级，TPS 上限几千；有 PageCache + 异步 fsync 策略：TPS 上百万。**PageCache 是 WAL 跑得快的隐藏底座**——但也是 ASYNC_FLUSH 断电会丢的根源。

### Q8：日志会无限增长怎么办？

通用范式：**checkpoint / snapshot + 日志截断**。即"周期性把内存当前状态做一次全量持久化（snapshot），之后只保留 snapshot 之后的日志"。

- MySQL redo：环形覆盖，配合 buffer pool 脏页 checkpoint
- Redis：AOF rewrite + RDB 快照
- RocketMQ：CommitLog 按时间过期删（特殊：不做 checkpoint，因为消息本身就是"日志"，72h 后业务认为消费完了直接删）
- Raft / ZK：状态机/数据树做 snapshot，截断 snapshot 之前的 log

RocketMQ 的特殊在于：它的"主存储"就是 CommitLog 本身（ConsumeQueue 只是索引），所以没有"日志 vs 主存储"的区分，只有"过期清理"。

### Q9：为什么共识协议（Raft / ZAB）不能用 ASYNC_FLUSH？

共识协议的核心承诺是 **"被多数派 commit 的日志永不丢失"**。如果节点用 ASYNC_FLUSH，回了 ACK 但数据其实只在 PageCache：
- 该节点重启 → 数据丢
- Leader 已经认为多数派承诺，发了 commit 给客户端
- 但实际只有少数派有这条 log → **一致性破坏**

所以共识协议**必须** fsync 后才回 ACK，性能换正确性。这是 etcd / ZK 写 QPS 比 Redis 低一两个量级的根本原因。

### Q10：能不能不要 WAL？比如直接每次写都落盘？

可以，但代价是**TPS 掉到几百**。绕过 WAL 的方式：

- **同步随机写**：直接每次都把数据写到最终位置 + fsync，TPS ≈ 几百
- **纯内存**：放弃持久化（如 Memcached / Redis 关掉所有持久化）
- **追加写但不分日志**（LSM-Tree）：每次写都是顺序追加到 SSTable，看似没有"日志"，但本质上 WAL（写之前先写到 memtable + WAL）+ SSTable 合并

主流的 LSM 引擎（LevelDB / RocksDB / Cassandra / HBase）依然有 WAL，因为 memtable 在内存里崩溃会丢——LSM 是"WAL 范式的进化版"，不是替代。

---

## 八、答题模板（60 秒话术）

> **WAL（Write-Ahead Logging）的核心规则只有一句**：**修改任何持久化数据结构之前，先把变更顺序追加写到一个日志文件，且日志 fsync 落盘后才能向客户端确认成功**。崩溃后从最近的 checkpoint 起重放日志即可恢复。
>
> **为什么所有持久化系统都用它**：① 把随机写换成顺序写，TPS 提升 100 倍（磁盘顺序写 ~10µs vs 随机写 ~5ms）；② fsync 承诺让"不丢"和"快"同时成立；③ 日志本身就是天然的复制源（主从复制 / Raft 复制）；④ 日志重放就是恢复，恢复时间可控。
>
> **同构实现**：① MySQL redo（环形 + 物理日志 + 双 1 fsync）；② Redis AOF（追加 + 逻辑命令 + 每秒 fsync）；③ RocketMQ CommitLog（mmap + 整条消息 + 异步刷盘+同步主从）；④ Raft Log（每次 commit 同步 fsync + snapshot 截断）；⑤ ZK txn log（同步 fsync + 周期 snapshot）。
>
> **关键 trade-off 是 fsync 频率**：每次 fsync 最安全但 TPS 几千；每秒一次平衡型，最多丢 1 秒；OS 自决最快但断电丢几十秒。**共识协议（Raft/ZK）必须每次 fsync**，不接受最终一致；数据库金融场景双 1，互联网容许少量丢失常用每秒或 N 事务一次。
>
> **日志无限增长靠 checkpoint/snapshot + 截断**解决：MySQL 是环形覆盖、Redis 是 AOF 重写、Raft/ZK 是 snapshot 后截断、RocketMQ 是按时间整文件过期删。

---

## 九、相关文档

### 本模块（横向）

- [两阶段提交与事务消息](./两阶段提交.md) — 2PC 的 Prepare 阶段就是把变更写到 WAL
- [长轮询 Long Polling](./长轮询.md) — 长轮询的"变化事件"通常由 WAL 写入派生（如 CommitLog 写入触发 notify）
- [主从复制范式](./主从复制范式.md) — WAL 自然就是复制源

### 具体实现（纵向，回到原模块）

- [MySQL/日志.md](../MySQL/日志.md) — redo / binlog / undo 三大日志细节
- [Redis/持久化.md](../Redis/持久化.md) — RDB / AOF / 混合持久化
- [MQ/存储机制.md](../MQ/存储机制.md) — CommitLog / ConsumeQueue / mmap + PageCache
- [MQ/刷盘与复制.md](../MQ/刷盘与复制.md) — SYNC_FLUSH vs ASYNC_FLUSH、同步主从
- [Distributed/一致性算法.md](../Distributed/一致性算法.md) — Raft / ZAB 的日志复制
- [Network/零拷贝.md](../Network/零拷贝.md) — mmap / sendfile / DMA 的底层支撑
