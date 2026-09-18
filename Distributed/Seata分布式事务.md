# Seata 分布式事务

> 阿里开源、国内分布式事务事实标准。
> 这道题面试的"段位差"在三点：
> ① 能不能讲清 **AT 模式的 undo_log 自动补偿原理**（这是 Seata 的灵魂创新）
> ② 能不能讲清 **AT / TCC / Saga / XA 4 种模式各自适合什么**
> ③ 能不能讲清 Seata 在 **生产里的真实坑**（hot row、性能、隔离级别）
> 答得清这三块就是高级。

---

## 一、为什么需要分布式事务

### 1.1 痛点

```java
@Transactional
public void createOrder(Order order) {
    orderDao.insert(order);              // 库 A：订单库
    inventoryService.deduct(order);      // 库 B：库存库（远程调用）
    pointsService.deduct(order);         // 库 C：积分库（远程调用）
}
```

`@Transactional` **只保证本地数据库**——库 A 和库 B / C 之间没有事务保证：
- 订单插入成功但库存扣减失败 → **超卖**
- 库存扣减成功但积分调用超时 → **状态不一致**
- 积分调用成功但本地事务 commit 失败 → **多扣积分**

### 1.2 分布式事务的难点

CAP 定理决定不可能既强一致又高可用：

| 方案 | 一致性 | 可用性 | 代价 |
| --- | --- | --- | --- |
| **2PC / XA** | 强 | 低（阻塞） | DB 必须支持 XA、性能差 |
| **TCC** | 强 | 中 | 业务侵入（写 try / confirm / cancel） |
| **Saga** | 弱（最终） | 高 | 业务写补偿事务 |
| **本地消息表** | 弱（最终） | 高 | 业务自己写表和扫描 |
| **MQ 事务消息** | 弱（最终） | 高 | 依赖 MQ |
| **Seata AT** | 中 | 高 | 自动补偿、需 undo_log 表 |

> **核心权衡**：业务能容忍多久"不一致"——能容忍秒级到分钟级，用最终一致；不能（如金融交易），用 TCC / XA。

---

## 二、Seata 架构

```
┌──────────────────────────────────────────────────────────┐
│                    TC (Transaction Coordinator)           │
│                    事务协调者（Seata Server，独立部署）   │
│                    持久化全局事务、协调 commit / rollback │
└─────────────────────────┬────────────────────────────────┘
                           │
                           │ TM 注册全局事务 + RM 注册分支事务
                           │
       ┌───────────────────┼───────────────────┐
       │                   │                   │
       ▼                   ▼                   ▼
   ┌────────┐         ┌────────┐         ┌────────┐
   │ 服务 A  │         │ 服务 B  │         │ 服务 C  │
   │  TM    │ ──→ 调用 │  RM    │ ──→ 调用 │  RM    │
   └────────┘         └────────┘         └────────┘
   订单服务            库存服务            积分服务
   
TM (Transaction Manager)：发起全局事务的地方（@GlobalTransactional 标注的方法）
RM (Resource Manager)：管理本地资源（DB），向 TC 注册分支事务
TC (Transaction Coordinator)：决定全局事务最终 commit / rollback
```

### 2.1 三大角色

| 角色 | 职责 | 谁扮演 |
| --- | --- | --- |
| **TC** | 协调中心 | Seata Server（独立部署） |
| **TM** | 全局事务发起方 | 入口服务（如订单服务） |
| **RM** | 资源管理方 | 每个数据库参与方（订单库、库存库、积分库） |

### 2.2 全局事务 ID（XID）

TM 发起全局事务时 TC 生成 XID，通过 RPC 上下文（HTTP Header / Dubbo Attachment）传递到所有下游 → 每个 RM 用同一个 XID 注册分支事务。

---

## 三、AT 模式（默认、生产主流）

**AT = Automatic Transaction**——Seata 的招牌创新，**业务零侵入**。

### 3.1 核心思想

```
执行业务 SQL 前   → 解析 SQL，查询当前数据（前置镜像）
执行业务 SQL      → 数据库本地事务
执行业务 SQL 后   → 查询新数据（后置镜像）
将前后镜像存入 undo_log 表
```

如果全局事务要回滚——根据 undo_log **反向生成补偿 SQL** 执行。

### 3.2 工作流程

