# XXL-JOB

> 国内**分布式任务调度**事实标准——大众点评开源、社区活跃、Spring Boot 集成简单、UI 完整、轻量好用。互联网公司 80% 的定时任务（订单超时、对账、清理、报表、推送、缓存刷新）都跑在它上面。
> 本篇要解决：
> ① **跟 Quartz / ElasticJob / Spring `@Scheduled` / DolphinScheduler 的边界**——什么场景该用 xxl-job
> ② 调度中心怎么扛**百万任务 + 秒级触发不漏**——基于 MySQL 行锁的分布式调度
> ③ **9 种路由策略 + 3 种阻塞策略**怎么选，**分片广播**到底能干啥
> ④ 失败重试、超时控制、优雅关闭、调度日志、报警的工程化
> ⑤ 高可用部署、性能瓶颈、生产踩坑（任务漂移、调度延迟、DB 锁竞争、海量任务）

---

## 一、XXL-JOB 是什么 / 解决什么

**XXL-JOB 是分布式任务调度平台**——把"何时跑、跑什么、跑哪台机器、跑失败怎么办"全部抽出来，业务方只需写**任务执行逻辑**，调度由平台保证。

**为什么不用 Spring `@Scheduled`**：
- 单机单线程，**多实例部署会重复执行**（除非加分布式锁）。
- 没有可视化、没有日志、没有失败告警、改 cron 要重启发布。
- 没有任务编排（一个跑完触发下一个）。
- **小项目能用**，**业务多机部署 + 几十个任务以上必踩坑**。

**为什么不用 Quartz**：
- Quartz 也支持集群（基于 DB 行锁），但**只解决"不重复"**，没有可视化、没有路由策略、没有分片、没有日志、没有任务管理 UI。
- 大部分公司基于 Quartz 自研一套调度平台 = 重新造轮子。
- xxl-job **本质上就是 Quartz + 完整的工业化外壳**（部分版本底层确实用了 Quartz，新版自研时间轮）。

### 核心定位与场景

✅ **适合**：
- 定时任务（cron 表达式）：每天凌晨对账、定期清理过期数据。
- 一次性任务：3 分钟后发短信。
- **轮询型业务**：扫订单超时、扫退款异常。
- **批处理 + 分片**：大表分库分表批处理，按 shard 并行。
- 跨服务调度（调用 A 服务的任务，跑完触发 B 服务）。

❌ **不适合**：
- **DAG 工作流**（数仓 ETL，几十个节点依赖）→ 用 **DolphinScheduler / Airflow**。
- **实时事件触发**（用户下单后 5 分钟未付款关闭）→ 用 **MQ 延迟消息**（业务上下文里更准确，避免周期扫表）。
- **极高频任务**（毫秒级）→ xxl-job 调度中心是秒级。

---

## 二、整体架构

```
   ┌──────────────────────────────────────────────┐
   │           XXL-JOB Admin（调度中心）            │
   │   ─────────────────────                       │
   │   - 调度线程（时间轮 / Quartz）                 │
   │   - 任务路由 + 触发                            │
   │   - 调度日志记录                               │
   │   - 失败重试 / 告警                            │
   │   - 后台 UI                                   │
   └────┬─────────────────────────────────────────┘
        │ HTTP（Triple/JSON over Netty）
        │ 调度中心 → 执行器：触发任务 / 终止任务
        │ 执行器 → 调度中心：注册 / 心跳 / 回调日志
        ▼
   ┌──────────────────────────────────────────────┐
   │          Executor（执行器，业务方接入）          │
   │   ─────────────────────                       │
   │   - 任务线程池                                 │
   │   - 注册自身到 Admin                           │
   │   - 接收触发请求 → 执行 JobHandler             │
   │   - 回调结果 + 日志到 Admin                    │
   └──────────────────────────────────────────────┘
                  │
                  ▼
            数据库 / Redis / 业务接口
```

### 2.1 Admin（调度中心）

