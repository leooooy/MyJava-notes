# ConcurrentHashMap

> JUC 最常考的容器。本篇讲清：
> ① HashMap 多线程为什么会"死循环"？
> ② JDK 1.7 分段锁（Segment）：16 段独立 ReentrantLock
> ③ JDK 1.8 改造：Node + CAS + synchronized + 红黑树
> ④ put / get / 扩容 / size 流程详解
> ⑤ 为什么禁止 null 键 / 值
> ⑥ 弱一致性迭代器、并发扩容
> ⑦ 与 Hashtable / Collections.synchronizedMap 性能对比

> 前置：[Java HashMap](../Java/HashMap.md)、[CAS](./CAS与原子类.md)、[Synchronized](./Synchronized.md)

---

## 一、HashMap 多线程问题

### 1.1 三大经典问题（高频题）

**问题 1：JDK 7 死循环**
JDK 7 HashMap 扩容时**头插法**会让链表反转。多线程同时扩容，链表节点可能形成**环**：

```
原链表：A → B → null
T1 扩容到一半挂起：next 指针处于 A → B 状态
T2 完成扩容：链表变成 B → A → null（头插倒序）
T1 继续：拿到 next=B 后头插 → 环 B → A → B → A ...
```
后续 get 命中这个 bucket → 死循环 → CPU 100%。

**问题 2：数据丢失**
两个线程同时 put 到同一个空 bucket，都判断"是空的"，都直接放——**后写覆盖前写**。

**问题 3：扩容期 put 丢数据**
线程 A 触发扩容，新建 newTable；线程 B 此时 put 到 oldTable，B 写完后扩容把 oldTable 替换成 newTable→ B 写的数据没了。

### 1.2 修复方案

JDK 8 改成尾插法解了"死循环"，但**多线程下数据丢失依然存在**。多线程场景必须用 **ConcurrentHashMap** 或 `Collections.synchronizedMap()`。

| 方案 | 性能 | 备注 |
| --- | --- | --- |
| `Hashtable` | 差（synchronized 整个方法）| 历史遗留，不要用 |
| `Collections.synchronizedMap` | 差（包了一层 synchronized） | 全表锁 |
| `ConcurrentHashMap` | **优**（细粒度锁 + CAS）| 生产唯一推荐 |

---

## 二、JDK 1.7：分段锁（Segment）

### 2.1 数据结构

```
       ConcurrentHashMap
              │
              ▼
       Segment[16]              ← 默认 16 段，每段独立 ReentrantLock
       ┌────────────┐
       │ Segment[0] │ ─► HashEntry[N] ─► HashEntry → HashEntry → ...
       │ Segment[1] │ ─► HashEntry[N] ─► HashEntry → ...
       │ ...        │
       │ Segment[15]│ ─► HashEntry[N] ─► HashEntry → ...
       └────────────┘
```

每个 `Segment extends ReentrantLock`，本质是 16 个独立的"小 HashMap"。

### 2.2 工作原理

**put**：
1. hash 算出 segment 下标 → 锁这一个 Segment
2. 在 Segment 内的 HashEntry[] 找位置 → 链表插入

**get**：
1. hash 算 segment 下标
2. **不加锁**（HashEntry 的 value 用 volatile，保证可见性）
3. 链表查找

**并发度**：默认 16，最多 16 个线程同时操作不同 Segment 不阻塞。可以构造时指定 `concurrencyLevel`。

### 2.3 缺点

- **粒度仍然偏大**：100 万元素分 16 段，每段 6 万——锁一段还是锁了几万元素
- 高竞争场景下，热点 segment 仍然成瓶颈
- **Segment 一旦初始化不能扩容**（数量固定）
- 对象嵌套深，内存占用偏大

---

## 三、JDK 1.8：完全重构

### 3.1 数据结构

```
        Node[]  (数组)
        ┌────┬────┬────┬────┬────┬────┐
        │ N0 │null│ N2 │ TR │null│ FN │
        └────┴────┴────┴────┴────┴────┘
              ▼              ▼     ▼
              链表       红黑树   ForwardingNode（扩容标记）
              N → N → N
```

