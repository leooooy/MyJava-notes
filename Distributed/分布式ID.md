# 分布式 ID 生成

> 分布式系统的"基础设施级"组件——分库分表、订单号、流水号、对账系统都离不开它。
> 本篇要解决的问题：
> ① 为什么不能用 UUID / 数据库自增 / Redis INCR 当主键？
> ② **雪花算法**（Snowflake）的核心是什么？**时钟回拨**为什么是它的命门？
> ③ 美团 **Leaf** / 滴滴 **TinyId** / 百度 **UidGenerator** 各自怎么改造的？
> ④ 怎么设计一个**业务可读的订单号**（带日期/分片/递增）？
>
> 这是分布式架构最容易被低估的话题——一个 ID 设计错误，**导致 DB 索引性能、对账逻辑、运维排障全部连锁出问题**。

---

## 一、分布式 ID 的核心要求

| 要求 | 含义 | 不满足的后果 |
| --- | --- | --- |
| **全局唯一** | 整个分布式系统不重复 | 主键冲突，业务出错 |
| **趋势递增** | 大致按时间递增（不需要严格） | DB 索引（B+ 树）插入性能差 |
| **高性能** | 单机至少 1w QPS 起步 | 影响业务 RT |
| **高可用** | ID 服务挂了业务不能停 | 全站不可下单 |
| **信息安全** | 不暴露业务信息（订单量等） | 竞争对手猜出每天交易量 |

**理想方案 = 全占**。但实际是各种取舍。

### 1.1 为什么强调"趋势递增"

InnoDB 主键索引是 B+ 树。**主键无序插入**会导致：
- 频繁的页分裂（page split）
- 索引页空间利用率低（碎片严重）
- 写性能下降 30%~50%

```
有序插入：
[100, 101, 102, 103]  →  顺序追加，性能最佳

无序插入（UUID 风格）：
[abc-x123, abc-x008, abc-x456]  →  每次找位置插入，频繁分裂页
```

> 真实数据：用 UUID 当主键 vs 用雪花 ID，写入性能差 2-3 倍，索引体积大 1.5 倍。

---

## 二、方案全景

### 2.1 七种主流方案对比

| 方案 | 全局唯一 | 趋势递增 | 性能 | 高可用 | 信息安全 |
| --- | --- | --- | --- | --- | --- |
| UUID | ✅ | ❌ | 极高 | ✅ | ✅ |
| 数据库自增 | ✅ | ✅ | 低 | ❌ 单点 | ❌ 暴露量 |
| 数据库分段（MyCat） | ✅ | 多列递增 | 中 | 中 | ❌ |
| Redis INCR | ✅ | ✅ | 高 | 中 | ❌ |
| **雪花算法** | ✅ | ✅ | 极高 | ✅ | ✅ |
| **号段模式** | ✅ | ✅ | 高 | ✅ | ❌ |
| **Leaf-Snowflake** | ✅ | ✅ | 极高 | ✅（解决时钟回拨）| ✅ |

### 2.2 选型决策树

```
是否需要业务可读（如订单号）？
  └─ 是 → 拼接：日期 + 业务码 + 雪花/号段 ID
  └─ 否
       ├─ 高并发（QPS > 10w）？→ 雪花算法 / Leaf-Snowflake
       ├─ 中等并发（QPS 1~10w）？→ Leaf-Segment / TinyId（号段模式）
       ├─ 简单场景，不分库 → 数据库自增就够
       └─ 临时 ID（缓存 key、消息 ID）→ UUID 也行
```

---

## 三、雪花算法（Snowflake）

### 3.1 核心结构（必背）

Twitter 2010 年开源，64 位 long：

```
0 | 41 位时间戳 | 10 位机器 ID | 12 位序列号
│   ↑           ↑              ↑
│   毫秒级时间   1024 台机器    单机单毫秒 4096 个 ID
└── 符号位（0，永远为正）
```

### 3.2 各部分详解

| 段位 | 长度 | 取值范围 | 作用 |
| --- | --- | --- | --- |
| **符号位** | 1 bit | 0 | 永远为正，避免负数 ID |
| **时间戳** | 41 bit | 0 ~ 2^41-1 ms | 约 69 年（从设定起点开始）|
| **机器 ID** | 10 bit | 0 ~ 1023 | 5 bit 机房 + 5 bit 机器，最多 1024 台 |
| **序列号** | 12 bit | 0 ~ 4095 | 同一毫秒同一机器 4096 个 ID |

**理论 QPS**：单机 4096 × 1000 = **409.6 w/s**（够用了）。

### 3.3 核心代码（必看）

