# MySQL 开发规范

> 互联网业务数据库的"军规"——基于阿里巴巴 / 腾讯等大厂规范整理。
>
> 这些规范不是教条，每条背后都有真实的事故。被面试问"你们公司 MySQL 规范有哪些"——不仅要列出规则，还要讲**为什么这条规则是这样的**。

---

## 一、基础规范

### 1.1 必须使用 InnoDB

> **理由**：事务、行锁、崩溃恢复、MVCC——OLTP 必备。MyISAM 已被淘汰，8.0 系统库自身全转 InnoDB。

### 1.2 必须使用 utf8mb4 字符集

> **理由**：
> - utf8（MySQL 早期实现）只支持 3 字节，不支持 emoji 和部分汉字
> - utf8mb4 真正的 UTF-8（4 字节），兼容所有 Unicode
>
> 老库 utf8 的代价：用户昵称带 emoji 入库报错 "Incorrect string value"——**真实事故**。

### 1.3 表与字段必须加中文注释

> **理由**：3 年后没人记得 `c_status` 是什么意思。

```sql
CREATE TABLE order (
  id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
  c_status  TINYINT UNSIGNED NOT NULL DEFAULT 0     COMMENT '订单状态：0待付款 1已付款 2已发货 3已签收 9已取消',
  ...
  PRIMARY KEY (id)
) COMMENT='订单主表';
```

### 1.4 开发 / 测试 / 生产环境必须隔离

> **理由**：开发误连生产 → 删库跑路。配置中心 + 网络 ACL 双重防护。

### 1.5 禁止存储文件 / 图片

> **理由**：
> - 数据库不擅长大对象存取（性能差）
> - 备份变慢、binlog 巨大、主从延迟
> - 存 OSS / S3 + 数据库存 URL 才对

### 1.6 禁止使用存储过程、视图、触发器、Event

> **理由**：
> - 调试困难（IDE 支持差）
> - 业务逻辑藏在数据库 → 应用层不易感知
> - 迁移、扩缩容麻烦
> - 性能问题难以观测

> **应用层能干的事，绝不放到数据库层**——这是互联网核心理念。

---

## 二、命名规范

### 2.1 库 / 表 / 字段

- **小写 + 下划线**：`user_info`，不要 `UserInfo` / `userInfo`（操作系统大小写敏感性差异）
- **见名知义**：`t_user` 不如 `user`；`tbl_order_xxx` 太冗余，省掉前缀
- **不超过 32 字符**：长名字让 SQL 难读
- **避免 SQL 关键字**：不要用 `order`、`user`、`group` 当表名（要加反引号才能用，麻烦）

### 2.2 索引

| 类型 | 命名 | 例 |
| --- | --- | --- |
| 主键 | 不命名（默认 PRIMARY） | — |
| 唯一索引 | `uk_<字段>` 或 `uniq_<字段>` | `uk_email` |
| 普通索引 | `idx_<字段>` 或 `idx_<字段1>_<字段2>` | `idx_user_id`、`idx_user_status` |
| 外键 | `fk_<表>_<字段>` | 但**禁用外键**，无需考虑 |

```sql
KEY uk_email (email),
KEY idx_user_status_time (user_id, status, create_time)
```

### 2.3 字段命名

| 类别 | 命名 | 例 |
| --- | --- | --- |
| 主键 | `id` | id BIGINT UNSIGNED |
| 时间字段 | `create_time, update_time` | DATETIME |
| 状态 | `status` | TINYINT |
| 删除标记 | `is_deleted` | TINYINT，0/1 |
| 关联 ID | `<表名>_id` | `user_id`, `order_id` |
| 数量 | `xxx_count, xxx_num` | INT UNSIGNED |
| 金额 | `xxx_amount` | DECIMAL |

---

## 三、表设计规范

### 3.1 必须有主键，推荐 BIGINT UNSIGNED 自增

```sql
id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY
```

> **理由**：
> - **自增**：顺序写入 → B+Tree 末尾追加 → 不触发页分裂；UUID 主键随机插入会页分裂频发
> - **BIGINT**：INT 上限 21 亿，互联网业务很容易撞墙
> - **UNSIGNED**：业务上 ID 不会负，多一倍范围
> - **必须有主键**：无主键的表在 ROW binlog 模式下，主从同步会全表扫，**主从延迟灾难**

### 3.2 禁止使用外键

> **理由**：
> - 外键检查在写入路径上 → 性能下降
> - 外键级联可能死锁
> - 分库分表后无法跨库维护
> - 业务一致性应由应用代码保证

