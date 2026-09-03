# EXPLAIN 详解

> EXPLAIN 是 MySQL 排查慢 SQL 的**第一工具**——它告诉你"优化器决定怎么执行这条 SQL"。
>
> 面试核心三问：① 12 列各代表什么、最重要的是哪几个？ → ② type 从好到坏怎么排？ → ③ Extra 里看到 `Using filesort` / `Using temporary` 怎么办？

---

## 一、用法

```sql
EXPLAIN SELECT * FROM t WHERE id = 10;

-- 8.0+ 推荐：树形展示，更直观
EXPLAIN FORMAT=TREE SELECT * FROM t WHERE id = 10;

-- 8.0+ 实际执行版本（注意会真跑 SQL）
EXPLAIN ANALYZE SELECT * FROM t WHERE id = 10;
```

`EXPLAIN` **不实际执行**，只产出执行计划；`EXPLAIN ANALYZE` 才会执行。生产慎用 ANALYZE，避免锁表的查询真跑。

---

## 二、12 列含义速查

| 列 | 重要度 | 含义 |
| --- | --- | --- |
| **id** | ⭐⭐ | SELECT 的序号；同 id 顺序执行，id 大的先执行 |
| **select_type** | ⭐ | SELECT 类型（SIMPLE / SUBQUERY / DERIVED / UNION） |
| **table** | ⭐ | 涉及的表名（或派生表别名 `<derivedN>`） |
| partitions | — | 命中的分区 |
| **type** | ⭐⭐⭐ | **访问类型**——优化最重要的指标 |
| **possible_keys** | ⭐ | 可能用的索引 |
| **key** | ⭐⭐⭐ | 实际用的索引（NULL 即没用） |
| **key_len** | ⭐⭐ | 用了索引的几个字节——判断是否用全组合索引 |
| ref | ⭐ | 与 key 比较的列或常量 |
| **rows** | ⭐⭐⭐ | 估算扫描的行数（越小越好） |
| filtered | ⭐ | 过滤后剩余百分比；rows × filtered = 实际返回行数 |
| **Extra** | ⭐⭐⭐ | 附加信息——常含致命警告 |

> **三星列**：type、key、rows、Extra——出问题大概率在这四个。

---

## 三、id：执行顺序

### 3.1 简单查询

```sql
EXPLAIN SELECT * FROM t WHERE id = 10;
```
| id | table |
| -- | --- |
| 1 | t |

### 3.2 JOIN

```sql
EXPLAIN SELECT * FROM t1 JOIN t2 ON t1.id = t2.t1_id;
```
| id | table |
| -- | --- |
| 1 | t1 |
| 1 | t2 |

**id 相同**，按从上到下执行——优化器选 t1 为驱动表（小表），t2 为被驱动表。

### 3.3 子查询

```sql
EXPLAIN SELECT * FROM t1 WHERE id IN (SELECT t1_id FROM t2);
```
| id | table |
| -- | --- |
| 1 | t1 |
| 2 | t2 |

**id 不同，大的先执行**（先跑子查询拿结果，再到外层）。

---

## 四、type：访问类型（重中之重）

**从好到坏**：

```
system > const > eq_ref > ref > fulltext > ref_or_null > index_merge > range > index > ALL
```

生产可接受 **range 以上**；`index` 和 `ALL` 都是危险信号。

### 4.1 system

特殊的 const，只有一行的系统表。常见于 `mysql.proxies_priv`。

### 4.2 const（精确匹配）

主键或唯一索引等值查询：
```sql
EXPLAIN SELECT * FROM t WHERE id = 10;     -- type: const
```
**优化器直接知道结果只有一行**——视同常量。

### 4.3 eq_ref（连接时主键/唯一索引）

JOIN 时，被驱动表用主键/唯一索引匹配：
```sql
SELECT * FROM order o JOIN user u ON o.user_id = u.id;  -- u: eq_ref（u.id 是主键）
```

### 4.4 ref（非唯一索引等值）

```sql
KEY idx_name (name)
EXPLAIN SELECT * FROM t WHERE name = '张三';  -- type: ref
```

**最常见的"良好"类型**。

### 4.5 fulltext

走 FULLTEXT 索引。少见。

### 4.6 ref_or_null

ref 基础上额外搜 NULL：`WHERE name = 'a' OR name IS NULL`。

### 4.7 index_merge

用了**多个索引**合并结果（OR / AND）：
```sql
KEY idx_a (a), KEY idx_b (b)
SELECT * FROM t WHERE a=1 OR b=2;   -- index_merge
```

虽然走了索引但**通常不是最优**——加复合索引 `(a, b)` 往往更好。

### 4.8 range（范围扫描）

```sql
SELECT * FROM t WHERE id BETWEEN 10 AND 20;       -- range
SELECT * FROM t WHERE name LIKE '张%';            -- range
SELECT * FROM t WHERE id IN (1, 2, 3);            -- range
```

