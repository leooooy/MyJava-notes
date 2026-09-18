# Comparable vs Comparator

> 排序协议是面试常考题，但被问得不深——除非你写了减法 trick 翻车。
>
> 本篇要讲清 4 件事：
> ① **Comparable 和 Comparator 的本质区别**——为什么要两个
> ② **compareTo / compare 的返回值约定** + 必须满足的契约
> ③ **减法写法的整型溢出坑**——经典面试陷阱
> ④ **Comparator 的链式 API**（JDK 8）——生产怎么写

---

## 一、为什么要两个排序接口

```java
public interface Comparable<T> {
    int compareTo(T o);     // 在自己类里实现，"自然顺序"
}

public interface Comparator<T> {
    int compare(T o1, T o2);    // 外部独立类，可有多种排序策略
}
```

**核心区别**：

- **Comparable**：内置在类里，**一个类只能有一种自然顺序**（比如 String 按字典序、Integer 按数值）
- **Comparator**：外部定义，**可以有任意多种排序策略**（按年龄、按姓名、按入职时间...）

**类比**：Comparable 是"我天生该按什么顺序排"，Comparator 是"现在我们按这个规则排"。

---

## 二、Comparable vs Comparator 对比

| 维度 | Comparable | Comparator |
| --- | --- | --- |
| 包 | `java.lang` | `java.util` |
| 方法 | `compareTo(T)` | `compare(T, T)` |
| 实现位置 | **被比较的类自己** | **外部独立类** |
| 排序策略数 | 1 种（自然序） | 多种 |
| 函数式接口 | ✅ | ✅（@FunctionalInterface） |
| 修改源码 | 需要 | 不需要 |
| 使用 | `Collections.sort(list)` | `list.sort(comparator)` |

**典型用法**：

```java
// Comparable：自己定义自然序
class User implements Comparable<User> {
    int age;
    public int compareTo(User other) {
        return Integer.compare(this.age, other.age);
    }
}
Collections.sort(userList);     // 按 age

// Comparator：外部多种排序策略
List<User> list = ...;
list.sort(Comparator.comparing(User::getName));        // 按 name
list.sort(Comparator.comparing(User::getAge).reversed());  // 按 age 降序
```

---

## 三、返回值约定（必背）

### 3.1 三种返回值

```java
return  -1;   // this < other  (排前面)
return   0;   // this == other (相等)
return  +1;   // this > other  (排后面)
```

实际上**返回任何 < 0、0、> 0 的整数都行**——但**严禁用减法**写。

### 3.2 比较协议（Effective Java）

```
1. 自反性：x.compareTo(x) == 0
2. 反对称性：sgn(x.compareTo(y)) == -sgn(y.compareTo(x))
3. 传递性：x.compareTo(y) > 0 && y.compareTo(z) > 0 → x.compareTo(z) > 0
4. 一致性：x.compareTo(y) == 0 → sgn(x.compareTo(z)) == sgn(y.compareTo(z))
5. 推荐与 equals 一致：(x.compareTo(y) == 0) == x.equals(y)
```

**违反协议**会怎样：

- 反对称性破坏 → `Collections.sort` 抛 `IllegalArgumentException: Comparison method violates its general contract`
- 传递性破坏 → 同上
- 与 equals 不一致 → **TreeSet/TreeMap 行为诡异**：`treeSet.contains(x)` 返回 false 但 `set.iterator()` 能找到 x

---

## 四、Comparator 的链式 API（JDK 8）

### 4.1 静态工厂

```java
Comparator<User> byAge = Comparator.comparing(User::getAge);                     // 按 age
Comparator<User> byAgeDesc = Comparator.comparing(User::getAge).reversed();      // 按 age 降序
Comparator<User> nullSafe = Comparator.nullsFirst(byAge);                        // null 在前

// 组合：先按 age，age 相同按 name
Comparator<User> combined = Comparator.comparing(User::getAge)
                                      .thenComparing(User::getName);

// 多种类型字段
Comparator<User> mixed = Comparator.comparingInt(User::getAge)                   // 避免拆箱
                                   .thenComparing(User::getName)
                                   .thenComparing(User::getCreateTime);
```