**核心职责**：
- 维护 **任务元数据**（cron 表达式、JobHandler 名、参数、路由策略、阻塞策略、超时、重试次数）。
- **触发调度**：到时间了把任务推给合适的执行器。
- **记录调度日志**：每一次触发的执行器、参数、结果、耗时、失败原因。
- **失败告警 + 重试**。

**底层依赖**：
- **MySQL**：存任务定义、执行器注册信息、调度日志（日志量大，需定时清理）。
- 没有 Redis、ZK、ETCD 等强依赖（这是 xxl-job 受欢迎的关键——**部署轻**）。

### 2.2 Executor（执行器）

业务方接入的部分。Spring Boot 应用引一个 starter：

```xml
<dependency>
    <groupId>com.xuxueli</groupId>
    <artifactId>xxl-job-core</artifactId>
    <version>2.4.0</version>
</dependency>
```

```java
@XxlJob("orderTimeoutJob")
public void orderTimeoutJob() throws Exception {
    XxlJobHelper.log("scan timeout orders start");
    int rows = orderService.cancelTimeoutOrders();
    XxlJobHelper.log("canceled rows = {}", rows);
    // 默认成功；失败抛异常或显式 XxlJobHelper.handleFail()
}
```

**执行器侧职责**：
- 启动时**注册**到 Admin（HTTP POST）+ 周期心跳（默认 30s）。
- 监听 Admin 推送的执行请求 → **任务线程池**异步执行。
- 执行结果 + 日志**回调** Admin。

---

## 三、调度核心机制 ⭐

### 3.1 一致性问题：多 Admin 部署怎么不重复触发

最难的一道题：Admin 集群部署 N 台，到点该哪台触发？怎么保证**不重复 + 不漏**？

**xxl-job 的方案：基于 MySQL 行锁的分布式调度**

```sql
-- 调度线程每秒扫一次
SELECT id, ... FROM xxl_job_lock WHERE lock_name = 'schedule_lock'
  FOR UPDATE;        -- 行锁，谁拿到谁是 leader

-- 拿到锁的 Admin 实例：
-- 1. 查询 xxl_job_info 中下次触发时间在 [now, now+5s) 的所有任务
-- 2. 下发到执行器
-- 3. 更新下次触发时间
-- 4. 提交事务（释放行锁）
```

**关键点**：
- **同一时刻只有一个 Admin 在触发**（行锁串行化）→ 不重复。
- 锁粒度小（只锁这一行）+ 持锁时间短（一次扫描完释放）→ 性能可接受。
- 多 Admin 部署的本质是**故障转移**，不是负载分担——单个 Admin 扛百万任务没问题。

### 3.2 调度线程：时间轮 vs Quartz

xxl-job **早期版本基于 Quartz**（重复造轮子嫌疑），**后续版本（2.x 起）自研时间轮**：

```
   预读未来 5 秒内要执行的任务
              ↓
   按"秒"挂到 Ring Data Map (60 个槽，类似时间轮)
              ↓
   ringThread 每秒扫描当前秒槽 → 触发
```

**Ring Data 调度线程**：
```java
// xxl-job-admin 简化伪码
while (true) {
    int nowSecond = LocalTime.now().getSecond();
    List<Integer> ringItemData = ringData.remove(nowSecond);
    for (Integer jobId : ringItemData) {
        JobTriggerPoolHelper.trigger(jobId, ...);   // 触发
    }
    Thread.sleep(1000 - System.currentTimeMillis() % 1000);  // 对齐到秒
}
```

**为什么不直接用 Quartz**：
- Quartz 内部锁多（QRTZ_LOCKS），高并发任务下 DB 锁竞争严重。
- 时间轮 + 内存预读，调度延迟稳定 < 100ms。

### 3.3 触发流程

