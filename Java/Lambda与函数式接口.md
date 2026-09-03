# Lambda 与函数式接口

> Lambda 是 JDK 8 的 **范式级** 改动——把 Java 从纯面向对象推到了"OO + 函数式"。面试要回答：
> ① Lambda 是什么、**为什么用 invokedynamic 实现**而不是匿名内部类
> ② **函数式接口** + 4 大常用接口（Function/Consumer/Supplier/Predicate）
> ③ **方法引用** 4 种形式
> ④ 闭包变量必须 **effectively final** 的真正原因
> ⑤ Lambda vs 匿名内部类的差异

---

## 一、为什么需要 Lambda

### 1.1 没有 Lambda 的痛苦

```java
// 排序：写一个匿名内部类
Collections.sort(list, new Comparator<User>() {
    @Override
    public int compare(User a, User b) {
        return Integer.compare(a.getAge(), b.getAge());
    }
});

// 启动线程
new Thread(new Runnable() {
    @Override
    public void run() {
        System.out.println("hello");
    }
}).start();
```

样板代码淹没了**真正的业务逻辑**。

### 1.2 有 Lambda

```java
list.sort((a, b) -> Integer.compare(a.getAge(), b.getAge()));
list.sort(Comparator.comparingInt(User::getAge));    // 更短

new Thread(() -> System.out.println("hello")).start();
```

### 1.3 Lambda 不只是语法糖

如果只是语法糖（编译成匿名内部类），Java 8 之前就能做到——**为什么等到 Java 8**？

**根本原因**：JVM 加了 `invokedynamic`（JDK 7）和 `LambdaMetafactory`（JDK 8），让 Lambda 在**运行时**生成实现，而不是编译期。性能比匿名内部类好、生成的 class 更少。

---

## 二、Lambda 表达式语法

```java
() -> System.out.println("hi")             // 无参
x -> x * 2                                  // 单参（可省括号）
(x, y) -> x + y                             // 多参
(int x, int y) -> x + y                     // 显式类型
(x, y) -> { System.out.println(x); return x + y; }    // 多语句
```

→ 编译器靠**目标类型推断**确定 Lambda 的类型——**赋给什么接口就是什么类型**。

```java
Runnable r = () -> System.out.println("hi");        // Runnable
Comparator<Integer> c = (a, b) -> a - b;            // Comparator
```

**同一个 Lambda 可以是不同类型** —— 取决于赋给谁。

---

## 三、函数式接口

### 3.1 定义

**函数式接口**：**有且仅有一个** **抽象方法**的接口。

```java
@FunctionalInterface
public interface Runnable {
    void run();
}

@FunctionalInterface
public interface Comparator<T> {
    int compare(T a, T b);
    
    // default / static 方法不影响"函数式"——它们不是抽象方法
    default Comparator<T> reversed() { ... }
}
```

`@FunctionalInterface`：编译期检查，**不是必需**——但加上更清晰，且如果将来加了第二个抽象方法编译器会报错。

### 3.2 4 大常用函数式接口（必背）

| 接口 | 方法签名 | 含义 | 用例 |
| --- | --- | --- | --- |
| `Function<T,R>` | `R apply(T t)` | 一进一出 | `s -> s.length()` |
| `Consumer<T>` | `void accept(T t)` | 消费（不返回） | `System.out::println` |
| `Supplier<T>` | `T get()` | 生产（无参产出） | `() -> new ArrayList<>()` |
| `Predicate<T>` | `boolean test(T t)` | 判断 | `s -> s.isEmpty()` |
| `BiFunction<T,U,R>` | `R apply(T t, U u)` | 二进一出 | `(a, b) -> a + b` |
| `UnaryOperator<T>` | `T apply(T t)` | 一进一出（同类型）| `s -> s.toUpperCase()` |
| `BinaryOperator<T>` | `T apply(T a, T b)` | 二进一出（同类型）| `(a, b) -> a + b` |

**避免装箱的版本**（数值用）：

```java
IntFunction<R>          // int → R
ToIntFunction<T>        // T → int
IntPredicate            // int → boolean
IntConsumer             // int → void
IntSupplier             // void → int
IntUnaryOperator        // int → int
IntBinaryOperator       // (int, int) → int
```

→ 同样的 LongFunction / DoubleFunction 等。**性能敏感场景必用基本类型版本**。

### 3.3 常用组合方法

