# Stream API

> Stream 是 JDK 8 的**集合处理范式革命**——从命令式（for 循环）转向声明式（filter/map/reduce）。
>
> 面试要回答：
> ① **Stream 不是集合** —— 数据源、不存储、一次性
> ② **中间操作 vs 终端操作** —— **惰性求值**才是核心
> ③ **常用操作**（filter/map/reduce/collect）+ Collectors 工厂
> ④ **并行流（parallelStream）** —— 什么时候用、什么时候坑
> ⑤ **生产高频踩坑** —— Collectors.toMap 重复 key、Stream 不能复用、装箱

---

## 一、Stream 不是集合

### 1.1 概念

**Stream**：从数据源（集合 / 数组 / IO）派生的 **元素序列**，支持**链式操作**和**聚合**。

```java
list.stream()
    .filter(x -> x > 5)        // 中间操作（返回 Stream）
    .map(x -> x * 2)            // 中间操作
    .collect(Collectors.toList());   // 终端操作（返回结果）
```

### 1.2 关键特征

| 维度 | Stream | 集合 |
| --- | --- | --- |
| **数据存储** | ❌ 不存数据 | ✅ 存 |
| **数据源** | 来自 Collection / 数组 / IO / Stream.of | 自己存 |
| **生命周期** | **一次性**——用完即弃 | 可重复访问 |
| **求值** | 中间操作**惰性**，终端操作触发 | 即时 |
| **并行** | `parallelStream()` 一行切并行 | 自己开线程 |

### 1.3 创建 Stream 的几种方式

```java
// 1. 集合
list.stream();
list.parallelStream();

// 2. 数组
Arrays.stream(arr);
Stream.of(1, 2, 3);

// 3. 范围
IntStream.range(0, 100);          // 0..99
IntStream.rangeClosed(0, 100);    // 0..100

// 4. 无限流（必须 limit）
Stream.iterate(0, x -> x + 2).limit(10);    // 0, 2, 4, ...
Stream.generate(Math::random).limit(5);

// 5. 文件
Files.lines(Path.of("a.txt"));    // ⚠ 用 try-with-resources

// 6. 字符串
"hello".chars();                  // IntStream of char codes
```

---

## 二、惰性求值（核心）

### 2.1 中间操作不立即执行

```java
list.stream()
    .filter(x -> {
        System.out.println("filter " + x);
        return x > 5;
    })
    .map(x -> {
        System.out.println("map " + x);
        return x * 2;
    });
// 上面这串什么都不打印——没有终端操作

list.stream().filter(...).map(...).count();
// 加 count 才打印
```

**核心**：**没有终端操作，整条流不执行**。

### 2.2 短路操作

```java
list.stream()
    .filter(x -> x > 0)
    .findFirst();        // 找到第一个就停止，不再 filter 后面的
```

**短路终端操作**：`findFirst` / `findAny` / `anyMatch` / `allMatch` / `noneMatch` / `limit`。

### 2.3 实测：迭代次数

```java
List<Integer> list = Arrays.asList(1, 2, 3, 4, 5);

list.stream()
    .filter(x -> { System.out.println("f " + x); return x > 0; })
    .map(x -> { System.out.println("m " + x); return x * 2; })
    .findFirst();

// 输出：f 1, m 1
// —— 只处理了第 1 个元素，找到就停。
```

→ 这就是 Stream 比"先 filter 全部 + 再 map 全部"高效的原因：**一个元素走完整条链**。

---

## 三、常用中间操作

### 3.1 filter / map / flatMap

```java
list.stream().filter(x -> x > 0)                    // 过滤
list.stream().map(String::toUpperCase)              // 转换
list.stream().mapToInt(String::length)              // 转 IntStream（避免装箱）

// flatMap：扁平化嵌套结构
List<List<Integer>> nested = ...;
nested.stream().flatMap(List::stream)               // 拍平成单层
                .collect(Collectors.toList());

// 数据库查询的典型用法
users.stream()
     .flatMap(user -> user.getOrders().stream())   // user → orders 拍平
     .collect(Collectors.toList());                 // 所有用户的所有订单
```

### 3.2 distinct / sorted / limit / skip

```java
list.stream()
    .distinct()                          // 去重（基于 equals）
    .sorted()                             // 自然序排序
    .sorted(Comparator.reverseOrder())    // 倒序
    .skip(5)                              // 跳前 5 个
    .limit(10)                            // 取 10 个
    ...
```

### 3.3 peek —— 调试工具

```java
list.stream()
    .filter(x -> x > 0)
    .peek(x -> System.out.println("after filter: " + x))    // 调试输出
    .map(x -> x * 2)
    .peek(x -> System.out.println("after map: " + x))
    .collect(...);
```