```
1. scheduleThread (1s 周期)
   └── 从 DB 读取 [now, now+5s) 的任务
       └── 放入 ringData (按秒分组)

2. ringThread (1s 周期)
   └── 取出当前秒的任务列表
       └── 提交到 jobTriggerPool（触发线程池，默认 200/快速 + 100/慢任务）

3. JobTriggerPoolHelper.trigger
   └── 路由（按路由策略选执行器）
       └── HTTP POST /run → 执行器
           └── 执行器线程池执行 JobHandler
               └── 回调结果到 Admin（HTTP /callback）
                   └── 写调度日志 / 失败重试 / 告警
```

### 3.4 任务触发线程池（防慢任务拖死）

```yaml
# xxl-job-admin
xxl.job.triggerpool.fast.max: 200        # 快速触发线程池
xxl.job.triggerpool.slow.max: 100        # 慢触发线程池
```

**机制**：
- 每个任务每分钟**有 10 次或以上慢触发（> 500ms）** → 自动归类到慢池。
- 防止单个慢任务把快任务的线程池吃光。

---

## 四、9 种路由策略（**面试必问**）

任务触发时选哪台执行器机器执行？xxl-job 提供 9 种策略：

| 策略 | 选择规则 | 适用场景 |
| --- | --- | --- |
| **FIRST** | 选第一台 | 调试 / 单机执行 |
| **LAST** | 选最后一台 | 同上 |
| **ROUND** ⭐ | **轮询** | 均匀分布，最常用 |
| **RANDOM** | 随机 | 轻量，分布均匀（短时间会偏） |
| **CONSISTENT_HASH** | 一致性哈希（按 jobId） | 同一任务**粘性**到同一机器（缓存命中） |
| **LEAST_FREQUENTLY_USED**（LFU） | 最不常用 | 平滑负载 |
| **LEAST_RECENTLY_USED**（LRU） | 最近最少使用 | 同上，时间维度 |
| **FAILOVER** ⭐ | **故障转移**：按顺序探活，失败换下一台 | 必须执行成功的关键任务 |
| **BUSYOVER** | **忙碌转移**：探询 idleBeat（空闲），找空闲机器 | 任务耗时长 + 不能堵 |
| **SHARDING_BROADCAST** ⭐ | **分片广播** | 数据分片并行处理（重磅） |

### 4.1 FAILOVER 故障转移

```
任务触发
  ├─► 机器 A：HTTP idleBeat 探活
  │   └─ 失败/超时 → 跳过
  ├─► 机器 B：探活
  │   └─ 成功 → 触发执行
```

**关键场景**：业务关键任务必须跑成功。机器 A 挂了或重启中，自动转 B。

### 4.2 BUSYOVER 忙碌转移

类似 FAILOVER，但探测的是 `idleBeat`（执行器返回当前任务是否在跑）：
- A 正在跑同一 jobId → 跳过 → B。
- 防止单机串行堵塞。

### 4.3 SHARDING_BROADCAST 分片广播 ⭐

**用法**：调度中心**给所有执行器都触发**这个任务，每个执行器收到 `(shardIndex, shardTotal)` 参数，自己按分片处理自己负责的数据。

```java
@XxlJob("userBatchJob")
public void userBatchJob() throws Exception {
    int shardIndex = XxlJobHelper.getShardIndex();   // 当前是第几个执行器
    int shardTotal = XxlJobHelper.getShardTotal();   // 总执行器数

    // 例如有 1000w 用户，3 台执行器分片处理
    List<User> users = userMapper.selectByShard(shardIndex, shardTotal);
    for (User u : users) {
        process(u);
    }
}
```

**SQL 侧分片**：
```sql
-- 按 user_id mod 分片
SELECT * FROM users WHERE MOD(id, #{shardTotal}) = #{shardIndex}
```

**典型应用**：
- 大表批处理（百万级用户每天发推送）→ 多机器分片并行。
- 分库分表场景 → 一个执行器处理一个库 / 一组表。
- 数据修复脚本。