### 4.2 性能：comparingInt vs comparing

```java
Comparator.comparing(User::getAge)        // ⚠ Integer，每次拆箱
Comparator.comparingInt(User::getAge)     // ✅ int，无拆箱
```

→ 数值字段用 `comparingInt` / `comparingLong` / `comparingDouble`，避免装箱开销。

### 4.3 自然序的快捷

```java
Comparator.naturalOrder()        // 等价 (a, b) -> a.compareTo(b)
Comparator.reverseOrder()        // 反向

list.sort(Comparator.naturalOrder());            // 等价 Collections.sort(list)
list.sort(Comparator.reverseOrder());            // 降序
```

---

## 五、Comparator vs Comparable 在容器中的应用

### 5.1 TreeMap / TreeSet 的两种比较方式

```java
// 方式 1：元素实现 Comparable
TreeSet<Integer> s = new TreeSet<>();    // 用 Integer.compareTo

// 方式 2：构造时传 Comparator
TreeSet<User> s = new TreeSet<>(Comparator.comparing(User::getName));
```

**优先级**：构造传 Comparator → 用 Comparator；不传 → 元素必须 Comparable，用其 compareTo。

### 5.2 PriorityQueue 同理

```java
PriorityQueue<User> pq = new PriorityQueue<>(Comparator.comparing(User::getPriority).reversed());
```

### 5.3 Collections.sort / List.sort

```java
List<User> list = ...;
Collections.sort(list);                          // 要求 User implements Comparable
Collections.sort(list, byAge);
list.sort(byAge);                                // JDK 8+ 推荐
```

---

## 六、生产踩坑

### 6.1 减法写法的整型溢出坑

**经典坑**：

```java
Comparator<Integer> wrong = (a, b) -> a - b;     // ⚠

wrong.compare(Integer.MAX_VALUE, -1);
// = MAX_VALUE - (-1) = MAX_VALUE + 1 = Integer.MIN_VALUE  → 溢出！
// 期望返回 +1（a > b），实际返回 MIN_VALUE → 错误
```

**正确写法**：

```java
// 方式 1：Integer.compare（推荐）
Comparator<Integer> right = (a, b) -> Integer.compare(a, b);
Comparator<Integer> right2 = Comparator.naturalOrder();

// 方式 2：显式判断
Comparator<Integer> right3 = (a, b) -> a < b ? -1 : a > b ? 1 : 0;
```

→ **永远不要用减法写 compare**——除非你能证明数值范围安全。`Long.compare`、`Double.compare` 同样比手写减法安全。

### 6.2 比较 long / double

```java
// ⚠ long 强转 int 也会溢出
Comparator<Long> wrong = (a, b) -> (int)(a - b);

// ✅
Comparator<Long> right = (a, b) -> Long.compare(a, b);

// ⚠ double 不能用减法（NaN、+0/-0 问题）
Comparator<Double> wrong2 = (a, b) -> (int)(a - b);

// ✅
Comparator<Double> right2 = Double::compare;
```

### 6.3 排序中修改对象

```java
list.sort((a, b) -> {
    a.cnt++;     // ⚠ 在 compare 里改对象状态
    return a.cnt - b.cnt;
});
```

→ Comparator 必须是**无副作用、纯函数**——破坏了一致性，sort 会抛 IllegalArgumentException 或行为诡异。

### 6.4 Comparator 与 equals 不一致

```java
class User {
    String id, name;
    @Override boolean equals(Object o) { return ...id 比较... }
}

TreeSet<User> set = new TreeSet<>(Comparator.comparing(User::getName));
set.add(new User("1", "Alice"));
set.add(new User("2", "Alice"));    // ⚠ name 相同 → TreeSet 认为相等 → 不加入

set.size();                          // 1 ⚠
set.contains(new User("3", "Alice"));   // true（name 相同就算）
```

**TreeSet 用 Comparator 的 0 判等**，不用 equals。**生产规范**：Comparator 与 equals 一致——比较所有 equals 用的字段。

