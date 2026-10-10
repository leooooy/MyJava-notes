# JMM 内存模型（Java Memory Model）

> 并发问题的"宪法"，所有可见性、有序性、原子性问题都从这里来。
> ① 为什么会有 JMM？为什么不直接用硬件内存模型？
> ② 主内存 / 工作内存到底是什么？跟 CPU 缓存什么关系？
> ③ 8 大原子操作 + 3 大特性（可见性 / 原子性 / 有序性）
> ④ happens-before 8 大规则——多线程"看见对方修改"的官方保证
> ⑤ as-if-serial / 重排序 / 内存屏障

> **本篇是 [Volatile](./Volatile.md) / [Synchronized](./Synchronized.md) / [CAS](./CAS与原子类.md) 的前置基础**，不读 JMM，背下面三个就只是死记硬背。

---

## 一、为什么需要 JMM

### 1.1 物理机的复杂性

一段简单代码 `int a = 1; int b = 2;`，在多核 CPU 上发生了：
1. **多级缓存**：L1 / L2 / L3，CPU 不会每次都读内存
2. **乱序执行**：只要语义不变（as-if-serial），CPU 可以打乱指令顺序提升 IPC
3. **写缓冲区（Store Buffer）**：CPU 写不立即落到 L1，先进 Store Buffer
4. **失效队列（Invalidate Queue）**：MESI 协议下，让别的核失效缓存行也是异步的
5. **编译器优化**：JIT 还会重排、把变量优化进寄存器

如果 Java 直接暴露这些细节，写一行 `boolean flag = true` 都要考虑：要不要 mfence？要不要 cache line padding？写一段并发代码全靠经验玄学。

### 1.2 JMM 的定位

**JMM 是 Java 给程序员的并发抽象**，屏蔽 x86 / ARM / PowerPC 这些底层差异：
- 一段 Java 代码在任何 JVM 实现 + 任何 CPU 架构上，多线程语义一致
- 程序员只需关心 JMM 规则（happens-before），不用读 ARM 手册

**类比**：JMM 之于硬件，类似 SQL 之于 B+Tree——上层抽象，屏蔽底层细节。

---

## 二、JMM 抽象模型

### 2.1 主内存与工作内存

```
        ┌──────────────────────────┐
        │         主内存            │   ← 所有共享变量（堆里的对象、static 变量）
        │   (shared variables)     │
        └──────────────────────────┘
              ▲              ▲
        load/store      load/store
              │              │
        ┌─────┴────┐    ┌────┴─────┐
        │ 工作内存  │    │ 工作内存  │   ← 每个线程私有
        │  (T1)    │    │  (T2)    │      （包含 CPU 缓存 + 寄存器 + 栈）
        └──────────┘    └──────────┘
```

> **重要**：主内存 / 工作内存是 **JMM 的逻辑抽象**，不是物理实体。
> 物理上，工作内存对应 **CPU 寄存器 + Store Buffer + L1/L2 缓存**，主内存对应 **DRAM + L3**。

### 2.2 8 大原子操作（JLS 定义）

线程操作变量必须经过这 8 步（虽然现在 JSR-133 之后规则更精细，但理解上仍是这套）：

| 操作 | 作用域 | 含义 |
| --- | --- | --- |
| `lock` | 主内存 | 把变量标识为线程独占 |
| `unlock` | 主内存 | 释放独占 |
| `read` | 主内存 → 工作内存 | 读出 |
| `load` | 工作内存 | 把 read 的值放到副本 |
| `use` | 工作内存 → 执行引擎 | 用变量 |
| `assign` | 执行引擎 → 工作内存 | 改变量 |
| `store` | 工作内存 → 主内存 | 准备写回 |
| `write` | 主内存 | 写入 |

**关键约束**：
- read & load 必须成对，store & write 必须成对
- 对一个变量执行 lock 之前，必须 clear 工作内存副本，重新 load（**这就是 synchronized 保证可见性的根**）
- 对一个变量 unlock 之前必须 store + write 回主内存

---

## 三、并发三大特性

### 3.1 原子性（Atomicity）

**操作不可被中断**。

| 是 | 否 |
| --- | --- |
| 基本类型 read/write（除 long/double） | `i++`（read+1+write 三步） |
| `synchronized` 块 | `volatile` 变量的复合操作 |
| `Atomic*` 类的方法（CAS） | 多个原子操作的组合 |

**陷阱**：32 位 JVM 上 `long` 和 `double` 的读写**不是原子的**（高 32 位 + 低 32 位分两次写）。可能读到一半旧值一半新值。`volatile long` 才是原子的（JLS 强制）。64 位 JVM 上自然原子。

### 3.2 可见性（Visibility）

**一个线程修改了共享变量，其他线程能立即看到**。

不可见的根因：
- 线程 A 改了变量，值还在自己 CPU 缓存里没刷主内存
- 线程 B 从自己缓存读，读到旧值

