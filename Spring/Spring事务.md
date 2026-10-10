# Spring 事务

> **大厂面试必考 TOP 3**。
> `@Transactional` 大家都会用，但 80% 的人讲不清三件事：
> ① **失效的 8 大场景**（生产 P0 事故的高频根因）
> ② **7 种传播行为** 和它们在嵌套调用里的真实表现
> ③ `@Transactional` 的 **AOP 实现链路**（凭什么靠注解就能开/提交事务）
> 答得出这三块就是高级。

---

## 一、Spring 事务在解决什么

JDBC 原生事务长这样：

```java
Connection conn = dataSource.getConnection();
try {
    conn.setAutoCommit(false);
    PreparedStatement p1 = conn.prepareStatement("UPDATE acc SET bal = bal - ? WHERE id = ?");
    p1.setBigDecimal(1, amt); p1.setLong(2, fromId); p1.executeUpdate();
    PreparedStatement p2 = conn.prepareStatement("UPDATE acc SET bal = bal + ? WHERE id = ?");
    p2.setBigDecimal(1, amt); p2.setLong(2, toId); p2.executeUpdate();
    conn.commit();
} catch (SQLException e) {
    conn.rollback();
    throw e;
} finally {
    conn.close();
}
```

**痛点**：
1. 每个方法都要写一遍 try-catch-rollback，**80% 是模板代码**
2. 多数据源时连接难管理
3. 嵌套调用（A 调 B 调 C）传不传事务、新开事务还是合并事务，**全靠开发者手工管理**——错一个就是数据不一致
4. 业务和事务管理代码耦合

Spring 事务的本质是 **用 AOP 把上面这套模板代码抽出去**，业务代码只剩一行 `@Transactional`。

---

## 二、事务管理三层抽象

```
┌──────────────────── 编程模型 ────────────────────┐
│  ① 声明式：@Transactional（推荐）                  │
│  ② 编程式：TransactionTemplate.execute(...)       │
│  ③ 原始式：PlatformTransactionManager 手动调       │
└──────────────────────┬──────────────────────────┘
                       │
                       ▼
┌─────────── PlatformTransactionManager ───────────┐
│  接口：getTransaction / commit / rollback         │
│  实现：                                           │
│    DataSourceTransactionManager     (JDBC)        │
│    JpaTransactionManager            (JPA)         │
│    HibernateTransactionManager      (Hibernate)   │
│    JtaTransactionManager            (XA 分布式)   │
│    R2dbcTransactionManager          (响应式)      │
└──────────────────────┬──────────────────────────┘
                       │
                       ▼
┌────────────── 底层资源 / 协议 ───────────────────┐
│  JDBC Connection / Hibernate Session / JTA / ... │
└──────────────────────────────────────────────────┘
```

**关键设计**：上层不依赖具体数据库，所有"开事务/提交/回滚"都通过 `PlatformTransactionManager` 接口完成——切数据库或切技术栈，业务代码不动。

---

## 三、`@Transactional` 怎么生效？

### 3.1 整体链路

```
启动期
└─ @EnableTransactionManagement / Spring Boot 自动配置
   └─ 注册 TransactionAttributeSource (扫描 @Transactional)
   └─ 注册 BeanFactoryTransactionAttributeSourceAdvisor (Advisor)
   └─ 注册 TransactionInterceptor (Advice)
   
运行期
└─ AbstractAutoProxyCreator.postProcessAfterInitialization()
   └─ 检查 bean 是否匹配 advisor → 匹配则生成代理
   
调用期
└─ 业务方法被调用
   └─ 经过 TransactionInterceptor.invoke()
      └─ TransactionAspectSupport.invokeWithinTransaction()
         ① getTransaction()   ← 开事务（按传播行为决定）
         ② proceed()           ← 调用真实方法
         ③ 出异常 → rollback()  ← 按 rollbackFor 决定
         ④ 正常 → commit()
```

### 3.2 `TransactionInterceptor` 核心代码

```java
// 简化版
public Object invoke(MethodInvocation invocation) throws Throwable {
    TransactionAttribute txAttr = getTransactionAttributeSource()
            .getTransactionAttribute(method, targetClass);
    PlatformTransactionManager tm = determineTransactionManager(txAttr);
    
    TransactionStatus status = tm.getTransaction(txAttr);   // 按传播行为开事务
    Object retVal;
    try {
        retVal = invocation.proceed();                       // 调业务方法
    } catch (Throwable ex) {
        if (txAttr.rollbackOn(ex)) {
            tm.rollback(status);
        } else {
            tm.commit(status);                               // 不在 rollbackFor 里 → 仍然提交
        }
        throw ex;
    }
    tm.commit(status);
    return retVal;
}
```

