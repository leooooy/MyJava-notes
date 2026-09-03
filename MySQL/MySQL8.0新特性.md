# MySQL 8.0 新特性

> 8.0 是 MySQL 自 5.6 以来最大的一次升级——**核心引擎、SQL 能力、运维能力**都有跨越式改进。
>
> 面试问"用过 8.0 吗 / 8.0 哪些新特性吸引你"——能把窗口函数、CTE、原子 DDL、Hash Join、隐藏索引讲清，立刻显出资深。
>
> 本篇按"SQL 能力 → 索引能力 → 引擎与日志 → DBA 运维 → JSON" 五块组织。

---

## 一、SQL 能力跨越（最显著的提升）

### 1.1 窗口函数（Window Functions）

> **8.0 最大的 SQL 能力提升**。8.0 之前要用各种 `(SELECT ...)` 子查询绕，现在一行搞定。

**用途**：分组内排序、求 TopN、累计、环比同比、滑动窗口。

```sql
-- 每个用户的最近 3 笔订单（之前要 join 自己 + 子查询）
SELECT * FROM (
  SELECT 
    *,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY create_time DESC) AS rn
  FROM order
) t WHERE rn <= 3;
```

**核心函数**：

| 类别 | 函数 | 用途 |
| --- | --- | --- |
| 排名 | `ROW_NUMBER()` | 每行唯一序号（1,2,3,4...） |
|  | `RANK()` | 同值同排名，有跳号（1,2,2,4...） |
|  | `DENSE_RANK()` | 同值同排名，不跳号（1,2,2,3...） |
| 偏移 | `LAG(col, n)` | 前 n 行的值（同比环比常用） |
|  | `LEAD(col, n)` | 后 n 行的值 |
| 聚合 | `SUM() OVER (...)` | 累计求和（分组内运行总计） |
|  | `AVG() OVER (...)` | 移动平均 |
| 边界 | `FIRST_VALUE` / `LAST_VALUE` | 分组内首/末值 |
|  | `NTH_VALUE(col, n)` | 分组内第 n 个值 |
| 分桶 | `NTILE(n)` | 把分组内行分到 n 个桶（百分位常用） |

### 1.2 实战例子

#### 累计求和

```sql
SELECT 
  order_date,
  amount,
  SUM(amount) OVER (ORDER BY order_date) AS cumulative_sum
FROM daily_sales;
```

#### 同比环比

```sql
SELECT 
  month,
  sales,
  LAG(sales, 1) OVER (ORDER BY month) AS last_month,
  sales - LAG(sales, 1) OVER (ORDER BY month) AS mom_diff,
  LAG(sales, 12) OVER (ORDER BY month) AS last_year_same_month
FROM monthly_sales;
```

#### 滑动 7 日均值

```sql
SELECT 
  date,
  amount,
  AVG(amount) OVER (
    ORDER BY date 
    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
  ) AS moving_avg_7d
FROM daily_metrics;
```

### 1.3 CTE（Common Table Expression）

> **WITH 子句**——让复杂查询可读、支持递归。

#### 普通 CTE

```sql
-- 8.0 之前：多层嵌套子查询，难读
SELECT * FROM (
  SELECT user_id, COUNT(*) AS order_count FROM order GROUP BY user_id
) o WHERE order_count > 100;

-- 8.0 CTE：清晰
WITH user_orders AS (
  SELECT user_id, COUNT(*) AS order_count
  FROM order
  GROUP BY user_id
)
SELECT * FROM user_orders WHERE order_count > 100;
```

#### 递归 CTE（杀手锏）

**用途**：树形结构（部门、菜单、评论）的层级遍历。

```sql
-- 查 user_id=1 及其所有下级（递归）
WITH RECURSIVE subordinates AS (
  -- 锚点
  SELECT user_id, supervisor_id, name, 1 AS level
  FROM employee
  WHERE user_id = 1
  
  UNION ALL
  
  -- 递归
  SELECT e.user_id, e.supervisor_id, e.name, s.level + 1
  FROM employee e
  INNER JOIN subordinates s ON e.supervisor_id = s.user_id
)
SELECT * FROM subordinates;
```

8.0 之前要在应用代码里用递归调用——一次次查 DB，性能差。

---

## 二、索引能力升级

### 2.1 隐藏索引（Invisible Index）

> **测试"删了这个索引会怎样"**——先隐藏观察，确认无影响再真删。

```sql
-- 隐藏（优化器看不见，但还在维护）
ALTER TABLE t ALTER INDEX idx_xxx INVISIBLE;

-- 观察一周线上效果
-- 没问题再删
DROP INDEX idx_xxx ON t;

-- 出问题立刻恢复（无开销）
ALTER TABLE t ALTER INDEX idx_xxx VISIBLE;
```

