# CAS 与原子类

> 无锁并发的核心原语，AQS / ConcurrentHashMap / ThreadPoolExecutor 全靠它。本篇讲清：
> ① CAS 是什么、CPU 怎么实现（cmpxchg / lock 前缀）
> ② 三大问题：ABA、自旋开销、单变量限制
> ③ Atomic 系列：AtomicInteger / AtomicReference / AtomicStampedReference
> ④ JDK 8 的 LongAdder：高竞争场景为什么比 AtomicLong 快 10×
> ⑤ Unsafe / VarHandle 关系

> 前置：[JMM 内存模型](./JMM内存模型.md)、[Volatile](./Volatile.md)

---

## 一、CAS 原理

### 1.1 一句话定义

**Compare And Swap**：如果内存值等于期望值 E，就把它设为新值 N，并返回 true；否则返回 false。

```c
bool CAS(addr, expect, newVal) {
    if (*addr == expect) { *addr = newVal; return true; }
    return false;
}
```

整个过程**由 CPU 单条指令完成，原子的**。x86 上是：
```
lock cmpxchg %rdx, (%rdi)
```
- `cmpxchg`：比较并交换
- `lock` 前缀：锁定缓存行（MESI），其他核此时不能读写这个缓存行

### 1.2 为什么叫"乐观锁"

CAS **不阻塞**：失败就重试，假设"大多数时候没人和我抢"。这是数据库乐观锁（version 字段）思路的硬件版。

| | 悲观锁（synchronized） | 乐观锁（CAS） |
| --- | --- | --- |
| 假设 | 一定会有冲突 | 大概率没冲突 |
| 实现 | 阻塞 / 挂起线程 | 自旋重试 |
| 适用 | 高竞争、临界区长 | 低竞争、临界区短 |
| 开销 | 上下文切换 | CPU 自旋 |

---

## 二、CAS 的三大问题

### 2.1 ABA 问题

**场景**：T1 读到 A，准备 CAS 改成 C；中间 T2 改成 B 又改回 A；T1 的 CAS 仍成功，但中间发生过变化没察觉。

**典型踩坑**：链表头删除场景
```
初始链表：A → B → C
T1 读 head=A，准备 CAS 把 head 改成 B
T2 完成：删 A、删 B、回插 A，链表变 A → C
T1 的 CAS(head, A, B) 仍然成功 → 链表变 B（一个野指针！）
```

**解决方案**：加版本号 `AtomicStampedReference<V>`：
```java
AtomicStampedReference<Node> head = new AtomicStampedReference<>(a, 0);
int[] stamp = new int[1];
Node cur = head.get(stamp);
head.compareAndSet(cur, newNode, stamp[0], stamp[0]+1);  // 版本号必须也匹配
```

### 2.2 自旋开销

CAS 失败要重试，**高竞争时 CPU 一直在循环**。极端情况几个线程互相抢，几乎都在自旋空转，CPU 吃满吞吐反而下降。

**对策**：
- JDK 6+ 自适应自旋（自旋几次失败就 yield 或 park）
- 高竞争换 **LongAdder** / 锁

### 2.3 只能保证单变量原子

```java
// CAS 不能直接做这种"两个字段同时改"
if (low < high) { low++; high--; }
```
**对策**：
- 把多个字段塞一个对象，对**对象引用**做 CAS（`AtomicReference`）
- 用锁

---

## 三、Atomic 系列

### 3.1 全家桶

| 类 | 作用 |
| --- | --- |
| `AtomicInteger` / `Long` / `Boolean` | 单值原子操作 |
| `AtomicIntegerArray` / `LongArray` / `ReferenceArray` | 数组元素原子操作（注意：volatile 数组的元素不是 volatile） |
| `AtomicReference<V>` | 对象引用原子操作 |
| `AtomicStampedReference<V>` | 带版本号引用，**解 ABA** |
| `AtomicMarkableReference<V>` | 带 boolean 标记 |
| `AtomicIntegerFieldUpdater<T>` | 反射式更新对象字段（不用 wrap，省内存） |
| `LongAdder` / `DoubleAdder` | **JDK 8 引入**，高并发计数器 |
| `LongAccumulator` | 自定义累加函数（min / max / 区间累加） |

### 3.2 AtomicInteger 源码核心

```java
public final int incrementAndGet() {
    return unsafe.getAndAddInt(this, valueOffset, 1) + 1;
}

// JDK 8 后由 Unsafe 提供
public final int getAndAddInt(Object o, long offset, int delta) {
    int v;
    do {
        v = getIntVolatile(o, offset);
    } while (!compareAndSwapInt(o, offset, v, v + delta));   // 失败重试
    return v;
}
```

### 3.3 实战例子

