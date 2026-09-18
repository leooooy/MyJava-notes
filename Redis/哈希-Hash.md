# 哈希 Hash

> 一个 key 对应一个**字段-值**集合（类似 Java 的 `Map<String, String>`）。
> 面试核心：底层编码切换（ziplist/listpack → hashtable）+ 渐进式 rehash + 与 String JSON 方案的对比。

---

## 一、Hash 适合做什么

| 场景 | 用法 |
| --- | --- |
| **对象缓存** | 一个对象一个 key，字段作为 field（替代 String 存 JSON） |
| **购物车** | key=用户ID，field=商品ID，value=数量 |
| **配置中心** | key=配置组，field=配置项 |
| **计数器集合** | 一个用户的多个计数指标聚合存储 |
| **小型字典** | 字段数 < 1万时性能优于 String + 多 key |

**为什么不直接用 String 存 JSON？**

| 维度 | Hash | String + JSON |
| --- | --- | --- |
| 单字段读 | `HGET key field` | 必须读整个 JSON 反序列化 |
| 单字段更新 | `HSET key field v` | 整 JSON 反序列化 → 改 → 重新序列化 → 写入 |
| 内存效率 | 小集合时 listpack 紧凑 | 序列化开销大 |
| 网络传输 | 按需取字段 | 必传整个对象 |

→ **频繁读写单字段 → Hash；整对象访问/序列化复杂 → String JSON**。

---

## 二、常用命令速查

```bash
# 写
HSET key field value             # 单个写
HSET key f1 v1 f2 v2             # 4.0+ 支持批量
HMSET key f1 v1 f2 v2            # 批量（4.0 后被 HSET 覆盖）
HSETNX key field value           # 字段不存在才写

# 读
HGET key field                   # 单字段
HMGET key f1 f2                  # 批量字段
HGETALL key                      # 所有字段（⚠️ 大 Hash 会卡）
HKEYS key                        # 所有字段名
HVALS key                        # 所有值
HEXISTS key field                # 字段是否存在

# 数值
HINCRBY key field 1              # 字段值原子 +1
HINCRBYFLOAT key field 0.1       # 浮点 +

# 元信息
HLEN key                         # 字段数
HDEL key field [field...]        # 删除字段

# 渐进式遍历（推荐替代 HGETALL）
HSCAN key 0 MATCH pattern COUNT 100
```

**复杂度**：基本 O(1)；`HGETALL/HKEYS/HVALS/HSCAN` O(N)。

---

## 三、底层编码（关键）

Hash 有 **2 种编码**（不同版本叫法不同）：

| Redis 版本 | 小集合 | 大集合 |
| --- | --- | --- |
| < 7.0 | `ziplist` | `hashtable` |
| **≥ 7.0** | `listpack` | `hashtable` |

> **重大变更**：7.0 用 `listpack` 全面替换 `ziplist`，原因见后面。

### 3.1 编码切换条件

满足**任一**条件就从 listpack/ziplist 转为 hashtable：

```ini
hash-max-listpack-entries 128    # 字段数 ≤ 128
hash-max-listpack-value   64     # 任一字段名/值字节数 ≤ 64
```

（7.0 之前是 `hash-max-ziplist-entries / -value`，默认值相同。）

**关键规则**：
- 小集合（≤128 字段且每个 ≤64 字节）→ listpack（紧凑、省内存）
- 大集合 → hashtable（O(1) 读写）
- **只升不降**：转 hashtable 后即使删元素回到小集合，也不再回 listpack

### 3.2 listpack vs hashtable 对比

| 维度 | listpack（小） | hashtable（大） |
| --- | --- | --- |
| **数据结构** | 紧凑数组 | 数组 + 链表 |
| **读写复杂度** | O(N) | **O(1)** |
| **内存** | 极省（无指针、无桶） | 多（每个 entry 有指针、桶有空槽） |
| **遍历性能** | 顺序读，cache 友好 | 随机访问，cache 不友好 |

