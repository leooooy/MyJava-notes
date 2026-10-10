# JDK / JRE / JVM 与版本演进

> 这一题几乎是 Java 面试的"暖场题"，但答得好不好，**直接决定面试官给你定的级别**。
>
> 本篇要回答 4 件事：
> ① JDK / JRE / JVM 各是什么、关系是什么——别再背"JRE 包含 JVM"那种半截答案
> ② Oracle JDK 和 OpenJDK 到底差什么——商用授权的坑
> ③ JDK 8 / 11 / 17 / 21 怎么选——生产用什么、为什么
> ④ 关键版本特性时间线——Lambda、模块化、虚拟线程依次讲清

---

## 一、为什么这一题很重要

很多候选人开口就说"JDK = JRE + 工具，JRE = JVM + 类库"，停。然后被追问：

- 那 javac 编译完是字节码，**字节码运行时谁加载的**？
- JDK 9 开始，JRE 还单独发布吗？为什么不再独立发？
- 你说 Oracle JDK 是免费的吗？17 之后呢？
- 你们生产用 JDK 几？为什么不上 17？

这些追问考察的是对生态的真实理解，**不是教科书定义**。

---

## 二、JDK / JRE / JVM 的关系

### 2.1 三层包含关系（经典图）

```
┌─────────────────────────────────────────────────┐
│  JDK = Java Development Kit（开发工具包）       │
│  ┌───────────────────────────────────────────┐ │
│  │ 开发工具：javac / javadoc / jdb / jar /    │ │
│  │           jlink / jpackage / jshell ...    │ │
│  ├───────────────────────────────────────────┤ │
│  │ JRE = Java Runtime Environment（运行环境）│ │
│  │  ┌────────────────────────────────────┐  │ │
│  │  │ 类库：java.lang / java.util / ...   │  │ │
│  │  │       (rt.jar 在 JDK 8 及之前)      │  │ │
│  │  ├────────────────────────────────────┤  │ │
│  │  │ JVM = Java Virtual Machine          │  │ │
│  │  │  类加载器 / 执行引擎 / GC / 内存管理 │  │ │
│  │  └────────────────────────────────────┘  │ │
│  └───────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

| 层级 | 角色 | 包含 | 一句话 |
| --- | --- | --- | --- |
| **JVM** | 字节码执行引擎 | 类加载器、字节码解释器、JIT、GC、内存模型 | 跑 `.class` 的虚拟 CPU |
| **JRE** | 运行 Java 程序的最小集合 | JVM + 标准类库（Java SE API） | 部署服务器只装 JRE 就够 |
| **JDK** | 开发 Java 程序的工具集 | JRE + javac + 调试 / 打包 / 监控工具 | 写代码必装 JDK |

### 2.2 一段编译运行流程串起来

```
HelloWorld.java
       │  javac（在 JDK 里）
       ▼
HelloWorld.class（字节码）
       │  java HelloWorld
       ▼
ClassLoader（在 JVM 里）→ 加载到方法区
       │
       ▼
执行引擎（解释 + JIT）→ 调用 java.lang.System.out.println（在 JRE 里）
       │
       ▼
输出 Hello World
```

→ **javac 是 JDK 的，java 命令是 JRE 的（启动 JVM），println 是 JRE 类库的**。

### 2.3 JDK 9 之后的变化（高频追问）

JDK 9 引入**模块化（JPMS）**后：

- **不再单独发布 JRE**——你想要轻量运行环境？用 `jlink` 自己定制。
- **rt.jar 拆成多个模块**：`java.base`、`java.sql`、`java.xml` 等几十个 module。
- **运行时镜像变小**：用 jlink 裁剪后，部署一个只跑业务的 JRE 可以从 200MB 压到 40MB（容器友好）。

```bash
jlink --module-path $JAVA_HOME/jmods \
      --add-modules java.base,java.logging,java.sql \
      --output custom-jre
