# SQL 优化与慢查询分析

> 慢 SQL 是生产事故的头号源头。面试不仅要讲"怎么写好的 SQL"，更要讲"线上慢 SQL 怎么发现、定位、优化"——能讲清这条链路就是合格的高级工程师。
>
> 本篇按"发现 → 定位 → 优化 → 防范"组织：① 慢日志怎么开 + 怎么读 → ② EXPLAIN 看出问题 → ③ 9 类常见优化手法（含分页、JOIN、count、IN/EXISTS）→ ④ 服务器层调优 → ⑤ 持续治理。

---

## 一、慢 SQL 的发现

### 1.1 开慢查询日志

```ini
# my.cnf
slow_query_log              = ON
slow_query_log_file         = /var/log/mysql/slow.log
long_query_time             = 0.5         # 阈值，秒，0.5 = 500ms
log_queries_not_using_indexes = ON         # 没走索引的也记
log_slow_admin_statements   = ON           # ALTER 等也记
log_throttle_queries_not_using_indexes = 60  # 限流防日志爆
```

> **生产建议阈值 500ms**，互联网业务接口预算通常 100ms 内完成 SQL。1s 太松，会漏掉很多问题。

### 1.2 慢日志字段

```
# Time: 2024-04-15T10:30:00
# User@Host: app[app] @ [10.0.0.1]
# Query_time: 2.345  Lock_time: 0.001  Rows_sent: 1  Rows_examined: 5000000
SET timestamp=1713170000;
SELECT * FROM order WHERE user_id = 12345;
```

| 字段 | 关注点 |
| --- | --- |
| Query_time | 总耗时 |
| Lock_time | 锁等待时间——大说明锁竞争 |
| Rows_sent | 实际返回行数 |
| Rows_examined | **扫描行数**——和 sent 差距大说明索引不优 |

### 1.3 慢日志聚合（pt-query-digest）

直接看 slow.log 太散，用 Percona Toolkit：

```bash
pt-query-digest /var/log/mysql/slow.log > slow-report.txt
```

输出按"总耗时排序"列出 TOP SQL，给出执行次数、平均时间、扫描行数等。**生产唯一推荐工具**。

### 1.4 在线观察

```sql
-- 当前正在跑的 SQL
SHOW PROCESSLIST;
-- 或更详细
SELECT * FROM information_schema.processlist WHERE COMMAND != 'Sleep';

-- 看慢 SQL 累计统计（5.6+ performance_schema）
SELECT digest_text, count_star, avg_timer_wait/1e9 AS avg_ms
FROM performance_schema.events_statements_summary_by_digest
ORDER BY avg_timer_wait DESC LIMIT 10;
```

---

## 二、定位：EXPLAIN 找瓶颈

详见 [EXPLAIN 详解](./explain.md)。重点看：

| 列 | 警戒值 |
| --- | --- |
| type | ALL / index → 危险 |
| key | NULL → 没走索引 |
| rows | 远大于实际返回行数 → 索引不优 |
| Extra | Using filesort / Using temporary → 排序/临时表 |

```sql
EXPLAIN SELECT ...;
EXPLAIN ANALYZE SELECT ...;   -- 8.0+，真正执行 + 实际耗时
SHOW WARNINGS;                 -- 看优化器改写
```

---

## 三、9 类常见优化手法

### 3.1 索引优化

#### 3.1.1 建好索引

