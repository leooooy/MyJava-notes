# 有序集合 ZSet

> Redis 最强大、最有特色的数据类型，没有之一。
> 面试核心：跳表（skiplist）原理、为什么不用红黑树、与 Set 的本质区别、排行榜/延时队列的实战。
> ZSet 题如果答不上跳表，基本就被打分到初级。

---

## 一、ZSet 是什么

**有序、唯一**的字符串集合，**每个元素绑定一个 score（浮点数权重）**，按 score 排序。

```
ZADD rank 100 "Tom"        # Tom 100 分
ZADD rank 95  "Jerry"      # Jerry 95 分
ZADD rank 120 "Spike"      # Spike 120 分

ZRANGE rank 0 -1 WITHSCORES
→ Jerry 95
  Tom   100
  Spike 120
```

**关键特性**：
- 元素唯一（同 Set）
- 按 score 自动排序
- score 可重复（score 相同时按字典序排）
- 支持范围查询（按分数 / 按位置 / 按字典序）

---

## 二、ZSet 适合做什么

| 场景 | 用法 | 命令 |
| --- | --- | --- |
| **排行榜** | score = 积分/点赞数 | `ZADD / ZREVRANGE` |
| **延时队列** | score = 执行时间戳 | `ZADD / ZRANGEBYSCORE` |
| **滑动窗口限流** | score = 请求时间戳 | `ZADD / ZREMRANGEBYSCORE / ZCARD` |
| **TopN 数据** | 维护 N 个最高分 | `ZADD / ZREMRANGEBYRANK` |
| **范围查询** | 商品按价格筛选 | `ZRANGEBYSCORE` |
| **优先级队列** | score = 优先级 | `ZPOPMIN / ZPOPMAX` |
| **多维度评分** | 综合排序（混合 score） | 业务计算 score |
| **附近的人** | 配合 GeoHash | Geo 命令底层是 ZSet |

> **没有 ZSet 不能轻松做的排序场景** —— 这是 Redis 的核心竞争力。

---

## 三、常用命令速查

```bash
# 写入
ZADD key score member                  # 添加
ZADD key NX score member               # 不存在才加
ZADD key XX score member               # 存在才更新
ZADD key GT score member               # score 大于现值才更新（6.2+）
ZADD key INCR score member             # 增量加（同 ZINCRBY）
ZINCRBY key 10 member                  # score += 10

# 删除
ZREM key member                        # 删元素
ZREMRANGEBYSCORE key 0 50              # 删 score 在 [0, 50] 的
ZREMRANGEBYRANK key 0 9                # 删排名 0-9 的
ZREMRANGEBYLEX key - [d                # 按字典序删

# 读取（按分数升序）
ZRANGE key 0 -1                        # 全部
ZRANGE key 0 9 WITHSCORES              # 前 10 名 + 分数
ZRANGE key 0 -1 REV                    # 6.2+ 反向（降序）
ZREVRANGE key 0 9 WITHSCORES           # 旧版降序

# 按分数范围
ZRANGEBYSCORE key 60 100               # score 在 [60, 100]
ZRANGEBYSCORE key (60 100              # 不含 60
ZRANGEBYSCORE key -inf +inf LIMIT 0 10 # 全范围 + 分页

# 按字典序（score 必须相同才有意义）
ZRANGEBYLEX key [a [c                  # 字典序在 [a, c]

# 排名查询
ZRANK key member                       # 升序排名（0 起）
ZREVRANK key member                    # 降序排名

# 统计
ZCARD key                              # 元素数
ZCOUNT key 60 100                      # score 在 [60, 100] 的数量
ZSCORE key member                      # 单元素分数
ZMSCORE key m1 m2                      # 6.2+ 批量

# 弹出（优先级队列用）
ZPOPMIN key [count]                    # 5.0+ 弹最低分
ZPOPMAX key [count]                    # 5.0+ 弹最高分
BZPOPMIN key timeout                   # 阻塞版

# 集合运算（同 Set）
ZUNIONSTORE dest 2 k1 k2 WEIGHTS 1 2   # 并集，k2 权重 *2
ZINTERSTORE dest 2 k1 k2
ZDIFFSTORE dest 2 k1 k2                # 6.2+
```

**复杂度**：
- ZADD/ZREM/ZSCORE：**O(log N)**
- ZRANGE/ZRANGEBYSCORE：O(log N + M)，M 是返回元素数
- ZCARD：O(1)
- ZRANK：O(log N)
- ZINCRBY：O(log N)

