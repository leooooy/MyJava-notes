# Optional

> Optional 是 JDK 8 给 Java 的"NPE 解药"——但**90% 的 Java 开发用错了它**。
>
> 面试要回答：
> ① Optional 解决什么问题、**为什么不能完全替代 null**
> ② **正确使用方式**：map/orElse/ifPresent，不要 isPresent + get
> ③ **错误用法**：当字段、当方法参数、当集合元素、序列化
> ④ Optional 的**性能开销**——不是零成本

---

## 一、Optional 解决什么问题

### 1.1 NPE 是 Java 最常见的 bug

Tony Hoare（Null 引用的发明人）2009 年公开道歉："**The Billion Dollar Mistake**"——估计 null 指针错误在工业界造成数十亿美元损失。

Java 的传统应对：**到处判 null**。

```java
public String getCity(User user) {
    if (user == null) return null;
    Address addr = user.getAddress();
    if (addr == null) return null;
    City city = addr.getCity();
    if (city == null) return null;
    return city.getName();
}
```

→ 业务被淹没在判空里。

### 1.2 Optional 的设计

Optional 是一个**容器**——要么有值，要么 empty：

```java
public final class Optional<T> {
    private final T value;
    private static final Optional<?> EMPTY = new Optional<>();
}
```

**核心思想**：把"可能没值"显式编码到类型里——调用者**必须**处理"没有"的情况。

### 1.3 用 Optional 重写

```java
public String getCity(User user) {
    return Optional.ofNullable(user)
        .map(User::getAddress)
        .map(Address::getCity)
        .map(City::getName)
        .orElse("UNKNOWN");
}
```

→ 链式 + 自动判空，**任何一环 null 都安全**。

---

## 二、Optional 创建与基础 API

### 2.1 三个工厂方法

```java
Optional.of(value)              // value 必须非 null，否则 NPE
Optional.ofNullable(value)      // value 可能 null
Optional.empty()                // 空 Optional
```

| 方法 | value 是 null 时 |
| --- | --- |
| `of` | **抛 NPE** |
| `ofNullable` | 返回 empty Optional |
| `empty` | 返回 empty Optional |

→ **生产规范**：不确定的用 `ofNullable`；明确非 null（业务保证）用 `of`——能在 bug 早期暴露。

### 2.2 检查 + 取值

```java
Optional<String> opt = ...;

opt.isPresent()           // 是否有值（不推荐直接用，配 if 是反模式）
opt.isEmpty()             // JDK 11+
opt.get()                 // 取值（empty 时抛 NoSuchElementException）⚠ 不推荐
opt.orElse("default")     // 空时返回默认
opt.orElseGet(() -> compute())   // 空时调用 supplier（懒）
opt.orElseThrow(() -> new NotFoundException())   // 空时抛
opt.orElseThrow()         // JDK 10+ 空时抛 NoSuchElementException
```

### 2.3 函数式 API（推荐用法）

```java
opt.ifPresent(v -> System.out.println(v));         // 有值就执行
opt.ifPresentOrElse(                               // JDK 9+
    v -> System.out.println(v),
    () -> System.out.println("empty")
);

opt.map(s -> s.length())                           // 转换（返回 Optional<Integer>）
opt.flatMap(s -> Optional.of(s.length()))          // 转换（避免嵌套 Optional<Optional<X>>）
opt.filter(s -> s.length() > 5)                    // 过滤（不满足返回 empty）

opt.or(() -> Optional.of("default"))               // JDK 9+ 空时返回备用 Optional
opt.stream()                                        // JDK 9+ 转 Stream（0 或 1 个元素）
```

---

## 三、orElse vs orElseGet（必考）

```java
opt.orElse(expensiveCompute());        // ⚠ 不管有没有值，expensiveCompute 都执行！
opt.orElseGet(() -> expensiveCompute());   // ✅ 仅 empty 时才执行
```

**根因**：`orElse(T t)` 的参数是值，**Java 的方法调用是 eager evaluation**——参数表达式必然求值。`orElseGet(Supplier<T>)` 的参数是函数，empty 时才调用。

### 3.1 实测影响

```java
Optional<User> u = userService.find(id);
return u.orElse(loadFromDB());           // ⚠ 哪怕 u 有值，loadFromDB() 也跑
return u.orElseGet(() -> loadFromDB());  // ✅
```

→ 默认值是**常量**（字符串、0、空集合）用 orElse；**动态计算**（DB 查询、新对象）用 orElseGet。

---

## 四、map vs flatMap

```java
// map：函数返回普通值
Optional<String> name = opt.map(User::getName);   // Optional<String>

// flatMap：函数本身返回 Optional —— 避免嵌套
Optional<Address> addr = opt.flatMap(User::findAddress);   // findAddress 返回 Optional<Address>
// 用 map 会得到 Optional<Optional<Address>>
```

**核心**：返回值已经是 Optional 时用 flatMap，避免 `Optional<Optional<T>>`。

