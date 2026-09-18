# Lock 原理

> JUC 锁全家桶，业务里出现频率最高的并发组件。本篇讲清：
> ① ReentrantLock：和 synchronized 的本质差异、公平/非公平、tryLock / lockInterruptibly
> ② ReentrantReadWriteLock：读写互斥的位运算技巧、锁降级、为什么不支持锁升级
> ③ StampedLock（JDK 8）：乐观读为什么能跑赢 ReadWriteLock
> ④ Lock 全景：偏向 / 轻量 / 重量 / 自旋 / 公平 / 可重入 / 共享 / 排他 这些"锁的形容词"到底什么关系
> ⑤ 选型：默认用 synchronized，什么时候必须换 Lock

> 前置：[AQS 原理](./AQS原理.md)、[Synchronized](./Synchronized.md)

---

## 一、Lock 全景（先理清概念混乱）

并发面试经常蹦出一堆"XX 锁"——很多其实是**正交维度**的不同分类，不是互斥的：

| 维度 | 选项 | 说明 |
| --- | --- | --- |
| **是否独占** | 独占锁 / 共享锁 | 独占（synchronized、ReentrantLock）；共享（Semaphore、读锁） |
| **是否公平** | 公平 / 非公平 | 公平 = 严格 FIFO；非公平 = 允许插队（默认） |
| **是否可重入** | 可重入 / 不可重入 | 同一线程能否多次拿同一把锁 |
| **是否可中断** | 可中断 / 不可中断 | 等锁过程能否被 interrupt 打断 |
| **乐观/悲观** | 乐观锁（CAS）/ 悲观锁（互斥） | CAS 假设没冲突；互斥假设一定冲突 |
| **JVM 锁状态** | 无锁 / 偏向 / 轻量级 / 重量级 | synchronized 内部的锁升级；只是性能优化 |
| **自旋/阻塞** | 自旋锁 / 阻塞锁 | 自旋 = 循环 CAS；阻塞 = park 让出 CPU |

**典型组合**：
- `synchronized`：独占、可重入、非公平、不可中断、阻塞（升级前会自旋）
- `ReentrantLock`：独占、可重入、可选公平、可中断、阻塞
- 读锁：共享、可重入、阻塞
- `Semaphore(N)`：共享（N 个许可）、不可重入
- `AtomicInteger`：无锁（CAS）、自旋

---

## 二、ReentrantLock

### 2.1 vs synchronized

| 维度 | synchronized | ReentrantLock |
| --- | --- | --- |
| 释放 | 自动（块结束 / 异常） | **必须 finally unlock()** |
| 可中断等待 | ❌ | ✅ `lockInterruptibly()` |
| 超时尝试 | ❌ | ✅ `tryLock(t, unit)` |
| 公平模式 | ❌ | ✅ `new ReentrantLock(true)` |
| Condition 数量 | 1（wait/notify 一套） | **N 个**（newCondition 任意多） |
| 可观测 | ❌ | `isLocked / getQueueLength / hasQueuedThreads` |
| 性能（JDK 6+） | 接近 | 略快（非公平模式） |
| 简洁性 | ✅ 没法忘记 unlock | ❌ 容易忘记 unlock |

### 2.2 标准用法

```java
private final ReentrantLock lock = new ReentrantLock();

public void critical() {
    lock.lock();
    try {
        // 临界区
    } finally {
        lock.unlock();          // ★ 必须在 finally
    }
}

// 超时尝试
if (lock.tryLock(100, TimeUnit.MILLISECONDS)) {
    try { ... } finally { lock.unlock(); }
} else {
    // 超时未获取，降级
}

// 可中断
try {
    lock.lockInterruptibly();
    try { ... } finally { lock.unlock(); }
} catch (InterruptedException e) {
    // 等待被中断
}
```

### 2.3 公平 vs 非公平

```java
// 默认非公平
ReentrantLock lock = new ReentrantLock();

// 公平
ReentrantLock fair = new ReentrantLock(true);
```

**非公平的"插队"机制**：新线程到来时**立即 CAS 抢锁**，不管队列里排了多少人。
- 抢成功：免一次入队 / park / unpark（节省 ~1-2 μs）
- 抢失败：进队等待

公平锁性能差**约 3-10 倍**。生产**默认非公平**，除非业务上严格要求"先到先得"（如基于到达顺序的限流）。

### 2.4 不可重入会怎样

`Lock` 接口允许实现"不可重入锁"，但 ReentrantLock 顾名思义是可重入的。**不可重入会死锁**：

