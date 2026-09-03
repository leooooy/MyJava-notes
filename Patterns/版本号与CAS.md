# 版本号与 CAS — MVCC / 乐观锁 / Raft term / ETag / 原子类同构设计

> 引子：
> ① **是什么**：**先读到一个版本号（version / trx_id / epoch / ETag / MD5），写时带上"我看到的版本"，服务端比对——一致才写、不一致就失败重试**。这条"乐观并发控制（OCC）"思想在 CPU 指令、数据库、HTTP 协议、分布式协议、配置中心里反复出现，每次只是版本号的"长相"不同。
> ② **面试为什么必考**：MySQL 的 MVCC、Java 的 AtomicInteger、HTTP 的 ETag、Raft 的 term、Kafka 的 leader epoch、Nacos 配置长轮询、业务的乐观锁——讲不清这套范式就讲不清半个并发面试。上一篇《主从复制范式》里"epoch/term 防脑裂"就是它的应用。
> ③ **本篇要解决**：① 这一堆看似无关的"版本号"是不是同一个东西 ② 乐观锁和悲观锁怎么选 ③ ABA 问题为什么只在某些场景出现 ④ 版本号应该选自增数字、UUID 还是内容哈希。

---

## 一、为什么需要版本号 / CAS

### 1.1 原始问题：并发写冲突

两个线程 / 客户端同时改一份数据，没有保护：

```
初始 balance = 100

T1 读 balance = 100
T2 读 balance = 100
T1 写 balance = 90（扣 10）
T2 写 balance = 80（扣 20）

最终 balance = 80   ❌ 应该是 70
```

**经典解法 1：悲观锁**。读的时候就加锁（`SELECT FOR UPDATE` / `synchronized` / 行锁 / 分布式锁）。问题：**大部分场景没冲突**，悲观锁等于"为了 1% 的冲突场景让 99% 的请求都等"——浪费。

**经典解法 2：乐观锁**。读不加锁，写时检查"我读到的版本还在不在"。**赌没人改**，输了就重试。

### 1.2 乐观控制的核心 idea

```
读：           T1 拿到 (balance=100, version=5)
检查并写：     T1 提交 "UPDATE balance=90 WHERE version=5"
              ├─ 服务端 version 仍是 5 → 写成功，version 升 6
              └─ 服务端 version 已是 6 → 写失败，T1 重试

T2 同时：      T2 也拿到 (balance=100, version=5)
              T2 提交 "UPDATE balance=80 WHERE version=5"
              ├─ T1 先到 → version 已是 6 → T2 失败
              └─ T2 重读 → (balance=90, version=6) → 重试 UPDATE balance=70 WHERE version=6 → 成功
```

**关键三件套**：
- **读时拿版本**（无锁）
- **写时比对版本**（原子操作）
- **失败重试**（业务侧自己重读重写）

---

## 二、共性骨架：六种"版本号"都在做同一件事

### 2.1 通用流程

```
[读取]
   │
   ▼
拿到 (data, version)
   │
   │  ...业务计算...
   │
   ▼
[写入]
   │
   ▼
发起 write(newData, expectVersion=version)
   │
   ▼
服务端原子检查：
   ├─ currentVersion == expectVersion?
   │      │
   │      ├─ 是 → 写入 + version 单调更新
   │      │      返回成功
   │      │
   │      └─ 否 → 拒绝
   │             返回 "版本冲突"
   │
   ▼
[客户端处理冲突]
   │
   ├─ 重试（重读+重写）
   ├─ 报错给上层
   └─ 合并冲突（如 Git）
```

### 2.2 六种系统的同构对照