```java
public class SnowflakeIdGenerator {
    // 起始时间戳（项目上线时间，比当前早 N 天即可）
    private final long epoch = 1577808000000L;  // 2020-01-01

    private final long workerIdBits = 5L;
    private final long datacenterIdBits = 5L;
    private final long sequenceBits = 12L;

    private final long maxWorkerId = -1L ^ (-1L << workerIdBits);          // 31
    private final long maxDatacenterId = -1L ^ (-1L << datacenterIdBits);  // 31
    private final long sequenceMask = -1L ^ (-1L << sequenceBits);         // 4095

    private final long workerIdShift = sequenceBits;                       // 12
    private final long datacenterIdShift = sequenceBits + workerIdBits;    // 17
    private final long timestampShift = sequenceBits + workerIdBits + datacenterIdBits;  // 22

    private long workerId;
    private long datacenterId;
    private long sequence = 0L;
    private long lastTimestamp = -1L;

    public synchronized long nextId() {
        long timestamp = System.currentTimeMillis();

        // 时钟回拨检测
        if (timestamp < lastTimestamp) {
            throw new RuntimeException("Clock moved backwards. Refusing to generate id");
        }

        // 同一毫秒内
        if (timestamp == lastTimestamp) {
            sequence = (sequence + 1) & sequenceMask;
            // 4096 个序列号用完，等下一毫秒
            if (sequence == 0) {
                timestamp = waitNextMillis(lastTimestamp);
            }
        } else {
            sequence = 0L;
        }

        lastTimestamp = timestamp;

        // 拼接
        return ((timestamp - epoch) << timestampShift)
             | (datacenterId << datacenterIdShift)
             | (workerId << workerIdShift)
             | sequence;
    }

    private long waitNextMillis(long lastTimestamp) {
        long timestamp = System.currentTimeMillis();
        while (timestamp <= lastTimestamp) {
            timestamp = System.currentTimeMillis();
        }
        return timestamp;
    }
}
```

### 3.4 雪花算法的两大坑

#### 坑 1：时钟回拨（最致命）

**触发场景**：
- NTP 校时把系统时间往回拨（夏令时切换、运维误操作）
- 虚拟机时间漂移后被宿主机校正
- 闰秒事件（如 2012 年 6 月 30 日的闰秒）

**后果**：
- 当前时间戳 < lastTimestamp → 算法直接抛异常或生成重复 ID
- **重复 ID 会导致主键冲突、订单重复、支付错乱**

**解决方案**（按强度递增）：

```
方案 1（朴素）：检测到回拨直接抛异常
  → 业务方报错重试，简单但故障期间不可用

方案 2（短回拨等）：回拨 < 5ms，循环等待时间追上
  → 适合极短回拨

方案 3（中回拨用预留序列号）：
  → 把序列号 12 bit 拆成 11 bit 序列 + 1 bit "回拨标识"
  → 检测到回拨切换标识位继续生成

方案 4（长回拨用备用机器 ID）：
  → 同一台机器准备多个 workerId，回拨后切到另一个

方案 5（持久化时间戳）：
  → 把上次时间戳写到 ZK / Redis，启动时校验
  → Leaf-Snowflake 的方案
```

#### 坑 2：机器 ID 分配

**问题**：10 bit = 1024 台机器，怎么分配？

| 方案 | 优点 | 缺点 |
| --- | --- | --- |
| 配置文件硬编码 | 简单 | 部署易错（两台配同 ID） |
| 启动时从 ZK 申请 | 自动分配 | 强依赖 ZK |
| **Leaf 方案**：ZK 持久化 + 本地缓存 | 容灾好 | 实现复杂 |
| K8s 用 Pod 序号 | 云原生友好 | 限定 K8s 环境 |

---

## 四、号段模式（美团 Leaf-Segment）

### 4.1 核心思路

数据库自增的优化版——**一次取一段，本地分发**：

```sql
CREATE TABLE leaf_alloc (
    biz_tag VARCHAR(128) PRIMARY KEY,    -- 业务标识（如 order / coupon）
    max_id BIGINT NOT NULL,              -- 当前最大 ID
    step INT NOT NULL,                   -- 步长（一次取多少）
    update_time TIMESTAMP
);
```

**取号段**（DB 一次操作，性能瓶颈仅在 DB 写）：

```sql
UPDATE leaf_alloc SET max_id = max_id + step WHERE biz_tag = 'order';
SELECT max_id, step FROM leaf_alloc WHERE biz_tag = 'order';
-- 假设 max_id = 1000, step = 1000
-- 这台机器拿到的号段是 [1, 1000]
-- 本地内存里递增分发 ID，用完再去取下一段 [1001, 2000]
```

### 4.2 双 Buffer 优化（性能毛刺解决）

朴素号段模式的问题：**号段用完时去 DB 取，业务卡顿 50ms+**。

Leaf 双 Buffer：