→ **peek 是中间操作**，没有终端操作不执行。**生产代码不要用 peek 改对象状态**——它的语义只是"看一眼"。

---

## 四、终端操作

### 4.1 收集到集合

```java
.collect(Collectors.toList());                      // → List
.collect(Collectors.toSet());                       // → Set
.collect(Collectors.toMap(User::getId, u -> u));    // → Map
.toList();                                          // JDK 16+ 等价 toList，**返回不可变 List**
```

### 4.2 reduce —— 聚合

```java
// sum
list.stream().reduce(0, Integer::sum);              // ⚠ 全程装箱

// max
list.stream().reduce((a, b) -> a > b ? a : b);      // 返回 Optional

// 字符串拼接
list.stream().reduce("", String::concat);           // ⚠ String 不可变，O(n²)
```

→ **拼接字符串别用 reduce**：

```java
list.stream().collect(Collectors.joining(","));     // ✅ StringBuilder 实现
```

### 4.3 数值聚合

```java
IntStream is = list.stream().mapToInt(User::getAge);
is.sum();
is.average();           // OptionalDouble
is.max();               // OptionalInt
is.summaryStatistics(); // IntSummaryStatistics（一次拿到 sum/avg/min/max/count）
```

### 4.4 forEach

```java
list.stream().forEach(System.out::println);

// ⚠ 并行流的 forEach 顺序不定
list.parallelStream().forEach(System.out::println);   // 乱序
list.parallelStream().forEachOrdered(System.out::println);   // 保持源顺序（牺牲并行收益）
```

### 4.5 匹配 / 查找

```java
list.stream().anyMatch(x -> x > 0);     // 任一满足
list.stream().allMatch(x -> x > 0);     // 全部满足
list.stream().noneMatch(x -> x < 0);    // 无满足

list.stream().findFirst();              // 第一个（保序）
list.stream().findAny();                // 任一（并行流更快）
```

---

## 五、Collectors 工厂方法

```java
// 收集到集合
Collectors.toList()
Collectors.toUnmodifiableList()             // JDK 10+
Collectors.toSet()
Collectors.toMap(keyMapper, valueMapper)
Collectors.toMap(k, v, mergeFunction)       // 处理重复 key
Collectors.toMap(k, v, m, () -> new TreeMap<>())   // 指定 Map 类型

// 字符串
Collectors.joining()
Collectors.joining(", ")
Collectors.joining(", ", "[", "]")          // [a, b, c]

// 分组（最常用）
Collectors.groupingBy(User::getDept)                // Map<Dept, List<User>>
Collectors.groupingBy(User::getDept, Collectors.counting())     // Map<Dept, Long>
Collectors.groupingBy(User::getDept, Collectors.summingInt(User::getAge))  // Map<Dept, Integer>
Collectors.groupingBy(User::getDept, Collectors.mapping(User::getName, toList()))

// 分区（按条件 true/false）
Collectors.partitioningBy(u -> u.getAge() > 18)     // Map<Boolean, List<User>>

// 聚合
Collectors.counting()
Collectors.summingInt(User::getAge)
Collectors.averagingInt(User::getAge)
Collectors.minBy(comparator)
Collectors.maxBy(comparator)
```

### 5.1 经典分组

```java
// 按部门分组用户
Map<String, List<User>> byDept = users.stream()
    .collect(Collectors.groupingBy(User::getDept));

// 按部门统计人数
Map<String, Long> countByDept = users.stream()
    .collect(Collectors.groupingBy(User::getDept, Collectors.counting()));

// 按部门求平均年龄
Map<String, Double> avgAgeByDept = users.stream()
    .collect(Collectors.groupingBy(User::getDept, Collectors.averagingInt(User::getAge)));

// 多级分组
Map<String, Map<String, List<User>>> byDeptAndCity = users.stream()
    .collect(Collectors.groupingBy(User::getDept, Collectors.groupingBy(User::getCity)));
```

→ 一行代码完成传统 SQL 的 GROUP BY。**生产高频用法**。

---

## 六、并行流（parallelStream）

### 6.1 怎么用

```java
list.parallelStream()
    .filter(...)
    .map(...)
    .collect(...);

// 或者从普通流转
list.stream().parallel()...
```

### 6.2 底层是 ForkJoinPool

并行流默认用 **`ForkJoinPool.commonPool`**——**全 JVM 共享**的线程池。

```java
ForkJoinPool.commonPool();    // 默认并行度 = CPU 核数 - 1
```

→ **多个并行流同时跑会互相争用**——一个慢的并行流会拖慢其他业务。

### 6.3 什么时候用

**用并行流的条件**（要全满足）：

