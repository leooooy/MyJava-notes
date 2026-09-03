# String 原理

> String 是 Java 用得最多的类，**也是面试问得最深的类**。一道"`String s = "abc"` 创建几个对象"已经能筛掉一半候选人。
>
> 本篇要讲清 5 件事：
> ① **不可变**到底是怎么实现的、为什么这么设计
> ② **字符串常量池**在哪、JDK 7 为什么搬到堆、`intern()` 干什么
> ③ `String s = "abc"` vs `new String("abc")` 创建几个对象
> ④ JDK 9 **紧凑字符串**（Compact Strings）省了什么
> ⑤ **String / StringBuilder / StringBuffer** 怎么选，编译器优化是什么

---

## 一、不可变设计

### 1.1 源码核心

```java
// JDK 8
public final class String implements ... {
    private final char[] value;        // ⚠ final char[]
    private int hash;                  // 缓存 hashCode（lazy init）
}

// JDK 9+
public final class String implements ... {
    private final byte[] value;        // ⚠ 改成 byte[]
    private final byte coder;          // 0: LATIN1, 1: UTF16
    private int hash;
}
```

不可变的几把锁：

1. **类是 `final`**——不能继承重写
2. **value 字段是 `private final`**——不能改引用，外界看不见
3. **没有暴露 value 的 setter**——所有"修改"操作都返回新对象（`substring` / `concat` / `replace` 都是新建）

### 1.2 为什么这么设计

| 动机 | 解释 |
| --- | --- |
| **常量池可行** | 不可变才能多个引用安全共享同一份 char[] |
| **HashMap key 安全** | hashCode 永远不变，put 进去取不到的灾难不会发生 |
| **线程安全** | 不可变天然线程安全，不需锁 |
| **缓存 hashCode** | 算一次永远有效（hash 字段 lazy init）|
| **类加载器关键参数** | classpath、类名都是 String，可变会被恶意篡改加载非预期类 |
| **网络 / SQL 安全** | URL、SQL 一旦传入就不能被修改，避免 TOCTOU 攻击 |

### 1.3 但 String 真的"完全"不可变吗？

```java
String s = "hello";
Field f = String.class.getDeclaredField("value");
f.setAccessible(true);
char[] v = (char[]) f.get(s);
v[0] = 'X';                       // 通过反射改了 value 数组
System.out.println(s);            // Xello —— ⚠ 被改了
```

→ **反射可以破坏不可变性**。但生产代码不会这么干，且 JDK 9+ 模块化后默认强封装，反射访问 `java.base` 内部字段会警告或失败。

---

## 二、内部数组：char[] → byte[]

### 2.1 JDK 8 的 char[]

```java
char[] value;              // 每个 char 占 2 字节（UTF-16）
```

→ 一个 ASCII 字符串 `"hello"` 占 5×2 = 10 字节，**浪费一半**（ASCII 实际只要 1 字节）。

### 2.2 JDK 9+ 紧凑字符串（Compact Strings）

```java
byte[] value;
byte coder;     // 0: LATIN1（每字符 1 字节），1: UTF16（每字符 2 字节）
```

逻辑：

```
全是 Latin-1（ASCII / 西欧字符）→ 用 byte[] 每字符 1 字节
出现非 Latin-1（中文 / emoji）→ 用 byte[] 每字符 2 字节
```

**收益**：

- ASCII 字符串内存减半（生产环境堆里大量是 Latin-1，**实测堆占用减少 5%~15%**）
- 减少 GC 压力
- L1 缓存命中率提升

JDK 9 升级，**应用代码完全不感知**（API 不变），但堆内存监控会发现明显下降。

### 2.3 看一个对象的实际占用

```java
String s = "hello";  // JDK 8: 头 16B + char[] 引用 4B + hash 4B + 8B 对齐 = 24B + 数组开销 24B = 48B
                     // JDK 9: 头 16B + byte[] 引用 4B + coder 1B + hash 4B + 对齐 = 24B + 数组开销 16B + 5B = 40B
```