```
========== Phase 1：执行业务 SQL ==========

TM:  @GlobalTransactional
     orderService.create()
     │
     ├─ TC：注册全局事务 → 生成 XID = "1.2.3"
     │
     ├─ 调用 RM-A（订单库）
     │  ├─ 解析 SQL 拿到 BeforeImage（执行前数据）
     │  ├─ 执行业务 SQL（INSERT INTO orders ...）
     │  ├─ 解析 SQL 拿到 AfterImage（执行后数据）
     │  ├─ 把 BeforeImage + AfterImage 写入 undo_log 表
     │  └─ 提交本地事务（业务 SQL + undo_log 一起 commit）
     │  └─ 向 TC 注册分支事务
     │
     ├─ 调用 RM-B（库存库）  → 同上
     │
     └─ 调用 RM-C（积分库）  → 同上

========== Phase 2：全局 commit / rollback ==========

成功路径（commit）：
   TC：通知所有 RM "可以删 undo_log 了"
   RM：异步删除 undo_log（释放空间）
   ✅ 完成

失败路径（rollback）：
   TC：通知所有 RM "回滚"
   RM：根据 undo_log 反向生成补偿 SQL（INSERT ↔ DELETE / UPDATE 用 BeforeImage 还原）
   RM：在新事务里执行补偿 SQL
   RM：删除 undo_log
   ✅ 完成
```

### 3.3 undo_log 表结构

```sql
CREATE TABLE undo_log (
    id            BIGINT(20) NOT NULL AUTO_INCREMENT,
    branch_id     BIGINT(20) NOT NULL,
    xid           VARCHAR(100) NOT NULL,
    context       VARCHAR(128) NOT NULL,
    rollback_info LONGBLOB NOT NULL,         -- 序列化的前后镜像
    log_status    INT(11) NOT NULL,
    log_created   DATETIME NOT NULL,
    log_modified  DATETIME NOT NULL,
    UNIQUE KEY ux_undo_log (xid, branch_id)
);
```

**关键点**：业务 SQL 和 undo_log **在同一个本地事务**里——保证镜像和实际数据一致。

### 3.4 业务代码

```java
// TM（事务发起方）
@GlobalTransactional(timeoutMills = 30_000, rollbackFor = Exception.class)
public void createOrder(Order order) {
    orderDao.insert(order);
    inventoryClient.deduct(order);     // Feign 调用，XID 自动透传
    pointsClient.deduct(order);
}

// RM（参与方）
@Transactional
public void deduct(Order order) {
    inventoryDao.update("...");        // Seata 自动拦截解析
}
```

**业务零侵入**：只在入口加 `@GlobalTransactional`，参与方用普通 `@Transactional`——Seata 通过 `DataSourceProxy` 代理 JDBC 连接，自动写 undo_log。

### 3.5 写隔离 / 读隔离

**写隔离**：同一行被多个全局事务并发更新时，Seata 用**全局锁**（在 TC 上）保证串行。

```
事务 1：UPDATE balance SET v = v - 100 WHERE id = 1   → 拿全局锁
事务 2：UPDATE balance SET v = v - 50  WHERE id = 1   → 等待全局锁
                                                          ↓
                                                       超时拿不到 → 回滚
```

**读隔离**：默认 **读未提交**——其他事务能看到中间状态。要读已提交用 `SELECT ... FOR UPDATE`（Seata 会拿全局锁）。

> **生产警告**：写隔离用全局锁——**hot row（爆款商品库存）会成性能瓶颈**。

---

## 四、TCC 模式

**TCC = Try / Confirm / Cancel**——业务方手写三阶段。

### 4.1 三个阶段

```
Try     ：预留资源（如冻结库存）
Confirm ：确认（真正扣减）
Cancel  ：取消（释放冻结）
```

### 4.2 业务代码示例

```java
@LocalTCC                              // ★ TCC 接口标识
public interface InventoryTccService {
    
    @TwoPhaseBusinessAction(name = "deduct", commitMethod = "confirm", rollbackMethod = "cancel")
    boolean tryDeduct(@BusinessActionContextParameter(paramName = "itemId") Long itemId,
                       @BusinessActionContextParameter(paramName = "count") int count);
    
    boolean confirm(BusinessActionContext ctx);
    boolean cancel(BusinessActionContext ctx);
}

@Service
public class InventoryTccServiceImpl implements InventoryTccService {
    @Override
    @Transactional
    public boolean tryDeduct(Long itemId, int count) {
        // ① 检查库存
        // ② 冻结库存（available -= count, frozen += count）
        return inventoryDao.tryDeduct(itemId, count) > 0;
    }
    
    @Override
    @Transactional
    public boolean confirm(BusinessActionContext ctx) {
        Long itemId = (Long) ctx.getActionContext("itemId");
        int count = (int) ctx.getActionContext("count");
        // 真正扣减（frozen -= count）
        inventoryDao.confirm(itemId, count);
        return true;
    }
    
    @Override
    @Transactional
    public boolean cancel(BusinessActionContext ctx) {
        Long itemId = (Long) ctx.getActionContext("itemId");
        int count = (int) ctx.getActionContext("count");
        // 释放冻结（available += count, frozen -= count）
        inventoryDao.cancel(itemId, count);
        return true;
    }
}
```

