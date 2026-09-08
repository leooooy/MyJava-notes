# HashMap

> HashMap 是 Java 面试**最高频的题没有之一**。一道"讲讲 HashMap"能问 30 分钟，覆盖：
> ① 数据结构（数组 + 链表 + 红黑树，JDK 7 vs 8 演进）
> ② **扰动函数**为什么右移 16 异或
> ③ **链表转红黑树**为什么是 8、为什么退化是 6
> ④ **扩容**怎么做、为什么容量必须是 2 的幂
> ⑤ **JDK 7 头插死循环** —— 经典面试题
> ⑥ **HashMap、TreeMap、LinkedHashMap、ConcurrentHashMap** 四兄弟比较
>
> 答这一题前自己先把源码读 3 遍。本篇按面试官追问顺序展开。

---

## 一、HashMap 是什么

HashMap = **散列表（Hash Table）**——通过 hash 函数把 key 映射到数组下标，O(1) 查找。

**特征**：

| 维度 | 取值 |
| --- | --- |
| key 重复 | ❌（put 同 key 覆盖）|
| value 重复 | ✅ |
| 允许 null | ✅ key 1 个 null（数组 0 位）+ value 任意 null |
| 顺序 | 无序（不保证插入序，扩容后顺序也会变）|
| 线程安全 | ❌ |

---

## 二、JDK 7 vs JDK 8 数据结构演进

### 2.1 JDK 7：数组 + 链表

```
table[0] → Entry → Entry → Entry → null   ← 链表
table[1] → null
table[2] → Entry → null
table[3] → Entry → Entry → null
```

冲突解决：**链表**。冲突多时（链表长）查找退化到 **O(n)**。

