# 大 key 与热 key 治理

> 生产 Redis 最大的两类隐患就是 **大 key** 和 **热 key**。
> 95% 的 Redis 线上事故（突发卡顿、QPS 雪崩、内存爆、迁移失败）都能追到这两个问题之一。
> 面试官如果问"你 Redis 有踩过什么坑"，能讲清这两块就是有真实经验。

---

## 一、为什么必须治理

| 问题 | 大 key | 热 key |
| --- | --- | --- |
| **本质** | 单个 key 占用内存太大 | 单个 key 访问频率太高 |
| **典型表现** | DEL 卡主线程、迁移失败、网络阻塞、序列化慢 | 单分片 CPU 100%、客户端 timeout、雪崩到 DB |
| **影响范围** | 整个 Redis 实例 | 单分片 / 整个集群 |
| **发现难度** | 中（工具能扫） | 高（需要采样） |

Redis 是单线程，**任何一个慢操作都会拖累所有客户端**。大 key 和热 key 就是慢操作的两个主要源头。

---

## 二、大 key（Big Key）

### 2.1 什么算大 key

**业界标准**（参考阿里云、腾讯云）：

| 类型 | 大 key 阈值 | 严重大 key |
| --- | --- | --- |
| String | value > 10KB | > 1MB |
| Hash | 字段数 > 1000 或总大小 > 1MB | > 1 万字段 / 10MB |
| List | 长度 > 5000 或总大小 > 1MB | > 5 万 / 10MB |
| Set | 元素数 > 5000 | > 5 万 |
| ZSet | 元素数 > 5000 | > 5 万 |

**实战经验**：
- value > 10KB 已经要警惕
- > 100KB 几乎必造成毛刺
- > 1MB 是定时炸弹

### 2.2 大 key 的危害

#### ① 阻塞主线程

Redis 单线程，操作大 key 的命令耗时长：
```
DEL 大 List/Hash → O(N)，可能阻塞数百 ms
HGETALL 大 Hash → O(N) + 返回数据序列化
SMEMBERS 大 Set → 同上
LRANGE 0 -1 大 List → 同上
```

#### ② 网络阻塞

```
返回 100MB value → 万兆网卡也要 100ms 才能传完
期间 client 连接被独占
```

#### ③ 持久化卡顿

- RDB：fork 时 COW 需要复制大量页
- AOF rewrite：写大 key 序列化慢

#### ④ 迁移失败

Cluster 迁移 slot 时，单 key 的迁移要序列化 + 网络传输 + 反序列化。
大 key 迁移可能超过 `cluster-node-timeout`，触发故障转移。

#### ⑤ 内存碎片

大 value 的内存分配难复用，碎片率飙升。

#### ⑥ 备份恢复慢

主从全量同步、备份恢复都要处理大 key。

### 2.3 大 key 的来源（业务上为什么会出现）

| 场景 | 例子 |
| --- | --- |
| **业务设计错误** | 把整张表存一个 Hash；用户的所有日志存一个 List |
| **数据无限增长** | 每个商品的"参与抽奖用户"Set，没限制大小 |
| **冷数据未清理** | 历史订单累积在用户的 List 里没 LTRIM |
| **value 包含大字段** | 缓存对象的 JSON 里塞了商品图片 base64 |
| **临时数据没 TTL** | 一次性数据写完没设过期 |

### 2.4 怎么发现大 key

#### ① redis-cli --bigkeys（生产可用，离线扫描）

```bash
redis-cli -h <host> -p <port> --bigkeys

# 输出示例:
[00.00%] Biggest string  found so far 'goods:1001' with 524288 bytes
[10.23%] Biggest hash    found so far 'cart:user:5' with 12345 fields
...
```

**原理**：SCAN + 调用 STRLEN/HLEN/LLEN/SCARD/ZCARD，按类型找最大的。
**注意**：**不是按字节数排序**——Hash 字段数多不一定字节数大，要配合 MEMORY USAGE 进一步看。

#### ② MEMORY USAGE（精确查单 key）

```bash
> MEMORY USAGE goods:1001
(integer) 524320      # 包含 key 自身和 value 的总字节
```

#### ③ DEBUG OBJECT（看更详细的信息）

```bash
> DEBUG OBJECT goods:1001
Value at:0x7f... refcount:1 encoding:raw serializedlength:524288 ...
```

#### ④ SCAN + 监控脚本（生产环境）

