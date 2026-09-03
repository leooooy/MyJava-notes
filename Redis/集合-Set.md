# 集合 Set

> 无序、不重复的字符串集合（类似 Java 的 `HashSet<String>`）。
> 面试核心：底层三态编码（intset/listpack/hashtable）+ 集合运算的应用场景 + 与 ZSet/Bitmap 的对比。

---

## 一、Set 适合做什么

| 场景 | 实现 | 命令 |
| --- | --- | --- |
| **去重** | 集合天然不重复 | `SADD` |
| **抽奖** | 随机抽取不重复用户 | `SRANDMEMBER` / `SPOP` |
| **点赞/收藏** | 用户 ID 集合 | `SADD / SISMEMBER / SCARD` |
| **标签** | 文章/商品的标签集合 | `SADD / SMEMBERS` |
| **共同好友** | 集合交集 | `SINTER` |
| **可能认识的人** | 二度关系 = 我朋友的朋友 - 我朋友 | `SDIFF` |
| **大数据去重统计** | 1000 万 UV 用 Set 太贵 | 改用 HyperLogLog |
| **黑名单/白名单** | 快速判断是否在 | `SISMEMBER` |

> 核心优势：**集合运算（交并差）原生支持**，数据库 JOIN 实现不出来这种简洁。

---

## 二、常用命令速查

```bash
# 基础
SADD key m1 m2 m3              # 添加（重复忽略）
SREM key m1                    # 删除
SISMEMBER key m1               # 是否存在（O(1)）
SMISMEMBER key m1 m2           # 6.2+ 批量判断
SMEMBERS key                   # 所有元素（⚠️ 大集合慎用）
SCARD key                      # 元素个数
SPOP key [count]               # 随机弹出（删除）
SRANDMEMBER key [count]        # 随机取（不删除）
SSCAN key 0 MATCH * COUNT 100  # 渐进式遍历

# 集合运算
SINTER k1 k2 k3                # 交集
SUNION k1 k2                   # 并集
SDIFF k1 k2                    # 差集（k1 有 k2 没有）

# 运算 + 存储（不返回结果）
SINTERSTORE dest k1 k2         # 交集存入 dest
SUNIONSTORE dest k1 k2
SDIFFSTORE dest k1 k2

# 移动元素
SMOVE src dst member           # 把 member 从 src 移到 dst（原子）
```

**复杂度**：
- SADD/SREM/SISMEMBER：O(1)（hashtable 时）/ O(N)（intset/listpack 时）
- SMEMBERS：O(N)
- SINTER：O(N×M)（最小集合的元素 N，集合数 M）
- SUNION：O(总元素数)

---

## 三、底层编码（三态）

| Redis 版本 | 全整数小集合 | 非整数小集合 | 大集合 |
| --- | --- | --- | --- |
| < 7.2 | `intset` | `hashtable` | `hashtable` |
| **≥ 7.2** | `intset` | `listpack` | `hashtable` |

> 7.2 引入 listpack 编码 Set，让"非整数但小集合"也能用紧凑结构（之前直接上 hashtable）。

### 3.1 编码切换条件

```ini
set-max-intset-entries 512        # intset 最大元素数
set-max-listpack-entries 128      # listpack 最大元素数（7.2+）
set-max-listpack-value 64         # listpack 单元素最大字节数（7.2+）
```

**切换路径**：
```
全整数 + ≤512 个       → intset
非整数 + 小且短         → listpack（7.2+）
不满足上述              → hashtable
```

**只升不降**：一旦升级到 hashtable，删元素也不再回去。

---

## 四、底层数据结构

### 4.1 intset（整数集合）

紧凑、有序、可二分查找的整数数组。

```c
typedef struct intset {
    uint32_t encoding;      // 元素编码（int16/int32/int64）
    uint32_t length;        // 元素个数
    int8_t contents[];      // 柔性数组，实际存储
} intset;
```

**特点**：
- 元素**有序**（升序），便于二分查找 O(log N)
- 元素**统一编码**：所有元素都用最大那个的编码长度（如插入了一个 int64，所有元素都升级）
- **只升级不降级**：插入大整数后，小整数也按大编码存

### 4.2 intset 的升级（关键）

```
原: encoding = INT16, [10, 20, 30]
插入 99999（需要 INT32）:
  1. 重新分配数组（每个槽 4 字节而不是 2 字节）
  2. 倒序拷贝（避免覆盖）
  3. 99999 放到末尾（如果是最大值）
  4. encoding 更新为 INT32
```

**为什么倒序**？防止前面元素覆盖还未拷贝的后面元素。

**为什么只升不降**？降级判断成本高（要扫全表确认没有大值），不值得。

### 4.3 listpack（小非整数集合，7.2+）