---

## 四、底层数据结构

ZSet **同时使用两种数据结构**：**dict**（字典）+ **skiplist**（跳表）。

### 4.1 编码切换

| Redis 版本 | 小集合 | 大集合 |
| --- | --- | --- |
| < 7.0 | `ziplist` | `skiplist + dict` |
| ≥ 7.0 | `listpack` | `skiplist + dict` |

**切换条件**：
```ini
zset-max-listpack-entries 128
zset-max-listpack-value 64
```

≤ 128 个元素且每个 ≤ 64 字节 → listpack，否则 skiplist + dict。

### 4.2 大集合：skiplist + dict 共存

为什么要两个数据结构？

| 场景 | 结构 | 复杂度 |
| --- | --- | --- |
| `ZSCORE member`（按 member 查 score） | **dict** | O(1) |
| `ZRANGE 0 9`（按排名查） | **skiplist** | O(log N + M) |
| `ZRANGEBYSCORE 60 100`（按分数范围查） | **skiplist** | O(log N + M) |

**设计哲学**：用空间换时间。
- 不用 skiplist 找 member → 太慢（要遍历）
- 不用 dict 排序 → 不可能（dict 无序）

→ 两个结构各负责一件事，元素同时存在两个结构里（指针引用，不重复存值）。

### 4.3 内存代价

skiplist + dict 比单一结构多约 30% 内存。但 Redis 的取舍是"性能 >> 内存"。

---

## 五、跳表（Skiplist）深度解析

### 5.1 跳表是什么

由 William Pugh 1990 年提出，**用空间换查找时间的有序链表变种**。

```
Level 4:  1 ───────────────────────────────→ 9
Level 3:  1 ───→ 4 ───────────────────────→ 9
Level 2:  1 ───→ 4 ───→ 6 ───────→ 8 ────→ 9
Level 1:  1 → 2 → 4 → 5 → 6 → 7 → 8 → 9
```

**核心思路**：
- 底层是一个有序链表（跳表的"地基"）
- 上层是稀疏索引（逐层减少节点）
- 查找时从最高层开始，能跳过去就跳过去
- 跳不过去就降一层
- 最坏情况降到底层

### 5.2 查找过程示例

查找 7：
```
Level 4: 从 1 开始 → 1 → 9 (太大) → 降级
Level 3: 从 1 → 4 → 9 (太大) → 降级
Level 2: 从 4 → 6 → 8 (太大) → 降级
Level 1: 从 6 → 7 ✓
```

平均比较次数 O(log N)，最坏 O(N)（极端情况层数都集中在底层）。

### 5.3 跳表的关键问题：节点该有几层

**随机决定**！每次插入时随机生成层数：
```c
// Redis 实现
int randomLevel() {
    int level = 1;
    while ((random() & 0xFFFF) < (ZSKIPLIST_P * 0xFFFF)) {
        level++;
    }
    return min(level, ZSKIPLIST_MAXLEVEL);
}
// ZSKIPLIST_P = 0.25
// ZSKIPLIST_MAXLEVEL = 32（5.0+ 是 64）
```

每层节点出现概率：
- Level 1：100%
- Level 2：25%
- Level 3：6.25%
- ...

**期望层数 = 1 / (1 - p) = 1.33**，所以平均空间开销很小。

### 5.4 Redis skiplist 节点结构

```c
typedef struct zskiplistNode {
    sds ele;                    // 成员对象
    double score;               // 分数
    struct zskiplistNode *backward;    // 后退指针（仅底层有）
    struct zskiplistLevel {
        struct zskiplistNode *forward;    // 前进指针
        unsigned long span;               // 跨度（用于排名计算）
    } level[];                  // 柔性数组，length = 该节点的层数
} zskiplistNode;

typedef struct zskiplist {
    zskiplistNode *header, *tail;
    unsigned long length;
    int level;                  // 当前最高层数
} zskiplist;
```

**关键点**：
- `score` 和 `ele` 都存在节点里（dict 也存了 ele 一份）
- `level[]` 柔性数组，每层一个 `forward + span`
- `span`（跨度）：当前节点到 `forward` 节点之间跨了多少个底层节点
- `backward`：底层链表的反向指针，用于反向遍历

### 5.5 排名（rank）怎么算

跳表本身不维护"我是第几"，但通过 `span` 字段可以算：

```
查找节点时，累加路径上所有"下降前"的 span
最终累加值就是该节点的排名
```

