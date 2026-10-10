# AQS 原理（AbstractQueuedSynchronizer）

> JUC 同步组件的脊梁。**ReentrantLock / ReadWriteLock / Semaphore / CountDownLatch / FutureTask / ThreadPoolExecutor** 全部基于它。
> 面试问到锁，最深可以问到 AQS。本篇讲清：
> ① AQS 的 3 个核心：state（同步状态）+ CLH 双向队列 + 模板方法
> ② 独占模式（Exclusive）与共享模式（Shared）
> ③ ReentrantLock.lock() 走完整链路是怎样的？
> ④ 公平 vs 非公平的源码差异（就一行）
> ⑤ Condition 怎么实现 await/signal？

> 前置：[CAS](./CAS与原子类.md)、[Volatile](./Volatile.md)、[等待唤醒机制](./等待唤醒机制.md)

---

## 一、AQS 在 JUC 的位置

```
                ┌─────────────────────────────┐
                │  ReentrantLock              │
                │  ReadWriteLock              │   ← 高层组件
                │  Semaphore                  │
                │  CountDownLatch / Cyclic    │
                │  ThreadPoolExecutor.Worker  │
                └──────────────┬──────────────┘
                               │ 内部类继承
                               ▼
                ┌─────────────────────────────┐
                │  AbstractQueuedSynchronizer │   ← 模板方法
                │   - state (volatile int)    │
                │   - CLH 双向队列             │
                │   - acquire/release 流程     │
                └──────────────┬──────────────┘
                               │
                               ▼
                ┌─────────────────────────────┐
                │  CAS (Unsafe)               │
                │  LockSupport.park/unpark    │   ← 底层原语
                └─────────────────────────────┘
```

AQS 提供"骨架"，子类实现"肌肉"（具体怎么判断锁状态），是**模板方法模式**的经典应用。

---

## 二、AQS 核心数据结构

### 2.1 同步状态 state

```java
private volatile int state;
protected final int getState();
protected final void setState(int);
protected final boolean compareAndSetState(int expect, int update);
```

**state 的语义由子类自定义**：
| 类 | state 含义 |
| --- | --- |
| ReentrantLock | 0 = 未锁；> 0 = 持有锁的重入次数 |
| ReentrantReadWriteLock | 高 16 位 = 读锁数；低 16 位 = 写锁重入数 |
| Semaphore | 剩余许可数 |
| CountDownLatch | 还需要 countDown 几次 |
| ThreadPoolExecutor.Worker | 0/1，是否正在跑任务 |

### 2.2 CLH 队列（变种）

AQS 用一个**双向 FIFO 队列**管理等锁的线程。每个等待线程被包装成 `Node`。

```
        head (虚拟节点)              tail
          │                            │
          ▼                            ▼
        ┌─────┐    ┌─────┐    ┌─────┐    ┌─────┐
        │  -  │ ◄──│ T1  │ ◄──│ T2  │ ◄──│ T3  │
        │     │ ──►│     │ ──►│     │ ──►│     │
        └─────┘    └─────┘    └─────┘    └─────┘
                                        ↑
                                   compareAndSet(tail, ...)
                                   新线程进队从尾部入
```

**Node 结构**：
```java
static final class Node {
    volatile Node prev;
    volatile Node next;
    volatile Thread thread;
    volatile int waitStatus;     // -1=SIGNAL/-2=CONDITION/-3=PROPAGATE/1=CANCELLED/0=初始
    Node nextWaiter;             // 共享/独占模式标记 + Condition 队列指针
}
```

**waitStatus 关键值**：
- `SIGNAL (-1)`：当前节点的后继需要被 unpark 唤醒
- `CANCELLED (1)`：节点已超时或被中断取消
- `CONDITION (-2)`：节点在 Condition 队列上等
- `PROPAGATE (-3)`：共享模式下，需要向后传播唤醒

### 2.3 为什么叫"CLH 变种"

经典 CLH（Craig, Landin, Hagersten）锁是**自旋锁**，在前驱节点状态上自旋。AQS 改成：
- 默认不自旋，找前驱后调 `LockSupport.park()` **挂起**（省 CPU）
- 前驱释放锁时 `unpark` 后继
- 双向链表（经典 CLH 单向）方便取消节点