---

## 三、字符串常量池

### 3.1 它是什么

**字符串常量池（String Pool / String Table）**：JVM 维护的一张哈希表，存放 String 对象的引用，用来去重。

### 3.2 三种入池方式

```java
// 方式 1: 字面量
String s1 = "abc";                       // 编译期常量，直接进池

// 方式 2: 编译期可计算的拼接
String s2 = "ab" + "c";                  // 编译期变成 "abc"，进池

// 方式 3: 显式 intern
String s3 = new String("abc").intern();  // 走一遍池
```

### 3.3 不会自动入池的

```java
String s = new String("abc");                // 堆上新对象，不在池里
String s2 = "ab" + new String("c");          // 含变量，运行时拼接，不入池
String s3 = userInput;                       // 用户输入，不入池
```

### 3.4 常量池在哪（演进史）

| 版本 | 位置 | 关键变化 |
| --- | --- | --- |
| JDK 6 | **永久代** | StringTable size 默认 1009，PermGen 满会 OOM |
| JDK 7 | **堆** | 搬到堆，StringTable 默认 60013 |
| JDK 8+ | 堆 + 元空间（PermGen → Metaspace） | StringTable 还在堆 |

**为什么 JDK 7 搬到堆**：

- PermGen 大小固定（`-XX:PermSize`）容易 OOM
- 堆有完整 GC 支持，常量池字符串可以被回收
- 堆 + 弱可达性 → 不再驻留的字符串可以被卸载

> **可调参数**：`-XX:StringTableSize=...` 调整哈希表桶数。生产经验：服务长时间运行后字符串多，建议设大点（**100003** 或更高，需是质数）。

### 3.5 intern() 干什么

```java
public native String intern();
```

逻辑：
1. 查池里有没有 equals 这个字符串的：有 → 返回池里的引用
2. 没有 → JDK 7+ 把**当前 String 对象的引用**放进池（不是 copy）；JDK 6 是 copy 字符串

```java
String s1 = new String("abc");           // 堆对象 + 池里"abc"已有
String s2 = s1.intern();                 // 返回池里那个引用
System.out.println(s1 == s2);            // false —— s1 是堆对象
System.out.println("abc" == s2);         // true
```

JDK 7+ 的 intern 行为微妙：

```java
String s = new StringBuilder().append("aa").append("bb").toString();
// "aabb" 拼出来的，不在池里
boolean inPool = (s.intern() == s);
// JDK 7+：true（因为 intern 直接把 s 引用放池里）
// JDK 6 ：false（intern 会 copy 一份进 PermGen）
```

**生产用 intern 的场景**：

- 大量重复字符串去重（节省堆）
- 例：日志解析后 user_agent 字段，几亿条重复，intern 后只占一份

但要注意：**StringTable 是固定大小的哈希表，intern 太多会哈希冲突**——查询变慢。

---

## 四、面试经典：创建几个对象

### 4.1 经典三连题

```java
String s1 = "abc";                         // 0 或 1 个对象
String s2 = new String("abc");             // 1 或 2 个对象
String s3 = new String("a") + new String("b");  // 至少 3 + 1 = 4 个
```

详解：

**`String s1 = "abc"`**：
- 类加载时，把 "abc" 加入常量池——**1 个 String 对象 + 1 个 char[]/byte[]**
- 之后再 `String s = "abc"` 都是从池取——**0 个**

**`String s2 = new String("abc")`**：
- "abc" 已在池里（1 个），new 在堆上又建一个 String 对象（共享 char[] 还是新建？）——**1 或 2 个**
- JDK 7+：new String(String original) 内部 `this.value = original.value` 共享 char[]——只多一个 String 对象
- 第一次执行（"abc" 不在池里）：池 1 个 + 堆 1 个 = **2 个**

