# Lua 脚本

> 现代 Redis 编程的"瑞士军刀"。
> 凡是涉及 **原子性 + 复杂逻辑** 的场景（分布式锁、限流、秒杀扣库存、CAS），几乎都靠 Lua 脚本。
> 面试必问，但很多人只会用，讲不清"为什么 Lua 比 MULTI/EXEC 强"。

---

## 一、为什么需要 Lua

### 1.1 一个真实问题

需求：**库存够才扣，并返回扣后的库存**。

```python
stock = redis.get("stock:1001")     # ← 第 1 次 RTT
if stock < 1:
    return False
redis.decr("stock:1001")            # ← 第 2 次 RTT
return True
```

**问题**：两次 RTT 之间，**别的客户端可能也扣了**。库存原本是 1，并发下两个客户端都通过了"够不够"检查，都执行 DECR → 超扣到 -1。

### 1.2 三种解决方案对比

| 方案 | 原子性 | 网络 RTT | 评价 |
| --- | --- | --- | --- |
| **WATCH + MULTI/EXEC**（乐观锁） | 是（CAS 重试） | 多次 | 实现繁琐，高并发下重试饥饿 |
| **分布式锁** | 是（互斥） | 多次 | 重，性能差 |
| **Lua 脚本** | **是（最强）** | **1 次** | **首选** |

```lua
-- 一段 Lua，原子完成"判断 + 扣减"
local stock = tonumber(redis.call('GET', KEYS[1]))
if not stock or stock < 1 then
    return 0
end
redis.call('DECR', KEYS[1])
return 1
```

→ 这就是 Lua 脚本的杀手级场景。

---

## 二、Lua 脚本核心特性

| 特性 | 含义 |
| --- | --- |
| **原子执行** | Redis 单线程串行执行脚本，**期间不响应其他客户端命令** |
| **服务端运行** | 脚本在 Redis 服务端解释执行，无网络往返 |
| **缓存复用** | 脚本可用 sha1 缓存，下次只发哈希值 |
| **可写逻辑** | 支持 if/else/for/局部变量等 Lua 语法 |
| **沙箱化** | 不能访问文件系统、网络、危险 API |

### 关键点：脚本执行期间 Redis 完全阻塞

主线程跑脚本时，其他客户端的命令**全部排队等待**。
→ **脚本必须快**，超过 **5 秒** 默认会被 `lua-time-limit` 警告，过长直接 SHUTDOWN NOSAVE。

---

## 三、命令速查

```bash
# 直接执行
EVAL "<lua-script>" <numkeys> <key1> <key2> ... <arg1> <arg2> ...

# 缓存脚本（推荐生产）
SCRIPT LOAD "<lua-script>"     # 返回 sha1
EVALSHA <sha1> <numkeys> <keys> <args>

# 管理
SCRIPT EXISTS <sha1>           # 检查是否已缓存
SCRIPT FLUSH                   # 清空所有脚本缓存
SCRIPT KILL                    # 杀掉正在跑的慢脚本（仅未写状态时有效）
```

### 3.1 一个完整示例

```bash
> EVAL "return redis.call('SET', KEYS[1], ARGV[1])" 1 mykey "hello"
OK

> SCRIPT LOAD "return redis.call('GET', KEYS[1])"
"6b1bf486c81ceb7151aaa8cb723a6c1abeac61bc"

> EVALSHA 6b1bf486c81ceb7151aaa8cb723a6c1abeac61bc 1 mykey
"hello"
```

### 3.2 Java 客户端示例

```java
// Jedis
String script = "return redis.call('GET', KEYS[1])";
String sha = jedis.scriptLoad(script);
Object result = jedis.evalsha(sha, 1, "mykey");

// Redisson
RScript script = redisson.getScript(StringCodec.INSTANCE);
String sha = script.scriptLoad("return redis.call('GET', KEYS[1])");
Object result = script.evalSha(RScript.Mode.READ_ONLY, sha,
    RScript.ReturnType.VALUE, Arrays.asList("mykey"));
```

---

## 四、KEYS 和 ARGV 的区别（必考）

```lua
-- 正确写法：通过 KEYS 数组访问 key
redis.call('SET', KEYS[1], ARGV[1])

-- 错误写法（生产严禁）：硬编码 key
redis.call('SET', 'fixed_key_name', ARGV[1])
```

### 4.1 为什么必须用 KEYS

**Redis Cluster 路由依赖**：客户端通过 KEYS 识别脚本访问哪些 key，决定路由到哪个节点。
- 用 KEYS：客户端能识别 → 路由正确 → Cluster 下可用
- 硬编码：客户端识别不到 → 路由可能错 → Cluster 下报 `CROSSSLOT` 或路由错节点