→ 设计哲学：**小数据用紧凑结构遍历快，大数据用哈希表查找快**。

---

## 四、hashtable 数据结构详解

```c
// 哈希表
typedef struct dictht {
    dictEntry **table;        // 桶数组
    unsigned long size;       // 桶数（2 的幂）
    unsigned long sizemask;   // size - 1，用于位运算取模
    unsigned long used;       // 已存储 entry 数
} dictht;

// 哈希节点
typedef struct dictEntry {
    void *key;
    union {
        void *val;
        uint64_t u64;
        int64_t s64;
        double d;
    } v;
    struct dictEntry *next;   // 拉链法解决冲突，头插
} dictEntry;

// 字典（外层封装）
typedef struct dict {
    dictType *type;
    void *privdata;
    dictht ht[2];             // ★ 两张表，rehash 用
    long rehashidx;           // -1 = 未在 rehash；否则记录进度
    unsigned long iterators;
} dict;
```

### 4.1 关键设计

1. **拉链法**：哈希冲突用单链表，**头插**（O(1)）
2. **位运算取模**：`hash & sizemask` 等价 `hash % size`，但快得多（`size` 必须是 2 的幂）
3. **两张表 ht[0] / ht[1]**：平时只用 ht[0]，rehash 时同时存在
4. **负载因子**：`load_factor = used / size`

### 4.2 何时触发 rehash

**扩容**（任一条件触发）：
- 没有 BGSAVE / BGREWRITEAOF 时，`load_factor >= 1`
- 有 BGSAVE / BGREWRITEAOF 时，`load_factor >= 5`

> **为什么有 BGSAVE 时阈值更高**？因为 BGSAVE 期间有 fork 子进程 + COW 共享内存。如果此时扩容会大量复制内存页，浪费物理内存。

**缩容**：`load_factor < 0.1`

---

## 五、渐进式 Rehash（核心面试点）

### 5.1 为什么需要渐进式

Hash 表很大时（比如 1000 万 entry），一次性 rehash 要：
- 分配新表内存（几百 MB）
- 遍历所有 entry 重新计算 hash
- 拷贝所有指针

**主线程会阻塞数秒**，业务直接挂。所以 Redis 把这个过程分摊到很多次操作中。

### 5.2 工作机制

```
1. 触发扩容：alloc ht[1] = 2 × ht[0].size
2. rehashidx = 0，开始 rehash
3. 每次执行 dict 的 CRUD 操作时：
   - 把 ht[0].table[rehashidx] 这个桶的所有 entry 迁移到 ht[1]
   - rehashidx++
4. 同时还有定时任务（每 1ms 干 100 微秒 rehash 工作），加速完成
5. 当 ht[0] 全部迁移完 → 释放 ht[0]，ht[1] 变成新的 ht[0]，rehashidx = -1
```

### 5.3 rehash 期间的 CRUD 怎么处理

| 操作 | 逻辑 |
| --- | --- |
| **添加** | 直接写入 ht[1]（避免再迁移） |
| **删除** | ht[0] 和 ht[1] 都查并删 |
| **查询** | 先查 ht[0]，没找到再查 ht[1] |
| **修改** | 同查询 |

→ rehash 不阻塞业务，单次操作只多迁移一个桶（O(1) 摊销）。

### 5.4 rehash 期间禁止哪些操作

- **BGSAVE/BGREWRITEAOF**：进行中不会触发新 rehash（避免内存翻倍）
- 但已经在 rehash 的不会停

---

## 六、典型应用代码

### 6.1 对象缓存（替代 JSON）

```java
// 写入
redis.hset("user:1", Map.of(
    "name", "Tom",
    "age",  "20",
    "balance", "100.50"
));
redis.expire("user:1", 3600);

// 单字段读（不用反序列化整个对象）
String name = redis.hget("user:1", "name");

// 单字段更新（不用重写整个对象）
redis.hset("user:1", "balance", "150.00");

// 原子加减
redis.hincrby("user:1", "balance_int", 100);
```

### 6.2 购物车

