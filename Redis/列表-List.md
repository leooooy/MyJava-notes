# 列表 List

> 双端可读写、可阻塞，是 Redis 里**最适合做消息队列**的基础类型。
> 面试核心：底层结构演进（ziplist → quicklist → listpack）+ ziplist 的连锁更新缺陷 + 与 Stream 的对比。

---

## 一、List 适合做什么

| 场景 | 实现 | 命令 |
| --- | --- | --- |
| **栈（LIFO）** | LPUSH + LPOP | 同端进出 |
| **队列（FIFO）** | LPUSH + RPOP | 异端进出 |
| **阻塞队列** | LPUSH + BRPOP | 简易 MQ |
| **消息流** | LPUSH + LRANGE | 微博/朋友圈时间线 |
| **最新 N 条记录** | LPUSH + LTRIM | 滚动日志 |
| **任务队列** | LPUSH + BRPOPLPUSH | 工作队列（带回执） |

> List 不是真正的"列表"，而是**双向链表**思路的实现。
> 注意：5.0+ 后 Redis 出了 **Stream**，专门做消息队列，比 List 强很多。**List 当 MQ 是临时方案**。

---

## 二、常用命令速查

```bash
# 写入（左 = 表头，右 = 表尾）
LPUSH key v1 v2 v3              # 从左插入（v3 → v2 → v1 顺序进表头）
RPUSH key v1 v2                 # 从右插入

# 读取
LPOP key                        # 弹出表头
RPOP key                        # 弹出表尾
LPOP key 5                      # 6.2+ 一次弹 5 个

# 阻塞读
BLPOP key timeout               # 没数据时阻塞 timeout 秒
BRPOP key timeout
BLMOVE src dst LEFT RIGHT to    # 阻塞从 src 弹 + 推到 dst

# 范围 / 索引
LRANGE key 0 -1                 # 全部（⚠️ 大 List 慎用）
LRANGE key 0 9                  # 前 10 个
LINDEX key 0                    # 索引读
LSET key 0 newvalue             # 索引写

# 修剪
LTRIM key 0 99                  # 只保留前 100 个

# 删除
LREM key 2 value                # 从头删除 2 个匹配 value 的
LREM key -2 value               # 从尾删除 2 个

# 元信息
LLEN key                        # 长度
LPOS key value                  # 6.0+ 找元素位置
```

**复杂度**：
- LPUSH/RPUSH/LPOP/RPOP/LLEN：**O(1)**
- LINDEX/LRANGE/LREM：O(N)（List 是链表，索引访问慢）
- LSET 最坏 O(N)

---

## 三、底层数据结构演进史（重要）

| Redis 版本 | 实现 |
| --- | --- |
| < 3.2 | 小 List 用 `ziplist`，大 List 用 `linkedlist` |
| 3.2 ~ 7.0 | 全部用 `quicklist`（quicklist 节点内部是 `ziplist`） |
| **≥ 7.0** | 全部用 `quicklist`（节点内部换成 **`listpack`**，替代 ziplist） |

→ 这是面试官经常追问的演进路径。

### 3.1 ziplist（压缩列表，旧版）

紧凑的连续内存数组，节省内存。

```
[zlbytes][zltail][zllen][entry1][entry2]...[entryN][zlend]
```

| 字段 | 字节 | 含义 |
| --- | --- | --- |
| zlbytes | 4 | 总字节数 |
| zltail | 4 | 末尾元素的偏移（用于反向遍历起点） |
| zllen | 2 | 元素数量（≥65535 时要遍历） |
| entry | 变长 | 节点 |
| zlend | 1 | 结束符 0xFF |

每个 entry 三个字段：`prevlen + encoding + content`。
- **prevlen**：前一个 entry 的长度（**1 字节或 5 字节**）
- **encoding**：当前 entry 的类型（字节数组 / 整数）
- **content**：实际值

> 这种"链式记录长度"是 ziplist 的核心，但也是它的灾难之源 → 连锁更新。

### 3.2 ziplist 的连锁更新（致命缺陷）