JMM 提供的可见性保证：
| 机制 | 可见性保证 |
| --- | --- |
| `volatile` | 写后立即刷主内存；读前必须重读主内存 |
| `synchronized` | 释放锁前，把工作内存刷主内存；获取锁后，清空工作内存重新 load |
| `final` | 构造函数结束后，final 字段对所有线程可见（前提：构造期不要把 this 逸出） |
| `Thread.start()` / `join()` | start 之前的写对新线程可见；线程结束的写对调 join 的线程可见 |

### 3.3 有序性（Ordering）

**程序代码的执行顺序与代码顺序一致**。

不有序的根因（重排序的 3 个来源）：
1. **编译器重排序**：JIT 优化（如循环展开）
2. **CPU 重排序**：流水线、乱序执行
3. **内存系统重排序**：Store Buffer、写合并

**as-if-serial 语义**：单线程内，编译器 + CPU 不管怎么重排，结果必须和顺序执行一样。所以单线程感知不到重排。

**多线程下重排会出问题**。经典例子：双重检查锁（DCL）单例

```java
public class Singleton {
    private static /* 没加 volatile */ Singleton instance;

    public static Singleton get() {
        if (instance == null) {
            synchronized (Singleton.class) {
                if (instance == null) {
                    instance = new Singleton();
                    //         ↑ 这一行不是原子的，分 3 步：
                    //         (1) 分配内存
                    //         (2) 初始化对象
                    //         (3) instance 指向内存
                    // 编译器/CPU 可能重排成 (1)(3)(2)
                    // 此时另一线程 if (instance == null) 拿到的是没初始化的对象 → NPE / 字段全 0
                }
            }
        }
        return instance;
    }
}
```

修复：`private static volatile Singleton instance;`，volatile 禁止 (2)(3) 重排。

---

## 四、happens-before 规则（JMM 灵魂）

### 4.1 为什么有 happens-before

JLS 不直接说"什么时候会重排"（太底层），而是用 happens-before 给程序员**看得见的保证**：
> 如果操作 A happens-before 操作 B，那么 A 的所有写对 B 可见。

8 大规则（必背）：

| # | 规则 | 含义 |
| --- | --- | --- |
| 1 | **程序顺序规则** | 单线程内，代码前面的语句 happens-before 后面的（结果上） |
| 2 | **监视器锁规则** | 解锁 happens-before 后续对同一锁的加锁 |
| 3 | **volatile 变量规则** | 对 volatile 变量的写 happens-before 后续对它的读 |
| 4 | **传递性** | A → B 且 B → C，那么 A → C |
| 5 | **start 规则** | `Thread.start()` happens-before 该线程内的任何动作 |
| 6 | **join 规则** | 线程内的所有动作 happens-before 别的线程从该线程 `join()` 返回 |
| 7 | **interrupt 规则** | `interrupt()` 调用 happens-before 被中断线程检测到中断 |
| 8 | **finalizer 规则** | 对象构造结束 happens-before 它的 finalize() |

### 4.2 实战例子

```java
class Box {
    int value;
    volatile boolean ready;     // ★

    void writer() {
        value = 42;             // (1)
        ready = true;           // (2) volatile 写
    }

    void reader() {
        if (ready) {            // (3) volatile 读
            assert value == 42; // (4)
        }
    }
}
```

证明 (4) 一定成立：
- 程序顺序：(1) → (2)
- volatile：(2) → (3)
- 程序顺序：(3) → (4)
- 传递性：(1) → (4) ✅

**这就是 volatile 的"附带可见性"**——配合普通变量可以无锁实现简单同步。

---

## 五、内存屏障（Memory Barrier）

JMM 是规范，落到实现是 **JVM 在编译时插入内存屏障指令**（CPU 级别）。

### 5.1 4 种屏障

| 屏障 | 含义 | x86 实现 |
| --- | --- | --- |
| **LoadLoad** | 屏障前的读，必须先于屏障后的读完成 | x86 强一致，不需要 |
| **StoreStore** | 屏障前的写，先于屏障后的写完成 | x86 强一致，不需要 |
| **LoadStore** | 屏障前的读，先于屏障后的写完成 | x86 强一致，不需要 |
| **StoreLoad** | 屏障前的写，先于屏障后的读完成 | `mfence` / `lock addl $0,(%rsp)` |

x86 是 **TSO（Total Store Order）**模型，自带前 3 种屏障；只有 StoreLoad 需要显式插入。所以 x86 上 volatile 写 = `lock` 前缀指令，volatile 读几乎免费。
ARM 是弱内存模型，4 种都得插入屏障，volatile 在 ARM 上比 x86 更贵。

### 5.2 volatile 屏障