| 维度 | **Java CAS / Atomic** | **MySQL MVCC** | **乐观锁（业务）** | **HTTP ETag** | **Raft term / ZK zxid / Kafka epoch** | **Nacos 配置 MD5** |
| --- | --- | --- | --- | --- | --- | --- |
| **版本号长什么样** | 内存值本身（or `AtomicStampedReference` 的 stamp）| `trx_id`（隐藏列，事务 ID）| 业务表的 `version` int 字段 | 内容哈希字符串 | 单调递增整数 | 配置内容的 MD5 |
| **谁生成** | 写入者自己 | InnoDB 事务管理器 | 业务方手动 +1 | Web 服务器 | Leader 选举时 +1 / 写入时 +1 | 配置发布时算 MD5 |
| **怎么"读到版本"** | 直接 load | SELECT 自动读到行的 trx_id | SELECT 业务字段时一起带回 | HTTP Response Header | RPC 响应 | 客户端拉到配置时一起拿 |
| **怎么"带版本写"** | `compareAndSet(expect, new)` | UPDATE 自带 WHERE 条件（隐式）| `UPDATE ... WHERE version=?` | `If-Match: <etag>` | RPC 请求带 term | 长轮询请求带 MD5 |
| **服务端怎么比对** | CPU 的 `cmpxchg` 指令 | undo 链 + ReadView 可见性判断 | SQL 的 WHERE 条件 | 比对 ETag | 比对 term 数字大小 | 字符串相等比较 |
| **失败怎么办** | while 自旋重试 | 当前读会重新加锁；快照读不冲突 | 业务重试 / 报错 | 客户端拿 409/412，决定重试或合并 | 旧 term 请求被拒绝；老 Leader 降级 | 长轮询挂起或立即返回新配置 |
| **本质** | 单变量原子更新 | 多版本快照读 | 行级乐观锁 | 资源版本协商 | 任期防脑裂 | 配置变更通知 |

### 2.3 一张图理解"为什么都是同一个范式"

```
                      共性骨架：读时拿版本 + 写时带版本 + 服务端比对
                                          │
        ┌─────────────────────┬───────────┴────────┬──────────────────────┐
        │                     │                    │                      │
   单变量原子             数据库行级          分布式任期           资源协商
   （硬件 / JVM）         （数据库内置）      （共识协议）         （应用协议）
        │                     │                    │                      │
   ┌────┴────┐           ┌────┴────┐          ┌────┴────┐            ┌────┴────┐
 Java CAS              MVCC                Raft term                ETag
 cmpxchg               trx_id              Kafka epoch              Nacos MD5
                       乐观锁              ZK zxid                  Git commit
```

**全是一种东西**：把"并发冲突"从"互斥锁阻塞"转化为"版本不匹配重试"。差别只在**版本号的形态**（数字 / 哈希 / 复合）和**冲突的处理时机**（CPU 自旋 / 业务重试 / 拒绝请求）。

---

## 三、关键机制详解

### 3.1 Java CAS：硬件级别的版本号

```java
public final int incrementAndGet() {
    int v;
    do {
        v = getIntVolatile(o, offset);
    } while (!compareAndSwapInt(o, offset, v, v + 1));   // 失败就重试
    return v + 1;
}
```

CPU 指令 `cmpxchg`（x86）+ `lock` 前缀，保证比较和交换是**原子**的：

```
LOCK CMPXCHG dest, src
    if (RAX == dest):       ← "我看到的旧值"
        dest = src          ← 写入新值
        ZF = 1              ← 成功
    else:
        RAX = dest          ← 把当前值读回 RAX
        ZF = 0              ← 失败
```

**这里的"版本号"是数据本身**——CAS 假设"数据没变 = 没人动过"。这是最朴素的版本号。

**问题**：ABA。值从 A → B → A，CAS 检查仍认为没变，但中间发生过变化。

→ 这是为什么有 `AtomicStampedReference`（用 stamp 作为额外版本号）

### 3.2 MVCC：多版本 + 隐式版本号

InnoDB 给每行加两个隐藏字段：

```
[行记录]
  - 业务列：name, balance, ...
  - DB_TRX_ID（6 字节）：最后修改这行的事务 ID
  - DB_ROLL_PTR：指向 undo log 中的旧版本

undo 链：
[最新: trx_id=300, name="张三"] → [trx_id=200, name="李四"] → [trx_id=100, name="王五"]
```

**读时拿版本**：SELECT 触发 ReadView 构造（"我能看到哪些事务"）。

**冲突检测**：ReadView 用 `(creator_trx_id, m_ids, min_trx_id, max_trx_id)` 判断每个版本对当前事务是否可见——可见就用，不可见就顺 roll_pointer 找老版本。

