# MVCC 多版本并发控制

> **MVCC**（Multi-Version Concurrency Control）是 InnoDB 实现 **读不加锁、读写不阻塞** 的核心机制，也是 RC / RR 隔离级别能高并发的根本原因。
>
> 面试要讲清三件事：① 为什么要 MVCC（不是为了取代锁）→ ② 它由哪几块拼起来 → ③ RC 和 RR 在 MVCC 上的差异（最高频追问）。

---

## 一、为什么需要 MVCC

### 1.1 纯锁方案的瓶颈

只用锁实现隔离性，会出现：

| 场景 | 纯锁方案 | 问题 |
| --- | --- | --- |
| 读读 | 都加 S 锁，相容 | OK |
| 读写 | 读阻塞写 / 写阻塞读 | OLTP **读多写少**，并发被读拖死 |
| 写写 | 互斥 | 必须串行 |

**核心矛盾**：业务上"读"和"写"操作的是同一逻辑行，但不一定操作的是同一**版本**。如果能让"读"读到旧版本、"写"在新版本上动手，读写就不必互相等。

### 1.2 MVCC 的价值

> **一句话**：让读操作访问历史版本（快照读），写操作改最新版本（当前读），二者不打架。

适用范围：

| 隔离级别 | MVCC 是否生效 | 备注 |
| --- | --- | --- |
| READ UNCOMMITTED | ❌ | 读最新行（含未提交）→ 不需要快照 |
| READ COMMITTED | ✅ | **每次 SELECT 生成新 ReadView** |
| REPEATABLE READ | ✅ | **事务首次 SELECT 生成 ReadView，全程复用** |
| SERIALIZABLE | ❌ | 所有 SELECT 加 S 锁，退化成纯锁方案 |

> **MVCC 只解决"快照读"的并发问题。当前读（`SELECT ... FOR UPDATE`、UPDATE、DELETE）一律走最新版本 + 加锁，由锁机制解决，不走 MVCC**。

---

## 二、MVCC 的三大组件

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  隐藏字段     │ →  │  undo 版本链  │ ←  │  ReadView    │
│ trx_id       │    │ 历史版本      │    │ 可见性判断   │
│ roll_pointer │    │ 回滚 + 快照   │    │              │
└──────────────┘    └──────────────┘    └──────────────┘
       数据来源              历史                判断规则
```

### 2.1 行记录的隐藏字段

InnoDB 每行都额外保留三个隐藏列：

| 字段 | 大小 | 作用 |
| --- | --- | --- |
| `DB_TRX_ID` | 6 字节 | 最近修改本行的事务 ID |
| `DB_ROLL_PTR` | 7 字节 | 回滚指针，指向 undo log 中的上一个版本 |
| `DB_ROW_ID` | 6 字节 | 隐式主键，仅当表无主键且无 NOT NULL UNIQUE 索引时才会有 |

> 面试常问"InnoDB 行记录有几个隐藏列？"——**两个必有（trx_id、roll_pointer）+ 一个条件性有（row_id）**，回答 3 个不准确。

### 2.2 Undo Log 与版本链

修改一条记录时，InnoDB **不直接覆盖**，而是：

1. 把旧值写入 undo log；
2. 在 undo log 中保留旧版本的所有列 + 旧 trx_id + 旧 roll_pointer；
3. 把新值写到行上，新行的 roll_pointer 指向 undo 中的旧版本。

形成一条**单向链表**：

```
[当前行: trx_id=300, name="张三"]
        │ roll_pointer
        ▼
[undo: trx_id=200, name="李四"]
        │ roll_pointer
        ▼
[undo: trx_id=100, name="王五"]
        │
        ▼ (NULL = 链尾)