- **数组 + 链表 + 红黑树**（链表长度 ≥ 8 且数组长度 ≥ 64 时转树）
- 锁的粒度从 Segment 降到**桶（数组单个槽）**：用 **synchronized 锁桶头节点**
- 空桶 put：CAS 直接写（不加锁）
- 非空桶 put：synchronized 锁头节点 + 链表 / 树插入

### 3.2 关键 hash 标记

```java
static final int MOVED     = -1;   // ForwardingNode hash，表示在扩容
static final int TREEBIN   = -2;   // 红黑树根的 hash
static final int RESERVED  = -3;   // computeIfAbsent 占位
```

普通 Node 的 hash 是 `key.hashCode() & 0x7fffffff`（最高位 0，正数）。

### 3.3 sizeCtl 这个魔法字段

```java
private transient volatile int sizeCtl;
```

**多用途变量**：
- `-1`：正在初始化数组
- `-(1 + nThreads)`：正在扩容，nThreads 个线程协助扩容
- 正数：扩容阈值（`n * 0.75`）

通过一个 int 编码多种状态，配合 CAS 转换。

---

## 四、JDK 1.8 核心流程

### 4.1 put 流程

```
putVal(key, val, onlyIfAbsent):
1. 算 hash = (key.hashCode ^ (hashCode >>> 16)) & 0x7fffffff
2. for 自旋：
    a. 表为空 → initTable() (CAS sizeCtl 防并发初始化)
    b. 桶为空 → CAS 直接 putNode → 成功返回
    c. 桶头是 ForwardingNode (扩容中) → helpTransfer()  (协助扩容！)
    d. 否则 synchronized (头节点) {
            // 重新检查头还是它（防止刚拿锁前被改）
            if (链表) 链表插入 / 更新；长度 ≥ 8 → treeifyBin
            if (红黑树) 树插入
       }
3. addCount(1)：累加计数器，触发扩容判断
```

**关键点**：
- 空桶 CAS 不加锁——大多数 put 是空桶，零竞争场景接近无锁
- 非空桶 synchronized 锁头节点——锁粒度降到 1 个桶（vs JDK 7 锁 1/16 表）

### 4.2 get 流程（无锁）

```
get(key):
1. 算 hash
2. 拿到桶头节点 (volatile 读)
3. 头是 null → 返回 null
4. 头 hash 直接命中且 key 匹配 → 返回 value
5. 头 hash < 0 (TREEBIN/MOVED) → 走 ForwardingNode.find / TreeBin.find
6. 否则遍历链表
```

**全程不加锁**——靠 Node.val 和 Node.next 的 volatile 修饰保证可见性。

### 4.3 扩容（最复杂）

JDK 8 ConcurrentHashMap 支持**多线程并发扩容**：

```
1. 触发扩容：addCount 检测到 size > sizeCtl
2. transfer():
   a. 创建 nextTable (2 倍)
   b. 把数组划分成多个"段"，每个线程认领一段：
         tab.length = 32, stride = 16
         T1 处理 [16, 31], T2 处理 [0, 15]
   c. 每个 bucket 处理完毕：
         空桶 → CAS 放 ForwardingNode (告诉别人"我已迁移")
         非空桶 → synchronized 锁头节点 → 拆分链表 / 树到 newTable[i] 和 newTable[i+oldLen]
   d. 处理完一段，自己再认领下一段，直到无段可领
3. 扩容期间其他线程的 put：
   - 桶头是 ForwardingNode → helpTransfer (帮忙搬！)
   - 桶非空 → 锁头节点正常 put（put 完照样会被搬走）
4. 扩容期间 get：
   - ForwardingNode.find 会 follow 到 nextTable 找
```

**精髓**：扩容不是"暂停整表"，而是**所有访问者都来帮忙搬**——多线程并发扩容，吞吐高。

### 4.4 size 实现

JDK 7：所有 Segment 加锁后求和（贵）
JDK 8：**LongAdder 思想**——`baseCount` + `CounterCell[]` 分散累加

```java
public int size() {
    long n = sumCount();
    return ((n < 0L) ? 0 : (n > Integer.MAX_VALUE) ? Integer.MAX_VALUE : (int) n);
}

final long sumCount() {
    long sum = baseCount;
    if (counterCells != null)
        for (CounterCell c : counterCells) if (c != null) sum += c.value;
    return sum;
}
```

