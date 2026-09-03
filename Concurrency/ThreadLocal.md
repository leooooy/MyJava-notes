# ThreadLocal

> Java 线程隔离的"标准答案"，几乎所有 Web 框架（Spring 事务、MDC 日志、Hibernate Session）都在用。本篇讲清：
> ① ThreadLocal 怎么实现"线程私有"——为什么不在 ThreadLocal 里存数据，而把数据放在 Thread 里
> ② ThreadLocalMap 的开放定址法、为什么 key 用弱引用
> ③ **内存泄漏**的根源 + remove 的必要性
> ④ InheritableThreadLocal / TransmittableThreadLocal 区别
> ⑤ 线程池场景下的"经典坑"

---

## 一、为什么要 ThreadLocal

### 1.1 痛点

多线程下共享变量需要锁。但有些场景"每个线程要一份独立副本"，根本不需要共享：
- 数据库连接 / 事务上下文（一个请求一条连接，请求结束销毁）
- 用户身份信息（每个请求的当前登录用户）
- 日志的 traceId / MDC
- DateFormat（SimpleDateFormat 不线程安全）

ThreadLocal 提供"**变量在线程间隔离、在方法间共享**"的语义。

### 1.2 用法

```java
private static final ThreadLocal<User> CURRENT_USER = new ThreadLocal<>();

// 拦截器入口
CURRENT_USER.set(authenticatedUser);
try {
    chain.doFilter(req, resp);
} finally {
    CURRENT_USER.remove();        // ★ 必须 remove，下面会讲
}

// 业务任意位置
User u = CURRENT_USER.get();
```

---

## 二、内部实现：数据存哪了？

### 2.1 不在 ThreadLocal 里！

容易误解的点：`ThreadLocal` 对象**自身不存数据**。它只是个"key"，真正的数据存在 **每个 Thread 对象的 `threadLocals` 字段**里。

```java
public class Thread {
    ThreadLocal.ThreadLocalMap threadLocals = null;     // 每个线程一份
    ThreadLocal.ThreadLocalMap inheritableThreadLocals = null;
    ...
}

public class ThreadLocal<T> {
    public T get() {
        Thread t = Thread.currentThread();
        ThreadLocalMap map = t.threadLocals;          // 拿当前线程的 map
        if (map != null) {
            ThreadLocalMap.Entry e = map.getEntry(this);   // 自己当 key
            if (e != null) return (T) e.value;
        }
        return setInitialValue();
    }
}
```

### 2.2 数据结构示意

```
       Thread-A                        Thread-B
   ┌───────────────┐               ┌───────────────┐
   │ threadLocals: │               │ threadLocals: │
   │ ┌───────────┐ │               │ ┌───────────┐ │
   │ │TL1 → 100  │ │               │ │TL1 → 200  │ │
   │ │TL2 → "abc"│ │               │ │TL2 → "xyz"│ │
   │ └───────────┘ │               │ └───────────┘ │
   └───────────────┘               └───────────────┘

       ▲                                   ▲
       │ TL1.get() ─ key 是 TL1 ─────────► 各自从 currentThread.threadLocals 查
       │                                   │
       └─ 同一个 ThreadLocal 实例，在不同线程拿到不同值
```

### 2.3 ThreadLocalMap 不是 HashMap

ThreadLocalMap 是 ThreadLocal 内部定义的、**为单线程优化**的简易 Map：
- **开放定址法**（线性探测）解决冲突，不是 HashMap 的拉链法
- 默认初始容量 **16**
- 扩容阈值 2/3
- key 是 **弱引用**（WeakReference<ThreadLocal<?>>）★ 这点是泄漏问题的根

为什么不用 HashMap：
- 单线程操作，无并发，不需要 ConcurrentHashMap
- 通常 entry 数量很少（一个线程持有的 ThreadLocal 一般 < 10 个），数组更紧凑
- 开放定址法 cache friendly

---

## 三、内存泄漏（最重要的考点）

### 3.1 引用链

```
Thread (强引用)
  └─► threadLocals (强引用)
        └─► Entry[]
              └─► Entry { WeakReference key (ThreadLocal); Object value (强引用) }
                              ▲                              ▲
                              │ 弱引用                       │ 强引用！
                              │
                ThreadLocal 对象（外部强引用没了，弱引用会被 GC 清掉，key 变 null）
```