**写时**：当前读（UPDATE / DELETE / SELECT FOR UPDATE）走最新版本 + 加行锁——这里 MVCC 不解决冲突，**回到悲观锁**。

**这是 MVCC 的精妙**：读不加锁、走版本号判断；写还是加锁——不是纯乐观，而是"读乐观写悲观"的混合体。

→ 细节见 [MySQL/mvcc.md](../MySQL/mvcc.md)

### 3.3 业务乐观锁：显式 version 字段

```sql
-- 表结构
CREATE TABLE order_t (
    id BIGINT PRIMARY KEY,
    status VARCHAR(20),
    version INT DEFAULT 0
);

-- 读
SELECT id, status, version FROM order_t WHERE id=123;
-- 拿到 (status='created', version=5)

-- 业务计算...

-- 写（关键：WHERE 带 version）
UPDATE order_t SET status='paid', version=version+1 
WHERE id=123 AND version=5;
-- 影响行数 = 1 → 成功；= 0 → 冲突，重试
```

**核心特点**：业务层主动维护版本号，无需数据库特殊支持。**几乎所有 ORM（MyBatis Plus / JPA）的 @Version 都是这套**。

**vs MVCC**：业务乐观锁是**应用层版本号**（对所有读写都生效），MVCC 是**数据库内置版本号**（只对快照读生效）。两者可以共存：MVCC 提供读不加锁的高并发，业务乐观锁防止"两个事务读到相同快照写入冲突"的丢失更新。

### 3.4 HTTP ETag：资源版本协商

```
[GET 请求]
  GET /api/user/123
  ← HTTP 200
  ← ETag: "abc123"
  ← Body: {"name": "张三", ...}

[业务修改]

[PUT 请求，带 If-Match]
  PUT /api/user/123
  If-Match: "abc123"
  Body: {"name": "李四", ...}

  服务端：
  ├─ 当前 ETag == "abc123" → 200 OK + 新 ETag "def456"
  └─ 当前 ETag != "abc123" → 412 Precondition Failed

[条件 GET，省带宽]
  GET /api/user/123
  If-None-Match: "abc123"
  ← 304 Not Modified（资源没变）
```

**ETag 通常是内容哈希（MD5 / SHA）或单调计数器**。HTTP 协议层面把乐观控制做进了规范——RESTful API 的"防丢失更新"标准做法。

### 3.5 Raft term / Kafka epoch / ZK zxid：分布式任期号

这是上一篇《主从复制范式》里讲的脑裂防御招式。

**核心场景**：老 Leader 网络隔离没察觉，新 Leader 已经选出，老 Leader 继续接受写入 → 数据冲突。

**解法**：每次选举 term/epoch +1，所有副本拒绝来自旧 term 的请求。

```
T0: term=5, Leader=A
T1: A 网络隔离，B 当选 Leader，term=6
T2: A 还在用 term=5 发 AppendEntries
T3: Follower 看到 term=5 < 当前 term=6 → 拒绝
T4: A 收到 Follower 回应中的 term=6 → 自降为 Follower
```

**这里的"版本号"是 term 数字**——单调递增、永不重置（即使 Leader 是同一个节点重新当选也会换 term）。

| 系统 | 任期号叫什么 | 编码方式 |
| --- | --- | --- |
| Raft | `term` | 64 位整数 |
| Kafka | `leader epoch` | 32 位整数（per partition）|
| ZK | `zxid` | 64 位 = epoch (高 32) + counter (低 32) |
| ZK 配置变更 | `cversion`（子节点）/ `dataVersion`（数据）| 整数 |

**ZK zxid 的精妙**：epoch 标识"哪一任 Leader"，counter 标识"这任内的第几条变更"——单个 64 位数字同时表达"任期"和"任期内的进度"。选举时比 zxid 大的赢——既考虑任期新、又考虑进度多。

### 3.6 Nacos 配置 MD5：内容指纹作为版本