> **关键 1**：`@Transactional` **本质就是 AOP**——所有 AOP 的限制（this 调用、private、final）原封不动地应用在事务上。
>
> **关键 2**：事务回滚的判断依据是 **`rollbackOn(ex)`**，默认只对 `RuntimeException` 和 `Error` 回滚，**checked 异常默认不回滚**。

---

## 四、传播行为（Propagation）—— 嵌套调用的灵魂

7 种传播行为决定 **当前方法在外层有/没有事务时分别怎么办**：

| 传播行为 | 外层 **有** 事务 | 外层 **无** 事务 | 典型场景 |
| --- | --- | --- | --- |
| **REQUIRED**（默认） | 加入外层事务 | 新建事务 | 99% 业务方法 |
| **REQUIRES_NEW** | 挂起外层，新建独立事务 | 新建事务 | 日志、审计——独立 commit/rollback |
| **NESTED** | 嵌套事务（用 SAVEPOINT） | 新建事务 | 局部回滚不影响外层 |
| **SUPPORTS** | 加入外层 | 不开事务 | 查询为主、可有可无 |
| **NOT_SUPPORTED** | 挂起外层，不开事务 | 不开事务 | 不需要事务的耗时操作 |
| **MANDATORY** | 加入外层 | **抛异常** | 强制要求外层有事务 |
| **NEVER** | **抛异常** | 不开事务 | 强制要求外层无事务 |

### 4.1 REQUIRED 的"加入"是什么含义

```java
@Transactional
public void outer() {
    inner();        // inner 也是 @Transactional(REQUIRED)
}
```

**底层只有一个 Connection、一个事务**：
- 外层开事务，inner 共用这个事务
- inner 抛异常 → **整个事务被标记为 rollback-only**
- 外层 catch 了 inner 的异常想继续 commit → 抛 `UnexpectedRollbackException`

> **追问**：为什么 catch 了还是回滚？因为标记位是事务级的——一旦 inner 出错，整个事务就只能回滚了。这是 REQUIRED 的本质。

### 4.2 REQUIRES_NEW vs NESTED

| 维度 | REQUIRES_NEW | NESTED |
| --- | --- | --- |
| 实现 | 挂起外层，**用新 Connection 新事务** | **同一个 Connection**，靠 SAVEPOINT |
| 外层回滚是否影响内层 | 不影响（内层已 commit） | **影响**（外层 roll 后内层也没了） |
| 内层回滚是否影响外层 | 不影响 | 不影响（roll 到 SAVEPOINT） |
| 性能 | 双连接，开销大 | 单连接，开销小 |
| 数据库支持 | 全部 | 必须支持 SAVEPOINT（MySQL InnoDB ✅） |
| 典型用法 | 写日志、审计、独立计费 | 局部失败可继续的批量操作 |

```java
@Transactional
public void batchProcess(List<Item> items) {
    for (Item item : items) {
        try {
            self.processOne(item);   // NESTED
        } catch (Exception e) {
            log.warn("item {} failed, skip", item.getId());
            // 这条失败不影响其他 item
        }
    }
}

@Transactional(propagation = NESTED)
public void processOne(Item item) { ... }
```

---

## 五、隔离级别（Isolation）

| 级别 | 脏读 | 不可重复读 | 幻读 | MySQL 默认 |
| --- | --- | --- | --- | --- |
| `READ_UNCOMMITTED` | ✅ | ✅ | ✅ |  |
| `READ_COMMITTED` | ❌ | ✅ | ✅ | Oracle / PostgreSQL 默认 |
| `REPEATABLE_READ` | ❌ | ❌ | ✅ (MySQL 用 GAP 锁部分解决) | **MySQL 默认** |
| `SERIALIZABLE` | ❌ | ❌ | ❌ |  |
| `DEFAULT` | 跟随数据库默认 |

```java
@Transactional(isolation = READ_COMMITTED)
public void doSomething() { ... }
```