### 4.3 TCC 三大问题

| 问题 | 含义 | 解法 |
| --- | --- | --- |
| **空回滚** | Try 没执行（如服务挂了），TC 仍然让 Cancel —— Cancel 找不到要回滚的数据 | Cancel 时先查事务表确认 Try 是否执行过 |
| **悬挂** | Try 因网络问题超时，TC 让 Cancel 先执行；之后 Try 才到达 → 资源泄漏 | Try 执行前先查事务表确认 Cancel 是否已执行 |
| **幂等** | Confirm / Cancel 被重复调用 | 维护事务状态表，已处理则跳过 |

> 防三大问题的标准做法：**事务控制表**（XID + branchId + 状态）—— Try / Confirm / Cancel 都先查表再操作。

### 4.4 TCC vs AT

| 维度 | AT | TCC |
| --- | --- | --- |
| 业务侵入 | 零 | **高**（写 3 个方法） |
| 隔离级别 | 默认读未提交 | 读已提交（资源已冻结） |
| 性能 | 中（需要快照 + 全局锁） | **高**（不需要快照） |
| 适用 | 大多数业务 | **金融、强一致、高并发** |

---

## 五、Saga 模式

长事务场景（订单可能跨天）—— AT / TCC 都不适合。

```
事务步骤：T1 → T2 → T3 → ... → Tn
补偿步骤：C1 ← C2 ← C3 ← ... ← Cn   （某个 Ti 失败时，回滚已完成的）
```

### 5.1 适用场景

- 订单履约（下单 → 支付 → 发货 → 签收）
- 旅游预订（订机票 → 订酒店 → 订接送）
- 长流程审批

### 5.2 Saga 与 TCC 区别

- TCC：每步先冻结资源（Try），最终统一确认或释放
- Saga：每步直接做实际操作，失败靠补偿事务回滚（`已扣 100 元 → 补偿事务退 100`）

**问题**：补偿期间数据可能短暂不一致；补偿事务可能失败（需要重试）。

---

## 六、XA 模式

基于数据库原生 XA 协议——两阶段提交。

| 维度 | 说明 |
| --- | --- |
| 一致性 | **强**（DB 保证） |
| 性能 | 差（事务阻塞、资源锁占用长） |
| 业务侵入 | 零 |
| 数据库要求 | 必须支持 XA（MySQL ✅、PostgreSQL ✅） |
| 适用 | 跨多 DB 强一致需求、性能要求不高 |

> **互联网业务几乎不用 XA**——性能太差。金融核心系统才用。

---

## 七、模式选型决策

```
分布式事务需求？
    │
    ├─ 强一致 + 跨数据库 + 性能不敏感 → XA
    │
    ├─ 强一致 + 高并发 + 业务能改 → TCC
    │
    ├─ 中等一致性 + 业务零侵入 → Seata AT（默认推荐）
    │
    ├─ 长流程 + 弱一致性 → Saga
    │
    └─ 最终一致 + 不想引入 Seata → MQ 事务消息 / 本地消息表
```

| 场景 | 推荐 |
| --- | --- |
| 订单 + 库存 + 积分（互联网常见） | **Seata AT** |
| 金融转账（A 减、B 加） | **TCC** 或 XA |
| 复杂订单履约 | Saga |
| 跨语言系统 | MQ 事务消息（Seata 主要 Java） |
| 简单业务无需引入新组件 | **本地消息表**（业务自己写） |

---

## 八、生产配置

### 8.1 业务方接入

```xml
<dependency>
    <groupId>io.seata</groupId>
    <artifactId>seata-spring-boot-starter</artifactId>
</dependency>
```

```yaml
seata:
  enabled: true
  application-id: order-service
  tx-service-group: my_tx_group
  config:
    type: nacos
    nacos:
      server-addr: 127.0.0.1:8848
      data-id: seataServer.properties
  registry:
    type: nacos
    nacos:
      application: seata-server
      server-addr: 127.0.0.1:8848
```

### 8.2 数据源代理

Seata AT 需要 `DataSourceProxy` 代理你的 DataSource——starter 默认自动代理。

