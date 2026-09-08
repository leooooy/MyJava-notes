# List

> List 是面试 Collection 体系里**最常用的考点**。问得最深的几条线：
> ① ArrayList **扩容**怎么扩、扩多少、每次扩容多少代价
> ② ArrayList vs LinkedList 真的"插入快"吗？老套路新答案
> ③ Vector 和 ArrayList 区别——为什么 Vector 已淘汰
> ④ CopyOnWriteArrayList 原理、读写一致性、适用场景
>
> 单链表数据结构基础不展开，重点放在 **JDK 实现细节 + 生产经验**。

---

## 一、List 接口

```java
public interface List<E> extends Collection<E> {
    boolean add(E e);
    void add(int index, E e);
    E get(int index);
    E set(int index, E e);
    E remove(int index);
    int size();
    Iterator<E> iterator();
    ListIterator<E> listIterator();    // 支持双向遍历 + 增删
    List<E> subList(int from, int to); // 视图（不是 copy）
    ...
}
```

特征：**有序（按插入序）+ 可重复 + 可索引**。

主流实现：

| 实现类 | 数据结构 | 线程安全 | 适用场景 |
| --- | --- | --- | --- |
| `ArrayList` | 动态数组 | ❌ | **默认选择**，随机访问 |
| `LinkedList` | 双向链表 | ❌ | 频繁头尾增删（其实不如 ArrayDeque） |
| `Vector` | 动态数组 + synchronized | ✅（已弃） | 不要用了 |
| `CopyOnWriteArrayList` | 写时复制数组 | ✅ | 读远多于写 |

---

## 二、ArrayList

### 2.1 数据结构

```java
public class ArrayList<E> extends AbstractList<E> {
    transient Object[] elementData;   // 实际存储数组
    private int size;                 // 元素个数（不是数组长度！）
    
    private static final int DEFAULT_CAPACITY = 10;
    private static final Object[] EMPTY_ELEMENTDATA = {};
    private static final Object[] DEFAULTCAPACITY_EMPTY_ELEMENTDATA = {};
}
```

> **关键区分**：`size` 是元素个数、`elementData.length` 是底层数组容量。

### 2.2 三种构造器

```java
new ArrayList<>();                  // elementData = DEFAULTCAPACITY_EMPTY_ELEMENTDATA（长度 0）
                                    // 第一次 add 时才扩到 10
new ArrayList<>(int capacity);      // 直接 new Object[capacity]
new ArrayList<>(Collection c);      // 拷贝 c 内容
```

> **生产建议**：知道大概大小一定预估容量。`new ArrayList<>(10000)` 比默认快很多——免去 13 次扩容（10→15→22→33→...→10000）。

### 2.3 add(E) 流程

```java
public boolean add(E e) {
    ensureCapacityInternal(size + 1);   // 确保有空间
    elementData[size++] = e;
    return true;
}

private void grow(int minCapacity) {
    int oldCapacity = elementData.length;
    int newCapacity = oldCapacity + (oldCapacity >> 1);   // ⚠ 1.5x 扩容
    if (newCapacity - minCapacity < 0) newCapacity = minCapacity;
    elementData = Arrays.copyOf(elementData, newCapacity);
}
```

**扩容核心**：

- 默认 10
- 每次 1.5x（`oldCap + oldCap / 2`）
- 调 `Arrays.copyOf` —— 内部 `System.arraycopy`

### 2.4 add(int, E) 流程（中间插入）

```java
public void add(int index, E element) {
    rangeCheckForAdd(index);
    ensureCapacityInternal(size + 1);
    System.arraycopy(elementData, index, elementData, index + 1, size - index);
    elementData[index] = element;
    size++;
}
```

→ 中间插入要**整体后移**——是 ArrayList 头部 / 中间插入慢的根本原因。

### 2.5 remove(int) 流程

```java
public E remove(int index) {
    rangeCheck(index);
    E oldValue = elementData(index);
    int numMoved = size - index - 1;
    if (numMoved > 0)
        System.arraycopy(elementData, index + 1, elementData, index, numMoved);
    elementData[--size] = null;     // 防内存泄漏（清空尾部引用）
    return oldValue;
}
```

> **小坑**：`remove(int)` 和 `remove(Object)` 重载——`list.remove(2)` 是删 index 2，`list.remove(Integer.valueOf(2))` 是删值 2 的元素。

