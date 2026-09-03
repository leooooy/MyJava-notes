# JIT 编译器与逃逸分析

> 高频追问链:"为什么 Java 跑久了反而变快"→ JIT → 分层编译 → 热点探测 → 内联 → **逃逸分析** → 栈上分配 / 标量替换 / 锁消除 → 反优化 → Code Cache。
>
> 本篇解决:① 解释执行 vs JIT 编译的边界;② C1 / C2 / Graal 分层编译;③ 热点探测怎么算"热";④ 方法内联的收益与限制;⑤ 逃逸分析的三种状态;⑥ 栈上分配 / 标量替换 / 锁消除的真实效果;⑦ Code Cache 的容量陷阱;⑧ JITWatch / PrintCompilation 诊断。

---

## 一、为什么需要 JIT

### 1.1 解释执行的痛点

JVM 启动时,字节码靠**解释器**逐条翻译为机器指令——可移植性强,但慢:

```
字节码: iload_1; iload_2; iadd; istore_3
   │
   ▼
解释器: switch (opcode) { case ILOAD: ...; case IADD: ...; }
   │
   ▼
每条指令都要查表 + 调度——比直接跑机器码慢一个数量级
```

### 1.2 JIT 的解法

JVM 边运行边把**热点代码**编译成本地机器码,直接执行:

```
冷代码 → 解释执行(启动快)
   │
   ▼ 热点探测
热代码 → JIT 编译为机器码 → 直接执行(运行快)
   │
   ▼ 极热代码
进一步优化(C2 / Graal):内联 + 逃逸分析 + 向量化 + ...
```

→ **HotSpot 这个名字就是从"热点编译"来的**。

### 1.3 "Java 跑久了反而变快"的根因

```
启动 30s          → 解释执行,QPS 100
跑 5 分钟        → C1 编译完成,QPS 800
跑 30 分钟        → C2 深度优化,QPS 5000
```

→ 这就是为什么 **Java 服务必须预热**——上线先空跑流量让 JIT 编译完,再切真实流量。否则启动后第一波流量秒级延迟。

---

## 二、分层编译(Tiered Compilation)

> JDK 7+ 默认开启,JDK 8 起强制(无法关闭分层只用 C2)。

### 2.1 五个编译层级

```
Level 0: 解释执行(Interpreter)
    │
    ▼ 触发条件:方法调用次数到达阈值
Level 1: C1 编译,无 profiling(简单优化)
Level 2: C1 编译,有限 profiling(收集调用次数 + 回边次数)
Level 3: C1 编译,完整 profiling(收集所有数据)
    │
    ▼ 收集到足够数据
Level 4: C2 编译,深度优化(基于 profiling 数据做激进优化)
```

**典型路径**:
```
解释 (L0) → C1 完整 profiling (L3) → C2 深度优化 (L4)
              │
              └ 大方法 / C2 队列满 → 直接走 L1 / L2
```

### 2.2 C1 vs C2

| | C1(Client / 客户端编译器) | C2(Server / 服务端编译器) |
| --- | --- | --- |
| 编译速度 | 快 | 慢 |
| 优化力度 | 简单优化(常量折叠、CSE、内联小方法) | **深度激进优化**(逃逸分析、向量化、循环展开) |
| 启动 | 早 | 晚 |
| 代码质量 | 中 | **高** |
| 触发阈值 | 较低 | 较高 |

**为什么不直接 C2**:C2 编译慢(可能几十 ms 到几秒),启动期会卡顿;C1 先跑起来,C2 慢慢编译热点。

### 2.3 Graal —— 下一代 C2

JDK 9 引入实验性 Graal 编译器(Java 写的 JIT,代码可读性好):

```bash
-XX:+UnlockExperimentalVMOptions
-XX:+UseJVMCICompiler                  # 用 Graal 替代 C2
```