```java
// 关闭自动代理（自定义场景）
@Bean
public DataSource dataSource(DataSource druidDataSource) {
    return new DataSourceProxy(druidDataSource);
}
```

### 8.3 undo_log 表（每个业务库都要建）

```sql
-- 每个参与 AT 的数据库都要建
CREATE TABLE undo_log (
    branch_id     BIGINT NOT NULL,
    xid           VARCHAR(100) NOT NULL,
    context       VARCHAR(128) NOT NULL,
    rollback_info LONGBLOB NOT NULL,
    log_status    INT NOT NULL,
    log_created   DATETIME(6) NOT NULL,
    log_modified  DATETIME(6) NOT NULL,
    UNIQUE KEY ux_undo_log (xid, branch_id)
) ENGINE = InnoDB AUTO_INCREMENT = 1 DEFAULT CHARSET = utf8mb4;
```

---

## 九、生产踩坑

### 坑 1：hot row 性能瓶颈

爆款商品库存——所有订单都更新同一行 `inventory.id=1`。Seata AT 全局锁让这些事务串行——QPS 直接掉到 100/s。

**修法**：
- ① 改 TCC（不要全局锁，靠业务幂等）
- ② 库存预热 + Redis 扣减（DB 异步同步）
- ③ 拆分热点（一个 SKU 拆成 100 个虚拟库存行）

### 坑 2：undo_log 没清理导致库膨胀

异常场景下 undo_log 没被清理——库越来越大，几个月后磁盘报警。

**修法**：
- ① Seata 1.4+ 默认有 undo_log 自动清理
- ② 定期跑脚本清理 `log_status = 1` 且 `log_created < NOW() - INTERVAL 7 DAY`

### 坑 3：跨库 SQL 不支持

Seata AT 解析 SQL 抓镜像——某些 SQL 解析器不支持：
- 多表 join 的 UPDATE
- 子查询
- 存储过程
- 某些 DDL

**修法**：① 改写 SQL 拆成多条；② 不能改的用 `@GlobalLock` + 业务自己保证一致。

### 坑 4：默认读未提交导致脏读

`SELECT * FROM balance` —— 看到的是其他事务还没确认的中间值。

**修法**：① 用 `SELECT ... FOR UPDATE`（Seata 会拿全局锁，读已提交）；② 或换成 TCC 模式。

### 坑 5：XID 没透传

Feign 调用没经过 Seata 拦截器，下游 RM 不知道全局事务——下游本地 commit 后无法回滚。

**修法**：
- 用 `seata-spring-boot-starter` 自动配置（Feign / RestTemplate / Dubbo 都自动透传）
- 检查 `RequestInterceptor` 是否注册

### 坑 6：Seata Server 单点故障

TC 是协调中心——挂了所有全局事务都进行不下去。

**修法**：Seata Server 集群部署（3 节点）+ 后端用 DB / Redis / Raft 模式存储事务状态。

### 坑 7：性能跌一半

引入 Seata AT 后单接口 RT 从 50ms 涨到 100ms+。

**根因**：每个分支事务都要和 TC 通信（注册分支、上报状态）+ 写 undo_log。

**修法**：
- ① 不需要分布式事务的方法别用 `@GlobalTransactional`
- ② 减少分支数（合并接口）
- ③ TC 集群部署 + 同机房

### 坑 8：TCC 接口实现不幂等

Confirm 被网络重试——同一笔订单被扣两次款。

**修法**：每个 TCC 接口都要查事务状态表确认是否已处理；用 XID + branchId 作为幂等键。

---

## 十、面试高频追问

**Q1：分布式事务的 4 种模式？**
A：① **XA**（DB 原生两阶段提交，强一致、性能差）；② **TCC**（Try / Confirm / Cancel，业务侵入、性能好）；③ **AT**（Seata 自动补偿、业务零侵入、默认推荐）；④ **Saga**（长流程、补偿事务、最终一致）。**互联网项目 90% 用 AT 或 MQ 最终一致**。

**Q2：Seata AT 的核心原理？**
A：通过 `DataSourceProxy` 代理 JDBC 连接，在执行业务 SQL **前后** 解析数据生成镜像（BeforeImage / AfterImage），把镜像存到 `undo_log` 表，与业务 SQL **在同一本地事务里 commit**。全局事务 commit 时异步删 undo_log；rollback 时根据 undo_log 反向生成补偿 SQL 执行。**业务零侵入**。

**Q3：AT 和 TCC 的区别？**
A：① **侵入性**：AT 零侵入、TCC 写 3 个方法；② **隔离性**：AT 默认读未提交（要 `FOR UPDATE` 才读已提交）、TCC 资源已冻结读已提交；③ **性能**：AT 中（写镜像 + 全局锁）、TCC 高；④ **适用**：AT 大多数场景，TCC 金融 / 强一致 / 高并发。