```java
synchronized void a() { b(); }
synchronized void b() { ... }
```
如果 synchronized 不可重入，调用 a → 拿锁 → 调 b → 等锁释放 → a 自己永远不可能释放 → 死锁。
所以 Java 内置锁和 ReentrantLock **都是可重入的**。

### 2.5 实现要点

继承 AQS，state 表示重入计数：
```java
// NonfairSync.tryAcquire
final boolean nonfairTryAcquire(int acquires) {
    Thread current = Thread.currentThread();
    int c = getState();
    if (c == 0) {
        if (compareAndSetState(0, acquires)) {
            setExclusiveOwnerThread(current);
            return true;
        }
    } else if (current == getExclusiveOwnerThread()) {
        int nextc = c + acquires;          // 重入累加
        if (nextc < 0) throw new Error("Maximum lock count exceeded");
        setState(nextc);
        return true;
    }
    return false;
}
```

---

## 三、ReentrantReadWriteLock

### 3.1 适用场景

**读多写少**——读读不互斥，读写 / 写写互斥。典型用例：
- 缓存
- 配置中心
- 注册表

### 3.2 state 的位运算技巧

state（int 32 位）拆成两半：
```
   高 16 位：读锁数（共享）          低 16 位：写锁重入数（独占）
   ┌──────────────────────────┐  ┌──────────────────────────┐
   │       sharedCount        │  │      exclusiveCount      │
   └──────────────────────────┘  └──────────────────────────┘
                  最大 65535                       最大 65535
```

```java
static final int SHARED_SHIFT   = 16;
static final int SHARED_UNIT    = (1 << SHARED_SHIFT);    // 0x10000
static final int MAX_COUNT      = (1 << SHARED_SHIFT) - 1; // 65535
static final int EXCLUSIVE_MASK = (1 << SHARED_SHIFT) - 1;

static int sharedCount(int c)    { return c >>> SHARED_SHIFT; }
static int exclusiveCount(int c) { return c & EXCLUSIVE_MASK; }
```

**为什么不用两个 int**？因为 AQS 只有一个 state，要用一次 CAS 同时操作两个值，必须挤进一个 int。

### 3.3 互斥规则

| 当前状态 | 申请读锁 | 申请写锁 |
| --- | --- | --- |
| 无锁 | ✅ | ✅ |
| 持读锁 | ✅ | ❌ 必须等所有读释放 |
| 持写锁（自己） | ✅（**锁降级**）| ✅ 重入 |
| 持写锁（他人） | ❌ | ❌ |

### 3.4 锁降级（写 → 读）

```java
final ReentrantReadWriteLock rw = new ReentrantReadWriteLock();
final Lock r = rw.readLock();
final Lock w = rw.writeLock();
volatile boolean cacheValid;

void update() {
    r.lock();
    if (!cacheValid) {
        r.unlock();
        w.lock();
        try {
            if (!cacheValid) {        // 拿到写锁后再 check 一遍（DCL 思想）
                refresh();
                cacheValid = true;
            }
            r.lock();                 // ★ 锁降级：先拿读锁，再释放写锁
        } finally {
            w.unlock();
        }
    }
    try {
        useCache();
    } finally {
        r.unlock();
    }
}
```

**为什么需要降级**：在写锁内"刷新完缓存 + 立即开始读"——降级后保证刷新完毕到读取期间，没有别的写者插入；如果先释放写锁再拿读锁，**会有窗口被别的写者抢**。

### 3.5 为什么不支持锁升级（读 → 写）

```java
r.lock();
try {
    if (need) w.lock();   // ❌ 死锁！
}
```
原因：多个线程都持读锁时，每个线程都想升级到写锁——所有线程都等"其他读锁释放"，**互相等待→死锁**。

JDK 没法在不破坏读锁语义的前提下安全实现读升写，所以**直接禁止**。

### 3.6 ReadWriteLock 的"写者饥饿"

非公平模式下，**新读者总是能插到等待写者前面**（读读不互斥）→ 持续高并发读会让写者永远等不到。

JDK 实现：非公平 RW 锁的读锁请求**会被`readerShouldBlock`策略阻塞** —— 队列里有正在等的写者时，新读者也乖乖排队，避免写饿死。

---

## 四、StampedLock（JDK 8 引入）

### 4.1 痛点：ReadWriteLock 的写仍然互斥读

读多写少且读频率极高时（每秒百万次），ReadWriteLock 的 CAS 修改 sharedCount 仍然有缓存行竞争开销。

