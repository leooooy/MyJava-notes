# MySQL 面试模块

> 大厂后端面试的"必考四大件"之一（Redis / MySQL / JVM / 并发）。
>
> 本模块按 **架构 → 存储引擎 → 事务并发 → 日志 → 性能优化 → 高可用 → 新特性** 七层组织，每篇都按 senior 标准写：原理 + 取舍 + 面试追问 + 生产踩坑 + 答题模板。

---

## 一、模块导航

### 架构与执行（2 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [MySQL 架构总览](./架构总览.md) | 接入 / Server / 引擎 / 系统文件四层 + 引擎对比 |
| [SQL 语句执行过程](./sql语句执行过程.md) | 查询流程 + 更新流程 + **两阶段提交**（高频题） |

### 存储引擎与索引（4 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [InnoDB 存储引擎](./InnDB.md) | Buffer Pool / Change Buffer / Double Write / AHI / 后台线程 |
| [索引](./索引.md) | B+Tree / 聚簇索引 / 最左前缀 / 索引下推 / 失效场景 |
| [explain](./explain.md) | type / key_len / Extra 全解读 + 实战案例 |

### 事务与并发（5 篇）

> **层次关系**：事务原理（基础）→ 隔离级别（行为）→ MVCC（快照机制）+ 锁（互斥机制）→ 死锁（错乱处理）。
>
> ```
> [事务的原理]   ← ACID + 三大日志映射
>      ↓
> [事务的隔离级别]
>      ├─ MVCC          ← 快照读，解决脏读 / 不可重复读 / 部分幻读
>      └─ 锁机制         ← 解决当前读 / 写写
>            ↓
>      [死锁分析]        ← 锁冲突的兜底排查
> ```

| 文档 | 一句话定位 |
| --- | --- |
| [事务的原理](./事务的原理.md) | ACID 与 undo / redo / binlog 映射 |
| [事务的隔离级别](./事务的隔离级别.md) | 四级别 + RC vs RR 生产选型 + 幻读真相 |
| [MVCC](./mvcc.md) | 隐式字段 + 版本链 + ReadView + RC/RR 唯一区别 |
| [锁机制](./锁机制.md) | 全局 / 表 / 行 / 间隙 / 临键锁 + 加锁规则总结 |
| [死锁分析](./死锁分析.md) | 5 种典型模式 + LATEST DETECTED DEADLOCK 排查 |

### 日志与崩溃恢复（1 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [三大日志](./日志.md) | redo / undo / binlog 对比 + 两阶段提交 + group commit |

### 性能优化、设计与规范（3 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [SQL 优化与慢查询分析](./sql优化.md) | 9 类优化手法 + pt-query-digest + 服务器调优 |
| [数据库设计与范式](./数据库设计与范式.md) | 三范式 + 反范式实战 + E-R 建模 + 订单系统设计 |
| [MySQL 开发规范](./MySQL规范.md) | 7 大类军规 + 每条背后的事故 |

### 高可用与扩展（3 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [主从复制](./主从复制.md) | 三线程 + 异步/半同步 + GTID + 主从延迟治理 |
| [备份与恢复](./备份与恢复.md) | mysqldump / Xtrabackup / **PITR 时间点恢复** / 备份策略与验证 |
| [分库分表](./分库分表.md) | 四象限拆分 + 分片键 + 分布式新问题 + NewSQL 替代 |

### 新特性（1 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [MySQL 8.0 新特性](./MySQL8.0新特性.md) | 窗口函数 / CTE / 隐藏索引 / Hash Join / 原子 DDL / JSON |

---

## 二、面试高频题 → 文档映射

被问到这些题，直接跳到对应文档：