例：查找元素 X 经过的路径：
```
Level 3: span=4 → 跳到 X 的前一个 → +4
Level 2: span=2 → 跳到 X 的前一个 → +2
Level 1: span=1 → 跳到 X → +1
排名 = 4 + 2 + 1 = 7
```

→ 这就是为什么 ZRANK 是 **O(log N)**。

---

## 六、为什么用跳表而不是红黑树？

经典面试题。Redis 作者 antirez 给出过几个理由：

### 1. 实现简单

红黑树的旋转、变色规则极其复杂，bug 风险大。
跳表只需要随机 + 链表操作，实现 200 行 vs 红黑树 1000+ 行。

### 2. 范围查询更高效

ZSet 大量场景是**范围查询**（ZRANGE / ZRANGEBYSCORE）：
- **跳表**：定位到起点后，沿底层链表顺序走 O(M)
- **红黑树**：要中序遍历，频繁回退到父节点，cache 不友好

### 3. 内存占用相当（跳表略多）

虽然跳表每个节点平均 1.33 个指针，红黑树固定 2 个 + 父指针，但跳表按 P=0.25 时实际指针数 ≈ 1.33 × N，**和红黑树差不多甚至略多**。**这一项跳表稍微吃亏，但其他优势足够**。

### 4. 调试方便

跳表是顺序的，打印出来一目了然。红黑树调试时要看树形结构。

### 5. 并发友好（潜在）

跳表的并发实现比红黑树容易（每个节点局部修改，不需要全局重平衡）。
虽然 Redis 单线程没用上这个优势，但开源社区有用跳表做并发数据结构的。

→ **总结**：跳表 = 简单 + 范围查询快 + 实现舒服。Redis 选它正确。

---

## 七、ZSet vs HashMap+TreeMap vs PriorityQueue

Java 同学经常问的对比：

| 方案 | 查 score O() | 排名 O() | 范围查询 O() | 备注 |
| --- | --- | --- | --- | --- |
| Redis ZSet | O(1) | O(log N) | O(log N + M) | dict + skiplist |
| Java TreeMap | O(log N) | 不支持 | O(log N + M) | 红黑树 |
| Java HashMap+TreeMap | O(1) + O(log N) | 不支持 | O(log N + M) | 双结构 |
| PriorityQueue | O(1) 取 min | 不支持 | 不支持 | 堆 |

ZSet 的"按 member 查 score O(1)" 是它独有的优势。

---

## 八、典型应用代码

### 8.1 排行榜（最经典）

```java
// 玩家得分（每次得分时更新）
redis.zincrby("rank:game:1001", score, "playerId:1");

// Top 10
List<Tuple<String, Double>> top10 = redis.zrevrangeWithScores("rank:game:1001", 0, 9);

// 我的排名（从 0 开始）
Long myRank = redis.zrevrank("rank:game:1001", "playerId:1");

// 我和 Top 10 之间还差多少分
Double topScore = redis.zscore("rank:game:1001", topPlayerId);
Double myScore = redis.zscore("rank:game:1001", "playerId:1");
double gap = topScore - myScore;

// 我前后 5 名（看竞争对手）
Long myRank = redis.zrevrank(...);
List around = redis.zrevrange("rank:game:1001", myRank - 5, myRank + 5);
```

### 8.2 延时队列

```java
// 生产者：30 秒后执行
long executeAt = System.currentTimeMillis() + 30_000;
redis.zadd("delay:queue", executeAt, JSON.toJSONString(task));

// 消费者：定时扫描已到期任务
while (true) {
    long now = System.currentTimeMillis();
    Set<String> ready = redis.zrangeByScore("delay:queue", 0, now, 0, 10);
    
    for (String task : ready) {
        // 用 ZREM 抢占（多消费者下保证唯一执行）
        if (redis.zrem("delay:queue", task) == 1) {
            executor.submit(() -> process(task));
        }
    }
    Thread.sleep(1000);
}
```

**改进版（Lua 原子）**：
```lua
local ready = redis.call('ZRANGEBYSCORE', KEYS[1], 0, ARGV[1], 'LIMIT', 0, 10)
if #ready > 0 then
    redis.call('ZREM', KEYS[1], unpack(ready))
end
return ready
```

→ 比 List 当 MQ 强（支持延时），但弱于专业 MQ（无 ACK）。

### 8.3 滑动窗口限流

