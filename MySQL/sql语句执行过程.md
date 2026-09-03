# SQL 语句执行过程

> 面试经典："一条 update 语句在 MySQL 内部走了什么流程"——能把这道题讲透，等于把架构、引擎、日志、事务、复制串起来一遍。
>
> 关键三块：① 查询流程（含 Buffer Pool 命中） → ② 更新流程（**核心：两阶段提交**） → ③ 崩溃恢复时事务怎么定生死。

---

## 一、查询流程：SELECT 怎么跑

```sql
SELECT * FROM t WHERE id = 10;
```

```
Connector  ─→  Parser  ─→  Preprocessor  ─→  Optimizer  ─→  Executor
                                                             │
                                                             ▼ Handler API
                                              ┌──────────────────────────┐
                                              │ InnoDB                    │
                                              │  1. Buffer Pool 查页      │
                                              │     ├ 命中 → 直接读       │
                                              │     └ 未命中 → 磁盘 IO    │
                                              │  2. 走聚簇索引 B+Tree     │
                                              │  3. 返回符合 WHERE 的行   │
                                              └──────────────────────────┘
                                                             │
                                              Server 层 Executor 处理 LIMIT/聚合
                                                             │
                                                             ▼ 网络协议
                                                          客户端
```

**关键细节**：

1. **Connector**：长连接复用，避免每次 TCP+鉴权开销。
2. **Parser**：把 SQL 文本变 AST，语法错在这一步报错。
3. **Preprocessor**：表/列存在性校验 + 权限检查（注意：**预处理后，权限改了已建连接不感知**）。
4. **Optimizer**：基于代价（统计信息中的行数 + IO/CPU 因子）选索引、定 join 顺序。
5. **Executor**：调引擎 `index_read()`，**逐行**拉取——LIMIT 满了立即停（不会读完整张表）。
6. **InnoDB**：先看 Buffer Pool 缓存页是否命中（典型命中率 99%+），未命中触发 IO。

---

## 二、更新流程（必背重点）

```sql
UPDATE t SET c = c + 1 WHERE id = 10;
```

完整流程见下：

```
 ┌── 1. Server 层 ─────────────────────────────────────────────┐
 │   Parser → 校验权限 → Optimizer 决定走 PRIMARY               │
 │   Executor 调 InnoDB:index_read(10)                          │
 └─────────────────────────────────────────────────────────────┘
                              │
 ┌── 2. InnoDB 加锁 ───────────────────────────────────────────┐
 │   ① 服务器层加 MDL 共享读锁（防 DDL）                        │
 │   ② 表上加 IX 意向锁                                         │
 │   ③ 行上加 X 锁（基于聚簇索引项）                            │
 └─────────────────────────────────────────────────────────────┘
                              │
 ┌── 3. 查找 + 改 Buffer Pool ─────────────────────────────────┐
 │   ① Buffer Pool 找数据页                                    │
 │     ├─ 命中 → 直接改                                         │
 │     └─ 未命中 → 从磁盘加载到 Buffer Pool 再改                │
 │   ② 老值写 undo log（缓冲）→ 用于回滚 + MVCC                  │
 │   ③ 新值落到内存数据页 → 此页变 "脏页"                       │
 │   ④ 修改内容写 redo log buffer                                │
 └─────────────────────────────────────────────────────────────┘
                              │
 ┌── 4. 提交（两阶段提交） ─────────────────────────────────────┐
 │   Phase 1: redo log 写入磁盘并状态标 prepare                 │
 │   Phase 2: Server 层写 binlog                                │
 │   Phase 3: redo log 标 commit                                │
 └─────────────────────────────────────────────────────────────┘
                              │
 ┌── 5. 释放锁，返回 affected_rows ────────────────────────────┐
 └─────────────────────────────────────────────────────────────┘
                              │
 ┌── 6. 后续异步 ──────────────────────────────────────────────┐
 │   ① 脏页由 Master Thread 异步刷盘（checkpoint）              │
 │   ② Slave I/O Thread 拉 binlog → 本地 relay log → 回放        │
 │   ③ Purge Thread 清理 undo（无 ReadView 引用后）              │
 └─────────────────────────────────────────────────────────────┘
```

> **关键认知**：
> - **更新成功 ≠ 数据落盘**——修改先在 Buffer Pool（脏页），再异步刷
> - **不丢数据靠 redo log**（事务提交前已落盘）
> - 这就是著名的 **WAL（Write-Ahead Logging）** 思想：先写日志、后改数据