**Q4：为什么 AT 模式默认读未提交？**
A：因为 AT 是"先 commit 本地事务、出错再补偿"的乐观策略—— 数据已经落库了，其他事务能看到。要读已提交必须用 `SELECT ... FOR UPDATE`，Seata 会拿全局锁让 select 等到事务结束。

**Q5：Seata 的全局锁怎么实现？**
A：TC 维护一张全局锁表（`lock_table`），key 是 `tableName + pkValue`。RM 注册分支事务时把要修改的行 key 上报给 TC，TC 检查是否被其他全局事务持有——是则等待 / 回滚。**hot row 是性能瓶颈**——所有事务串行。

**Q6：TCC 的三大问题？**
A：① **空回滚**：Try 没执行 Cancel 来了；② **悬挂**：Cancel 先于 Try 到达；③ **幂等**：Confirm / Cancel 被重复调用。解法都是维护**事务状态表**——每次操作前查 XID + branchId 的状态。

**Q7：Saga 和 TCC 区别？**
A：TCC 先冻结资源（Try）再统一确认；Saga 直接做实际操作，失败靠补偿事务（已扣 100 → 退 100）。Saga 适合**长流程**、TCC 适合**强一致 + 短流程**。

**Q8：Seata 的 TC 单点怎么办？**
A：TC 集群部署 + 后端存储用 DB / Redis / Raft（Seata 1.5+）。生产**至少 3 节点**——主节点挂了从节点接管，事务状态不丢。

**Q9：分布式事务一定要用 Seata 吗？**
A：**不一定**。最终一致性场景（订单 + 通知）用 **MQ 事务消息**或**本地消息表**更轻量，不需要引入 Seata 这种重组件。Seata 适合**强中一致 + 多服务参与 + 业务零侵入**的场景。

**Q10：Seata 的性能开销？**
A：每个分支事务有 ~10-30ms 额外开销（注册分支 + 写 undo_log + 上报状态）。10 个分支的全局事务可能比单库事务慢 100ms+。**用 Seata 的前提是业务能容忍这个开销**——金融秒杀场景宁可用 TCC（不写 undo_log）。

---

## 十一、答题模板（60 秒）

> 分布式事务有 4 种主流模式：① **XA**（DB 原生两阶段、强一致、性能差）；② **TCC**（Try / Confirm / Cancel，业务侵入但性能好）；③ **Seata AT**（自动补偿、零侵入，默认推荐）；④ **Saga / MQ 最终一致**（弱一致、长流程）。
>
> **Seata AT 核心**：`DataSourceProxy` 代理 JDBC，**业务 SQL 前后解析数据生成 BeforeImage / AfterImage**，与业务 SQL **同一本地事务里 commit 到 undo_log 表**。全局 commit 时异步删 undo_log；rollback 时按 undo_log 反向生成补偿 SQL 执行。**业务零侵入**——只需在入口加 `@GlobalTransactional`。
>
> **三大角色**：① **TC**（Transaction Coordinator）独立部署的协调中心；② **TM** 全局事务发起方；③ **RM** 资源管理方（每个 DB）。XID 通过 RPC 上下文（HTTP Header / Dubbo）自动透传。
>
> **写隔离用全局锁**——TC 上对修改的行加锁让多事务串行——**hot row（爆款库存）是性能瓶颈**。**读默认读未提交**，要读已提交用 `SELECT ... FOR UPDATE`。
>
> **生产高频坑**：① hot row 性能差（改 TCC 或 Redis 扣减）；② undo_log 没清膨胀；③ 不支持多表 join UPDATE / 存储过程；④ XID 没透传 → 下游不知道事务；⑤ TC 单点必须集群（≥ 3 节点）。
>
> **选型**：互联网项目 90% **AT** 或 **MQ 最终一致**；金融强一致用 **TCC**；跨库强一致用 **XA**；长流程用 **Saga**。

---

## 十二、相关文档

- 上层：[SpringCloud通用.md](SpringCloud通用.md) — 分布式事务在微服务中的位置
- 前置：[Spring事务.md](Spring事务.md) — 本地事务原理
- 配套：[../MySQL/事务的原理.md](../MySQL/事务的原理.md) — 数据库事务底层
- 配套：[../MQ/](../MQ/) — MQ 事务消息 / 最终一致方案
- 配套：[Distributed 模块](./README.md) — CAP / 分布式系统理论