```

**面试加分点**：知道"JRE 不再独立发布，要用 jlink 定制"——这是 JDK 9+ 模块化的实战落地。

---

## 三、Oracle JDK vs OpenJDK

### 3.1 历史背景

```
2006: Sun 把 JDK 开源 → OpenJDK
2009: Oracle 收购 Sun → 接手 OpenJDK
2014: JDK 8 发布，Oracle JDK 个人 / 商用免费
2018-09: JDK 11 后，Oracle JDK 商用要付费 / OpenJDK 免费
2021-09: JDK 17 LTS，Oracle 改 NFTC 协议 → 17 / 21 商用 3 年内免费
```

### 3.2 区别（生产视角）

| 维度 | Oracle JDK | OpenJDK |
| --- | --- | --- |
| **代码** | 基于 OpenJDK + 少量私有补丁 | 完全开源 |
| **协议** | 旧版 Oracle BCL / 新版 NFTC | GPL v2 + Classpath Exception |
| **商用** | JDK 11–16 收费、17/21 三年免费 | **永久免费** |
| **支持** | Oracle 官方 8 年商业支持 | 社区支持 |
| **更新节奏** | 季度安全更新 | 同步 |

### 3.3 主流 OpenJDK 发行版

| 发行方 | 名字 | 特点 |
| --- | --- | --- |
| **Eclipse Adoptium** | Temurin | **首选**，原 AdoptOpenJDK，社区认证 |
| **Amazon** | Corretto | AWS 长期支持，免费 |
| **Azul** | Zulu | 商业支持完善 |
| **Microsoft** | MSFT JDK | 给 Azure 用 |
| **阿里巴巴** | Dragonwell | 国内用，针对阿里业务优化 |
| **腾讯** | Kona | 同上 |
| **Red Hat** | OpenJDK | RHEL / CentOS 自带 |

> **生产推荐**：Temurin（社区主流，无授权风险）或 Corretto（云上 + AWS 集成好）。

### 3.4 一个常见误区

> 面试官追问：你确定生产可以用 Oracle JDK 8 吗？

JDK 8 在 2019 年 1 月之后**商用要付费**——很多公司直到现在还在用 Oracle JDK 8 + `update 192` 这种老版本，没敢升级也没买授权，**法务上是有风险的**。正确做法是切到 **Temurin / Corretto** 的 JDK 8 镜像，零成本、API 完全兼容。

---

## 四、主流 LTS 版本对比

> Java 从 JDK 9 开始改成 6 个月一个版本，每 2~3 年一个 **LTS（长期支持版）**。生产**只用 LTS**。

| 维度 | JDK 8 | JDK 11 | JDK 17 | JDK 21 |
| --- | --- | --- | --- | --- |
| 发布时间 | 2014-03 | 2018-09 | 2021-09 | 2023-09 |
| 默认 GC | Parallel | **G1** | G1 | G1 |
| 最大堆压缩指针 | ≤ 32 GB | ≤ 32 GB | ≤ 32 GB | ≤ 32 GB |
| 当前商用占比（2026） | 35% | 30% | 25% | 10% |
| Oracle 免费支持到 | 2030（付费） | 2026-09 | 2029-09 | 2031-09 |

### 4.1 JDK 8 关键特性（面试必背）

```java
// 1. Lambda 表达式
list.forEach(item -> System.out.println(item));

// 2. Stream API
list.stream().filter(x -> x > 10).map(x -> x * 2).collect(Collectors.toList());

// 3. 接口 default 方法
interface Calc {
    default int doubleIt(int x) { return x * 2; }
}

// 4. Optional
Optional<User> user = Optional.ofNullable(getUser());
user.ifPresent(u -> log.info(u.getName()));

// 5. 方法引用
list.forEach(System.out::println);

// 6. CompletableFuture
CompletableFuture.supplyAsync(this::query).thenApply(this::process);

// 7. 时间 API（java.time）
LocalDate.now().plusDays(7);

// 8. Metaspace 取代永久代（PermGen）
```

### 4.2 JDK 11 关键特性

```java
// 1. var（局部变量类型推导）
var list = new ArrayList<String>();

// 2. HttpClient（替代 HttpURLConnection）
HttpClient.newHttpClient().send(...);

// 3. ZGC（实验，亚毫秒级 GC）
-XX:+UnlockExperimentalVMOptions -XX:+UseZGC

// 4. String.repeat、isBlank、lines

// 5. Files.readString / writeString

// 6. 移除 Java EE / CORBA 模块
//    java.xml.ws、java.xml.bind 都没了
```

> **JDK 8 → 11 升级最常见的坑**：Java EE 模块没了——`javax.xml.bind`（JAXB）必须自己引依赖。

### 4.3 JDK 17 关键特性

```java
// 1. sealed class（密封类，限制继承）
public sealed class Shape permits Circle, Square, Triangle {}

// 2. record（不可变数据类）
public record Point(int x, int y) {}
// 自动生成构造器、getter、equals、hashCode、toString

// 3. 文本块（多行字符串）
String json = """
    {"name": "Alice", "age": 30}
    """;

// 4. instanceof 模式匹配
if (obj instanceof String s) { System.out.println(s.length()); }

// 5. switch 表达式（预览升级到正式）
int code = switch(status) {
    case "OK" -> 200;
    case "NOT_FOUND" -> 404;
    default -> 500;
};