**对比 MQ 分片消费**：
- MQ 分片消费靠 partition + consumer group，**消息驱动**。
- xxl-job 分片广播是**调度驱动**，更适合定时全量扫描。

---

## 五、3 种阻塞处理策略

任务还没跑完，下一次又触发了，怎么办？

| 策略 | 行为 | 适用 |
| --- | --- | --- |
| **SERIAL_EXECUTION** ⭐ | **串行**：放进队列等当前跑完 | 默认，普通业务 |
| **DISCARD_LATER** | **丢弃**：直接拒绝新触发 | 幂等任务 / 不重要 |
| **COVER_EARLY** | **覆盖**：杀掉旧的 + 跑新的 | 实时性优先（推送、刷缓存） |

```yaml
# 单个 JobHandler 同时只允许一个实例运行
# SERIAL 队列默认上限 20，超了报错
xxl.job.executor.jobthread.max: 20
```

### 踩坑：SERIAL 队列堆爆

**场景**：某个任务 cron `*/5 * * * * ?`（5 秒一次），平时跑 1 秒，某天下游慢→单次跑 30 秒。
**结果**：每 5 秒来一次新触发，串行队列**积压 6 个/分钟**，1 小时积压 700+ → 队列超限报错。
**修复**：
- 长耗时任务**别用频繁 cron**（拉间隔）。
- 改 `DISCARD_LATER`（业务幂等的话）。
- 看下游是不是该优化。

---

## 六、失败处理三件套

### 6.1 失败重试

```yaml
# 任务级配置
失败重试次数: 3
```

- 失败后调度中心**自动重试**到指定次数。
- 重试间隔：默认立即（**生产建议改源码加退避**）。
- 配合 FAILOVER 路由 → 这次失败下次换台机器。

### 6.2 超时控制

```yaml
任务超时时间: 60 秒
```

- 超时后调度中心**主动 kill** 执行器侧任务（HTTP /kill → 执行器 `Thread.interrupt()`）。
- 业务代码必须**响应 interrupt**，否则 kill 不掉（这是 Java 的老问题）。

```java
// 推荐写法
while (running && !Thread.currentThread().isInterrupted()) {
    process();
}
```

### 6.3 失败告警

- 内置邮件告警（默认）。
- 自定义 `JobAlarm` 接口接钉钉/飞书/企业微信/电话。
- 告警包含：任务名、执行器、失败次数、错误日志摘要。

---

## 七、GLUE 模式（在线 IDE）

xxl-job 支持 **5 种任务类型**：
| 类型 | 说明 | 用途 |
| --- | --- | --- |
| **BEAN** ⭐ | 业务侧打 `@XxlJob` 注解 | **生产 99% 用这个** |
| GLUE_JAVA | Admin 在线写 Java 代码、保存即生效 | 临时脚本、紧急修复 |
| GLUE_GROOVY | Groovy 脚本 | 同上 |
| GLUE_PYTHON / SHELL / NODEJS | 各种脚本 | 运维任务 |

**GLUE 模式的争议**：
- ✅ 优点：紧急修复不用发版（凌晨改个 SQL 修复数据，几分钟搞定）。
- ❌ 缺点：**绕过代码评审**，权限控制不严会被滥用，安全风险大（脚本能执行任何代码）。
- 生产建议：**关闭 GLUE 模式**，或限制只有 admin 角色能用 + 强制 code review 流程。

---

## 八、参数 / 配置 / 取舍

### 8.1 Admin 配置

```yaml
spring:
  datasource:
    url: jdbc:mysql://...?useUnicode=true&characterEncoding=utf8
    hikari:
      maximum-pool-size: 30          # 调度中心 DB 连接池
      minimum-idle: 10

xxl:
  job:
    accessToken: "your-secret"        # Admin <-> Executor 认证 token，必填！
    triggerpool:
      fast:
        max: 200                      # 快任务触发线程池
      slow:
        max: 100                      # 慢任务（自动判定）触发线程池
    logretentiondays: 30              # 调度日志保留天数（重要！日志量超大）
```

