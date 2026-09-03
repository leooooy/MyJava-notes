# Volatile

> Java 最轻量级的同步机制。面试几乎必考：
> ① volatile 三大语义：可见性、有序性、单变量读写原子性
> ② 为什么 volatile **不能**保证 `i++` 原子？
> ③ volatile 的字节码 / 内存屏障到底插了什么？
> ④ volatile 适合什么场景？典型用例（DCL、状态标志、读多写少）
> ⑤ 和 synchronized / atomic / final 的区别

> 前置：[JMM 内存模型](./JMM内存模型.md)。读完 JMM 再看本篇会顺很多。

---

## 一、volatile 三大语义

### 1.1 可见性

写 volatile 变量，**立即刷主内存**；读 volatile 变量，**从主内存读**（绕开 CPU 缓存的过期副本）。

```java
class StopFlag {
    volatile boolean stop = false;     // 不加 volatile，下面循环可能永远跑

    void worker() {
        while (!stop) { doWork(); }
    }
    void shutdown() { stop = true; }
}
```

不加 volatile 的话，JIT 会把 `stop` 优化进寄存器，循环里永远读到 false。

### 1.2 有序性（禁止指令重排）

JVM 在 volatile 写前后插内存屏障，**禁止重排序穿越屏障**。这是 DCL 单例必须 volatile 的根因。

### 1.3 单变量读写的原子性

仅对 **单一 volatile 变量的 read / write**原子，**不对复合操作（read-modify-write）原子**。

```java
volatile int counter = 0;
counter++;        // 不是原子！read + 1 + write 三步
```

> JLS 强制：**`volatile long` / `volatile double` 在 32 位 JVM 上的读写也必须原子**（普通 long/double 不保证）。

---

## 二、原理：内存屏障

### 2.1 JVM 插入的屏障

JSR-133 规定，对 volatile 字段：

```
（普通操作）
─── StoreStoreBarrier ───   写 volatile 前，所有普通写必须完成
volatile 写
─── StoreLoadBarrier ────   写后强制刷主内存（最贵的屏障）

─── LoadLoadBarrier ────    读 volatile 前，强制重读主内存
volatile 读
─── LoadStoreBarrier ───    读后续操作不能往前越界
（普通操作）
```

### 2.2 落到 x86 的指令

x86 是 TSO 强一致模型，前 3 种屏障是免费的，只有 StoreLoad 需要：
```
lock addl $0x0, (%rsp)      ; 或 mfence；通常用 lock; addl 因为 mfence 慢
```
`lock` 前缀有两个作用：
1. 锁总线 / 缓存行（实现原子）
2. 充当全屏障（实现 StoreLoad）

**所以 x86 上 volatile 写约比普通写慢 1~3 倍，volatile 读几乎免费。** ARM 弱模型上 volatile 写贵很多（要插 dmb ish）。

### 2.3 字节码层面

volatile 在字节码上**没有特殊指令**，区别只在 class 文件的字段 access_flag 上有 `ACC_VOLATILE` 标志（0x40）。JIT 编译时根据这个标志插屏障。

```bash
javap -v Foo.class | grep volatile
# private volatile boolean stop;
#  flags: ACC_PRIVATE, ACC_VOLATILE
```

---

## 三、什么时候能用 volatile（必须同时满足）

- **写不依赖当前值**：`flag = true` ✅；`counter = counter + 1` ❌
- **不与其他变量构成不变约束**：单独的状态位 ✅；`if (low < high)` 类型的多变量约束 ❌

简而言之：**只能保证单变量原子读写**，复合操作 / 多变量约束都不行。

### 3.1 典型用例

**用例 1：状态标志位**
```java
volatile boolean shutdown;
while (!shutdown) { doWork(); }
```

**用例 2：双重检查锁单例**
```java
class Singleton {
    private static volatile Singleton INSTANCE;
    public static Singleton get() {
        if (INSTANCE == null) {
            synchronized (Singleton.class) {
                if (INSTANCE == null) INSTANCE = new Singleton();
            }
        }
        return INSTANCE;
    }
}
```

**用例 3：发布不可变对象**
```java
volatile ImmutableConfig config;
// 任意线程：config = newConfig 后，所有线程能立即看到
```

**用例 4：与 CAS 配合实现无锁**
```java
class AtomicCounter {
    private volatile int value;
    public int incrementAndGet() {
        for (;;) {
            int cur = value;
            if (UNSAFE.compareAndSwapInt(this, OFFSET, cur, cur + 1)) return cur + 1;
        }
    }
}
```

---

## 四、volatile vs synchronized vs Atomic vs final

| 维度 | volatile | synchronized | Atomic* | final |
| --- | --- | --- | --- | --- |
| 可见性 | ✅ | ✅ | ✅ | ✅（构造完成后） |
| 有序性 | ✅（禁止重排） | ✅（块内单线程） | ✅ | ✅（构造期屏障） |
| 原子性 | ⚠️ 单读/写原子 | ✅ 块内任意 | ✅ CAS | n/a |
| 阻塞 | ❌ 非阻塞 | ✅ 阻塞 | ❌ 非阻塞自旋 | n/a |
| 性能 | 最快（接近普通变量） | 慢（重锁更慢） | 中（自旋成本） | 最快 |
| 适用 | 单变量、状态位 | 任意复合操作 | 计数器、累加 | 不可变字段 |

---