```java
// 1 分钟内最多 100 次请求
String key = "limit:" + userId;
long now = System.currentTimeMillis();

// Lua 脚本保证原子
String lua = """
  redis.call('ZREMRANGEBYSCORE', KEYS[1], 0, ARGV[1])  -- 清理 1 分钟前的
  local count = redis.call('ZCARD', KEYS[1])
  if count >= tonumber(ARGV[3]) then
    return 0
  end
  redis.call('ZADD', KEYS[1], ARGV[2], ARGV[2])
  redis.call('EXPIRE', KEYS[1], 60)
  return 1
""";

long allow = redis.eval(lua, key, now - 60000, now, 100);
if (allow == 0) throw new RateLimitException();
```

### 8.4 优先级队列

```java
// 优先级越小越先执行
redis.zadd("priority:queue", 1, "highTask");
redis.zadd("priority:queue", 5, "midTask");
redis.zadd("priority:queue", 10, "lowTask");

// 弹出最低优先级（最先执行）
List<Tuple<String, Double>> task = redis.bzpopmin(0, "priority:queue");
```

### 8.5 用户最近浏览记录（去重 + 时间排序）

```java
// 浏览了商品（重复浏览覆盖）
redis.zadd("history:user:1", System.currentTimeMillis(), "goods:1001");

// 最近 20 条
List recent = redis.zrevrange("history:user:1", 0, 19);

// 限制最多保留 100 条
redis.zremrangeByRank("history:user:1", 0, -101);   // 删除 0 到 倒数 101
```

---

## 九、面试高频追问

### Q1：ZSet 底层用什么？

两种编码：
- **小集合**：listpack（7.0+）/ ziplist
- **大集合**：**dict + skiplist**（同时使用）

### Q2：为什么 ZSet 大集合要用两个数据结构？

- **dict** 用于 O(1) 通过 member 查 score（`ZSCORE`）
- **skiplist** 用于 O(log N) 范围查询和排名（`ZRANGE`、`ZRANGEBYSCORE`、`ZRANK`）

各负其责，元素值在 dict 和 skiplist 节点之间共享指针。

### Q3：跳表是什么？怎么实现 O(log N)？

有序链表 + 多层稀疏索引。从最高层开始查，跳过尽可能多的元素，跳不过就降级。
平均 O(log N)，最坏 O(N)。

### Q4：每个跳表节点有几层？

随机决定。Redis 实现：
```
while (random < 0.25):
    level += 1
return min(level, 32)
```
P = 0.25，期望层数 1.33。

### Q5：为什么跳表用 P=0.25 而不是 0.5？

P=0.5 时层数期望 2，每个节点平均 2 个指针，内存翻倍。
P=0.25 时期望 1.33，**节省内存的同时性能损失很小**（log 1/0.25 = 2 倍，仍是 O(log N)）。

### Q6：为什么不用 B+ 树？

B+ 树是**面向磁盘**的（节点大、减少 IO），Redis 全内存不需要这个特性。
B+ 树范围查询要顺序读叶子节点链表，跳表已经天然有序链表，效果差不多。
B+ 树实现远比跳表复杂。

### Q7：为什么不用红黑树？

跳表的几个优势（简单、范围查询快、调试方便）已经在第六节讲过。
另外：**Java TreeMap 用红黑树是因为 Java 标准库需要"通用"，且没有跳表内置实现**。Redis 是专门优化的有序结构。

### Q8：ZRANK 怎么 O(log N) 算出排名？

跳表节点有 `span` 字段（跨度）。查找路径上每次"前进"，累加 span。到达目标节点时，累加值就是排名。
没有 span 字段时只能从头数，O(N)。

### Q9：ZSet 元素去重靠什么？

dict（哈希表）保证 member 唯一。
ZADD 时先查 dict：
- 没有 → 在 dict 和 skiplist 各加一份
- 有 → 如果 score 不同，更新（在 skiplist 里删除老的、插入新的）

### Q10：score 相同的多个元素怎么排序？

按 **member 字典序**排序。
ZRANGEBYLEX 命令支持按字典序范围查询，前提是 score 全相同。

### Q11：能存多大的 ZSet？

理论上 2^32 - 1 个元素。
实际：单 ZSet 超过 100 万元素就要警惕（内存、迁移、序列化都受影响）。

### Q12：怎么查"我和我前后 10 名"？

```
myRank = ZREVRANK key me
ZREVRANGE key (myRank - 10) (myRank + 10) WITHSCORES
```