可接受。要警惕**范围太大变成接近全表**——`WHERE id > 1` 扫几乎全表，type 还是 range，但 rows 巨大。

### 4.9 index（索引全扫）

**扫全索引树**，比 ALL 好一点（索引比数据小）但仍是问题：
```sql
KEY idx_name (name)
SELECT name FROM t;          -- index（全扫 idx_name）
SELECT * FROM t ORDER BY id; -- index（按主键全扫）
```

### 4.10 ALL（全表扫描）

**最差**。生产慢 SQL 多半 type=ALL。要么没索引要么索引失效。

> **判断准则**：
> - 主键查询应是 const
> - JOIN 被驱动表应是 eq_ref / ref
> - 范围查询应是 range
> - **ALL 和 index 都是优化目标**

---

## 五、key 与 key_len

### 5.1 key

实际选用的索引名。NULL = 没走索引。

### 5.2 key_len 计算（高频考点）

key_len = **使用了索引的字节数**。判断组合索引是否完整命中。

| 列类型 | key_len 公式 |
| --- | --- |
| `INT NOT NULL` | 4 |
| `INT NULL` | 4 + 1（NULL 标志位） |
| `BIGINT NOT NULL` | 8 |
| `CHAR(N) NOT NULL` charset=utf8mb4 | N × 4 |
| `VARCHAR(N) NOT NULL` charset=utf8mb4 | N × 4 + 2（变长长度位） |
| `VARCHAR(N) NULL` | N × 4 + 2 + 1 |
| `DATE NOT NULL` | 3 |
| `DATETIME NOT NULL` | 5（5.6+） |

**例子**：

```sql
KEY idx_a_b_c (a INT NOT NULL, b VARCHAR(20) NOT NULL utf8mb4, c INT NULL)

WHERE a=1                       -- key_len=4         （只走 a）
WHERE a=1 AND b='x'             -- key_len=4+82=86   （走 a, b）
WHERE a=1 AND b='x' AND c=2     -- key_len=4+82+5=91 （全部走）
WHERE a=1 AND c=2               -- key_len=4         （c 不走，因为跳过 b）
```

> **用法**：组合索引可疑时 → 看 key_len → 比对预期 → 找断在哪一列。

### 5.3 ref

显示与 key 比较的什么：
- `const`：常量（`WHERE id=10`）
- 列名：JOIN 时另一表的列
- `func`：函数结果

---

## 六、rows 与 filtered

- **rows**：优化器估算要扫的行数（基于统计信息，不一定准）
- **filtered**：估计 WHERE 之后剩余百分比（0~100）

实际预计返回行数 = `rows × filtered / 100`。

> **rows 不准的根因**：统计信息陈旧。`ANALYZE TABLE t;` 可重新采样。

---

## 七、Extra：附加信息（必看）

### 7.1 好信号

| Extra | 含义 |
| --- | --- |
| `Using index` | 覆盖索引！叶子拿全数据，**不回表** |
| `Using index condition` | ICP 索引下推（5.6+），引擎层就过滤完 |
| `Using where` | Server 层用 WHERE 过滤；常和 Using index 共同出现 |

### 7.2 警告信号（要优化）

| Extra | 含义 | 怎么改 |
| --- | --- | --- |
| **`Using filesort`** | 内存或磁盘排序 | 建覆盖索引让 ORDER BY 走索引 |
| **`Using temporary`** | 创建临时表（GROUP BY、UNION 常见） | 建索引让 GROUP BY 走索引；或优化 SQL |
| `Using join buffer (Block Nested Loop)` | 被驱动表无索引，要全表扫然后内存比对 | 给 JOIN 列加索引 |

### 7.3 信息性

| Extra | 含义 |
| --- | --- |
| `Impossible WHERE` | 优化器算出 WHERE 永假（如 `WHERE 1=0`） |
| `Distinct` | 找到一个匹配后停止 |
| `Range checked for each record` | JOIN 时按行检查能否用索引——通常糟糕 |
| `Select tables optimized away` | 优化器不读表也能给结果（如 `MIN(id)` 走索引） |

---

## 八、典型案例分析

### 8.1 案例 1：表扫但应走索引

```sql
EXPLAIN SELECT * FROM user WHERE phone = 13800138000;
```

| type | key | rows | Extra |
| --- | --- | --- | --- |
| ALL | NULL | 1000000 | Using where |

→ 没走索引。  
**根因**：`phone` 是 VARCHAR，常量是数字 → 隐式转换。  
**修复**：`WHERE phone = '13800138000'`。

### 8.2 案例 2：组合索引断在中间

```sql
KEY idx_a_b_c (a, b, c)
EXPLAIN SELECT * FROM t WHERE a=1 AND c=3;
```

| key | key_len |
| --- | --- |
| idx_a_b_c | 4 |

→ 只走了 a，c 没走（因为跳过 b）。  
**修复**：调整索引顺序为 `(a, c, b)`，或补上 `b` 条件。