// 6. ZGC 正式生产可用
```

### 4.4 JDK 21 关键特性（重磅）

```java
// 1. 虚拟线程（Virtual Threads）正式 GA  ← 杀手级特性
Thread.startVirtualThread(() -> { /* 业务 */ });
// 一个 JVM 跑百万级虚拟线程不是梦

// 2. switch 模式匹配（正式）
String result = switch (obj) {
    case Integer i -> "int: " + i;
    case String s -> "str: " + s;
    case null -> "null";
    default -> "other";
};

// 3. 序列集合（SequencedCollection）
list.getFirst();   list.getLast();
list.addFirst(x);  list.removeLast();

// 4. 记录模式（Record Patterns）
if (obj instanceof Point(int x, int y)) { /* 直接拆解 */ }

// 5. 分代 ZGC（Generational ZGC）
-XX:+UseZGC -XX:+ZGenerational
```

→ JDK 21 是 **JDK 8 之后最值得升级的版本**——虚拟线程对高并发服务来说是范式级提升。

---

## 五、版本选型决策

### 5.1 现状

```
小团队 / 老项目                  → JDK 8（稳定，但要切到 Temurin）
新项目 / Spring Boot 3.x         → JDK 17（Spring Boot 3 最低要求 17）
高并发 IO 密集（网关 / 微服务）  → JDK 21（虚拟线程）
对 GC 敏感（金融、低延迟）        → JDK 17 或 21 + ZGC
```

### 5.2 升级建议

| 起点 | 终点 | 风险等级 | 关注点 |
| --- | --- | --- | --- |
| JDK 8 → 11 | 中等 | Java EE 模块、字节码版本、内部 API（sun.misc.Unsafe）、GC 切到 G1 |
| JDK 11 → 17 | 低 | sealed / record 兼容性问题少，主要看依赖库 |
| JDK 17 → 21 | 低 | 虚拟线程是新增能力，老代码不动也能跑 |
| JDK 8 → 17 直跳 | **高** | 推荐先升 11 再升 17，分两步 |

---

## 六、关键特性时间线

```
JDK 5  (2004)  ← 泛型 / 注解 / 自动装箱 / 枚举 / for-each
JDK 6  (2006)  ← 性能调优为主
JDK 7  (2011)  ← try-with-resources / Diamond / NIO.2 / 字符串 switch
JDK 8  (2014)  ← Lambda / Stream / 接口 default / Optional / java.time
JDK 9  (2017)  ← 模块化（JPMS）/ JShell / G1 默认
JDK 10 (2018)  ← var
JDK 11 (2018) LTS ← HttpClient / ZGC（实验）/ 移除 Java EE
JDK 14 (2020)  ← Helpful NPE / record（预览）
JDK 16 (2021)  ← record 正式
JDK 17 (2021) LTS ← sealed / 文本块 / 模式匹配
JDK 21 (2023) LTS ← 虚拟线程正式 / 分代 ZGC / 序列集合
JDK 25 (2025) LTS ← 持续演进中
```

---

## 七、生产踩坑

### 7.1 仍在用 Oracle JDK 8 但没买授权

**现象**：审计被发现使用 Oracle JDK 11 商用版无授权。
**根因**：JDK 11 之后 Oracle JDK **商用收费**，但运维不知道，从官网下载装上去就用。
**修复**：所有镜像切 Temurin / Corretto，CI 里加 `java -version` 检测，禁止 Oracle JDK。

### 7.2 容器里 JDK 8 没设 -Xmx，OOM Killer

**现象**：K8s Pod 内存 4GB，JDK 8 程序跑着跑着被 oomkilled。
**根因**：JDK 8 早期版本（≤ u131）**不识别 cgroup**，默认按宿主机物理内存的 1/4 算 -Xmx → 比 Pod limit 大很多 → 超 limit 被杀。
**修复**：升级到 JDK 8u191+ 或 JDK 11+，自动识别容器内存；显式设置 `-Xmx`。

### 7.3 升 JDK 11 后 JAXB 找不到

**现象**：编译过，运行时 `ClassNotFoundException: javax.xml.bind.JAXBContext`。
**根因**：JDK 11 移除了 `java.xml.bind` 模块。
**修复**：

```xml
<dependency>
    <groupId>jakarta.xml.bind</groupId>
    <artifactId>jakarta.xml.bind-api</artifactId>
    <version>4.0.0</version>
</dependency>
<dependency>
    <groupId>org.glassfish.jaxb</groupId>
    <artifactId>jaxb-runtime</artifactId>
    <version>4.0.0</version>