**优势**:对函数式代码 / Lambda / Stream 优化更激进。
**劣势**:稳定性早期不如 C2;**JDK 17 起 Oracle 移除内置 Graal**(改作 GraalVM 独立产品)。

---

## 三、热点探测(Hot Spot Detection)

> JIT 怎么判断"哪段代码是热点"?

### 3.1 两个计数器

每个方法维护两个计数器:

| 计数器 | 触发什么 |
| --- | --- |
| **方法调用计数器**(Invocation Counter) | 方法被调用次数 |
| **回边计数器**(Back Edge Counter) | 循环回跳次数(检测热点循环) |

**任一计数器达到阈值** → 触发 JIT 编译。

阈值参数:
```bash
-XX:CompileThreshold=10000         # C2 调用阈值(默认 10000)
                                   # C1 默认 1500
-XX:OnStackReplacePercentage=140   # 回边阈值百分比
```

### 3.2 OSR(On-Stack Replacement)—— 栈上替换

> 经典面试陷阱:"一个方法只跑一次,但里面有 1000 万次循环——会被 JIT 吗?"

会——靠 **OSR**:

```
public void m() {              // 方法只调一次,不会触发方法计数器
    for (int i = 0; i < 1e7; i++) {
        // 回边计数器累加 → 达到阈值 → 触发 OSR
    }
}
```

OSR 的特殊之处:**在循环执行中途**把当前栈帧"替换"成编译后的版本,继续在新代码里跑——**栈上替换**。

**典型场景**:启动时的初始化循环、跑批 ETL 任务里的大循环。

### 3.3 计数器衰减

调用次数会**随时间衰减**——避免冷代码因为长期偶尔调用而被错误标热。
JDK 8 后这个机制有所削弱(分层编译里更看相对热度)。

---

## 四、方法内联(Inlining)

> JIT **最重要的优化**,是其它优化的前提——内联后逃逸分析、循环展开、常量传播才能跨方法生效。

### 4.1 是什么

```java
int add(int a, int b) { return a + b; }

void calc() {
    int c = add(1, 2);    // 内联后等价: int c = 1 + 2;  → 进一步常量折叠为 int c = 3;
}
```

把被调方法的代码"嵌入"到调用方,**省掉栈帧创建 / 参数压栈 / 跳转 / 返回**。

### 4.2 内联的限制

| 限制 | 阈值 | 参数 |
| --- | --- | --- |
| 方法字节码大小(普通) | ≤ 35 B | -XX:MaxInlineSize=35 |
| 热方法字节码大小 | ≤ 325 B | -XX:FreqInlineSize=325 |
| 调用栈深度 | ≤ 9 | -XX:MaxInlineLevel=9 |
| 方法被调次数 | ≥ 一定次数 | — |
| **必须能确定具体调用目标** | — | 关键限制 ↓ |

### 4.3 多态调用为什么难内联

```java
interface Animal { void sound(); }

void play(Animal a) {
    a.sound();    // 不知道实际是 Dog 还是 Cat → invokevirtual
}
```

JIT 不知道运行时 `a` 是谁,内联不了。

**HotSpot 的解法**:
- **CHA(Class Hierarchy Analysis)**:运行时若发现 Animal 只有 Dog 一个实现 → 单态 → 直接内联 Dog.sound()
- **多态内联缓存(Inline Cache)**:记录最近 1~2 个具体类型,大概率命中就内联;不命中走慢路径
- **去虚化(Devirtualization)**:把 invokevirtual 改写成 invokestatic

→ **写代码尽量让方法保持单态(只有一个实现)**——这是 JIT 优化的友好姿势。

### 4.4 final / private / static 方法天生易内联

这三种方法**调用目标编译期可定**,不需要 CHA → JIT 直接内联。
所以早期"性能优化"教程总说"加 final"——现代 JIT 通过 CHA 几乎能识别所有实际单态方法,加 final 收益已经不大,但**可读性 + 避免覆盖**的角度仍推荐。

### 4.5 看内联决策