### 4.2 KEYS 的 Cluster 限制

脚本里所有 KEYS **必须在同一个 slot**，否则报错：
```
ERR CROSSSLOT Keys in request don't hash to the same slot
```

**解决**：用 Hash Tag `{tag}` 让多 key 落同 slot：
```bash
EVAL "..." 2 {user:1001}:profile {user:1001}:cart
```

### 4.3 ARGV 是参数

任意非 key 数据通过 ARGV 传：
```lua
local userId = ARGV[1]
local timestamp = ARGV[2]
```

---

## 五、脚本缓存机制（性能关键）

### 5.1 EVAL 的问题

每次 EVAL 都把整段脚本通过网络传给 Redis：
- 10KB 脚本 + 1 万次调用 = 100MB 网络流量
- 服务端每次都要解析

### 5.2 EVALSHA 的优化

```
1. 应用启动时：SCRIPT LOAD 一次，拿到 sha1
2. 后续调用：只传 sha1（40 字节）
3. Redis 找到缓存的脚本直接执行
```

**节省 100x+ 网络流量** + 服务端跳过解析。

### 5.3 注意点：缓存失效

服务端可能由于：
- `SCRIPT FLUSH`
- 主从切换（新主没缓存）
- 重启

→ 脚本缓存丢失。客户端 SDK 通常处理这种情况：
```python
try:
    return redis.evalsha(sha1, ...)
except NoScriptError:
    return redis.eval(script, ...)   # fallback 重新加载
```

Redisson、Lettuce 都有内置回退机制。

---

## 六、典型应用场景

### 6.1 分布式锁的安全释放

```lua
-- 校验 + 删除原子化（防止误删别人的锁）
if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('DEL', KEYS[1])
else
    return 0
end
```