---

## 三、两阶段提交（XA / 2PC）

> 这是 MySQL 面试的"黄金考点"——**为什么 redo log 和 binlog 要做两阶段提交？**

### 3.1 两个日志各自角色

| 日志 | 层 | 类型 | 作用 |
| --- | --- | --- | --- |
| redo log | InnoDB 引擎 | **物理日志**（"页 X 偏移 Y 改成 Z"） | 崩溃恢复（保证持久性） |
| binlog | Server 层 | **逻辑日志**（SQL/行变更） | 主从复制 + 时间点恢复 |

### 3.2 不做两阶段会出什么问题？

**反例 A：先写 redo，再写 binlog**

```
1. redo log 写完（持久性已保证）
2. 系统崩溃
3. binlog 还没写
4. 重启后 redo log 重放 → 主库数据有更新
   但 binlog 没记录 → 从库永远收不到 → 主从不一致
```

**反例 B：先写 binlog，再写 redo**

```
1. binlog 写完（已发到从库）
2. 系统崩溃
3. redo log 还没写
4. 重启后主库恢复时这个事务不存在 → 但从库已执行 → 主从不一致
```

### 3.3 两阶段提交怎么解决

```
事务提交流程：

    1. redo log 状态置为 PREPARE，写入磁盘
              │
              ▼
    2. binlog 写入磁盘（成功 = 主从一致性的"承诺点"）
              │
              ▼
    3. redo log 状态置为 COMMIT
```

**崩溃恢复时**，扫描 redo log，按事务状态决定：

| 事务状态 | binlog 是否完整 | 处理 |
| --- | --- | --- |
| COMMIT | 不需查（必然完整） | 提交 |
| PREPARE | binlog 完整 | **提交**（认为客户端已知道结果） |
| PREPARE | binlog 不完整 | **回滚** |
| 不存在（连 PREPARE 都没到） | — | 数据未变，无需处理 |

> 这个"binlog 完整就提交"的设计意图：**binlog 是主从复制的"凭证"，只要从库可能见过它，主库就必须保留这个事务**。

### 3.4 为什么不直接用一个日志？

历史上：binlog 是 Server 层做主从复制必须的（多引擎共用），redo log 是 InnoDB 引擎崩溃恢复必须的——两者职责不重叠也不能合一。

> 合一的尝试是 8.0 的 **clone plugin** + 增量复制改进，但 **redo + binlog 双日志** 仍是默认架构。

---

## 四、刷盘控制：性能 vs 持久性

| 参数 | 取值 | 说明 |
| --- | --- | --- |
| `innodb_flush_log_at_trx_commit` | 0 | 每秒刷一次 redo（崩溃丢 1 秒） |
|  | **1**（默认） | 每次提交都 fsync redo（最安全，最慢） |
|  | 2 | 每次提交写 page cache，每秒 fsync（OS 崩溃丢 1 秒） |
| `sync_binlog` | 0 | 由 OS 决定刷盘时机 |
|  | **1**（默认） | 每次提交都 fsync binlog |
|  | N>1 | 每 N 个事务 fsync 一次 |

> **金融级要求**：两个都设 1（双 1 配置），但 IOPS 压力大。
> **互联网容忍少量丢失**：常用 `flush_log=2 + sync_binlog=1000`，吞吐高很多。
> **典型坑**：DBA 把 `sync_binlog=0` 调来抗写入，主从复制延迟 + 主库宕机就丢数据。

---

## 五、autocommit 与显式事务

```sql
SHOW VARIABLES LIKE 'autocommit';  -- 默认 ON
```

- `autocommit = ON`：每条 DML 是一个独立事务，执行完自动提交
- `autocommit = OFF` 或 `BEGIN` / `START TRANSACTION` 显式开启：直到 `COMMIT` 或 `ROLLBACK` 才结束

> **生产坑**：JDBC 默认 `autoCommit=true`，而某些 ORM 框架（如老 MyBatis）可能切到 false 但忘记 commit → 锁不释放、连接被占。Spring `@Transactional` 是显式事务，注意事务边界。

---

## 六、查询是否走 Buffer Pool

```sql
SHOW STATUS LIKE 'Innodb_buffer_pool_read%';
```

| 指标 | 含义 |
| --- | --- |
| `Innodb_buffer_pool_read_requests` | 总读请求数（含命中） |
| `Innodb_buffer_pool_reads` | 真正发起磁盘 IO 的数 |

