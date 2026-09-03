# Object 类

> Object 是所有 Java 类的父类，**只有 11 个方法**，但每一个都是面试高频考点：
> ① `==` vs `equals` 区别
> ② `equals` 和 `hashCode` 必须同时重写——为什么？
> ③ `wait` / `notify` 为什么必须在 `synchronized` 里？
> ④ `clone` 是浅拷贝还是深拷贝？怎么实现深拷贝？
>
> 答这些题之前必须先把 11 个方法**摆全**，否则面试官追问你根本接不住。

---

## 一、Object 的 11 个方法

```java
public class Object {
    public final native Class<?> getClass();
    public native int hashCode();
    public boolean equals(Object obj) { return (this == obj); }
    protected native Object clone() throws CloneNotSupportedException;
    public String toString() { ... }
    public final native void notify();
    public final native void notifyAll();
    public final native void wait(long timeout) throws InterruptedException;
    public final void wait(long timeout, int nanos) throws InterruptedException;
    public final void wait() throws InterruptedException;
    protected void finalize() throws Throwable {}  // JDK 9 已 @Deprecated，JDK 18 标记为 forRemoval
}
```

按用途分类：

| 类别 | 方法 | 必背点 |
| --- | --- | --- |
| 类型 | `getClass()` | 反射入口；final native |
| 哈希 / 比较 | `hashCode()` / `equals()` | 必须配套重写 |
| 字符串 | `toString()` | 默认 `类名@hashCode 的 16 进制` |
| 拷贝 | `clone()` | 浅拷贝；要实现 `Cloneable` 标记接口 |
| 线程协作 | `wait()` / `notify()` / `notifyAll()` | 必须在 synchronized 里调 |
| 析构（已废弃） | `finalize()` | JDK 9 弃用，**别用** |

---

## 二、`getClass()`

```java
String s = "hello";
Class<?> clazz = s.getClass();   // class java.lang.String
```

- `final native`，子类不能重写
- 返回的是**运行时类型**（实际类），不是声明类型
- 反射的入口：`s.getClass().getMethod("length").invoke(s)`

> **小坑**：泛型由于类型擦除，`List<String>.getClass()` 和 `List<Integer>.getClass()` 是同一个 class。

---

## 三、`hashCode()`

```java
public native int hashCode();
```

### 3.1 默认实现

JDK 8 以前：返回**对象的内存地址**（C++ 实现：基于 `_mark` 字段）。
JDK 8+：可通过 `-XX:hashCode=N` 选择算法（默认 5：基于 Marsaglia XOR-shift 的伪随机），**不再等于内存地址**。

### 3.2 hashCode 是怎么存的