> **互联网最大价值**：避免删了关键索引导致全站慢查询雪崩——隐藏可以"软删除"。

### 2.2 降序索引（Descending Index）

```sql
-- 8.0 之前：DESC 只是语法糖，索引仍是升序，ORDER BY a DESC 走索引但反向遍历
KEY idx_a (a)

-- 8.0：真正的降序索引
KEY idx_a (a DESC)

-- 混合方向（之前不支持，要 filesort）
KEY idx_ab (a ASC, b DESC)
```

**收益**：复杂排序场景（榜单同时按时间 ASC + 分数 DESC）能精确走索引，无 filesort。

### 2.3 函数索引（Functional Index）

> **5.7 及以前的痛点**：`WHERE YEAR(create_time) = 2024` 索引失效。8.0 终于解决。

```sql
-- 在表达式上建索引
ALTER TABLE t ADD INDEX idx_year ((YEAR(create_time)));

-- 这下走索引了
SELECT * FROM t WHERE YEAR(create_time) = 2024;
```

### 2.4 直方图（Histogram）

> 优化器代价估算更准——以前靠"列值范围 × 总行数"推估，现在能基于直方图算分布。

```sql
-- 8.0 创建直方图
ANALYZE TABLE t UPDATE HISTOGRAM ON age WITH 100 BUCKETS;
```

**典型场景**：年龄字段 90% 用户是 20~30 岁，10% 是 60+ 岁——直方图能让优化器知道范围内的真实分布，避免选错索引。

---

## 三、JOIN 能力跨越：Hash Join

### 3.1 之前的痛点

5.7 及以前，被驱动表 JOIN 列**没索引**时，走 **Block Nested-Loop Join (BNL)**——把驱动表行批量塞 join_buffer，再扫被驱动表全表逐个比对。**慢且没有进度可观测**。

### 3.2 8.0.18+ 的 Hash Join

```
1. 扫小表（驱动表），所有行的 JOIN 列建哈希表
2. 扫大表（被驱动表），每行 JOIN 列哈希查
3. 命中即输出
```

**收益**：BNL 是 O(M × N)，Hash Join 是 O(M + N)——大表 JOIN 性能数量级提升。

### 3.3 触发条件

- 等值 JOIN（`=`）
- 被驱动表 JOIN 列**没合适的索引**
- 8.0.18+ 自动用，无需手动开

```sql
EXPLAIN ANALYZE SELECT * FROM t1 JOIN t2 ON t1.k = t2.k;
-- Extra 看到 Hash Join 字样
```

> **业务影响**：之前因为没索引被迫上 BNL 的慢 JOIN，升级 8.0 后自动加速。

---

## 四、引擎与日志改进

### 4.1 数据字典转 InnoDB

5.7 及以前：表结构存 `.frm` 文件 + `mysql.*` 系统库（MyISAM）。

8.0：**全部转 InnoDB**——`.frm` 文件没了，元数据存在 InnoDB 表里。

**意义**：
- 元数据操作支持事务
- 跨引擎一致性保证
- DDL 能做到原子（见下一节）

### 4.2 原子 DDL（Atomic DDL）

> **5.7 及以前的痛点**：DDL 不是事务——`DROP TABLE t1, t2`，t1 删完崩了 → t2 还在。8.0 解决。

```sql
-- 8.0：要么全成功，要么全失败
DROP TABLE t1, t2, t3;
```

**实现**：DDL 现在通过 InnoDB undo / redo log 保证原子。

### 4.3 redo log 改无锁链表

8.0 重写了 redo log buffer 的并发控制——从全局 mutex 改成无锁链表。**多核场景下 redo 写入性能大幅提升**——是 8.0 比 5.7 性能提升的关键之一。

### 4.4 双写文件可以独立 + 多文件

```ini
innodb_doublewrite = ON
innodb_doublewrite_dir = /path/to/dwr_dir   # 8.0 独立目录
innodb_doublewrite_files = 2                # 多文件并行刷盘
```

8.0 之前 doublewrite 是单文件单点 → 高并发瓶颈；8.0 可以拆多文件并行。

---

## 五、运维能力提升

### 5.1 角色（ROLE）

> 终于像 Oracle 一样有"角色"概念了——不必给每个用户挨个授权。

```sql
-- 创建角色
CREATE ROLE 'app_read', 'app_write';
GRANT SELECT ON mydb.* TO 'app_read';
GRANT INSERT, UPDATE ON mydb.* TO 'app_write';

-- 给用户授角色
GRANT 'app_read', 'app_write' TO 'user1'@'%';

-- 用户使用前激活
SET DEFAULT ROLE ALL TO 'user1'@'%';
```