### 2.6 时间复杂度

| 操作 | 时间复杂度 | 说明 |
| --- | --- | --- |
| `get(i)` / `set(i, e)` | **O(1)** | 数组下标访问 |
| `add(e)` | 平均 **O(1)** | 摊还（amortized），扩容时 O(n) |
| `add(0, e)` / `add(i, e)` | **O(n)** | 后续元素整体后移 |
| `remove(i)` | **O(n)** | 后续元素整体前移 |
| `contains(o)` | **O(n)** | 顺序扫 |
| `indexOf(o)` | **O(n)** | 顺序扫 |

---

## 三、LinkedList

### 3.1 数据结构

```java
public class LinkedList<E> extends AbstractSequentialList<E>
        implements List<E>, Deque<E> {
    transient int size = 0;
    transient Node<E> first;
    transient Node<E> last;

    private static class Node<E> {
        E item;
        Node<E> next;
        Node<E> prev;
    }
}
```

→ **双向链表 + 头尾指针**。同时实现 `List` 和 `Deque`，可以当**栈、队列、双端队列**用。

### 3.2 内存占用

每个节点除了存 item，还要存 prev / next 两个引用（64 位 JVM + 压缩指针：4B + 4B）+ 对象头 12B + 对齐 = **24~32B 一个节点**，再加 item 自身。

→ **存同样数据，LinkedList 比 ArrayList 多占 2~3x 内存**。

### 3.3 时间复杂度

| 操作 | 时间复杂度 | 说明 |
| --- | --- | --- |
| `get(i)` | **O(n)** | 从最近的端开始遍历 |
| `add(e)` / `addLast(e)` | **O(1)** | 尾插 |
| `addFirst(e)` | **O(1)** | 头插 |
| `add(i, e)` | **O(n)** | 先 get 到 i 位置（O(n)），然后插入 O(1) |
| `remove(i)` | **O(n)** | 同上 |
| `removeFirst` / `removeLast` | **O(1)** | 头尾删 |

> **关键反直觉**：`add(i, e)` **不是 O(1)**——找到 i 位置就 O(n) 了。所以 LinkedList 的"中间插入快"的说法**是错的**。

---

## 四、ArrayList vs LinkedList 决策表

### 4.1 经典对比表

| 维度 | ArrayList | LinkedList |
| --- | --- | --- |
| 数据结构 | 动态数组 | 双向链表 |
| 随机访问 `get(i)` | **O(1)** | O(n) |
| 头部插入 `add(0,e)` | O(n) | **O(1)** |
| 尾部插入 `add(e)` | 平均 O(1) | O(1) |
| 中间插入 `add(i,e)` | O(n)（移动） | O(n)（查找） |
| 内存占用 | 紧凑（连续数组） | 大（2 个引用 / 元素） |
| CPU 缓存友好 | ✅（顺序内存） | ❌（指针跳跃） |
| 是否支持队列 | ❌ | ✅（实现 Deque） |
| 默认选择 | ✅ **永远先选这个** | 几乎不用 |

### 4.2 LinkedList 真的快吗

**理论**：LinkedList 头尾增删 O(1)，ArrayList 头插 O(n)。
**实际**：LinkedList 几乎**没场景比 ArrayList 快**。原因：

1. **CPU 缓存命中率**：ArrayList 顺序内存，预读 64 字节进 L1；LinkedList 指针跳跃，缓存基本失效
2. **现代 CPU memcpy 极快**：System.arraycopy 走 SIMD，10000 元素的 ArrayList 头插也就几微秒
3. **指针开销**：LinkedList 每节点多 16~24B，**全表内存大 3 倍** → 内存 IO 多、GC 压力大

**实测**：10 万次头插，ArrayList 比 LinkedList 慢，但 100 万次反而 ArrayList 更快——因为 LinkedList 的内存碎片让 CPU 缓存miss 严重。

> Java 之父之一 Joshua Bloch 公开说过："**I never use LinkedList**." 

### 4.3 啥时候用 LinkedList

- 实现**队列 / 栈 / 双端队列** —— 但 `ArrayDeque` 更优
- API 强制要 `Deque<E>`、不能用 ArrayDeque（罕见）

→ **现代 Java 几乎没有 LinkedList 是最优解的场景**。

---

## 五、面试常被问的细节