### 8.2 Executor 配置

```yaml
xxl:
  job:
    admin:
      addresses: http://admin1:8080,http://admin2:8080  # 多 admin 用逗号
    accessToken: "your-secret"
    executor:
      appname: order-service
      address: ""                     # 自动发现，多网卡场景手动指定
      ip: ""                          # 默认取本机内网 IP
      port: 9999                      # 嵌入式服务端口
      logpath: /data/xxl-job/jobhandler
      logretentiondays: 30
```

### 8.3 任务线程池

```java
// 执行器侧
xxl.job.executor.jobthread.max: 20        // 单 JobHandler 最大并行（一般任务串行不需要调）
```

---

## 九、对比 / 选型

| 维度 | xxl-job | Quartz | ElasticJob | DolphinScheduler | Spring `@Scheduled` |
| --- | --- | --- | --- | --- | --- |
| 出身 | 大众点评 | OpenSymphony | 当当（已捐 Apache） | 易观（Apache） | Spring |
| 集群协调 | **DB 行锁** | DB 行锁 | **ZooKeeper** | ZooKeeper | 无（单机） |
| 部署难度 | **极轻**（Admin + DB） | 极轻 | 中（依赖 ZK） | 重（多组件） | 极轻 |
| UI | ✅ 完整 | ❌ | ✅ | ✅ 强 | ❌ |
| 任务编排 / DAG | ❌ 弱（仅父子触发） | ❌ | ❌ | ✅ **强** | ❌ |
| 分片 | ✅（广播分片） | ❌ | ✅ **核心** | ❌ | ❌ |
| 路由策略 | ✅ **9 种** | ❌ | 简单 | 简单 | ❌ |
| GLUE 在线代码 | ✅ | ❌ | ❌ | ✅（Shell/SQL） | ❌ |
| 国内热度 | **极高** | 高 | 中 | 中（数仓圈高） | 极高 |
| 适用 | **业务定时任务** | 老项目 | 中间件圈 | 数仓 ETL | 单机小项目 |

**资深建议**：
- **业务定时任务** → xxl-job（无脑选）。
- **数仓 / DAG 工作流** → DolphinScheduler / Airflow。
- **MQ 延迟消息能干的** → 不要用 xxl-job 扫表（业务上下文里触发更精准、性能好）。

---

## 十、生产踩坑

### 坑 1：调度日志爆 MySQL
**场景**：5000 个任务、平均 1 分钟一次 → 每天 720w 调度日志 → 一周后表 5000w 行 → 慢查询满天飞，磁盘报警。
**修复**：
- `logretentiondays: 7` 自动清理（默认 30 天太长）。
- `xxl_job_log` 表加合适索引（trigger_time + job_id）。
- 海量任务环境，**调度日志独立 DB 实例**（跟业务库隔离）。
- 极致：日志写 Elasticsearch，MySQL 只留索引/状态。

### 坑 2：MySQL 行锁竞争 → 调度延迟飙升
**场景**：任务数 5w+，多 Admin 实例 → DB 上 `xxl_job_lock` `FOR UPDATE` 串行，每秒只能跑一轮调度，超过的任务延迟。
**修复**：
- 不要部署过多 Admin（**2~3 台足够，多了反而慢**）。
- 拆分多个 xxl-job 集群（按业务域）。
- 数据库用 SSD + 性能足够的实例。
- 极致：换 ElasticSearch 调度集中度更高的方案（自研或 ElasticJob）。

### 坑 3：执行器优雅关闭丢任务
**场景**：发布期间执行器 kill 时，正在跑的任务被强制中断（数据写一半）。
**修复**：
- 启 `Tomcat shutdown hook` + xxl-job-core 已有的优雅关闭逻辑（最多等 60s）。
- 业务代码：长任务**周期性**检查 `Thread.currentThread().isInterrupted()`，到点保存 checkpoint。
- 重要任务用**幂等 + 重试**保证。