参考 [索引设计原则](./索引.md#六索引设计原则)：
- WHERE / JOIN / ORDER BY / GROUP BY 列加索引
- 组合索引：等值放前、范围放后
- 区分度高的列放前
- 单表 ≤5 个索引

#### 3.1.2 覆盖索引

```sql
-- 改前：SELECT * 必回表
SELECT * FROM t WHERE name='张三';

-- 改后：仅查需要的列，让索引覆盖
SELECT id, name FROM t WHERE name='张三';
-- KEY idx_name(name) 包含 id（主键）→ 不回表
```

#### 3.1.3 避免索引失效

参考 [索引失效全场景](./索引.md#五索引失效全场景)：
- 函数 / 表达式：`YEAR(t)=2024` → 改 `t BETWEEN '2024-01-01' AND '2024-12-31'`
- 隐式转换：`phone=13800138000` → 改 `phone='13800138000'`
- 左模糊：`LIKE '%xx'` → 改全文索引或 ES
- 跳过最左前缀
- 范围列后续列断索引

### 3.2 LIMIT 深分页

```sql
-- 慢：要扫前 100 万行才取 10 行
SELECT * FROM t ORDER BY id LIMIT 1000000, 10;
```

#### 方案 A：游标主键（推荐）

适用于"上一页 → 下一页"翻页场景：

```sql
-- 第一页
SELECT * FROM t ORDER BY id LIMIT 10;

-- 后续页：传 last_id
SELECT * FROM t WHERE id > 1000000 ORDER BY id LIMIT 10;
```

→ 只扫 10 行。

#### 方案 B：延迟关联

适用于"任意页跳转"：

```sql
SELECT t.* FROM t INNER JOIN (
  SELECT id FROM t ORDER BY id LIMIT 1000000, 10
) x USING (id);
```

→ 内层走主键索引（覆盖索引）扫 100 万 id（快），外层只回表 10 行。

#### 方案 C：BETWEEN

```sql
SELECT * FROM t WHERE id BETWEEN 1000000 AND 1000009;
```

要求主键连续——很多业务不满足。

### 3.3 ORDER BY 优化

#### 3.3.1 让排序走索引

```sql
-- 慢：filesort
KEY idx_user (user_id)
SELECT * FROM order WHERE user_id=1 ORDER BY create_time DESC LIMIT 10;

-- 改：复合索引覆盖排序列
ALTER TABLE order ADD KEY idx_user_time (user_id, create_time);
```

#### 3.3.2 LIMIT 1 早停

```sql
-- 业务上明确只要一条
SELECT * FROM t WHERE name='张三' LIMIT 1;
```

让优化器找到第一条立即停止扫描。

### 3.4 JOIN 优化

#### 3.4.1 小表驱动大表

```sql
-- A 小，B 大
SELECT * FROM A LEFT JOIN B ON A.id = B.a_id;
-- 优化器自动选 A 为驱动表（小表），扫 |A| 次 B
```

5.6+ 优化器会自动调整 JOIN 顺序，但**JOIN 列一定要有索引**。

#### 3.4.2 JOIN 类型

| 算法 | 触发条件 | 性能 |
| --- | --- | --- |
| Index Nested-Loop Join | 被驱动表 JOIN 列**有索引** | 好 |
| Block Nested-Loop Join (BNL) | 被驱动表 JOIN 列**没索引** | 差，全表扫 |
| Hash Join（8.0+） | 被驱动表无索引 | BNL 的替代，快很多 |

EXPLAIN Extra 看到 `Using join buffer (Block Nested Loop)` → 必须给被驱动表 JOIN 列加索引，或升级 8.0 用 Hash Join。

#### 3.4.3 JOIN 不超过 3 张表

互联网规范。多表 JOIN：
- 难调优（多表笛卡尔积爆炸）
- 改业务模型（冗余字段、宽表）
- 复杂场景上 OLAP（ClickHouse / Doris）

### 3.5 count 优化

| 写法 | InnoDB 性能 | 说明 |
| --- | --- | --- |
| `count(*)` | **最快** | 优化器选最小辅助索引扫 |
| `count(1)` | 同 count(*) | 完全等价 |
| `count(主键)` | 慢一点 | 扫聚簇索引，叶子是整行 |
| `count(字段)` | 慢 + 不算 NULL | 扫该字段的索引 |

**结论**：永远用 `count(*)`。

> **大表 count(*) 还是慢怎么办？**
> - 维护一个计数器（INCR / DECR 在写入时）
> - 用近似值（show table status, rows 字段，可能不准）
> - 引入实时数仓

### 3.6 IN / EXISTS / NOT IN / NOT EXISTS

| 写法 | 行为 |
| --- | --- |
| `t1 WHERE id IN (SELECT id FROM t2)` | 5.6+ 自动优化为 SEMI JOIN，差不多 |
| `t1 WHERE EXISTS (SELECT 1 FROM t2 WHERE t2.id=t1.id)` | 老优化器更稳定 |
| `t1 WHERE id NOT IN (SELECT id FROM t2 WHERE id IS NOT NULL)` | NOT IN 遇 NULL 全失败，必须显式排除 |
| `t1 WHERE NOT EXISTS (SELECT 1 FROM t2 WHERE t2.id=t1.id)` | **推荐** |

> 反向查询 `NOT IN`、`!=`、`<>` 通常索引失效——能改 `NOT EXISTS` 就改。

### 3.7 子查询

```sql
-- 慢：可能产生临时表
SELECT * FROM t WHERE id IN (SELECT max(id) FROM t GROUP BY name);

-- 改：JOIN
SELECT t.* FROM t INNER JOIN (
  SELECT max(id) AS id FROM t GROUP BY name
) x USING (id);
```

5.6+ 优化器对子查询有优化，但写成 JOIN 仍更稳。

### 3.8 UNION

```sql
SELECT a FROM t WHERE c=1
UNION
SELECT a FROM t WHERE c=2;
```

`UNION` 默认去重 → 用临时表 → 慢。如不需去重用 `UNION ALL`。

### 3.9 批量插入

```sql
-- 慢：N 次往返
INSERT INTO t (...) VALUES (1);
INSERT INTO t (...) VALUES (2);
...

-- 快：一次往返
INSERT INTO t (...) VALUES (1), (2), (3), ...;
```

JDBC 批量：

```java
ps.addBatch(); ps.executeBatch();
// JDBC URL 必须加 rewriteBatchedStatements=true 才生效
```

不加的话 PreparedStatement.executeBatch 实际还是一条条执行——这是 Java 圈最常见的"批量插入很慢"原因。

---

## 四、数据类型与建表优化

### 4.1 选最小够用的类型

| 类型 | 占用 | 适用 |
| --- | --- | --- |
| TINYINT / SMALLINT / INT / BIGINT | 1/2/4/8 | 整数尽量选最小够用的 |
| CHAR(N) | 固定 N×4（utf8mb4） | 长度固定（手机号、身份证） |
| VARCHAR(N) | 实际长度 + 1/2 字节长度位 | 变长 |
| DATE / DATETIME / TIMESTAMP | 3 / 5 / 4 | TIMESTAMP 范围到 2038（**禁用**） |

> 互联网规范：用 BIGINT UNSIGNED 主键、VARCHAR、DATETIME；禁用 TEXT/BLOB（拆独立表），禁用 ENUM（改 TINYINT + 字典表）。

### 4.2 NOT NULL DEFAULT

字段全部 NOT NULL + 设默认值：
- NULL 让索引、统计、比较都更复杂
- NULL 占额外的 bitmap 位
- 业务上 0 / 空字符串 vs NULL 含义模糊

### 4.3 反范式

**范式**：减少冗余，但带来 JOIN 开销。  
**反范式**：冗余字段，避免 JOIN。

互联网通常**适度反范式**——比如订单表冗余 user_name、product_name，避免每次 JOIN user / product。代价：用户改名要更新多张表（用 binlog/Canal 异步同步即可）。

---

## 五、服务器层调优

### 5.1 参数

```ini
# Buffer Pool（最重要）
innodb_buffer_pool_size       = 物理内存 × 0.5~0.75
innodb_buffer_pool_instances  = 8

# redo log（避免 checkpoint 频繁触发）
innodb_log_file_size          = 1G ~ 4G
innodb_log_buffer_size        = 16M

# IO
innodb_io_capacity            = 2000   # SSD 调高
innodb_io_capacity_max        = 4000
innodb_flush_neighbors        = 0      # SSD 关

# 临时表
tmp_table_size                = 64M
max_heap_table_size           = 64M

# 排序缓冲
sort_buffer_size              = 2M     # 太大反而吃内存
join_buffer_size              = 2M

# 并发
max_connections               = 1000
innodb_thread_concurrency     = 0      # 不限制
```

### 5.2 监控指标

| 指标 | SQL | 健康值 |
| --- | --- | --- |
| Buffer Pool 命中率 | `1 - Innodb_buffer_pool_reads / Innodb_buffer_pool_read_requests` | >99% |
| 慢 SQL 数 | `SHOW STATUS LIKE 'Slow_queries'` | 不应快速增长 |
| 临时表数 | `Created_tmp_disk_tables` 增长 | 慢说明经常落盘临时表 |
| 锁等待 | `Innodb_row_lock_waits` | 不应大量增长 |

---

## 六、SQL 优化通用流程

```
1. 慢日志 / pt-query-digest 找 TOP SQL
                ↓
2. EXPLAIN 看执行计划
   ├─ type=ALL → 加 / 改索引
   ├─ Using filesort → 索引覆盖排序
   ├─ Using temporary → 优化 GROUP BY / UNION
   └─ rows 巨大 → 检查索引区分度
                ↓
3. 改 SQL 或加索引（覆盖索引、最左前缀）
                ↓
4. 复测：观察 Query_time 和 Rows_examined
                ↓
5. 灰度上线 + 监控
```

---

## 七、生产踩坑

### 7.1 改了索引反而更慢

新加 idx_a 后某 SQL 走了它，但实际不优——优化器估代价偏差。

**修复**：
- `ANALYZE TABLE` 让统计信息更新
- `FORCE INDEX` 强制走对的索引
- 删冗余索引（让优化器选择空间小一点）

### 7.2 索引太多 INSERT 慢

订单表加 12 个索引 → INSERT 50ms 涨 500ms。

**修复**：合并冗余索引，单表保持 ≤5。

### 7.3 大事务 + 锁等待

UPDATE 涉及百万行 → 锁持有时间长 → 阻塞业务。

**修复**：拆 BATCH，每次 5000 行。

### 7.4 SELECT * 拖慢全网

应用 `SELECT *` 拉 100 列、几十 KB 一行 → 网络带宽打满。

**修复**：所有 SELECT 显式列名，CodeReview 拦截 `SELECT *`。

### 7.5 Java 批量 INSERT 没走批量

JDBC URL 没加 `rewriteBatchedStatements=true` → batch 实际是逐条 → 100 条 INSERT 跑 5 秒。

**修复**：加参数，验证 binlog 中是否合并成多行 INSERT。

---

## 八、面试高频追问

### Q1：怎么发现慢 SQL？

慢查询日志（`long_query_time=0.5`）+ `pt-query-digest` 聚合分析；线上配合 `performance_schema.events_statements_summary_by_digest`。

### Q2：EXPLAIN 看什么？

- type：const/ref/range 是好，ALL/index 要优化
- key：是否走索引
- key_len：组合索引完整度
- rows：扫描行数 vs 实际返回行数差距大说明索引不优
- Extra：filesort / temporary 是警告

### Q3：深分页怎么优化？

游标主键（推荐，业务支持）或延迟关联（任意跳页）。LIMIT M, N 的 M 太大本质就是无谓扫描。

### Q4：JOIN 怎么优化？

被驱动表 JOIN 列必须有索引（避免 BNL）；小表驱动大表；JOIN ≤3 张；8.0+ 享受 Hash Join。

### Q5：count(*) 慢吗？怎么优化？

InnoDB 必须扫表（没维护行数）。优化：
- 用 count(*) 而不是 count(主键)（优化器选最小辅助索引）
- 业务侧维护计数器
- 大表用近似值或实时数仓

### Q6：什么是覆盖索引？

SELECT 字段全在索引里，叶子直接拿全数据，不回表。EXPLAIN 看 `Using index`。

### Q7：什么时候索引会失效？

函数、隐式转换、左模糊、跳过最左前缀、范围列后续列、OR 一边无索引、优化器估代价不划算。

### Q8：慢 SQL 优化的步骤？

慢日志找 → EXPLAIN 定位 → 加索引/改 SQL → 复测 → 监控。

### Q9：为什么 Java 批量插入很慢？

JDBC URL 没加 `rewriteBatchedStatements=true`，PreparedStatement.executeBatch 实际逐条执行。加了后才合并成 multi-value insert。

### Q10：sort_buffer_size 越大越好吗？

不是。sort_buffer 是**每连接独占**——大并发下 1000 连接 × 8MB = 8GB 凭空消耗。设 2~4MB 即可，超大排序自然走磁盘临时文件。

---

## 九、答题模板（60 秒话术）

> 慢 SQL 治理是个**链路**：
>
> ① **发现**：开慢查询日志（阈值 500ms），用 pt-query-digest 聚合，按总耗时排序找 TOP SQL。
>
> ② **定位**：EXPLAIN 看 type / key / rows / Extra，type=ALL 或 Extra 出现 filesort / temporary 是警告。
>
> ③ **优化**：常见手法——
> - 索引：覆盖索引避免回表、最左前缀、避免失效（隐式转换/函数/左模糊）
> - 分页：游标主键或延迟关联，禁 `LIMIT 1000000, 10`
> - JOIN：被驱动表 JOIN 列必加索引，小表驱动大表，超过 3 张 JOIN 重新建模
> - count：永远 `count(*)`
> - 反向查询：`NOT EXISTS` 替 `NOT IN`
> - 批量插入：JDBC 加 `rewriteBatchedStatements=true`
>
> ④ **服务器层**：Buffer Pool 50%~75%、redo 1G+、SSD 关 flush_neighbors。
>
> ⑤ **持续治理**：CodeReview 拦截 `SELECT *`、定期跑 pt-query-digest、监控 Buffer Pool 命中率和锁等待。

---

## 十、相关文档

- [explain](./explain.md) — 执行计划详解
- [索引](./索引.md) — 索引设计与失效
- [InnoDB 存储引擎](./InnDB.md) — 服务器调优参数
- [MySQL 规范](./MySQL规范.md) — 建表 / SQL 规范
- [死锁分析](./死锁分析.md) — 锁等待与死锁
