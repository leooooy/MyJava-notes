# Sentinel

> 阿里开源、Spring Cloud Alibaba 主推的流量治理组件。
> 这道题面试的"段位差"在三点：
> ① 能不能讲清 **限流 / 熔断 / 降级** 三件事的边界（很多人混着说）
> ② 能不能讲清 **滑动窗口 + LeapArray** 限流算法的实现
> ③ 能不能讲清 **熔断的三态状态机** 和参数怎么调

---

## 一、Sentinel 解决什么

微服务架构下"流量"和"依赖"两个核心问题：

| 问题 | 解决工具 |
| --- | --- |
| 入口流量超过容量 → 服务被打挂 | **限流（Rate Limiting）** |
| 下游服务挂了 → 调用方线程全卡死 | **熔断（Circuit Breaking）** |
| 主流程失败 → 用户体验差 | **降级（Fallback）** |
| 热点用户 / 商品 → 占用大量资源 | **热点参数限流** |
| 调用链冗长 → 慢调用拖累整链路 | **慢调用熔断** |

**Sentinel = 把上面 5 件事一站式解决 + 提供动态规则配置 + 控制台**。

---

## 二、Sentinel vs 同类对比

| 维度 | **Sentinel** | Hystrix | Resilience4j |
| --- | --- | --- | --- |
| 出品 | 阿里 | Netflix | 社区 |
| 维护现状 | 活跃 | **已停更** | 活跃 |
| 核心隔离 | **信号量**为主 | 线程池 / 信号量 | 信号量 |
| 限流 | ✅（功能丰富） | ❌（只熔断） | ✅ |
| 熔断 | ✅ | ✅ | ✅ |
| 控制台 | **强大**（实时监控 + 规则推送） | 简陋 | 无 |
| 动态规则 | ✅（接 Nacos / Apollo） | ❌ | 通过代码 API |
| 学习曲线 | 中 | 中 | 低（函数式） |
| 国内主流 | **是** | 否 | 否 |

> **新项目结论**：国内 Spring Cloud Alibaba 项目首选 Sentinel；Spring Cloud 官方推 Resilience4j；Hystrix 不要再用。

---

## 三、核心概念

### 3.1 资源（Resource）

被保护的代码块——可以是方法、Controller、SQL、自定义 KEY。

```java
@SentinelResource(value = "getUserById", fallback = "getUserFallback", blockHandler = "blockHandler")
public User getUserById(Long id) { ... }
```

### 3.2 规则（Rule）

针对资源的治理策略：

| 规则类型 | 含义 |
| --- | --- |
| **流控规则**（FlowRule） | QPS / 并发线程数限流 |
| **熔断规则**（DegradeRule） | 慢调用 / 异常比例 / 异常数熔断 |
| **热点规则**（ParamFlowRule） | 按参数（如 userId）维度限流 |
| **系统规则**（SystemRule） | 整机维度（CPU / Load / 入口 QPS） |
| **授权规则**（AuthorityRule） | 按调用来源黑白名单 |

### 3.3 槽（Slot Chain）

Sentinel 内部把"统计 + 决策 + 拦截"做成责任链——每个 Slot 一个职责：

```
请求进入 SphU.entry("resource")
   ↓
NodeSelectorSlot          构建调用链路
   ↓
ClusterBuilderSlot        统计入口 / 集群节点
   ↓
LogSlot                   日志
   ↓
StatisticSlot       ★    实时统计（窗口数据）
   ↓
AuthoritySlot             黑白名单
   ↓
SystemSlot                系统规则（CPU、Load）
   ↓
FlowSlot            ★    流控规则
   ↓
DegradeSlot         ★    熔断规则
   ↓
业务代码执行
```

> **设计精髓**：和 Spring AOP 类似——把横切关注点切成独立 Slot，按需开关。

---

## 四、限流：滑动窗口实现

### 4.1 为什么不用计数器