### 坑 4：任务漂移 / 不准时
**场景**：任务设置 `0 0 * * * ?`（每小时整点），但实际经常 0 分 1~3 秒才触发。
**根因**：
- 调度中心扫描周期 1 秒。
- 网络延迟 + DB 锁 + 触发线程池调度 → 总延迟 100~3000ms。
**修复**：
- 业务接受秒级精度（xxl-job 不是毫秒级调度框架）。
- 真要毫秒级 → 用执行器内部基于内存的定时器（DelayQueue / HashedWheelTimer）。

### 坑 5：海量短任务，触发线程池爆
**场景**：5w+ 任务每分钟一次 → 每秒触发 800+ → fast 池满 → 排队 → 慢任务自动归类到 slow 池也满。
**修复**：
- 拉大 `triggerpool.fast.max`（如 500）。
- 把短任务**合并成批任务**（SHARDING_BROADCAST 分片处理）。
- 拆 xxl-job 集群。

### 坑 6：分片广播分片不均
**场景**：3 台执行器，分片广播按 `user_id % 3`，但用户分布不均（有大客户/僵尸 ID）→ 一台跑 4 小时，两台 1 小时。
**修复**：
- 分片维度用更均匀的 hash（如 `id` 哈希后取模而非直接取模）。
- 分片粒度更细（5w 用户 → 用 100 个分片标号，3 台执行器各取 33 个）。
- 执行器侧业务**自我限流**避免单实例压垮下游。

### 坑 7：accessToken 没配 → 任意接入伪造任务
**场景**：开发环境 Admin 没配 accessToken → 攻击者扫到 8080 端口 → 注册恶意执行器 → 拿走调度中心信任。
**修复**：**accessToken 必须配**，所有 Admin <-> Executor HTTP 调用都带这个 token 校验。

### 坑 8：执行器 IP 取错（多网卡 / 容器化）
**场景**：K8s Pod 内执行器自动注册的 IP 是 Pod IP（10.x.x.x），调度中心调不通。
**修复**：
- 显式配 `xxl.job.executor.ip: ${POD_IP}`。
- 或使用 Service Name + ClusterIP。
- 容器化建议改用 sidecar 暴露 NodePort。

### 坑 9：log4j2 漏洞（2.4.0 之前）
**背景**：xxl-job 历史版本依赖过 log4j2 1.2.x，存在 RCE 漏洞。
**修复**：升级到 2.4.0+ 或自行替换 log4j 版本。

### 坑 10：调度中心单 DB 成单点
**场景**：调度中心连的 MySQL 主节点宕机 → 所有任务停摆。
**修复**：
- MySQL 必须主从（最好 MHA / Orchestrator 自动切）。
- 业务侧**关键任务**有兜底——如订单超时业务里再加一层 Redis 自检（不完全依赖调度中心）。

---

## 十一、面试高频追问

**Q1：xxl-job 跟 Quartz 啥区别？**
Quartz 只是个 Java 调度库，提供 cron 解析 + 集群锁。xxl-job 是**完整的调度平台**——Admin UI + 执行器隔离 + 9 种路由 + 分片广播 + 失败告警 + 在线日志。Quartz 解决"啥时候触发"，xxl-job 解决"调度的工程化方方面面"。

**Q2：调度中心怎么保证多实例不重复调度？**
基于 **MySQL 行锁**（`SELECT FOR UPDATE` `xxl_job_lock`）—— 同一时刻只有一个 Admin 持锁扫任务、触发。其他 Admin 只是热备，故障转移用。这种方案优点是**轻**（不依赖 ZK/ETCD），缺点是 DB 锁会成为大集群瓶颈。

**Q3：调度延迟有多大？**
正常情况 < 1 秒。极端场景（DB 锁竞争 / 触发线程池爆）可能 5~10 秒。**xxl-job 是秒级调度，不是毫秒级**——毫秒级精度需求要在执行器内自己做。