```java
String cartKey = "cart:" + userId;

// 加商品
redis.hincrby(cartKey, "goods:" + goodsId, 1);

// 改数量
redis.hset(cartKey, "goods:" + goodsId, "3");

// 删商品
redis.hdel(cartKey, "goods:" + goodsId);

// 查所有商品
Map<String, String> all = redis.hgetall(cartKey);

// 商品总数
Long count = redis.hlen(cartKey);
```

### 6.3 多维计数器

```java
// 用户的多种统计聚合到一个 Hash
redis.hincrby("stats:user:1", "view", 1);
redis.hincrby("stats:user:1", "like", 1);
redis.hincrby("stats:user:1", "share", 1);

// 一次取全部
Map<String, String> stats = redis.hgetall("stats:user:1");
```

比起每个指标一个 String key（`stats:user:1:view`、`stats:user:1:like`...）：
- **省内存**：小 Hash 用 listpack 紧凑存储
- **批量取**：一次 HGETALL 拿到所有指标

---

## 七、面试高频追问

### Q1：Hash 底层用什么数据结构？

两种编码：
- **小集合（≤128 字段且每个 ≤64 字节）**：listpack（7.0+）/ ziplist（之前）
- **大集合**：hashtable（哈希表 + 拉链法）

可以 `OBJECT ENCODING key` 查看。

### Q2：listpack 和 ziplist 有什么区别？为什么 7.0 要换？

**ziplist 的致命问题**：**连锁更新**（详见 [列表-List](./列表-List.md)）。
每个节点存"前一个节点的长度"，长度变化时可能触发整链级联更新，最坏 O(N²)。

**listpack 的改进**：
- 每个节点只存"自己的长度"，不存前一个的
- 反向遍历靠"末尾长度字段"（每个节点末尾再写一份自己的长度）
- 彻底解决连锁更新问题

### Q3：渐进式 rehash 为什么不一次做完？

一次性 rehash 会**阻塞主线程**，大 Hash 阻塞秒级。
渐进式把工作分摊到每次 CRUD + 定时任务里，每次只迁移一个桶，主线程不卡。

### Q4：rehash 期间内存会翻倍吗？

会。ht[0] 和 ht[1] 同时存在，理论上 1.5~2 倍内存。
**所以 BGSAVE/BGREWRITEAOF 期间会延迟扩容**——避免和 fork 的 COW 撞车，造成物理内存翻几倍。

### Q5：rehash 怎么影响 fork？

Redis 在 fork 子进程进行持久化时，主进程不希望大量页变化（COW 触发）。
rehash 会大量复制 dictEntry → 大量页变更 → COW 触发 → 物理内存暴增 → 可能 OOM。
所以子进程存在期间，**扩容阈值从 1 提到 5**，尽量推迟 rehash。

### Q6：什么时候选 Hash 而不是 String？

| 场景 | 选 |
| --- | --- |
| 频繁读写**单个字段** | Hash |
| 总是整对象访问 | String + JSON 也可 |
| 字段间需要原子计数（HINCRBY） | Hash |
| 字段非常多（>1 万）且总是全量读 | 反而 String + 序列化更好 |

### Q7：HGETALL 大 Hash 有什么问题？

- **网络阻塞**：一次返回所有字段，可能几 MB
- **主线程阻塞**：序列化所有字段是 O(N)
- **客户端 OOM**：返回数据太大撑爆客户端

**修复**：用 `HSCAN` 渐进式拉取。

### Q8：Hash 有大 key 怎么办？

判断标准：
- 字段数 > 1 万
- 总内存 > 10MB

**治理**：
- 拆分（按字段哈希散列到多个 key）
- 不要再用 HGETALL，改 HSCAN
- 删除用 HDEL 单字段，不要直接 DEL 整个 Hash（大 Hash 同步删除阻塞主线程，用 UNLINK）

### Q9：Hash 怎么实现分布式锁的可重入？