### 8.3 案例 3：filesort 排序

```sql
EXPLAIN SELECT * FROM order WHERE user_id=1 ORDER BY create_time DESC LIMIT 10;
```

| type | key | Extra |
| --- | --- | --- |
| ref | idx_user | Using filesort |

→ 走 user_id 索引找到行，然后内存排序。  
**修复**：建复合索引 `(user_id, create_time)`，让 ORDER BY 直接走索引：

```sql
ALTER TABLE order ADD KEY idx_user_time (user_id, create_time);
```

排完再看：

| type | key | Extra |
| --- | --- | --- |
| ref | idx_user_time | Using index condition |

→ 没有 filesort 了。

### 8.4 案例 4：JOIN 被驱动表无索引

```sql
EXPLAIN SELECT * FROM order o JOIN user u ON o.user_id = u.id;
```

| id | table | type | key | Extra |
| --- | --- | --- | --- | --- |
| 1 | o | ALL | NULL | |
| 1 | u | ref | PRIMARY | |

→ o 被全表扫。  
**根因**：可能 order 表的 user_id 没索引（没建 / 失效）。  
**修复**：给 user_id 加索引。

### 8.5 案例 5：深分页

```sql
EXPLAIN SELECT * FROM t ORDER BY id LIMIT 1000000, 10;
```

| type | rows |
| --- | --- |
| index | 1000010 |

→ 走主键扫了 100 万行。  
**修复**：延迟关联：

```sql
EXPLAIN SELECT t.* FROM t INNER JOIN (
  SELECT id FROM t ORDER BY id LIMIT 1000000, 10
) x USING (id);
```

内层 type=index、Extra=`Using index`（覆盖索引），外层 const，扫描行数大幅下降。

---

## 九、SHOW WARNINGS 看优化器改写

```sql
EXPLAIN SELECT * FROM t WHERE id IN (SELECT id FROM t2);
SHOW WARNINGS;
```

输出会显示**优化器改写后的 SQL**——能看到子查询变 SEMI JOIN、外连接消除等动作。理解优化器决策的好工具。

---

## 十、面试高频追问

### Q1：type 的层级你能说全吗？

`system > const > eq_ref > ref > range > index > ALL`，重点记关键档：const（主键/唯一等值）、eq_ref（join 走主键/唯一）、ref（普通索引等值）、range（范围）、index（全索引扫）、ALL（全表）。

### Q2：怎么判断索引是否完整命中组合索引？

看 **key_len**：根据组合索引每列字节数累加，对比 EXPLAIN 显示的值，差多少就知道断在哪。

### Q3：Extra 出现 Using filesort 怎么办？

ORDER BY 没走索引。建复合索引让排序列在 WHERE 列后面，且方向一致。

### Q4：Using temporary 是什么？怎么消除？

临时表，常见于 GROUP BY 和 UNION。让 GROUP BY 列走索引（保证有序），或换 UNION ALL（如不需要去重）。

### Q5：rows 不准怎么办？

`ANALYZE TABLE t;` 重新统计。线上长期不准多半统计采样太小，可调 `innodb_stats_persistent_sample_pages`。

### Q6：可不可以信 EXPLAIN 显示的 key？

绝大多数情况可以，但优化器**有时选错**——可以 FORCE INDEX 强制，或 ANALYZE TABLE 让统计准。

### Q7：const 和 eq_ref 区别？

const：单表查询主键/唯一索引等值（结果至多一行，优化器视为常量）。  
eq_ref：JOIN 时被驱动表的主键/唯一索引等值（每个驱动表的行最多匹配被驱动表一行）。

### Q8：EXPLAIN ANALYZE 和 EXPLAIN 区别？

EXPLAIN 仅给执行计划，不跑。EXPLAIN ANALYZE（8.0+）真实执行，给出每步的实际耗时和行数——更准但有副作用，生产慎用。

---

## 十一、答题模板（30 秒话术）

> EXPLAIN 是优化的第一工具，重点看四列：**type**（访问类型，最差是 ALL/index）、**key**（实际用的索引）、**key_len**（看组合索引断在哪）、**rows**（扫描行数）、**Extra**（关键警告）。
>
> 良好执行计划应是 const / eq_ref / ref / range；ALL 和 index 是优化目标。
>
> Extra 里 `Using filesort` 和 `Using temporary` 是性能杀手，前者用复合索引让排序走索引，后者优化 GROUP BY / UNION。出现 `Using index` 是覆盖索引（最佳）；`Using index condition` 是 ICP 下推（5.6+ 优化）。
>
> 当 EXPLAIN 显示走了索引但 rows 仍很大，说明索引区分度低或范围太大——重新评估索引设计。

---

## 十二、相关文档

- [索引](./索引.md) — 数据结构与设计原理
- [SQL 优化与慢查询](./sql优化.md) — 慢 SQL 分析全流程
- [MySQL 规范](./MySQL规范.md) — 索引命名与数量限制