> **生产建议**：99% 用 `DEFAULT`（跟数据库走）。MySQL 的 RR 在 InnoDB 下用 MVCC + Next-Key Lock 已经避免了大部分幻读，没必要手动调。**改隔离级别前先证明它能解决你的问题**。

---

## 六、`@Transactional` 失效的 8 大场景（生产 P0 高频根因）

### 失效 1：`this` 自调用（最高频）

```java
@Service
public class OrderService {
    public void outer() {
        innerTx();          // ❌ 不走代理，事务失效
    }
    @Transactional
    public void innerTx() { ... }
}
```

**修法**：见 [AOP.md](AOP.md) 的 4 种修法。

### 失效 2：方法非 public

```java
@Service
public class OrderService {
    @Transactional
    private void doTx() { ... }       // ❌ private 不被代理
    @Transactional
    protected void doTx2() { ... }    // ❌ JDK 代理只代理接口方法（接口都是 public）
}
```

**修法**：改 public。

### 失效 3：抛 checked 异常但没声明 `rollbackFor`

```java
@Transactional      // ❌ 默认只回滚 RuntimeException 和 Error
public void doTx() throws IOException {
    if (...) throw new IOException();  // 不会触发回滚！数据已落库
}

// ✅ 修法
@Transactional(rollbackFor = Exception.class)
public void doTx() throws IOException { ... }
```

> **生产规约**：所有写库的 `@Transactional` 都要带 `rollbackFor = Exception.class`。

### 失效 4：异常被自己 catch 了

```java
@Transactional
public void doTx() {
    try {
        userDao.insert(user);
        throw new RuntimeException();
    } catch (Exception e) {
        log.error("err", e);    // ❌ 异常被吃了，事务正常 commit
    }
}
```

**修法**：catch 后再 throw，或显式 `TransactionAspectSupport.currentTransactionStatus().setRollbackOnly()`。

### 失效 5：bean 没被 Spring 管理

```java
public class OrderService {                  // ❌ 没有 @Service / @Component
    @Transactional
    public void doTx() { ... }
}
```

不是 Spring bean → 没经过 BPP → 没生成代理。**修法**：加 `@Service`。

### 失效 6：标在 final / static 方法上

```java
@Service
public class OrderService {
    @Transactional
    public final void doTx() { ... }    // ❌ CGLIB 代理子类重写不了 final
    
    @Transactional
    public static void doTx2() { ... }  // ❌ static 不属于实例，AOP 拦不到
}
```

### 失效 7：跨线程调用 / `@Async`

```java
@Transactional
public void outer() {
    new Thread(() -> doTx()).start();   // ❌ 子线程拿不到事务上下文
}
```

事务通过 `TransactionSynchronizationManager` 的 `ThreadLocal` 绑定 Connection。子线程独立 ThreadLocal，看不到外层事务。
**修法**：子线程独立开事务（`TransactionTemplate`），或同步执行。

### 失效 8：错误的事务管理器（多数据源）

```java
@Transactional        // ❌ 多数据源时默认拿到的可能不是你想要的那个 TM
public void doTx() { ... }

// ✅ 修法
@Transactional(transactionManager = "userTxManager")
public void doTx() { ... }
```

---

## 七、生产配置最佳实践

```java
@Transactional(
    rollbackFor = Exception.class,    // 强制 checked 也回滚
    timeout = 5,                       // 5 秒超时（防慢 SQL 拖死事务）
    isolation = Isolation.DEFAULT,     // 跟数据库默认
    propagation = Propagation.REQUIRED // 默认
)
public void createOrder() { ... }
```

### 7.1 事务超时（必配）

线上事故高发场景：业务里调了远程接口，远程方接口卡 30 秒——事务一直开着，连接不还，连接池打爆。

```java
@Transactional(timeout = 5)   // 5 秒后自动回滚并报错
```

> **超时只对 SQL 检查点生效**——纯 Java 代码不会被打断。所以核心是：**事务里别调 RPC、别做 IO、别长循环**。

### 7.2 read-only 事务

```java
@Transactional(readOnly = true)
public List<User> listUsers() { ... }
```

只读事务的好处：
- ① 数据库可以用 read-only 优化（部分数据库会跳过 redo log）
- ② Hibernate / MyBatis 不做 dirty check
- ③ 主从架构下可以路由到从库

### 7.3 编程式事务（兜底）