**`String s3 = new String("a") + new String("b")`**：
- "a" 进池 + new "a" + "b" 进池 + new "b" + StringBuilder.toString() 新 String = **5 个对象**（不算 StringBuilder 内部 char[]）

### 4.2 面试高频追问

**Q：`String s = "ab" + "c"` 几个对象？**

→ 编译期常量折叠成 "abc"，**1 个对象**（如果池里没有）。`javap -c` 看字节码就一条 `ldc #2 // String abc`。

**Q：`String a = "ab"; String b = "c"; String s = a + b;` 几个？**

→ 运行时拼接，编译为 `new StringBuilder().append(a).append(b).toString()`：
- "ab" + "c" 都在池（如果之前没用过，2 个）
- StringBuilder 1 个
- StringBuilder.toString() 内部 new String() 1 个
- 共 **3 + StringBuilder 内部 char[]** ≈ 4 个

**Q：`String a = "ab"; final String b = "c"; String s = a + b;`？**

→ `final b = "c"` 编译期常量，会被内联：等价于 `a + "c"`——但 a 不是 final，**还是运行时拼接**。如果两边都 final，编译期就折叠了。

---

## 五、字符串拼接的编译优化

### 5.1 `+` 在不同上下文的实现

```java
// 1. 编译期常量
String s = "a" + "b";
// → javac 折叠为 "ab"

// 2. 运行时拼接（JDK 8）
String s = a + b;
// → new StringBuilder().append(a).append(b).toString()

// 3. 运行时拼接（JDK 9+）
String s = a + b;
// → invokedynamic + StringConcatFactory.makeConcatWithConstants
//   JIT 把这个 indy 优化成内联的拼接，比 StringBuilder 还快
```

### 5.2 JDK 9 的 `invokedynamic` 优化

JDK 9 之前：每次 `+` 都 new 一个 StringBuilder。
JDK 9+：编译期生成 `invokedynamic`，**JIT 在运行时根据实际类型动态生成最优代码**——可能完全没有 StringBuilder。

```bash
javap -c JDK9Plus.class
# 看到的是: invokedynamic #2, makeConcatWithConstants ...
```

**实测性能**：JDK 9+ 的 `+` 拼接比 JDK 8 快约 20-50%。

### 5.3 但循环里仍然别用 +

```java
String result = "";
for (int i = 0; i < 10000; i++) {
    result += i;       // ⚠ 每次循环新建 StringBuilder（JIT 也救不了）
}
```

→ 循环内 `+` 会每轮新建 StringBuilder，**O(n²) 性能**。**显式用 StringBuilder**：

```java
StringBuilder sb = new StringBuilder();
for (int i = 0; i < 10000; i++) {
    sb.append(i);
}
String result = sb.toString();
```

---

## 六、StringBuilder vs StringBuffer

### 6.1 对比表

| 维度 | String | StringBuilder | StringBuffer |
| --- | --- | --- | --- |
| 可变性 | 不可变 | 可变 | 可变 |
| 线程安全 | ✅（不可变） | ❌ | ✅（synchronized） |
| 性能 | 拼接慢 | 快 | 中等（有锁开销） |
| 引入版本 | 一直在 | JDK 5 | JDK 1.0 |
| 推荐 | 短字符串 / 常量 | **单线程拼接** | 几乎不用 |

### 6.2 StringBuffer 的悲剧

```java
public class StringBuffer extends AbstractStringBuilder {
    public synchronized StringBuffer append(String str) { ... }
    public synchronized String toString() { ... }
}
```

每个方法都 `synchronized`——**单线程也付锁开销**，又没人真在多线程下拼字符串（多线程要的是 StringBuilder + 外部同步，而不是粒度极小的方法级同步）。

→ JDK 5 出 StringBuilder 后，**StringBuffer 几乎被废**。生产代码看到 StringBuffer 都该改成 StringBuilder。

### 6.3 StringBuilder 内部