```bash
-XX:+UnlockDiagnosticVMOptions
-XX:+PrintInlining
```

输出例子:
```
@ 12   com.foo.Service::doWork (15 bytes)   inline (hot)
@ 18   com.foo.Helper::heavy (350 bytes)    too big
@ 25   com.foo.IFace::call (4 bytes)        not inlineable: virtual call
```

---

## 五、逃逸分析(Escape Analysis)

> JIT 优化的**杀手锏**——分析对象作用域是否"逃逸"出方法或线程,决定能否做激进优化。

### 5.1 三种逃逸状态

```
不逃逸(NoEscape)
   └─ 对象只在当前方法里用,不会被外部访问
        → 可以栈上分配 / 标量替换

方法逃逸(MethodEscape / ArgEscape)
   └─ 对象作为参数传给其它方法,但不会被外部线程引用
        → 不能栈上分配,可以做部分优化

线程逃逸(GlobalEscape)
   └─ 对象赋给静态字段 / 实例字段,可能被其它线程访问
        → 不能做任何激进优化
```

### 5.2 怎么算逃逸

```java
// 不逃逸 ✅
void f1() {
    StringBuilder sb = new StringBuilder();
    sb.append("a");
    System.out.println(sb.toString());   // sb 只在方法内
}

// 方法逃逸
void f2() {
    StringBuilder sb = new StringBuilder();
    helper(sb);                          // 传给其它方法,可能被持有
}

// 线程逃逸 ❌
static StringBuilder GLOBAL;
void f3() {
    StringBuilder sb = new StringBuilder();
    GLOBAL = sb;                         // 赋给静态变量,其它线程能访问
}
```

### 5.3 启用与查看

```bash
-XX:+DoEscapeAnalysis              # 默认开
-XX:+PrintEscapeAnalysis           # 打印分析结果(需 DiagnosticVMOptions)
-XX:+EliminateAllocations          # 启用标量替换(默认开)
-XX:+EliminateLocks                # 启用锁消除(默认开)
```

---

## 六、逃逸分析催生的三大优化

### 6.1 栈上分配(Stack Allocation)

> 严格说,HotSpot **没有真正的栈上分配** —— 通过**标量替换**实现等效效果。

理论上,不逃逸对象可以分配在栈帧里,方法返回时随栈帧自动销毁——**完全不进堆,GC 不管**。

但 HotSpot 走了一条更激进的路:把对象**完全拆解**,根本不存在"对象"这个东西(看下一节)。

### 6.2 标量替换(Scalar Replacement)

> HotSpot 实际做的事——比栈上分配更彻底。

```java
class Point { int x; int y; }

void f() {
    Point p = new Point();
    p.x = 10;
    p.y = 20;
    System.out.println(p.x + p.y);
}

// 标量替换后等价于:
void f() {
    int x = 10;          // 对象拆成两个 int 局部变量
    int y = 20;          // 直接进寄存器/栈
    System.out.println(x + y);
}
                        // 根本没分配 Point 对象
```

**收益**:
- 零分配 → 不增加 GC 压力
- 字段进寄存器 → 比内存访问快百倍
- 配合后续优化(常量折叠 → 直接算出 30)

### 6.3 锁消除(Lock Elimination)

> 没有线程逃逸的对象,锁是无意义的——**JIT 直接擦除**。

```java
String concat(String a, String b, String c) {
    StringBuffer sb = new StringBuffer();
    sb.append(a);
    sb.append(b);
    sb.append(c);
    return sb.toString();
}
```

`StringBuffer.append` 内部是 `synchronized`——但 sb 不逃逸,只有当前线程能访问 → JIT **消除 synchronized**,变成 StringBuilder 一样快。

→ 这就是为什么"现代 JIT 让 StringBuffer 和 StringBuilder 性能差距几乎为零"——但**还是用 StringBuilder**(显式表意)。

### 6.4 锁粗化(Lock Coarsening)

> 短时间内反复加同一把锁 → JIT 把外层合并成一个大锁。