```java
Function<Integer, Integer> times2 = x -> x * 2;
Function<Integer, Integer> plus10 = x -> x + 10;

times2.andThen(plus10).apply(3);    // (3 * 2) + 10 = 16
times2.compose(plus10).apply(3);    // (3 + 10) * 2 = 26

Predicate<String> notEmpty = s -> !s.isEmpty();
Predicate<String> longEnough = s -> s.length() > 5;
notEmpty.and(longEnough).test("hello");      // false
notEmpty.or(s -> s.length() == 0).test("");   // true
notEmpty.negate().test("");                   // true
Predicate.not(notEmpty).test("");             // true (JDK 11+)
```

---

## 四、方法引用 —— Lambda 的"快捷写法"

### 4.1 4 种形式

```java
// 1. 静态方法
Integer::parseInt              // s -> Integer.parseInt(s)

// 2. 实例方法（绑定特定对象）
System.out::println            // x -> System.out.println(x)
log::error                     // msg -> log.error(msg)

// 3. 实例方法（未绑定，第一个参数当 receiver）
String::length                 // s -> s.length()
String::toUpperCase            // s -> s.toUpperCase()

// 4. 构造器
ArrayList::new                 // () -> new ArrayList<>()
String::new                    // (chars) -> new String(chars)
User::new                      // (name) -> new User(name) —— 推断对应构造器
```

### 4.2 实例方法两种区别（必背）

```java
// 形式 2：绑定 —— receiver 在 :: 左边，已确定
String prefix = "INFO: ";
Function<String, String> add = prefix::concat;
add.apply("hello");        // prefix.concat("hello") = "INFO: hello"

// 形式 3：未绑定 —— 第一个参数当 receiver
Function<String, Integer> len = String::length;
len.apply("hello");        // "hello".length() = 5
```

**面试考法**：`String::length` 是哪种？**形式 3**——`String` 是类不是实例，参数当 receiver。

---

## 五、闭包变量 effectively final

### 5.1 规则

```java
int count = 0;
Runnable r = () -> count++;     // ⚠ 编译报错
Runnable r2 = () -> System.out.println(count);    // ✅ 只读 OK

count = 5;                       // ⚠ 即使只读，外部修改也违反 effectively final
```

Lambda **可以引用**外部局部变量，但**变量必须 effectively final**——初始化后不再被修改（`final` 写不写都行，关键是 **逻辑上不变**）。

### 5.2 为什么这个限制

**根本原因**：Java 的局部变量在**栈**上，Lambda 可能在**另一个线程**或**晚于声明栈帧**执行——栈帧弹出后变量就没了。

```java
public Runnable createTask() {
    int x = 100;
    return () -> System.out.println(x);    // 返回时 createTask 栈帧已弹
}
```

JVM 的解决方法：**把 x 拷贝到 Lambda 对象的字段里**（值捕获）。但如果 x 可变，外面改 → Lambda 里看不到 → 行为不一致。**Java 的妥协：禁止变量可变。**

### 5.3 引用类型可以"改内容"

```java
List<Integer> list = new ArrayList<>();
Runnable r = () -> list.add(1);    // ✅ list 引用没变
list = null;                        // ⚠ 这就报错——改了引用
```

→ 只是**引用**不能变；引用指向的对象**可以改**。

### 5.4 绕过限制：用容器

```java
int[] count = {0};                   // 数组（可变）
Runnable r = () -> count[0]++;       // ✅ 改数组内容

AtomicInteger counter = new AtomicInteger();
Runnable r2 = () -> counter.incrementAndGet();   // ✅
```

→ 实际**不推荐**——这违背了 effectively final 的设计意图。要可变状态用 `AtomicInteger` / `AtomicReference`，并且明确这是并发安全的需求。

---

## 六、Lambda vs 匿名内部类

### 6.1 字节码差异

**匿名内部类**：

```java
Runnable r = new Runnable() {
    public void run() { System.out.println("hi"); }
};
```

编译后生成 **`Outer$1.class`**（一个独立 class 文件），运行时 `new Outer$1()`。

**Lambda**：

```java
Runnable r = () -> System.out.println("hi");
```

编译后**没有额外 class 文件**，只有一条 `invokedynamic` 字节码：

```
invokedynamic #15:run:()Ljava/lang/Runnable;
```