```
[当前号段 Buffer1]：1~1000
[备用号段 Buffer2]：空

当 Buffer1 用了 10% (100 个) → 异步去 DB 取 Buffer2
Buffer1 用完 → 直接切到 Buffer2，用户无感知

[当前号段 Buffer2]：1001~2000
[备用号段 Buffer1]：空 → 用了 10% 后又去取
```

**效果**：99.99% 请求直接走内存，DB 取号段是异步动作。

### 4.3 优缺点

✅ 趋势递增（DB 自增的特性）
✅ 性能远超直接用 DB（一次取一千，内存分发）
✅ ID 紧凑、可读（纯数字）
❌ 暴露业务量（看 ID 就能算出每天订单量）
❌ 重启浪费一段（机器挂了那段没用完的 ID 作废）
❌ 强依赖 DB（DB 挂了号段取不到）

---

## 五、Leaf-Snowflake（解决时钟回拨）

美团 Leaf 的另一种模式，针对雪花算法的时钟回拨问题，用 **ZK 持久化 workerId 和上次时间戳**：

```
1. 服务启动：从 ZK 拿 workerId（自动分配，避免冲突）
2. 服务运行：每 3s 把当前时间戳写回 ZK 持久化
3. 服务重启：
   - 从 ZK 读上次时间戳
   - 当前时间 > 上次时间戳 → 正常启动
   - 当前时间 < 上次时间戳 → 检测到回拨，拒绝启动 / 等待时间追上
```

**比原版雪花算法多了**：
- workerId 自动分配（不用人工配置）
- 时钟回拨能检测出来（重启时校验）
- 可以容忍小幅回拨（< 5ms 等一下）

→ 美团技术博客《Leaf——美团点评分布式 ID 生成系统》是必读资料。

---

## 六、业务可读订单号（实战）

订单号通常需要**业务可读**：客服一眼能看出年月、业务线、机房。

```
订单号示例：20260509-PAY-3-1234567890

含义：
- 20260509：日期（YYYYMMDD）
- PAY：业务码（支付）
- 3：机房代码
- 1234567890：雪花 ID 后 10 位（保证唯一）
```

**生成逻辑**：

```java
public String generateOrderNo(String bizCode) {
    String date = LocalDate.now().format(DateTimeFormatter.BASIC_ISO_DATE);  // 20260509
    String dc = String.valueOf(getDataCenter());                              // 3
    long snowflakeId = snowflake.nextId();
    String snowflakeSuffix = String.valueOf(snowflakeId % 10_000_000_000L);  // 后 10 位

    return String.format("%s-%s-%s-%s", date, bizCode, dc, snowflakeSuffix);
}
```

**注意点**：
- **不要**把订单号当主键存 DB（字符串太长，索引差）
- 用一个 BIGINT 当主键（雪花 ID），订单号当业务字段（带唯一索引）
- 长度控制在 20-32 字符内（前端 / 第三方接口友好）

---

## 七、生产踩过的坑

### 坑 1：UUID 当 MySQL 主键

> 早期项目把 UUID 当 InnoDB 主键，订单表写入 RT 平均 50ms（业务无关）。
> 改成雪花 ID 后，RT 降到 5ms，索引大小减少 40%。

**根因**：UUID 无序，B+ 树插入频繁页分裂；UUID 36 字符，索引大。

### 坑 2：雪花算法时钟回拨事故

> 运维手动校时把服务器时间往回拨 200ms → 雪花算法生成大量重复 ID → 订单表主键冲突 → 业务报错 5 分钟。

**修复**：① 禁用手动校时；② 用 chrony / NTP 平滑校准；③ 切换 Leaf-Snowflake 方案。

### 坑 3：机器 ID 配置冲突

> 上线时新机器漏配 workerId，默认值 = 0，跟另一台已存在的 0 号机器冲突 → 同一时间生成重复 ID。

**修复**：启动时从 ZK 拿 workerId，确保唯一。

### 坑 4：号段模式重启浪费严重

> 号段步长设 10000，每次重启浪费 1 万 ID。一周重启几次 + 上百台机器 → 浪费 N 百万 ID → 用户看到订单号跳很多。

**修复**：步长改为 100~1000（高频取号但减少浪费），用户接受 ID 不连续。

### 坑 5：订单号暴露业务量

> 订单号直接用号段递增 → 竞争对手每天 0 点和 24 点各下一单 → 通过订单号差值算出公司日单量。

**修复**：订单号里嵌入随机段或按机房打散，让连续不可推导。

### 坑 6：分库分表后 ID 冲突

> 分了 16 个库每个用本地自增 → 各自从 1 开始 → 跨库迁移合并时主键冲突。

**修复**：跨库统一用雪花算法，机器 ID 包含分片信息。

---

## 八、面试高频追问

### Q1：为什么不直接用 UUID？