```java
for (int i = 0; i < 1000; i++) {
    synchronized (lock) {              // 反复加锁解锁
        ...
    }
}

// 锁粗化后等价于:
synchronized (lock) {
    for (int i = 0; i < 1000; i++) {
        ...
    }
}
```

**收益**:省掉 1000 次加锁开销。
**代价**:临界区变大,其他线程等待时间变长——**JIT 会权衡,通常只对小循环有效**。

---

## 七、Code Cache —— JIT 编译产物的家

### 7.1 是什么

JIT 编译后的本地机器码存在 **Code Cache** 区,**不在堆 / 不在元空间** —— 单独的内存区。

```bash
-XX:InitialCodeCacheSize=64m        # 初始
-XX:ReservedCodeCacheSize=240m      # 上限(JDK 8 默认 240MB)
-XX:+SegmentedCodeCache             # JDK 9+ 默认开,分三段(non-method/profiled/non-profiled)
```

### 7.2 Code Cache 满了会怎样

```
WARNING: CodeCache is full. Compiler has been disabled.
WARNING: Try increasing the code cache size using -XX:ReservedCodeCacheSize=
```

**严重后果**:
- JIT 停止编译——新热点回退到解释执行
- **性能断崖式下降**(可能 QPS 降一个数量级)
- 已编译的代码继续跑,但失去优化机会

**根因**:
- 代码量大(微服务多 + 各种代理 / Lambda / 反射生成的类)
- 老 JDK 8 默认只 240MB 不够现代应用

**修复**:
```bash
-XX:ReservedCodeCacheSize=512m      # 大型应用建议 512m~1g
-XX:+UseCodeCacheFlushing           # 满了自动清理冷代码(默认开)
```

### 7.3 监控

```bash
jcmd <pid> Compiler.codecache       # 看 Code Cache 使用
jstat -compiler <pid>                # 编译统计
jstat -printcompilation <pid> 1000   # 实时看编译事件
```

---

## 八、反优化(Deoptimization)

> JIT 的乐观优化——基于"假设"做激进优化,假设不成立时**退回解释执行**。

### 8.1 触发反优化的场景

| 场景 | 例子 |
| --- | --- |
| 多态推断失败 | CHA 假设单态,运行时加载新实现类 |
| 类型推断失败 | profiling 假设 List 总是 ArrayList,实际收到 LinkedList |
| 异常分支被走到 | profiling 假设某 catch 永远不进,实际进了 |
| 类卸载 | 内联的方法所属类被卸载 |

### 8.2 反优化代价

```
JIT 编译版本 → 检测到假设失败 → 抛弃机器码 → 退回解释执行 → 重新 profile → 重新编译
```

**典型现象**:服务跑得好好的,某个新功能上线后某段代码 QPS 暴跌——可能是反优化频繁。

```bash
-XX:+PrintCompilation
# 看输出里是否频繁出现 made not entrant / made zombie
```

---

## 九、AOT 与 GraalVM Native Image

> 与 JIT 相反:**Ahead-Of-Time** —— 提前把 Java 编译成本地可执行文件。

### 9.1 痛点:JIT 启动慢

云原生场景(Serverless / 短期任务):
- 启动 → 解释执行慢
- 跑了几十秒终于 JIT 完
- 但任务也跑完了
- → JIT 优化白费

### 9.2 GraalVM Native Image

```bash
native-image -jar app.jar
# 生成本地二进制 ./app
./app
# 启动 50ms vs JVM 启动 3s
# 内存占用 50MB vs JVM 500MB
```

**优势**:启动快、内存少、无 JIT 暖机。
**劣势**:
- 编译慢(几分钟)
- 反射 / 动态代理需要配置文件提前声明(closed-world assumption)
- **峰值吞吐通常低于 JIT**(JIT 跑久了能基于 profiling 比 AOT 优化得更好)
- 兼容性陷阱(部分库不工作)