固定时间窗口计数器在边界有"双倍流量"问题：

```
时间轴： |──── 1s ────|──── 1s ────|
请求：     100次      100次
        ↑           ↑
        都在 0.6-1.2s 这 600ms 内 → 实际上 0.6 秒涌入了 200 个请求
```

### 4.2 滑动窗口

把 1 秒切成 N 个小窗口（默认 2 个），每个 500ms 滑动：

```
当前时刻 t：[t-500ms, t-1000ms] 的窗口数据求和
└─ 任意 1 秒区间内请求数都准确
```

### 4.3 LeapArray：Sentinel 的滑动窗口实现

```java
public abstract class LeapArray<T> {
    protected int windowLengthInMs;       // 单个窗口大小
    protected int sampleCount;            // 窗口数（默认 2）
    protected int intervalInMs;           // 总时长 = windowLength * sampleCount

    protected final AtomicReferenceArray<WindowWrap<T>> array;
    
    public WindowWrap<T> currentWindow() {
        long timeId = currentTime / windowLengthInMs;
        int idx = (int) (timeId % sampleCount);                // ★ 环形数组
        WindowWrap<T> old = array.get(idx);
        if (old == null) {
            return resetWindowTo(...);
        }
        if (currentTime - old.windowStart() >= intervalInMs) {
            old.resetTo(...);                                  // 老窗口过期，复用槽位
        }
        return old;
    }
}
```

**关键设计**：环形数组复用槽位，避免不停 new 对象 → 内存稳定。

### 4.4 限流模式

| 模式 | 效果 | 适用 |
| --- | --- | --- |
| **直接拒绝**（默认） | 超阈值立即抛 `BlockException` | 大多数场景 |
| **Warm Up**（预热） | 启动时按比例放行，逐步增加 | 突发流量保护冷启动 |
| **匀速排队** | 漏桶算法，请求排队 | 需要削峰填谷 |

---

## 五、熔断：三态状态机

### 5.1 熔断器三个状态

```
       [CLOSED 闭合]
       正常放行 + 统计错误率
            │
            │  错误率 > 阈值（如 50%）
            ▼
        [OPEN 打开]
        直接拒绝（fail fast）
            │
            │  等待 N 秒（如 10s）
            ▼
       [HALF_OPEN 半开]
       放 1 个请求探测
            │
            ├─ 成功 → CLOSED
            └─ 失败 → OPEN
```

### 5.2 三种熔断策略

| 策略 | 阈值 | 适用 |
| --- | --- | --- |
| **慢调用比例**（SLOW_REQUEST_RATIO） | 1 秒 RT > 阈值的请求占比 | **生产首选**——慢调用是雪崩前兆 |
| **异常比例**（ERROR_RATIO） | 错误请求占总请求比例 | 错误率波动大的场景 |
| **异常数**（ERROR_COUNT） | 错误请求绝对数 | 流量低但要敏感的场景 |

### 5.3 关键参数

```java
DegradeRule rule = new DegradeRule();
rule.setResource("getUserById");
rule.setGrade(RuleConstant.DEGRADE_GRADE_RT);      // 慢调用
rule.setCount(500);                                  // 慢调用阈值 500ms
rule.setSlowRatioThreshold(0.5);                     // 50% 请求慢就熔断
rule.setMinRequestAmount(10);                        // 最少 10 个请求才参与统计（防小流量误判）
rule.setStatIntervalMs(10_000);                      // 统计窗口 10s
rule.setTimeWindow(5);                               // 熔断 5s
```

> **生产经验**：`minRequestAmount` 不可少——夜里 QPS 1，1 个慢调用就达到 100% 慢调用率，会误熔断。

---

## 六、注解使用：`@SentinelResource`

