# Synchronized

> Java 内置锁，面试 Top 1 高频。本篇讲清楚：
> ① synchronized 在字节码 / JVM 层是什么？monitorenter / monitorexit / ACC_SYNCHRONIZED 怎么对应
> ② Monitor 是什么？为什么每个对象都能当锁？
> ③ JDK 1.6 的**锁升级**：无锁 → 偏向锁 → 轻量级锁 → 重量级锁
> ④ Mark Word 怎么记录锁状态？
> ⑤ 三大特性如何保证：可见性 / 原子性 / 有序性
> ⑥ synchronized vs Lock 该用哪个？

> 前置：[JMM 内存模型](./JMM内存模型.md)、[CAS](./CAS与原子类.md)

---

## 一、synchronized 用法（3 种）

```java
class Counter {
    private int n;

    // 1. 实例方法 → 锁 this
    public synchronized void inc1() { n++; }

    // 2. 静态方法 → 锁 Class 对象
    public static synchronized void inc2() { staticN++; }

    // 3. 代码块 → 锁指定对象
    private final Object lock = new Object();
    public void inc3() {
        synchronized (lock) { n++; }
    }
}
```

| 形式 | 锁对象 |
| --- | --- |
| `synchronized` 实例方法 | `this`（当前实例） |
| `synchronized` 静态方法 | 当前类的 `Class` 对象 |
| `synchronized (obj) {}` | obj |

> 易错：用 `synchronized (Integer.valueOf(1))` 这种"驻留对象"做锁——多个无关代码可能锁同一个对象，造成误竞争或死锁。**生产规范**：锁对象必须 `private final`，且最好是 `Object` 实例。

---

## 二、字节码层面

### 2.1 同步代码块：monitorenter / monitorexit

```java
synchronized (lock) { count++; }
```

```
javap -c：
   1: monitorenter      ← 入口加锁
   2: getstatic     #2  ← count
   5: iconst_1
   6: iadd
   7: putstatic     #2  ← count = count + 1
  10: monitorexit       ← 正常出口
  11: goto          19
  14: monitorexit       ← 异常出口（finally 隐式插入）
  15: athrow
```

**关键观察**：编译器为每个 `monitorenter` 生成 **2 个 `monitorexit`**——正常退出 + 异常退出。这就是"synchronized 异常会自动释放锁"的实现。

### 2.2 同步方法：ACC_SYNCHRONIZED 标志

```bash
javap -v Foo.class
public synchronized void inc();
  flags: ACC_PUBLIC, ACC_SYNCHRONIZED   ← 标志位，无字节码指令
```

JVM 调用方法时检查这个 flag，**隐式执行 monitorenter / monitorexit**。

### 2.3 二者本质相同

最终都走 JVM 内部的 `ObjectMonitor::enter` / `::exit` 路径，只是触发点不同。

---

## 三、Monitor 与对象头（核心）

### 3.1 Mark Word（对象头中的 64 bit）

每个 Java 对象头都有一个 Mark Word，用来记录锁状态、GC 年龄、HashCode 等。**64 位 JVM 下的 Mark Word（关键的位）**：

```
锁状态        |  其他信息（25/24/30 bit）              | biased | age | lock
-------------|---------------------------------------|--------|-----|------
无锁          | hashCode (31)                          | 0      | 4 b | 01
偏向锁        | thread_id (54)  | epoch (2)            | 1      | 4 b | 01
轻量级锁      | 指向栈中 Lock Record 的指针           |              | 00
重量级锁      | 指向 ObjectMonitor 的指针             |              | 10
GC 标记       | -                                      |              | 11
```

**lock 字段（最低 2 位）就是锁状态机**。

### 3.2 ObjectMonitor（重量级锁的核心数据结构）

C++ 实现，HotSpot 源码 `objectMonitor.hpp`：

```c++
ObjectMonitor() {
    _header       = NULL;
    _count        = 0;       // 重入次数
    _owner        = NULL;    // 持有锁的线程
    _WaitSet      = NULL;    // 调用 wait() 的线程队列
    _EntryList    = NULL;    // 等待获取锁的线程队列
    _recursions   = 0;
    _cxq          = NULL;    // 多线程争用入口（Contention Queue）
}
```