### 3.2 泄漏路径

**正常流程**：业务用完 ThreadLocal 后没把它的引用置 null。
```java
ThreadLocal<HugeData> tl = new ThreadLocal<>();
tl.set(hugeData);
// 业务结束，tl 这个变量超出作用域，没人引用 tl 了
```

**这时候**：
- ThreadLocal 对象在堆里**只剩弱引用**（来自 Entry.key）
- GC 一来，ThreadLocal 对象被回收，Entry.key 变成 null
- 但 Entry.value 还是**强引用**，Entry 仍在 ThreadLocalMap 数组里
- → value 永远无法被 GC，**内存泄漏**

**线程池场景下尤其严重**：线程池的线程**不会销毁**，threadLocals 会持续累积"key=null 的脏 Entry"，最后 OOM。

### 3.3 ThreadLocal 的"补救"机制

set / get / remove 时，ThreadLocal **会顺手清理 key=null 的 Entry**（叫 `expungeStaleEntry`）：
- get 时遇到 key=null 的 Entry → 把 Entry 的 value 置 null，把 Entry 在数组里"挪走"（开放定址法的连带处理）
- set 时若插入位置周围有脏 Entry → 也清理

但这是"机会主义清理"——如果业务后续不再调 get/set，泄漏永远不会被清。

### 3.4 治本：手动 remove

```java
try {
    ThreadLocal.set(...);
    业务逻辑();
} finally {
    ThreadLocal.remove();         // ★ 必须！
}
```

`remove()` 会真正把 Entry 从数组里移除（包括 value 强引用），彻底消除泄漏。

### 3.5 为什么 key 设计成弱引用而不是强引用？

如果 key 是强引用：
- ThreadLocal 对象只要 Thread 还活着就一直被 ThreadLocalMap 引用
- 业务代码即使把 `tl = null`，ThreadLocal 也不会被 GC
- 这种泄漏更隐蔽（没有任何途径清理）

弱引用至少给了 GC 一个清理 key 的窗口，配合 ThreadLocal 的机会主义清理 + 强制 remove，可以解决问题。

---

## 四、四大引用类型（顺带介绍）

| 类型 | 何时回收 | 用途 |
| --- | --- | --- |
| **强引用 (Strong)** | 内存不足也不回收（除非引用置 null） | 默认所有 `Object o = new Object()` |
| **软引用 (Soft)** | 内存不足才回收 | 缓存（图片缓存、HTTP 响应缓存） |
| **弱引用 (Weak)** | **下次 GC 必回收** | ThreadLocalMap.Entry.key、WeakHashMap |
| **虚引用 (Phantom)** | 任何时候都可能回收，get() 永远返回 null | 跟踪对象被 GC 的时机（DirectByteBuffer 释放堆外内存） |

```java
import java.lang.ref.*;
Object o = new Object();
WeakReference<Object> wr = new WeakReference<>(o);
o = null;
System.gc();
wr.get();    // 大概率为 null（GC 后弱引用对象被回收）
```

---

## 五、InheritableThreadLocal

### 5.1 痛点

```java
ThreadLocal<String> tl = new ThreadLocal<>();
tl.set("hello");
new Thread(() -> System.out.println(tl.get())).start();   // null！
```

主线程 set 的值，子线程 get 不到——因为 ThreadLocalMap 是各自独立的。

### 5.2 InheritableThreadLocal

**子线程创建时拷贝父线程的 inheritableThreadLocals**：

```java
InheritableThreadLocal<String> itl = new InheritableThreadLocal<>();
itl.set("hello");
new Thread(() -> System.out.println(itl.get())).start();   // "hello"
```

实现：`new Thread()` 构造时检查父线程的 inheritableThreadLocals，**浅拷贝一份**给子线程。

### 5.3 局限：线程池场景失效

```java
ExecutorService pool = Executors.newFixedThreadPool(10);
itl.set("user-A");
pool.submit(() -> log(itl.get()));
itl.set("user-B");
pool.submit(() -> log(itl.get()));
```