`prevlen` 字段是变长的：
- 前一个节点 < 254 字节 → prevlen 用 **1 字节**
- 前一个节点 ≥ 254 字节 → prevlen 用 **5 字节**

**问题**：
```
原本: [e0][e1(252字节)][e2][e3]...
e1 之后插入了一个 300 字节的元素 e1.5
                 ↓
[e0][e1(252)][e1.5(300)][e2][e3]...
                          ↑
                e2 的 prevlen 要从 1 字节升到 5 字节
                e2 长度变化 → 可能让 e3 的 prevlen 也升级
                e3 长度变化 → 可能让 e4 也升级
                ...
```

**最坏情况**：每个节点都触发 prevlen 升级 → 每次升级要 realloc + 数据迁移 → **O(N²) 复杂度**！

### 3.3 quicklist（3.2+）

为了解决 ziplist 单链的"大集合性能差"和"连锁更新"，用**双向链表 + 多段 ziplist** 组合：

```
[head] ←→ [ziplist1] ←→ [ziplist2] ←→ [ziplist3] ←→ [tail]
              │              │              │
              └─ N 个 entry  └─ N 个 entry  └─ N 个 entry
```

**节点结构**：
```c
typedef struct quicklistNode {
    struct quicklistNode *prev, *next;
    unsigned char *zl;         // 7.0+ 是 listpack，之前是 ziplist
    unsigned int sz;           // 字节数
    unsigned int count;        // 元素数
    // ...
} quicklistNode;
```

**优点**：
- 仅在节点内部用 ziplist/listpack（紧凑）
- 节点之间用链表（避免单 ziplist 过大时的连锁更新雪崩）
- 支持节点级别压缩（LZF）：中间不常访问的节点压缩

**关键配置**：
```ini
list-max-listpack-size -2       # 单节点 8KB（推荐）
list-compress-depth 0           # 节点压缩深度（0=不压缩）
```

`list-max-listpack-size` 取值：
- 正数：限制元素数（如 128）
- 负数：限制字节数（-1=4KB, -2=8KB, -3=16KB, -4=32KB, -5=64KB）

### 3.4 listpack（7.0+ 终极方案）

ziplist 的连锁更新问题用 listpack 解决：**每个节点不再存 prevlen，只存自己的长度**。

```
[total_bytes][num_elements][entry1][entry2]...[entryN][end]
```

每个 entry：`encoding + content + length-of-self`

**反向遍历**：通过末尾的 `length-of-self` 字段，能算出当前节点的起点。

```
找前一节点 = 当前位置 - length-of-self - encoding 长度
```

→ 没有 prevlen，**完全消除连锁更新**。

### 3.5 listpack vs ziplist 对比

| 维度 | ziplist | listpack |
| --- | --- | --- |
| 反向遍历 | 通过 prevlen | 通过末尾 length-of-self |
| 长度字段 | 链式（前节点的） | 自描述（自己的） |
| 连锁更新 | **有，最坏 O(N²)** | **无** |
| 复杂度 | O(N²) 最坏 | 严格 O(N) |
| 兼容性 | 旧版 | 7.0+ |

> 7.0 把 Hash、List、Set、ZSet **全部换成 listpack**，是一次大重构。

---

## 四、典型应用代码

### 4.1 简单消息队列（生产慎用，建议用 Stream）

```java
// 生产者
redis.lpush("mq:order", JSON.toJSONString(order));

// 消费者（阻塞）
List<String> result = redis.brpop(0, "mq:order");   // 0 = 永久阻塞
String msg = result.get(1);
process(JSON.parseObject(msg, Order.class));
```

**问题**：
- **消息丢失**：消费者取走但还没处理就崩了 → 消息丢
- **没有 ACK**：处理失败无法回滚到队列
- **不支持多消费者组**：同一消息只能一个消费者拿到

→ **生产用 Stream，不要用 List 当 MQ**。

### 4.2 可靠消息队列（带回执）

```java
// 推送到处理队列时同时备份
String msg = redis.brpoplpush("mq:order", "mq:order:processing", 30);

try {
    process(msg);
    redis.lrem("mq:order:processing", 1, msg);   // 处理成功删除备份
} catch (Exception e) {
    // 处理失败，msg 还在 processing 队列，定时任务可以拣回
}
```

