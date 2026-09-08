# Set

> Set 不是面试主战场，但**几乎一定会被点到**。考点集中在：
> ① HashSet 的底层是**什么**——其实就是 HashMap
> ② TreeSet 怎么排序、和 TreeMap 关系
> ③ LinkedHashSet 为什么能"保插入序"
> ④ 怎么实现一个线程安全的 Set
> ⑤ HashSet 怎么"判重"——回到 hashCode + equals 契约

---

## 一、Set 接口

```java
public interface Set<E> extends Collection<E> {
    boolean add(E e);          // 已存在返回 false
    boolean contains(Object o);
    boolean remove(Object o);
    int size();
    Iterator<E> iterator();
}
```

特征：**不重复、无索引**，是否有序看实现。

主流实现：

| 实现类 | 数据结构 | 顺序 | 线程安全 |
| --- | --- | --- | --- |
| `HashSet` | HashMap 包一层 | 无序 | ❌ |
| `LinkedHashSet` | LinkedHashMap 包一层 | 插入序 | ❌ |
| `TreeSet` | TreeMap 包一层（红黑树） | 排序序 | ❌ |
| `CopyOnWriteArraySet` | CopyOnWriteArrayList 包一层 | 插入序 | ✅ |
| `ConcurrentSkipListSet` | ConcurrentSkipListMap 包一层（跳表） | 排序序 | ✅ |

→ **几乎所有 Set 都是 Map 包一层**——共用 Map 的实现，把 value 设成同一个 dummy 对象。

---

## 二、HashSet

### 2.1 内部就是 HashMap

```java
public class HashSet<E> implements Set<E> {
    private transient HashMap<E, Object> map;
    private static final Object PRESENT = new Object();   // dummy value

    public HashSet() { map = new HashMap<>(); }

    public boolean add(E e) {
        return map.put(e, PRESENT) == null;     // null 表示之前没有 → 新增成功
    }

    public boolean contains(Object o) {
        return map.containsKey(o);
    }

    public boolean remove(Object o) {
        return map.remove(o) == PRESENT;
    }
}
```

→ HashSet 就是把元素当 HashMap 的 key、value 全部填同一个 dummy 对象。**所有 HashMap 的特性都继承**。

### 2.2 怎么判重

`HashSet.add(e)` 流程：

1. 算 `e.hashCode()`，找数组下标
2. 桶里已有节点：`equals(e)` 比较——相等 → 返回 false（已有）；不等 → 加链表 / 树
3. 桶为空：直接放

→ **判重靠的是 hashCode + equals 契约**。

### 2.3 自定义类要重写 hashCode + equals

```java
class User {
    String id, name;
    // ⚠ 没重写 hashCode 和 equals
}

Set<User> set = new HashSet<>();
set.add(new User("1", "Alice"));
set.add(new User("1", "Alice"));     // 还是 add 进去了
set.size();                           // 2 ⚠
```

→ Object 默认 hashCode 基于地址 → 两个 new 出来的 User 对象 hashCode 不同 → 桶不同 → "不重复"。

**修复**：

```java
@Override public boolean equals(Object o) { ... 比 id ... }
@Override public int hashCode() { return Objects.hash(id); }
```