```
客户端长轮询请求：
  POST /v1/cs/configs/listener
  Body: dataId=foo + group=bar + md5=abc123    ← 我手里这版的指纹

服务端：
  当前配置 MD5 == "abc123" → hold 30s 不返回
  当前配置 MD5 != "abc123" → 立即返回新配置

客户端拿到新配置，重新计算 MD5，下次请求带新 MD5。
```

**MD5 作为版本号的好处**：
- **客户端无需维护单调计数**——任何时候只要拿配置内容就能算出 MD5
- **服务端无状态**——不用记"每个客户端订阅到了哪一版"
- **天然容忍乱序**——只要 MD5 匹配就认为同步

这正是《长轮询》那一篇讲过的核心机制——长轮询能做到"准实时通知 + 服务端无状态"，靠的就是 MD5 这个"内容版本号"。

→ 细节见 [Patterns/长轮询.md](./长轮询.md)

---

## 四、ABA 问题：版本号选择的关键考量

### 4.1 什么场景会出 ABA

**只有版本号 = "数据本身"或"内容哈希"的场景才有 ABA**。

```
T1 读到 head = ptr_A
T2 把 head pop 成 B，又 push 进 A（地址恰好复用） → head = ptr_A
T1 的 CAS(head, ptr_A, ptr_X) 仍成功 → 但中间链表已变结构 → 野指针
```

**ABA 在哪些系统出现**：

| 系统 | 是否会 ABA | 原因 |
| --- | --- | --- |
| Java CAS（裸 `AtomicInteger`）| ✅ | 值本身做版本 |
| Java `AtomicStampedReference` | ❌ | stamp 单调递增 |
| MySQL MVCC | ❌ | trx_id 单调递增 |
| 业务乐观锁（int version）| ❌ | version 只增不减 |
| HTTP ETag（哈希）| ✅ 理论上 | 但哈希冲突极小 |
| Raft term / ZK zxid | ❌ | 任期号单调递增 |
| Nacos MD5 | ✅ 理论上 | 同 ETag |

**结论**：**版本号一定要单调递增**，用哈希/内容做版本理论上有 ABA 但概率极小。

### 4.2 单调版本号的实现技巧

| 实现 | 适合 | 例子 |
| --- | --- | --- |
| **本地原子计数** | 单进程 | `AtomicLong`、业务乐观锁 |
| **事务级单调** | 数据库 | InnoDB trx_id（全局分配）|
| **选举级单调** | 共识协议 | Raft term（每次选举 +1）|
| **持久化时钟** | 跨重启场景 | ZK zxid（epoch 写盘）|

**关键陷阱**：版本号不能因为节点重启就回到 0。Raft 的 term、ZK 的 epoch 都必须持久化——否则节点重启后用更小的 term 写入会被 Follower 接受（如果有 bug 的话），破坏一致性。

---

## 五、悲观锁 vs 乐观锁：选型指南

### 5.1 核心 trade-off

| 维度 | 悲观锁 | 乐观锁 |
| --- | --- | --- |
| **核心思想** | 假设一定有冲突，先锁住 | 假设大概率无冲突，失败重试 |
| **典型实现** | `synchronized` / 行锁 / 分布式锁 | CAS / version 字段 / ETag |
| **性能（低冲突）** | 差（无谓加锁开销）| 好 |
| **性能（高冲突）** | 中（顺序排队）| 极差（自旋 / 重试爆炸）|
| **死锁风险** | 有 | 无 |
| **饿死风险** | 公平锁可解 | 高冲突下可能永远失败 |
| **失败语义** | 阻塞 / 超时 | 立即失败，业务决定 |

### 5.2 决策树

```
冲突率高吗？
├─ 是（如热点账户、秒杀库存）
│  └─ 选悲观锁（行锁 / 分布式锁 / Redis 锁）
│
└─ 否（绝大多数业务）
   └─ 进一步判断：写不写跨网络？
      ├─ 单机内存 → CAS（AtomicXxx）
      ├─ 单库 → MVCC（数据库自带）+ 业务 version 字段防丢失更新
      ├─ 跨服务调用 → 业务 version 字段 / ETag / 分布式锁
      └─ 跨节点协调 → Raft term / leader epoch
```

### 5.3 混合策略