### 5.1 ArrayList 扩容是多少倍？

JDK 8 之后是 **1.5x**（`oldCap + oldCap >> 1`）。HashMap 是 2x，因为它要保持容量为 2 的幂；ArrayList 不需要这个特性，1.5x 是空间和时间的折衷。

### 5.2 LinkedList 真的快吗？

**前面已展开**——除非是教科书理论场景，实际生产里 ArrayList **几乎永远赢**。

### 5.3 多线程下 ArrayList 会怎样？

可能：

- **数据丢失**：两个线程同时 add，size++ 不是原子的
- **抛 ArrayIndexOutOfBoundsException**：扩容过程中数组被换，旧索引失效
- **抛 NPE**：迭代时另一个线程把元素置 null

修复：用 `CopyOnWriteArrayList` 或 `Collections.synchronizedList`，或自己加锁。

### 5.4 ArrayList 怎么遍历删除？

```java
// ❌ 抛 ConcurrentModificationException
for (Integer x : list) if (x % 2 == 0) list.remove(x);

// ✅ 方式 1：Iterator.remove
Iterator<Integer> it = list.iterator();
while (it.hasNext()) if (it.next() % 2 == 0) it.remove();

// ✅ 方式 2：removeIf（JDK 8+）
list.removeIf(x -> x % 2 == 0);

// ✅ 方式 3：倒序 for 循环
for (int i = list.size() - 1; i >= 0; i--) {
    if (list.get(i) % 2 == 0) list.remove(i);
}
```

倒序 for 不抛 CME 是因为它**不通过迭代器**——直接调 `remove(int)`，不检查 modCount。但**生产推荐 removeIf**。

---

## 六、CopyOnWriteArrayList

### 6.1 实现

```java
public class CopyOnWriteArrayList<E> implements List<E> {
    private transient volatile Object[] array;
    final transient ReentrantLock lock = new ReentrantLock();

    public boolean add(E e) {
        lock.lock();
        try {
            Object[] elements = array;
            int len = elements.length;
            Object[] newElements = Arrays.copyOf(elements, len + 1);   // ⚠ 复制整个数组
            newElements[len] = e;
            array = newElements;                                       // 替换引用
            return true;
        } finally { lock.unlock(); }
    }

    public E get(int index) {
        return (E) array[index];                                       // 无锁
    }
}
```

**核心思想（COW）**：
- 写：**复制整个数组**，在新数组里改，最后替换引用
- 读：**完全无锁**，直接读 `array`

### 6.2 一致性模型

```
读到的是某个时刻的快照（不一定最新）
写完之后，下次读才能看到新数据
```

→ **最终一致**，不是强一致。如果读写之间需要严格的"刚写完就要读到"，**COW 不适合**。

### 6.3 适用场景（必背）

| 场景 | COW | ArrayList |
| --- | --- | --- |
| **读多写少**（10:1 以上） | ✅ 完美 | 要加锁 |
| 读写均衡 | ❌ 写代价太大 | 加锁 OK |
| 写多 | ❌ 内存爆炸 | — |
| 强一致 | ❌ | — |

**典型场景**：

- 配置类（监听器、订阅者列表）——启动时加，运行时几乎只读
- 黑白名单
- 路由表

**不要用的场景**：

- 业务日志写入（写多）
- 频繁修改的购物车（写多）

### 6.4 缺点

- **内存翻倍**：写时复制整个数组，瞬间占用 2x 内存
- **GC 压力**：旧数组被 GC，频繁写时频繁 GC
- **数据延迟**：读看到的是快照，可能不是最新
- **迭代器持快照**：迭代过程不抛 CME，但看不到新数据

---

## 七、Vector —— 已淘汰

```java
public class Vector<E> extends AbstractList<E> {
    public synchronized boolean add(E e) { ... }      // 每个方法 synchronized
    public synchronized E get(int index) { ... }
    public synchronized int size() { return elementCount; }
    
    protected int capacityIncrement;       // ⚠ 扩容增量（不是倍数）
}
```

**和 ArrayList 区别**：

| 维度 | ArrayList | Vector |
| --- | --- | --- |
| 线程安全 | ❌ | ✅（每方法 synchronized） |
| 扩容倍数 | 1.5x | 2x（如果 capacityIncrement 为 0） |
| 性能 | 高 | 单线程也付锁开销 |