详见 [列表-List.md - listpack](./列表-List.md#34-listpack-70-终极方案)。
紧凑数组，每个元素带自描述长度，无连锁更新。

### 4.4 hashtable

详见 [哈希-Hash.md - hashtable](./哈希-Hash.md#四hashtable-数据结构详解)。
Set 的 hashtable 实现就是把 value 设为 NULL 的字典。
查询/插入/删除 O(1)。

---

## 五、典型应用代码

### 5.1 抽奖（不重复中奖）

```java
// 用户参与抽奖
redis.sadd("lottery:1001:users", userId);

// 抽 10 个中奖者（不重复）
List<String> winners = redis.spop("lottery:1001:users", 10);
```

`SPOP` 删除取出，保证不重复中奖。
`SRANDMEMBER` 不删除，可重复抽（每次都从全量中随机）。

### 5.2 点赞 / 收藏

```java
// 点赞
redis.sadd("article:1001:likes", userId);

// 取消
redis.srem("article:1001:likes", userId);

// 是否点过赞
redis.sismember("article:1001:likes", userId);

// 点赞数
redis.scard("article:1001:likes");

// 谁点了赞
redis.smembers("article:1001:likes");        // 小集合
redis.sscan("article:1001:likes", "0");      // 大集合分页
```

### 5.3 共同关注（社交）

```java
// 我关注的
redis.sadd("follow:1001", "2002", "2003", "2004");
// 你关注的
redis.sadd("follow:2001", "2002", "2003", "2005");

// 共同关注
Set<String> common = redis.sinter("follow:1001", "follow:2001");
// → [2002, 2003]

// 你关注的我没关注的（推荐"可能认识的人"）
Set<String> recommend = redis.sdiff("follow:2001", "follow:1001");
// → [2005]
```

### 5.4 标签系统

```java
// 文章打标签
redis.sadd("article:1001:tags", "Java", "Redis", "面试");

// 找标签为 Java 的所有文章
redis.sadd("tag:Java:articles", "1001", "1002", "1003");

// 同时有 Java 和 Redis 标签的文章
Set<String> result = redis.sinter("tag:Java:articles", "tag:Redis:articles");
```

### 5.5 黑名单 / 白名单

```java
// IP 黑名单
redis.sadd("blacklist:ip", "1.2.3.4");

// 拦截
if (redis.sismember("blacklist:ip", clientIp)) {
    return Result.fail("您的 IP 已被封禁");
}
```

> 大规模黑名单（千万级）用 **布隆过滤器**，空间效率高得多。详见 [布隆过滤器](./布隆过滤器.md)。

### 5.6 SINTERSTORE 优化大集合运算

```java
// 实时计算共同关注（每次都算）
Set<String> common = redis.sinter("follow:A", "follow:B");

// 缓存计算结果（5 分钟有效）
redis.sinterstore("common:A:B", "follow:A", "follow:B");
redis.expire("common:A:B", 300);
// 后续直接 SMEMBERS common:A:B
```

---

## 六、Set vs ZSet vs Bitmap vs HyperLogLog

经常被对比，回答时要能说清取舍：

| 场景 | Set | ZSet | Bitmap | HLL |
| --- | --- | --- | --- | --- |
| **去重** | ✓ | ✓ | △（ID 必须能映射成位） | ✓（近似） |
| **是否存在** | O(1) | O(log N) | O(1) | × |
| **排序** | × | ✓ | × | × |
| **基数统计** | SCARD O(1) | ZCARD O(1) | BITCOUNT O(N) | PFCOUNT O(1) 近似 |
| **集合运算** | ✓ | × | BITOP | PFMERGE |
| **内存（1 亿个 UID）** | ~2GB | ~3GB | 12.5MB | 12KB |
| **数据精确性** | 精确 | 精确 | 精确 | 误差 0.81% |

**选择规则**：
- 数据量小、要精确、要查具体元素 → **Set**
- 要排序（如排行榜）→ **ZSet**
- 用户 ID 是连续整数 + 大量布尔状态 → **Bitmap**
- 海量去重计数 + 精度可接受 → **HyperLogLog**

---

## 七、面试高频追问

### Q1：Set 底层用什么数据结构？

三种编码：
- **intset**：全整数 + 元素 ≤ 512 个
- **listpack**：7.2+，非整数小集合
- **hashtable**：大集合或值很长

可以 `OBJECT ENCODING key` 查看。

### Q2：intset 怎么实现 O(log N) 查找？

intset 是**有序整数数组**，插入时保持有序，查找用**二分查找**。
但插入时要插中间位置，O(N)。所以 intset 只适合**读多写少 + 小集合**。

### Q3：intset 为什么只升级不降级？

降级判断成本：要扫全集合确认没有大数 → O(N)。
而升级是被动触发（插入时自然发现）→ O(1) 判断。
权衡之下，工程上不实现降级。

### Q4：Set 的 SMEMBERS 大集合危险吗？

危险。返回所有元素：
- 网络传输：100 万元素几十 MB
- 主线程序列化 O(N)，期间所有命令排队
- 客户端可能 OOM

**修复**：用 `SSCAN`（渐进式分批）。

### Q5：SPOP 和 SRANDMEMBER 区别？

- **SPOP**：随机弹出 + 删除（不可重复）
- **SRANDMEMBER**：随机取，**不删除**（可能重复）

抽奖一次性抽 N 名 → SPOP；用户每次刷新看推荐 → SRANDMEMBER。

### Q6：SINTER 性能怎么保证？

Redis 内部优化：**先取最小的集合**，遍历最小集合，对每个元素检查是否在其他集合中。
复杂度 O(N×M)，N 是最小集合元素数，M 是集合数。
**所以集合大小相差悬殊时，SINTER 性能反而好**。

### Q7：SINTER 大集合卡主线程怎么办？

- 用 `SINTERSTORE` 异步存储结果，避免一次返回大量数据
- 用 `SINTERCARD`（7.0+）：只返回交集大小，不返回元素
- 业务上限制集合大小或预计算

### Q8：Set 怎么实现"批量判断元素是否存在"？

6.2 之前：循环 SISMEMBER（多次往返）或 Lua 脚本。
6.2+：`SMISMEMBER key m1 m2 m3`，一次返回多个判断结果。

### Q9：Set 能存重复元素吗？

不能。`SADD key v` 重复添加时返回 0（表示没新增），元素仍唯一。

### Q10：怎么判断两个用户的"重叠粉丝"？

```
SINTER followers:A followers:B
```

如果集合很大（千万），用 `SINTERSTORE` 缓存结果，避免每次实时计算。

### Q11：Set 适合做布隆过滤器替代吗？

不适合。1 亿 UID 的 Set 大概 2GB；布隆过滤器只要 100MB。
Set 的优势是"精确"，布隆过滤器是"内存极省 + 误判可接受"。

### Q12：抽奖用 Set 怎么保证公平？

- `SADD` 加入参与者
- `SPOP` 随机弹出（Redis 内部用 hash 函数 + 取模）

但 SPOP 不能严格保证"概率均等"——hashtable 的随机性受桶分布影响。
真要严格公平：业务侧用"奖池数组 + 索引随机"。

---

## 八、生产真实踩坑

### Case 1：SMEMBERS 大集合卡死

排行榜接口图省事 SMEMBERS 拉百万用户 → 一次返回 50MB → 主线程卡 200ms。
**修复**：SSCAN 分批；或 ZSet 替代（直接拿 TopN）。

### Case 2：抽奖用 SRANDMEMBER 导致重复中奖

代码用了 `SRANDMEMBER count 10`，没删元素 → 同一用户被多次抽中。
**修复**：用 `SPOP count 10`，弹出即删除。

### Case 3：实时计算共同关注被拖垮

社交场景"共同关注"接口直接 SINTER 两个百万级集合，单次 50ms+。
**修复**：
- 异步预计算 + 缓存（SINTERSTORE）
- 限制只算 Top 100 个共同关注

### Case 4：Set 大 key 导致迁移困难

某热门话题的"参与用户"Set 涨到 500 万，Cluster 迁移这个 slot 时卡 20 秒。
**修复**：拆分（按时间窗口或哈希散列）；UNLINK 异步删除。

### Case 5：intset 升级时阻塞

某 Set 一直是 intset 编码，某次插入一个超大数字触发整体升级（1000 万元素全部转 INT64），主线程阻塞 100ms+。
**修复**：避免全整数集合超过 512 元素（超了主动转 hashtable）。

### Case 6：黑名单 Set 替代布隆过滤器

千万级 IP 黑名单全用 Set 存，内存几个 GB，查询慢。
**修复**：换布隆过滤器，内存节省 95%+，查询 O(1)。

---

## 九、答题模板（60 秒话术）

> Set 用于**去重、抽奖、点赞、标签、共同关注（集合运算）**。三种编码：**intset**（全整数且 ≤512 元素，有序数组二分查找 O(log N)）、**listpack**（7.2+ 非整数小集合）、**hashtable**（大集合，O(1)）。intset 内统一编码、只升不降。
>
> 集合运算 SINTER / SUNION / SDIFF 在大集合上是阻塞操作，要小心。
>
> 替代选择：海量去重计数用 **HyperLogLog**（12KB 算 2^64 基数），布尔状态用 **Bitmap**，要排序用 **ZSet**。
>
> 大 Set 治理：SSCAN 替 SMEMBERS、UNLINK 替 DEL，必要时按业务维度拆分。

→ 关联：[数据结构总览](./数据结构总览.md)、[有序集合-ZSet](./有序集合-ZSet.md)、[哈希-Hash](./哈希-Hash.md)、[布隆过滤器](./布隆过滤器.md)