---

## 五、Optional 不要做什么（生产规范）

### 5.1 不要做字段

```java
class User {
    private Optional<String> nickname;     // ⚠ 反模式
}
```

**为什么不行**：

- Optional 不是 Serializable —— 序列化失败
- Jackson 默认不识别 Optional —— JSON 转换出问题
- 内存占用比 null 多（Optional 对象 + value 字段 = 多一层间接）
- 字段层面 Optional 没意义——直接用 null 然后 getter 返回 Optional 更好

**正确**：

```java
class User {
    private String nickname;     // 允许 null
    
    public Optional<String> getNickname() {
        return Optional.ofNullable(nickname);   // ✅ getter 包 Optional
    }
}
```

### 5.2 不要做方法参数

```java
public void update(Optional<String> name) { ... }    // ⚠
```

**调用者**：

```java
update(Optional.empty());           // 啰嗦
update(Optional.of("Alice"));       // 啰嗦
update(null);                       // 还可以传 null（Optional 自身可以为 null）！
```

**正确**：方法重载：

```java
public void update() { ... }
public void update(String name) { ... }
```

### 5.3 不要做集合元素

```java
List<Optional<User>> list;          // ⚠ 反模式
Map<String, Optional<User>> map;    // ⚠
```

**为什么不行**：

- 集合本身已经能表达"没有"——空集合
- Map 用 `containsKey` 区分"key 不存在"和"value 是 null"
- 多一层 Optional 是冗余

**正确**：

```java
List<User> list;                    // 没用户就空 list
Map<String, User> map;              // 没 key 就 containsKey 判断
```

### 5.4 不要 isPresent + get

```java
// ❌ 反模式（和判 null 没区别）
if (opt.isPresent()) {
    return opt.get();
}
return "default";

// ✅
return opt.orElse("default");

// ❌
if (opt.isPresent()) {
    return opt.get().toUpperCase();
}
return null;

// ✅
return opt.map(String::toUpperCase).orElse(null);
```

**根因**：`isPresent + get` 是把 Optional 退化成 null 检查——没用上 Optional 的设计意图（强制处理 empty）。

**SonarQube 等代码扫描会专门标记这种反模式**。

### 5.5 不要返回 null Optional

```java
public Optional<User> find(Long id) {
    return null;     // ⚠ 永远不要这么干
}
```

**Optional 的语义**：null 表示"未初始化"，empty 表示"无值"。**返回 Optional 的方法**永远应该返回 `Optional.empty()` 或有值的 Optional，**不返回 null**。

---

## 六、Optional 性能

### 6.1 不是零成本

```java
// 直接判 null
if (user != null) return user.getName();
return null;

// Optional
return Optional.ofNullable(user).map(User::getName).orElse(null);
```

**Optional 的开销**：

- **创建对象**：每次 `ofNullable` new 一个 Optional（除了 EMPTY 单例）
- **方法调用链**：map/orElse 多层间接，**JIT 可以内联**但不一定每次都内联
- **类型装箱**：`Optional<Integer>` 每次包装

实测：简单场景 Optional 比直接判 null **慢 1.5 ~ 3 倍**。

### 6.2 性能敏感场景

```java
// 高频路径：直接判 null
if (user != null && user.getAddress() != null) {
    ...
}

// 业务层：用 Optional 增强可读性
return Optional.ofNullable(user)
    .map(User::getAddress)
    .map(Address::getCity)
    .orElse(City.UNKNOWN);
```

→ **核心循环、性能敏感函数用 null**；**业务函数用 Optional**——更易读、防 bug。

### 6.3 数值版本

```java
OptionalInt    // 避免装箱
OptionalLong
OptionalDouble

IntStream.of(1, 2, 3).max();     // 返回 OptionalInt
```

---

## 七、生产踩坑

### 7.1 Optional 字段导致 Jackson 失败

```java
class User {
    private Optional<String> nickname;
}

objectMapper.writeValueAsString(new User());    // 默认序列化为 {"nickname": {"empty": true}} 之类
```

**修复**：装 Jackson 的 jdk8-module：

```xml
<dependency>
    <groupId>com.fasterxml.jackson.datatype</groupId>
    <artifactId>jackson-datatype-jdk8</artifactId>
</dependency>
```

```java
objectMapper.registerModule(new Jdk8Module());
```

→ 但**根本修复**是不要 Optional 做字段。

### 7.2 orElse 误用

```java
// 高频接口的 fallback
return Optional.ofNullable(cache.get(key))
    .orElse(loadFromDB(key));    // ⚠ 即使 cache 命中，loadFromDB 也跑

// 修复
return Optional.ofNullable(cache.get(key))
    .orElseGet(() -> loadFromDB(key));    // ✅
```

线上故障的常见根因——loadFromDB 是慢操作，cache 命中率 99% 也照跑，DB 被打爆。

### 7.3 Optional.get() 抛异常