```java
@SentinelResource(
    value = "getUserById",                          // 资源名
    blockHandler = "blockHandler",                  // 限流 / 熔断的处理方法
    blockHandlerClass = BlockHandlers.class,        // 可放在独立类（推荐）
    fallback = "fallback",                          // 业务异常的降级方法
    fallbackClass = Fallbacks.class,
    exceptionsToIgnore = { BizException.class }     // 这些异常不触发 fallback
)
public User getUserById(Long id) {
    return userClient.getById(id);
}

// fallback 方法签名要和原方法一致（可加 Throwable 参数）
public User fallback(Long id, Throwable e) {
    return User.UNKNOWN;
}

// blockHandler 方法签名要和原方法一致 + 加 BlockException 参数
public User blockHandler(Long id, BlockException e) {
    throw new BizException(429, "请求过载");
}
```

### 6.1 `blockHandler` vs `fallback` 区别

| 触发条件 | blockHandler | fallback |
| --- | --- | --- |
| 限流 / 熔断（`BlockException`） | ✅ | ❌ |
| 业务异常 | ❌ | ✅ |
| 都没配 | 抛 `BlockException` | 抛原异常 |
| 都配了 | **blockHandler 优先** | / |

> **设计意图**：限流/熔断 是 Sentinel 的"主动拒绝"——返 429；业务异常是真出错——返 500 或降级数据。两类用不同处理方法。

---

## 七、与 Spring Cloud / Feign 集成

### 7.1 Spring MVC 自动埋点

```yaml
spring:
  cloud:
    sentinel:
      transport:
        dashboard: 127.0.0.1:8080      # Sentinel 控制台地址
      filter:
        url-patterns: /**              # 自动给所有 URL 埋点
```

启用后所有 Controller 接口自动作为 Sentinel 资源——控制台直接看到。

### 7.2 Feign 集成

```yaml
feign:
  sentinel:
    enabled: true
```

```java
@FeignClient(name = "user-service", fallback = UserClientFallback.class)
public interface UserClient {
    @GetMapping("/user/{id}")
    User getById(@PathVariable Long id);
}

@Component
public class UserClientFallback implements UserClient {
    @Override
    public User getById(Long id) { return User.UNKNOWN; }
}
```

详见 [Feign.md](Feign.md)。

---

## 八、动态规则：接 Nacos

**问题**：默认 Sentinel 规则存内存——服务重启全丢。

**修法**：把规则源改成 Nacos：

```xml
<dependency>
    <groupId>com.alibaba.csp</groupId>
    <artifactId>sentinel-datasource-nacos</artifactId>
</dependency>
```

```yaml
spring:
  cloud:
    sentinel:
      datasource:
        flow-rule:
          nacos:
            server-addr: 127.0.0.1:8848
            data-id: user-service-flow-rules
            group-id: SENTINEL_GROUP
            data-type: json
            rule-type: flow                 # 流控规则
        degrade-rule:
          nacos:
            ...
            rule-type: degrade              # 熔断规则
```

Nacos 上规则 JSON：

```json
[
  {
    "resource": "getUserById",
    "count": 100,
    "grade": 1,
    "limitApp": "default"
  }
]
```

修改 Nacos 上的规则——所有实例秒级生效；服务重启规则不丢。

---

## 九、热点参数限流

某些场景下整体 QPS 不高，但**特定参数值**（如某个 userId / itemId）流量极大：

```java
@SentinelResource(value = "queryItem", blockHandler = "blockHandler")
public Item queryItem(@SentinelParam(index = 0) Long itemId, String type) {
    return itemDao.find(itemId);
}
```

规则配置（控制台或 Nacos）：

```json
{
  "resource": "queryItem",
  "paramIdx": 0,
  "count": 100,
  "paramFlowItemList": [
    {"object": "12345", "count": 1000, "classType": "java.lang.Long"}
  ]
}
```

含义：参数 0（itemId）每秒 100 次；但 itemId=12345（爆款）单独配 1000 次/秒。

> **生产场景**：秒杀活动——商品 ID 12345 是大爆款，单独提高额度；其他正常 100。