### 3.3 单表大小控制

| 数据规模 | 建议 |
| --- | --- |
| <500 万行 / 单表 <10 GB | 单表 |
| 500 万 ~ 5000 万 | 考虑垂直拆分（冷热分离） |
| >5000 万 / >50 GB | 水平分表 |

> **依据**：B+Tree 三层可索引 ~2000 万行；超过开始进入第四层 IO，性能下降。

### 3.4 大字段拆分

```sql
-- 订单主表（高频查询）
order: id, user_id, amount, status, create_time, ...

-- 订单详情表（仅看详情时查）
order_detail: order_id, product_list (TEXT), shipping_info (TEXT), ...
```

热数据小、冷数据大——拆开后 Buffer Pool 命中率提升。

### 3.5 必备字段

每张表必须有：

```sql
id          BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
update_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
is_deleted  TINYINT  NOT NULL DEFAULT 0   COMMENT '0未删 1已删（软删除）'
```

> **软删除**：互联网通常不真删数据——审计、回溯、防误操作。但软删除会让索引区分度下降，需配合定期归档。

---

## 四、列设计规范

### 4.1 数据类型最小化

| 业务 | 推荐 |
| --- | --- |
| 状态枚举（≤256） | `TINYINT UNSIGNED` |
| ID（中等业务量） | `INT UNSIGNED` |
| ID（互联网业务） | `BIGINT UNSIGNED` |
| 计数（不会负） | `INT UNSIGNED` |
| 金额 | `DECIMAL(M,2)`（不要 FLOAT/DOUBLE） |
| 短文本 | `VARCHAR(N)` |
| 长文本 | `TEXT`（拆独立表） |
| 时间 | `DATETIME` |

### 4.2 char vs varchar

| 选 | 何时 |
| --- | --- |
| **char(N)** | 长度严格固定（手机号 11、身份证 18、MD5 32） |
| **varchar(N)** | 变长（昵称、地址等） |

CHAR 性能略高、空间略浪费；VARCHAR 反之。**互联网默认 VARCHAR**——固定长度的反而少。

### 4.3 禁用 timestamp

> **理由**：
> - timestamp 范围只到 2038-01-19 03:14:07（**2038 问题**）
> - timestamp 受时区影响（MySQL 在 SET / GET 时换算）
>
> 一律用 `DATETIME`——8 字节，范围到 9999 年，无时区。

### 4.4 用 TINYINT 替代 ENUM

```sql
-- 不推荐
gender ENUM('男', '女', '未知')

-- 推荐
gender TINYINT NOT NULL DEFAULT 0 COMMENT '0未知 1男 2女'
```

> **理由**：ENUM 增加新值要 ALTER TABLE（DDL，可能锁表）；TINYINT 加新值无需改表，业务字典表管理。

### 4.5 必须 NOT NULL DEFAULT

```sql
-- 不推荐
description VARCHAR(500)   -- 默认 NULL

-- 推荐
description VARCHAR(500) NOT NULL DEFAULT ''
```

> **理由**：
> - NULL 让索引、统计、比较都更复杂
> - NULL 占额外 bitmap 位
> - `count(field)` 不计 NULL，业务理解错乱
> - `is null` / `is not null` 写起来啰嗦

### 4.6 金额用 DECIMAL，不要 FLOAT/DOUBLE

```sql
-- 错误：浮点数有精度问题
price FLOAT      -- 0.1 + 0.2 = 0.30000000000000004

-- 正确
price DECIMAL(10, 2)   -- 精确十进制
```

互联网业务中**金钱、利率、汇率**都必须 DECIMAL。

---

## 五、索引设计规范

### 5.1 单表索引数量 ≤ 5

> **理由**：
> - 每个二级索引存"主键值 + 索引列"，占空间
> - INSERT/UPDATE 要更新所有相关索引
> - 优化器选择空间大，反而可能选错

### 5.2 组合索引字段数 ≤ 5

> **理由**：5 个字段还不能极大缩小范围 → 大概率设计有问题。复杂查询应该上 ES / OLAP。

### 5.3 不在区分度低的字段建索引

```sql
-- 性别字段（只有男/女/未知）建索引几乎无用
KEY idx_gender (gender)
```

> **判断**：`SELECT COUNT(DISTINCT col) / COUNT(*)` 应 >0.1（即每个值平均不超过 10% 的行）。

### 5.4 不在频繁更新字段建索引