```python
# 业务时段慎用！抽样扫描更安全
cursor = 0
while True:
    cursor, keys = redis.scan(cursor, count=100)
    for k in keys:
        size = redis.memory_usage(k)
        if size > 1024 * 1024:  # > 1MB
            log.warning(f"Big key: {k}, size={size}")
    if cursor == 0:
        break
```

#### ⑤ rdb-tools 离线分析

```bash
pip install rdbtools
rdb -c memory dump.rdb --bytes 1024 > bigkeys.csv
```

不影响线上，**最安全**。每天定时分析 RDB 备份。

#### ⑥ 阿里云/腾讯云控制台

云上 Redis 自带大 key 实时分析。

### 2.5 怎么治理大 key

#### 方案 1：拆分

最常用方案：

```
原: cart:userId  (一个 Hash 存所有商品)
拆: cart:userId:1, cart:userId:2, cart:userId:3 ...
    按商品 hash 分到 N 个小 Hash
```

具体拆法：
- **按业务维度**：商品按品类 / 用户按区域
- **按 hash 取模**：`cart:userId:${goodsId % 100}`
- **按时间分片**：`log:userId:202501`

#### 方案 2：精简数据

- value 里的大字段（图片、文档）转用对象存储，Redis 只存 URL
- JSON 字段瘦身，去掉不必要的字段
- 用 protobuf 替代 JSON（体积省 60%）

#### 方案 3:压缩

- 应用层对 value 做 gzip / snappy
- 注意：CPU 换内存，要评估 Redis 主线程的解压成本（业务侧解压更好）

#### 方案 4：异步删除（必备）

```bash
DEL big_key      # ✗ 同步阻塞
UNLINK big_key   # ✓ 4.0+ 异步删除（推荐）
```

UNLINK 把 key 从主键空间立即移除（业务看不见了），实际内存释放放后台线程做。

#### 方案 5：限制增长

```bash
# List 限长
LPUSH log:userId entry
LTRIM log:userId 0 999      # 只保留最近 1000 条

# ZSet 限长
ZADD rank score member
ZREMRANGEBYRANK rank 0 -1001    # 只保留分数最高的 1000 个

# Stream 限长
XADD stream MAXLEN 10000 * field value
```

#### 方案 6：拆 String 为 Hash

```
原: SET user:1 '{"name":"Tom","age":20,"address":"..."}'
拆: HSET user:1 name Tom age 20 address "..."
```

好处：单字段访问，不用每次序列化整个对象（同时小 Hash 用 listpack 编码很省内存）。

### 2.6 大 key 删除的安全姿势

```bash
# 字符串：直接 UNLINK
UNLINK big_string_key

# 大 Hash：HSCAN + HDEL 分批，再删壳
HSCAN big_hash 0 COUNT 100
# 对每批字段 HDEL
UNLINK big_hash

# 大 List：LTRIM 先截短，再 UNLINK
LTRIM big_list -1 0     # 截到只剩 0 个元素（其实清空了）
UNLINK big_list

# 大 Set/ZSet：SSCAN + SREM 分批
```

**永远不要直接 DEL 大 key**——4.0+ 用 UNLINK，更老版本只能分批拆。

---

## 三、热 key（Hot Key）

### 3.1 什么算热 key

| 维度 | 阈值（参考） |
| --- | --- |
| 单 key QPS | > 1 万 / 秒（中规模），> 5 万 / 秒（大规模必爆） |
| 单 key 流量占总流量比 | > 1% 单实例容量就算热 |
| 单分片 CPU 占比 | 远高于其他分片 |

### 3.2 热 key 的危害

#### ① 单分片 CPU 100%

Cluster 下，热 key 集中在一个 master 上，CPU 跑满 → 该分片整体响应变慢。

#### ② 心跳超时 → 集群误判故障转移

CPU 满 → 心跳延迟 → 其他节点判定该 master FAIL → 触发故障转移 → 5~30s 该分片不可用 → 客户端重试风暴 → 雪崩。

#### ③ 网络带宽打满

热 key value 不大也不行——QPS 5 万 × value 1KB = 50MB/s，普通千兆网卡顶不住。

#### ④ 缓存击穿放大