**Q4：路由策略选哪个？**
- 普通任务：**ROUND**（轮询）。
- 关键任务：**FAILOVER**（故障转移）。
- 长耗时不能堵：**BUSYOVER**。
- 数据并行处理：**SHARDING_BROADCAST**。
- 缓存粘性：**CONSISTENT_HASH**。
- 别用 FIRST/LAST，那是调试用的。

**Q5：分片广播怎么实现的？**
调度中心**遍历执行器列表**，给每台都触发该任务，通过 HTTP 参数把 `(shardIndex, shardTotal)` 传给执行器。执行器侧通过 `XxlJobHelper.getShardIndex()` 拿到自己的编号，按编号处理自己分片的数据（典型用法 `MOD(id, shardTotal) = shardIndex`）。

**Q6：分片广播 vs MQ 分片消费？**
- **分片广播**：调度驱动 + 全量扫描（"凌晨扫所有用户"）。
- **MQ 分片消费**：消息驱动 + 单条事件（"用户下单后异步处理"）。
- 业务上：周期性扫表用分片广播，事件触发用 MQ。

**Q7：阻塞策略 SERIAL/DISCARD/COVER 怎么选？**
- **SERIAL**（串行，默认）：普通业务，按到达顺序排队。
- **DISCARD**（丢弃）：当前还在跑就拒绝新的，**幂等任务**用。
- **COVER**（覆盖）：杀旧跑新，**实时性优先**（如缓存刷新）。
- 老任务跑超时常态化 → 看是优化下游还是改阻塞策略。

**Q8：失败重试机制？**
任务失败后调度中心自动重试（次数任务级配置），重试间隔默认立即（生产建议加退避）。配合 FAILOVER 路由：每次重试自动选下一台健康执行器。

**Q9：任务执行超时怎么 kill？**
调度中心超时后发 HTTP `/kill` 给执行器 → 执行器对线程 `interrupt()`。**业务代码必须响应 interrupt**——比如 `while(!Thread.currentThread().isInterrupted())`，否则 kill 不掉（Java 的限制）。`Thread.sleep()` 会自动响应中断抛 InterruptedException，但 IO 阻塞、while(true) 不会。

**Q10：Admin 高可用？**
多实例 + 同一个 MySQL。Admin 之间无状态，靠 DB 行锁选 leader 调度。前面挂 LB（域名或 Nginx）让执行器 + 用户 UI 访问。**注意 MySQL 是单点**，必须主从 + 自动切换。

**Q11：执行器高可用？**
执行器多实例部署 → 路由策略选 ROUND / FAILOVER → 单台挂掉自动转其他实例。注册中心是 Admin（HTTP 心跳），心跳超时 90s 自动下线。

**Q12：调度日志爆库怎么办？**
- 缩短保留时间 `logretentiondays: 7`。
- 调度日志独立 DB 实例。
- 海量场景换 ES 存日志。
- 业务侧别滥用调度（高频 + 大量任务自然日志多）。

**Q13：xxl-job 适合做秒级实时调度吗？**
不适合，xxl-job 调度精度秒级。**毫秒级 / 秒级实时性**用：
- 内存定时器（DelayQueue / HashedWheelTimer / Netty Timer）。
- MQ 延迟消息（RocketMQ delayLevel / RabbitMQ TTL+DLQ）。
- 调度中心适合分钟级及以上 + 跨服务编排。

**Q14：怎么实现"用户下单 30 分钟未付款关闭"？**
**不用 xxl-job 扫表**：扫表方案数据量大时性能差、最坏延迟 = 扫描周期。
**正确方案**：MQ 延迟消息（下单时发一条 30 分钟的延迟消息）、Redis ZSet（score = 截止时间）+ 后台扫，或 Redisson 延时队列。