```
ObjectMonitor 工作流程：
                ┌─────────────┐
                │   Owner     │ ← 当前持有锁的线程
                └──────┬──────┘
                       │ wait()       notify/Exit
                       ▼              ▲
                ┌─────────────┐   ┌──────────┐
                │  WaitSet    │   │EntryList │ ← 阻塞等锁的线程
                └─────────────┘   └──────────┘
                       ▲
                       │ notify / notifyAll
                ┌──────┴──────┐
                │     cxq     │ ← 新来的争抢线程先进 cxq
                └─────────────┘
```

> **WaitSet** = wait() 等通知的线程队列；**EntryList / cxq** = 等锁的线程队列。这是 wait/notify 机制能与 synchronized 配合的根。

### 3.3 重量级锁开销大的根因

进入 ObjectMonitor 要：
1. 用户态 → 内核态切换（pthread_mutex / futex 系统调用）
2. 线程被挂起（park），被唤醒（unpark）
3. 一次切换 ~1-10 μs

**JDK 6 以前 synchronized 直接走重量级**，所以"性能差"的恶名传开。JDK 6 引入锁升级后大幅优化。

---

## 四、锁升级（JDK 6+ 关键优化）

### 4.1 完整状态机

```
                          ↑
          多线程竞争     │  撤销
                       │  代价
        无锁 ───────► 偏向锁 ───────► 轻量级锁 ─────────► 重量级锁
        (01)            (01)             (00)              (10)
                第一次拿锁         多线程交替无竞争    存在真正竞争
                记录 thread_id     CAS 替换 Lock      升级到 OS 互斥量
                                  Record 指针          (mutex/futex)
```

锁**只能升级，不能降级**（JDK 15 之前；之后偏向锁默认关闭）。

### 4.2 偏向锁

**假设**：实际生产代码中，很多锁**始终只有一个线程访问**（例如线程私有的 ArrayList 加 synchronized）。

**优化**：第一次拿锁时，CAS 把当前线程 ID 写到对象头的 thread_id 位，下次同一个线程再拿锁，发现 thread_id 是自己，**直接进入临界区，不做任何同步操作**。

**撤销代价**：一旦有第二个线程来争抢，要做"偏向锁撤销"——必须等到全局安全点（Safe Point），STW 暂停所有线程，撤销原线程的偏向，**这个开销大**。

**结论**：JDK 15 起 **偏向锁默认关闭**（JEP 374，Java 15）。原因：
- 现代代码并发模型不再像旧时代那样"单线程持锁居多"
- 撤销代价 + 维护成本 > 实际收益

```bash
# JDK 8/11 默认开启
-XX:+UseBiasedLocking

# JDK 15+ 默认关闭，需要手动开
-XX:+UseBiasedLocking
```

### 4.3 轻量级锁

**假设**：有多个线程竞争，但**交替执行无真正争用**（同步块时间极短）。

**实现**：
1. 线程进入同步块前，在自己的栈帧分配 **Lock Record**（拷贝当前对象的 Mark Word）
2. CAS 把对象头的 Mark Word 替换成指向自己 Lock Record 的指针
3. CAS 成功 → 拿到锁；失败 → **自旋几次再 CAS**（自适应自旋）
4. 自旋多次仍失败 → 升级到重量级锁

```
            线程 T1 栈帧
            ┌──────────────┐
            │ Lock Record  │ ──┐
            │  (备份 MW)   │   │
            └──────────────┘   │
                               ▼
                        ┌─────────────┐
                        │   对象头     │
                        │  Mark Word   │ ─── 指向 T1 的 Lock Record
                        │   状态: 00   │
                        └─────────────┘
```

**自旋的代价**：占着 CPU 干等。所以**自旋次数有限**：
- JDK 6 默认 10 次（`-XX:PreBlockSpin`）
- JDK 7+ 启用**自适应自旋**：根据上次自旋成功率动态调整（成功率高就多旋几下）

### 4.4 重量级锁

升级到 ObjectMonitor，竞争失败的线程**直接挂起**（不再自旋），等被唤醒。CPU 不浪费，但切换贵。

### 4.5 锁升级的判定流程

