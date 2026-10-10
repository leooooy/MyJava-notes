# 字符串 String

> Redis 5 种基础类型里**用得最多**的，但也是最容易被忽视底层的。
> 面试官问"String 你了解吗"——能从 SDS 讲到三种编码切换、再讲到为什么不用 C 字符串，就是 senior。

---

## 一、能用来做什么

| 场景 | 用法 | 核心命令 |
| --- | --- | --- |
| 单值缓存 / 对象缓存 | JSON 序列化整个对象 | `SET / GET` |
| 计数器 | 文章阅读数、点赞数 | `INCR / DECR / INCRBY` |
| 分布式锁 | 唯一标识占位 | `SET NX EX` |
| 全局唯一 ID | 批量获取 ID 段（性能高） | `INCRBY orderId 100` |
| 限流（计数器法） | 单位时间累计 | `INCR + EXPIRE` |
| 共享 Session | JWT/Token 存 Redis | `SETEX session:xxx 1800 v` |
| 位图（Bitmap） | 签到、活跃用户统计 | `SETBIT / GETBIT / BITCOUNT` |

> String 的 value 上限是 **512MB**，但任何超过 1MB 的 value 都已经是大 key，必须警惕。

---

## 二、常用命令速查

```bash
# 基础读写
SET key value                   # 写入
SET key value EX 60             # 写入 + 60s 过期
SET key value NX                # 不存在才写（分布式锁基础）
SET key value XX                # 存在才写
SETEX key 60 value              # 等价于 SET + EX
GET key                         # 读取

# 批量
MSET k1 v1 k2 v2                # 批量写（原子）
MGET k1 k2                      # 批量读

# 原子计数
INCR counter                    # +1
DECR counter                    # -1
INCRBY counter 10               # +10
INCRBYFLOAT counter 0.1         # 浮点

# 范围操作
APPEND key v                    # 追加
STRLEN key                      # 长度
GETRANGE key 0 5                # 子串
SETRANGE key 7 "world"          # 替换

# 位操作（Bitmap）
SETBIT key 100 1                # 第 100 位置 1
GETBIT key 100                  # 读第 100 位
BITCOUNT key                    # 统计 1 的数量
BITOP AND/OR/XOR dest k1 k2     # 位运算
```

**性能复杂度**：基本都是 O(1)，例外 `STRLEN`（O(1) 因为 SDS 自带长度）、`APPEND`（O(N)）、`BITCOUNT`（O(N)）。

---

## 三、底层编码（关键面试点）

String 有 **3 种内部编码**，根据值的内容自动选择：

| 编码 | 触发条件 | 含义 |
| --- | --- | --- |
| `int` | value 是整数且能用 long（8 字节）表示 | 直接把整数存在指针位置（不分配 SDS） |
| `embstr` | 字符串长度 ≤ **44 字节**（5.0+，之前是 39） | 嵌入式 SDS，redisObject 和 SDS 内存连续分配 |
| `raw` | 字符串长度 > 44 字节 | 普通 SDS，redisObject 和 SDS 分开分配 |

### 3.1 编码切换规则

```
SET k 100              → int
SET k "hello"          → embstr（5 字节）
SET k "<45 字节字符串>" → raw（>44 字节）

APPEND k "anything"    → raw（embstr 是只读的，APPEND 会触发转换）
INCR (对 int)          → 仍是 int
INCR (对 embstr "abc") → 报错（不是数字）
```

**关键规则**：编码**只升不降**。
- 一个 int 编码的 key 经过 `APPEND` 变成字符串后 → raw，永远不会回到 int
- 一个 embstr 经过修改后 → raw，永远不回 embstr

### 3.2 为什么 embstr 是 44 字节

redisObject 是 16 字节，jemalloc 分配内存时按 2 的幂对齐。
**16 + sdshdr8(3) + 字符串内容 + '\0' = 64 字节**（一个 cache line 大小）
→ 字符串内容 = 64 - 16 - 3 - 1 = **44 字节**

### 3.3 三种编码内存对比

存 100 个用户的 key（如 `user:id`，value = 整数 ID）：

| 编码 | 单个 key 内存（约） |
| --- | --- |
| int | ~56 字节 |
| embstr | ~64 字节 |
| raw | ~96 字节 |

→ **能用 int 用 int，能用 embstr 用 embstr**。这就是为什么计数器要用 `INCR`，不要用 `SET counter "1"`。

---

## 四、SDS（Simple Dynamic String）深度解析

Redis 不直接用 C 字符串，而是自己实现了 SDS。

### 4.1 C 字符串的问题

```c
char *str = "hello";
// 1. 获取长度要遍历到 '\0'，O(n)
// 2. 不二进制安全（中间不能含 '\0'）
// 3. 修改时要手动 realloc，容易溢出
// 4. 不可修改（字面量在只读段）
```

### 4.2 SDS 的结构（5.0+ 简化版）

```c
struct __attribute__((__packed__)) sdshdr8 {
    uint8_t len;        // 已使用的字节数
    uint8_t alloc;      // 分配的总字节数（不含 header 和 '\0'）
    unsigned char flags; // 类型标识（sdshdr5/8/16/32/64）
    char buf[];         // 实际字符串
};
```