**Q15：xxl-job 跟 DolphinScheduler 怎么选？**
- xxl-job：**业务定时任务**（订单扫描、对账、批处理），轻量、好集成。
- DolphinScheduler：**数仓 / 大数据 ETL** + DAG 编排（Hive / Spark / Flink），重，但 DAG 强。
- **互联网业务后台**用 xxl-job，**数据团队**用 DolphinScheduler，分工明确。

**Q16：在线 GLUE 模式安全吗？**
不太安全，相当于给 Admin 一个**远程代码执行**入口。生产建议：① 关掉 GLUE；② 必须开就严格权限控制 + 审计日志 + code review 流程。紧急修复用过一次后立即落到正式发布。

**Q17：xxl-job 调度中心存 MySQL，能换其他 DB 吗？**
源码里写死了 MySQL 方言（部分 SQL），换 PG / Oracle 要改源码（GitHub 有社区分支）。生产基本都用 MySQL。

---

## 十二、答题模板（60 秒话术）

> "xxl-job 是国内分布式任务调度的事实标准——大众点评开源，社区活跃，部署轻（只需 Admin + MySQL，不依赖 ZK），UI 完整。
>
> **架构**：调度中心 Admin（管任务定义 + 触发 + 日志）+ 执行器 Executor（业务方接入 + 跑任务）。两者通过 HTTP 通信，靠 accessToken 认证。
>
> **调度核心**：Admin 多实例部署时，靠 **MySQL 行锁**（`xxl_job_lock` 表 `FOR UPDATE`）保证同一时刻只有一个 Admin 在调度——不重复、不漏。新版 Admin **自研时间轮**（取代 Quartz），1 秒预读未来 5s 任务挂到 ringData，每秒触发，调度延迟稳定 < 1s。
>
> **9 种路由策略**：ROUND（默认轮询）/ FAILOVER（故障转移）/ BUSYOVER（忙碌转移）/ CONSISTENT_HASH（粘性）/ **SHARDING_BROADCAST**（分片广播，所有执行器都触发，按 shardIndex/shardTotal 分片处理大数据）。**3 种阻塞策略**：SERIAL（默认串行）/ DISCARD（幂等任务用）/ COVER（实时刷新用）。
>
> **失败处理三件套**：失败重试（次数 + FAILOVER 自动换机器）+ 超时控制（`Thread.interrupt()` kill）+ 邮件/钉钉告警。
>
> **生产踩坑 TOP 3**：
> ① **调度日志爆库**：`logretentiondays` 默认 30 天太长，海量任务一周就把表撑爆。
> ② **DB 行锁竞争**：Admin 部署超过 3 台反而慢，瓶颈在 MySQL `FOR UPDATE`，建议拆集群。
> ③ **任务执行超时 kill 不掉**：业务代码必须响应 `Thread.interrupt()`，否则只能等线程跑完。
>
> **选型边界**：业务定时任务用 xxl-job；DAG 工作流用 DolphinScheduler；事件驱动（订单超时关闭）用 MQ 延迟消息别用扫表。"

---

## 十三、相关文档

- [Concurrency / 线程池](../Concurrency/线程池.md) — Executor 任务线程池原理
- [Concurrency / 阻塞队列](../Concurrency/阻塞队列.md) — 串行队列底层
- [MQ / 延迟消息](../MQ/延迟消息.md) — 事件驱动延时方案对比 xxl-job 扫表
- [MQ / RocketMQ 架构](../MQ/RocketMQ架构.md) — MQ 替代周期扫表的典型场景
- [Distributed / 分布式锁](../Distributed/分布式锁.md) — xxl-job DB 行锁 vs Redis/ZK 锁
- [Distributed / 一致性哈希](../Distributed/一致性哈希.md) — CONSISTENT_HASH 路由策略原理
- [Microservice / 服务注册与发现](../Microservice/服务注册与发现.md) — xxl-job 执行器自注册机制
- [MySQL / 锁机制](../MySQL/锁机制.md) — `SELECT FOR UPDATE` 行锁原理