---

## 三、模板方法（子类要实现的 5 个）

```java
// 独占模式
protected boolean tryAcquire(int arg);
protected boolean tryRelease(int arg);

// 共享模式
protected int tryAcquireShared(int arg);
protected boolean tryReleaseShared(int arg);

// 是否独占持有（Condition 用）
protected boolean isHeldExclusively();
```

子类**只需重写它需要的部分**：
- ReentrantLock 重写独占的 `tryAcquire / tryRelease`
- Semaphore 重写共享的 `tryAcquireShared / tryReleaseShared`
- ReentrantReadWriteLock 两套都重写

---

## 四、独占模式：acquire / release

### 4.1 acquire 主流程

```java
public final void acquire(int arg) {
    if (!tryAcquire(arg) &&
        acquireQueued(addWaiter(Node.EXCLUSIVE), arg))
        selfInterrupt();
}
```

**三步**：
1. **tryAcquire**：子类实现的"快速尝试"——CAS state，成功返回 true
2. **addWaiter**：失败则把当前线程包成 Node，CAS 加到队列尾
3. **acquireQueued**：在队列里**自旋 + park**——前驱是 head 时再 tryAcquire；不是 head 或失败就 park

### 4.2 acquireQueued 详解

```java
final boolean acquireQueued(final Node node, int arg) {
    boolean interrupted = false;
    for (;;) {                              // 自旋
        final Node p = node.predecessor();
        if (p == head && tryAcquire(arg)) { // 前驱是 head 才有资格抢
            setHead(node);
            p.next = null;                  // help GC
            return interrupted;
        }
        if (shouldParkAfterFailedAcquire(p, node) &&
            parkAndCheckInterrupt())        // ★ 真正阻塞在这里
            interrupted = true;
    }
}
```

**关键**：只有**前驱是 head** 的节点才 tryAcquire——这是 FIFO 公平性的来源（队列里"老二"才有资格抢，老三老四只能干瞪眼）。

### 4.3 release 主流程

```java
public final boolean release(int arg) {
    if (tryRelease(arg)) {
        Node h = head;
        if (h != null && h.waitStatus != 0)
            unparkSuccessor(h);             // 唤醒后继
        return true;
    }
    return false;
}
```

释放后唤醒队列里 head 的后继，被唤醒的线程从 `parkAndCheckInterrupt()` 醒来，回到自旋，再尝试 tryAcquire。

### 4.4 ReentrantLock.lock() 完整链路（必背）

```
NonfairSync.lock()
  └─► CAS(state, 0, 1)   ← 直接抢一发
       │
       ├─ 成功：setExclusiveOwnerThread(currentThread)，结束
       │
       └─ 失败：acquire(1)
              └─► tryAcquire(1)
                    ├─ state == 0：再 CAS 抢一发
                    ├─ 持锁线程是自己：state++（重入）
                    └─ 都不是：return false
                  │
                  └─► 失败 → addWaiter() 入队 → acquireQueued() → park
```

**公平锁**只比非公平锁多一行：
```java
// FairSync.tryAcquire 的关键差异
if (!hasQueuedPredecessors() && compareAndSetState(0, acquires)) ...
//   ↑ 公平锁：先看队列里有没有前辈，有就不抢
```

非公平锁的"barge（插队）"行为：
- 新来的线程**直接 CAS 抢锁**，不管队列里排了多少人
- 如果抢成功，比排队的更早拿到锁（不公平）
- 但**减少了 park/unpark** 的开销，吞吐更高（默认就是非公平）

---

## 五、共享模式：acquireShared / releaseShared

### 5.1 与独占的差异

| | 独占 | 共享 |
| --- | --- | --- |
| state 含义 | 0 / >0 | 0 / 剩余许可 |
| tryAcquire 返回 | bool | int（>=0 成功，<0 失败） |
| 唤醒模式 | 唤醒一个后继 | **传播唤醒**：唤醒一个后，它如果还有剩余许可，继续唤醒下一个 |
| 典型场景 | ReentrantLock | Semaphore / CountDownLatch / 读锁 |