按 buf 容量分 5 种：sdshdr5（≤32B）、8（≤256B）、16、32、64。**目的：节省 header 空间**（小字符串就用小 header）。

### 4.3 SDS 解决了什么

| 问题 | C 字符串 | SDS |
| --- | --- | --- |
| 取长度 | O(n) | **O(1)**（直接读 len） |
| 二进制安全 | 不安全（'\0' 终止） | **安全**（用 len 判断结尾） |
| 缓冲区溢出 | 需手动 realloc | **自动扩容** |
| 频繁修改性能 | 每次 realloc | **空间预分配 + 惰性释放** |

### 4.4 空间预分配（性能关键）

修改后扩容规则：
- 新长度 < 1MB → 多分配相同长度（即翻倍）
- 新长度 ≥ 1MB → 多分配 1MB

**目的**：避免每次 APPEND 都触发 `realloc` 系统调用（用户态 → 内核态切换）。

### 4.5 惰性空间释放

字符串变短时**不立即释放内存**，记录在 `alloc - len` 里，下次扩容可复用。

---

## 五、典型应用代码示例

### 5.1 缓存对象

```java
// JSON 方式
String json = JSON.toJSONString(user);
redis.setex("user:" + id, 3600, json);

// 反序列化
String json = redis.get("user:" + id);
User user = JSON.parseObject(json, User.class);
```

→ 简单，但更新单字段要重写整个 JSON。**频繁更新单字段用 Hash 更合适**。

### 5.2 分布式锁

```java
// 加锁（Redisson 底层就是这个）
String uuid = UUID.randomUUID().toString();
boolean locked = redis.set("lock:order:1", uuid, "NX", "EX", 30);

// 释放（Lua 校验 + DEL，保证原子）
String script = "if redis.call('GET',KEYS[1])==ARGV[1] " +
                "then return redis.call('DEL',KEYS[1]) else return 0 end";
redis.eval(script, ...);
```

→ 详见 [分布式锁](./分布式锁.md)。

### 5.3 计数器（点赞、阅读量）

```java
// 阅读量 +1
redis.incr("article:read:" + articleId);

// 限流（每分钟最多 60 次）
String key = "limit:" + userId + ":" + System.currentTimeMillis() / 60000;
long cnt = redis.incr(key);
if (cnt == 1) redis.expire(key, 60);
if (cnt > 60) throw new RateLimitException();
```

> **注意**：`INCR + EXPIRE` 是两步操作，**不是原子**。极端情况下 INCR 后客户端崩了 → key 没设 TTL → 永久残留。
> **生产做法**：用 Lua 脚本合并；或用 Redisson 的 `RateLimiter`。

### 5.4 全局 ID 生成

```java
// 一次拿一段，避免每次都打 Redis
long startId = redis.incrby("orderId", 100);    // 拿到 1001
// 本地用 1001~1100，用完再批量取
```

→ 类似数据库的"号段模式"，性能极高，单实例百万 QPS 不在话下。

### 5.5 Bitmap：日活/签到

```java
// 用户 12345 今天签到
redis.setbit("sign:" + LocalDate.now(), 12345, 1);

// 今天签到了多少人
redis.bitcount("sign:" + LocalDate.now());

// 用户 12345 这个月连续签到几天
for (int i = 0; i < 30; i++) {
    String key = "sign:" + LocalDate.now().minusDays(i);
    if (redis.getbit(key, 12345) == 0) break;
    days++;
}
```

**Bitmap 的优势**：1 亿用户的"签到/已读"标志，只需 12.5MB 内存（1 亿 / 8）。

### 5.6 Bitmap 进阶：HyperLogLog 类似的去重计数

```java
// 统计今天独立访客
redis.setbit("uv:" + date, userId, 1);
redis.bitcount("uv:" + date);    // 近似 UV
```

但比 HyperLogLog 占空间（每个用户 ID 都要一位）。HLL 是 12KB 固定大小，误差 0.81%。

---

## 六、面试高频追问

### Q1：Redis 的字符串和 C 的字符串有什么区别？

四点：
1. **取长度 O(1)**（C 是 O(n)）
2. **二进制安全**（可以存图片、加密数据等含 `\0` 的内容）
3. **自动扩容**（避免缓冲区溢出）
4. **空间预分配 + 惰性释放**（减少 realloc 次数）

### Q2：String 的内部编码有几种？分别什么情况用？

三种：
- `int`：整数且能用 long 表示
- `embstr`：字符串 ≤ 44 字节，redisObject 和 SDS 内存连续
- `raw`：> 44 字节，redisObject 和 SDS 分开

可以用 `OBJECT ENCODING key` 查看。

### Q3：为什么 embstr 是 44 字节而不是其他数？

64 字节 cache line 减去 redisObject (16) + sdshdr8 header (3) + 末尾 '\0' (1) = 44。
让一个完整的 String 对象正好放进一个 cache line，CPU 缓存利用率最优。

### Q4：embstr 修改后会回到 int 或 embstr 吗？