### 4.3 时间线（最新 N 条）

```java
// 用户发微博
redis.lpush("timeline:" + userId, postId);
redis.ltrim("timeline:" + userId, 0, 99);     // 只保留最新 100 条

// 看时间线
List<String> postIds = redis.lrange("timeline:" + userId, 0, 19);  // 前 20 条
```

### 4.4 滚动日志

```java
redis.lpush("log:" + serviceId, JSON.toJSONString(logEntry));
redis.ltrim("log:" + serviceId, 0, 999);   // 保留最近 1000 条
```

### 4.5 简单关注流（Push 模型）

```java
// 用户发了一条微博，推给所有粉丝
for (Long fanId : fans) {
    redis.lpush("inbox:" + fanId, postId);
    redis.ltrim("inbox:" + fanId, 0, 999);
}
```

适合粉丝少的场景（< 1 万）。大 V 用拉模型 + 推拉结合。

---

## 五、面试高频追问

### Q1：List 底层用什么数据结构？

**演进**：
- 3.2 之前：小用 ziplist，大用 linkedlist
- 3.2 ~ 7.0：全部用 quicklist（节点是 ziplist）
- 7.0+：quicklist（节点是 listpack）

`OBJECT ENCODING key` 查看（通常返回 `quicklist`）。

### Q2：ziplist 的连锁更新是什么？

ziplist 每个 entry 存"前一个 entry 的长度"（prevlen）。
prevlen 是变长的，前节点 < 254 字节用 1 字节，否则 5 字节。
当某节点扩大到 ≥254 字节，下一节点的 prevlen 要从 1 升 5，自身长度也变了，可能再触发下下个节点升级，**最坏 O(N²)**。

### Q3：listpack 怎么解决连锁更新？

每个 entry 不再存"前一个的长度"，只存"自己的长度"。
反向遍历靠末尾的"length-of-self"字段算出当前节点起点。
没有 prevlen → 没有连锁。

### Q4：为什么需要 quicklist？只用 ziplist 不行吗？

ziplist 在大集合时性能崩：
- 单 ziplist 几 MB，每次 realloc 慢
- 连锁更新最坏 O(N²)
- 内存碎片严重

quicklist = 双向链表 + 多段小 ziplist（每段 8KB），平衡了内存紧凑性和插入性能。

### Q5：List 适合做消息队列吗？

**不推荐**。三个问题：
1. 消费后才能 ACK，崩溃会丢
2. 不支持消费者组
3. 不能回放历史消息

→ 生产用 Redis Stream（5.0+）或专业 MQ（RocketMQ / Kafka）。

### Q6：BLPOP 阻塞期间客户端连接怎么处理？

阻塞客户端的连接占用一个线程（旧版）。6.0+ 多线程模式下也是单线程模型处理。
**生产建议**：阻塞 timeout 不要为 0（永久），设个合理值（如 30s）避免长连接堆积。

### Q7：LRANGE 0 -1 危险在哪？

返回 List 全部元素：
- 大 List（10 万元素）一次返回几 MB → 网络阻塞
- 主线程序列化也是 O(N) → 卡其他客户端
- 客户端 OOM

**修复**：分批 LRANGE 或用 LSCAN（不存在，要分页）。

### Q8：List 怎么实现栈？

LPUSH + LPOP（同端进出）→ 后进先出（LIFO）= 栈。

### Q9：阻塞队列 BLPOP/BRPOP 比 LPOP/RPOP 强在哪？

- LPOP：没数据时立刻返回 nil，要客户端轮询
- BLPOP：没数据时阻塞，有数据立刻返回，避免轮询浪费

**取舍**：BLPOP 占连接，LPOP + 间隔轮询占 QPS。

### Q10：LPUSH 多个值的顺序？

```
LPUSH key A B C
→ 头插入 A，再头插入 B，再头插入 C
→ 列表顺序：C B A
```

记忆：每个值独立头插。

### Q11：LREM 怎么用？