```

**两类 undo**：

| 类型 | 触发 | 何时清理 |
| --- | --- | --- |
| Insert undo | INSERT | 事务提交后**立即可清** |
| Update undo | UPDATE / DELETE | **不能立即清**——还要给其它快照读用，由 **Purge 线程**判断"没有任何 ReadView 还可能用到"才清 |

> **生产坑（高频追问）**：长事务 → undo 链不能清 → ibdata 膨胀。线上见过单库 ibdata 涨到几百 GB，根因就是某个 SELECT 跑了几小时没结束。

### 2.3 ReadView（一致性视图）

ReadView 是事务在某个时刻看世界的"快照协议"。它**不存数据**，只存"哪些事务的修改对我可见"的判断依据。

```
ReadView {
    m_ids       : 生成时刻仍活跃（未提交）的事务 ID 列表
    min_trx_id  : m_ids 中的最小值
    max_trx_id  : 系统下一个将分配的事务 ID（即生成时刻最大已分配 + 1）
    creator_trx_id : 创建该 ReadView 的事务 ID
}
```

> **关键认知**：`max_trx_id` ≠ 当前最大事务 ID，而是**下一个**要分配的（开区间上界）。这是高频陷阱。

---

## 三、可见性判断算法

读到某行时，拿出该行的 `DB_TRX_ID`，按下表判断：

| 条件 | 含义 | 处理 |
| --- | --- | --- |
| `trx_id == creator_trx_id` | 本事务自己改的 | **可见** |
| `trx_id < min_trx_id` | 修改本行的事务在 ReadView 生成前**已提交** | **可见** |
| `trx_id >= max_trx_id` | 修改本行的事务在 ReadView 生成**之后**才启动 | **不可见** |
| `min_trx_id <= trx_id < max_trx_id` 且 `trx_id ∈ m_ids` | 生成时刻该事务**仍活跃**（未提交） | **不可见** |
| `min_trx_id <= trx_id < max_trx_id` 且 `trx_id ∉ m_ids` | 生成时刻该事务**已提交** | **可见** |

不可见时，沿 `roll_pointer` 跳到 undo log 上一个版本，重复判断，直到找到可见版本或链尾（链尾代表行未生成 → 看不到）。

### 3.1 一个具象例子（必背）

假设系统中：

- 事务 100、200 已提交
- 事务 300 正在跑，刚刚 UPDATE 了 row1（`name: "原值" → "300改"`）
- 事务 400 启动并 SELECT row1，此时事务 500 还没开始

事务 400 生成的 ReadView：
- `m_ids = [300]`（只有 300 还活跃；400 是 creator 不算）
- `min_trx_id = 300`
- `max_trx_id = 401`（下一个）
- `creator_trx_id = 400`

读 row1：行上 `trx_id = 300` → 落在 `[min, max)` 且在 `m_ids` 中 → **不可见** → 跟 roll_pointer 找到旧版本 `name="原值", trx_id=200` → `200 < min_trx_id=300` 且已提交 → **可见**。

事务 400 看到的是 `"原值"`。✅

---

## 四、RC vs RR 的核心差异（最高频追问）

> **同一套 MVCC 机制，仅靠 ReadView 生成时机的不同，就实现了两种隔离级别。**

| 维度 | READ COMMITTED | REPEATABLE READ |
| --- | --- | --- |
| ReadView 生成时机 | **每次 SELECT 都新建** | **事务内首次 SELECT 时生成，复用到事务结束** |
| 现象 | 能看到其他事务**已提交**的最新数据 | 事务内多次读结果一致 |
| 不可重复读 | 出现 | 不出现 |
| 幻读（快照读） | 出现 | 不出现 |

### 4.1 同一例子两种隔离的差别

```
T1: BEGIN
T1: SELECT * FROM t WHERE id=1   -- 读到 v1
        T2: BEGIN; UPDATE t SET v=v2 WHERE id=1; COMMIT
T1: SELECT * FROM t WHERE id=1   -- 第二次读
T1: COMMIT
```

- **RC**：第二次读会**重新生成 ReadView**，T2 已提交不在 m_ids → 看到 v2 → **不可重复读**
- **RR**：第二次读**复用**首次生成的 ReadView，T2 在 m_ids 中（即使已提交也按当时状态判断）→ 看到 v1 → **可重复读**

### 4.2 隐藏陷阱：RR 的 ReadView 真的是"事务开始"时生成吗？

**不是！** 是事务内**第一条 SELECT** 时生成。

```
T1: BEGIN                              -- ReadView 还没生成
        T2: BEGIN; UPDATE t SET v=v2 WHERE id=1; COMMIT