### 5.2 Semaphore 实现略

```java
// Semaphore.NonfairSync
final int nonfairTryAcquireShared(int acquires) {
    for (;;) {
        int available = getState();
        int remaining = available - acquires;
        if (remaining < 0 ||
            compareAndSetState(available, remaining))
            return remaining;
    }
}
```

state 就是剩余许可数；CAS 减成功就拿到。

### 5.3 CountDownLatch 实现略

```java
// state = N，每次 countDown -1，countDown 到 0 时把整个 head 节点整链向后唤醒
protected boolean tryReleaseShared(int releases) {
    for (;;) {
        int c = getState();
        if (c == 0) return false;
        int nextc = c - 1;
        if (compareAndSetState(c, nextc))
            return nextc == 0;        // 归零才返回 true 触发 doReleaseShared
    }
}
```

`await()` 走共享获取，state==0 才能通过；其他线程 `countDown` 减 state 到 0 时全员放行。**所以 CountDownLatch 是一次性的，不能 reset**。

---

## 六、Condition：AQS 上的 wait/notify

### 6.1 类比

| | synchronized | ReentrantLock |
| --- | --- | --- |
| 等待 | `obj.wait()` | `condition.await()` |
| 通知 | `obj.notify/All()` | `condition.signal/All()` |
| 等待队列 | ObjectMonitor.WaitSet | AQS 内部的 Condition Queue |
| 个数 | **每个对象 1 个** | **可以有任意多个 Condition** |

### 6.2 多 Condition 价值

生产者-消费者经典场景：
```java
final ReentrantLock lock = new ReentrantLock();
final Condition notFull  = lock.newCondition();
final Condition notEmpty = lock.newCondition();

void put(E x) throws InterruptedException {
    lock.lock();
    try {
        while (count == capacity) notFull.await();
        enqueue(x);
        notEmpty.signal();          // 精确唤醒"等不空"的消费者
    } finally { lock.unlock(); }
}

E take() throws InterruptedException {
    lock.lock();
    try {
        while (count == 0) notEmpty.await();
        E x = dequeue();
        notFull.signal();           // 精确唤醒"等不满"的生产者
        return x;
    } finally { lock.unlock(); }
}
```

synchronized + 一个 wait/notify 队列**做不到精确唤醒**：notifyAll 会把生产者和消费者一起叫醒，互相空走。

### 6.3 await/signal 内部链路

```
await():
1. 把当前节点从 AQS 主队列取出（释放锁，state 完全置 0）
2. 加到 Condition 自己的单向队列
3. park 当前线程

signal():
1. 把 Condition 队列的头节点转移到 AQS 主队列尾
2. 这个节点会按 AQS 主队列的 FIFO 规则被唤醒（可能等其他线程释放锁）
```

`signal` 不立即唤醒，而是把节点"挪到主队列排队"。等到主队列前驱释放锁，才会真正 unpark 它。

---

## 七、生产踩坑

### 7.1 自定义同步器忘了原子操作

```java
protected boolean tryAcquire(int arg) {
    if (getState() == 0) {
        setState(1);                // ❌ 非原子
        setExclusiveOwnerThread(Thread.currentThread());
        return true;
    }
    return false;
}
```
**修复**：必须用 `compareAndSetState(0, 1)`，否则两个线程同时通过 if 检查。

### 7.2 自定义同步器忘了重写 isHeldExclusively

`Condition.await()` 会调 `release` 释放完整 state，需要 `isHeldExclusively` 判定独占持有。不重写直接抛 `UnsupportedOperationException`。

### 7.3 LockSupport.park 醒来要查"是不是真的被 signal"

park 可能被**伪唤醒**或被中断打断，所以醒来后必须重新检查条件，所以 `Condition.await()` 永远要写在 `while` 里：
```java
while (!conditionMet) condition.await();   // ★ 不能用 if
```

### 7.4 取消的节点没及时清理 → 内存泄漏

中断 / tryLock 超时会让 Node 状态变成 CANCELLED。如果 cleanup 不及时，CANCELLED 节点在队列里堆积。AQS 在 `acquireQueued` 中会顺手清理，但极端场景仍会出问题，监控时关注 AQS 队列长度。