`size()` 返回的是**估计值**——sum 期间有别的线程在写，结果可能"略偏"。强一致性的 size 在并发表里没法零开销实现。

---

## 五、为什么禁止 null

```java
ConcurrentHashMap<String, String> map = new ConcurrentHashMap<>();
map.put(null, "x");      // NPE
map.put("k", null);      // NPE
```

### 5.1 表面原因

`putVal` 里第一行就 `if (key == null || value == null) throw new NullPointerException();`

### 5.2 设计根因（多丽巴杰里 Doug Lea 解释）

**二义性问题**：
```java
v = map.get(key);
if (v == null) ...     // 不知道是 (a) key 不存在 还是 (b) value 是 null
```

单线程下可以 `containsKey` 二次校验，但**并发场景下两次操作之间值可能改变**——根本无法可靠区分。

为避免迷惑性，CHM 直接禁止 null。`HashMap` 单线程没此问题，所以允许 null。

> 这是 Doug Lea 在 jsr-166 邮件列表的原话：
> "The main reason that nulls aren't allowed in ConcurrentMaps is that ambiguities that may be just barely tolerable in non-concurrent maps can't be accommodated."

---

## 六、JDK 7 vs 8 全方位对比

| 维度 | JDK 1.7 | JDK 1.8 |
| --- | --- | --- |
| 数据结构 | Segment[16] + HashEntry[] | Node[] + 链表 + 红黑树 |
| 锁粒度 | 锁 Segment（约 1/16 表） | 锁桶头节点（1 个槽） |
| 锁实现 | ReentrantLock | synchronized + CAS |
| put 空桶 | 加锁 | **CAS 无锁** |
| put 非空桶 | 加锁 Segment | 加锁桶头节点 |
| get | 无锁（HashEntry.val volatile）| 无锁（Node.val volatile）|
| 扩容 | 单线程，每个 Segment 独立扩容 | **多线程协助并发扩容** |
| 计数 | 各 Segment count 求和（要锁全部） | LongAdder 思想（baseCount + CounterCell）|
| 长链表查找 | O(N) | O(log N)（红黑树）|
| 内存 | Segment 嵌套层级深 | 平铺结构紧凑 |

---

## 七、生产踩坑

### 7.1 用 size + put 实现"原子初始化"

```java
if (map.size() == 0) map.put(k, v);   // ❌ 多线程下 size 检查 + put 不原子
```
**修复**：用 `putIfAbsent` 或 `computeIfAbsent`。

### 7.2 computeIfAbsent 嵌套递归死锁（JDK 8 bug，9 修复）

```java
map.computeIfAbsent("a", k1 -> map.computeIfAbsent("b", k2 -> 42));
```
JDK 8 上一旦两个 key 落同一桶，会死锁。JDK 9 修复。**不要在 mapping function 里再操作同一个 map**。

### 7.3 forEach + put 抛 ConcurrentModificationException？

CHM 的迭代器是**弱一致性**——不抛异常，但能读到迭代开始后的部分修改。如果业务依赖"迭代时不变"，CHM 不能给这个保证。

### 7.4 把 ConcurrentHashMap 当全局缓存还忘了清理

CHM 没有过期机制，无脑塞会 OOM。
**修复**：用 Caffeine / Guava Cache（带过期 + LRU + 大小上限）。

### 7.5 容量预估错导致扩容连锁

构造时不传初始容量，默认 16，几十万 key 全靠扩容达到——多次 resize 影响吞吐。
**修复**：`new ConcurrentHashMap<>(预估容量 / 0.75)`。

### 7.6 hash 冲突攻击

恶意构造 hash 冲突的 key 列表，所有元素落同一桶 → 退化为链表 / 红黑树 → 单桶查找慢。HTTP 请求参数解析等场景被攻击。
**修复**：使用安全的 hash 函数（JDK 内部对 String 已经做过扰动），别用 hashCode 暴露给外界的对象当 key。

---

## 八、面试高频追问