`status`、`update_time` 这种高频改的字段，每次更新都触发 B+Tree 重组——必要时建（业务需要）但要权衡。

### 5.5 组合索引：等值放前、范围放后

```sql
-- 业务：WHERE user_id=? AND status=? AND create_time > ?
KEY idx_user_status_time (user_id, status, create_time)
   ↑ 等值     ↑ 等值     ↑ 范围
```

> **理由**：范围列后面的列断索引（详见 [索引](./索引.md)）。

### 5.6 利用最左前缀，避免重复索引

```sql
-- 已有
KEY idx_a (a),
KEY idx_a_b (a, b)
```

`idx_a` 是冗余的——`idx_a_b` 已包含 a 的最左前缀。

---

## 六、SQL 使用规范

### 6.1 禁止 SELECT *

```sql
-- 错误
SELECT * FROM user WHERE id=1;

-- 正确
SELECT id, name, email FROM user WHERE id=1;
```

> **理由**：
> - 网络带宽浪费
> - 没法用覆盖索引
> - 表结构变更（增删列）破坏应用 SQL

### 6.2 INSERT 必须指定字段

```sql
-- 错误
INSERT INTO user VALUES (1, '张三', 25, ...);

-- 正确
INSERT INTO user (id, name, age) VALUES (1, '张三', 25);
```

> **理由**：列顺序变更或加列时不破坏。

### 6.3 禁止隐式类型转换

```sql
-- 错误：phone 是 VARCHAR
SELECT * FROM user WHERE phone = 13800138000;
                          ↑ 数字 → 索引失效

-- 正确
SELECT * FROM user WHERE phone = '13800138000';
```

应用代码用 PreparedStatement 自动带类型——**禁止字符串拼接 SQL**。

### 6.4 禁止 WHERE 列函数 / 表达式

```sql
-- 错误
WHERE YEAR(create_time) = 2024
WHERE id + 1 = 100

-- 正确
WHERE create_time BETWEEN '2024-01-01' AND '2025-01-01'
WHERE id = 99
```

### 6.5 不推荐左模糊

```sql
-- 错误
WHERE name LIKE '%三'        -- 不走索引
WHERE name LIKE '%三%'        -- 不走索引

-- 正确
WHERE name LIKE '张%'         -- 前缀匹配可走索引
```

模糊搜索建议走 ES / 全文索引。

### 6.6 大表禁止 JOIN / 子查询

```sql
-- 慎用：千万行 JOIN
SELECT ... FROM big_table_1 JOIN big_table_2 ...
```

互联网做法：
- 业务侧两次查询 + 内存关联
- 反范式化（冗余字段）
- 上 OLAP（ClickHouse / Doris）

### 6.7 禁止 ORDER BY RAND()

```sql
-- 错误：排所有行 + 随机数
SELECT * FROM t ORDER BY RAND() LIMIT 1;
```

→ filesort 全表扫，海量行卡死。

**正确**：业务侧生成随机 ID 再查。

### 6.8 LIMIT 不能滥用

```sql
-- 错误：深分页
SELECT * FROM t LIMIT 1000000, 10;   -- 扫 100 万行

-- 正确
WHERE id > 1000000 LIMIT 10
-- 或延迟关联
```