→ **适合**:Serverless 函数、CLI 工具、Spring Native / Quarkus / Micronaut 框架。
→ **不适合**:长期运行的高吞吐服务。

### 9.3 ProjectAOT(JDK 9 实验)

JDK 9 引入 `jaotc` 工具试图集成 AOT 进 JDK,**JDK 17 已废弃**。这条路 Oracle 让位给了 GraalVM Native Image。

---

## 十、生产踩坑

### 10.1 服务上线第一波请求超时

**现象**:服务发布完接受流量,前 30 秒~ 2 分钟 P99 超时。

**根因**:JIT 还没编译完热点代码,全在解释执行。

**修复**:
1. **预热**:发布后用脚本 / SLB 流量回放发暖机请求,等 JIT 完成再接真流量
2. **JFR 监控编译进度**:`-XX:StartFlightRecording=...`
3. **AppCDS**:Class Data Sharing,加快类加载和元数据预备:
   ```bash
   -XX:ArchiveClassesAtExit=app.jsa     # JDK 13+
   -XX:SharedArchiveFile=app.jsa
   ```

### 10.2 Code Cache 满导致性能崩盘

**现象**:服务跑了几天后突然 QPS 腰斩,没有 GC 异常,无 OOM。

**根因**:Code Cache 240MB(JDK 8 默认)用满,JIT 停编译。

**排查**:
```bash
jcmd <pid> Compiler.codecache
# 看 used / max
```

**修复**:`-XX:ReservedCodeCacheSize=512m`。

### 10.3 反优化抖动

**现象**:某段代码 QPS 周期性飙降,GC 没问题。

**根因**:某次调用类型变化导致反优化 → 重新编译 → 又遇到新类型 → 再反优化……循环。

**排查**:
```bash
-XX:+PrintCompilation
# 频繁的 "made not entrant" 是反优化标志
```

**修复**:看具体业务,通常是某个接口的多态实现太多,改成更稳定的设计。

### 10.4 -XX:-TieredCompilation 错误关闭

老教程里有"`关闭分层编译让 C2 直接编译,提升性能`"——**错误!**

JDK 8+ 的 C2 强依赖 C1 的 profiling 数据;关掉分层 → C2 没数据 → 优化质量大幅下降 → 启动还慢。

→ **不要关分层编译**。

### 10.5 反射 / 动态代理打爆 JIT

```java
// 频繁创建动态代理类 → 每个新类都触发新一轮 JIT 编译
for (int i = 0; i < 10000; i++) {
    Object proxy = Proxy.newProxyInstance(...);
}
```

CodeCache 飙升 + Metaspace 飙升,可能触发 Code Cache 满。

**修复**:缓存 Proxy 实例 / 用编译时生成代码替代运行时生成。

---

## 十一、JIT 诊断工具

### 11.1 PrintCompilation(基础)

```bash
-XX:+PrintCompilation
```

输出:
```
123  45    n  java.lang.System::currentTimeMillis (native)
234  46  3   com.foo.Service::doWork (123 bytes)
345  47  4   com.foo.Service::doWork (123 bytes)        ← Level 4(C2)编译
456  46  3   com.foo.Service::doWork (123 bytes)   made not entrant   ← 反优化
```

字段:`时间戳 编译ID 标志位 层级 方法名 字节码大小 状态`。

### 11.2 PrintInlining

```bash
-XX:+UnlockDiagnosticVMOptions
-XX:+PrintInlining
```

看每个方法是否被内联、为什么不内联。

### 11.3 PrintAssembly(看汇编)

```bash
-XX:+UnlockDiagnosticVMOptions
-XX:+PrintAssembly
# 需要 hsdis 库
```

直接看 JIT 生成的机器码——除非做深度优化,否则不需要。

### 11.4 JITWatch(GUI)

```bash
# 启动加日志
-XX:+UnlockDiagnosticVMOptions
-XX:+TraceClassLoading
-XX:+LogCompilation
-XX:LogFile=jit.log

# 用 JITWatch 打开 jit.log
# https://github.com/AdoptOpenJDK/jitwatch
```