**Q1：JDK 7 和 JDK 8 ConcurrentHashMap 区别？**
- 数据结构：Segment+HashEntry → Node+链表+红黑树
- 锁：ReentrantLock 锁 Segment → synchronized 锁桶头 + CAS
- 并发度：固定 16 → 等于桶数（百万级）
- 扩容：单线程 → 多线程协助
- 长链表：O(N) → O(log N)

**Q2：JDK 8 为什么用 synchronized 而不继续用 ReentrantLock？**
- 锁粒度小到桶级别，大多数桶无竞争 → synchronized 锁升级（偏向→轻量→重量）开销很低
- synchronized 由 JVM 优化，性能不输 ReentrantLock，且代码更简洁
- 减少 ReentrantLock 队列管理开销

**Q3：CHM 怎么保证 get 不加锁还安全？**
- Node.val 用 volatile，写入对所有线程可见
- Node.next 用 volatile，链表结构变化对 get 可见
- 扩容期遇到 ForwardingNode 跟随到 nextTable 查
- 容忍弱一致性（迭代期间数据可能变）

**Q4：CHM 的 size() 可靠吗？**
**估计值**。底层 baseCount + CounterCell 分段累加，sumCount 期间别的线程可能在写。强一致 size 在并发容器里代价太大（要锁全表）。

**Q5：为什么 CHM 不允许 null？**
为了消除 `get(k)` 返回 null 时的二义性（"key 不存在" vs "key 存在但 value 是 null"）。并发场景下无法用 containsKey 可靠区分。HashMap 单线程没此问题所以允许。

**Q6：链表转红黑树的两个条件？**
- 链表长度 ≥ **8**（TREEIFY_THRESHOLD）
- 数组长度 ≥ **64**（MIN_TREEIFY_CAPACITY）
- 否则即使链表长，也优先扩容（数组小时扩容比转树更划算）
- 红黑树节点数退到 ≤ 6 时退回链表（UNTREEIFY_THRESHOLD）

**Q7：CHM 怎么实现并发扩容？**
扩容线程把表拆成多段（默认每段 16 桶），每段一个线程认领。其他线程 put 时如果发现桶头是 ForwardingNode → helpTransfer 进来帮忙搬。所有访问者都参与扩容，吞吐高。

**Q8：CopyOnWriteArrayList 和 ConcurrentHashMap 思路有什么不同？**
- CHM：分段细粒度加锁 + CAS，**适合读写都频繁**
- COW List：读不加锁，写时全量拷贝新数组，**只适合读多写极少**（写一次拷贝整个数组）

---

## 九、答题模板（90 秒话术）

> ConcurrentHashMap 是线程安全的 HashMap。
>
> **JDK 1.7** 用 **Segment + ReentrantLock** 分段锁，默认 16 段，最多 16 线程并发。锁粒度仍偏大、Segment 嵌套层级深。
>
> **JDK 1.8 完全重构**：扔掉 Segment，用 **Node[] + 链表 + 红黑树** 平铺结构。空桶 **CAS 无锁** 直接写，非空桶 **synchronized 锁桶头节点**——锁粒度从 1/16 表降到 1 个桶。链表长度 ≥ 8 且数组长度 ≥ 64 时转红黑树（O(N) → O(logN)）。
>
> 关键创新：**多线程并发扩容**——把表拆段，所有访问者都来帮忙搬，桶搬完后放 ForwardingNode 标记。计数用 LongAdder 思想（baseCount + CounterCell 分散累加），size() 是估计值。
>
> get 全程**无锁**，靠 Node 字段的 volatile 保证可见性。
>
> 禁止 null：避免"key 不存在 vs value 是 null"在并发下无法区分的二义性。
>
> 经典坑：**JDK 8 的 computeIfAbsent 嵌套死锁**（已 fix）、**当全局缓存忘清理 OOM**（用 Caffeine）、**容量预估错连锁扩容**。

---

## 十、相关文档

- [HashMap](../Java/HashMap.md) — 单线程版，理解扩容机制
- [CAS 与原子类](./CAS与原子类.md) — JDK 8 CHM 大量用 CAS
- [Synchronized](./Synchronized.md) — JDK 8 CHM 锁桶头
- [阻塞队列](./阻塞队列.md) — 其他并发容器
- [一致性哈希](../Distributed/一致性哈希.md) — 分布式哈希思路