详见 [SQL 优化](./sql优化.md#32-limit-深分页)。

---

## 七、事务规范

### 7.1 事务必须短

| 类型 | 时长上限 |
| --- | --- |
| 用户请求级事务 | < 200ms |
| 后台批处理事务 | < 1s |

> **理由**：长事务卡 Purge → undo 膨胀；锁占太久 → 业务阻塞。

### 7.2 事务中禁止 RPC / 网络调用

```java
// 错误：事务中调外部 API，如果 API 卡住 30 秒，事务也卡 30 秒
@Transactional
public void doBusiness() {
    db.update();
    httpClient.call(externalApi);   // 危险！
    db.update();
}
```

→ 数据库连接长时间被占，整体雪崩。

### 7.3 只读方法不要乱加事务

```java
// 错误：纯读不需要事务
@Transactional
public Order getOrder(Long id) {
    return mapper.select(id);
}

// 正确
@Transactional(readOnly = true)   // 或干脆不加
```

### 7.4 大批量改 → 拆 BATCH

```java
// 错误：一次改 100 万行
UPDATE order SET status=1 WHERE create_time < '2024-01-01';

// 正确：每次 5000 行
while (true) {
    int n = mapper.batchUpdate(5000);
    if (n == 0) break;
    Thread.sleep(50);   // 给从库喘息
}
```

---

## 八、生产防护规范

### 8.1 DDL 必须走变更平台

不要在生产库直接 `ALTER TABLE`。原因：
- DDL 在大表会锁数小时
- 主从延迟数小时
- 失败回滚痛苦

工具：**gh-ost**、**pt-online-schema-change**、**Cloud DBA**。

### 8.2 DDL 前必查长事务

```sql
SELECT * FROM information_schema.innodb_trx
WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 60;
```

有长事务 → 等它结束再 DDL；否则 MDL 锁会阻塞所有查询。

### 8.3 生产敏感命令禁用

```sql
-- 严禁
DROP DATABASE
DROP TABLE         -- 改名（rename 后业务确认无影响再删）
TRUNCATE TABLE
DELETE FROM xxx;   -- 没 WHERE
UPDATE xxx SET ...; -- 没 WHERE

-- 限制工具账号 / 申请走流程
GRANT ... ON ... TO ...
```

### 8.4 数据变更必须有恢复方案

DELETE 前先备份：
```sql
CREATE TABLE order_backup AS SELECT * FROM order WHERE create_time < '2024-01-01';
DELETE FROM order WHERE create_time < '2024-01-01';
```

或开启 binlog ROW 格式后能用 `mysqlbinlog` 反向恢复。

---

## 九、面试高频追问

### Q1：为什么不让用 ENUM？

新增枚举值要 ALTER TABLE，可能锁表数小时；TINYINT + 应用层字典更灵活。

### Q2：为什么互联网禁外键？

外键检查影响写性能；外键级联可能死锁；分库分表后跨库无法维护。业务一致性由应用代码保证。

### Q3：主键为什么用自增 BIGINT？

- 自增：顺序写、不页分裂
- BIGINT：INT 21 亿不够用
- UNSIGNED：业务 ID 不会负

### Q4：为什么不让 SELECT *？

网络浪费、不能覆盖索引、表结构变更破坏应用。

### Q5：单表多大需要分库分表？

经验值 500 万行 / 5GB 起考虑垂直拆分；5000 万 / 50GB 起考虑水平分表。**B+Tree 三层 ≈ 2000 万行**是物理依据。

### Q6：为什么禁 timestamp？

2038 年溢出 + 时区问题。一律用 DATETIME。

### Q7：金额为什么不能 FLOAT？

浮点精度丢失：`0.1 + 0.2 ≠ 0.3`。金钱必须 DECIMAL(M, N)。

### Q8：单表索引为什么 ≤ 5？

每个索引占空间 + 写入路径要维护；优化器选择多容易选错。

### Q9：长事务为什么有害？

undo 不能 Purge → 磁盘膨胀；锁占太久 → 业务阻塞；主从延迟。

### Q10：DDL 为什么必须走平台？

锁表时间长（特别是 5.6 前）；失败回滚困难；主从延迟灾难。gh-ost / pt-osc 用影子表 + 触发器 + 切表，无锁不延迟。

---

## 十、答题模板（60 秒话术）

> 数据库规范分七层：
>
> 1. **基础**：必须 InnoDB + utf8mb4；表 / 字段必须中文注释；环境隔离。
> 2. **命名**：小写下划线；唯一索引 uk_、普通 idx_；时间 create_time / update_time；删除 is_deleted。
> 3. **表设计**：必须 BIGINT UNSIGNED 自增主键；禁外键；单表 ≤500 万行考虑拆分。
> 4. **列**：类型最小化；禁 timestamp（2038 + 时区）、金额 DECIMAL、字段 NOT NULL DEFAULT；用 TINYINT 替 ENUM。
> 5. **索引**：单表 ≤5；组合索引等值前范围后；区分度低不建。
> 6. **SQL**：禁 `SELECT *`；INSERT 列出字段；WHERE 禁函数 / 表达式 / 隐式转换；禁 `ORDER BY RAND()`。
> 7. **事务 / 运维**：事务 <1s；事务内禁 RPC；DDL 走平台（gh-ost）；DDL 前查长事务；生产敏感命令限权。
>
> 每条规范背后都有真实事故——比如 utf8 不存 emoji、外键导致死锁、timestamp 时区错乱、ALTER 锁表整库阻塞。

---

## 十一、相关文档

- [索引](./索引.md) — 索引设计原理
- [SQL 优化与慢查询](./sql优化.md) — 实战优化
- [事务的原理](./事务的原理.md) — 长事务危害
- [架构总览](./架构总览.md) — 引擎选择