线程池的线程**不是每次新创建**——它们是池在初始化时创建的。`InheritableThreadLocal` 的拷贝只在**线程创建时**发生一次，后续 set 的值在线程池线程里看不到。

→ 拿到的 `itl.get()` 可能是上次任务遗留的值，**完全错乱**。

### 5.4 阿里 TransmittableThreadLocal（TTL）

阿里开源 [transmittable-thread-local](https://github.com/alibaba/transmittable-thread-local) 解决了线程池下的 ThreadLocal 传递。

核心思路：
1. 提交任务时**捕获当前线程的 TTL 值**
2. 任务在线程池线程中执行前，把这些值**写入**线程池线程的 TTL
3. 任务执行完**还原**线程池线程原有的 TTL

需要包装 `Runnable` 或装饰 ExecutorService：
```java
ExecutorService pool = TtlExecutors.getTtlExecutorService(realPool);
TransmittableThreadLocal<String> ttl = new TransmittableThreadLocal<>();
ttl.set("traceId-123");
pool.submit(() -> log(ttl.get()));    // 能拿到 "traceId-123"
```

**TTL 的典型用例**：分布式链路追踪（traceId 跨线程池传递）、用户上下文跨异步任务传递。

---

## 六、生产用例

### 6.1 Spring 事务

`org.springframework.transaction.support.TransactionSynchronizationManager`：
```java
private static final ThreadLocal<Map<Object, Object>> resources = new NamedThreadLocal<>("Transactional resources");
```
当前事务的连接、隔离级别等绑定在 ThreadLocal 上，DAO 任意位置能拿到当前事务。

### 6.2 SLF4J 的 MDC

`org.slf4j.MDC`：
```java
MDC.put("traceId", UUID.randomUUID().toString());
log.info("...");          // 日志格式 [%X{traceId}] 自动带上
MDC.clear();
```
内部就是 `InheritableThreadLocal<Map<String,String>>`。**配合线程池要用 TTL 包装**。

### 6.3 SimpleDateFormat 线程封装

```java
private static final ThreadLocal<DateFormat> SDF =
    ThreadLocal.withInitial(() -> new SimpleDateFormat("yyyy-MM-dd"));
```
SimpleDateFormat **不线程安全**，多线程共用会偶发解析错乱。每个线程一份就安全了。
JDK 8+ 直接用线程安全的 `DateTimeFormatter` 更好。

---

## 七、生产踩坑

### 7.1 线程池里忘 remove → OOM

**现象**：线上服务跑半天后 Old Gen 满，dump 看到 ThreadLocalMap.Entry 数十万个，value 都是大对象。
**根因**：线程池线程不销毁，ThreadLocal 累积。
**修复**：`finally { tl.remove(); }`，或框架统一在 Filter 末尾清理。

### 7.2 线程池 + InheritableThreadLocal 串数据

**现象**：A 用户的请求看到了 B 用户的 traceId / 上下文。
**根因**：InheritableThreadLocal 只在线程创建时拷贝；线程池复用线程，导致老 ThreadLocal 残留。
**修复**：换 TransmittableThreadLocal。

### 7.3 ThreadLocal 当全局缓存用

```java
private static final ThreadLocal<Map<K,V>> CACHE = ...;   // 每个线程一份缓存
```
**问题**：每个线程一份完全独立——线程池里 100 个线程就 100 份缓存，命中率低 + 内存浪费。
**修复**：换 ConcurrentHashMap 或 Caffeine。

### 7.4 父子线程传递错位

```java
// 误用 ThreadLocal 而不是 InheritableThreadLocal
ThreadLocal<String> tl = new ThreadLocal<>();
tl.set("a");
new Thread(() -> tl.get()).start();   // null
```
**修复**：父子线程传递用 InheritableThreadLocal，线程池场景再升级 TTL。

### 7.5 静态 ThreadLocal 引用导致 ClassLoader 泄漏（容器场景）

Tomcat 容器卸载 webapp 时，如果 ThreadLocal 的 value 引用了 webapp ClassLoader 的类，且这个 ThreadLocal 是 Tomcat 工作线程的（线程不销毁），ClassLoader 永远不能被 GC，每次部署内存涨。

Tomcat 在线程销毁前会做 ThreadLocal cleanup。生产场景：长生命周期线程上的 ThreadLocal **必须**手动 remove。

---

## 八、面试高频追问

**Q1：ThreadLocal 怎么实现线程隔离？**
数据其实存在每个 Thread 对象的 `threadLocals` 字段（一个 ThreadLocalMap），ThreadLocal 自己只是个 key。`ThreadLocal.get()` 内部调用 `Thread.currentThread().threadLocals.get(this)`，自然每个线程读到自己那份。

**Q2：ThreadLocalMap 的 key 为什么是弱引用？**
防止外部代码不再使用 ThreadLocal 时，ThreadLocal 对象因为被 ThreadLocalMap 强引用而无法 GC。弱引用让 GC 能在 ThreadLocal 没有外部强引用时回收它。但 value 仍是强引用，所以**还是要 remove**才能彻底清掉 value。

**Q3：内存泄漏的根本原因？**
ThreadLocal 被 GC 后，Entry.key=null，但 Entry.value 还是强引用且 Entry 还在数组里。线程不死（如线程池），value 永远不能 GC。

**Q4：set/get 时 ThreadLocal 不是会清理脏 Entry 吗，为什么还要 remove？**
两个原因：
- 这种清理是"机会主义"的——只清自己 set/get 的位置周围，不保证清干净
- 如果业务后续不再访问该 ThreadLocal，永远没机会触发清理
所以**显式 remove 是唯一可靠的清理方式**。

**Q5：InheritableThreadLocal 在线程池下为什么失效？**
ITL 的拷贝发生在 `new Thread()` 时一次性。线程池线程是预先创建好的，提交任务时不创建新线程，ITL 不会重新拷贝。结果就是新提交任务看到的 ITL 是线程上次任务残留的（或线程创建时父线程的）。

**Q6：怎么实现父子线程之间 ThreadLocal 的传递？**
- 同步直接传：方法参数透传（最干净）
- 异步 + 一次性创建：InheritableThreadLocal
- 异步 + 线程池：TransmittableThreadLocal（阿里开源）

**Q7：ThreadLocalMap 用开放定址法不是用拉链，为什么？**
- 单线程访问，无并发，不需要 ConcurrentHashMap
- ThreadLocal 数量通常很少（每线程 < 10），开放定址 cache friendly
- key 是弱引用，配合"探测式清理"实现简单

**Q8：用 ThreadLocal 还是参数传递？**
能用参数传递就用参数。ThreadLocal 隐式传参，代码可读性差、调试痛苦、容易泄漏。**只在跨多层框架代码（必须无侵入）的场景用**——典型如事务上下文、用户身份、日志 MDC。

---

## 九、答题模板（90 秒话术）

> ThreadLocal 实现**线程隔离的变量**，常用于事务上下文、用户身份、日志 MDC、SimpleDateFormat 这种线程不安全对象的封装。
>
> **数据存在 Thread 对象的 threadLocals 字段**（ThreadLocalMap），ThreadLocal 只是 key——所以同一个 ThreadLocal 在不同线程读到不同值。ThreadLocalMap 用开放定址法、初始容量 16。
>
> **核心坑是内存泄漏**：Entry 的 key 是弱引用，value 是强引用。ThreadLocal 被 GC 后 key 变 null，但 value 还在，**线程池场景累积导致 OOM**。所以使用必须 `try-finally remove()`。
>
> **InheritableThreadLocal** 解决父子线程传递（Thread 创建时浅拷贝），但**线程池下失效**（线程不重新创建）。线程池场景用阿里 **TransmittableThreadLocal**——任务提交时捕获、执行前注入、执行后还原。
>
> 经典坑：
> - 线程池忘 remove → OOM
> - 线程池 + ITL → 数据串流
> - SimpleDateFormat 误以为线程安全 → 用 ThreadLocal 包

---

## 十、相关文档

- [JVM 垃圾回收](../JVM/垃圾回收.md) — 弱引用 / 软引用回收时机
- [线程池](./线程池.md) — ThreadLocal 泄漏的主要场景
- [进程与线程](./进程与线程.md) — Thread 对象结构