第一次调 `hashCode()` 后，结果会写到对象头的 **Mark Word** 里（参考 [JVM/对象在内存中的布局](../JVM/对象在内存中的布局.md#21-mark-word8-字节)）。后续调用直接读，不重算。

> **副作用**：调过 `hashCode()` 的对象**无法再使用偏向锁**（Mark Word 没空间同时存哈希码 + 偏向锁信息）。

### 3.3 重写要求

参见 [六、equals 和 hashCode 契约](#六equals--hashcode-契约必背)。

---

## 四、`equals()` —— 逻辑相等

### 4.1 默认实现

```java
public boolean equals(Object obj) {
    return (this == obj);   // 等于 ==，比较引用
}
```

→ 默认行为：两个对象只要不是同一个引用，`equals` 就是 false。

### 4.2 标准重写模板

```java
public class User {
    private String id;
    private String name;

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;                                  // 1. 引用相等快速返回
        if (o == null || getClass() != o.getClass()) return false;   // 2. 类型检查
        User user = (User) o;                                        // 3. 强转
        return Objects.equals(id, user.id);                          // 4. 业务字段比较
    }

    @Override
    public int hashCode() {
        return Objects.hash(id);                                     // 与 equals 用一样的字段
    }
}
```

### 4.3 `==` 与 `equals` 的陷阱

| 场景 | `==` | `equals` |
| --- | --- | --- |
| 基本类型 | 比值 | 不存在 |
| 引用类型 | 比地址 | 比内容（如果重写了） |
| String `"abc" == "abc"` | true（常量池） | true |
| `new String("abc") == "abc"` | **false** | true |
| `Integer 100 == 100` | true（缓存命中） | true |
| `Integer 200 == 200` | **false**（出缓存） | true |

**Integer 缓存**：`Integer.valueOf(int)` 缓存 -128 ~ 127，超过就 new 一个新对象。**生产代码 Integer 比较永远用 equals 或拆箱**，不要用 `==`。

```java
Integer a = 200, b = 200;
System.out.println(a == b);          // false ⚠
System.out.println(a.equals(b));     // true
System.out.println(a.intValue() == b.intValue());  // true
```

### 4.4 String 的 equals

```java
public boolean equals(Object anObject) {
    if (this == anObject) return true;
    if (anObject instanceof String) {
        String aString = (String) anObject;
        if (coder() == aString.coder()) {
            return isLatin1() ? StringLatin1.equals(value, aString.value)
                              : StringUTF16.equals(value, aString.value);
        }
    }
    return false;
}
```

→ JDK 9+ 的紧凑字符串：先比 coder（Latin-1 vs UTF-16），不同直接 false；同种 coder 才走 byte[] 比较。

---

## 五、`toString()`

### 5.1 默认实现

```java
public String toString() {
    return getClass().getName() + "@" + Integer.toHexString(hashCode());
}
```

打印出来是 `com.foo.User@5cad8086`，对调试**毫无帮助**。

### 5.2 生产推荐

```java
@Override
public String toString() {
    return "User{id='" + id + "', name='" + name + "'}";
}
```

或用 IDE / Lombok 生成。

> **小坑**：`toString` 千万别打印**敏感字段**（密码、token、身份证）——日志里印出来会被审计抓。

---

## 六、equals & hashCode 契约（必背）

### 6.1 五大契约

```
1. 自反性：a.equals(a) == true
2. 对称性：a.equals(b) == b.equals(a)
3. 传递性：a.equals(b) && b.equals(c) → a.equals(c)
4. 一致性：在对象不变的情况下，多次调用结果一致
5. 与 null：a.equals(null) == false
```

**与 hashCode 的契约**：

```
a.equals(b) == true → 必须 a.hashCode() == b.hashCode()
反之不要求（不同对象可以同 hash，叫"哈希冲突"，正常）
```

### 6.2 必须配套重写的根本原因

HashMap、HashSet 这类**基于哈希**的容器，定位元素的逻辑是：

```
1. 算 key.hashCode() 找数组下标
2. 在该下标的链表/红黑树里用 equals 比较
```

→ 只重写 `equals` 不重写 `hashCode`，会发生：

```java
class User {
    String id;
    User(String id) { this.id = id; }
    @Override public boolean equals(Object o) { return ((User)o).id.equals(id); }
    // ⚠ 没重写 hashCode
}

Map<User, Integer> map = new HashMap<>();
map.put(new User("A"), 1);
Integer val = map.get(new User("A"));   // null! 取不到
```

为什么取不到：两个 `User("A")` 的 `hashCode()` 不同（默认基于地址），算出的数组下标不同，`get` 时根本找不到那个桶。

### 6.3 反过来：只重写 hashCode 不重写 equals

也会出问题：HashMap 找到桶后，调 `equals` 判断 key 是否相等——默认 `equals` 比地址，依然找不到。

> **结论**：`equals` 和 `hashCode` **永远成对重写**。IDE 生成都是一起出来的。

### 6.4 如果对象会被改怎么办

```java
class User {
    String id;
    int age;
    @Override public int hashCode() { return Objects.hash(id, age); }
}

User u = new User("A", 20);
map.put(u, "value");
u.age = 21;                  // ⚠ 修改了参与哈希的字段
map.get(u);                  // null —— hashCode 变了，找不到桶
```

→ **HashMap 的 key 必须是不可变的**（或者业务上保证不会改参与哈希的字段）。这就是为什么大家爱用 String、Integer 当 key——它们是 immutable。

---

## 七、`clone()` —— 浅拷贝 vs 深拷贝

### 7.1 默认是浅拷贝

```java
public class Address implements Cloneable {
    String city;
    @Override
    public Address clone() throws CloneNotSupportedException {
        return (Address) super.clone();
    }
}

public class User implements Cloneable {
    String name;
    Address address;     // 引用类型
    @Override
    public User clone() throws CloneNotSupportedException {
        return (User) super.clone();    // ⚠ 浅拷贝
    }
}

User u1 = new User(); u1.address = new Address("Beijing");
User u2 = u1.clone();
u2.address.city = "Shanghai";
System.out.println(u1.address.city);    // Shanghai —— 被改了！
```

→ `super.clone()` 只复制对象的字段值（包括引用），**不递归复制引用指向的对象**。

### 7.2 三种实现深拷贝的方式

**方式 1：手动递归 clone**

```java
@Override
public User clone() throws CloneNotSupportedException {
    User cloned = (User) super.clone();
    cloned.address = this.address.clone();   // 关键：嵌套字段也 clone
    return cloned;
}
```

**方式 2：序列化（万能但慢）**

```java
public User deepCopy() {
    try (ByteArrayOutputStream bos = new ByteArrayOutputStream();
         ObjectOutputStream oos = new ObjectOutputStream(bos)) {
        oos.writeObject(this);
        try (ObjectInputStream ois = new ObjectInputStream(
                 new ByteArrayInputStream(bos.toByteArray()))) {
            return (User) ois.readObject();
        }
    } catch (Exception e) { throw new RuntimeException(e); }
}
```

→ 全部字段必须实现 `Serializable`；性能差（序列化反序列化开销）；**线上拷贝几万对象别用**。

**方式 3：JSON 序列化（生产常用）**

```java
String json = objectMapper.writeValueAsString(user);
User copy = objectMapper.readValue(json, User.class);
```

→ 比方式 2 快、可读性好，但要小心循环引用。

### 7.3 Cloneable 是什么

`Cloneable` 是**标记接口**（marker interface，没有任何方法），唯一作用：让 `Object.clone()` 能正常工作。**不实现就抛 `CloneNotSupportedException`**。

→ 设计上是个**反面教材**——`clone` 应该在 `Cloneable` 接口里定义，而不是在 `Object` 里 protected。Joshua Bloch 自己在 Effective Java 里都批评这个 API。

### 7.4 生产推荐

| 场景 | 推荐 |
| --- | --- |
| 不可变对象 | 不需要 clone，直接共用引用 |
| 简单 POJO | Lombok `@Builder.toBuilder` 或拷贝构造器 |
| 复杂对象 | JSON 序列化（Jackson / Fastjson） |
| 性能敏感 | 手写深拷贝（递归 clone） |
| **避免** | `Object.clone()`——API 设计差，易出错 |

---

## 八、wait / notify —— 为什么必须在 synchronized 里

### 8.1 三个方法

```java
public final void wait()                     // 释放锁，无限等
public final void wait(long timeout)         // 释放锁，等 timeout ms
public final void wait(long timeout, int nanos)  // 同上 + 纳秒精度

public final native void notify()            // 唤醒等待队列里的一个
public final native void notifyAll()         // 唤醒等待队列里的全部
```

### 8.2 必须在 synchronized 里调

```java
synchronized (lock) {
    while (!condition) {
        lock.wait();         // 必须在这里
    }
    // 业务逻辑
}

// 唤醒方
synchronized (lock) {
    condition = true;
    lock.notify();           // 必须在这里
}
```

→ 不在 `synchronized` 里调，抛 `IllegalMonitorStateException`。

### 8.3 为什么这个限制

**根本原因**：`wait` 的语义是**原子地释放锁 + 进入等待**。如果不在持锁状态调，**锁的状态根本就没建立**，无从释放。

**对照场景**（不加 synchronized 的话）：

```java
// 场景：消费者
if (!queue.hasItem()) {       // ① 检查
    lock.wait();              // ② 等  ← 之间生产者插了一个 item 还 notify 了
}
queue.take();                 // ③ 取
```

如果 ①② 之间不持锁，生产者可能在中间插入：放 item + notify。等消费者执行到 ②，notify **已经发完了**——消费者就永远等下去（信号丢失）。

加 synchronized 后，消费者持锁期间生产者拿不到锁，无法 notify，避免这个 race。

### 8.4 wait 用 while 不用 if

```java
// ❌ 错的
synchronized (lock) {
    if (!condition) lock.wait();
}

// ✅ 对的
synchronized (lock) {
    while (!condition) lock.wait();
}
```

**原因**：

1. **虚假唤醒（spurious wakeup）**：操作系统层面 `pthread_cond_wait` 可能没人 notify 也返回。Java 规范允许这种情况。
2. **抢锁竞争**：被 notify 后，醒来要重新抢锁——拿到锁时，条件可能已被别人改变。

### 8.5 wait 和 sleep 区别

| 维度 | `Thread.sleep` | `Object.wait` |
| --- | --- | --- |
| 定义在 | Thread | Object |
| 是否释放锁 | ❌ 不释放 | ✅ 释放 |
| 是否需要持锁 | 不需要 | **必须持锁** |
| 唤醒条件 | 时间到 / interrupt | notify / notifyAll / interrupt / 超时 |

### 8.6 notify vs notifyAll

| 方法 | 唤醒数 | 适用场景 |
| --- | --- | --- |
| `notify()` | 一个（具体哪个 JVM 决定） | 单生产单消费、对等线程模型 |
| `notifyAll()` | 所有等待的 | 不同条件的等待者；**生产代码默认用这个** |

> Doug Lea 在 Java Concurrency 里的建议：**永远用 `notifyAll`**，除非你能证明 `notify` 一定不丢消息。

---

## 九、`finalize()` —— 已废弃，别用

```java
protected void finalize() throws Throwable {}
```

GC 回收对象前调用一次（且只调一次）。**JDK 9 已 @Deprecated，JDK 18 标记 `forRemoval=true`**。

**为什么废弃**：

1. **执行时机不确定**——GC 决定，可能永远不调
2. **性能差**——有 finalize 的对象走 F-Queue，至少经历两次 GC 才能回收
3. **可能让对象复活**——在 finalize 里把 this 赋给静态字段
4. **不可靠**——JVM 退出时可能不执行（默认不跑 finalizer）

**替代**：用 `try-with-resources` + `AutoCloseable`：

```java
try (FileInputStream in = new FileInputStream("a.txt")) {
    // 用完自动 close
}
```

或 `Cleaner`（JDK 9+）：

```java
private static final Cleaner cleaner = Cleaner.create();
cleaner.register(this, () -> { /* 清理资源 */ });
```

---

## 十、生产踩坑

### 10.1 重写 equals 没重写 hashCode

最经典——HashMap 取不到值（[6.2](#62-必须配套重写的根本原因)）。

### 10.2 hashCode 用了可变字段

```java
class User { String id; @Override int hashCode() { return Objects.hash(id); } }

User u = new User("A"); set.add(u);
u.id = "B";              // ⚠
set.contains(u);         // false —— 找不到了
```

**生产规范**：作为 HashMap key 的对象，**hashCode 必须基于不可变字段**（业务主键、UUID）。

### 10.3 子类重写 equals 破坏对称性

```java
class Animal { String name; ... equals 比 name }
class Dog extends Animal { String breed;
    @Override boolean equals(Object o) {
        return o instanceof Dog && ((Dog)o).breed.equals(breed) && super.equals(o);
    }
}

Animal a = new Animal("Buddy");
Dog d = new Dog("Buddy", "Husky");
a.equals(d);   // true（按 name）
d.equals(a);   // false（要求是 Dog）
```

→ 违反对称性。**Effective Java 第 11 条**：**`equals` 用 `getClass()` 严格类型检查，不要用 `instanceof` 跨子类**。

### 10.4 wait 用 if 而不是 while

虚假唤醒 + race 条件 → 系统偶现卡死或重复处理（[8.4](#84-wait-用-while-不用-if)）。

### 10.5 toString 印敏感字段

DEBUG 日志把对象 toString 进去，**密码、token 上日志系统**，被合规审计抓。**生产规范**：toString 中标记 `@Sensitive` 字段不打印；用 `**` 替代。

---

## 十一、面试高频追问

### Q1：Object 有几个方法？

11 个：`getClass / hashCode / equals / clone / toString / notify / notifyAll / wait(三个重载) / finalize`。注意 `wait` 是 3 个重载。

### Q2：== 和 equals 区别？

`==` 比的是栈上的值（基本类型 = 数值，引用类型 = 地址）；`equals` 是 Object 提供的方法，**默认行为等于 `==`**，子类可以重写为"逻辑相等"。

### Q3：为什么重写 equals 必须重写 hashCode？

HashMap / HashSet 用 hashCode 找桶，equals 比内容。只重写 equals 会让两个"相等"对象 hashCode 不同，分到不同桶，**HashMap.get 取不到**。这是 equals/hashCode 契约：`equals 相等 → hashCode 相等`。

### Q4：hashCode 默认怎么算？

JDK 8+ 用伪随机算法（XOR-shift），不再是地址；首次调用结果会写到 Mark Word 里，后续读缓存。**调过 hashCode 的对象不能再用偏向锁**。

### Q5：clone 是浅拷贝还是深拷贝？

**默认浅拷贝**——只复制字段值，引用类型字段共享。深拷贝有三种方式：手动递归 clone、序列化、JSON。生产常用 JSON。

### Q6：Cloneable 接口里有方法吗？

没有，是**标记接口**——告诉 JVM 这个类允许 clone。不实现 Cloneable 调 super.clone() 抛 `CloneNotSupportedException`。Effective Java 推荐**别用 clone，改用拷贝构造器**。

### Q7：wait 为什么必须在 synchronized 里？

wait 的语义是**原子释放锁 + 进入等待**。不持锁就没什么可释放的，**JVM 抛 `IllegalMonitorStateException`**。不强制持锁会有信号丢失（消费者检查到等待之间，生产者已经发完 notify）。

### Q8：wait 和 sleep 区别？

定义类不同（Object vs Thread）；wait **释放锁**，sleep 不释放；wait 必须持锁，sleep 不需要。

### Q9：wait 为什么用 while 不用 if？

防止**虚假唤醒**和**条件被改变**——醒来必须重新检查，否则可能进入业务逻辑时条件不满足。

### Q10：notify 唤醒的是哪个线程？

JVM 实现决定，**Java 规范不保证顺序**——HotSpot 通常是 FIFO 但不能依赖。**生产代码用 notifyAll**，避免特定唤醒导致的死等。

### Q11：finalize 还能用吗？

JDK 9 弃用，JDK 18 标记 forRemoval。**别用**——执行时机不定、性能差、对象可能复活。资源清理用 `try-with-resources` 或 `Cleaner`。

### Q12：为什么 String 当 HashMap key 好？

不可变（hashCode 永远不变）、有现成的高质量 hashCode（基于内容）、equals 实现高效（先比 coder 再比 byte[]）。

---

## 十二、答题模板（60 秒话术）

> Object 有 **11 个方法**，分四类：getClass、hashCode、equals、toString、clone、wait/notify/notifyAll、finalize。
>
> 重点是 **equals 和 hashCode 必须配套重写**——HashMap 用 hashCode 找桶，equals 比内容；只改一个会导致 get 不到。重写时注意契约：自反 / 对称 / 传递 / 一致 / equals 相等 hashCode 必相等。
>
> **clone 默认浅拷贝**，引用字段共享；深拷贝实战用 JSON 序列化，方便。Cloneable 是标记接口、API 设计差，**Effective Java 推荐改用拷贝构造器**。
>
> **wait/notify 必须在 synchronized 里**——wait 的语义是原子释放锁加等待，不持锁就抛 IllegalMonitorStateException；用 while 防虚假唤醒，notifyAll 替代 notify 避免信号丢失。
>
> **finalize 已弃用**，资源清理用 try-with-resources 或 Cleaner。

---

## 十三、相关文档

- [HashMap](./HashMap.md) — equals/hashCode 在 HashMap 里的具体用法
- [String 原理](./String原理.md) — String.equals / String.hashCode 实现
- [对象在内存中的布局](../JVM/对象在内存中的布局.md) — Mark Word 怎么存 hashCode
- [Synchronized](../Concurrency/Synchronized.md) — wait/notify 的锁机制
- [等待唤醒机制](../Concurrency/等待唤醒机制.md) — wait/notify 模式深入