**强烈推荐**——可视化看编译决策、内联链、反优化原因,排查 JIT 问题神器。

### 11.5 JFR

```bash
-XX:StartFlightRecording=duration=120s,filename=jfr.jfr
# JMC 打开,JIT Compilation 视图
```

---

## 十二、面试高频追问

### Q1:为什么 Java 跑久了反而变快?

JIT(Just-In-Time Compiler)边运行边把热点代码编译成本地机器码——刚启动是解释执行(慢),热点被识别后编译成机器码(快),C2 / Graal 进一步深度优化(更快)。这就是 HotSpot 名字的由来。

### Q2:解释执行和 JIT 编译怎么切换?

冷代码:解释器执行(慢但启动快、占内存少)。
热代码:JIT 编译成机器码,直接跑机器码。
判断标准:方法调用计数器 + 回边计数器达到阈值。

### Q3:C1 和 C2 区别?

- C1(客户端编译器):快编译、轻优化、早出代码
- C2(服务端编译器):慢编译、重度优化(逃逸分析 / 向量化 / 循环展开)、代码质量高

JDK 7+ 默认**分层编译**——C1 先出来跑,C2 慢慢编译热点。

### Q4:什么是 OSR?

On-Stack Replacement,**栈上替换**——一个方法只调一次但内部有大循环时,JVM 不能等方法返回再编译,而是在循环执行中途把当前栈帧替换成编译后的版本继续跑。

### Q5:方法内联是什么?有什么收益?

把被调方法的代码直接嵌入调用方,省掉栈帧创建 / 参数压栈 / 跳转 / 返回。
**更重要的**:内联后逃逸分析、常量折叠、循环展开等优化才能跨方法生效——是其它 JIT 优化的前置条件。

### Q6:多态调用能内联吗?

虚方法 / 接口方法默认不能,但 HotSpot 通过:
- **CHA(类层次分析)**:发现实际只有一个实现 → 直接内联
- **多态内联缓存**:记录最近 1~2 种类型,大概率命中就内联
- **去虚化**:把 invokevirtual 改写成 invokestatic

→ 代码尽量保持单态实现对 JIT 最友好。

### Q7:逃逸分析是什么?三种状态?

分析对象的作用域是否逃出方法或线程:
- **不逃逸**:只在方法内用 → 可栈上分配 / 标量替换 / 锁消除
- **方法逃逸**:作为参数传给其它方法 → 部分优化
- **线程逃逸**:赋给静态字段 / 实例字段 → 不能做激进优化

### Q8:HotSpot 真有"栈上分配"吗?

严格说**没有真正的栈上分配** —— HotSpot 通过**标量替换**实现等效效果:把不逃逸对象彻底拆成几个局部变量,根本不存在"对象"这个东西。比真栈上分配更彻底。

### Q9:锁消除什么时候生效?

JIT 发现 synchronized 锁住的对象不会逃逸到其它线程 → 锁是无意义的 → 直接擦除。
经典例子:`StringBuffer` 内部是 synchronized,但 sb 是局部变量不逃逸 → 锁被消除 → 性能等同 StringBuilder。

### Q10:Code Cache 是什么?满了会怎样?

存放 JIT 编译产物的内存区,不在堆 / 不在元空间。
满了:JIT 停止编译,新热点回退解释执行,**性能断崖式下降**。
JDK 8 默认 240MB,大型微服务建议 `-XX:ReservedCodeCacheSize=512m`。

### Q11:什么是反优化?

JIT 基于"假设"做激进优化(如假设某个方法是单态),假设不成立时(后来加载了新实现类)→ 抛弃机器码退回解释执行 → 重新 profile → 重新编译。
反优化频繁会导致性能抖动。

### Q12:JIT 和 AOT 区别?适用场景?