声明式搞不定的场景（自调用、循环里逐条提交、动态选择是否开事务）：

```java
@Resource private TransactionTemplate txTemplate;

public void batchProcess(List<Item> items) {
    for (Item item : items) {
        txTemplate.executeWithoutResult(status -> {
            try {
                doOne(item);
            } catch (Exception e) {
                status.setRollbackOnly();
            }
        });
    }
}
```

---

## 八、生产踩坑

### 坑 1：长事务拖死连接池

业务在事务里调了 HTTP 接口，第三方挂了，HTTP 默认 60s 超时——事务持有连接 60 秒，连接池 50 个连接全占满。其他请求 504。

**修法**：
1. **事务里不调 RPC、不做 IO**——拆出来，调用在事务前/后做
2. 强制超时 `@Transactional(timeout = 3)`
3. 监控事务持续时间（`spring.jpa.show-sql=false` 后用 P6Spy 监控 SQL 时长）

### 坑 2：嵌套事务全部回滚

```java
@Transactional public void outer() {
    try {
        inner1();    // 失败
    } catch (Exception e) {
        log.warn("inner1 failed");
    }
    inner2();        // 想继续做
}

@Transactional public void inner1() { throw new RuntimeException(); }
@Transactional public void inner2() { ... }
```

现象：`outer` 末尾抛 `UnexpectedRollbackException: Transaction rolled back because it has been marked as rollback-only`。
**根因**：`REQUIRED` 加入同一事务，inner1 出错时整个事务被标记 rollback-only，inner2 即使成功，commit 时被强制回滚。
**修法**：inner1 改 `REQUIRES_NEW`（独立事务，回滚不影响外层）。

### 坑 3：`@Transactional` 修饰的方法事务一直没开

线上发现写库后没回滚。debug 发现进了方法，但 `TransactionSynchronizationManager.isActualTransactionActive()` 返回 false。
**根因**：调用方调的是注入字段 `private OrderServiceImpl orderService`——JDK 代理时类型是接口，强转失败拿到的是原始对象。
**修法**：注入接口类型，或改 CGLIB。

### 坑 4：MySQL 默认 RR 隔离级别下死锁高发

业务写表 SQL 里有 `WHERE status = 1 AND ...`，并发更新不同行也死锁。
**根因**：MySQL InnoDB 在 RR 下用 Next-Key Lock 锁范围，多个事务都锁了相邻范围。
**修法**：① 改隔离级别 RC（MySQL 5.7+ 互联网常见做法）；② 优化 SQL，让 WHERE 走精准索引避免 GAP 锁；③ 拆事务，缩小锁范围。

### 坑 5：从库读不到主库刚写的数据

```java
@Transactional
public Order createAndQuery(Long userId) {
    orderDao.insert(...);      // 写主库
    return orderDao.query(...); // 从库读 → 找不到（主从复制延迟）
}
```

**根因**：业务做了主从分离，写后立即读走从库，主从同步还没完成。
**修法**：① 强制走主库（自定义注解 + AOP 切换数据源）；② 事务内全部走主库；③ 写后等待 / 重试。

---

## 九、面试高频追问

**Q1：`@Transactional` 是怎么实现的？**
A：本质是 AOP。`@EnableTransactionManagement` 注册一个 `TransactionInterceptor`（Advice）和对应的 Advisor。Bean 创建时 BPP 检查方法上有 `@Transactional`，匹配则生成代理。运行时调用进入代理 → `TransactionInterceptor.invoke()` → 调 `PlatformTransactionManager.getTransaction()` 开事务 → 调用真实方法 → 按结果 commit / rollback。

**Q2：默认情况下哪些异常会回滚？**
A：`RuntimeException` 和 `Error`。**checked 异常默认不回滚**——这是 Spring 的设计选择（checked 异常被认为是"业务可恢复异常"）。生产代码必须显式声明 `rollbackFor = Exception.class`。

**Q3：传播行为里 REQUIRED 和 REQUIRES_NEW 的区别？**
A：
- REQUIRED：加入外层事务（同一个 Connection、同一个事务），共生死
- REQUIRES_NEW：挂起外层，新开独立事务（新 Connection、新事务），独立 commit/rollback——常用于审计、独立日志