### 5.2 caching_sha2_password 默认

8.0 默认密码插件从 `mysql_native_password` 换成 `caching_sha2_password`——更安全。

> **生产坑**：很多老客户端不支持 caching_sha2，需要：
> ```sql
> ALTER USER 'user1'@'%' IDENTIFIED WITH mysql_native_password BY 'pwd';
> ```

### 5.3 SET PERSIST：动态配置持久化

```sql
-- 5.7：SET GLOBAL 重启失效，必须手动改 my.cnf
SET GLOBAL max_connections = 1000;

-- 8.0：SET PERSIST 持久化
SET PERSIST max_connections = 1000;
```

存在 `data_dir/mysqld-auto.cnf`——重启后仍生效。

### 5.4 跳过查询缓存（Query Cache 已删）

8.0 直接**删除 Query Cache** 模块——OLTP 写多场景下命中率 <1%，维护成本远大于收益。

> 缓存能力交给应用层用 Redis 做。

### 5.5 EXPLAIN ANALYZE

```sql
-- 8.0.18+：真正执行 + 实际耗时（注意：会真跑 SQL）
EXPLAIN ANALYZE SELECT * FROM t WHERE id = 1;
```

输出每步实际行数和耗时——比单纯的估算更准。

### 5.6 资源组（Resource Groups）

```sql
CREATE RESOURCE GROUP report_group
  TYPE = USER VCPU = 0-3 THREAD_PRIORITY = 19;

-- 把"报表线程"绑到低优先级 CPU 组
SET RESOURCE GROUP report_group FOR <thread_id>;
```

**用途**：让 OLAP 类慢查询占用低优先级 CPU，不影响 OLTP。

---

## 六、JSON 增强（5.7 引入，8.0 大量优化）

### 6.1 JSON 类型基础

```sql
CREATE TABLE config (
  id INT PRIMARY KEY,
  data JSON
);

INSERT INTO config VALUES 
  (1, '{"name": "张三", "age": 25, "tags": ["vip", "active"]}');
```

### 6.2 JSON 操作（5.7+）

```sql
-- 取字段
SELECT data->'$.name' FROM config;
SELECT data->>'$.name' FROM config;     -- ->> 自动去引号

-- 修改
UPDATE config SET data = JSON_SET(data, '$.age', 30) WHERE id = 1;

-- 函数
JSON_EXTRACT, JSON_SET, JSON_INSERT, JSON_REPLACE, JSON_REMOVE, JSON_ARRAY_APPEND
```

### 6.3 JSON 索引（重点）

#### 函数索引（8.0+）

```sql
-- 在 JSON 字段上建索引（通过函数索引）
ALTER TABLE config ADD INDEX idx_name ((CAST(data->>'$.name' AS CHAR(50))));

-- 这下走索引
SELECT * FROM config WHERE data->>'$.name' = '张三';
```

#### Multi-Valued Index（8.0.17+）

```sql
-- 在 JSON 数组字段建索引
ALTER TABLE config ADD INDEX idx_tags ((CAST(data->'$.tags' AS CHAR(20) ARRAY)));

-- 走索引
SELECT * FROM config WHERE 'vip' MEMBER OF (data->'$.tags');
```

### 6.4 JSON 用法准则

| ✅ 适合 | ❌ 不适合 |
| --- | --- |
| 灵活配置（不定字段） | 稳定字段（应该列存） |
| 嵌套结构（多层 nesting） | 平铺结构 |
| 不索引或低频查询 | 高频 WHERE / JOIN 字段 |
| 写多读少 | 改部分字段需读写整 JSON |

> **互联网典型用法**：用户配置 / 商品扩展属性 / 第三方回调原始数据存档。**核心查询字段绝不存 JSON**。

---

## 七、其它值得一提的特性

### 7.1 SKIP LOCKED / NOWAIT

```sql
-- 之前：抢锁要等锁等待超时
SELECT * FROM order WHERE status=0 LIMIT 10 FOR UPDATE;

-- 8.0：抢不到立刻跳过
SELECT * FROM order WHERE status=0 LIMIT 10 FOR UPDATE SKIP LOCKED;

-- 抢不到立刻报错（不等）
SELECT * FROM order WHERE id=1 FOR UPDATE NOWAIT;
```

**用途**：消息队列消费者并行抢任务（每个消费者拿不同的 10 行）、超卖防御。

### 7.2 Common Table Expression for INSERT/UPDATE/DELETE