## 五、volatile 不能保证原子的"陷阱代码"

```java
class Counter {
    volatile int n = 0;
    void inc() { n++; }   // ❌ 多线程下结果不对
}

// 1000 个线程各调 1000 次 inc()，结果 ≠ 100 万

// 修复方案
// (a) AtomicInteger
private final AtomicInteger n = new AtomicInteger();
void inc() { n.incrementAndGet(); }

// (b) synchronized
private int n;
synchronized void inc() { n++; }

// (c) LongAdder（高竞争场景，分段累加）
private final LongAdder n = new LongAdder();
void inc() { n.increment(); }
```

---

## 六、生产踩坑

### 6.1 误以为 volatile 能保证 `i++` 原子

**现象**：用 `volatile int counter` 做计数器，QPS 监控数字偏低。
**根因**：`counter++` 是三步，多线程会丢更新。
**修复**：换 `AtomicInteger` 或 `LongAdder`（高并发时 LongAdder 性能更好——分段 Cell 减少竞争）。

### 6.2 用 volatile 包装 HashMap 当并发容器

**现象**：`volatile HashMap<K,V> cache;` 多线程 put 偶发死循环（JDK 7 旧版）或丢数据。
**根因**：volatile 只保证引用本身的可见性，不保证 HashMap 内部结构线程安全。
**修复**：直接用 `ConcurrentHashMap`。volatile 字段适合"整体替换"的不可变对象，不适合"原地修改"的可变结构。

### 6.3 volatile 数组的元素不享受 volatile 语义

```java
volatile int[] arr = new int[10];
arr[0] = 1;   // 这次写 arr[0] 没有 volatile 语义！
```
volatile 修饰的是引用，不是数组元素。需要数组元素 volatile 语义，用 `AtomicIntegerArray` / `VarHandle.getAcquire/setRelease`。

### 6.4 long/double 的 32 位 JVM 撕裂

32 位嵌入式 JVM 上，普通 long 字段读到 `0xFFFFFFFF00000000`（高低 32 位分两次写撕裂）。修复：加 `volatile` 或换 64 位 JVM。

---

## 七、面试高频追问

**Q1：volatile 怎么保证可见性？**
JVM 在写 volatile 后插 StoreLoadBarrier（x86 上是 `lock addl $0,(%rsp)`），强制刷 Store Buffer 到主内存，并使其他 CPU 缓存失效（MESI 协议）；读前插 LoadLoad，从主内存重读。

**Q2：volatile 怎么禁止重排序？**
通过 4 种屏障：StoreStore / StoreLoad / LoadLoad / LoadStore。这些屏障告诉编译器和 CPU"这条线两边的指令不能交换"。

**Q3：volatile 性能开销大吗？**
- x86 读：几乎为零
- x86 写：~10ns（lock 前缀 + 缓存行失效广播）
- ARM 读 / 写都贵（要 dmb 屏障）
比 synchronized（重锁 100ns+ 加阻塞）便宜得多，但比普通变量贵。

**Q4：DCL 单例为什么必须 volatile？**
`new Singleton()` 分三步：(1) 分配内存 (2) 初始化 (3) 引用赋值。CPU 可以重排成 (1)(3)(2)，导致另一个线程看到非空但未初始化的对象（NPE / 字段全 0）。volatile 禁止 (2)(3) 重排。

**Q5：volatile 能替代锁吗？**
不能。volatile 不解决：
- 复合操作（i++ / check-then-act）
- 多变量不变约束
- 互斥访问代码段
这些场景必须用 synchronized / Lock / Atomic。

**Q6：JMM 中 volatile 和 final 的区别？**
- volatile：变量任何时候改都立即可见
- final：构造函数结束时一次性可见，之后不可变

**Q7：JDK 9+ 的 VarHandle 跟 volatile 啥关系？**
VarHandle 提供更细粒度的内存语义控制：`getVolatile/setVolatile`（同 volatile）、`getAcquire/setRelease`（更弱、更快）、`getOpaque`（最弱、单变量原子但无屏障）。生产代码很少直接用，主要用于框架（Disruptor、Netty）。

---

## 八、答题模板（60 秒话术）

> volatile 是 Java 最轻量级的同步原语，提供三个语义：**可见性**（写后刷主内存、读前从主内存）、**有序性**（禁止指令重排）、**单变量读写原子性**。
>
> 它**不保证复合操作原子**，所以 `i++` 仍会丢更新。原理是 JVM 编译时插入**内存屏障**（StoreStore / StoreLoad / LoadLoad / LoadStore），x86 上 StoreLoad 落到 `lock addl` 指令。
>
> 典型用例：**状态标志、DCL 单例、不可变对象的发布、配合 CAS 实现无锁**。
>
> 不适合的场景：计数器（用 AtomicInteger / LongAdder）、复合状态（用 synchronized / Lock）、原地修改的容器（用 ConcurrentHashMap）。
>
> 它和 synchronized 的最大区别：volatile **不阻塞**、不互斥、不解决原子性；synchronized 都解决，但更重。

---

## 九、相关文档

- [JMM 内存模型](./JMM内存模型.md) — volatile 的理论根基
- [JVM 内存屏障](../JVM/内存屏障.md) — 4 种屏障的 CPU 实现
- [Synchronized](./Synchronized.md) — 重锁版同步
- [CAS 与原子类](./CAS与原子类.md) — volatile + CAS 实现无锁