参见 [Object 类 - equals/hashCode 契约](./Object类.md#六equals--hashcode-契约必背)。

### 2.4 时间复杂度

| 操作 | 时间复杂度 |
| --- | --- |
| `add` / `contains` / `remove` | 平均 O(1)，最坏 O(log n)（红黑树） |
| `iterator` | O(capacity)（要扫所有桶） |

→ 注意：**遍历是 O(n + capacity)**，capacity 大但 size 小时遍历慢。

---

## 三、TreeSet

### 3.1 内部就是 TreeMap

```java
public class TreeSet<E> implements NavigableSet<E> {
    private transient NavigableMap<E, Object> m;
    private static final Object PRESENT = new Object();

    public TreeSet() { this(new TreeMap<>()); }

    public boolean add(E e) {
        return m.put(e, PRESENT) == null;
    }
}
```

特征：

- **红黑树**，元素自动排序
- 元素必须 `Comparable` 或在构造时传 `Comparator`
- **不允许 null**（compareTo NPE）

### 3.2 排序方式

```java
// 方式 1：元素实现 Comparable
TreeSet<Integer> s1 = new TreeSet<>();
s1.add(3); s1.add(1); s1.add(2);
// 遍历：1, 2, 3（自然序）

// 方式 2：构造时传 Comparator
TreeSet<User> s2 = new TreeSet<>(Comparator.comparing(User::getAge).reversed());
// 按 age 降序
```

### 3.3 NavigableSet 额外方法

```java
TreeSet<Integer> s = new TreeSet<>(Arrays.asList(1, 5, 10, 20));

s.first();              // 1
s.last();               // 20
s.lower(10);            // 5  （严格小于 10）
s.floor(10);            // 10 （小于等于 10）
s.higher(10);           // 20 （严格大于 10）
s.ceiling(10);          // 10 （大于等于 10）
s.subSet(5, 20);        // [5, 10]  （半开区间）
s.headSet(10);          // [1, 5]
s.tailSet(10);          // [10, 20]
```

→ TreeSet **比 HashSet 强大**，但代价是 **O(log n)** 而不是 O(1)。

### 3.4 时间复杂度

| 操作 | 时间复杂度 |
| --- | --- |
| add / contains / remove | O(log n) |
| first / last | O(log n) |

---

## 四、LinkedHashSet

### 4.1 内部就是 LinkedHashMap

```java
public class LinkedHashSet<E> extends HashSet<E> {
    public LinkedHashSet() {
        super(16, 0.75f, true);     // 调用 HashSet 包私有构造，里面 new LinkedHashMap
    }
}
```

特征：

- 数据结构：HashMap（数组+链表+树）+ **双向链表**
- 双向链表记录**插入顺序**
- 遍历按插入序

### 4.2 vs HashSet

```java
Set<Integer> hash = new HashSet<>();
hash.add(3); hash.add(1); hash.add(2);
// 遍历：可能 1,2,3，可能 3,1,2，看 hash 分布

Set<Integer> linked = new LinkedHashSet<>();
linked.add(3); linked.add(1); linked.add(2);
// 遍历：3, 1, 2 ← 插入顺序
```

### 4.3 性能代价

LinkedHashSet **每个节点多 2 个引用**（before、after）：

- 内存比 HashSet 多约 **30%**
- 时间复杂度仍是 O(1)，但常数变大

**用途**：保留插入序的去重场景——比如订单 ID 去重后按到达顺序处理。

---

## 五、CopyOnWriteArraySet

```java
public class CopyOnWriteArraySet<E> implements Set<E> {
    private final CopyOnWriteArrayList<E> al;

    public CopyOnWriteArraySet() {
        al = new CopyOnWriteArrayList<>();
    }

    public boolean add(E e) {
        return al.addIfAbsent(e);    // 内部线性扫描判重 + COW 添加
    }
}
```

特征：

- 包装 `CopyOnWriteArrayList`
- 添加时 **线性扫描** 整个数组判重 → **O(n)**
- 写代价高，但读完全无锁

→ **只适合元素少、读远多于写**——典型场景：监听器列表、订阅者集合（几十到几百个）。**几千以上的 Set 不要用**——`addIfAbsent` 的 O(n) 加上 COW 整数组复制，性能爆炸。

---

## 六、ConcurrentSkipListSet

```java
public class ConcurrentSkipListSet<E> implements NavigableSet<E> {
    private final ConcurrentNavigableMap<E, Object> m;
}
```

特征：

- 包装 `ConcurrentSkipListMap`
- 数据结构：**跳表**（Skip List）
- 线程安全 + **排序**
- 时间复杂度 O(log n)
- 不允许 null

**跳表 vs 红黑树**：

| 维度 | 跳表 | 红黑树 |
| --- | --- | --- |
| 平均查找 | O(log n) | O(log n) |
| 内存 | 多（多层链表） | 少 |
| 并发 | 无锁 / CAS 友好 | 难（旋转影响多个节点） |

→ 高并发排序场景的唯一选择。Redis 的 ZSet 也用跳表，原因相同。

---

## 七、生产踩坑

### 7.1 自定义类做 Set 元素没重写 equals / hashCode

最常见——见 [2.3](#23-自定义类要重写-hashcode--equals)。**进 Set 的对象一定要重写**。

### 7.2 Set 元素的 hashCode 字段被改

```java
class User { String id; ... hashCode 用 id ... }
Set<User> set = new HashSet<>();
User u = new User("A"); set.add(u);
u.id = "B";                          // ⚠ 改了
set.contains(u);                     // false —— hashCode 变了，找不到桶
set.size();                          // 1 —— 但还在！
```

→ 进 Set 的对象 **hashCode 必须不可变**。可变的就别进 Set。

### 7.3 TreeSet 元素 null

```java
TreeSet<Integer> s = new TreeSet<>();
s.add(null);     // ⚠ NullPointerException（compareTo 调用）
```

TreeMap / TreeSet 都不允许 null key/element。

### 7.4 HashSet 期望去重但实际没去重

**根因**：`equals` 实现错误（比如对称性破坏、忘了类型检查）。
**排查方法**：

```java
User a = new User("1"), b = new User("1");
System.out.println(a.equals(b));         // 应该 true
System.out.println(a.hashCode() == b.hashCode());   // 应该 true
```

如果上面两条不全为 true，equals/hashCode 写错了。

### 7.5 ConcurrentModificationException

```java
Set<Integer> set = new HashSet<>(Arrays.asList(1,2,3));
for (Integer x : set) if (x == 2) set.remove(x);    // ⚠ CME
```

修复：

```java
set.removeIf(x -> x == 2);        // ✅
Iterator<Integer> it = set.iterator();
while (it.hasNext()) if (it.next() == 2) it.remove();   // ✅
```

参见 [集合框架总览 - fail-fast](./集合类.md#六fail-fast-vs-fail-safe)。

---

## 八、答题模板（60 秒话术）

> Set 三大实现都是 **Map 包一层**——HashSet 包 HashMap、TreeSet 包 TreeMap、LinkedHashSet 包 LinkedHashMap。把元素当 key、value 填同一个 dummy 对象。
>
> **HashSet**：底层 HashMap，O(1)，无序，**判重靠 hashCode + equals 契约**——自定义类必须同时重写。
>
> **TreeSet**：底层 TreeMap（红黑树），O(log n)，按 Comparable 或 Comparator 排序，提供 `first/last/floor/ceiling/subSet` 等 NavigableSet 能力。**不允许 null**。
>
> **LinkedHashSet**：底层 LinkedHashMap，O(1) + 双向链表保插入序。多 30% 内存换有序遍历。
>
> 线程安全：**CopyOnWriteArraySet**（包 COW List，addIfAbsent 是 O(n)，只适合元素少+读多）；**ConcurrentSkipListSet**（包跳表 Map，O(log n)，高并发排序唯一选择）。
>
> 进 Set 的对象 **hashCode 必须不可变**——否则放进去就再也找不到。

---

## 九、相关文档

- [HashMap](./HashMap.md) — Set 的底层
- [Object 类](./Object类.md) — equals/hashCode 契约
- [集合框架总览](./集合类.md) — 集合体系全景
- [Comparator](./Comparator.md) — TreeSet 的排序协议
- [Concurrency / ConcurrentHashMap](../Concurrency/ConcurrentHashMap.md) — 并发容器