**Q4：NESTED 是真嵌套事务吗？**
A：不是真正的嵌套——靠 SAVEPOINT 实现。同一个 Connection、同一个事务，只是内层回滚回到 SAVEPOINT 不影响外层；外层回滚则全部丢失。本质是"局部回滚点"。

**Q5：`@Transactional` 最多嵌套多少层？**
A：技术上没限制——但每层 `REQUIRES_NEW` 多占一个连接，连接池上限就是层数上限。生产建议层数控制在 2 以内，超过往往是设计问题。

**Q6：事务回滚时 ThreadLocal 的状态怎么办？**
A：`TransactionSynchronizationManager` 持有所有事务相关 ThreadLocal（Connection、SynchronizationActive 等）。事务 commit/rollback 后 `cleanupAfterCompletion` 会清空这些 ThreadLocal——不会泄漏。但 **业务代码自己用的 ThreadLocal 不在管理范围**，需要业务自己清。

**Q7：分布式事务 Spring 怎么处理？**
A：Spring 自身只管理单数据源事务。分布式事务方案：
- **JTA / XA**：`JtaTransactionManager` 接 Atomikos / Bitronix——两阶段提交，性能差
- **Seata**：阿里开源，AT 模式（自动补偿）/ TCC / Saga
- **本地消息表**：业务自己保证最终一致
- **MQ 事务消息**：RocketMQ 半消息

**Q8：`PROPAGATION_REQUIRED` 和数据库的隔离级别冲突吗？**
A：传播行为是 Spring 层面的"事务嵌套策略"，隔离级别是数据库层面的"并发可见性"——两者正交。但要注意：嵌套调用里**内层的 isolation 设置无效**——既然已经加入了外层事务，整个事务的 isolation 由外层决定。

**Q9：`@Transactional` 标在接口上 vs 实现类上？**
A：**推荐标在实现类**。标接口时，JDK 代理能识别（注解是接口的一部分），但 CGLIB 代理可能识别不到（CGLIB 代理子类，接口注解通过反射获取有限制）。标实现类两种代理都能识别。Spring 官方文档明确推荐标实现类。

**Q10：事务超时是 SQL 超时吗？**
A：不是。Spring 事务超时是**整个事务的最大时长**，会在每次 SQL 执行前计算剩余时间，传给 JDBC 的 `Statement.setQueryTimeout()`。如果业务里有 IO / RPC / 长循环，**Java 代码本身不被超时打断**——事务超时只在下次 SQL 执行时生效。

---

## 十、答题模板（60 秒）

> Spring 事务的本质是 **AOP**——通过 `TransactionInterceptor` 在业务方法调用前后执行 `getTransaction / commit / rollback`，由 `PlatformTransactionManager` 抽象屏蔽数据库差异（DataSourceTM / JpaTM / JtaTM）。
>
> 核心三件事：
>
> **① 7 种传播行为**：默认 `REQUIRED`（加入外层），`REQUIRES_NEW`（挂起外层、独立事务，常用审计），`NESTED`（同 Connection 的 SAVEPOINT，局部回滚），`SUPPORTS / NOT_SUPPORTED / MANDATORY / NEVER` 是边界行为。
>
> **② 失效场景**：① this 自调用、② private/final/static、③ 异常被 catch 吞掉、④ checked 异常没 `rollbackFor`、⑤ 跨线程调用、⑥ bean 没纳入 Spring、⑦ 多数据源 TM 错配、⑧ JDK 代理强转实现类。**生产 P0 高频根因**。
>
> **③ 默认只对 RuntimeException 和 Error 回滚**——所有写库的 `@Transactional` 必须 `rollbackFor = Exception.class`、`timeout = 几秒`，且**事务里不调 RPC / 不做 IO**。
>
> 嵌套调用最常见的 `UnexpectedRollbackException` 根因：内层 REQUIRED 加入外层事务，内层失败把整个事务标记 rollback-only，外层 catch 后也救不回来——要让内层独立失败，改 `REQUIRES_NEW`。

---

## 十一、相关文档

- 前置：[AOP.md](AOP.md) — 事务的 AOP 实现原理
- 前置：[Bean生命周期.md](Bean生命周期.md) — `TransactionInterceptor` 在哪步织入
- 配套：[../MySQL/事务的隔离级别.md](../MySQL/事务的隔离级别.md) — 数据库层面的隔离
- 配套：[../MySQL/事务的原理.md](../MySQL/事务的原理.md) — undo / redo / MVCC