T1: SELECT * FROM t WHERE id=1         -- 这里才生成 ReadView，T2 已提交 → 看到 v2
```

> **面试陷阱题**：BEGIN 后没读、其它事务改完，BEGIN 的事务再读会读到哪个？答案是**改后的版本**（因为 ReadView 在 SELECT 时才建）。如果想"事务一开始就拍快照"，要用 `START TRANSACTION WITH CONSISTENT SNAPSHOT`。

---

## 五、MVCC 与幻读

### 5.1 幻读的两种语义

| 语义 | 描述 | MVCC 能否解决 |
| --- | --- | --- |
| 同一查询前后**行数变化** | 别的事务 INSERT 了新行 | RR 下快照读 ✅ 解决 |
| 当前读再次执行**看到新行** | 即 SELECT ... FOR UPDATE 看到了新行 | ❌ 解决不了，需 **间隙锁/临键锁** |

### 5.2 RR 下幻读"消失"的真相

```
T1: BEGIN
T1: SELECT * FROM t WHERE age>20  -- 快照读，得到 3 行
        T2: INSERT (age=25); COMMIT
T1: SELECT * FROM t WHERE age>20  -- 快照读，仍是 3 行（ReadView 复用）
```

✅ RR + MVCC 解决快照读幻读。

### 5.3 但有一种情况 RR 仍会幻读：当前读穿透

```
T1: BEGIN
T1: SELECT * FROM t WHERE age>20                -- 3 行
        T2: INSERT (age=25); COMMIT
T1: SELECT * FROM t WHERE age>20 FOR UPDATE     -- 4 行！
```

`FOR UPDATE` 是当前读，绕过 ReadView，直接读最新数据 → 幻读出现。

**InnoDB 怎么救**：当前读时加 **Next-Key Lock**（行锁 + 间隙锁），阻止其他事务在该范围 INSERT。但前提是 **T1 必须先把范围用当前读"占住"**。

> **生产真坑**：开发者以为 RR 解决了所有幻读 → 结合 `SELECT ... FOR UPDATE` 写业务 → 间隙锁不够大 → 仍幻读 + 锁等待超时。详见 [锁机制](./锁机制.md#四加锁规则总结) 中加锁原则。

---

## 六、MVCC 流程：一次 SELECT 全过程

```
SELECT * FROM t WHERE id=10
    │
    ├─ 1. 从聚簇索引找到 id=10 的行记录
    │
    ├─ 2. 取行的 trx_id, roll_pointer
    │
    ├─ 3. 用 ReadView 判可见
    │       ├─ 可见 → 返回该版本
    │       └─ 不可见 → 沿 roll_pointer 找 undo 上一版本，回 3
    │
    └─ 4. 链尾仍不可见 → 视为不存在
```

UPDATE 流程（写操作走当前读 + 加锁）：

```
UPDATE t SET v=v2 WHERE id=10
    │
    ├─ 1. 加 X 锁（聚簇索引 record lock）
    ├─ 2. 当前读取最新行（不走 ReadView）
    ├─ 3. 写 undo log（记 v1）
    ├─ 4. 写 redo log（物理修改）
    └─ 5. 修改行上的 v、trx_id、roll_pointer