```
LREM key 2 value    # 从左到右，删 2 个匹配 value
LREM key -2 value   # 从右到左，删 2 个
LREM key 0 value    # 删所有匹配的
```

复杂度 O(N)。

### Q12：List 大 key 怎么治理？

判断：元素数 > 5 万或总内存 > 10MB。
治理：
- 拆分（按时间窗口分多个 key，如 `log:date:hour`）
- LTRIM 限制长度
- 删除用 UNLINK 不用 DEL

---

## 六、List vs Stream（面试常问）

5.0+ Redis Stream 是专门做消息队列的，比 List 强：

| 特性 | List | Stream |
| --- | --- | --- |
| 消费 ACK | 无 | 有（XACK） |
| 消费者组 | 无 | 有（XGROUP） |
| 历史回放 | 无（弹出即消失） | 有（消息保留，按 ID 读） |
| 多生产/多消费 | 简单 | 完善 |
| 持久化 | 同 List（RDB/AOF） | 同 |
| 适合场景 | 简单队列、栈、时间线 | 完整 MQ |

→ **2024 年新项目用 Redis 做 MQ，建议直接用 Stream**。

---

## 七、生产真实踩坑

### Case 1：List 当 MQ 丢消息

某订单系统用 BRPOP 消费 List，消费者拿到消息后处理时挂了 → 消息永久丢失。
**修复**：
1. 用 BRPOPLPUSH 推到"处理中"队列做备份
2. 处理成功删除备份；失败不删，定时拣回
3. 长期方案：换 Stream 或 RocketMQ

### Case 2：LRANGE 拉全量卡死

排行榜接口图省事 LRANGE 0 -1，结果 List 涨到 50 万 → 一次返回几十 MB → Redis 主线程卡 200ms。
**修复**：
- 限制返回数量（业务上分页）
- 大 List 拆分（如按月）
- ZSet 才是排行榜的正确选择

### Case 3：LPUSH 不限制长度，内存暴涨

日志收集用 LPUSH 写 Redis，没设 LTRIM，跑了一晚上单个 key 几个亿元素，机器内存爆了。
**修复**：每次 LPUSH 后立刻 LTRIM 限长度；监控大 key。

### Case 4：连锁更新导致毛刺

旧版本（3.0）大 ziplist 在某次插入时触发连锁更新，主线程 80ms 毛刺。
**修复**：升级到 7.0+ 用 listpack；或拆分。

### Case 5：BLPOP timeout=0 导致连接堆积

消费者代码 `BLPOP key 0`（永久阻塞），客户端没设 socket 超时 → 连接长期占用，几千个客户端导致 Redis 连接数打满。
**修复**：BLPOP timeout 设 30s，循环重试。

### Case 6：双端写入忘了一致性

两个服务都往同一个 List 写：A 用 LPUSH 写头，B 用 RPUSH 写尾，C 是消费者用 LPOP。
结果消费顺序混乱，A 写的总是先被消费。
**修复**：明确生产/消费的端，统一使用一种方向；或用 Stream（不依赖 push/pop 端）。

---

## 八、答题模板（60 秒话术）

> List 用于**栈、队列、阻塞队列、消息流、时间线**。底层经过三代演进：**3.2 之前是 ziplist + linkedlist**（小用 ziplist，大转 linkedlist），**3.2~7.0 是 quicklist + ziplist**（双向链表节点，每节点是个 ziplist），**7.0+ 是 quicklist + listpack**。
>
> ziplist 最大缺陷是 **连锁更新**——节点的 prevlen 字段链式存储，一个节点扩大会级联更新后续节点，最坏 O(N²)。
>
> **listpack** 的改进是每节点只存自身长度，反向遍历靠末尾长度字段，根除连锁更新。**quicklist** 是双向链表 + 多段小 listpack，平衡紧凑性和性能。
>
> 生产建议：消息队列用 **Stream**（5.0+ 替代）；时间线、栈、排行榜小数据用 List 配 LTRIM 限长。

→ 关联：[数据结构总览](./数据结构总览.md)、[哈希-Hash](./哈希-Hash.md)、[有序集合-ZSet](./有序集合-ZSet.md)