### 4.2 三种模式

```java
StampedLock sl = new StampedLock();

// 1. 写锁（独占）
long s = sl.writeLock();
try { ... } finally { sl.unlockWrite(s); }

// 2. 悲观读（共享，类似传统读锁）
long s = sl.readLock();
try { ... } finally { sl.unlockRead(s); }

// 3. 乐观读（无锁，关键创新）★
long s = sl.tryOptimisticRead();
int x = data.x;
int y = data.y;
if (!sl.validate(s)) {                  // 期间有写则降级
    s = sl.readLock();
    try { x = data.x; y = data.y; }
    finally { sl.unlockRead(s); }
}
```

### 4.3 乐观读的精髓

`tryOptimisticRead` **不加锁**，只返回当前 stamp。读完后 `validate(stamp)`：
- stamp 没变 → 期间没人写过，读到的数据有效
- stamp 变了 → 写者插入了，降级走传统读锁

**好处**：读侧**完全无 CAS、无屏障**，性能接近无锁。
**代价**：读到的数据可能不一致（写完一半），所以读完必须 validate；validate 失败要降级重读，写多场景反而更慢。

### 4.4 局限

- **不可重入**！同一线程拿了写锁还想再拿读锁会死锁
- 不支持 Condition
- 中断处理复杂（默认非可中断）
- API 易用性差，业务用得少；框架（如 Caffeine）用得多

### 4.5 性能对比（粗略）

读多写少（99% 读）下：
```
synchronized       : 1×
ReentrantLock      : 1.2×
ReadWriteLock      : 5×
StampedLock 乐观读 : 12×
```

---

## 五、其他 Lock 简述

### 5.1 Semaphore

**信号量**：state = 许可数；`acquire()` -1 / `release()` +1。典型用例：
- 限流（最多 N 个并发请求）
- 资源池（数据库连接最多 N 个）
- 控制队列大小

```java
Semaphore sem = new Semaphore(10);   // 最多 10 并发
sem.acquire();
try { doWork(); } finally { sem.release(); }
```

### 5.2 CountDownLatch

**一次性栅栏**：state 初始 = N，await 阻塞直到 state = 0。典型用例：
- 主线程等所有子任务完成
- 多线程同时启动（latch.await，最后 latch.countDown 同时放行）

```java
CountDownLatch latch = new CountDownLatch(5);
for (int i = 0; i < 5; i++) {
    pool.submit(() -> { doTask(); latch.countDown(); });
}
latch.await();   // 等 5 个都完成
```

**只能用一次**，归零后无法重置。要循环用 → CyclicBarrier。

### 5.3 CyclicBarrier

**可重用的栅栏**：N 个线程互相等齐再一起放行；放行后自动 reset。

```java
CyclicBarrier barrier = new CyclicBarrier(3, () -> System.out.println("齐活"));
// 每个线程：
barrier.await();   // 3 个都到齐才返回
```

### 5.4 Phaser

**进阶版 CyclicBarrier**：支持动态线程数、分阶段。复杂场景才用。

---

## 六、生产踩坑

### 6.1 忘记 finally 解锁

```java
lock.lock();
doWork();           // 抛异常 → 锁永远不释放 → 死锁
lock.unlock();
```
**修复**：必须 try-finally。Idea / SonarLint 会高亮告警。

### 6.2 try-finally 内 unlock 抛异常

```java
lock.lock();
try { doWork(); }
finally { lock.unlock(); }   // 如果 lock.lock 失败，这里 IllegalMonitorStateException
```
**修复**：`lock.lock()` 必须**写在 try 之前**，确保只有真正拿到锁才会解锁。

### 6.3 ReentrantLock 的 fair 模式拖累吞吐

**现象**：业务用了 `new ReentrantLock(true)`，QPS 上不去。
**修复**：默认非公平，除非真的有"必须 FIFO"需求。

### 6.4 用 RW 锁但读临界区超短

**现象**：用 ReadWriteLock 包了一个 `return map.get(key)`，性能反而比 synchronized 差。
**根因**：临界区比 RW 锁内部 CAS / 队列管理还短，框架开销 > 收益。
**修复**：直接 `ConcurrentHashMap`，或者短临界区用 synchronized。

### 6.5 锁降级写错顺序

```java
w.lock();
try {
    refresh();
    w.unlock();      // ❌ 先释放写锁
    r.lock();        // 中间窗口被别的写者插入
}
```
**修复**：必须**先 r.lock 再 w.unlock**（持有写锁状态下拿读锁，安全降级）。