```
进入 synchronized：
├─ MW 是无锁状态 (01)
│   ├─ 偏向锁开启：CAS 写 thread_id → 偏向锁
│   └─ 偏向锁关闭：CAS 替换 Lock Record 指针 → 轻量级锁
│
├─ MW 是偏向锁，且 thread_id 是自己 → 直接进
├─ MW 是偏向锁，但 thread_id 不是自己 → 撤销偏向 → 升级轻量级
│
├─ MW 是轻量级锁
│   ├─ 是自己持有 → 重入（栈里加一个 Lock Record，count++）
│   └─ 是别人持有 → CAS 自旋；失败次数过多 → 升级重量级
│
└─ MW 是重量级锁 → 直接进 EntryList 排队
```

---

## 五、三大特性如何保证

### 5.1 原子性

monitorenter / monitorexit 之间，**任何时候只有一个线程执行**，所以代码块内任意操作（哪怕是 `i++` 这种复合）都是原子的。

### 5.2 可见性

JMM 规则：
- 释放锁前（monitorexit 前），把工作内存的修改 flush 到主内存
- 获取锁后（monitorenter 后），清空工作内存，从主内存重新 load

底层实现：lock 释放对应 StoreStoreBarrier + StoreLoadBarrier，加锁对应 LoadLoadBarrier + LoadStoreBarrier。

### 5.3 有序性

锁内的代码 **as-if-serial**——CPU 可以重排，但单线程结果一致。多线程下因为互斥，外面的线程看不到内部任何中间状态。

---

## 六、可重入性

```java
synchronized (lock) {
    System.out.println("level 1");
    synchronized (lock) {                  // 同一个线程
        System.out.println("level 2");     // ← 可以进
        synchronized (lock) {
            System.out.println("level 3"); // ← 也可以进
        }
    }
}
```

**实现**：ObjectMonitor 里的 `_recursions`（重入计数器）。每次同一线程再 enter，计数器 +1；每次 exit，计数器 -1；归零才真正释放。

**避免了什么死锁**：父类 synchronized 方法调子类 synchronized 方法（都锁 this）；递归调用自己的 synchronized 方法。

---

## 七、synchronized vs ReentrantLock

| 维度 | synchronized | ReentrantLock |
| --- | --- | --- |
| 实现层级 | JVM 关键字（C++ ObjectMonitor） | JDK 类库（AQS） |
| 释放锁 | 自动（块结束 / 异常） | **必须 finally 里 unlock()** |
| 可中断 | ❌ | ✅ `lockInterruptibly()` |
| 超时尝试 | ❌ | ✅ `tryLock(t, unit)` |
| 公平锁 | ❌ 非公平 | ✅ 可选（`new ReentrantLock(true)`） |
| 多个等待队列 | ❌ 一个 wait/notify 队列 | ✅ Condition.newCondition() 多个 |
| 性能（JDK 6+） | 接近 ReentrantLock | 略快 |
| 监控 / 调试 | jstack 一目了然 | 需要 Lock 的 API |

**选型**：
- 默认用 **synchronized**（语法简洁、自动释放、JVM 优化好）
- 需要 **超时 / 中断 / 公平 / 多 Condition** 时用 ReentrantLock
- 高并发**读多写少**用 ReadWriteLock
- **不要再迷信** "ReentrantLock 比 synchronized 快"——JDK 6 之后两者差距很小

---

## 八、生产踩坑

### 8.1 锁错对象（最常见）

```java
private Integer count = 0;
public void inc() {
    synchronized (count) {     // ❌ count 每次自增就变成新 Integer 对象（自动装箱）
        count++;
    }
}
```
**修复**：锁定 `private final Object lock = new Object();`，且不要锁基本类型包装器、`String.intern()`、Class 这种全局对象。

### 8.2 双重锁 + 不 volatile = NPE