```java
// 1. 计数器
AtomicLong counter = new AtomicLong();
counter.incrementAndGet();

// 2. 无锁状态机
AtomicInteger state = new AtomicInteger(INIT);
while (true) {
    int s = state.get();
    if (s == TERMINATED) break;
    if (state.compareAndSet(s, s + 1)) doWork();   // 状态推进
}

// 3. 无锁单例延迟初始化
AtomicReference<Singleton> INSTANCE = new AtomicReference<>();
public static Singleton get() {
    Singleton s = INSTANCE.get();
    if (s == null) {
        s = new Singleton();
        if (!INSTANCE.compareAndSet(null, s)) s = INSTANCE.get();
    }
    return s;
}
```

---

## 四、LongAdder：高竞争利器（JDK 8）

### 4.1 痛点：AtomicLong 在高竞争下慢

`AtomicLong.incrementAndGet()` 在 64 个线程压测下，**所有线程争用同一个 value 的缓存行** → 大量 CAS 失败 + 缓存行乒乓 → 吞吐反而下降。

### 4.2 LongAdder 思路：分段累加

```
        ┌──────────────────────────────────────┐
        │  LongAdder                            │
        ├──────────────────────────────────────┤
        │  base   (低竞争时只用这个)            │
        ├──────────────────────────────────────┤
        │  cells[]  (高竞争时分散到多个 Cell)   │
        │   ┌───┬───┬───┬───┬───┬───┬───┬───┐ │
        │   │ C │ C │ C │ C │ C │ C │ C │ C │ │ 数组长度自动扩容
        │   └───┴───┴───┴───┴───┴───┴───┴───┘ │
        └──────────────────────────────────────┘
```

每个 Cell 用 `@Contended` 注解填充到 128 字节，**消除伪共享**。线程根据 hash 分散到不同 Cell 上 CAS。

`sum()` 时把 base + 所有 cells 加起来——**结果可能不实时一致**，但单调正确。

### 4.3 性能对比（粗略）

64 线程 1 亿次累加（i7-9700K）：
- AtomicLong：~3.5 秒
- LongAdder：~0.4 秒（**约 8-10× 提速**）
- synchronized：~5 秒

### 4.4 选型

| 场景 | 选 |
| --- | --- |
| 写少（读多） | AtomicLong（sum 实时准确） |
| 写多 + 不需要实时一致读 | LongAdder（计数器 / 监控指标 / QPS 统计）|
| 需要原子的 max / min / 自定义聚合 | LongAccumulator |

---

## 五、Unsafe 与 VarHandle

### 5.1 Unsafe（JDK 内部"作弊器"）

`sun.misc.Unsafe` 提供原生 CAS / 内存屏障 / 直接内存操作。**Atomic 类、AQS、ConcurrentHashMap、Disruptor、Netty** 全靠它。

```java
// 反射拿 Unsafe（JDK 9+ 模块化后官方不让用，但反射依然能拿）
Field f = Unsafe.class.getDeclaredField("theUnsafe");
f.setAccessible(true);
Unsafe unsafe = (Unsafe) f.get(null);

// 核心 API
unsafe.compareAndSwapInt(obj, offset, expect, update);
unsafe.compareAndSwapLong(obj, offset, expect, update);
unsafe.compareAndSwapObject(obj, offset, expect, update);
unsafe.objectFieldOffset(field);
unsafe.allocateMemory(bytes);   // 直接内存
unsafe.putOrderedInt(...);      // 不强制屏障的 store
```

JDK 9+ 不推荐业务代码用 Unsafe（可能被移除），改用 VarHandle。

### 5.2 VarHandle（JDK 9+ 官方替代）

```java
public class Counter {
    private volatile int value;
    private static final VarHandle VH;
    static {
        try {
            VH = MethodHandles.lookup()
                  .findVarHandle(Counter.class, "value", int.class);
        } catch (Exception e) { throw new Error(e); }
    }

    public boolean cas(int expect, int update) {
        return VH.compareAndSet(this, expect, update);
    }
    public int getAcquire() { return (int) VH.getAcquire(this); }
    public void setRelease(int v) { VH.setRelease(this, v); }
}
```

**VarHandle 的内存语义**（按强度排序）：
| API | 语义 | 用途 |
| --- | --- | --- |
| `getVolatile` / `setVolatile` | 等同 volatile | 一般场景 |
| `getAcquire` / `setRelease` | 单向屏障，比 volatile 弱 | 生产者-消费者 |
| `getOpaque` / `setOpaque` | 仅原子无屏障 | 性能敏感、不需要可见性 |
| `getPlain` / `setPlain` | 普通读写 | 不要求并发的场景 |

业务代码 99% 场景用不到 VarHandle，**框架代码（Disruptor / Netty 4.x+）开始用**。

---

## 六、CAS 在 JUC 的应用

| 组件 | 怎么用 CAS |
| --- | --- |
| **AtomicInteger** | 直接 `compareAndSwapInt` |
| **AQS** | CAS state、CAS 队列尾节点 |
| **ConcurrentHashMap** | 桶为空时 CAS 插入；扩容时 CAS forwardingNode |
| **ThreadPoolExecutor** | CAS 修改 ctl（高位状态 + 低位 worker 数） |
| **CopyOnWriteArrayList** | 写时拷贝完新数组，CAS 替换引用 |
| **Synchronized 锁升级** | 偏向锁 / 轻量级锁的 CAS Mark Word |

