# Java 面试模块

> Java 后端面试的 **基础底盘**——集合、Object 契约、String、抽象/接口、Java 8 函数式（Lambda/Stream/Optional）、泛型、反射、异常这些是几乎每场面试**必问**的内容。
>
> 本模块按 **基础 → 集合 → 函数式 → 进阶 → 算法** 五层组织，每篇按 senior 标准写：原理 + 取舍 + 面试追问 + 生产踩坑 + 答题模板。
>
> 共 19 篇，约 350KB。可以按"推荐学习路径"按序读，也可以按"高频题映射"直接跳。

---

## 一、模块导航

### 基础（6 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [JDK / JRE / JVM 与版本演进](./jdk.md) | 三者关系、Oracle JDK vs OpenJDK、LTS 版本（8/11/17/21）选型、关键特性时间线 |
| [基本数据类型与自动装箱](./基本数据类型与自动装箱.md) | 8 种基本类型、Integer 缓存 -128~127、float/double 精度、BigDecimal、parseInt vs valueOf |
| [Object 类](./Object类.md) | 11 个方法、equals/hashCode 契约、深浅拷贝、wait/notify 必须在 synchronized 内 |
| [String 原理](./String原理.md) | 不可变性、字符串常量池、intern、JDK 9 紧凑字符串、StringBuilder vs StringBuffer |
| [抽象类和接口](./抽象类和接口.md) | 区别、Java 8 default/static、Java 9 private、设计选型 |
| [集合框架总览](./集合类.md) | Collection vs Map 体系、线程安全分类、fail-fast vs fail-safe |

### 集合（5 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [List](./List.md) | ArrayList 扩容 1.5x、LinkedList 双向链表、Vector 已淘汰、CopyOnWriteArrayList |
| [HashMap](./HashMap.md) | 数组+链表+红黑树、扰动函数、JDK 7 头插死循环、TreeMap、LinkedHashMap |
| [Set](./Set.md) | HashSet 包装 HashMap、TreeSet 红黑树、LinkedHashSet 保序、CopyOnWriteArraySet |
| [Queue](./Queue.md) | Queue/Deque 体系、ArrayDeque vs LinkedList、PriorityQueue 二叉堆 |
| [Comparable vs Comparator](./Comparator.md) | 自然序 vs 定制序、签名/返回值约定、Comparator 链式 API |

### 函数式（3 篇，Java 8+ 必考）

| 文档 | 一句话定位 |
| --- | --- |
| [Lambda 与函数式接口](./Lambda与函数式接口.md) | invokedynamic + LambdaMetafactory、4 大函数式接口、方法引用、effectively final |
| [Stream API](./Stream%20API.md) | 中间 vs 终端操作、惰性求值、Collectors、parallelStream 何时用 |
| [Optional](./Optional.md) | 设计动机、orElse vs orElseGet、map/flatMap、不要做字段/参数 |

### 进阶（3 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [异常体系](./异常体系.md) | Throwable 层级、Checked vs Unchecked、try-with-resources、异常吞掉的坑 |
| [泛型](./泛型.md) | 类型擦除、桥接方法、PECS、`<? extends>` vs `<? super>`、不能 new T[] |
| [反射与动态代理](./反射与动态代理.md) | Class/Method/Field、JDK Proxy（接口）vs CGLIB（继承）、Spring AOP 选型 |

> **注意**：原 Java 模块下的 [限流算法](../Microservice/限流算法.md) 已迁至 [Microservice 模块](../Microservice/README.md)，[一致性哈希](../Distributed/一致性哈希.md) 已迁至 [Distributed 模块](../Distributed/README.md)——这两个话题本质属于分布式 / 微服务范畴，不是 Java 语言特性。

---

## 二、面试高频题 → 文档映射

被问到这些题，直接跳到对应文档：

### 基础