热 key 一旦过期，瞬间打到 DB → DB 挂。详见 [缓存击穿](./缓存雪崩，击穿，穿透.md#三缓存击穿hotspot-invalid)。

### 3.3 热 key 的来源

| 场景 | 例子 |
| --- | --- |
| **大 V 数据** | 微博 / 抖音热门博主的粉丝列表 |
| **促销商品** | 双 11 秒杀的爆款 |
| **热点新闻** | 某某明星离婚 |
| **热门活动** | 抽奖参与者计数 |
| **配置数据** | 全站共享的开关、限流配置（每个请求都读） |

### 3.4 怎么发现热 key

#### ① redis-cli --hotkeys（4.0+）

```bash
redis-cli --hotkeys

# 要求 maxmemory-policy 不是 noeviction
```

**原理**：基于 LFU 计数器找访问频率高的 key。
**限制**：只有开启 LFU 策略时有效；只能事后扫描。

#### ② MONITOR 抽样（生产慎用）

```bash
MONITOR | head -10000 | awk '{print $4}' | sort | uniq -c | sort -nr | head
```

**MONITOR 严重影响 Redis 性能**，只能短时间运行（< 1 秒）做抽样。生产严禁长时间开。

#### ③ 客户端打点

应用层在 Redis 调用前后打日志：
```java
long before = System.nanoTime();
String result = redis.get(key);
metrics.timer("redis.get." + key).record(System.nanoTime() - before);
```

按 key 聚合统计访问频率，超阈值告警。

#### ④ 代理层热点检测（Tair Proxy / Codis）

云厂商的 Redis 代理普遍带热 key 自动识别。

#### ⑤ INFO commandstats

```bash
INFO commandstats
# cmdstat_get:calls=...  ← 命令级统计，不到 key 级
```

只能看命令级统计，不到 key 维度。

### 3.5 怎么治理热 key

#### 方案 1：本地缓存（最常用）

```java
// Caffeine 本地缓存
LoadingCache<String, String> local = Caffeine.newBuilder()
    .maximumSize(1000)
    .expireAfterWrite(10, TimeUnit.SECONDS)
    .build(key -> redis.get(key));

String value = local.get("hotkey");
```

**关键**：
- TTL 短（5~30 秒），容忍短暂不一致
- 必须有上限（防 OOM）
- 写操作要发布事件让所有节点本地缓存失效（MQ / Pub-Sub）

#### 方案 2：多副本 key（分散）

```
原: SET goods:1001 ...      ← 所有请求都打这一个 key
拆: SET goods:1001:0 ...
    SET goods:1001:1 ...
    ...
    SET goods:1001:9 ...    ← 10 个副本，各分摊 1/10 流量

读: redis.get("goods:1001:" + ThreadLocalRandom.current().nextInt(10))
```

**适用**：超热点的"读热"场景。每个副本独立写，写时全部更新。

#### 方案 3:服务端分片

按 hash 把热 key 拆到多个实际 key，对外封装统一接口。
适合"集合类型的热 key"（如热门话题的参与用户 Set），按 userId hash 分多个 Set。

#### 方案 4：永不过期 + 后台异步刷新

```java
// 主线程读到的是"逻辑过期"标志（永远命中），后台异步刷新
ValueWithExpiry v = redis.get(key);
if (v.isExpired()) {
    asyncExecutor.submit(() -> refreshFromDB(key));
}
return v.getValue();    // 即使过期也立即返回旧值
```

避免缓存击穿瞬间打 DB。详见 [缓存击穿 - 逻辑过期](./缓存雪崩，击穿，穿透.md#方案-2逻辑过期异步思路推荐高并发场景)。

#### 方案 5：限流 + 兜底

热 key 流量打到 Redis 也压不住时，应用层限流：
```java
if (rateLimiter.tryAcquire()) {
    return redis.get(hotKey);
} else {
    return localCache.get(hotKey);  // 用兜底值
}
```

#### 方案 6：读写分离

热 key 是读热点 → 用主从架构，读流量打从库（多个从库分摊）。
注意：会引入主从延迟问题（详见 [主从一致性](./主从一致性.md)）。

#### 方案 7：迁移热 key 到独立分片

Cluster 下把热 key 单独迁到一个不放其他业务的 master，不影响别人。
**只能缓解，不能根治**——单分片仍是瓶颈。

### 3.6 缓存击穿（热 key 的特殊场景）

热 key 过期瞬间，所有请求打 DB。详见 [缓存击穿](./缓存雪崩，击穿，穿透.md#三缓存击穿hotspot-invalid)。

主要方案：
- 互斥锁（让一个请求重建缓存）
- 逻辑过期（永不真过期，异步刷新）
- 永不过期 + 定时刷新

---

## 四、大 key + 热 key 双倒霉的场景

最危险：**又大又热**。例：双 11 主推商品的"详情数据 + 参与用户列表 + 评论数 + 库存"全塞一个大 Hash，QPS 又高。

后果：
- HGETALL 返回 MB 级数据 + QPS 5 万 → 网络爆
- 单分片 CPU 100% + 主线程被 HGETALL 卡住 → 心跳超时
- 缓存过期瞬间穿透到 DB → 雪崩

**修复**：
1. 拆 Hash 为 String + ZSet + 多副本 key
2. 本地缓存兜底
3. 永不过期 + 异步刷新

---

## 五、监控告警

| 指标 | 阈值 | 含义 |
| --- | --- | --- |
| 单 key 大小（MEMORY USAGE） | > 100KB | 大 key 候选 |
| `instantaneous_ops_per_sec`（INFO） | 突增 | 突发流量 |
| 单分片 CPU | > 80% | 可能有热 key |
| 慢日志（SLOWLOG） | 命令耗时 > 10ms | 大 key 操作 |
| 单 key QPS（客户端打点） | > 1 万 | 热 key |
| 主从同步延迟 | > 1s | 大 key 阻塞同步 |
| `mem_fragmentation_ratio` | > 1.5 | 碎片严重（大 key 副作用） |

---

## 六、面试高频追问

### Q1：什么算大 key？怎么发现？

定义：String > 10KB；集合类型 > 5000 元素或 > 1MB。
发现：
- `redis-cli --bigkeys`（在线扫，按数量找大）
- `MEMORY USAGE` 单 key 精确测
- `rdb-tools` 离线分析（最安全）
- 云厂商控制台

### Q2：大 key 的危害？

阻塞主线程、网络阻塞、持久化卡顿、迁移失败、内存碎片、备份慢。
**核心**：Redis 单线程，任何慢操作影响所有客户端。

### Q3：怎么删大 key？

**4.0+ 用 UNLINK**（异步删除，立即从主键空间移除，后台释放内存）。
**老版本**：分批删（HSCAN + HDEL，SSCAN + SREM，LTRIM），再 DEL 壳。
**绝对不要直接 DEL 大 key**。

### Q4：什么算热 key？

QPS > 1 万 / 秒、或单 key 流量占总流量 > 1%、或单分片 CPU 远高于其他分片。

### Q5：怎么发现热 key？

- `redis-cli --hotkeys`（4.0+，要 LFU 策略）
- 客户端打点统计（最准）
- 代理层热点检测（云厂商）
- MONITOR 短时间抽样（**生产慎用**）

### Q6：怎么治理热 key？

按从轻到重：
1. **本地缓存**（短 TTL）
2. **多副本 key**（拆成 N 个分散流量）
3. **服务端分片**（按业务维度拆）
4. **永不过期 + 异步刷新**（防击穿）
5. **限流兜底**（极端流量保 DB）
6. **迁移到独立分片**（运维层缓解）

### Q7：UNLINK 和 DEL 区别？

- DEL：同步释放内存，大 key 阻塞主线程
- UNLINK：仅从主键空间移除（O(1) 体感），后台线程释放内存
- 用法相同，4.0+ 推荐永远用 UNLINK

### Q8：FLUSHALL 大库会怎样？

阻塞主线程几秒到几十秒。
**生产**：用 `FLUSHALL ASYNC`（4.0+），或重命名禁用 `rename-command FLUSHALL ""`。

### Q9：大 key 影响主从复制吗？

影响很大：
- 全量同步：大 key 序列化 + 网络传输慢，可能超时
- 增量同步：大 key 一条命令占 backlog 很多空间
- 复制延迟：从库应用大 key 命令时也慢

**建议**：主从 backlog 调大；避免大 key；监控 lag。

### Q10：本地缓存防热 key，一致性怎么保证？

不能强一致。可接受方案：
- 短 TTL（10-30s），容忍秒级延迟
- 写操作发布事件 → MQ/Pub-Sub 通知所有节点失效
- 重要变更不放本地缓存

### Q11：多副本 key 怎么写？

写时全部更新：
```
SET goods:1001:0 newValue
SET goods:1001:1 newValue
... (全部 N 个副本)
```
读时随机选一个：`goods:1001:${random(N)}`。
代价：写放大 N 倍。适合读 >> 写的场景。

### Q12：BIGKEY/HOTKEY 命令会影响线上性能吗？

`--bigkeys`：用 SCAN + 单 key 命令，相对安全，但持续运行有 CPU 开销，**业务低峰期跑**。
`--hotkeys`：依赖 LFU 计数器，开销小。
**MONITOR**：极大开销，**严禁长时间运行**。
**rdb-tools**：完全离线，最安全。

---

## 七、生产真实踩坑

### Case 1：大 Hash 删除阻塞主线程

某购物车记录 Hash，单用户字段数 5 万。运维清理用 `DEL` → 主线程阻塞 800ms → 业务雪崩。
**修复**：HSCAN + HDEL 分批；或直接 UNLINK。

### Case 2：热 key 拖垮整个 Cluster

双 11 大促爆款商品 QPS 50 万 → 该 master CPU 100% → 心跳超时 → 故障转移 → 5 秒不可用 → 客户端重试风暴 → 其他分片也被打挂。
**修复**：本地缓存 + 多副本 key + 命令超时调短到 50ms 快速失败。

### Case 3：rdb-tools 分析发现冷藏 10GB 大 key

某用户行为日志 List，业务忘了 LTRIM，跑了一年涨到 5000 万元素 / 8GB。
**修复**：LTRIM 截到 1000；加每日定时任务限长。

### Case 4：BRPOP 看似没事，实际是大 key

`BRPOP big_list` 返回正常，但每次 LPUSH 时主线程要扫 List 维护索引（quicklist 多节点）。
**修复**：拆 List；或换成 Stream。

### Case 5：热点配置 key 每秒读 10 万次

全站限流配置存一个 String key，每个请求都 GET → 单分片打满。
**修复**：本地缓存（30s TTL）+ 配置变更走 MQ 广播失效。

### Case 6：迁移大 key 失败

Cluster 扩容时迁移 slot，单 key 200MB → migrate 命令超过 cluster-node-timeout → slot 迁移失败回滚。
**修复**：迁移前先把这个 key 拆掉；调大 cluster-node-timeout。

### Case 7：大 String 网络打满

商品详情 JSON value 500KB，QPS 1000 → 出口流量 500MB/s → 网卡打满 → 所有客户端超时。
**修复**：拆 Hash 按字段访问；图片移到 OSS；JSON 改 protobuf。

### Case 8：HGETALL 大 Hash 客户端 OOM

业务图省事 HGETALL 一个 10 万字段 Hash，单次返回 200MB → 客户端解析时 OOM。
**修复**：HSCAN 分页；服务端 SDK 加单次返回大小限制。

---

## 八、答题模板（60 秒话术）

> **大 key** 指 String > 10KB、集合类型 > 5000 元素或 > 1MB；**热 key** 指单 key QPS > 1 万或单分片 CPU 远高于其它。
>
> **大 key 危害**：操作阻塞主线程、网络传输爆带宽、持久化变慢、Cluster 迁移失败、删除时内存释放卡顿。**发现**：`redis-cli --bigkeys` 在线扫 + MEMORY USAGE 查具体 + rdb-tools 离线分析 RDB。**治理**：拆分（一个 Hash 拆 N 份）、精简字段、UNLINK 异步删替代 DEL、LTRIM 限制 List 长度。
>
> **热 key 危害**：单分片打满 → 心跳超时 → 误判故障转移 → 雪崩级联。**发现**：`redis-cli --hotkeys` + 客户端打点统计 + 代理层（Twemproxy / Codis）检测。**治理**：本地缓存（Caffeine 短 TTL）+ **多副本 key**（user:1234#0 ~ user:1234#9 随机访问）+ 永不过期异步刷新 + 限流兜底。
>
> 加分项：**DEL → UNLINK**、**FLUSHALL → FLUSHALL ASYNC**，监控 SLOWLOG 和命令 P99 延迟——这是 senior 与初级的分水岭。

→ 关联：[Redis 工作流程](./工作流程.md)、[缓存雪崩、击穿、穿透](./缓存雪崩，击穿，穿透.md)、[Redis 集群部署](./集群部署.md)、[秒杀场景 - Redis 故障应对](./秒杀场景-Redis故障应对.md)、[Redis 主从一致性](./主从一致性.md)