JVM 给 volatile 字段插入：
```
普通写 / 读
[StoreStoreBarrier]   ← 写 volatile 前，所有普通写必须先完成
volatile 写
[StoreLoadBarrier]    ← 写 volatile 后，强制刷主内存

[LoadLoadBarrier]     ← 读 volatile 前，最新值必须从主内存读
volatile 读
[LoadStoreBarrier]    ← 读 volatile 后，后续操作不能往前重排
普通读 / 写
```

**详见 [JVM 内存屏障](../JVM/内存屏障.md)**。

---

## 六、生产踩坑

### 6.1 DCL 单例不加 volatile（最经典）

**现象**：偶现 NPE，对象字段是默认值（0 / null）。
**根因**：构造未完成，对象引用就赋值出去了（指令重排）。
**修复**：`private static volatile Singleton instance;` 或者直接用静态内部类 / 枚举单例。

### 6.2 long 在 32 位 JVM 上读到撕裂值

**现象**：32 位 ARM 嵌入式 JVM，long 计数器偶尔变成 `0xFFFFFFFF00000000` 这种鬼值。
**根因**：long 写分两次 32 位完成，读到中间状态。
**修复**：加 `volatile`，或换 64 位 JVM。

### 6.3 没有 happens-before 关系，普通变量永远不可见

```java
// 错的
class Stop {
    boolean stopped = false;     // 不加 volatile

    void run() {
        while (!stopped) { ... } // 优化器可能把 stopped 提到寄存器，永远读不到 true
    }
    void stop() { stopped = true; }
}
```

**根因**：JIT 在循环体里发现 stopped 没在循环里被改，优化成 `while (true)`。
**修复**：`volatile boolean stopped`。

---

## 七、面试高频追问

**Q1：volatile 是怎么保证可见性的？为什么不能保证原子性？**
- 可见性：写之后立刻 flush 到主内存（StoreLoad 屏障），读前从主内存重读
- 原子性：volatile 只对**单个变量的读 / 写**原子，`i++` 是 read+1+write 三步，volatile 不解决

**Q2：synchronized 比 volatile 强在哪？**
- volatile：可见性 + 有序性，**不保证复合操作原子**
- synchronized：可见性 + 有序性 + 原子性（互斥）+ 可重入 + 阻塞语义

**Q3：double-check locking 为什么要 volatile？**
对象初始化的 (1)(2)(3) 三步，如果重排成 (1)(3)(2)，另一个线程可能拿到 "引用非空但字段未初始化" 的对象。volatile 禁止 (2)(3) 间的重排序。

**Q4：as-if-serial 和 happens-before 区别？**
- as-if-serial：**单线程**保证，重排不影响单线程结果
- happens-before：**多线程**保证，定义"什么时候 A 的写对 B 可见"

**Q5：x86 的 volatile 比 ARM 便宜，为什么？**
x86 是强内存模型（TSO），LoadLoad / StoreStore / LoadStore 屏障是免费的，只有 StoreLoad 需要 mfence；ARM 是弱模型，4 种都得插 dmb 指令，所以同样的 volatile 在 ARM 上更慢。

**Q6：final 字段的内存语义？**
构造函数中对 final 字段的写，与"构造完成把 this 引用赋值给共享变量"之间，有 StoreStore 屏障，保证：**只要 this 引用不在构造期间逸出**，其他线程拿到 this 引用时一定能看到 final 字段已初始化。

---

## 八、答题模板（60 秒话术）

> JMM 是 Java 给程序员的**并发抽象**，屏蔽 x86 / ARM 等底层差异。它定义了**主内存 + 每个线程的工作内存**，规定了 8 种原子操作和**可见性 / 原子性 / 有序性**三大特性。
>
> 真正落地的契约是 **happens-before**：A happens-before B，那 A 的所有写对 B 可见。8 条规则里最常用的是 **volatile 规则、锁规则、传递性、start/join 规则**。
>
> volatile 的可见性靠**内存屏障**实现：写 volatile 前后插 StoreStore / StoreLoad，读 volatile 前后插 LoadLoad / LoadStore。x86 强一致，几乎只有 StoreLoad 实际有指令开销；ARM 弱一致 4 种都得插。
>
> 经典踩坑是 **DCL 单例不加 volatile**——对象初始化 (1)(2)(3) 重排导致返回半初始化对象。修复就是 volatile 禁止指令重排。

---

## 九、相关文档

- [Volatile](./Volatile.md) — JMM 落地的最轻量同步原语
- [Synchronized](./Synchronized.md) — 同时保证三大特性的重锁
- [CAS 与原子类](./CAS与原子类.md) — 无锁原子化
- [JVM 内存模型](../JVM/内存模型.md) — 同主题，JVM 视角的细节
- [JVM 内存屏障](../JVM/内存屏障.md) — JMM 屏障的 CPU 落地指令
- [JVM 内存与 OS：MMU / 虚拟内存](../JVM/JVM内存与OS-MMU虚拟内存.md) — **注意区分**：本篇是语言层多线程语义，MMU 是硬件层虚拟地址翻译，两者正交