**第一次执行时**，JVM 调用 `LambdaMetafactory.metafactory` **运行时生成**实现类（在内存里），**复用**给后续调用。

**收益**：

- **classfile 数减少**——大型项目启动快
- **空 Lambda 不分配对象**：`Runnable r = () -> {}` 编译后 `r` 引用同一个 instance
- 性能比内部类略好

### 6.2 this 的含义不同

```java
public class Outer {
    private String name = "outer";

    public void test() {
        // 匿名内部类：this 是内部类自己
        new Runnable() {
            public void run() {
                System.out.println(this);             // Outer$1
                System.out.println(Outer.this.name);   // outer
            }
        }.run();

        // Lambda：this 是外部类
        Runnable r = () -> {
            System.out.println(this);                  // Outer
            System.out.println(this.name);             // outer
        };
        r.run();
    }
}
```

→ Lambda **没有自己的 this**，借用外部类的 this。**比匿名内部类直观**。

### 6.3 完整对比表

| 维度 | Lambda | 匿名内部类 |
| --- | --- | --- |
| 字节码 | invokedynamic | 独立 class 文件 |
| this 含义 | 外部类 this | 内部类自己 |
| 有 this 字段 | 否 | 是（Outer.this 引用外部）|
| 能否实现多方法 | ❌ 单方法（函数式接口） | ✅ 可以多方法 |
| 能否定义字段 | ❌ | ✅ |
| 启动性能 | 好（运行时生成） | 一般 |
| 内存占用 | 小（无 this 字段） | 大 |

→ **能用 Lambda 就用 Lambda**——更简洁、更快。除非要实现多方法接口或定义字段。

---

## 七、生产踩坑

### 7.1 Lambda 里抛 Checked 异常

```java
list.stream().map(s -> Files.readString(Path.of(s)));   // ⚠ 编译报错
```

`Function.apply` 不抛 Checked，Lambda 里也不能抛。**修复**：

```java
// 1. 包成 RuntimeException
list.stream().map(s -> {
    try { return Files.readString(Path.of(s)); }
    catch (IOException e) { throw new UncheckedIOException(e); }
});

// 2. 工具类（vavr）
Stream.of(...).map(CheckedFunction1.<String, String>of(s -> Files.readString(...)).unchecked());
```

### 7.2 闭包变量被外部改

```java
List<Runnable> tasks = new ArrayList<>();
for (int i = 0; i < 5; i++) {
    int finalI = i;       // 必须新变量，否则 i 可变
    tasks.add(() -> System.out.println(finalI));
}
```

JDK 8+ for-each 的循环变量本身是 effectively final（每次新建），但**经典 for 循环的 i 不是**——所以要用 finalI 拷贝。

### 7.3 Lambda 引发 NPE

```java
Function<String, Integer> f = String::length;
f.apply(null);                // ⚠ NPE on null.length()

// 修复
Function<String, Integer> safe = s -> s == null ? 0 : s.length();
```

**面试小考点**：方法引用 `String::length` 是**未绑定**形式，参数当 receiver——参数 null 直接 NPE。

### 7.4 空 Lambda 看似一样实际不同

```java
Runnable r1 = () -> {};
Runnable r2 = () -> {};
System.out.println(r1 == r2);    // 看 JVM 实现，**通常是 true**（缓存复用）

Function<Integer, Integer> f1 = x -> x;
Function<Integer, Integer> f2 = x -> x;
System.out.println(f1 == f2);    // 通常 true
```

→ 不要依赖 Lambda 的 `==` 行为——**用 `equals` 不会按内容比**（默认 Object.equals 比地址）。

### 7.5 Lambda 性能：第一次调用慢

第一次执行 invokedynamic 时，JVM 要调 `LambdaMetafactory` 生成实现类——开销约 **几百微秒**。后续调用接近原生（JIT 内联）。

→ 启动性能敏感的场景注意：**冷启动**期间大量 Lambda 第一次执行，可能暂时慢。

### 7.6 在 Lambda 里持有大对象引发内存泄漏

```java
public Function<String, String> create() {
    BigObject big = new BigObject();
    return s -> s + big.getName();    // ⚠ Lambda 持有 big 引用
}
```

返回的 Function 长期持有，big 永远 GC 不掉。**生产规范**：Lambda 只闭包**真正需要的**变量。

---

## 八、面试高频追问

### Q1：Lambda 和匿名内部类区别？