| 高频题 | 跳转 |
| --- | --- |
| MySQL 架构有几层？ | [架构总览](./架构总览.md) |
| InnoDB 和 MyISAM 区别？ | [架构总览 - 引擎对比](./架构总览.md#四存储引擎对比高频面试题) |
| 一条 update 语句的全过程？ | [SQL 执行过程 - 更新流程](./sql语句执行过程.md#二更新流程必背重点) |
| 为什么要两阶段提交？ | [SQL 执行过程 - 两阶段提交](./sql语句执行过程.md#三两阶段提交-xa--2pc) |
| 崩溃恢复时事务怎么定生死？ | [SQL 执行过程](./sql语句执行过程.md) / [日志](./日志.md) |
| Buffer Pool 改良 LRU 是怎么回事？ | [InnoDB - 改良 LRU](./InnDB.md#311-改良版-lru必背) |
| Change Buffer 解决什么问题？为什么不对唯一索引生效？ | [InnoDB - Change Buffer](./InnDB.md#32-change-buffer写优化) |
| Double Write 解决什么？为什么 redo log 不够？ | [InnoDB - Double Write](./InnDB.md#42-double-write防部分写失效) |
| MySQL 索引为什么用 B+Tree？ | [索引 - 为什么是 B+Tree](./索引.md#一为什么是-btree) |
| 聚簇索引和非聚簇索引区别？ | [索引 - 聚簇 vs 非聚簇](./索引.md#二聚簇索引-vs-非聚簇索引) |
| 什么是回表？覆盖索引？索引下推？ | [索引 - 回表与覆盖](./索引.md#三回表与覆盖索引) |
| 最左前缀原则？为什么范围列后续断索引？ | [索引 - 组合索引](./索引.md#四组合索引与最左前缀) |
| 索引为什么会失效？ | [索引 - 索引失效](./索引.md#五索引失效全场景) |
| EXPLAIN 怎么看？ | [explain](./explain.md) |
| Using filesort / Using temporary 怎么办？ | [explain - Extra](./explain.md#七extra附加信息必看) |
| ACID 各靠什么实现？ | [事务的原理](./事务的原理.md#一acid) |
| undo log 什么时候删？ | [事务的原理](./事务的原理.md#22-提交也要写-undo) |
| 脏读 / 不可重复读 / 幻读区别？ | [事务的隔离级别](./事务的隔离级别.md#一并发事务的三种现象) |
| MySQL 默认隔离级别是什么？为什么不是 RC？ | [事务的隔离级别](./事务的隔离级别.md#五rc-vs-rr-生产选型) |
| RR 解决幻读了吗？ | [事务的隔离级别 - RR 真的解决幻读吗](./事务的隔离级别.md#四rr-真的解决了幻读吗高频陷阱) |
| MVCC 怎么实现的？RC 和 RR 在 MVCC 上的差别？ | [MVCC](./mvcc.md) |
| ReadView 几个字段？可见性怎么判断？ | [MVCC - ReadView](./mvcc.md#23-readview一致性视图) |
| 行锁是怎么实现的？ | [锁机制 - 行级锁](./锁机制.md#四行级锁innodb-重点) |
| 什么是 MDL？为什么生产容易出事？ | [锁机制 - MDL](./锁机制.md#32-mdlmetadata-lock元数据锁) |
| 意向锁是什么？为什么需要？ | [锁机制 - 意向锁](./锁机制.md#33-意向锁is--ix) |
| Gap Lock / Next-Key Lock 在哪个级别才有？ | [锁机制 - 行锁形态](./锁机制.md#43-三种行锁形态) |
| 加锁规则三原则？ | [锁机制 - 加锁规则](./锁机制.md#五加锁规则高频考点) |
| 发生死锁怎么排查？ | [死锁分析](./死锁分析.md) |
| 常见死锁模式？ | [死锁分析 - 典型模式](./死锁分析.md#四典型死锁案例) |
| redo log 和 binlog 区别？ | [日志 - redo vs binlog](./日志.md#五redo-vs-binlog-对比) |
| binlog 三种格式怎么选？ | [日志 - binlog](./日志.md#四binlog二进制日志) |
| WAL 是什么？为什么 redo 顺序写比改数据页随机写快？ | [日志 - redo log](./日志.md#二redo-log重做日志) |
| 怎么发现慢 SQL？ | [SQL 优化 - 慢日志](./sql优化.md#一慢-sql-的发现) |
| 深分页怎么优化？ | [SQL 优化 - 深分页](./sql优化.md#32-limit-深分页) |
| count(*) 慢吗？怎么优化？ | [SQL 优化 - count](./sql优化.md#35-count-优化) |
| JOIN 怎么优化？ | [SQL 优化 - JOIN](./sql优化.md#34-join-优化) |
| Java 批量 INSERT 为什么很慢？ | [SQL 优化 - 批量插入](./sql优化.md#39-批量插入) |
| 互联网公司的 MySQL 规范有哪些？ | [MySQL 规范](./MySQL规范.md) |
| 单表多大需要分库分表？ | [分库分表 - 触发条件](./分库分表.md#一为什么需要分库分表) |
| 分片键怎么选？ | [分库分表 - 分片键](./分库分表.md#三分片键sharding-key选择) |
| 跨片 JOIN / 跨片事务怎么办？ | [分库分表 - 分布式新问题](./分库分表.md#四分布式新问题) |
| 主从复制流程？ | [主从复制 - 三个线程](./主从复制.md#二复制原理三个线程) |
| 主从延迟根因和治理？ | [主从复制 - 延迟治理](./主从复制.md#五主从延迟replication-lag) |
| 异步 / 半同步 / 同步区别？ | [主从复制 - 复制模式](./主从复制.md#三复制模式) |
| 三范式各是什么？区别？ | [数据库设计与范式 - 三范式](./数据库设计与范式.md#二三范式必背) |
| 互联网为什么不严格遵循范式？ | [数据库设计与范式 - 反范式](./数据库设计与范式.md#三反范式互联网核心实战) |
| 订单表为什么冗余 user_name / 商品价格？ | [数据库设计与范式 - 订单实战](./数据库设计与范式.md#五订单系统建模实战高频场景) |
| MySQL 怎么备份？逻辑还是物理？ | [备份与恢复 - 逻辑 vs 物理](./备份与恢复.md#二备份的两个维度) |
| mysqldump 加 --single-transaction 的原理？ | [备份与恢复 - mysqldump](./备份与恢复.md#33-single-transaction-工作原理) |
| 误删表怎么救？什么是 PITR？ | [备份与恢复 - PITR 流程](./备份与恢复.md#七pitr-完整流程核心) |
| 备份策略怎么定？ | [备份与恢复 - 生产策略](./备份与恢复.md#八备份策略生产实战) |
| Xtrabackup 怎么实现热备？ | [备份与恢复 - Xtrabackup](./备份与恢复.md#五percona-xtrabackup物理备份生产首选) |
| MySQL 8.0 哪些新特性？ | [MySQL 8.0 新特性](./MySQL8.0新特性.md) |
| 窗口函数和 GROUP BY 区别？ | [MySQL 8.0 - 窗口函数](./MySQL8.0新特性.md#11-窗口函数window-functions) |
| 递归 CTE 应用场景？ | [MySQL 8.0 - CTE](./MySQL8.0新特性.md#13-cte-common-table-expression) |
| 隐藏索引 / 函数索引怎么用？ | [MySQL 8.0 - 索引能力](./MySQL8.0新特性.md#二索引能力升级) |
| Hash Join 解决什么问题？ | [MySQL 8.0 - Hash Join](./MySQL8.0新特性.md#三join-能力跨越hash-join) |
| 原子 DDL 是什么？ | [MySQL 8.0 - 原子 DDL](./MySQL8.0新特性.md#42-原子-ddlatomic-ddl) |
| JSON 字段怎么建索引？ | [MySQL 8.0 - JSON](./MySQL8.0新特性.md#六json-增强57-引入80-大量优化) |
| 8.0 升级要注意什么？ | [MySQL 8.0 - 升级注意](./MySQL8.0新特性.md#九升级-80-注意事项) |

---

## 三、推荐学习路径

### 新手路径（按依赖顺序）

```
基础层
 1. MySQL 架构总览                ← 全局视图
 2. SQL 执行过程                  ← 一条 SQL 的内部
 3. InnoDB 存储引擎               ← 存储 / 内存 / 后台线程

索引与查询
 4. 索引                          ← 必学，最高频考点
 5. explain                       ← 配合索引验证

事务与并发
 6. 事务的原理                     ← ACID + 三大日志
 7. 事务的隔离级别                 ← 4 级别 + RC/RR 选型
 8. MVCC                          ← 快照读机制
 9. 锁机制                        ← 互斥机制
10. 死锁分析                      ← 锁的兜底
11. 日志                          ← undo / redo / binlog 整合

设计与优化
12. 数据库设计与范式               ← 三范式 + 反范式实战
13. SQL 优化与慢查询              ← 性能调优
14. MySQL 开发规范                ← 上线前必看

高可用
15. 主从复制                      ← 高可用基础
16. 备份与恢复                    ← PITR 时间点恢复
17. 分库分表                      ← 横向扩展终极

新特性
18. MySQL 8.0 新特性              ← 窗口函数 / CTE / Hash Join
```

### 面试速通路径（30 分钟刷一遍）

每篇看 **答题模板** 一节就够：

**架构与执行**
- [架构总览 - 答题模板](./架构总览.md#九答题模板30-秒话术)
- [SQL 执行过程 - 答题模板](./sql语句执行过程.md#九答题模板60-秒话术)

**存储与索引**
- [InnoDB - 答题模板](./InnDB.md#九答题模板60-秒话术)
- [索引 - 答题模板](./索引.md#十答题模板60-秒话术)
- [explain - 答题模板](./explain.md#十一答题模板30-秒话术)

**事务与并发**
- [事务的原理 - 答题模板](./事务的原理.md#九答题模板60-秒话术)
- [事务的隔离级别 - 答题模板](./事务的隔离级别.md#九答题模板60-秒话术)
- [MVCC - 答题模板](./mvcc.md#九答题模板30-秒话术)
- [锁机制 - 答题模板](./锁机制.md#十答题模板60-秒话术)
- [死锁分析 - 答题模板](./死锁分析.md#九答题模板60-秒话术)
- [日志 - 答题模板](./日志.md#十答题模板60-秒话术)

**设计与优化**
- [SQL 优化 - 答题模板](./sql优化.md#九答题模板60-秒话术)
- [数据库设计与范式 - 答题模板](./数据库设计与范式.md#十答题模板60-秒话术)
- [MySQL 规范 - 答题模板](./MySQL规范.md#十答题模板60-秒话术)

**高可用**
- [主从复制 - 答题模板](./主从复制.md#十一答题模板60-秒话术)
- [备份与恢复 - 答题模板](./备份与恢复.md#十二答题模板60-秒话术)
- [分库分表 - 答题模板](./分库分表.md#九答题模板60-秒话术)

**新特性**
- [MySQL 8.0 新特性 - 答题模板](./MySQL8.0新特性.md#十二答题模板60-秒话术)

---

## 四、关键速记表

### 4.1 InnoDB 关键参数

```ini
# 内存
innodb_buffer_pool_size       = 物理内存 × 0.5~0.75
innodb_buffer_pool_instances  = 8
innodb_log_buffer_size        = 16M

# redo log
innodb_log_file_size          = 1G ~ 4G
innodb_flush_log_at_trx_commit = 1     # 双 1 高可靠

# binlog
sync_binlog                   = 1
binlog_format                 = ROW
gtid_mode                     = ON

# 文件
innodb_file_per_table         = ON

# 复制
slave_parallel_type           = LOGICAL_CLOCK
slave_parallel_workers        = 8
slave_preserve_commit_order   = 1
rpl_semi_sync_master_enabled  = 1

# IO（SSD）
innodb_io_capacity            = 2000
innodb_flush_neighbors        = 0

# 监控
slow_query_log                = ON
long_query_time               = 0.5
innodb_print_all_deadlocks    = ON
```

### 4.2 三大日志一图

| 日志 | 层 | 类型 | 作用 |
| --- | --- | --- | --- |
| **undo** | InnoDB | 逻辑（反向操作） | 回滚 + MVCC |
| **redo** | InnoDB | 物理（页修改） | 崩溃恢复 |
| **binlog** | Server | 逻辑（行/SQL） | 主从复制 + PITR |

### 4.3 隔离级别 + 锁

| 级别 | 脏读 | 不可重复 | 幻读 | 实现 |
| --- | --- | --- | --- | --- |
| RU | ✓ | ✓ | ✓ | 不做特殊保护 |
| RC | ✗ | ✓ | ✓ | MVCC（每次新 ReadView） |
| **RR** | ✗ | ✗ | ✗* | MVCC（首次 ReadView 复用）+ Gap Lock |
| Serializable | ✗ | ✗ | ✗ | 全 SELECT 加 S 锁 |

\* 快照读由 ReadView 解，当前读由 Next-Key Lock 解

### 4.4 加锁规则速查

| 索引 | 查询 | 命中 | 锁形态 |
| --- | --- | --- | --- |
| 唯一索引 | 等值 | 命中 | Record Lock |
|  |  | 不命中 | Gap Lock |
|  | 范围 | — | Next-Key Lock + 多锁一行 |
| 普通索引 | 等值 | 命中 | Next-Key + 后续 Gap |
|  |  | 不命中 | Gap Lock |
|  | 范围 | — | Next-Key Lock |

### 4.5 EXPLAIN type 排序

```
system > const > eq_ref > ref > range > index > ALL
                                           ↑       ↑
                                         警告    必须优化
```

### 4.6 索引失效场景

```
1. 函数 / 表达式：YEAR(t)=2024
2. 隐式类型转换：phone=13800138000 (varchar)
3. 左模糊：LIKE '%xx'
4. 跳过最左前缀
5. 范围列后续列断索引
6. OR 一边无索引
7. 区分度低（性别）→ 优化器放弃
```

### 4.7 高频生产参数

| 场景 | 配置 |
| --- | --- |
| 金融级零丢失 | flush_log_at_trx_commit=1 + sync_binlog=1（双 1） |
| 互联网高吞吐 | flush_log_at_trx_commit=2 + sync_binlog=100~1000 |
| 半同步避免主挂丢数据 | rpl_semi_sync_master_enabled=1 |
| 主从并行复制 | slave_parallel_type=LOGICAL_CLOCK + 8 workers |

### 4.8 MySQL 版本演进

| 版本 | 关键变化 |
| --- | --- |
| 5.5 | InnoDB 成为默认引擎 |
| 5.6 | 在线 DDL；GTID；ICP；多线程 Purge |
| 5.7 | JSON；并行复制；Buffer Pool 在线 resize；undo 表空间独立 |
| 8.0 | 数据字典转 InnoDB（无 .frm）；窗口函数；CTE；隐藏索引；移除 Query Cache；Hash Join；ATOMIC DDL |

---

## 五、生产踩坑 TOP 10

| 坑 | 文档 |
| --- | --- |
| 长事务卡 Purge → undo 膨胀 → 磁盘炸 | [MVCC](./mvcc.md#71-长事务导致-undo-膨胀) |
| ALTER + 长事务 → MDL 锁全表 | [锁机制 - MDL](./锁机制.md#322-加锁规则) |
| 隐式类型转换吞 QPS（phone 字段不加引号） | [索引 - 索引失效](./索引.md#52-隐式类型转换的细节高频陷阱) |
| 大事务拆爆从库（ROW binlog 百万事件） | [主从复制 - 延迟](./主从复制.md#92-row-binlog-巨大事务卡死从库) |
| 索引太多 INSERT 慢一个量级 | [索引 - 单表索引数量](./索引.md#64-单表索引数量) |
| Java 批量 INSERT 实际还是逐条 | [SQL 优化 - 批量插入](./sql优化.md#39-批量插入) |
| sync_binlog=0 主从不一致 | [日志 - sync_binlog](./日志.md#84-sync_binlog0-主从不一致) |
| 深分页 LIMIT 1000000, 10 几十秒 | [SQL 优化 - 深分页](./sql优化.md#32-limit-深分页) |
| 分库分表用 order_id 当分片键 → 全分片广播 | [分库分表 - 分片键](./分库分表.md#71-分片键选错) |
| ibdata1 不收缩（没开 file_per_table） | [InnoDB](./InnDB.md#71-ibdata-不收缩) |

---

## 六、面试常被一连串追问的话题

按出现频率列出：

1. **索引**：B+Tree → 聚簇 vs 非聚簇 → 回表 → 覆盖索引 → 索引下推 → 失效
2. **MVCC**：隐式字段 → 版本链 → ReadView → RC vs RR → 与幻读
3. **锁**：全局 → 表 → MDL → 意向 → Record/Gap/Next-Key → 加锁规则
4. **隔离级别**：脏读/不可重复/幻读 → 4 级别 → RR 解决幻读 → RC vs RR 选型
5. **日志**：redo（物理 + WAL） → undo（回滚 + MVCC） → binlog（主从 + ROW） → 两阶段提交 → group commit
6. **执行流程**：连接 → Parser → Optimizer → Executor → Buffer Pool → 两阶段提交 → 主从
7. **慢 SQL 优化**：慢日志 → EXPLAIN → 索引 / SQL 改写 → 复测
8. **死锁**：必要条件 → InnoDB 检测 → LATEST DETECTED → 5 种模式 → 修复
9. **主从**：3 线程 → 异步/半同步 → GTID → 延迟根因 → 并行复制
10. **分库分表**：何时拆 → 分片键 → 跨片 JOIN/事务 → 全局 ID → 扩容
11. **数据库设计**：三范式 → 反范式动机 → E-R 建模 → 订单表为何冗余 user_name
12. **备份恢复**：mysqldump vs Xtrabackup → 全量 + 增量 → binlog → PITR 误删恢复 → 备份验证
13. **8.0 新特性**：窗口函数 → 递归 CTE → 隐藏索引 → Hash Join → 原子 DDL → JSON 索引

每条主线都对应至少一篇深度文档，按上方"高频题映射"快速跳转。

---

## 七、相关模块

- [Redis 面试模块](../Redis/README.md) — 缓存与 MySQL 配合
- [JVM](../JVM/README.md) — 应用层影响 DB 连接管理
- [Concurrency](../Concurrency/README.md) — 并发原语与 MVCC 思想
- [分布式事务](../Distributed/分布式事务.md) — 分库分表的事务方案
- [分布式ID](../Distributed/分布式ID.md) — Snowflake / Leaf
- [一致性哈希](../Distributed/一致性哈希.md) — 分片算法