```

---

## 七、生产踩坑案例

### 7.1 长事务导致 undo 膨胀

**现象**：磁盘告警，ibdata 文件几百 GB；`SHOW ENGINE INNODB STATUS` 看 history list length 巨大。

**根因**：某 BI 慢查询跑了几小时事务没提交 → Purge 线程不能清理 undo → 历史版本越堆越多。

**排查**：
```sql
SELECT * FROM information_schema.innodb_trx
ORDER BY trx_started ASC LIMIT 10;
```
找到最老的事务 → kill 它。

**预防**：
- 应用层禁止长事务（业务事务 ≤ 1 秒）
- 监控 `Innodb_history_list_length`，>1000 万要告警
- 大查询走从库 / OLAP 系统

### 7.2 RR 下"读到自己写的"陷阱

```
T1: BEGIN
T1: SELECT * FROM t WHERE id=1   -- 看到 v1（ReadView 已建）
T1: UPDATE t SET v='new' WHERE id=1
T1: SELECT * FROM t WHERE id=1   -- 看到 'new'，不是 v1
```

**为什么？** 因为行的 trx_id == creator_trx_id（自己改的）→ 直接可见。这不是 bug，是 MVCC 的设计：**自己事务内的修改一定可见**。

### 7.3 误以为 SELECT 完全无锁

```
SELECT * FROM t WHERE id=1 LOCK IN SHARE MODE;
SELECT * FROM t WHERE id=1 FOR UPDATE;
```

这两个是**当前读**，会加 S/X 锁，**不走 MVCC**。新人误用 `FOR UPDATE` 看快照值，导致大量行锁堆积。

---

## 八、面试高频追问

### Q1：MVCC 用在哪几个隔离级别？

RC、RR。RU 直接读最新值，SERIALIZABLE 全部加锁。

### Q2：RC 和 RR 是怎么用同一套 MVCC 机制实现不同效果的？

**唯一区别是 ReadView 生成时机**：
- RC：每次 SELECT 重新生成 → 总能看到最新已提交
- RR：事务内首次 SELECT 生成、复用到结束 → 全程一致

### Q3：MVCC 解决幻读了吗？

**部分解决**。
- 快照读：RR + MVCC ✅ 解决（ReadView 复用）
- 当前读：MVCC 不管，靠 **Next-Key Lock**（间隙锁 + 行锁）阻止他人插入

### Q4：undo log 什么时候删？

- Insert undo：事务提交即删
- Update undo：必须等到**没有任何 ReadView 可能用到该版本**，由 Purge 线程异步清理。长事务会卡住 Purge。

### Q5：ReadView 里的 max_trx_id 是当前最大事务 ID 吗？

**不是**，是**下一个**要分配的（即"已分配最大值 + 1"）。`trx_id < max_trx_id` 用的是开区间。

### Q6：BEGIN 之后如果还没读，其它事务改完了再读，能读到改后吗？

**RR 下也能读到**——ReadView 在第一条 SELECT 时才建，BEGIN 不建。如要"事务开启即拍快照"，用 `START TRANSACTION WITH CONSISTENT SNAPSHOT`。

### Q7：MVCC 和锁是什么关系？

**互补**：
- 读：MVCC 提供无锁快照
- 写：行锁保证互斥
- 当前读：锁 + 当前数据，不走 MVCC

并不是"有 MVCC 就不要锁"——MVCC 只让快照读绕开锁，写仍要加锁。

### Q8：版本链可以无限长吗？

理论上可以，物理上由 Purge 不断清理。链越长，沿 roll_pointer 找版本越慢——这就是为什么长事务会让查询变慢的原因之一。

### Q9：MVCC 在 Cluster Index 和 Secondary Index 上一样吗？

**不一样**。二级索引行**没有 trx_id**，判断可见性靠：
1. 二级索引页有个 `PAGE_MAX_TRX_ID`（页级最大）
2. 若 `PAGE_MAX_TRX_ID < min_trx_id` → 整页可见，直接用
3. 否则回表到聚簇索引，按 trx_id 走标准判断

这就是为什么"覆盖索引"能跳过回表大幅加速。

---

## 九、答题模板（30 秒话术）

> MVCC 是 InnoDB 用 **undo 版本链 + ReadView** 实现的快照读机制，让读不加锁、读写不阻塞。
>
> 每行隐藏 trx_id、roll_pointer 两个字段，更新时旧值进 undo log，roll_pointer 把行串成版本链。
>
> 事务读的时候生成 ReadView（含活跃事务列表 m_ids、min/max_trx_id 等），按"自己改的 / 早提交的可见，活跃中或之后启动的不可见"判断可见性，不可见就沿链找旧版本。
>
> RC 和 RR 共用同一机制，只在 **ReadView 生成时机** 上有别——RC 每次 SELECT 都建，RR 整个事务复用一次。
>
> MVCC 只解决快照读的幻读，当前读（`FOR UPDATE`）的幻读还要靠间隙锁/临键锁。
>
> 生产上最大的坑是长事务卡住 Purge → undo 不清理 → 磁盘炸 + 查询变慢。

---

## 十、相关文档

- [事务隔离级别](./事务的隔离级别.md) — RC / RR 的整体差异
- [锁机制](./行锁.md) — Next-Key Lock 解决当前读幻读
- [日志](./日志.md) — undo log 物理结构
- [InnoDB 存储引擎](./InnDB.md) — Purge Thread 如何回收 undo