实际生产几乎是 **MVCC + 乐观锁 + 兜底悲观锁** 的组合：

```
正常路径：业务读 (data, version) → 计算 → UPDATE WHERE version=X
失败 N 次：降级悲观锁（SELECT FOR UPDATE）保证一定成功
极热点：分布式锁前置（如秒杀的库存）
```

**乐观锁不是银弹**——高冲突场景一定要有悲观锁兜底。

---

## 六、生产踩坑

### 踩坑 1：CAS 自旋 CPU 跑满

**现象**：JVM CPU 飙到 100%，火焰图全是 `Unsafe.compareAndSwapInt`。

**根因**：业务在热点资源（如全局计数器）上用 `AtomicLong.incrementAndGet()`。100 个线程同时 +1，99 个失败重试，几乎所有 CPU 都在自旋。

**修复**：① 用 `LongAdder` 替代 `AtomicLong`——分段累加，按需汇总；② 业务侧分桶（把一个热点 key 拆成 N 个）；③ 实在不行加 `synchronized` 让线程顺序排队，反而比自旋快。

### 踩坑 2：业务乐观锁 version 没改，"丢失更新"

**现象**：金融业务对账少了几笔，无任何报错。

**根因**：DBA 直接用 SQL 改了几行业务表，没改 version 字段。后续业务用旧 version 做 UPDATE 居然命中——但实际写入的是被 DBA 改之前的快照。

**修复**：① 所有人改业务表必须改 version（DBA 操作走脚本审核）；② 关键金融场景用 MVCC + 业务 version 双重保护；③ binlog 监控对 version 字段不增反减的更新告警。

### 踩坑 3：MySQL 长事务把 undo 链拖死

**现象**：ibdata 文件从 50GB 涨到 800GB，磁盘告警。

**根因**：业务系统跑了一个查询 5 小时的报表事务，期间所有 UPDATE 的旧版本都不能被 Purge 线程清掉（Read View 还要用）——undo 链无限增长。

**修复**：① 监控 `information_schema.innodb_trx` 长事务（> 60s 报警）；② 报表走只读从库；③ 大查询拆分；④ 严禁 SELECT 不加 WHERE 条件。

→ MVCC 的 Purge 机制是版本号系统的"垃圾回收"——不及时清就内存/磁盘爆炸。

### 踩坑 4：HTTP ETag 用强校验导致请求都 412

**现象**：升级 Nginx + 后端后，所有 PUT 请求 412 Precondition Failed。

**根因**：客户端 If-Match 用的是旧 ETag，但后端响应的 ETag 算法变了（如开了 gzip、加了字段）——ETag 不再匹配。

**修复**：① ETag 算法升级要 backward compatible，或显式 bump 版本；② 客户端拿到 412 应该重新 GET 再 PUT，而不是直接报错；③ 弱校验 `W/"abc123"` 不严格比较内容指纹。

### 踩坑 5：Kafka leader epoch 不匹配导致丢消息（老问题）

**现象**：Kafka 0.10 时代偶发 partition 数据回退。

**根因**：老 Leader L1 在 epoch=5 写了消息 M，没复制就挂；新 Leader L2 起来 epoch=6 写了不同消息；L1 恢复后是 Follower，按 offset 截断到 L2 的 HW（high watermark），M 丢了。但 L1 已经向 Producer 回了成功（acks=1）。

**修复**：① 升级到 0.11+ 用 leader epoch + log truncation 协议（KIP-101）；② 关键场景 `acks=all` + `min.insync.replicas=2`；③ `unclean.leader.election.enable=false`。

**核心教训**：**任期号必须配合"日志截断协议"才能完全防数据回退**——光有任期号还不够，要保证新任 Leader 能让所有 Follower 回退到一致点。

### 踩坑 6：Nacos MD5 计算 CPU 飙高

**现象**：Nacos Server CPU 持续 70%+，火焰图 MD5 占 40%。

**根因**：6 万客户端每个订阅 100 个配置，长轮询每秒 20 万次 MD5 字符串比对 + 计算。