| 高频题 | 跳转 |
| --- | --- |
| `Integer a = 100, b = 100; a == b` 是什么？ | [基本类型](./基本数据类型与自动装箱.md#三integer-缓存经典面试题) |
| 为什么 `0.1 + 0.2 != 0.3`？ | [基本类型](./基本数据类型与自动装箱.md#四float--double-精度) |
| BigDecimal 怎么正确用？ | [基本类型](./基本数据类型与自动装箱.md#43-bigdecimal--钱必须用) |
| 自动装箱的底层是什么？ | [基本类型](./基本数据类型与自动装箱.md#二包装类与自动装箱) |
| parseInt 和 valueOf 区别？ | [基本类型](./基本数据类型与自动装箱.md#五parseint-vs-valueof-vs-intvalue) |
| JDK / JRE / JVM 区别？ | [jdk](./jdk.md#二jdk--jre--jvm-的关系) |
| Oracle JDK 和 OpenJDK 区别？ | [jdk](./jdk.md#三oracle-jdk-vs-openjdk) |
| 你们用什么版本？为什么？ | [jdk](./jdk.md#四主流-lts-版本对比) |
| `==` 和 equals 区别？ | [Object 类](./Object类.md#四equals--逻辑相等) |
| 重写 equals 必须重写 hashCode 吗？为什么？ | [Object 类](./Object类.md#62-必须配套重写的根本原因) |
| Object 有哪些方法？ | [Object 类](./Object类.md#一object-的-11-个方法) |
| wait / notify 为什么要在 synchronized 里？ | [Object 类](./Object类.md#八waitnotify-为什么必须在-synchronized-里) |
| 浅拷贝和深拷贝？怎么实现深拷贝？ | [Object 类](./Object类.md#七clone--浅拷贝-vs-深拷贝) |
| String 为什么不可变？为什么这么设计？ | [String 原理](./String原理.md#一不可变设计) |
| `String s = "abc"` 创建几个对象？ | [String 原理](./String原理.md#42-面试高频追问) |
| `new String("abc")` 创建几个对象？ | [String 原理](./String原理.md#42-面试高频追问) |
| intern() 干什么？ | [String 原理](./String原理.md#四字符串常量池) |
| String、StringBuilder、StringBuffer 区别？ | [String 原理](./String原理.md#六stringbuilder-vs-stringbuffer) |
| 抽象类和接口区别？什么时候用哪个？ | [抽象类和接口](./抽象类和接口.md#四怎么选-final-决策表) |
| Java 8 接口 default 方法解决了什么问题？ | [抽象类和接口](./抽象类和接口.md#三java-8--9-接口的演进) |
| 接口能多继承吗？菱形继承怎么处理？ | [抽象类和接口](./抽象类和接口.md#52-菱形继承钻石问题) |

### 集合

| 高频题 | 跳转 |
| --- | --- |
| 集合体系画一下？ | [集合框架总览](./集合类.md#一集合框架全景图) |
| ArrayList 怎么扩容？ | [List](./List.md#二arraylist) |
| ArrayList 和 LinkedList 区别？ | [List](./List.md#四arraylist-vs-linkedlist-决策表) |
| LinkedList 真比 ArrayList 头插快吗？ | [List](./List.md#52-linkedlist-真的快吗) |
| Vector 和 ArrayList 区别？为什么不推荐？ | [List](./List.md#五vector--已淘汰) |
| CopyOnWriteArrayList 原理？适用场景？ | [List](./List.md#六copyonwritearraylist) |
| HashMap 数据结构？JDK 7 vs 8 区别？ | [HashMap](./HashMap.md#二jdk-7-vs-jdk-8-数据结构演进) |
| HashMap 的 hash 函数为什么要扰动？ | [HashMap](./HashMap.md#三扰动函数为什么右移-16) |
| 链表什么时候转红黑树？为什么是 8？ | [HashMap](./HashMap.md#52-为什么链表-8--红黑树6--退化) |
| HashMap 怎么扩容？为什么是 2 的幂？ | [HashMap](./HashMap.md#六扩容机制) |
| JDK 7 HashMap 多线程死循环？ | [HashMap](./HashMap.md#101-jdk-7-头插死循环) |
| HashMap、TreeMap、LinkedHashMap 区别？ | [HashMap](./HashMap.md#八treemap--linkedhashmap) |
| HashSet 怎么保证不重复？底层是什么？ | [Set](./Set.md#二hashset) |
| TreeSet 怎么排序？ | [Set](./Set.md#三treeset) |
| Queue 和 Deque 关系？ | [Queue](./Queue.md#一queue--deque-体系) |
| ArrayDeque 和 LinkedList 选哪个做栈？ | [Queue](./Queue.md#33-arraydeque-vs-linkedlist) |
| PriorityQueue 是什么数据结构？ | [Queue](./Queue.md#四priorityqueue) |
| Comparable 和 Comparator 区别？ | [Comparator](./Comparator.md#二comparable-vs-comparator-对比) |
| compareTo 返回什么？写反了会有什么问题？ | [Comparator](./Comparator.md#62-减法写法的整型溢出坑) |

### 函数式（Java 8+）

| 高频题 | 跳转 |
| --- | --- |
| Lambda 和匿名内部类区别？ | [Lambda](./Lambda与函数式接口.md#六lambda-vs-匿名内部类) |
| Lambda 为什么用 invokedynamic？ | [Lambda](./Lambda与函数式接口.md#一为什么需要-lambda) |
| 4 大函数式接口？ | [Lambda](./Lambda与函数式接口.md#32-4-大常用函数式接口必背) |
| 闭包变量为什么必须 effectively final？ | [Lambda](./Lambda与函数式接口.md#52-为什么这个限制) |
| 方法引用 4 种形式？ | [Lambda](./Lambda与函数式接口.md#41-4-种形式) |
| Stream 中间操作 vs 终端操作？ | [Stream](./Stream%20API.md#二惰性求值核心) |
| Stream 是惰性求值什么意思？ | [Stream](./Stream%20API.md#二惰性求值核心) |
| parallelStream 什么时候用？ | [Stream](./Stream%20API.md#六并行流parallelstream) |
| Collectors.toMap 重复 key 怎么处理？ | [Stream](./Stream%20API.md#71-collectorstomap-重复-key-抛异常) |
| reduce 和 collect 区别？ | [Stream](./Stream%20API.md#42-reduce--聚合) |
| Optional 的 orElse 和 orElseGet 区别？ | [Optional](./Optional.md#三orelse-vs-orelseget必考) |
| Optional 能做字段/参数吗？ | [Optional](./Optional.md#五optional-不要做什么生产规范) |
| Optional.of vs ofNullable？ | [Optional](./Optional.md#21-三个工厂方法) |

### 进阶

| 高频题 | 跳转 |
| --- | --- |
| 异常体系画一下？ | [异常体系](./异常体系.md#一throwable-体系全景) |
| Checked 和 Unchecked 区别？什么时候抛 RuntimeException？ | [异常体系](./异常体系.md#二checked-vs-unchecked) |
| Error 能 catch 吗？ | [异常体系](./异常体系.md#22-error--unchecked--checked) |
| try-finally 里 return，结果是什么？ | [异常体系](./异常体系.md#52-finally-与-return-的执行顺序) |
| try-with-resources 原理？ | [异常体系](./异常体系.md#四try-with-resources) |
| 泛型类型擦除是什么？带来什么影响？ | [泛型](./泛型.md#二类型擦除type-erasure) |
| `List<Integer>` 和 `List<String>` 是同一个类吗？ | [泛型](./泛型.md#21-擦除后是同一个-class) |
| `<? extends T>` 和 `<? super T>`（PECS）？ | [泛型](./泛型.md#四pecs-原则) |
| 为什么 `new T[]` 编译不过？ | [泛型](./泛型.md#62-为什么不能-new-t) |
| 反射调用慢吗？为什么？ | [反射与动态代理](./反射与动态代理.md#33-反射性能为什么慢) |
| JDK Proxy 和 CGLIB 区别？ | [反射与动态代理](./反射与动态代理.md#五jdk-proxy-vs-cglib-面试必考) |
| Spring AOP 默认用哪个？ | [反射与动态代理](./反射与动态代理.md#六spring-aop-的代理选型) |
| Method.invoke 内部做了什么？ | [反射与动态代理](./反射与动态代理.md#33-反射性能为什么慢) |

### 算法（已迁出）

> 限流算法、一致性哈希迁至 [Distributed 模块](../Distributed/README.md#二面试高频题--文档映射)。

---

## 三、推荐学习路径

### 新手路径（按依赖序）

```
基础层（必修）
 1. JDK / JRE / JVM           ← 全局视角
 2. 基本数据类型与自动装箱     ← Integer 缓存 / BigDecimal 是高频陷阱
 3. Object 类                  ← equals/hashCode 契约决定后面 HashMap 的正确性
 4. String 原理                ← 不可变 + 常量池
 5. 抽象类和接口               ← 设计的两种基础抽象

集合层（高频考区）
 6. 集合框架总览               ← 体系图
 7. List                      ← 最常用
 8. HashMap                   ← 最高频，必背
 9. Set / Queue               ← 边角但常考
10. Comparator                ← 排序协议

函数式层（Java 8+ 必考）
11. Lambda 与函数式接口       ← invokedynamic + LambdaMetafactory
12. Stream API                ← 集合处理范式革命
13. Optional                  ← NPE 解药，但 90% 用错

进阶层
14. 异常体系                  ← 必背 Throwable
15. 泛型                      ← 类型擦除是面试坑
16. 反射与动态代理            ← Spring AOP / MyBatis 都靠它

> 限流算法 / 一致性哈希 → 见 [Distributed 模块](../Distributed/README.md)。
```

### 面试速通路径（30 分钟刷一遍）

每篇看 **答题模板** 一节就够：

**基础**
- [JDK - 答题模板](./jdk.md#九答题模板60-秒话术)
- [基本类型 - 答题模板](./基本数据类型与自动装箱.md#八答题模板60-秒话术)
- [Object - 答题模板](./Object类.md#十答题模板60-秒话术)
- [String - 答题模板](./String原理.md#十答题模板60-秒话术)
- [抽象类和接口 - 答题模板](./抽象类和接口.md#九答题模板60-秒话术)

**集合**
- [集合总览 - 答题模板](./集合类.md#八答题模板60-秒话术)
- [List - 答题模板](./List.md#九答题模板60-秒话术)
- [HashMap - 答题模板](./HashMap.md#十一答题模板90-秒话术)
- [Set - 答题模板](./Set.md#八答题模板60-秒话术)
- [Queue - 答题模板](./Queue.md#八答题模板60-秒话术)
- [Comparator - 答题模板](./Comparator.md#八答题模板60-秒话术)

**函数式（Java 8+）**
- [Lambda - 答题模板](./Lambda与函数式接口.md#九答题模板60-秒话术)
- [Stream - 答题模板](./Stream%20API.md#九答题模板90-秒话术)
- [Optional - 答题模板](./Optional.md#九答题模板60-秒话术)

**进阶**
- [异常体系 - 答题模板](./异常体系.md#九答题模板60-秒话术)
- [泛型 - 答题模板](./泛型.md#九答题模板60-秒话术)
- [反射与动态代理 - 答题模板](./反射与动态代理.md#九答题模板60-秒话术)

---

## 四、关键速记表

### 4.1 集合速查

| 维度 | List | Set | Map | Queue |
| --- | --- | --- | --- | --- |
| 重复 | ✅ | ❌ | key ❌ | ✅ |
| 有序 | ✅ 插入序 | 看实现 | 看实现 | FIFO/优先级 |
| 经典实现 | ArrayList | HashSet | HashMap | ArrayDeque |
| 排序实现 | — | TreeSet | TreeMap | PriorityQueue |
| 保插入序 | ArrayList | LinkedHashSet | LinkedHashMap | LinkedList |
| 线程安全 | CopyOnWriteArrayList | CopyOnWriteArraySet | ConcurrentHashMap | ConcurrentLinkedQueue |

### 4.2 HashMap 关键参数

| 常量 | 值 | 含义 |
| --- | --- | --- |
| DEFAULT_INITIAL_CAPACITY | 16 | 默认初始容量 |
| MAXIMUM_CAPACITY | 2^30 | 最大容量 |
| DEFAULT_LOAD_FACTOR | 0.75 | 负载因子 |
| TREEIFY_THRESHOLD | 8 | 链表→红黑树阈值 |
| UNTREEIFY_THRESHOLD | 6 | 红黑树→链表阈值 |
| MIN_TREEIFY_CAPACITY | 64 | 树化的最小数组长度 |

### 4.3 equals / hashCode 契约（必背）

```
1. 自反性：a.equals(a) == true
2. 对称性：a.equals(b) == b.equals(a)
3. 传递性：a.equals(b) && b.equals(c) → a.equals(c)
4. 一致性：多次调用结果一致（不变状态）
5. 与 hashCode 的契约：
   - a.equals(b) == true → a.hashCode() == b.hashCode()
   - 反之不成立（哈希冲突）
6. 与 null：a.equals(null) == false
```

### 4.4 LTS 版本对比

| 版本 | 发布时间 | 默认 GC | 关键特性 |
| --- | --- | --- | --- |
| **JDK 8** | 2014 | Parallel | Lambda、Stream、接口 default 方法、Optional |
| **JDK 11** | 2018 | G1 | var、HttpClient、ZGC（实验）、移除 Java EE |
| **JDK 17** | 2021 | G1 | sealed class、record、文本块、Pattern Matching |
| **JDK 21** | 2023 | G1 | 虚拟线程（正式）、Pattern for switch、序列集合 |

### 4.5 PECS 口诀

```
Producer Extends, Consumer Super
生产者用 extends（只读出，类型是 T 或子类）
消费者用 super  （只写入，类型是 T 或父类）

写入：List<? extends Number>  ❌ 不能 add
读出：List<? super Integer>   ✅ 但读出的是 Object
```

### 4.6 Java 8+ 函数式速查

| 接口 | 方法 | 含义 | 数值版 |
| --- | --- | --- | --- |
| `Function<T,R>` | `R apply(T)` | 一进一出 | IntFunction / ToIntFunction |
| `Consumer<T>` | `void accept(T)` | 消费 | IntConsumer |
| `Supplier<T>` | `T get()` | 生产 | IntSupplier |
| `Predicate<T>` | `boolean test(T)` | 判断 | IntPredicate |
| `BiFunction<T,U,R>` | `R apply(T, U)` | 二进一出 | — |
| `UnaryOperator<T>` | `T apply(T)` | 一进一出（同型）| IntUnaryOperator |

方法引用 4 种：`Integer::parseInt`（静态）、`obj::method`（绑定实例）、`String::length`（未绑定，参数当 receiver）、`ArrayList::new`（构造器）。

### 4.7 Stream 关键 API

```
中间操作（惰性）：filter / map / flatMap / sorted / distinct / limit / skip / peek
终端操作（触发）：collect / reduce / forEach / count / findFirst / anyMatch / sum

数值流避免装箱：mapToInt / mapToLong / mapToDouble → IntStream / LongStream / DoubleStream

Collectors：toList / toMap / groupingBy / partitioningBy / counting / summingInt / averagingInt / joining
```

### 4.8 Optional 正确姿势

```
✅ 推荐                          ❌ 反模式
opt.map(...).orElse(...)        if (opt.isPresent()) { opt.get()... }
opt.ifPresent(...)              if (opt.isPresent()) { ... }
ofNullable(maybeNull)           of(maybeNull)  ← null 抛 NPE
orElseGet(() -> compute())      orElse(compute())  ← 无论如何都跑
仅做返回值                      做字段 / 参数 / 集合元素
```

### 4.9 反射 vs JDK Proxy vs CGLIB

| 维度 | 反射 | JDK Proxy | CGLIB |
| --- | --- | --- | --- |
| 限制 | 无 | 必须基于接口 | 不能代理 final 类/方法 |
| 实现 | Method.invoke | InvocationHandler + Proxy | 字节码生成子类 |
| 性能 | 慢（无内联） | 比反射快（生成类） | 接近原生（FastClass） |
| Spring AOP | — | 有接口默认走 | 无接口 / 强制配置 |

---

## 五、生产踩坑 TOP 10

| 坑 | 文档 |
| --- | --- |
| HashMap 多线程下数据丢失 / 死循环（JDK 7） | [HashMap - 死循环](./HashMap.md#101-jdk-7-头插死循环) |
| 重写 equals 没重写 hashCode → HashMap 取不到 | [Object 类](./Object类.md#62-必须配套重写的根本原因) |
| Integer 缓存边界（-128~127） | [基本类型](./基本数据类型与自动装箱.md#三integer-缓存经典面试题) |
| BigDecimal 用 double 构造 / equals 比 scale | [基本类型](./基本数据类型与自动装箱.md#43-bigdecimal--钱必须用) |
| `Optional.orElse(compute())` 永远求值 | [Optional](./Optional.md#三orelse-vs-orelseget必考) |
| `Collectors.toMap` 重复 key 抛异常 | [Stream](./Stream%20API.md#71-collectorstomap-重复-key-抛异常) |
| `parallelStream` 用错（IO 任务、共享 commonPool） | [Stream](./Stream%20API.md#六并行流parallelstream) |
| String + 拼接在循环里性能爆炸 | [String 原理](./String原理.md#62-循环里用--拼接) |
| ArrayList.subList() 不是普通 List | [List](./List.md#82-sublist-不是普通-list) |
| Arrays.asList 返回的不是 ArrayList | [List](./List.md#83-arraysaslist-坑) |
| ConcurrentModificationException（fail-fast） | [集合总览](./集合类.md#六fail-fast-vs-fail-safe) |
| Comparator 用减法溢出 | [Comparator](./Comparator.md#62-减法写法的整型溢出坑) |
| 异常被 catch 后吞掉 | [异常体系](./异常体系.md#71-异常被吞掉) |
| 反射调用 setAccessible(true) 性能下降 | [反射与动态代理](./反射与动态代理.md#33-反射性能为什么慢) |

---

## 六、面试连环追问的话题

按出现频率列出：

1. **HashMap 全家桶**：数据结构 → 扰动 → 树化阈值 → 扩容 → 死循环 → 线程安全
2. **equals/hashCode**：== vs equals → 重写规则 → HashMap 用法 → Integer 缓存
3. **String 三件套**：不可变设计 → 常量池 → intern → StringBuilder
4. **集合分类**：体系图 → 线程安全实现 → fail-fast → CopyOnWrite
5. **抽象/接口**：何时用 → Java 8 default → 菱形继承
6. **泛型**：类型擦除 → PECS → 不能 new T[]
7. **反射 + 代理**：JDK Proxy vs CGLIB → Spring AOP → 性能
8. **异常**：Throwable → Checked vs Unchecked → try-finally-return → try-with-resources

每条主线对应至少一篇深度文档，按上方"高频题映射"快速跳转。

> 分布式相关高频题（限流、一致性哈希、CAP、事务、锁、ID、注册中心）→ 见 [Distributed 模块](../Distributed/README.md)。

---

## 七、相关模块

- [JVM 面试模块](../JVM/README.md) — 内存模型、对象布局、GC，Java 运行时基础
- [Concurrency 并发](../Concurrency/README.md) — JMM、ConcurrentHashMap、线程池、AQS
- [MySQL 面试模块](../MySQL/README.md) — B+Tree、索引、事务
- [Redis 面试模块](../Redis/README.md) — 缓存、分布式锁、布隆过滤器
- [Spring](../Spring/README.md) — Bean 生命周期、AOP、自动装配
- [Distributed 分布式](../Distributed/README.md) — 幂等、分布式事务