---

## 七、生产踩坑

### 7.1 用 AtomicLong 做高 QPS 计数器，CPU 飚到 100%

**现象**：监控埋点用 AtomicLong 累加 QPS，单机 50w QPS 时 CPU 莫名跑满。
**根因**：所有线程 CAS 同一个变量 → 缓存行乒乓 + 大量 CAS 失败重试。
**修复**：换 LongAdder，CPU 立刻降一半。

### 7.2 ABA 导致链表错乱

**现象**：自研无锁队列偶发 NPE / 数据错乱。
**根因**：节点被回收又重用（ABA）。
**修复**：换 `AtomicStampedReference`，或者用 `Treiber Stack` + GC。

### 7.3 自旋过度导致延迟抖动

**现象**：低延迟交易系统延迟 P99 飙高。
**根因**：高竞争下大量自旋在 CAS 失败循环里，影响别的线程拿 CPU。
**修复**：高竞争锁直接换 ReentrantLock 或换数据结构（分段、按 key hash 分流）。

### 7.4 误用 Atomic 系列以为能锁住"复合操作"

```java
// ❌ 这个不是原子的！
if (atomicCounter.get() < 100) {
    atomicCounter.incrementAndGet();
}
```
两步之间另一个线程可能改了值。**正确**：
```java
atomicCounter.updateAndGet(v -> v < 100 ? v + 1 : v);   // JDK 8+
```
或者直接用锁。

---

## 八、面试高频追问

**Q1：CAS 在 CPU 层是什么指令？**
x86 是 `lock cmpxchg`，ARM 是 `LDREX/STREX` 对（Load-Exclusive / Store-Exclusive）。`lock` 前缀让指令锁定对应缓存行（MESI 协议下进入 Modified 态独占），保证原子性。

**Q2：CAS 一定线程安全吗？**
**对单变量**线程安全。对多变量（如同时改 a 和 b）不安全，需要把多变量打包成对象后对引用做 CAS。

**Q3：ABA 问题怎么解？**
- `AtomicStampedReference`（版本号）
- `AtomicMarkableReference`（boolean 标记）
- 业务场景里 ABA 不一定有害（如计数器，A→B→A 的中间状态没意义），具体看场景

**Q4：Atomic 类比 synchronized 一定快吗？**
- 低竞争：**Atomic 快得多**（无阻塞）
- 高竞争：**Atomic 反而慢**（自旋空转 + 缓存行乒乓），synchronized 走重量级锁阻塞反而省 CPU
- 生产经验：高竞争 + 计数类场景换 LongAdder

**Q5：LongAdder 的 sum() 准确吗？**
**最终一致，不实时一致**。sum 时累加 base + 所有 cells，但累加过程中其他线程可能继续写。所以 LongAdder 不适合"必须实时精确"的场景（如金融余额）。

**Q6：volatile + CAS 能完全替代 synchronized 吗？**
不能。
- 临界区有多步操作（保护代码段而非单变量）→ 必须锁
- 高竞争下 CAS 自旋反而 CPU 浪费 → 锁更优
- 需要等待唤醒（wait/notify）→ 必须锁
但 **大多数细粒度同步**（计数器、状态机、无锁队列）CAS 优于锁。

**Q7：为什么 Atomic 字段都加 volatile？**
保证读到最新值（可见性）。CAS 只解决写的原子性，但读如果不 volatile，可能读到 CPU 缓存的过期副本，CAS 必败循环。

---

## 九、答题模板（60 秒话术）

> CAS（Compare-And-Swap）是 CPU 提供的**单条原子指令**（x86 的 `lock cmpxchg`），实现"内存值 == 期望值就改成新值"。是 Java 无锁并发的基石。
>
> 三大问题：**ABA**（用版本号 AtomicStampedReference 解）、**自旋开销**（高竞争 CPU 浪费）、**只能单变量原子**（多字段要打包成对象 CAS 引用）。
>
> JDK 提供 `Atomic*` 全家桶；JDK 8 新增的 **LongAdder** 用**分段累加 + @Contended 消除伪共享**，高竞争场景比 AtomicLong 快 8-10 倍。
>
> 底层 API 是 `Unsafe`，JDK 9+ 推荐 **VarHandle**（提供 acquire/release / opaque 等更细粒度的内存语义）。
>
> 选型：低竞争用 Atomic、高写少读用 LongAdder、复合操作 / 等待通知用锁。

---

## 十、相关文档

- [JMM 内存模型](./JMM内存模型.md) — CAS 依赖的可见性
- [Volatile](./Volatile.md) — Atomic 字段的 volatile 必备
- [AQS 原理](./AQS原理.md) — JUC 锁框架，state 全靠 CAS
- [ConcurrentHashMap](./ConcurrentHashMap.md) — JDK 8 实现里 CAS 的应用
- [Synchronized](./Synchronized.md) — 锁升级也用 CAS 替换 Mark Word