```sql
WITH old_orders AS (
  SELECT id FROM order WHERE create_time < '2023-01-01'
)
DELETE FROM order WHERE id IN (SELECT id FROM old_orders);
```

### 7.3 Lateral Derived Tables

```sql
SELECT t1.id, t2.recent_orders
FROM customer t1,
LATERAL (
  SELECT GROUP_CONCAT(order_id) AS recent_orders
  FROM order
  WHERE user_id = t1.id
  ORDER BY create_time DESC
  LIMIT 5
) t2;
```

### 7.4 GROUP BY 行为变更

5.7 及以前 `GROUP BY` 自动**隐式排序**——无意义的开销。

8.0：`GROUP BY` **不再隐式排序**，要排序自己写 `ORDER BY`。

> **生产坑**：升级 8.0 后某些查询输出顺序变了——业务依赖隐式排序的代码要改。

---

## 八、版本演进对比速查

| 特性 | 5.7 | 8.0 |
| --- | --- | --- |
| 默认引擎 | InnoDB | InnoDB |
| 数据字典 | .frm 文件 + MyISAM 系统库 | **InnoDB 表** |
| 原子 DDL | ❌ | ✅ |
| 窗口函数 | ❌ | ✅ |
| CTE / 递归 CTE | ❌ | ✅ |
| 隐藏索引 | ❌ | ✅ |
| 降序索引 | ❌（DESC 仅语法糖） | ✅ 真降序 |
| 函数索引 | ❌ | ✅ |
| 直方图 | ❌ | ✅ |
| Hash Join | ❌（只有 BNL） | ✅（8.0.18+） |
| Multi-Valued JSON Index | ❌ | ✅（8.0.17+） |
| ROLE 角色 | ❌ | ✅ |
| SET PERSIST | ❌ | ✅ |
| Query Cache | ✅（默认关） | ❌（已删） |
| caching_sha2 默认密码 | ❌ | ✅ |
| SKIP LOCKED / NOWAIT | ❌ | ✅ |
| 资源组 | ❌ | ✅ |
| JSON 函数 | ✅ 基础 | ✅ 大量增强 |

---

## 九、升级 8.0 注意事项

### 9.1 不兼容点

1. **保留字**：`RANK`、`SYSTEM`、`GROUPS` 等成保留字，作为列名要加反引号
2. **认证插件**：caching_sha2_password 默认，老客户端可能连不上
3. **GROUP BY 不再隐式排序**：依赖输出顺序的业务要改
4. **utf8 → utf8mb4**：默认字符集变了，新建表用 utf8mb4
5. **原子 DDL**：DROP TABLE 中途崩溃行为不同
6. **MyISAM 系统库**：升级期间需特殊处理

### 9.2 升级路径

```
5.7 → 8.0：必须 in-place 升级，不能跳过 5.7
5.6 → 8.0：必须先 5.6 → 5.7 → 8.0
```

### 9.3 升级前检查

```bash
mysqlcheck --check-upgrade --all-databases
mysql_upgrade --user=root --password   # 8.0 之后已废弃但 5.7 → 8.0 仍需
```

---

## 十、生产踩坑

### 10.1 升级后老应用连不上

老 JDBC 驱动不支持 caching_sha2_password。

**修复**：升级驱动（mysql-connector-java 8.0+）；或临时改回老插件：
```sql
ALTER USER 'app'@'%' IDENTIFIED WITH mysql_native_password BY 'pwd';
```

### 10.2 GROUP BY 输出顺序变了

5.7 业务习惯不写 ORDER BY 也"碰巧"有序。8.0 升级后乱序，业务断言失败。

**修复**：所有依赖输出顺序的 SQL **显式 ORDER BY**——本来就该这样。

### 10.3 窗口函数滥用拖垮 OLTP

```sql
-- 大表加复杂窗口函数 → 内存爆 / 慢查询
SELECT *, ROW_NUMBER() OVER (ORDER BY create_time DESC) FROM huge_table;
```

**正解**：窗口函数适合 OLAP / 报表场景，OLTP 高并发列表别用。

### 10.4 函数索引滥用

```sql
-- 看似聪明
ALTER TABLE t ADD INDEX idx_name_lower ((LOWER(name)));

-- 但 INSERT/UPDATE 每次都算 LOWER → 写性能下降
```

**正解**：能改 SQL 避免函数就别建函数索引。

### 10.5 隐藏索引"忘记删"

把索引隐藏一个月观察，确认无影响后忘了删——索引仍在维护，浪费空间和写性能。

**修复**：定期 review `INFORMATION_SCHEMA.STATISTICS` 中的隐藏索引。

---

## 十一、面试高频追问