### 6.5 Comparable 实现破坏对称性

```java
class A implements Comparable<A> { ... }
class B extends A { 
    @Override public int compareTo(A o) {
        if (!(o instanceof B)) return 1;     // ⚠ 子类拒绝和父类比
        ...
    }
}

A a = new A(...); B b = new B(...);
a.compareTo(b);    // 走 A 的逻辑（可能 0）
b.compareTo(a);    // 总是 1
// 反对称性破坏
```

→ Comparable 在继承层级里很难写对，**Effective Java 推荐用 Comparator 替代**——外部比较器更易控制。

---

## 七、面试高频追问

### Q1：Comparable 和 Comparator 区别？

Comparable 是被比较类自己实现的"自然顺序"，一个类一种；Comparator 是外部独立类，可定义任意多种排序策略。前者要改源码，后者不用。

### Q2：compareTo 返回什么？

负数：当前对象排前面（小于）；零：相等；正数：当前对象排后面（大于）。**严禁用减法**——整型溢出。用 `Integer.compare(a, b)` / `Long.compare(a, b)`。

### Q3：用减法写 compare 有什么问题？

整型溢出。`MAX_VALUE - (-1)` 溢出为 `MIN_VALUE`，本应返回 +1 反而返回大负数。Effective Java 第 14 条专门讲。

### Q4：必须重写 hashCode 才能用 Comparator 吗？

不是，Comparator 不依赖 hashCode。但**TreeSet/TreeMap 用 Comparator 判等**（compare 返回 0），如果和 equals 不一致 contains 会怪。生产建议 **Comparator 和 equals 一致**。

### Q5：JDK 8 Comparator 链式 API 怎么用？

```java
Comparator.comparing(User::getAge)               // 按 age
          .thenComparing(User::getName)          // 同 age 按 name
          .reversed();                           // 整体倒序
```

数值字段用 `comparingInt/Long/Double` 避免装箱。

### Q6：TreeSet 用什么比较元素？

构造时传 Comparator → 用 Comparator；不传 → 元素必须 Comparable，用 compareTo。**注意**：TreeSet 用 0 判等，不用 equals——所以 Comparator 要和业务"相等"语义一致。

### Q7：实现 Comparable 时和 equals 必须一致吗？

不强制，但**强烈推荐**：`compareTo == 0` 应该等价 `equals == true`。不一致会让 TreeSet/TreeMap 行为诡异。BigDecimal 是反例：`new BigDecimal("1.0").equals(new BigDecimal("1.00"))` 是 false 但 `compareTo` 返回 0——所以 BigDecimal 不能放 HashSet 期望去重。

---

## 八、答题模板（60 秒话术）

> **Comparable 是被比较类自己实现的自然顺序**（compareTo 在类里），**Comparator 是外部排序策略**（compare 在独立类）——一个类一种自然序、可有多种 Comparator。
>
> 返回值约定：**负数 / 零 / 正数**，分别表示小于 / 等于 / 大于。**严禁用减法**——`a - b` 整型溢出，正确写法是 `Integer.compare(a, b)` 或 `Long.compare`。
>
> JDK 8 链式 API：`Comparator.comparing(...).thenComparing(...).reversed()`，**数值字段用 `comparingInt/Long/Double`** 避免装箱。
>
> 三大契约：自反 / 反对称 / 传递。破坏会让 sort 抛 `Comparison method violates its general contract`。**强烈推荐 compareTo == 0 等价 equals**——TreeSet/TreeMap 用 compare 判等，不一致会出诡异 bug。
>
> Effective Java 推荐：**继承层级里用 Comparator 而非 Comparable**——外部比较器更易控制，避免子类破坏对称性。

---

## 九、相关文档

- [Object 类](./Object类.md) — equals 和 compareTo 一致性
- [集合框架总览](./集合类.md) — 集合体系
- [Set](./Set.md) — TreeSet 用 Comparator 排序和判等
- [Queue](./Queue.md) — PriorityQueue 用 Comparator 决定优先级
- [HashMap](./HashMap.md) — TreeMap 同样依赖 Comparator