→ 详见 [Redis 分布式锁](./分布式锁.md#版本-4uuid--lua-释放解决误删)。

### 6.2 滑动窗口限流

```lua
-- 1 分钟内最多 100 次
local key = KEYS[1]
local now = tonumber(ARGV[1])
local window = 60000   -- ms
local limit = tonumber(ARGV[2])

redis.call('ZREMRANGEBYSCORE', key, 0, now - window)
local count = redis.call('ZCARD', key)
if count >= limit then
    return 0
end
redis.call('ZADD', key, now, now)
redis.call('EXPIRE', key, 61)
return 1
```

→ 详见 [有序集合 ZSet](./有序集合-ZSet.md#83-滑动窗口限流)。

### 6.3 秒杀扣库存

```lua
-- 用户限购 + 库存预扣 + 用户记录，三件事原子
local stock = tonumber(redis.call('HGET', KEYS[1], ARGV[1]))
if not stock or stock < 1 then
    return 0
end
local userBought = redis.call('SISMEMBER', KEYS[2], ARGV[2])
if userBought == 1 then
    return -1
end
redis.call('HINCRBY', KEYS[1], ARGV[1], -1)
redis.call('SADD', KEYS[2], ARGV[2])
return 1
```

→ 详见 项目中是如何处理高并发的。

### 6.4 CAS 更新

```lua
-- 类似 compare-and-swap
local current = redis.call('GET', KEYS[1])
if current == ARGV[1] then
    redis.call('SET', KEYS[1], ARGV[2])
    return 1
else
    return 0
end
```

### 6.5 多个 key 的原子聚合

```lua
-- 一次取多个统计指标的总和
local total = 0
for i, key in ipairs(KEYS) do
    total = total + tonumber(redis.call('GET', key) or 0)
end
return total
```

---

## 七、Lua vs 其他方案

| 方案 | 原子性 | 逻辑能力 | 网络 RTT | 错误处理 | 推荐场景 |
| --- | --- | --- | --- | --- | --- |
| **Lua 脚本** | 最强 | 完整 | 1 次 | 异常中止 | **复杂原子操作** |
| **MULTI/EXEC** | 中（不回滚） | ✗ | ~3 次 | 部分失败仍执行 | 简单批量 + 乐观锁 |
| **Pipeline** | ✗ | ✗ | 1 次 | 独立 | 大批量加速（无原子需求） |
| **WATCH + MULTI** | CAS（重试） | 部分 | 多次 | 同 MULTI | 简单 CAS |
| **分布式锁** | 互斥 | 完整 | 多次 | 业务处理 | 长操作 |

> **现代 Redis 编程优先级：Lua > 多 key 命令 > Pipeline > MULTI/EXEC**。

---

## 八、Redis 7.0 Functions（替代 Lua）

7.0 引入 **Functions** 作为 Lua 的现代替代：

```bash
FUNCTION LOAD "#!lua name=mylib
redis.register_function('add', function(keys, args)
    return redis.call('INCRBY', keys[1], args[1])
end)"

FCALL add 1 counter 5
```

### 8.1 Functions vs Lua

| 维度 | Lua（EVAL/EVALSHA） | Functions（FCALL） |
| --- | --- | --- |
| **持久化** | 缓存可能丢（重启/SCRIPT FLUSH） | **持久化**（写到 RDB/AOF，重启不丢） |
| **主从复制** | EVALSHA 需要从库也有缓存 | 复制时一起同步函数库 |
| **管理** | 散落各处 | 库（library）形式集中管理 |
| **版本化** | ✗ | 库可替换 |
| **生态** | 成熟（5.0~6.x 主流） | 7.0+，渐进采用 |

> Functions 是未来方向，但 **当前生产 95% 仍用 Lua**——客户端 SDK、Redisson 等基础设施都基于 Lua。

---

## 九、Lua 编程注意事项

### 9.1 类型转换坑

Redis 返回的数字字符串不能直接做算术：
```lua
local v = redis.call('GET', KEYS[1])
-- v 是 string，比如 "100"
if v > 0 then ... end           -- ✗ 字符串和数字比较
if tonumber(v) > 0 then ... end -- ✓
```

### 9.2 nil 处理

`GET` 不存在的 key 返回 false（Lua 表达），不是 nil：
```lua
local v = redis.call('GET', 'nonexistent')
if v == false then
    -- key 不存在
end
```

### 9.3 不要写无限循环

```lua
while true do                  -- ✗ 卡死 Redis
    ...
end
```
Redis 会等到 `lua-time-limit`（默认 5 秒）才能用 `SCRIPT KILL` 中止——前提是脚本未做写操作。
**写操作之后无法 KILL**，只能 SHUTDOWN NOSAVE 重启。

### 9.4 不要在脚本里做 IO

Lua 沙箱默认禁用文件、网络。但 **不要尝试绕过**——即使能做也会拖慢主线程。

### 9.5 控制脚本输入参数

不要把大数组当 ARGV 传：
```lua
EVAL "..." 0 huge_array_of_10000_items   -- ✗ 网络 + 解析压力
```
应该把数据先 SADD/HMSET 进 Redis，脚本里读。

### 9.6 ARGV 都是字符串

```lua
local count = tonumber(ARGV[1])  -- 必须显式转换
```

### 9.7 logging 用 redis.log

调试用 `redis.log(redis.LOG_WARNING, "...")`，不要用 `print()`（输出到客户端会破坏返回值）。

---

## 十、面试高频追问

### Q1：Lua 脚本是原子的吗？

**是**。Redis 单线程串行执行脚本，**期间不响应其他客户端命令**——脚本看到的状态是一致的，效果像数据库事务的"序列化隔离"。

### Q2：Lua 比 MULTI/EXEC 强在哪？

三点：
1. **逻辑能力**：能写 if/for/局部变量
2. **更原子**：MULTI 入队不响应，但脚本里能根据中间结果决定后续命令；MULTI 不行
3. **效率**：MULTI 多次 RTT，Lua 一次

详见第七节对比表。

### Q3：EVALSHA 比 EVAL 快多少？

**网络传输节省 100x+**（脚本越长越明显）。
服务端解析也更快（直接命中缓存）。
生产**必须用 EVALSHA**。

### Q4：脚本缓存什么时候失效？

- `SCRIPT FLUSH`
- 主从切换（新主未必有）
- Redis 重启
- Cluster 节点变化

客户端 SDK 应处理 NoScriptError 异常，自动 fallback 到 EVAL。

### Q5：Lua 脚本里能用 RANDOMKEY、TIME、SRANDMEMBER 这些"随机/时间"命令吗？

**能用，但有限制**：
- 主从复制时，主从执行结果会不一致
- 5.0 之前的"非确定性命令"会让脚本不能写（防止主从分裂）
- 5.0+ 可以用 `redis.replicate_commands()` 让脚本以"重放具体命令"形式复制（而不是脚本本身）

**最佳实践**：随机/时间从 ARGV 传入，脚本本身保持"确定性"。

### Q6：Lua 脚本能跨节点（Cluster）吗？

**不能**。一个脚本里所有 KEYS 必须在同一 slot。
解决：Hash Tag `{user:1001}:xxx`。

### Q7：Lua 脚本太慢卡主线程怎么办？

预防：
- 控制脚本逻辑，避免大循环
- 单脚本耗时 < 1ms 为佳
- 用 `lua-time-limit`（默认 5s）报警

应急：
- `SCRIPT KILL` 杀慢脚本（**仅未写操作时有效**）
- 如果已经写过，只能 `SHUTDOWN NOSAVE` 重启

### Q8：脚本写到一半失败会怎样？

**部分写已经生效**——Lua 不支持回滚。
解决：脚本逻辑要先校验所有前置条件，再统一写。

### Q9：Lua 脚本在主从复制下怎么传输？

5.0 之前：脚本本身被传到从库执行（要求脚本是确定性的）。
5.0+：可选 "命令模式"——把脚本里实际执行的写命令一条条复制到从库。**避免脚本非确定性导致主从分裂**。

### Q10：Lua 和 Redis Functions 有什么区别？

- **Lua（EVAL/EVALSHA）**：传统方案，缓存可能丢失
- **Functions（FCALL，7.0+）**：库形式，持久化 + 主从复制函数本身

未来方向是 Functions，但生产成熟度还不及 Lua。

### Q11：Lua 脚本里能调用其他 Lua 脚本吗？

**不能直接**。Redis Lua 沙箱不允许 `require`、`dofile` 等。
变通：把公共逻辑写成 Lua 函数，放在同一脚本里。

### Q12：Lua 脚本性能极限是多少？

简单脚本 ~10 万 QPS（接近 Redis 命令处理上限）。
脚本越复杂越慢（解释执行 + 命令调用）。
**经验**：单脚本耗时控制在 100μs 以内。

---

## 十一、生产真实踩坑

### Case 1：硬编码 key 在 Cluster 报错

```lua
return redis.call('SET', 'orderId:counter', ...)  -- ✗ 硬编码
```
单机能跑，迁 Cluster 后报路由错误。
**修复**：所有 key 通过 KEYS 数组传入。

### Case 2：长 Lua 卡死主线程

某个抽奖脚本里有 1 万次循环 + 多次 ZADD，单脚本执行 800ms → 全 Redis 业务超时。
**修复**：拆分逻辑，预扣库存放脚本（< 1ms），其他逻辑放业务代码。

### Case 3：脚本写过状态后 SCRIPT KILL 无效

bug 脚本死循环 + 已经 SET 过 key → SCRIPT KILL 返回 `BUSY` 但杀不掉。
**修复**：只能 SHUTDOWN NOSAVE 重启 → 丢未持久化数据。
**预防**：脚本逻辑严格 review，单元测试。

### Case 4：EVALSHA 失败业务报错

主从切换后从库没缓存，EVALSHA 报 `NOSCRIPT`，业务直接挂。
**修复**：客户端 SDK 升级支持 NOSCRIPT 自动 fallback；或定期 SCRIPT LOAD 预热所有节点。

### Case 5：Lua 脚本里用了 TIME 命令

主从复制时主从执行结果不一致 → 数据漂移。
**修复**：时间从客户端 ARGV 传入；或调用 `redis.replicate_commands()` 切到命令复制模式。

### Case 6：忘了 tonumber 导致逻辑错

```lua
if redis.call('GET', KEYS[1]) >= 100 then ... end
```
GET 返回字符串 "50"，"50" >= 100 在 Lua 里是字符串比较，永远为 false。
**修复**：永远用 `tonumber()` 包装。

### Case 7：脚本里嵌入超大列表

业务把 5000 个商品 ID 作为 ARGV 传入，脚本里 for 循环全部处理 → 单脚本耗时 200ms。
**修复**：分批处理（每批 100 个），多次脚本调用代替一次大批。

---

## 十二、答题模板（60 秒话术）

> Lua 脚本是 Redis "复杂逻辑 + 原子性" 的标配——**分布式锁释放、限流（令牌桶/滑动窗口）、扣库存、CAS** 都用它。**原子性**靠 Redis 单线程串行执行脚本，期间不响应其他命令。
>
> 和 **MULTI/EXEC** 比，Lua 能写真正的逻辑（条件分支、循环、计算），效率和原子性都更强；和 **Pipeline** 比，Lua 原子、Pipeline 不原子。
>
> 生产用 **EVALSHA + SCRIPT LOAD** 而不是每次 EVAL 完整脚本——节省百倍流量。**KEYS 数组必须用**——传 key 不能写在脚本里，因为 Cluster 路由依赖 KEYS 判断 slot；**Cluster 下所有 KEYS 必须同 slot**，靠 Hash Tag。
>
> 生产坑：脚本要快（**<1ms 不阻塞主线程**）、不写无限循环、tonumber 显式类型转换。
>
> Redis 7.0 的 **Functions** 是 Lua 的现代替代——支持持久化、命名空间、版本管理，渐进迁移。

→ 关联：[Redis 事务](./事务.md)、[管道与批量优化](./管道与批量优化.md)、[Redis 分布式锁](./分布式锁.md)、[有序集合 ZSet](./有序集合-ZSet.md)、[Redis 集群部署](./集群部署.md)