三大缺点：
1. **无序**：B+ 树主键索引性能差（页分裂、空间浪费）
2. **太长**：36 字符（连字符版），索引体积大
3. **不可读**：没有时间、业务等信息，运维排障难

互联网业务几乎不用 UUID 当主键，仅在临时场景（缓存 key、消息 ID）用。

### Q2：雪花算法的 41 位时间戳为什么够 69 年？

41 bit = 2^41 = 2,199,023,255,552 ms ≈ 69.7 年
从 epoch（项目上线时间）开始算 → 项目能活 69 年（够用）

**注意**：epoch 必须设成项目上线时间，不要用 0（1970-01-01），否则浪费一半时间戳空间。

### Q3：怎么解决时钟回拨？

四个层次：
1. **检测**：lastTimestamp 持久化，每次比对
2. **等待**：回拨 < 5ms 直接 sleep 等
3. **切换**：回拨大就切到备用 workerId
4. **拒绝**：拒绝生成 + 报警 + 人工介入

生产推荐 **Leaf-Snowflake**：ZK 持久化时间戳，重启时校验。

### Q4：号段模式的号段大小怎么定？

平衡三个因素：
- **太小**（如 100）：DB 压力大（频繁取号段）
- **太大**（如 100000）：重启浪费多
- **典型值**：1000-10000，业务忍受少量浪费

监控指标：DB 取号段 QPS、号段使用率、平均消耗速度。

### Q5：高并发下雪花算法序列号 4096 不够怎么办？

单毫秒 4096 = 单秒 409w，**正常业务远远达不到**。
真到了瓶颈：
- 部署多个节点，每个节点配不同 workerId（10 bit 支持 1024 台）
- 业务侧分库分表，每个库用独立 ID 生成器

### Q6：怎么保证 ID 严格递增？

雪花算法是**趋势递增**（同一毫秒内序列号递增，跨毫秒按时间）——**不是严格递增**。

要严格递增（很少需要）：
- DB 自增主键（性能差）
- Redis INCR（高可用差）
- 单点 ID 服务（瓶颈）

> 实际业务从不要求严格递增——B+ 树要的只是趋势，不是绝对。

### Q7：分库分表用什么 ID？

**雪花算法是首选**：
- 全局唯一（不依赖中心）
- 趋势递增（B+ 树友好）
- 不需要协调（ShardingSphere、MyCat 默认支持雪花）

**不要用**：
- DB 自增（每个分库都从 1 开始，会冲突）
- UUID（无序，B+ 树性能差）

### Q8：怎么设计订单号让客服一眼看出问题？

```
20260509-202-3-1234567890
   ↑      ↑   ↑      ↑
  日期   业务  机房   雪花尾数

业务码示例：
  101 = 注册订单
  202 = 支付订单
  303 = 退款订单
```

客服收到投诉：客户 ID 12345 的订单 `20260509-202-3-...`
- 看日期定位日志
- 看业务码确定业务流
- 看机房定位 K8s Pod
- 雪花尾数 → 通过 `id % 10000000000` 反查 DB 主键

---

## 九、答题模板（60 秒话术）

> 分布式 ID 的核心要求是**全局唯一 + 趋势递增 + 高性能 + 高可用**。
>
> **UUID 不能用**——无序、太长、B+ 树写性能差 2-3 倍；DB 自增是单点；Redis INCR 高可用差。互联网主流是**雪花算法**和**号段模式**。
>
> **雪花算法**：64 位 = **1 符号位 + 41 时间戳 + 10 机器 ID + 12 序列号**，单机 409w QPS。命门是**时钟回拨**——NTP 校时往回跳会生成重复 ID。解决方案是 **Leaf-Snowflake**：用 ZK 持久化 workerId 和上次时间戳，重启时校验回拨。
>
> **号段模式**（美团 Leaf-Segment）：DB 一次取一段（如 1~1000），内存里分发。**双 Buffer 优化**——用了 10% 就异步取下一段，无毛刺。趋势递增、紧凑可读，但暴露业务量、重启浪费。
>
> **选型**：高并发选雪花（Leaf-Snowflake 解决回拨），中等并发选号段（Leaf-Segment 双 Buffer），需要业务可读用拼接（日期+业务码+雪花尾数）。
>
> **生产坑**：UUID 当主键写性能差、时钟回拨导致重复 ID、机器 ID 重复冲突、订单号泄漏业务量。

---

## 十、相关文档

- [幂等](./幂等.md) — 幂等键经常用分布式 ID
- [分布式锁](./分布式锁.md) — 锁的 value 用分布式 ID 防误删
- [MySQL/分库分表](../MySQL/分库分表.md) — 分库分表强依赖分布式 ID
- [一致性哈希](./一致性哈希.md) — 数据分片的另一种思路
- [Redis/字符串-String](../Redis/字符串-String.md) — Redis INCR 当 ID 的实现