**头插法**：新节点插链表头。这是 JDK 7 多线程死循环的根源（详见 [10.1](#101-jdk-7-头插死循环)）。

### 2.2 JDK 8：数组 + 链表 + 红黑树

```
table[0] → Node → Node → null
table[5] → Node → Node → ... → Node → ... (8 个就转红黑树)
              ↓
         TreeNode（红黑树）
```

**核心改进**：

- 冲突链表长度 ≥ 8 且数组长度 ≥ 64 → 转红黑树（查找 O(log n)）
- 红黑树节点数 ≤ 6 → 退化为链表
- 改 **尾插法**，解决 JDK 7 死循环

### 2.3 关键常量

```java
static final int DEFAULT_INITIAL_CAPACITY = 1 << 4;   // 16
static final int MAXIMUM_CAPACITY = 1 << 30;          // 2^30
static final float DEFAULT_LOAD_FACTOR = 0.75f;       // 负载因子
static final int TREEIFY_THRESHOLD = 8;               // 链表 → 红黑树
static final int UNTREEIFY_THRESHOLD = 6;             // 红黑树 → 链表
static final int MIN_TREEIFY_CAPACITY = 64;           // 数组小于这个就先扩容
```

---

## 三、扰动函数 —— 为什么右移 16

### 3.1 hash 函数

```java
static final int hash(Object key) {
    int h;
    return (key == null) ? 0 : (h = key.hashCode()) ^ (h >>> 16);
}
```

```
key.hashCode()   = 1010 1011 1100 1101 0011 0100 0101 0110  （32 位）
h >>> 16         = 0000 0000 0000 0000 1010 1011 1100 1101  （高 16 位移到低 16）
异或             = 1010 1011 1100 1101 1001 1111 1001 1011
```

### 3.2 为什么这么做

数组下标计算：

```java
int i = (n - 1) & hash;     // n 是数组长度（2 的幂）
```

`(n-1) & hash` 等价于 `hash % n`（n 是 2 的幂时）。但只用了 hash 的**低 log₂(n) 位**——n=16 时只用低 4 位。

**问题**：如果两个 key 的 hashCode 高位不同、低位相同 → 数组下标相同 → 哈希冲突。

**扰动**：用 `h >>> 16` 把高 16 位异或到低 16 位，让**高位也参与下标计算**——大幅减少冲突。

### 3.3 实测效果

引用 JDK 注释里的数据（Doug Lea 写的）：

> XOR shifts ... give a more uniform distribution at modest cost ... reducing collisions by **20-30%**.

→ 一行扰动代码减少 20-30% 冲突，性价比极高。

---

## 四、put 流程（JDK 8）

```java
public V put(K key, V value) {
    return putVal(hash(key), key, value, false, true);
}

final V putVal(int hash, K key, V value, boolean onlyIfAbsent, boolean evict) {
    Node<K,V>[] tab; Node<K,V> p; int n, i;
    
    // 1. table 为空 → 第一次扩容（resize 内部新建数组）
    if ((tab = table) == null || (n = tab.length) == 0)
        n = (tab = resize()).length;
    
    // 2. 算下标 i = (n-1) & hash，桶为空 → 直接放
    if ((p = tab[i = (n - 1) & hash]) == null)
        tab[i] = newNode(hash, key, value, null);
    
    else {
        Node<K,V> e; K k;
        
        // 3. 桶头 key 相等 → 准备覆盖
        if (p.hash == hash && ((k = p.key) == key || (key != null && key.equals(k))))
            e = p;
        
        // 4. 桶头是红黑树节点 → 走红黑树插入
        else if (p instanceof TreeNode)
            e = ((TreeNode<K,V>)p).putTreeVal(this, tab, hash, key, value);
        
        // 5. 链表 → 尾插
        else {
            for (int binCount = 0; ; ++binCount) {
                if ((e = p.next) == null) {
                    p.next = newNode(hash, key, value, null);
                    // 链表 ≥ 8 → 树化（前提：数组 ≥ 64，否则只是扩容）
                    if (binCount >= TREEIFY_THRESHOLD - 1)
                        treeifyBin(tab, hash);
                    break;
                }
                if (e.hash == hash && ((k = e.key) == key || (key != null && key.equals(k))))
                    break;
                p = e;
            }
        }
        
        // 6. 已存在 key → 覆盖 value 返回旧值
        if (e != null) {
            V oldValue = e.value;
            if (!onlyIfAbsent || oldValue == null) e.value = value;
            return oldValue;
        }
    }
    
    ++modCount;
    // 7. 元素数超阈值 → 扩容
    if (++size > threshold) resize();
    return null;
}
```

**记忆口诀（5 步）**：

1. 表空就扩容
2. 算下标，桶空直接放
3. 桶头 key 相等 → 覆盖
4. 桶是树 → 树插
5. 桶是链表 → 尾插，长 8 转树

---

## 五、链表与红黑树的转换

### 5.1 链表 → 红黑树（树化 treeifyBin）

```java
final void treeifyBin(Node<K,V>[] tab, int hash) {
    int n;
    if (tab == null || (n = tab.length) < MIN_TREEIFY_CAPACITY)
        resize();              // ⚠ 数组 < 64 优先扩容，不树化
    else if ((e = tab[index = (n - 1) & hash]) != null) {
        // ...转红黑树
    }
}
```

**两个条件同时满足**才树化：

1. 链表长度 ≥ **8**
2. 数组长度 ≥ **64**

只满足 1 不满足 2：先扩容。**为什么**：数组小的时候冲突多，扩容打散数据更划算。

### 5.2 为什么链表 8 → 红黑树，6 → 退化

JDK 8 源码注释（**必背**）：

> Because TreeNodes are about twice the size of regular nodes, we use them only when bins contain enough nodes to warrant use. ... Ideally, under random hashCodes, the frequency of nodes in bins follows a **Poisson distribution** ... with parameter of about 0.5 on average for the default resizing threshold of 0.75. ...
>
> 0:    0.60653066
> 1:    0.30326533
> 2:    0.07581633
> 3:    0.01263606
> 4:    0.00157952
> 5:    0.00015795
> 6:    0.00001316
> 7:    0.00000094
> 8:    0.00000006
> more: less than 1 in ten million

→ 在均匀哈希下，一个桶达到 8 个节点的概率**小于千万分之一**。如果真到了 8，**几乎必然 hashCode 实现有问题**——这时候转红黑树是"自我保护"。

**退化为 6 而不是 7 或 8**：留 1 个缓冲带，避免 8/7 之间反复横跳。

### 5.3 红黑树 vs 链表性能

| 长度 | 链表查找 | 红黑树查找 |
| --- | --- | --- |
| 8 | O(8) = 8 | O(log 8) = 3 |
| 64 | O(64) = 64 | O(log 64) = 6 |
| 1000 | O(1000) | O(log 1000) ≈ 10 |

但红黑树**节点比 Node 大 2x**（多了 parent / red / left / right），存储开销大。所以只在长链表退化时用。

---

## 六、扩容机制

### 6.1 扩容时机

```
size > threshold 时扩容
threshold = capacity * loadFactor
默认：16 * 0.75 = 12 → 第 13 个 put 触发扩容到 32
```

### 6.2 为什么容量必须 2 的幂

下标计算 `(n-1) & hash`，**只有 n 是 2 的幂时 `(n-1) & hash == hash % n`**。

```
n = 16 → n-1 = 15 = 1111  → & hash 等价于取 hash 的低 4 位
n = 17 → n-1 = 16 = 10000 → & 后只有第 5 位有效，几乎所有 hash 落到 0/16
```

**好处**：

- 位运算比模运算快 5-10 倍
- 扩容时元素**要么留在原位、要么去 [原位+oldCap]**——位运算判断

### 6.3 扩容关键代码（JDK 8）

```java
final Node<K,V>[] resize() {
    int newCap = oldCap << 1;        // 容量翻倍
    Node<K,V>[] newTab = new Node[newCap];
    
    for (int j = 0; j < oldCap; ++j) {
        Node<K,V> e = oldTab[j];
        if (e == null) continue;
        
        if (e.next == null) {
            newTab[e.hash & (newCap - 1)] = e;     // 单节点直接重新算下标
        }
        else if (e instanceof TreeNode) {
            ((TreeNode<K,V>)e).split(this, newTab, j, oldCap);
        }
        else {
            // 链表：拆成 lo / hi 两条
            Node<K,V> loHead = null, loTail = null;
            Node<K,V> hiHead = null, hiTail = null;
            do {
                Node<K,V> next = e.next;
                if ((e.hash & oldCap) == 0) {       // ⚠ 关键：判断扩容后位置
                    // 在原位
                    if (loTail == null) loHead = e; else loTail.next = e;
                    loTail = e;
                } else {
                    // 在原位 + oldCap
                    if (hiTail == null) hiHead = e; else hiTail.next = e;
                    hiTail = e;
                }
            } while ((e = next) != null);
            
            if (loTail != null) { loTail.next = null; newTab[j] = loHead; }
            if (hiTail != null) { hiTail.next = null; newTab[j + oldCap] = hiHead; }
        }
    }
    return newTab;
}
```

### 6.4 扩容下标计算（核心）

```
oldCap = 16  = 0001 0000
newCap = 32  = 0010 0000

判断：e.hash & oldCap == 0？

e.hash bit 4 为 0 → e.hash & oldCap == 0 → 留原位
e.hash bit 4 为 1 → e.hash & oldCap != 0 → 去 j + oldCap
```

**只看一位**就决定去向，不需要重新算 hash。这就是 2 的幂容量的性能红利。

### 6.5 为什么负载因子 0.75

**Poisson 分布优化**：负载因子 0.75 时，链表长度的 Poisson 分布参数 λ ≈ 0.5——8 个节点的概率最小（千万分之六）。

**空间 vs 时间**：

- 0.5 → 浪费空间
- 1.0 → 冲突剧增
- 0.75 是公认的最优折衷

**生产规范**：**不要改 loadFactor**，没有比 0.75 更好的选择。

---

## 七、HashMap 与 hash 冲突攻击

### 7.1 哈希碰撞 DoS

恶意构造大量同 hashCode 的 key，把 HashMap 退化成单链表 O(n)。Java 7 没有红黑树，10 万个同 hash key → put 慢到接近不可用。

### 7.2 JDK 8 的防御

链表长度 ≥ 8 转红黑树 → 最坏 O(log n)，缓解 DoS。

但根本上：**接受用户输入做 HashMap key 时一定要做 hash 验证**（如限制 key 长度、做 HMAC）。

---

## 八、TreeMap & LinkedHashMap

### 8.1 TreeMap

```java
public class TreeMap<K,V> implements NavigableMap<K,V> {
    private final Comparator<? super K> comparator;
    private transient Entry<K,V> root;
}

class Entry<K,V> {
    K key; V value;
    Entry<K,V> left, right, parent;
    boolean color;       // 红黑树
}
```

特征：

- 数据结构：**红黑树**
- 排序：按 key 的 `compareTo` 或 Comparator
- get / put：**O(log n)**
- 不允许 null key（compareTo 会 NPE）

**额外能力**：`firstKey() / lastKey() / floorKey() / ceilingKey() / subMap()`——TreeMap 实现 `NavigableMap` 接口。

### 8.2 LinkedHashMap

```java
public class LinkedHashMap<K,V> extends HashMap<K,V> {
    transient LinkedHashMap.Entry<K,V> head;
    transient LinkedHashMap.Entry<K,V> tail;
    final boolean accessOrder;       // false: 插入序; true: 访问序
}

static class Entry<K,V> extends HashMap.Node<K,V> {
    Entry<K,V> before, after;        // ⚠ 多了双向链表指针
}
```

特征：

- 继承 HashMap，**额外维护一条双向链表**
- 默认按**插入顺序**遍历（`accessOrder = false`）
- 设 `accessOrder = true` 后，每次 get 把节点移到链表尾——**LRU 实现基础**

**LRU 缓存**：

```java
LinkedHashMap<K, V> lru = new LinkedHashMap<>(16, 0.75f, true) {  // accessOrder = true
    @Override
    protected boolean removeEldestEntry(Map.Entry<K,V> eldest) {
        return size() > 100;        // 超过 100 个删最老的
    }
};
```

→ 简洁的本地 LRU 缓存。

### 8.3 三兄弟对比

| 维度 | HashMap | LinkedHashMap | TreeMap |
| --- | --- | --- | --- |
| 数据结构 | 数组+链表+树 | 数组+链表+树 + **双向链表** | **红黑树** |
| 顺序 | 无序 | 插入序 / 访问序 | key 排序 |
| get / put | O(1) | O(1) | **O(log n)** |
| null key | ✅ 1 个 | ✅ 1 个 | ❌ |
| 内存 | 中 | 中（多 2 引用 / 节点） | 中 |
| 用途 | 默认字典 | LRU、保插入序 | 范围查询、排序 |

---

## 九、ConcurrentHashMap（简）

详细见 [Concurrency / ConcurrentHashMap](../Concurrency/ConcurrentHashMap.md)。

**对比 HashMap**：

| 维度 | HashMap | ConcurrentHashMap |
| --- | --- | --- |
| 线程安全 | ❌ | ✅ |
| 实现思路（JDK 7） | — | **分段锁（Segment）** |
| 实现思路（JDK 8） | — | **CAS + synchronized 桶头** |
| null key/value | ✅ | ❌（ambiguous，禁止） |
| 性能 | 单线程最快 | 多线程下接近 HashMap |

为什么 ConcurrentHashMap 不允许 null：`get(key) == null` 在并发下二义——是 key 不存在还是 value 是 null？无法区分。HashMap 单线程下可用 `containsKey` 区分，并发下做不到原子。

---

## 十、生产踩坑

### 10.1 JDK 7 头插死循环

**经典面试题**。JDK 7 多线程并发扩容，链表用头插法，可能导致**链表成环**。

```
扩容前：A → B → null

线程 1 准备移 A：next 记为 B
线程 2 完成移动：链表变成 B → A → null

线程 1 继续：把 A 头插，结果 A → B；接着移 B（因为 next 还指 B）：B 头插到 A 前 → B → A
然后处理 next（就是 A）：A 头插 → A → B → A → ...  ⚠ 环

读：get 时 while(e != null) 永远转，CPU 100%
```

JDK 8 改尾插法 + 扩容时按位分流，**这个问题没了**——但 HashMap 仍**不是线程安全**，多线程下数据丢失、覆盖等其他问题仍在。**多线程要用 ConcurrentHashMap**。

### 10.2 hashCode / equals 不一致

```java
class User { String id; @Override int hashCode() { return id.hashCode(); } 
             // ⚠ 没重写 equals
}

map.put(new User("A"), 1);
map.get(new User("A"));    // null —— equals 比地址，不相等
```

参见 [Object 类 - equals/hashCode 契约](./Object类.md#六equals--hashcode-契约必背)。

### 10.3 用可变对象做 key

```java
Map<List<Integer>, String> map = new HashMap<>();
List<Integer> key = new ArrayList<>(Arrays.asList(1,2));
map.put(key, "value");
key.add(3);                  // ⚠ key 变了
map.get(key);                // null —— hashCode 变了
```

**HashMap 的 key 必须不可变**——String、Integer、Long 这种 immutable 类是最优选择。

### 10.4 容量没预估

```java
Map<K,V> map = new HashMap<>();          // 默认 16
for (int i = 0; i < 100000; i++) map.put(...);
// 经历多次扩容（16 → 32 → 64 → ... → 131072），约 13 次 rehash
```

**修复**：知道大小就预估：

```java
Map<K,V> map = new HashMap<>(expectedSize / 0.75 + 1);
// 或用 Guava
Map<K,V> map = Maps.newHashMapWithExpectedSize(100000);
```

### 10.5 putIfAbsent 与 computeIfAbsent

```java
// ❌ get + put 不是原子（并发会有 race）
if (!map.containsKey(k)) map.put(k, compute(k));

// ✅ JDK 8 原子方法
map.putIfAbsent(k, value);
map.computeIfAbsent(k, key -> compute(key));    // 函数式，懒计算
map.compute(k, (key, oldVal) -> ...);
map.merge(k, 1, Integer::sum);                  // 计数
```

但 HashMap 这些方法**仍然不是线程安全**——只是单线程下原子。多线程要用 ConcurrentHashMap。

---

## 十一、面试高频追问

### Q1：HashMap 数据结构？JDK 7 vs 8 区别？

JDK 7：数组 + 链表，头插法。JDK 8：数组 + 链表 + 红黑树，链表 ≥8 且数组 ≥64 转红黑树（O(log n)），尾插法。

### Q2：扰动函数为什么右移 16 异或？

数组下标 = `(n-1) & hash`，n 小时只用 hash 的低位。`hash ^ (hash >>> 16)` 把高 16 位混入低 16 位，**减少 20~30% 哈希冲突**。

### Q3：链表为什么 8 转红黑树，6 退化？

Poisson 分布下达到 8 的概率小于千万分之一——到 8 大概率 hashCode 实现有问题，转树自我保护。退化阈值 6 留 1 节点缓冲，避免 8/7 之间反复转换。

### Q4：HashMap 为什么容量必须 2 的幂？

`(n-1) & hash` 等价 `hash % n`（n 为 2 的幂时），位运算比模运算快 5-10 倍。扩容时通过 `hash & oldCap` 一位判断元素去向（原位 / 原位+oldCap），不需重新算 hash。

### Q5：负载因子为什么 0.75？

空间和时间的平衡——0.5 太浪费、1.0 冲突剧增。Poisson 分布证明 0.75 时 8 节点概率最低。**生产不要改**。

### Q6：HashMap 怎么扩容？

容量翻倍，遍历每个桶；单节点重新算下标；链表按 `hash & oldCap` 分成两条（loHead / hiHead），分别放原位和 [原位+oldCap]；红黑树同理且节点 ≤6 退化为链表。

### Q7：JDK 7 HashMap 为什么会死循环？

JDK 7 头插法 + 多线程并发扩容 → 链表成环 → get 时 CPU 100%。JDK 8 改尾插 + 按位分流，这个 bug 没了，但**仍不是线程安全**，要用 ConcurrentHashMap。

### Q8：HashMap 允许 null key 吗？

允许 1 个 null key（强制放在 table[0]），无数 null value。TreeMap 不允许（compareTo 会 NPE），ConcurrentHashMap 不允许（并发下 get 返回 null 二义）。

### Q9：HashMap、TreeMap、LinkedHashMap 区别？

HashMap：无序、O(1)、最常用。
TreeMap：按 key 排序、O(log n)、红黑树、范围查询。
LinkedHashMap：保插入序 / 访问序、O(1)、可实现 LRU。

### Q10：HashMap 为什么不用 AVL 树而用红黑树？

AVL 严格平衡，**插入 / 删除时旋转更多**——红黑树是"近似平衡"，写入性能更好；查询性能差距不大（都是 log n）。生产场景写入比 AVL 完美平衡更重要。

### Q11：ConcurrentHashMap 和 HashMap 区别？

线程安全 / 不安全；不允许 null key/value；JDK 7 用分段锁、JDK 8 用 CAS + synchronized 桶头；并发下接近 HashMap 性能。详见 [Concurrency / ConcurrentHashMap](../Concurrency/ConcurrentHashMap.md)。

### Q12：HashMap 的 key 一般用什么？

不可变类——String、Integer、Long、UUID 这种 immutable。可变对象做 key，改了字段后 hashCode 变了，原来的 entry **永远找不到**（内存泄漏）。

---

## 十一、答题模板（90 秒话术）

> HashMap 是基于散列表的字典，JDK 8 起底层是 **数组 + 链表 + 红黑树**——冲突时挂链表，链表长度 ≥ 8 且数组长度 ≥ 64 转红黑树（查找 O(log n)），节点数 ≤ 6 退化回链表。
>
> hash 函数有**扰动**——`(h = key.hashCode()) ^ (h >>> 16)`，把高 16 位混入低 16 位，让 `(n-1) & hash` 取下标时高位也参与，**减少 20~30% 冲突**。
>
> 容量必须是 **2 的幂**（默认 16）：`(n-1) & hash` 等价于 `hash % n`，位运算比模运算快；扩容时通过 `hash & oldCap` 一位判断元素是留原位还是去 [原位+oldCap]。负载因子 **0.75** 是 Poisson 分布的最优解，**别改**。
>
> 树化阈值 8 来自 Poisson 分布——均匀哈希下达到 8 概率小于千万分之一，**到 8 几乎必然 hashCode 有问题**，转红黑树是自我保护。退化阈值 6 留缓冲。
>
> JDK 7 头插法 + 多线程扩容 → 死循环，JDK 8 改 **尾插 + 按位分流** 解决，但 HashMap **仍不是线程安全**——多线程用 **ConcurrentHashMap**（JDK 7 分段锁 → JDK 8 CAS + synchronized 桶头）。
>
> HashMap 允许 1 个 null key，TreeMap 不允许（NPE），ConcurrentHashMap 不允许（并发二义）。三兄弟分工：**HashMap 默认、TreeMap 排序、LinkedHashMap 保序 / LRU**。

---

## 十二、相关文档

- [Object 类](./Object类.md) — equals/hashCode 契约决定 HashMap 是否能用
- [String 原理](./String原理.md) — 最佳 HashMap key 类型
- [集合框架总览](./集合类.md) — 集合体系
- [Concurrency / ConcurrentHashMap](../Concurrency/ConcurrentHashMap.md) — 线程安全的 Map
- [JVM / 对象在内存中的布局](../JVM/对象在内存中的布局.md) — Node 对象的内存占用