**为什么不用**：

- 多线程：`ConcurrentHashMap` 或 `CopyOnWriteArrayList` 性能更好
- 单线程：白白付锁开销
- API 老旧：`firstElement` / `addElement` 这种命名

→ **看到 Vector 就改 ArrayList**。

---

## 八、生产踩坑

### 8.1 多线程修改 ArrayList

**现象**：偶发 `IndexOutOfBoundsException`，数据偶尔丢失。
**根因**：多线程并发 add，size++ 和数组扩容不是原子的。
**修复**：

- 读多写少 → `CopyOnWriteArrayList`
- 读写均衡 → `Collections.synchronizedList(...)` 并外部加锁迭代
- 业务允许有锁 → 自己 `synchronized` 控制

### 8.2 subList 不是普通 List

```java
List<Integer> list = new ArrayList<>(Arrays.asList(1,2,3,4,5));
List<Integer> sub = list.subList(1, 4);    // [2,3,4]
list.add(0);                               // ⚠ 修改原 list
sub.size();                                // 抛 ConcurrentModificationException
```

`subList` 返回的是**原 list 的视图（view）**，不是 copy。原 list 修改会破坏 sub 的 modCount，反之亦然。**生产规范**：要切片就 `new ArrayList<>(list.subList(...))` 真正复制一份。

### 8.3 Arrays.asList 坑

```java
List<Integer> list = Arrays.asList(1, 2, 3);
list.add(4);                               // ⚠ UnsupportedOperationException
```

`Arrays.asList` 返回的是 `Arrays$ArrayList`（**不是 java.util.ArrayList**），是个**固定大小的视图**——可以 set，但不能 add / remove。

**正确做法**：

```java
List<Integer> list = new ArrayList<>(Arrays.asList(1, 2, 3));
List<Integer> list = Stream.of(1, 2, 3).collect(Collectors.toCollection(ArrayList::new));
List<Integer> list = List.of(1, 2, 3);                            // JDK 9+ 但不可变
```

### 8.4 List.of() 不可变

```java
List<Integer> list = List.of(1, 2, 3);
list.add(4);                               // ⚠ UnsupportedOperationException
```

JDK 9 加的 `List.of`、`Set.of`、`Map.of` 都返回**不可变集合**。要修改就 `new ArrayList<>(List.of(1,2,3))`。

### 8.5 大量 add 不预估容量

```java
List<User> list = new ArrayList<>();          // 默认 10
for (User u : userBatch) list.add(u);         // userBatch 100 万条
// → 经历多次扩容：10 → 15 → 22 → ... → 100 万，约 30 次 arraycopy
```

**修复**：

```java
List<User> list = new ArrayList<>(userBatch.size());
list.addAll(userBatch);    // 内部一次扩容到位
```

---

## 九、答题模板（60 秒话术）

> List 三大实现：**ArrayList**（动态数组、随机访问 O(1)、默认选）、**LinkedList**（双向链表、头尾 O(1)）、**Vector**（已弃）。
>
> ArrayList 默认容量 10，扩容 **1.5x**（位运算 `oldCap + oldCap >> 1`）。`add(0, e)` 是 O(n)，`get(i)` 是 O(1)；中间插入要 `System.arraycopy` 整体后移。
>
> LinkedList 是双向链表，头尾 O(1)，但 `get(i)` 是 O(n)——**真没场景比 ArrayList 快**：CPU 缓存友好性差、内存大 3 倍、System.arraycopy 极快。Joshua Bloch 都说"I never use LinkedList"。
>
> 多线程：用 **CopyOnWriteArrayList**——读完全无锁、写复制整个数组替换引用。**只适合读远多于写**——不然内存爆炸。典型场景：配置 / 监听器 / 黑白名单。
>
> 生产几个坑：**`subList` 是视图不是 copy**、**`Arrays.asList` 不能 add**、**`List.of` 不可变**、**多线程改 ArrayList 偶发 OOB**。

---

## 十、相关文档

- [集合框架总览](./集合类.md) — fail-fast / 线程安全集合分类
- [HashMap](./HashMap.md) — 集合体系另一支柱
- [Queue](./Queue.md) — ArrayDeque 替代 LinkedList 做队列 / 栈
- [Concurrency / 阻塞队列](../Concurrency/阻塞队列.md) — BlockingQueue 系列