**修复**：① Server 端缓存配置的 MD5（不变时不重算）；② 升级到 Nacos 2.x 用 gRPC stream，版本号直接用 `release key` 数值比较；③ 客户端订阅按 group 聚合减少粒度。

---

## 七、面试高频追问

### Q1：CAS 和乐观锁是同一个东西吗？

**思想相同，实现层次不同**。

- CAS 是 CPU 指令级别的"原子比较+交换"——单变量、纳秒级
- 乐观锁是软件工程概念——可以用 CAS 实现（如 Java Atomic），也可以用数据库 WHERE 条件实现（业务 version 字段），也可以用 HTTP 协议实现（ETag）

**CAS 是乐观锁的最小单元**，乐观锁是 CAS 思想的工程化扩展。

### Q2：MVCC 是乐观锁吗？

**部分是**。MVCC 的"读不加锁"基于版本号判断可见性——是乐观锁思想；但"写"（当前读、UPDATE）还是加行锁——是悲观锁。

更准确的说法：**MVCC 是读乐观 + 写悲观的混合模型**。RC / RR 隔离级别能高并发，靠的是读乐观这一半。

### Q3：ABA 在什么场景下是真问题？

**只在"基于值/哈希做版本号"且"中间状态有副作用"的场景**：
- 无锁链表：head 指针指向被释放又分配回相同地址的节点 → 野指针
- 内存池：对象 ABA → 引用计数错

**不是问题的场景**：
- 业务逻辑只关心"最新值是什么"，不关心中间变化（如计数器）
- 用单调递增版本号（trx_id / term / 业务 version）的场景

解法：`AtomicStampedReference`（额外 stamp）或换成单调版本号。

### Q4：Raft 的 term 和 Kafka 的 epoch 是同一个东西吗？

**骨架相同**——都是单调递增的整数，每次"重新选举"时 +1，标识"哪一任 Leader"。所有节点拒绝来自旧任期的请求。

差别：
- Raft term：log entry 级别（每条 log 都带 term）；选举投票要看 lastLogTerm
- Kafka epoch：partition 级别（每 partition 独立 epoch）；配合 leader epoch cache + log truncation 协议

**本质都是"用单调数字表达 Leader 任期"防脑裂**——上一篇《主从复制范式》的核心招式。

### Q5：ETag 和 Nacos MD5 都是内容哈希做版本号，会不会冲突？

理论上有，实际可忽略。MD5 128 位空间下两个不同内容碰撞的概率 ≈ 2^-64——比"机房同时被雷劈"还小。

但有更隐蔽的坑：**哈希算法升级**或**编码格式变化**会导致同样内容算出不同哈希——这是踩坑 4 的根源。

### Q6：业务乐观锁失败了怎么办？

按"简单到复杂"四级：
1. **立即报错**：用户层重试（如表单提交失败让用户刷新页面再提）
2. **业务层重试**：捕获 `optimisticLockException`，重读重写最多 N 次
3. **降级悲观锁**：N 次失败后 SELECT FOR UPDATE，保证一次成功
4. **削峰填谷**：进 MQ 串行处理（如秒杀场景）

热点场景一定要有兜底——乐观锁在高冲突下重试 100 次也可能全失败。

### Q7：MVCC 为什么能"读不加锁"？

InnoDB 给每行加 `DB_TRX_ID`（事务版本号）+ undo 链。SELECT 时构造 ReadView 决定"我能看到哪些事务的修改"：

- 当前事务自己改的：可见
- 提交时间早于本事务的：可见
- 提交时间晚于本事务的：不可见，顺 roll_pointer 找老版本

整个过程**只查不写**——无锁。是 InnoDB 实现 RC/RR 高并发的核心。

→ 细节见 [MySQL/mvcc.md](../MySQL/mvcc.md)

### Q8：版本号应该选自增数字、UUID 还是内容哈希？

按用途：

| 用途 | 推荐版本号 | 原因 |
| --- | --- | --- |
| 业务乐观锁 | 自增 int | 简单、易比较 |
| 数据库行版本 | 事务 ID（DB 自动）| InnoDB 已经维护 |
| 共识协议任期 | 单调整数 | 选举语义需要 |
| HTTP 资源协商 | 内容哈希 | 服务端无需维护版本 |
| 配置同步 | 内容哈希 / release key | 客户端无需维护状态 |
| 分布式时钟 | 逻辑时钟（Lamport / vector）| 跨节点排序 |