```java
abstract class AbstractStringBuilder {
    byte[] value;           // JDK 9+ 也用 byte[]
    int count;
    byte coder;
    static final int MAX_ARRAY_SIZE = Integer.MAX_VALUE - 8;
}
```

扩容策略：

```java
private int newCapacity(int minCapacity) {
    int newCapacity = (value.length << 1) + 2;   // 2 倍 + 2
    if (newCapacity - minCapacity < 0) newCapacity = minCapacity;
    return newCapacity > MAX_ARRAY_SIZE ? hugeCapacity(minCapacity) : newCapacity;
}
```

**容量预估**：能预估字符串长度的话，**初始化时指定容量**避免扩容：

```java
new StringBuilder(1024).append(...)
```

---

## 七、字符串相关 API 容易踩坑

### 7.1 `split` 性能

```java
String[] parts = csv.split(",");          // 内部用正则，慢
String[] parts = StringUtils.split(csv, ',');  // Apache Commons，没正则，快几倍
```

5.x 之前每次都编译正则；JDK 7+ 对单字符做了快路径，但还是不如纯字符串切。

### 7.2 `String.format` 慢

```java
String s = String.format("user=%s, age=%d", name, age);   // 每次解析 format
// 替代
String s = "user=" + name + ", age=" + age;               // 快得多
```

→ 高频日志、循环里别用 format，慢一个数量级。

### 7.3 `replaceAll` 是正则

```java
"a.b.c".replaceAll(".", "-");      // ❌ 全替换成 "-----"（. 是任意字符）
"a.b.c".replace(".", "-");         // ✅ 字面量替换 "a-b-c"
```

`replaceAll` 第一个参数是**正则**，`replace` 是字面量。

---

## 八、生产踩坑

### 8.1 String + 拼接 SQL 导致注入

```java
String sql = "SELECT * FROM user WHERE name='" + name + "'";  // ❌ SQL 注入
// 用 PreparedStatement
PreparedStatement ps = conn.prepareStatement("SELECT * FROM user WHERE name=?");
ps.setString(1, name);
```

### 8.2 大量 intern 导致 StringTable 膨胀

**现象**：日志解析服务跑几天后，`StringTable` 占用 1GB+。
**根因**：所有解析后的字段都 intern() 了，但很多字段是 UUID、时间戳等永远不重复的——**全部进池**。
**修复**：只对**预期高重复**的字段 intern（如 user_agent 枚举、status）；StringTableSize 设大；定期重启服务。

### 8.3 substring 内存泄漏（已修复）

```java
// JDK 6 及之前：substring 共享原数组（性能优化变成坑）
String huge = readFile();    // 1MB 字符串
String tiny = huge.substring(0, 10);
// tiny 内部还引用着 1MB 的 char[] —— huge 永远 GC 不掉
```

JDK 7+ **改为 substring 总是 copy**——内存泄漏问题修复，但 substring 不再 O(1)。

### 8.4 StringBuilder 容量没预估

```java
StringBuilder sb = new StringBuilder();    // 默认 16
for (int i = 0; i < 10000; i++) {
    sb.append("xxxxxxxxxxxxxxxx");          // 触发多次扩容、数组拷贝
}

// 预估好初始容量
StringBuilder sb = new StringBuilder(160000);
```

### 8.5 编码不统一

```java
byte[] bytes = str.getBytes();              // 用平台默认编码！
byte[] bytes = str.getBytes(StandardCharsets.UTF_8);   // ✅ 显式指定
```

Windows 默认 GBK、Linux 默认 UTF-8——**不指定编码 = 跨环境出乱码**。生产规范：所有 String ⇄ byte[] 都显式指定 UTF-8。

---

## 九、面试高频追问

### Q1：String 为什么不可变？

class final + value final + 没有 setter。这么做是为了：常量池、线程安全、HashMap key 安全、hashCode 缓存、安全（classpath / SQL / URL 不被篡改）。

### Q2：String 真的不可变吗？