- **JIT**:运行时编译,基于 profiling 做激进优化,峰值性能高,但启动慢、有暖机期
- **AOT**(GraalVM Native Image):提前编译成本地二进制,启动快(50ms vs 3s)、内存少,但峰值吞吐通常不如 JIT,且反射等需要配置文件

适用:JIT 适合长期运行高吞吐服务;AOT 适合 Serverless / CLI / 启动敏感场景。

### Q13:加 final 能提升性能吗?

历史上有效——final 方法编译期能确定调用目标,易内联。
**现代 JIT 通过 CHA 几乎能识别所有实际单态方法**,加 final 收益已经不大,但仍推荐(可读性 + 防止覆盖)。

### Q14:为什么不直接用 C2 跳过 C1?

JDK 8+ 的 C2 **强依赖 C1 的 profiling 数据**——关掉 C1 → C2 没数据 → 优化质量大幅下降 + 启动反而变慢。
**不要 `-XX:-TieredCompilation`**(老教程的错误建议)。

### Q15:启动慢怎么办?

四个方向:
1. **预热**:上线后先发暖机请求让 JIT 编译完
2. **AppCDS**:JDK 13+ 的 Class Data Sharing,加快类加载
3. **Native Image**:GraalVM 编译成本地二进制(适合短期任务)
4. **ReadyAOT(JDK 9 实验,JDK 17 废弃)**:已无前途,改用 Graal

---

## 十三、答题模板(90 秒话术)

> JVM 启动时字节码靠**解释器**逐条翻译机器指令——慢但启动快。**JIT** 边运行边把热点代码编译成本地机器码——这就是 HotSpot 名字的由来,也是"Java 跑久了反而变快"的根因。
>
> JDK 7+ 默认**分层编译**:**Level 0 解释 → L1~L3 C1(轻优化、收 profiling)→ L4 C2(基于 profiling 深度优化)**。C1 快出代码,C2 跑深度优化。
>
> **热点判断**:方法调用计数器 + 回边计数器达到阈值就编译;只跑一次但有大循环的方法靠 **OSR(栈上替换)** 在循环中途切换到编译版本。
>
> **JIT 最重要的优化是方法内联**——它是其它优化(常量折叠、逃逸分析、循环展开)能跨方法生效的前提。多态调用通过 **CHA + 多态内联缓存 + 去虚化** 优化。代码保持单态对 JIT 最友好。
>
> **逃逸分析**判断对象是否"逃出"方法或线程,催生三大优化:**标量替换**(不逃逸对象拆成局部变量,根本不分配 → HotSpot 没有真正的栈上分配,标量替换更彻底)、**锁消除**(StringBuffer 局部变量的 synchronized 被擦)、**锁粗化**(连续小锁合并成大锁)。
>
> **Code Cache** 是 JIT 编译产物的家(不在堆 / 元空间),JDK 8 默认 240MB,**满了 JIT 停编译,QPS 断崖式下降**——大型应用必须调大到 `512m+`。
>
> **反优化**:JIT 基于假设做激进优化,假设破灭(如发现新实现类破坏了 CHA 单态假设)就抛弃机器码退回解释执行,频繁反优化会导致性能抖动。
>
> **AOT / GraalVM Native Image** 走相反路线——提前编译成本地二进制,启动 50ms vs JVM 3s,适合 Serverless / CLI,但峰值吞吐不如 JIT。

---

## 十四、相关文档

- [对象在内存中的布局](./对象在内存中的布局.md) — 标量替换怎么拆解对象
- [垃圾回收](./垃圾回收.md) — JIT 优化间接降低 GC 压力
- [JVM 参数](./jvm参数.md) — JIT 相关参数完整清单
- [JVM 调优](./jvm调优.md) — JIT 相关调优案例
- [线上问题排查](./线上问题排查.md) — JITWatch / PrintCompilation 诊断
- [Synchronized](../Concurrency/Synchronized.md) — 锁消除作用于哪些锁