**绝对禁止**：UUID 做版本号——无法比较大小。

### Q9：为什么 ZK 用 zxid（epoch + counter）而不是单 term？

zxid 同时表达两个维度：
- 高 32 位 epoch：哪一任 Leader（每次选举 +1）
- 低 32 位 counter：本任内的第几条变更（任期内单调递增）

**选举投票时**：先比 epoch（任期新的赢），epoch 相同比 counter（进度多的赢）。

Raft 的 term 只表达任期，比较时还要单独看 lastLogIndex；zxid 一个 64 位数搞定——**更紧凑、更易比较**。这也是 ZK 比 Raft 早出现的"前辈优势"。

---

## 八、答题模板（60 秒话术）

> **版本号 + CAS 是乐观并发控制（OCC）的通用范式**：读时拿到一个版本号，写时带上"我看到的版本"，服务端原子比对——一致才写、不一致就拒绝。冲突由客户端重试解决，无需阻塞。
>
> **六种同构实现**：
>
> ① **Java CAS**：CPU 的 `cmpxchg` 指令，值本身做版本——`AtomicInteger.compareAndSet(expect, new)`；
>
> ② **MySQL MVCC**：每行隐藏 `trx_id` + undo 链，SELECT 用 ReadView 判可见——读乐观、写悲观的混合；
>
> ③ **业务乐观锁**：业务表加 `version` 字段，`UPDATE WHERE version=?` 影响行数判断成功；
>
> ④ **HTTP ETag**：内容哈希做版本，`If-Match` 头协商——RESTful 防丢失更新标准；
>
> ⑤ **Raft term / Kafka epoch / ZK zxid**：单调递增整数标识 Leader 任期，旧任期请求被拒——防脑裂；
>
> ⑥ **Nacos 配置 MD5**：配置内容指纹做版本，长轮询请求带 MD5——服务端无状态。
>
> **关键 trade-off**：低冲突场景乐观锁性能爆赞；高冲突场景悲观锁更稳。生产用**MVCC + 业务乐观锁 + 兜底悲观锁**的组合——MVCC 提供读并发，业务 version 防丢失更新，热点场景降级 SELECT FOR UPDATE。
>
> **ABA 问题**只出现在"基于值/哈希做版本"的场景，单调递增版本号天然免疫。`AtomicStampedReference` 就是为了解决 CAS 的 ABA。
>
> **生产坑**：① CAS 自旋 CPU 跑满 → 用 LongAdder；② MVCC 长事务撑爆 undo 链 → 监控长事务；③ 业务 version 字段被绕过 → 严格审核 DBA 操作；④ Kafka 任期号还要配 log truncation 协议才完全防数据回退。

---

## 九、相关文档

### 本模块（横向）

- [主从复制范式](./主从复制范式.md) — Raft term / Kafka leader epoch 防脑裂是本范式的应用
- [长轮询 Long Polling](./长轮询.md) — Nacos MD5 是版本号在配置同步场景的应用
- [WAL 预写日志](./WAL预写日志.md) — Raft log 的 (term, index) 复合版本号

### 具体实现（纵向，回到原模块）

- [Concurrency/CAS与原子类.md](../Concurrency/CAS与原子类.md) — Java CAS、ABA、AtomicStampedReference
- [MySQL/mvcc.md](../MySQL/mvcc.md) — InnoDB 的 trx_id、undo 链、ReadView
- [MySQL/事务的隔离级别.md](../MySQL/事务的隔离级别.md) — RC/RR 在 MVCC 上的差异
- [MySQL/锁机制.md](../MySQL/锁机制.md) — 悲观锁（行锁、间隙锁）对照
- [Distributed/一致性算法.md](../Distributed/一致性算法.md) — Raft term / ZK zxid 的选举与日志匹配
- [Microservice/Nacos.md](../Microservice/Nacos.md) — 配置 MD5 的长轮询协议