注意 myRank < 10 时下界用 0。

### Q13：延时队列用 ZSet vs RocketMQ？

| 维度 | ZSet | RocketMQ |
| --- | --- | --- |
| 实现 | 自己写 | 开箱即用 |
| 时间精度 | 秒级（取决于扫描频率） | 18 个固定级别 |
| ACK 机制 | 自己做 | 内置 |
| 持久化 | RDB/AOF | 完整存储 |
| 适合规模 | 万级 | 亿级 |

→ 量小用 ZSet 灵活，量大用专业 MQ。

### Q14：为什么 ZSet 不是 dict + 红黑树？

回到 Q7：跳表实现简单 + 范围查询友好 + 排名 O(log N)（红黑树排名要 O(N) 或额外维护）。
此外，跳表写起来 200 行，红黑树 1000+ 行——这是真实的工程考量。

### Q15：ZSet 怎么实现"附近的人"？

Geo 命令底层就是 ZSet：
- 用 GeoHash 算法把经纬度编码成 52 位整数
- 这个整数作为 score 存进 ZSet
- 范围查询附近的人 → ZSet 范围查询

---

## 十、生产真实踩坑

### Case 1：排行榜全量 ZRANGE 0 -1 卡死

某游戏排行榜接口 `ZRANGE 0 -1`，1000 万玩家全拉 → 一次返回 100MB → 主线程卡 500ms → 业务雪崩。
**修复**：分页 `ZRANGE 0 99` 拉前 100；用户排名拉自己周边的就行。

### Case 2：ZADD 大批量 score 相同导致跳表退化

某场景 score 全是 0（误用 ZSet 当 Set），元素按字典序在 skiplist 里排成一长串，ZRANGEBYLEX 性能 O(N)。
**修复**：score 用业务有意义的值（如时间戳）；纯去重用 Set。

### Case 3：延时队列扫描间隔大导致延迟

定时任务每 5 秒扫一次 → 任务实际延迟 0~5 秒。
**修复**：缩短扫描间隔（每秒）；或用阻塞 BZPOPMIN（但要会算"还剩多少时间"）。

### Case 4：延时队列多消费者重复执行

多个消费者 ZRANGEBYSCORE 拉到相同任务 → 都 process 了。
**修复**：用 ZREM 抢占（返回 1 才执行）；或 Lua 脚本原子化。

### Case 5：滑动窗口限流 ZSet 内存暴涨

每个用户一个 ZSet 存请求时间戳，但 ZREMRANGEBYSCORE 没及时清理 → 大量过期数据残留。
**修复**：每次操作前先 ZREMRANGEBYSCORE 清理；给整个 key 设短 TTL（比窗口稍长）。

### Case 6：ZSet 和 dict 不一致

直接用 DEBUG 命令改了 skiplist 内部数据，dict 没同步 → ZSCORE 和 ZRANGE 结果不一致。
**修复**：永远不要直接动数据结构内部，用 ZADD/ZREM 等命令。

### Case 7：listpack 转 skiplist 的阈值踩坑

某 ZSet 设了 `zset-max-listpack-entries 1024`（默认 128），接近 1024 时频繁转换 skiplist + 转回失败（只升不降）→ 内存效率不如预期。
**修复**：用默认值；或确认能容忍 listpack 在大集合下的 O(N) 性能。

---

## 十一、答题模板（60 秒话术）

> ZSet 是**排行榜、延时队列、滑动窗口、优先级队列、附近的人**的标配。底层小集合用 **listpack**，大集合用 **dict + skiplist 双结构并存**——dict 保证 O(1) 按 member 查 score，skiplist 保证 O(log N) 范围查询和按 score 排序。
>
> **跳表**原理：有序链表 + 多层稀疏索引，每层节点以 P=0.25 概率出现，期望层数 1.33。比红黑树**实现简单、范围查询友好、调试方便**——这是 Redis 弃红黑树用跳表的核心理由。
>
> **排行榜**实战：ZINCRBY 累计、ZREVRANGE 取榜、ZREVRANK 查排名（O(log N)，靠 skiplist span 字段）。**延时队列**：score = 执行时间戳，定时扫到期任务，ZREM 原子抢占防止重复消费。

→ 关联：[数据结构总览](./数据结构总览.md)、[集合-Set](./集合-Set.md)、[哈希-Hash](./哈希-Hash.md)、[列表-List](./列表-List.md)、[限流算法](../Microservice/限流算法.md)