```java
Optional<User> u = service.find(id);
String name = u.get().getName();     // ⚠ empty 时抛 NoSuchElementException
```

**修复**：永远先判，或用 map/orElse：

```java
String name = u.map(User::getName).orElse("UNKNOWN");
```

### 7.4 流式编程后忘了取值

```java
list.stream().findFirst().ifPresent(System.out::println);   // ✅
String name = list.stream().findFirst();    // ⚠ 类型不对，编译错
String name = list.stream().findFirst().get();   // ⚠ 空 list 抛
```

**修复**：

```java
String name = list.stream().findFirst().orElse("default");
```

### 7.5 用 Optional 替代异常

```java
public Optional<User> find(Long id) {
    if (id == null) return Optional.empty();    // ⚠ 业务逻辑错误
    return ...;
}
```

→ 业务参数错应该抛 `IllegalArgumentException`，不是返回 empty。**Optional 表达"没值"，不是"出错"**。

---

## 八、面试高频追问

### Q1：Optional 解决什么问题？

把"可能没值"显式编码到类型——强制调用者处理 empty 情况，**减少 NPE**。比纯 null 判断**可读性好、链式调用方便**。

### Q2：of / ofNullable / empty 区别？

`of(value)`：value 为 null 抛 NPE（业务保证非 null 时用，能早暴露 bug）；`ofNullable(value)`：value null 返回 empty；`empty()`：直接返回 empty。

### Q3：orElse 和 orElseGet 区别？

`orElse(T t)`：参数是值，**永远求值**；`orElseGet(Supplier)`：参数是函数，**仅 empty 时求值**。**默认值是常量用 orElse，动态计算用 orElseGet**——否则性能浪费。

### Q4：为什么不能用 isPresent + get？

把 Optional 退化成 null 检查，没用上 Optional 的设计意图。**用 map / orElse / ifPresent 链式**——更安全，编译期强制处理 empty。

### Q5：Optional 能做字段吗？

不能。Optional 不实现 Serializable、Jackson 默认不识别、内存浪费、字段层面 null 已够用。**字段保留 null + getter 返回 Optional** 才是正确模式。

### Q6：Optional 能做方法参数吗？

不能。调用者要包成 Optional 啰嗦，且 Optional 自身可能是 null。**用方法重载**：`update()` + `update(String name)`。

### Q7：Optional 性能怎么样？

不是零成本——每次创建 Optional 对象、链式调用多层间接。简单 null 判断比 Optional 快 1.5~3 倍。**核心循环用 null，业务层用 Optional**。

### Q8：map 和 flatMap 区别？

map：函数返回普通值；flatMap：函数返回 Optional。**避免 `Optional<Optional<T>>` 嵌套用 flatMap**。

### Q9：Optional 能为 null 吗？

技术上能（变量本身可以是 null）——但**返回 Optional 的方法永远不该返回 null**，要么返回 empty，要么返回有值的。这是 Effective Java 第 55 条。

### Q10：Optional 在 Stream 里怎么用？

- `findFirst() / findAny() / max() / min() / reduce()` 都返回 Optional
- 配 `ifPresent / orElse` 取值
- JDK 9+ 可 `opt.stream()` 转 Stream（empty → 空 Stream）便于 flatMap

---

## 九、答题模板（60 秒话术）

> Optional 是 JDK 8 加的**容器**——表达"可能没值"，强制调用者处理 empty，减少 NPE。
>
> 创建：**`of` 严格非 null（早暴露 bug）、`ofNullable` 容忍 null、`empty` 空 Optional**。**返回 Optional 的方法永远不返回 null**——返 empty 或有值。
>
> 取值正确姿势：**用 map/orElse/ifPresent 链式**，**不要 isPresent + get**——后者把 Optional 退化成 null 检查，没用上设计意图。
>
> **orElse vs orElseGet** 必考：orElse 参数永远求值，orElseGet 仅 empty 时求值。**默认值是常量用 orElse，动态计算用 orElseGet**——否则 fallback 永远跑导致性能 / DB 被打爆。
>
> **生产规范**：Optional **不做字段**（Serializable / Jackson 不友好）、**不做参数**（调用啰嗦 + Optional 可为 null）、**不做集合元素**（冗余）。**只用作返回值**——getter 包 Optional 是经典模式。
>
> 性能：Optional **不是零成本**，简单 null 判断比 Optional 快 1.5~3x。**性能敏感路径用 null，业务层用 Optional** 增强可读性。

---

## 十、相关文档

- [Lambda 与函数式接口](./Lambda与函数式接口.md) — Optional 的方法都是函数式
- [Stream API](./Stream%20API.md) — findFirst / max 返回 Optional
- [基本数据类型与自动装箱](./基本数据类型与自动装箱.md) — OptionalInt 避免装箱
- [异常体系](./异常体系.md) — orElseThrow 抛业务异常
- [Object 类](./Object类.md) — equals / hashCode 在 Optional 里也实现