---

## 十、生产踩坑

### 坑 1：规则没持久化，重启全丢

默认规则存内存——重启 / 扩容后规则全没。
**修法**：接 Nacos / Apollo（前面详述）。

### 坑 2：`minRequestAmount` 漏配导致夜间误熔断

夜间 QPS = 1，1 个慢请求 → 100% 慢调用率 → 触发熔断。**业务还没问题**，但用户调不通。
**修法**：`minRequestAmount` 设合理（如 10）——少于这个数不参与熔断判断。

### 坑 3：`@SentinelResource` 自调用失效

```java
public void outer() {
    inner();    // ❌ this 调用，注解失效
}
@SentinelResource(...)
public void inner() { ... }
```

`@SentinelResource` 也是 AOP——同 `@Transactional` 失效场景。

### 坑 4：`fallback` 方法签名错

```java
@SentinelResource(value = "x", fallback = "fb")
public User getUser(Long id) { ... }

public User fb(String name) { ... }    // ❌ 参数类型不一致，启动失败
```

**fallback 方法签名必须和原方法一致**（可在末尾加 `Throwable` 参数）。

### 坑 5：BlockHandler 异常被吞

`blockHandler` 方法本身抛异常——业务里看到的是 `BlockException` 包了原异常。
**修法**：blockHandler 里别再抛——返回降级数据或自定义业务异常。

### 坑 6：控制台连不上

Sentinel 控制台必须能从 client 拉到数据——不只是 client 推。
**修法**：① 客户端启动加 `-Dcsp.sentinel.api.port=8719`（Sentinel API 端口）；② 控制台所在机器要能访问 client 的 8719 端口。

### 坑 7：滑动窗口精度不够

默认 1 秒分 2 个窗口（500ms 一个）—— 极端情况仍有 1.5 倍流量。
**修法**：调高 `sampleCount`（如 10），但内存开销变大。

### 坑 8：规则推送到 Nacos 后，控制台显示的不一致

控制台是"读 Sentinel client 内存"，Nacos 是规则源——两边显示可能不同步。
**修法**：把控制台也接 Nacos 推送（`SENTINEL_DASHBOARD` 模式），或只用 Nacos 改规则、控制台只看监控。

---

## 十一、面试高频追问

**Q1：Sentinel 和 Hystrix 区别？**
A：① 维护：Hystrix 已停更，Sentinel 活跃；② 隔离方式：Hystrix 默认线程池隔离（开销大）、Sentinel 信号量为主（轻量）；③ 限流：Sentinel 功能丰富（QPS / 并发 / 热点 / 集群），Hystrix 几乎只做熔断；④ 控制台：Sentinel 强大，Hystrix 简陋；⑤ 动态规则：Sentinel 可接 Nacos / Apollo 实时推送。**新项目优先 Sentinel**。

**Q2：限流 / 熔断 / 降级 是同一个东西吗？**
A：**不是**。
- **限流**：保护**自己**——超过阈值拒绝请求
- **熔断**：保护**调用方**——下游不可用时快速失败，不让线程卡死
- **降级**：兜底逻辑——主流程失败走 fallback 返默认值或缓存
三者经常配合：限流挡住一波流量 + 熔断防止下游拖累自己 + 降级保证用户体验。

**Q3：Sentinel 限流算法？**
A：**滑动窗口 + LeapArray**。把统计周期切成 N 个小窗口（默认 2 个，每 500ms），用环形数组复用槽位。每次请求落到当前小窗口的计数器；判断时累加最近 N 个窗口求和。比固定时间窗口避免了边界突刺，比令牌桶/漏桶简单且统计精确。

**Q4：Sentinel 熔断三态？**
A：CLOSED（闭合，正常放行 + 统计） → OPEN（打开，快速失败） → HALF_OPEN（半开，放 1 个探测）。OPEN 状态等待 `timeWindow` 后进入 HALF_OPEN；HALF_OPEN 探测成功回 CLOSED，失败回 OPEN。