</dependency>
```

### 7.4 JDK 17 反射默认警告

**现象**：升级到 JDK 17，部分老库报 `InaccessibleObjectException`。
**根因**：JDK 17 默认 strong encapsulation，反射访问 `java.base` 内部 API 被禁。
**修复**：临时启用 `--add-opens java.base/java.lang=ALL-UNNAMED`，长期升级到合规库。

---

## 八、面试高频追问

### Q1：JDK、JRE、JVM 区别？

JVM 是字节码执行引擎；JRE = JVM + 标准类库（运行 Java 必需）；JDK = JRE + 开发工具（javac、jar 等）。**生产部署装 JRE，开发装 JDK**。JDK 9 后不再单独发布 JRE，需要 jlink 定制。

### Q2：javac 在哪？java 命令在哪？

javac 在 JDK 里（开发工具）；java 命令在 JRE 里，作用是启动 JVM 加载 main 方法。两者都在 `$JAVA_HOME/bin` 下，但角色完全不同。

### Q3：你们生产用什么 JDK？为什么？

诚实回答你的真实情况，可加一段**反思**：
- "我们用 Temurin JDK 17，跑 Spring Boot 3。当初从 8 升到 17，最大动力是 record + 文本块写得更清爽。"
- "原本 Oracle JDK 8，发现授权风险后切到 Corretto 8，零业务感知。"

### Q4：Oracle JDK 和 OpenJDK 一样吗？

代码 99% 一样（OpenJDK 是 Oracle JDK 的开源源头）；区别在**授权**——Oracle JDK 11+ 商用收费，OpenJDK 永久免费。**生产只用 OpenJDK 发行版**（Temurin / Corretto / Zulu）。

### Q5：JDK 8 到 17 关键升级点？

- 默认 GC：Parallel → **G1**
- 永久代 → 元空间（JDK 8 已变）
- Java EE 模块（JAXB / JAX-WS）被移除（JDK 11）
- record / sealed / 文本块 / 模式匹配（JDK 17）
- Spring Boot 3 最低要求 JDK 17

### Q6：你了解虚拟线程吗？

JDK 21 GA。JVM 自己实现的轻量级线程，调度由 JVM（不是 OS）完成；阻塞 IO 时**自动让出 carrier 线程**——一个 JVM 可以跑百万虚拟线程，**对网关 / 微服务这种 IO 密集型场景**是降维打击。但**死循环、CPU 密集、`synchronized` 长持锁** 会阻塞 carrier 线程，要用 `ReentrantLock` 替代。

### Q7：JIT、AOT 和 GraalVM Native Image？

JIT（Just-In-Time）：运行时把热点字节码编译成机器码（C2 / Graal 编译器）。
AOT（Ahead-Of-Time）：编译期就把字节码 → 机器码，启动快但缺优化（无 profile-guided）。
GraalVM Native Image：把 Java 程序编译成单个原生可执行文件，**启动 ms 级、内存占用 1/10**，但反射 / 动态代理要配置元数据，不适合所有场景。Spring Boot 3 + GraalVM 是当前 Serverless 的主流方案。

### Q8：JDK 9 模块化（JPMS）解决了什么？

- 减小 JRE 体积（jlink 裁剪）
- 强封装内部 API（sun.misc.Unsafe 不再随便访问）
- 解决 jar hell（明确依赖关系）
- 但**业务代码很少用**，主要是 JDK 自己用——所以面试只要知道概念就够。

---

## 九、答题模板（60 秒话术）

> JDK 是开发工具包，包含 JRE 加 javac 等工具；JRE 是运行环境，包含 JVM 加标准类库；JVM 是字节码执行引擎。**JDK 9 之后不再单独发布 JRE**，要轻量运行环境用 jlink 自己裁剪。
>
> 生产建议用 **OpenJDK 发行版**（Temurin / Corretto），不用 Oracle JDK——JDK 11+ 商用要授权。
>
> 主流 LTS 是 **8 / 11 / 17 / 21**，新项目优先 **17**（Spring Boot 3 起点）或 **21**（要虚拟线程）。从 8 升到 17 最主要的几个变化：默认 GC 从 Parallel 切到 **G1**，永久代换成 **元空间**，Java EE 模块被移除（JAXB 要单独引），加了 **record / sealed / 文本块 / 模式匹配** 等新语法。
>
> JDK 21 的杀手级特性是 **虚拟线程**——IO 密集场景百万并发，但 synchronized 长持锁要换成 ReentrantLock。

---

## 十、相关文档

- [Object 类](./Object类.md) — Object 是所有类的父类，每个 Java 程序都依赖它
- [JVM 模块](../JVM/README.md) — JVM 是这一题的下一层细节
- [JVM 参数](../JVM/jvm参数.md) — 不同 JDK 默认参数差异
- [收集器全景](../JVM/收集器全景.md) — 默认 GC 的演进
- [虚拟线程](../Concurrency/虚拟线程.md) — JDK 21 的核心特性