- 数据量大（**至少 1 万级以上**）
- **CPU 密集型**操作（不是 IO）
- 操作**无副作用**（不修改外部状态）
- 元素**可拆分**（ArrayList / 数组好，LinkedList 差）
- 不要**保序**

**不要用的场景**：

- IO 操作（用 CompletableFuture 替代）
- 数据小（开线程的开销大于收益）
- 业务依赖处理顺序

### 6.4 性能反例

```java
// ⚠ 看着合理，实际更慢
List<Integer> small = Arrays.asList(1, 2, 3, 4, 5);
small.parallelStream().map(x -> x * 2).count();
// 启动并行机制 + 拆分 + 合并的开销远大于直接 5 次乘法
```

实测：**1000 元素以下并行流几乎一定更慢**。

### 6.5 用自定义 ForkJoinPool

```java
ForkJoinPool pool = new ForkJoinPool(4);
pool.submit(() -> 
    list.parallelStream().map(...).collect(...)
).get();
```

→ 想避开 commonPool 共享问题。但 Stream 内部仍走 ForkJoinPool 的工作窃取——**重 IO 任务还是别用**。

---

## 七、生产踩坑

### 7.1 Collectors.toMap 重复 key 抛异常

```java
Map<String, User> map = users.stream()
    .collect(Collectors.toMap(User::getName, u -> u));   // ⚠ name 重复抛 IllegalStateException
```

**修复 1：合并函数**：

```java
.collect(Collectors.toMap(User::getName, u -> u, (oldV, newV) -> newV));   // 后者覆盖
.collect(Collectors.toMap(User::getName, u -> u, (oldV, newV) -> oldV));   // 前者保留
```

**修复 2：分组**：

```java
Map<String, List<User>> map = users.stream()
    .collect(Collectors.groupingBy(User::getName));
```

### 7.2 Collectors.toMap value 为 null 抛 NPE

```java
.collect(Collectors.toMap(User::getId, User::getNickname));   // ⚠ nickname 为 null → NPE
```

**根因**：`HashMap.merge` 内部检查 value 非空——这是 toMap 的合并函数走 merge 的副作用。

**修复**：

```java
// 1. 过滤掉 null value
users.stream().filter(u -> u.getNickname() != null).collect(toMap(...));

// 2. 用 collect + 自定义 supplier
.collect(HashMap::new, (m, u) -> m.put(u.getId(), u.getNickname()), Map::putAll);
```

### 7.3 Stream 不能复用

```java
Stream<Integer> s = list.stream();
s.count();           // 第一次 OK
s.findFirst();       // ⚠ IllegalStateException: stream has already been operated upon or closed
```

**Stream 是一次性的**——终端操作执行后就 close 了。要再用要**重新 stream**。

### 7.4 forEach 修改外部变量

```java
List<Integer> result = new ArrayList<>();
list.parallelStream().forEach(result::add);    // ⚠ 多线程并发 add，丢数据 / 抛异常
```

**修复**：用 `collect`：

```java
List<Integer> result = list.parallelStream().collect(Collectors.toList());
```

→ `Collectors.toList` 内部用线程安全的合并机制（每个线程一个本地 list，最后合并）。

### 7.5 装箱导致性能差

```java
list.stream().reduce(0, Integer::sum);              // ⚠ 全程装箱
list.stream().mapToInt(Integer::intValue).sum();    // ✅ IntStream
```

实测：**装箱版慢 5-10x**。

### 7.6 Files.lines 没关闭

```java
Files.lines(path).forEach(...);    // ⚠ Stream 没关闭，文件句柄泄漏

// ✅
try (Stream<String> lines = Files.lines(path)) {
    lines.forEach(...);
}
```

→ **从 IO 来的 Stream 必须 try-with-resources**（Stream 实现了 AutoCloseable）。

### 7.7 Stream 不会让代码更快

```java
// 简单循环用 Stream 没有性能优势
int sum = 0;
for (int x : list) sum += x;                       // 1x

list.stream().mapToInt(i -> i).sum();              // ~1x（差不多）
```

→ **Stream 的价值是可读性、声明式**，不是性能。**简单循环不要为了"看起来现代化"改 Stream**。

### 7.8 Stream 影响 Debug

```java
// 调试痛点：Stream 链上某一步出错，栈跟踪很难定位
list.stream().map(...).filter(...).reduce(...);    // 报错栈深、不易看
```

→ Lambda 里抛异常时栈信息有限。**复杂业务避免一行写完整条 Stream**——拆开命名变量便于调试：

```java
List<Order> filtered = list.stream().filter(...).collect(toList());
List<OrderDTO> dtos = filtered.stream().map(...).collect(toList());
```