### Q1：MySQL 8.0 哪些新特性最吸引你？

按重要性：原子 DDL、窗口函数、CTE（含递归）、隐藏索引、函数索引、Hash Join、ROLE 角色、SET PERSIST。

### Q2：窗口函数和 GROUP BY 区别？

GROUP BY 折叠行（聚合后只剩一行），窗口函数**保留每行**并附加聚合/排名结果。`PARTITION BY` 是窗口函数的"分组"，但不折叠行。

### Q3：递归 CTE 应用场景？

树形结构遍历（部门、菜单、评论树）、图遍历（社交关系网）、序列生成。8.0 之前要在应用代码递归调用，现在数据库一次完成。

### Q4：隐藏索引怎么用？

`ALTER TABLE t ALTER INDEX idx INVISIBLE`——优化器看不见但仍维护。验证"删了这个索引会怎样"的安全方式。出问题秒恢复 VISIBLE。

### Q5：8.0 为什么删 Query Cache？

OLTP 写多场景命中率 <1%——写一次让所有相关 SQL 缓存失效，维护成本远大于收益。8.0 直接删，缓存交给 Redis。

### Q6：8.0 的 Hash Join 解决什么问题？

之前被驱动表无索引时只能 BNL（O(M×N)）。8.0 支持 Hash Join（O(M+N)），大表 JOIN 不再灾难。

### Q7：原子 DDL 是什么？

DDL 操作要么全成功要么全失败——`DROP TABLE t1, t2` 中途崩溃不会"t1 删了 t2 还在"。靠 InnoDB undo/redo + 数据字典转 InnoDB 实现。

### Q8：8.0 升级要注意什么？

- caching_sha2_password 默认（老驱动连不上）
- GROUP BY 不再隐式排序
- 保留字增加（RANK 等）
- 必须 5.7 → 8.0，不能从 5.6 直跳
- utf8mb4 默认（5.7 默认是 utf8）

### Q9：JSON 字段怎么建索引？

8.0 用**函数索引**：`ALTER TABLE t ADD INDEX ((CAST(data->>'$.name' AS CHAR(50))))`；JSON 数组用 **Multi-Valued Index**：`ALTER TABLE t ADD INDEX ((CAST(data->'$.tags' AS CHAR(20) ARRAY)))`。

### Q10：SKIP LOCKED 用在哪？

并行任务消费——多个消费者抢任务，`FOR UPDATE SKIP LOCKED` 让每个消费者跳过被锁的行，拿到不同任务，无锁等待。秒杀 / 消息队列场景实用。

---

## 十二、答题模板（60 秒话术）

> MySQL 8.0 是自 5.6 以来最大升级，分**SQL / 索引 / 引擎 / 运维 / JSON** 五大块。
>
> **SQL 能力**最显著——**窗口函数**（ROW_NUMBER / RANK / LAG / LEAD / SUM OVER 等）和 **CTE**（含递归）让"分组内 TopN""树形遍历""同比环比"从绕子查询变一行 SQL；新增 **SKIP LOCKED / NOWAIT** 解决并行抢任务的锁竞争。
>
> **索引能力**：**隐藏索引**让"删索引"先软删观察、**降序索引**真支持 a ASC b DESC 混排、**函数索引**解决 `YEAR(t)=2024` 类失效、**直方图**让优化器代价估算更准。
>
> **JOIN**：8.0.18+ 引入 **Hash Join** 替代 BNL，大表 JOIN 性能数量级提升。
>
> **引擎**：**数据字典转 InnoDB**（.frm 没了），支持 **原子 DDL**；redo log 重写为无锁链表，多核场景写入提升大；Double Write 支持多文件并行。
>
> **运维**：终于有了 **ROLE 角色**、**SET PERSIST 持久化配置**、**EXPLAIN ANALYZE** 真实执行；**删除 Query Cache**（缓存交给 Redis）；**资源组**让 OLAP 慢查询不影响 OLTP。
>
> **JSON** 大量增强，含 **Multi-Valued Index**（数组字段建索引），但**核心字段仍应列存**。
>
> 升级注意：caching_sha2 默认密码插件、GROUP BY 不再隐式排序、保留字增加、必须 5.7→8.0 不能跳。

---

## 十三、相关文档

- [架构总览 - 版本演进](./架构总览.md#五版本演进速记) — 各版本时间线
- [索引](./索引.md) — 隐藏索引 / 函数索引基础
- [SQL 优化与慢查询](./sql优化.md) — Hash Join 在 JOIN 优化里
- [explain](./explain.md) — EXPLAIN ANALYZE
- [MySQL 规范](./MySQL规范.md) — 升级注意事项