### 6.6 StampedLock 重入死锁

```java
StampedLock sl = new StampedLock();
long s1 = sl.writeLock();
long s2 = sl.writeLock();   // ❌ 同一线程也会阻塞，死锁
```
StampedLock **不可重入**，老老实实当成内部组件用，不要嵌套。

---

## 七、面试高频追问

**Q1：ReentrantLock 怎么实现可重入？**
AQS 的 state 当重入计数：第一次拿锁 state=1，再次拿就 state++（同一线程不需要 CAS）；释放时 state--，归零才真正释放。

**Q2：公平锁源码哪一行让它公平？**
`FairSync.tryAcquire` 里的 `hasQueuedPredecessors()`——如果队列前面有人，就不抢，直接 return false 走入队。

**Q3：ReadWriteLock 为什么不支持锁升级？**
多个读线程同时升级 → 互相等"其他读锁释放" → 死锁。JDK 无法在不破坏读锁语义下安全升级，直接禁止。

**Q4：StampedLock 的乐观读怎么和写锁协调？**
写锁会修改内部 stamp 序号；乐观读只读 stamp，读完 validate(stamp)——序号没变就读到一致数据，序号变了说明期间有写，降级用悲观读重读。

**Q5：Semaphore vs CountDownLatch vs CyclicBarrier？**
- Semaphore：N 个许可（限流 / 资源池）
- CountDownLatch：N 个事件归零后放行（一次性、单向倒数）
- CyclicBarrier：N 个线程互相等齐（可重用、所有人都得到达）

**Q6：synchronized 和 Lock 性能哪个更好？**
JDK 6 之前 synchronized 慢得多。**JDK 6+ 二者差距很小**：
- 低竞争：synchronized 略快（偏向锁 / 轻量级锁几乎无开销）
- 高竞争：ReentrantLock 略快（无 STW 升级 + 队列管理更精细）
默认建议：能用 synchronized 就用 synchronized（语法简洁、自动释放、JVM 优化激进），需要高级特性才换 Lock。

**Q7：怎么判断该用 ReentrantLock 还是 synchronized？**
触发任一条件就换 ReentrantLock：
- 需要 tryLock（超时 / 非阻塞）
- 需要 lockInterruptibly（可中断）
- 需要公平模式
- 需要多个 Condition
- 需要 isLocked / getQueueLength 类监控
- 锁的持有时间跨方法 / 跨类（synchronized 必须块结构）

**Q8：JDK 21 虚拟线程下 Lock 怎么选？**
**ReentrantLock 优先**——已被改造为不 pin 载体线程；synchronized 在 JDK 21 还会 pin（虚拟线程不能让出），导致虚拟线程阻塞退化为载体线程阻塞。JEP 491（Java 24）后这块拉平。

---

## 八、答题模板（90 秒话术）

> JUC Lock 全家桶基于 **AQS**：
>
> **ReentrantLock**——独占可重入锁，比 synchronized 多 **超时 / 中断 / 公平 / 多 Condition / 监控**。代价是**必须 finally unlock()**。state 表示重入次数。公平锁就比非公平多一行 `hasQueuedPredecessors`。
>
> **ReentrantReadWriteLock**——把 state 拆成 **高 16 位读 + 低 16 位写**，读读不互斥、读写 / 写写互斥。**支持锁降级**（写→读，不释放写锁就拿读锁），**禁止锁升级**（读→写会死锁）。读多写少场景比 ReentrantLock 快 5×。
>
> **StampedLock**（JDK 8）——三模式：写锁、悲观读、**乐观读**。乐观读完全无锁（只取 stamp，读完 validate），读多写少能再快 2×。代价是**不可重入、API 复杂**。
>
> 配套工具：**Semaphore**（限流 / 资源池）、**CountDownLatch**（一次性归零栅栏）、**CyclicBarrier**（可重用栅栏）。
>
> 选型原则：**默认 synchronized**（自动释放、语义简洁）；需要超时 / 中断 / 公平 / 多 Condition 才换 ReentrantLock；读多写少且读临界区比较"重"才换 ReadWriteLock；超高频读才考虑 StampedLock。

---

## 九、相关文档

- [AQS 原理](./AQS原理.md) — Lock 的内部实现
- [Synchronized](./Synchronized.md) — 内置锁对比
- [CAS 与原子类](./CAS与原子类.md) — 无锁选项
- [等待唤醒机制](./等待唤醒机制.md) — Condition 的底层
- [死锁分析](./死锁分析.md) — 锁的兜底排查