不会。Redis 编码**只升不降**（升级路径 int → embstr → raw）。
即使值改回原来的整数，编码仍保持 raw。
这是为了避免反复升降级带来的性能开销。

### Q5：APPEND 一个 int 编码的 key 会怎样？

转成 raw。`APPEND counter "abc"` → counter 变成字符串编码（raw）。
**坑**：业务代码不要混用，会导致 INCR 后续操作失败（"value is not an integer"）。

### Q6：SET 操作是原子的吗？MSET 呢？

- 单个 SET：**是**（Redis 命令在主线程串行执行，单命令原子）
- MSET：**是**（批量原子）
- SET + EXPIRE 两步：**不是**（用 SET 带 EX 选项可以原子）

### Q7：value 太大有什么问题？

- 单个 value > 1MB 算大 key，序列化/网络/内存压力大
- > 10MB 严重影响性能（一次 GET 阻塞主线程几十毫秒）
- > 100MB 必出事故（同步、迁移、持久化、过期都被拖累）

**治理**：拆分（按业务维度），或把大字段移到 Hash/对象存储。

### Q8：INCR 有上限吗？

有，long 类型上限 `2^63 - 1`（约 9.2 × 10^18）。超过会报错 `ERR increment would overflow`。
浮点用 INCRBYFLOAT，没有溢出但精度有限。

### Q9：怎么用 String 做限流？

**计数器法**（最简单）：
```
INCR key
if first time: EXPIRE key 60
if cnt > limit: 拒绝
```

但有问题：临界点可能放过两倍流量（59s 来 100 个 + 60s 来 100 个）。
更精确用**滑动窗口**（Redis ZSet）或**令牌桶**（Redisson `RateLimiter`）。

→ 详见 [限流算法](../Microservice/限流算法.md)。

### Q10：Bitmap 适合做什么？不适合做什么？

**适合**：
- 大规模布尔状态（签到、活跃、是否在线）
- 用户位置可哈希成连续整数 ID
- 节省内存（1 位 = 1 个用户标志）

**不适合**：
- 用户 ID 离散（如 UUID） → 浪费空间
- 需要存详细信息（不只是 0/1）

### Q11：能用 String 做 MQ 吗？

不行。String 没有"消费"语义，要用 List 的 `LPUSH/BRPOP` 或 Stream。
单纯 String 只能做"消息计数器"或"幂等标记"。

### Q12：embstr 是只读的吗？

**逻辑上"修改"会触发转 raw**——因为 embstr 的 redisObject 和 SDS 内存相邻分配，修改要重新分配。
所以 embstr 只读不是"不能改"，而是"改了就升级成 raw"。

---

## 七、生产真实踩坑

### Case 1：大 JSON value 拖慢业务

某商品详情缓存成 JSON，单 value 500KB。一次 GET 100ms+，高并发下网络打满。
**修复**：拆 Hash，按字段访问（HGET goods:1 price），或拆多个 String key。

### Case 2：INCR + EXPIRE 不原子导致 key 永久残留

```java
redis.incr(key);
redis.expire(key, 60);   // 这里如果客户端崩了
```
key 没 TTL，永久占内存，限流计数也错乱。
**修复**：用 Lua 脚本合并；或第一次返回 1 时再设 EXPIRE（也不严格）；或干脆用带 TTL 的 SET。

### Case 3：用 SET 存数字而不是 INCR

```java
redis.set("counter", String.valueOf(num + 1));   // ✗ 非原子，会丢更新
redis.incr("counter");                            // ✓
```

### Case 4：分布式锁忘了 NX

```java
redis.set("lock:k", uuid, "EX", 30);    // 没加 NX，覆盖别人的锁
```
**修复**：必须 `SET k v NX EX 30`。

### Case 5：Bitmap key 过大导致迁移困难

签到 key 用了"大日历"全用户位图，单 key 100MB+，Cluster 迁移卡住。
**修复**：按用户分片（`sign:date:userId/10000`），单 key 控制在 10MB 内。

### Case 6：误把序列化对象当字符串 SETRANGE

序列化后的二进制数据用 SETRANGE 改了几个字节，结果反序列化失败。
**修复**：序列化对象用整存整取，不要做位置操作。

---

## 八、答题模板（60 秒话术）

> Redis 的 String 是最常用类型，应用覆盖**缓存、计数器、分布式锁、限流、Bitmap**。底层用 **SDS（Simple Dynamic String）**——相比 C 字符串解决了四个问题：长度 O(1)、二进制安全、自动扩容、空间预分配。
>
> 三种内部编码：**int**（纯整数）、**embstr**（≤44 字节，连续内存一次分配，cache line 友好）、**raw**（>44 字节，分两次分配）；编码切换**只升不降**。
>
> 生产上 value 控制在 1MB 以内防大 key；面试加分点是讲清 APPEND 会触发 embstr→raw 的编码升级、INCR 的上限是 long 范围、Bitmap 在签到统计的应用。

→ 关联：[数据结构总览](./数据结构总览.md)、[哈希-Hash](./哈希-Hash.md)、[分布式锁](./分布式锁.md)、[限流算法](../Microservice/限流算法.md)、[工作流程](./工作流程.md)