Redisson 用 Hash：
```
HSET lock:key {clientId} {重入次数}
HINCRBY 在加锁时 +1
HINCRBY 在解锁时 -1
归 0 才 DEL key
```

→ 详见 [分布式锁](./分布式锁.md)。

### Q10：Hash 的字段名/值上限多大？

- 字段名/值是 String，单个上限 512MB
- 但实际超过 64 字节会从 listpack 转 hashtable，影响内存效率
- **生产建议**：字段名短（缩写），值控制在 1KB 内

### Q11：HSCAN 能保证不漏不重吗？

- **不重**：保证（同一个 cursor 不会重复返回同一 entry）
- **可能漏**：如果 SCAN 期间 rehash 完成，新插入的可能漏（但通常可接受）
- **可能重复**：rehash 期间，少数情况下同一字段可能返回两次

→ 业务层做去重处理。

### Q12：Hash 的内存为什么比 Java HashMap 小那么多？

原因：
1. **小集合用 listpack**：纯紧凑数组，没有指针、桶、链表的开销
2. **大集合 hashtable** 也比 Java 紧凑（C 直接控制内存布局，Java 有对象头、对齐）
3. **没有泛型擦除和装箱**：Java HashMap 存数字要 Integer 包装

实测：1000 个简单字段，Redis Hash ~30KB，Java HashMap ~80KB。

---

## 八、生产真实踩坑

### Case 1：HGETALL 大 Hash 卡死主线程

某购物车记录用 Hash 存，单用户字段数 5 万 → HGETALL 一次 200ms → 业务雪崩。
**修复**：用 HSCAN 分批；或改成"按时间分片"的多个小 Hash。

### Case 2：直接 DEL 大 Hash 阻塞

清理购物车用了 `DEL cart:userId`，大购物车 DEL 阻塞主线程几百毫秒。
**修复**：改用 `UNLINK`（异步删除）；或先 HSCAN + HDEL 分批清理。

### Case 3：listpack 配置忘改

某线上业务发现 Hash 全是 hashtable 编码，内存比预期多 30%。原因：value 长度都超过 64 字节。
**修复**：把 64 字节字段拆成多个，或调高 `hash-max-listpack-value`（注意大集合性能下降）。

### Case 4：rehash 期间内存暴涨

大 Hash 扩容触发 rehash，期间内存从 5GB 涨到 9GB，触发 swap 性能骤降。
**修复**：调大机器内存或拆分 Hash；监控 `mem_fragmentation_ratio`。

### Case 5：用 Hash 当 SQL 表，字段数百万

把整张用户表（百万行）放一个 Hash，每个用户一个 field。结果：HGETALL 不可能、扩容卡死、备份恢复慢。
**修复**：每个用户独立一个 Hash key，按 ID hash 分片到 Cluster 不同节点。

### Case 6：HMSET 已废弃但还在用

代码里用 `HMSET`，新版本 Redis 报告已废弃但还能用，未来版本可能去掉。
**修复**：改用 `HSET key f1 v1 f2 v2`（4.0+ 支持批量）。

---

## 九、答题模板（60 秒话术）

> Hash 适合**对象缓存、购物车、计数器集合**——和 String 存 JSON 比，单字段访问效率高（HSET / HGET 不用反序列化整对象），但整对象读用 String 更省事。
>
> 底层在小集合时用 **listpack（7.0+）/ ziplist**（≤128 字段且每字段 ≤64 字节），超过转 **hashtable**。
>
> hashtable 扩容用**渐进式 rehash**——分摊到每次 CRUD 和定时任务，写新表读两表，避免一次性阻塞主线程；BGSAVE 期间会调高扩容阈值防止 COW 内存暴增。
>
> 生产坑是大 Hash 用 HGETALL 阻塞主线程——改 HSCAN 分批；删大 Hash 用 UNLINK 异步删替代 DEL。

→ 关联：[数据结构总览](./数据结构总览.md)、[字符串-String](./字符串-String.md)、[分布式锁](./分布式锁.md)、[工作流程](./工作流程.md)