**Q5：三种熔断策略哪个生产首选？**
A：**慢调用比例（SLOW_REQUEST_RATIO）**——慢调用是雪崩的前兆，比纯异常更早预警。配合 `minRequestAmount`（最少请求数）防小流量误判。

**Q6：`@SentinelResource` 的 `blockHandler` 和 `fallback` 区别？**
A：
- `blockHandler`：处理 **`BlockException`**（限流 / 熔断 / 系统 / 授权）—— 接 Sentinel 主动拒绝
- `fallback`：处理 **业务异常** —— 接调用真的出错
- 都配时 blockHandler 优先

**Q7：Sentinel 规则怎么持久化？**
A：默认存内存——重启丢。接 Nacos / Apollo 作为 datasource，规则改了 Nacos 自动推到所有 client；客户端拉取也走 Nacos。**生产强制要求持久化**。

**Q8：怎么实现热点参数限流？**
A：用 `@SentinelParam(index = 0)` 标注参数（或在控制台配置规则中指定 paramIdx）。Sentinel 按参数值分别统计——可以全局阈值 + 特定值（如热门商品 ID）单独配置高阈值。秒杀场景的标准做法。

**Q9：Sentinel 性能开销大吗？**
A：很小（每次请求几十纳秒）。原因：① 信号量隔离（不像 Hystrix 默认线程池每次提交任务）；② LeapArray 用环形数组没 GC 压力；③ Slot 链都是简单计算，无 IO。生产 QPS 几万都没问题。

**Q10：Sentinel 和 Spring Cloud Gateway 集成？**
A：网关引 `spring-cloud-starter-alibaba-sentinel-gateway`，自动给 Route / API 分组埋点；规则配在控制台或 Nacos。详见 [SpringCloudGateway.md](SpringCloudGateway.md)。

---

## 十二、答题模板（60 秒）

> Sentinel 是阿里开源的流量治理组件，解决 **限流 / 熔断 / 降级 / 热点参数 / 系统保护** 5 件事。
>
> **核心架构**：Slot 责任链—— 请求进入按顺序经过 NodeSelectorSlot → StatisticSlot（实时统计）→ AuthoritySlot → SystemSlot → **FlowSlot（限流）** → **DegradeSlot（熔断）**。每个 Slot 单职责。
>
> **限流算法**：**滑动窗口 + LeapArray**。把 1 秒切成 N 个小窗口（默认 2 个），用环形数组复用槽位避免 GC，最近 N 个窗口求和判断 QPS——比固定窗口避免边界突刺。
>
> **熔断三态**：CLOSED → OPEN → HALF_OPEN。三种策略：慢调用比例（**生产首选，雪崩前兆**）/ 异常比例 / 异常数。关键参数 `minRequestAmount`（最少请求数）防小流量误熔断。
>
> **使用**：`@SentinelResource(value, blockHandler, fallback)`——blockHandler 处理限流熔断（`BlockException`），fallback 处理业务异常。两者方法签名要和原方法一致。
>
> **生产配置**：① **接 Nacos 持久化规则**（默认存内存重启丢）；② Spring Cloud / Feign 自动埋点；③ 热点参数限流秒杀必备；④ 控制台监控实时数据。
>
> **常见坑**：① `minRequestAmount` 漏配夜间误熔断；② 自调用 AOP 失效；③ fallback 方法签名错启动失败；④ 规则推到 Nacos 但控制台没接同步显示。

---

## 十三、相关文档

- 上层：[SpringCloud通用.md](SpringCloud通用.md) — Sentinel 在微服务架构中的位置
- 配套：[Feign.md](Feign.md) — Feign + Sentinel 熔断降级
- 配套：[SpringCloudGateway.md](SpringCloudGateway.md) — 网关层限流
- 配套：[Nacos.md](Nacos.md) — 规则持久化数据源