字节码不同：Lambda 用 invokedynamic + LambdaMetafactory **运行时生成**，匿名内部类编译时生成独立 class；this 含义不同（Lambda 是外部类，匿名内部类是自己）；Lambda 不能定义字段、只能实现单方法（函数式接口），匿名内部类没限制。

### Q2：Lambda 为什么用 invokedynamic？

减少 classfile 数量、运行时延迟绑定（编译期不固定实现类）、JVM 可以缓存复用（空 Lambda 同实例）、JIT 友好。Java 7 引入 invokedynamic 本就是为动态语言的，Java 8 拿来给 Lambda 用。

### Q3：函数式接口是什么？@FunctionalInterface 必须加吗？

只有 1 个抽象方法的接口（default/static 不算）。@FunctionalInterface 不是必需，但加上**编译期检查**——如果加了第二个抽象方法编译报错，更安全。

### Q4：4 大函数式接口？

- `Function<T, R>`：apply，一进一出
- `Consumer<T>`：accept，消费
- `Supplier<T>`：get，生产
- `Predicate<T>`：test，判断

数值版本：IntFunction、IntPredicate、IntConsumer 等——**避免装箱**。

### Q5：方法引用 4 种形式？

- 静态：`Integer::parseInt`
- 绑定实例：`System.out::println`、`obj::method`
- 未绑定实例：`String::length`（第一个参数当 receiver）
- 构造器：`ArrayList::new`

### Q6：闭包变量为什么必须 effectively final？

JVM 把外部局部变量**值捕获**到 Lambda 对象字段——如果允许变量改变，Lambda 内外不一致。深层原因：Lambda 可能晚于声明栈帧执行（异步、返回到外部）——栈上的变量已经没了。

### Q7：Lambda 里 this 是谁？

**外部类的 this**——Lambda 没有自己的 this。和匿名内部类不同（匿名内部类 this 是自己）。

### Q8：Lambda 能抛 Checked 异常吗？

不能——函数式接口（如 Function.apply）签名没有 throws。要抛得自己包成 RuntimeException 或用 vavr 等库。

### Q9：Lambda 性能怎么样？

**首次调用**慢（LambdaMetafactory 生成实现类，几百微秒）；后续接近原生，JIT 可内联。**比匿名内部类略好**（无 this 字段、空 Lambda 复用实例）。

### Q10：Stream 操作里 Lambda 装箱怎么避免？

用 `IntStream` / `LongStream` / `DoubleStream` 和 `mapToInt` / `mapToLong` / `mapToDouble`：

```java
list.stream().mapToInt(String::length).sum();    // 不装箱
list.stream().map(String::length).reduce(0, Integer::sum);   // 全程装箱
```

---

## 九、答题模板（60 秒话术）

> Lambda 是 JDK 8 加的**函数式编程支持**，本质是**对函数式接口（单抽象方法接口）的实例化**。底层用 **invokedynamic + LambdaMetafactory**——运行时生成实现类，**比匿名内部类性能好、不生成额外 class 文件**。
>
> 4 大函数式接口：`Function<T,R>`（apply 一进一出）、`Consumer<T>`（accept 消费）、`Supplier<T>`（get 生产）、`Predicate<T>`（test 判断）。**性能敏感场景用基本类型版本**（IntFunction/ToIntFunction）避免装箱。
>
> **方法引用 4 种**：静态（`Integer::parseInt`）、绑定实例（`System.out::println`）、未绑定实例（`String::length`，第一个参数当 receiver）、构造器（`ArrayList::new`）。
>
> 闭包变量必须 **effectively final**——JVM 是**值捕获**到 Lambda 对象字段，外部变量可变会导致内外不一致。引用类型可以改对象内容（list.add 没问题）但不能改引用本身。
>
> Lambda 的 **this 是外部类的 this**（和匿名内部类不同），**不能定义字段、只能实现单方法接口**、**不能直接抛 Checked 异常**。

---

## 十、相关文档

- [Stream API](./Stream%20API.md) — Lambda 的最大用户
- [Optional](./Optional.md) — 配合 Lambda 替代 if-null
- [Comparator](./Comparator.md) — 链式 Comparator 大量用 Lambda
- [基本数据类型与自动装箱](./基本数据类型与自动装箱.md) — Stream 数值版本避免装箱
- [反射与动态代理](./反射与动态代理.md) — invokedynamic 也用于反射优化