**命中率** = `1 - reads / read_requests`，应 >99%。低于这个值要扩 `innodb_buffer_pool_size`（典型机器物理内存的 50%~75%）。

---

## 七、生产踩坑

### 7.1 大事务把主从拉爆

事务太大 → binlog 单条事件巨大 → 从库回放时整张表锁住（5.7 前甚至单线程回放）。

**对策**：
- 大批量更新拆 BATCH（每批 1000~5000 行）
- 5.7+ 启用并行复制（`slave_parallel_type=LOGICAL_CLOCK`）

### 7.2 主从切换后丢数据

主库崩溃，redo 已 PREPARE 但 binlog 未发到从库 → 主从切换后，新主缺这个事务 → **数据丢失**。

**根因**：异步复制的天然问题。
**对策**：半同步复制（`rpl_semi_sync_master_enabled=1`）+ MGR 多副本。

### 7.3 误以为 commit 就一定落盘

`flush_log_at_trx_commit=2` 时，commit 返回成功 ≠ 数据已 fsync 到磁盘——OS 崩溃会丢最近 1 秒事务。金融场景要双 1。

---

## 八、面试高频追问

### Q1：MySQL 一条 update 语句的全过程？

按上面的流程图复述：连接 → 解析 → 优化 → 执行器 → 引擎加锁 → 改 Buffer Pool + 写 undo + 写 redo → 两阶段提交 → 释放锁 → 返回。

### Q2：为什么要两阶段提交？不能一个日志吗？

binlog 是 Server 层主从复制必须，redo log 是引擎层崩溃恢复必须，职责不重叠。先 redo 后 binlog 或先 binlog 后 redo 都会主从不一致——必须用 2PC 协调。

### Q3：崩溃恢复时怎么决定事务的生死？

扫 redo：
- 事务状态 = COMMIT：提交
- 状态 = PREPARE 且 binlog 完整：提交（已发出去了，必须保留）
- 状态 = PREPARE 但 binlog 不完整：回滚

### Q4：commit 返回成功，数据一定到磁盘了吗？

取决于 `innodb_flush_log_at_trx_commit`：
- 1（默认）：redo 已 fsync，断电不丢
- 2：redo 在 page cache，OS 崩溃可能丢
- 0：每秒一次 fsync，崩溃可能丢 1 秒

**数据页**总是异步刷的，靠 redo 保证不丢。

### Q5：WAL 是什么意思？

Write-Ahead Logging：**先写日志、后改数据**。理由：日志是顺序追加（快），数据页是随机 IO（慢），用顺序 IO 代替随机 IO，性能数十倍提升。

### Q6：autocommit=ON 的事务安全吗？

每条 DML 都是独立事务、独立提交，**安全**。但**多条 DML 之间没有原子性**——要原子性必须显式 `BEGIN ... COMMIT`。

### Q7：为什么要先加 MDL 锁？

防止事务执行期间别人 ALTER TABLE 改了表结构 → 列对不上、索引消失。MDL 是 Server 层的元数据保护。

---

## 九、答题模板（60 秒话术）

> 一条 update 在 MySQL 里走的路：
>
> ① 客户端 → Connector 鉴权 → Parser 解析 → Optimizer 选索引 → Executor。
>
> ② 进 InnoDB：先加 MDL 读锁、IX 意向锁、行 X 锁，找到数据页（Buffer Pool 命中或加载）。
>
> ③ 老值写 undo log，新值改 Buffer Pool 数据页（变脏页），变更写 redo log buffer。
>
> ④ commit 时走**两阶段提交**：redo prepare → binlog 写入 → redo commit。这保证 redo 和 binlog 一致——崩溃恢复时按 binlog 完整性来定事务命运。
>
> ⑤ commit 返回后，脏页由后台线程异步刷盘（checkpoint），undo 由 Purge 线程异步清理，binlog 由 dump thread 推给从库。
>
> 这套设计核心思想是 **WAL**：日志顺序写代替数据页随机写，性能提升一个数量级。

---

## 十、相关文档

- [架构总览](./架构总览.md) — 分层架构 + 引擎对比
- [InnoDB 存储引擎](./InnDB.md) — Buffer Pool / Change Buffer 细节
- [日志](./日志.md) — redo / undo / binlog 完整对比
- [事务的原理](./事务的原理.md) — ACID 实现
- [MVCC](./mvcc.md) — 快照读机制
- [主从复制](./主从复制.md) — binlog 怎么变成从库数据