**反射可破**。但 JDK 9+ 模块化后默认强封装，反射访问 `java.base` 内部字段会警告或失败。

### Q3：JDK 9 紧凑字符串解决什么问题？

JDK 8 用 char[]（每字符 2 字节），ASCII 串浪费一半。JDK 9 改成 byte[] + coder——Latin-1 串每字符 1 字节，**堆内存减少 5%~15%**。API 不变，应用无感。

### Q4：常量池在哪？JDK 7 为什么搬？

JDK 6 在永久代（PermGen），易 OOM。JDK 7 搬到堆——可以走 GC 回收不再用的字符串、容量大。JDK 8 永久代换成元空间，常量池**仍在堆**。

### Q5：`String s = "abc"; String s2 = new String("abc");` 几个对象？

第一次执行：池里"abc" 1 个 + 堆里 new 1 个 = **2 个**。
之后再执行：池里已有，**只多 1 个**（new 那个）。

### Q6：`new String("abc").intern() == "abc"` 是什么？

true。intern 把 new 出来那个对象的引用放池里（JDK 7+），但池里已经有"abc"了——所以返回的是池里的"abc"，等于字面量"abc"。

### Q7：StringBuilder 和 StringBuffer 区别？

StringBuilder（JDK 5）非线程安全、快；StringBuffer（JDK 1.0）方法 synchronized、慢。**多线程拼字符串场景几乎不存在**——StringBuffer 基本被废，生产用 StringBuilder。

### Q8：String + 拼接和 StringBuilder 区别？

JDK 8：`a + b` 编译为 `new StringBuilder().append(a).append(b).toString()`。
JDK 9+：编译为 `invokedynamic`，JIT 动态生成最优代码，比 StringBuilder 快。
**循环内**：仍然别用 + ——每次循环新建 StringBuilder，O(n²)。

### Q9：String.equals 怎么实现？

JDK 9+：先比 coder（Latin-1 vs UTF-16），不同 false；同种 coder 比 byte[]。所以**两个完全相同的字符串比较是 O(n)**，但前置短路。

### Q10：String.hashCode 怎么算？怎么缓存？

```java
h = 0
for each char c: h = 31 * h + c
```

为什么 31：质数 + 31 = 32 - 1 = `(h<<5) - h`，JIT 优化成位运算。**hashCode 缓存在 hash 字段**——第一次算之后存起来，后续 O(1)。但 hash=0 的字符串每次仍会重算。

---

## 十、答题模板（60 秒话术）

> String 是 **final + private final byte[]/char[]**——三层不可变保证：常量池可行、线程安全、HashMap key 安全、hashCode 可缓存。
>
> JDK 9 紧凑字符串：char[] 改 byte[] + coder（LATIN1/UTF16），ASCII 串内存减半，**堆占用降 5%~15%**。
>
> 字符串常量池 JDK 6 在永久代易 OOM，**JDK 7 搬到堆**，可被 GC。`new String("abc")` 和字面量 `"abc"` 不是同一个对象；`intern()` JDK 7+ 把堆引用放池里，可去重大量重复字符串。
>
> 拼接：编译期常量折叠成一个 String；运行时 JDK 8 `+` 编译成 StringBuilder，JDK 9+ 用 **invokedynamic** 更快；**循环里必须显式 StringBuilder**，否则 O(n²)。
>
> StringBuilder（JDK 5、非线程安全、快）替代 StringBuffer（synchronized、慢）；**StringBuffer 几乎已废**。

---

## 十一、相关文档

- [Object 类](./Object类.md) — String 重写了 equals / hashCode
- [集合框架总览](./集合类.md) — String 是最佳的 HashMap key
- [对象在内存中的布局](../JVM/对象在内存中的布局.md) — String 对象的实际占用
- [JVM 运行时数据区 - 字符串常量池](../JVM/内存区域.md#52-字符串常量池搬家史) — 池的存放位置演进