---

## 八、面试高频追问

**Q1：AQS 怎么用 CAS 保证多线程同时入队不冲突？**
入队用 `compareAndSetTail(oldTail, newNode)`——只有 oldTail 没变才入队成功；失败就重试（自旋）。这是**无锁链表**的标准做法。

**Q2：为什么 AQS 用双向队列而不是单向？**
- 单向：节点取消时，找前驱要从 head 遍历 O(N)
- 双向：直接 `node.prev` O(1) 找前驱
- park/unpark 也需要快速找前驱判断 SIGNAL 状态

**Q3：head 节点为什么是"虚拟"的？**
head **不持有线程**，只是个占位。这样队列空时也有 head；入队时直接 CAS 到 tail，不需要特殊处理空队列。

**Q4：公平锁性能为什么差？**
公平锁 tryAcquire 时先 `hasQueuedPredecessors`——队列非空就放弃 CAS 抢锁，直接进队 park。
非公平锁直接 CAS 抢——抢成功就免一次 park/unpark（一次 unpark ~1μs）。
高竞争场景非公平能快 5-10 倍，但极端情况会饿死队尾。

**Q5：ReentrantLock 重入怎么实现？**
`tryAcquire` 检查持锁线程是否是 currentThread，是就 `state += acquires`（不用 CAS，因为本线程独占）；release 时 `state -= releases`，归 0 才真正释放。

**Q6：state 为什么是 int 不是 long？**
- 32 位 JVM 上 int 读写天然原子，long 不是
- 加上重入计数等，int 已够用
- ReadWriteLock 把 int 拆高低 16 位双重利用

**Q7：AQS 有什么缺点？**
- API 复杂，自定义同步器难写对（容易 BUG）
- CLH 队列在大量短临界区竞争下，park/unpark 成本可能超过临界区本身
- 对程序员有一定门槛

**Q8：JDK 21 的 VirtualThread 怎么影响 AQS？**
ReentrantLock 已经被改造成不 pin 载体线程——虚拟线程 await 时会让出载体线程。但 synchronized 在 JDK 21 还是 pin 的（JEP 491 在 Java 24 才解决）。所以**虚拟线程 + 同步原语**优先 ReentrantLock。

---

## 九、答题模板（90 秒话术）

> AQS 是 JUC 锁框架的脊梁，提供 **同步状态 state（volatile int）+ CLH 双向 FIFO 队列 + 一组模板方法**。
>
> 子类自定义 state 语义：ReentrantLock 用 state 表示重入次数，Semaphore 用 state 表示剩余许可，ReadWriteLock 把 state 拆成高 16 位读 + 低 16 位写。
>
> **acquire 流程**：先 `tryAcquire`（CAS state 快速试）→ 失败包装成 Node 入队（CAS tail）→ 在队列里**自旋 + park**：前驱是 head 才有资格抢，否则 LockSupport.park。`release` 后通过 `unpark` 唤醒后继。
>
> 公平 vs 非公平**只差一行**：公平锁先 `hasQueuedPredecessors` 让位，非公平锁直接 CAS 抢——非公平吞吐高，但可能饿死队尾。
>
> Condition 是 AQS 提供的 wait/notify 机制，每个 Lock 可以创建任意多个 Condition，对比 synchronized 一个对象一套 wait/notify，**能精确唤醒**（生产者只唤生产者、消费者只唤消费者）。
>
> 整个 AQS 的精髓是：**CAS 替代锁、park/unpark 替代忙等、模板方法解耦"判定逻辑"和"队列管理"**。

---

## 十、相关文档

- [Lock 原理](./Lock原理.md) — ReentrantLock / RW / StampedLock 详解
- [CAS 与原子类](./CAS与原子类.md) — AQS 操作 state 的根本
- [等待唤醒机制](./等待唤醒机制.md) — park/unpark 与 Condition
- [Synchronized](./Synchronized.md) — 内置锁对比
- [ConcurrentHashMap](./ConcurrentHashMap.md) — 没用 AQS 但 CAS 思路类似