---

## 八、面试高频追问

### Q1：Stream 是什么？和集合区别？

Stream 是**元素序列上的链式操作**，本身不存数据、一次性、惰性求值；集合是数据存储。Stream 提供声明式 API（filter/map/reduce）替代命令式 for 循环。

### Q2：什么是中间操作和终端操作？

中间操作返回 Stream，**惰性**——不立即执行（filter/map/sorted/distinct）；终端操作返回结果或 void，触发实际执行（collect/reduce/forEach/count）。**没有终端操作整条 Stream 不执行**。

### Q3：Stream 是怎么"惰性"的？

每个中间操作返回新的 Stream 对象，内部记录操作链；终端操作触发时**逐元素**走完整条链——一个元素走完所有中间操作再处理下一个。短路操作（findFirst）可以提前终止。

### Q4：parallelStream 怎么用？什么时候用？

底层 **ForkJoinPool.commonPool**，全 JVM 共享。条件：数据量大（≥1 万）+ CPU 密集 + 无副作用 + 可拆分 + 不需保序。**IO 密集别用**——用 CompletableFuture。

### Q5：Collectors.toMap 重复 key 怎么办？

抛 IllegalStateException。修复传**合并函数** `(old, new) -> new` 或改用 `groupingBy`。还要注意 value 不能 null（HashMap.merge 检查），否则 NPE。

### Q6：Stream 能复用吗？

**不能**——终端操作后 Stream close。要复用就重新 `list.stream()`。

### Q7：reduce 和 collect 区别？

- `reduce`：**不可变聚合**（基于不变量累加，像求 sum）
- `collect`：**可变聚合**（用 mutable container 聚合，像 ArrayList）

`reduce(0, Integer::sum)` 每次新建 Integer，**O(n) 装箱**；`Collectors.summingInt` 内部用 int[] 累加，零装箱。

### Q8：mapToInt 和 map 区别？

`map(Function<T,R>)` 返回 `Stream<R>`；`mapToInt(ToIntFunction<T>)` 返回 `IntStream`——**避免装箱**，提供 sum/average/max/min 等数值聚合方法。性能敏感场景必用。

### Q9：peek 干什么？

中间操作，**只看不改**——没终端操作不执行，所以**不能用 peek 来代替 forEach**。生产 peek 用于调试日志，**别用来改对象状态**。

### Q10：Stream 性能比 for 好吗？

不一定——简单循环 Stream 略慢（链式调用开销、JIT 内联难度），并行流大数据量才快。**Stream 的价值是可读性和声明式**，不是性能。

---

## 九、答题模板（90 秒话术）

> Stream 是 JDK 8 的**集合处理范式**——把命令式 for 循环转成声明式 filter/map/reduce 链。Stream **不是集合**：不存数据、一次性、惰性求值。
>
> 操作分**中间操作**（filter/map/sorted，返回 Stream，惰性）和**终端操作**（collect/reduce/forEach/count，触发执行）。**没终端不跑**。短路操作（findFirst/anyMatch）可以提前终止。
>
> Stream 是**逐元素走完整条链**——不是先 filter 全部再 map 全部，所以 `findFirst` 找到第一个就停，效率高。
>
> 高频用法：`Collectors.groupingBy(User::getDept, Collectors.counting())` 一行代替 SQL GROUP BY；`Collectors.toMap` 注意**重复 key 要传合并函数、value 不能 null**。
>
> **parallelStream** 底层是 **ForkJoinPool.commonPool**（JVM 共享）——只在数据量 ≥1 万 + CPU 密集 + 无副作用 + 可拆分时用。**IO 任务用 CompletableFuture**，不要用并行流。
>
> 性能：**数值聚合用 IntStream/LongStream/DoubleStream + mapToInt** 避免装箱（差 5-10x）；**简单循环 Stream 没有性能优势**——Stream 的价值是可读性。
>
> 生产几个坑：**Stream 不能复用**（重新 stream）、**Files.lines 必须 try-with-resources**、**复杂业务不要一行 Stream 写完**（debug 困难）。

---

## 十、相关文档

- [Lambda 与函数式接口](./Lambda与函数式接口.md) — Stream 的最大用户
- [Optional](./Optional.md) — findFirst / max 等返回 Optional
- [Comparator](./Comparator.md) — sorted 用 Comparator
- [基本数据类型与自动装箱](./基本数据类型与自动装箱.md) — Stream 的装箱开销
- [Concurrency / ForkJoinPool](../Concurrency/ForkJoinPool.md) — parallelStream 的底层
- [Concurrency / CompletableFuture](../Concurrency/CompletableFuture.md) — IO 任务的并行替代