DCL 单例不加 volatile，重排导致返回半初始化对象。详见 [JMM 内存模型](./JMM内存模型.md#33-有序性ordering)。

### 8.3 同步方法范围过大

```java
public synchronized void process() {
    fetchFromDB();        // 慢 IO 也被锁住
    update(localState);   // 真正需要同步的就这一行
    sendKafka();          // Kafka 发送被锁
}
```
**修复**：缩小到只同步真正共享变量的部分（`synchronized (lock) { update(...) }`）。

### 8.4 偏向锁撤销 STW 卡顿

JDK 8 上 Web 应用启动时，所有 String / HashMap / ArrayList 默认偏向锁；多线程一来全要撤销 → 频繁 STW。
**修复**：`-XX:-UseBiasedLocking` 直接禁用（短时高并发应用建议关）。JDK 15+ 默认就关。

### 8.5 锁的对象被 hashCode 调用导致偏向锁失效

`Object.hashCode()` 会占用 Mark Word 的 31 bit hash 槽，**导致该对象不能作为偏向锁**（因为 thread_id 也要这块位）。生产观察：缓存 key 用 String 当锁会触发这个。
**修复**：锁专用对象（`new Object()`），不要锁有意义的业务对象。

---

## 九、面试高频追问

**Q1：synchronized 是怎么实现可见性的？**
进入同步块时清空工作内存重新 load，退出前 flush 工作内存到主内存——对应 LoadBarrier / StoreLoadBarrier。

**Q2：JDK 6 之前为什么 synchronized 性能差？**
没有锁升级，每次进入都走 ObjectMonitor → pthread_mutex（系统调用 + 上下文切换 ~微秒级）。JDK 6 加偏向 / 轻量级锁后，无竞争场景几乎免费。

**Q3：偏向锁的撤销为什么贵？**
要在全局安全点（Safe Point）暂停所有线程，遍历所有线程栈检查锁记录，决定升级还是撤销。这个 STW 短但频繁，影响低延迟应用。

**Q4：自旋锁好还是阻塞好？**
- 锁持有时间 < 上下文切换开销 → 自旋更优
- 锁持有时间 > 上下文切换开销 → 阻塞更优
JVM 通过自适应自旋（看历史成功率）自动调节。

**Q5：synchronized 锁的是对象还是引用？**
锁的是**对象（Mark Word）**。两个引用指向同一对象 → 锁同一把锁；同一引用变量被 reassign → 锁不同对象。

**Q6：static synchronized 和 实例 synchronized 互斥吗？**
**不互斥**。前者锁 Class 对象，后者锁实例 this，是两把不同的锁。

**Q7：synchronized 和 wait/notify 怎么配合？**
wait / notify 必须在 synchronized 块内调用（否则抛 `IllegalMonitorStateException`），它们操作的是 ObjectMonitor 的 WaitSet / EntryList。详见 [等待唤醒机制](./等待唤醒机制.md)。

**Q8：JDK 21 还需要 synchronized 吗？**
要。虚拟线程（Loom）下 synchronized **会 pin 住载体线程**（虚拟线程不能让出），导致虚拟线程退化。所以虚拟线程 + 同步场景，应优先用 `ReentrantLock`（JDK 21 已优化为不 pin）。

---

## 十、答题模板（90 秒话术）

> synchronized 是 Java 内置锁，三种用法：实例方法（锁 this）、静态方法（锁 Class）、代码块（锁指定对象）。字节码上对应 **monitorenter / monitorexit** 或 **ACC_SYNCHRONIZED 标志**，最终都走 JVM 的 **ObjectMonitor**。
>
> 它通过对象头的 **Mark Word**记录锁状态。**JDK 6 引入锁升级**：无锁 → **偏向锁**（一线程独占，CAS 写 thread_id）→ **轻量级锁**（栈帧里 Lock Record + CAS + 自旋）→ **重量级锁**（升级到 OS 互斥量，挂起线程）。锁只升不降。
>
> 同时保证 **可见性**（释放锁前 flush 主内存）、**原子性**（互斥）、**有序性**（as-if-serial 锁内）、**可重入**（ObjectMonitor 的 `_recursions`）。
>
> 比 ReentrantLock 简单（自动释放），但缺少**超时、中断、多 Condition、公平模式**。生产里默认 synchronized，需要高级特性才换 Lock。
>
> 经典坑：**DCL 不加 volatile**（重排 NPE）、**锁错对象**（基本类型包装、String.intern）、**同步范围过大**（IO 也锁住）、**偏向锁撤销 STW**（JDK 15 默认关）。

---

## 十一、相关文档

- [JMM 内存模型](./JMM内存模型.md) — synchronized 的可见性 / 有序性根基
- [CAS 与原子类](./CAS与原子类.md) — 锁升级里 CAS 是核心原语
- [等待唤醒机制](./等待唤醒机制.md) — wait/notify 与 ObjectMonitor 的关系
- [Lock 原理](./Lock原理.md) — ReentrantLock 对比
- [死锁分析](./死锁分析.md) — synchronized 死锁排查
