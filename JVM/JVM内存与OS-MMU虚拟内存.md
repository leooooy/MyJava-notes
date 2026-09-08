# JVM 内存与 OS：MMU / 虚拟内存

> Java 工程师每天写 `new byte[1024]`，但**这个地址是怎么落到物理内存上的**——大多数人讲不清。本篇从 **MMU + Cache（TLB）** 两个角度做最小化介绍，目标是建立"虚拟地址 → 物理地址"的清晰心智模型，为后续看懂 RSS 虚高、HugePage 调优、ZGC 染色指针打地基。
>
> 本篇只解决：
> ① **MMU 是什么、怎么工作**（硬件翻译单元 + 页表）
> ② **TLB 是 MMU 的 cache**——为什么没它 CPU 跑不动
> ③ **缺页中断**——`new` 一块大内存为什么不立刻占物理页
> ④ JVM 工程师必知的 4 个内存指标：**VSZ / Reserved / Committed / RSS**
>
> ⚠️ 注意分层：本篇是 **OS 硬件层**，与 [JMM 内存模型](../Concurrency/JMM内存模型.md)（语言层多线程语义）、[运行时数据区](./内存区域.md)（JVM 进程内的逻辑划分）不在同一层。三篇配套读完，整条 "Java 代码 → JVM → OS → 物理内存" 链路就通了。

---

## 一、为什么需要虚拟内存

裸机时代进程直接操作物理地址 → 进程间无隔离、内存不够用、地址必须编译期固定。**虚拟内存**给每个进程一个独立的 0 ~ 2^48 字节虚拟地址空间，带来 4 个核心收益：

| 收益 | 说明 |
| --- | --- |
| **隔离** | 进程 A 的野指针打不到进程 B |
| **超额分配（overcommit）** | 16GB 物理内存能跑总和 100GB 的多进程 |
| **按需加载** | `new byte[1G]` 只占虚拟地址，访问才分配物理页 |
| **共享与 COW** | fork 后父子共享页，写时复制（Redis 持久化的基础） |

**JVM 视角**：`-Xmx8g` 给 JVM 8GB **虚拟**地址，但**不等于立刻占 8GB 物理内存**——这是后面所有 "RSS 虚高"、"容器 OOM" 的根源。

---

## 二、MMU：硬件地址翻译单元

```
       Java 代码                  arr[0] = 1;
          │
          ▼
       虚拟地址                   0x00007f8a4c001000   (48 位)
          │
          ▼
   ┌────────────────┐
   │     MMU        │   ← 硬件单元，CPU 自带，每次访存自动触发
   │  地址翻译引擎   │
   └────────────────┘
          │
          ├── 先查 TLB（cache） ──→ 命中 → 直接拿到物理地址
          │                       miss
          ▼
   ┌────────────────┐
   │  Page Table    │   ← OS 维护的页表（存在内存里）
   └────────────────┘
          │
          ▼
       物理地址                  0x000000023f80c000
          │
          ▼
       DRAM
```

**记住三件套**：

| 组件 | 位置 | 作用 |
| --- | --- | --- |
| **MMU** | CPU 硬件 | 每次访存自动把虚拟地址翻译成物理地址 |
| **页表（Page Table）** | 内存 | 由 OS 维护的虚→物映射表 |
| **TLB** | CPU 硬件 | 缓存页表项的 cache（详见下一节） |

### 2.1 多级页表（一句话理解）

单级页表会占 **512GB**——一个进程都装不下。所以 x86_64 用 **4 级页表**，按需创建子表（没用到的虚拟地址区间根本不分配中间表），实际占用通常只几 MB。

**代价**：TLB miss 时，硬件要走完 4 级才能拿到物理地址 → **一次 miss = 4 次内存访问**。这就是为什么 TLB 这么关键。

---

## 三、局部性原理：所有 Cache 能 Work 的根本

> **为什么 TLB / CPU cache / Buffer Pool 都能命中？** 因为程序访问内存有规律——这条规律叫 **局部性原理（Principle of Locality）**，是 1968 年 Peter Denning 提出、所有 cache 体系的理论基石。**没有局部性，cache 命中率会等于容量比，cache 形同虚设**。

### 3.1 两种局部性

| 类型 | 含义 | Java 例子 |
| --- | --- | --- |
| **时间局部性**（Temporal Locality） | 刚访问过的数据，很快会**再次**访问 | for 循环反复读同一变量；JIT 热点方法；近期 GC 存活的对象 |
| **空间局部性**（Spatial Locality） | 访问了 A，A **附近**的数据大概率也被访问 | 数组顺序遍历；对象字段访问；ArrayList 扩容拷贝 |

**衍生概念**：**顺序局部性**（Sequential Locality）是空间局部性的特例——访问 A 之后下一个就是 A+1（最强、最可预测）。CPU 预取器（Prefetcher）专门针对它工作。

### 3.2 整个 cache 体系都靠它

| 层 | 时间局部性如何用 | 空间局部性如何用 |
| --- | --- | --- |
| **CPU L1/L2/L3** | LRU 留住热数据 | **一次拉 cache line = 64B**（不是按字节读） |
| **TLB** | 留住最近翻译过的页表项 | HugePage 把单条 TLB 覆盖范围放大 512× |
| **JIT Code Cache** | 留住热点方法的本地代码 | 同方法的指令物理相邻、利于 iTLB / iCache |
| **JVM TLAB** | 线程局部分配，对象集中 | 同一批新对象物理相邻、cache 友好 |
| **MySQL Buffer Pool** | LRU 留住热页 | **预读（read-ahead）一次拉 N 页** |
| **OS PageCache** | LRU 留住热文件页 | `readahead` 一次预读多页 |
| **Redis** | 整个进程就是一个 cache | — |

**记住一句话**：**几乎所有"性能优化"动作的本质都是在利用局部性**——要么提升时间局部性（让热数据更集中），要么提升空间局部性（让相关数据物理相邻）。

### 3.3 Java 代码层面怎么利用

**正例**（顺序访问，空间局部性 + CPU 预取）：

```java
int[] arr = new int[1_000_000];
long sum = 0;
for (int i = 0; i < arr.length; i++) sum += arr[i];   // 一次 cache line 拉 16 个 int
```

**反例**（指针追逐，空间局部性极差）：

```java
// LinkedList 每个 Node 散落在堆里不同位置
for (Node n = head; n != null; n = n.next) sum += n.val;   // 每跳一次大概率 cache miss
```

> **经验数据**：同样 100 万元素求和，`int[]` 顺序遍历 ~1ms，`LinkedList<Integer>` 遍历 ~10~20ms——**5~20 倍差距，主因是空间局部性 + 装箱**。这也是为什么 `ArrayList` 在大多数场景应该是默认选择。

**二维数组的"行优先"陷阱**：

```java
int[][] m = new int[1024][1024];
// ✅ 行优先（Java 内存顺序）—— 空间局部性强
for (int i = 0; i < 1024; i++)
    for (int j = 0; j < 1024; j++) sum += m[i][j];

// ❌ 列优先 —— 每次跳 4KB，cache 全 miss
for (int j = 0; j < 1024; j++)
    for (int i = 0; i < 1024; i++) sum += m[i][j];
```

两种写法逻辑等价，但实测前者比后者快 **5~10 倍**——纯粹空间局部性差异。

### 3.4 局部性的"副作用"：伪共享

空间局部性是好事，但有时把**逻辑无关的两个字段**塞到同一 cache line（64B）会出问题：

```java
class Counter {
    long a;   // 线程 A 频繁改
    long b;   // 线程 B 频繁改
}             // a 和 b 在同一 cache line → A 改 a 会让 B 的 cache line 失效
```

这就是**伪共享（False Sharing）**——空间局部性反过来咬人。详见 [伪共享与缓存一致性](../Concurrency/伪共享与缓存一致性.md)。

---

## 四、TLB：MMU 的 Cache

> **核心类比**：CPU 有 L1/L2/L3 cache 缓存数据，**MMU 也有自己的 cache——TLB**，缓存最近用过的页表项。两套 cache 同时工作，缺一不可，**都基于上一节的局部性原理**。

### 4.1 为什么必须有 TLB

如果每次访存都查页表：
```
读一个 int (4B) → 走 4 级页表 = 4 次内存访问 → +1 次访问数据本身 = 5 次访问
```

也就是说**每次访存代价 5x**。这显然不可接受。TLB 是 CPU 内的小型 cache，专门缓存"最近的虚→物映射"，命中后直接拿物理地址，**1 cycle 搞定**。

### 4.2 TLB 性能数据（背一下）

| 操作 | 延迟 | 类比 |
| --- | --- | --- |
| **TLB hit** | ~1 cycle | L1 cache hit |
| **TLB miss + page walk** | ~100 cycle | L3 miss 打到 DRAM |

| TLB 规模（典型 Intel） | 数量 |
| --- | --- |
| L1 dTLB（数据） | 64 项 |
| L1 iTLB（指令） | 128 项 |
| L2 STLB（共享） | 1536 项 |

### 4.3 TLB 与 CPU Cache 的关系

```
       CPU 访问 arr[0]
              │
              ▼
   ┌──────────────────────┐
   │  虚拟地址             │
   └──────────────────────┘
              │
              ▼
   ┌──────────────────────┐
   │  MMU + TLB           │   ← TLB 命中（拿到物理地址）
   └──────────────────────┘
              │
              ▼
   ┌──────────────────────┐
   │  L1 → L2 → L3 cache  │   ← CPU 数据 cache 命中（拿到数据）
   └──────────────────────┘
              │
        都 miss 才打 DRAM
              ▼
            DRAM
```

**两套 cache 是串联的**：
- TLB 解决"地址在哪"的 cache（虚→物翻译）
- L1/L2/L3 解决"数据在哪"的 cache（物理地址→数据）
- 任何一个 miss 都会拖延访问

**HugePage 为什么能提速**：4KB 改成 2MB 页 → 一条 TLB 项覆盖范围放大 **512 倍** → 同样 64 条 TLB 项原本覆盖 256KB，现在覆盖 128MB → 大堆 JVM 的 TLB 命中率显著提升。代价是 HugePage 不能 swap、必须预留。详见 [JVM 调优](./jvm调优.md)。

---

## 五、缺页中断（Page Fault）

> **核心理解**：缺页中断不是异常，是 **OS 故意设计的懒加载机制**。"new byte[1G]" 不是真给你 1G 内存，是给你 1G 张"未来再说"的提货单。

### 5.1 三种缺页

| 类型 | 触发场景 | 代价 |
| --- | --- | --- |
| **Minor Fault** | 虚拟页未映射物理页，OS 直接分配空闲页 | 微秒级 |
| **Major Fault** | 物理页在 swap / 磁盘，需要 IO 读回 | **毫秒级**（HDD 10ms） |
| **Segfault** | 访问非法地址（NULL、越界） | 进程 SIGSEGV 崩溃 |

### 5.2 Java 视角的常见场景

```
JVM 启动 -Xmx4g            → mmap reserve 4G 虚拟地址，无缺页
访问 Eden 区新页            → minor fault，分配物理页（RSS 上涨）
GC 扫描已被换出的页         → major fault，等磁盘 IO ⚠️ STW 被拖长
Unsafe 越界                → segfault → JVM crash
```

**经典生产坑**：服务夜间被 swap 拖入 major fault → GC STW 飙到秒级。**生产标配 `swapoff -a`**——宁可 OOM Killer 杀进程，也不让 JVM 入 swap。

**加速启动稳定性的开关**：`-XX:+AlwaysPreTouch`——启动时遍历整堆主动触发 minor fault，把启动后的零散抖动一次性付清。代价是启动慢 10s 左右，但运行期延迟平稳。延迟敏感服务推荐开。

---

## 六、JVM 内存四指标（高频混淆）

> **面试金句**：JVM 内存"用了多少"是个分层问题，看用什么口径。

```
┌──────────────────────────────────────────────────┐
│   Reserved（mmap 申请的虚拟地址）                  │   = -Xmx
│   ┌──────────────────────────────────────────┐   │
│   │   Committed（OS 承诺会有物理页，但不一定占用）│   │
│   │   ┌──────────────────────────────────┐   │   │
│   │   │   RSS（实际占的物理内存）          │   │   │  ← 运维 / cgroup 看的是这个
│   │   └──────────────────────────────────┘   │   │
│   └──────────────────────────────────────────┘   │
└──────────────────────────────────────────────────┘

VSZ = Reserved（进程视角的虚拟地址总占用）
```

| 指标 | 含义 | 查看 |
| --- | --- | --- |
| **VSZ** | 进程虚拟地址空间总量 | `ps -o vsz` |
| **Reserved** | mmap 申请、占地址空间但未必有物理页 | `jcmd VM.native_memory` |
| **Committed** | OS 承诺会给物理页 | `jcmd VM.native_memory` |
| **RSS** | **实际占的物理内存** | `top` / `ps -o rss` |

**典型差异**：`-Xms1g -Xmx4g` 启动一个空 Spring Boot → VSZ ≈ 5G+（虚），RSS ≈ 300MB（实）。

**JVM 的 RSS 经常 > -Xmx**，因为这些不在 `-Xmx` 内：
- Metaspace、Direct Buffer、线程栈（`N × Xss`）、JIT Code Cache、GC 元数据、glibc malloc arena

容器内 JVM 经验配比：**`-Xmx ≈ container limit × 70%`**，剩 30% 留给以上各项。

---

## 七、生产场景速记

只列结论，深度排查见 [JVM 调优](./jvm调优.md) / [线上问题排查](./线上问题排查.md)。

| 现象 | 根因 | 处置 |
| --- | --- | --- |
| 延迟突然飙秒级，GC 日志正常 | THP 后台 compaction 同步阻塞 | `echo never > /sys/kernel/mm/transparent_hugepage/enabled` |
| 启动后几分钟 P99 偏高 | 渐进式 minor fault | `-XX:+AlwaysPreTouch` |
| 容器 RSS 远超 -Xmx 被杀 | glibc arena / Metaspace / Direct 失控 | `MALLOC_ARENA_MAX=2` + 给 Metaspace/Direct 设上限 |
| 进程突然消失、无 hprof | OOM Killer（cgroup 或 host） | `dmesg | grep -i killed` 验证；调小 -Xmx |
| 夜间 GC STW 秒级抖动 | 堆页被换到 swap → major fault | `swapoff -a` + `vm.swappiness=0` |
| 大堆 JVM CPU 不均 | NUMA 跨节点访问 | `-XX:+UseNUMA` 或 `numactl` 绑核 |

---

## 八、面试高频追问

### Q1：MMU 是什么？它什么时候工作？

CPU 硬件内置的地址翻译单元，**每次访存自动触发**，把虚拟地址翻成物理地址。翻译靠 OS 维护的多级页表，加 CPU 内的 TLB cache 加速。

### Q2：什么是局部性原理？为什么所有 cache 都靠它？

两种局部性：① **时间局部性**——刚访问过的数据很快会再访问；② **空间局部性**——访问 A 后大概率访问 A 附近。

**没有局部性，cache 命中率会等于"容量比"（cache 容量 / 总数据量）**，cache 形同虚设。整个层级体系——CPU L1/L2/L3、TLB、JIT Code Cache、Buffer Pool、PageCache——都基于这一原理。CPU **一次拉一整条 cache line（64B）** 而不是按字节读，就是赌空间局部性；**LRU 淘汰策略**赌的是时间局部性。

**Java 工程师能怎么用**：① 顺序遍历优于跳跃访问（数组 vs 链表 5~20 倍差距）；② 二维数组按行遍历（Java 行优先）；③ 避免伪共享（详见 [伪共享](../Concurrency/伪共享与缓存一致性.md)）。

### Q3：TLB 和 CPU 的 L1/L2/L3 cache 是一回事吗？

不是。**两者并存、串联工作**：
- **TLB** 是 MMU 的 cache，缓存"虚→物地址映射"（页表项）
- **L1/L2/L3** 是 CPU 数据 cache，缓存"物理地址→数据"

任意一边 miss 都会拖慢访问。TLB miss 走 page walk（~100 cycle），cache miss 走 DRAM（~100 ns）。

### Q4：页表为什么要多级？

单级 48 位虚拟地址 + 4KB 页 → 512GB 页表，装不下。多级页表**按需创建子表**，实际占用通常只几 MB。代价：TLB miss 时硬件要走 4 级（x86_64）。

### Q5：minor fault 和 major fault 区别？

- **Minor**：虚拟页未映射物理页，OS 分配空闲页 → 微秒级
- **Major**：物理页被换到 swap 或磁盘 → **毫秒级**，会打出 STW 抖动

生产环境**关 swap** 是把 major 限制到极少数（只有 file mmap 才可能）。

### Q6：HugePage 为什么能提速？

4KB → 2MB 页，**一条 TLB 项覆盖范围 ×512**，TLB 命中率显著提升。大堆 JVM CPU 收益 5%~15%。代价：HugePage 不可 swap、必须预留、容器化场景难精算。

### Q7：`-Xms = -Xmx` 设相等会立即占满物理内存吗？

**默认不会**——只 mmap 了虚拟地址（Reserved），物理页是 minor fault 时按需分配。要立即占满：`-XX:+AlwaysPreTouch`，启动时遍历整堆主动触发缺页。

### Q8：RSS、VSZ、Committed 怎么区分？

**Reserved 是答应，Committed 是承诺，RSS 是事实**。容器 limit 和 OOM Killer 看的是 **RSS**。VSZ = Reserved（最大、最虚）。

### Q9：JVM RSS 经常大于 -Xmx，钱去哪了？

七处：Metaspace、Direct Buffer、线程栈、JIT Code Cache、GC 元数据、glibc malloc arena、JNI/Native Library。排查工具：`jcmd <pid> VM.native_memory summary` + `pmap -X <pid>`。

### Q10：ZGC 染色指针怎么用到 MMU？

ZGC 用虚拟地址的高 4 位做颜色标记，**同一物理页通过 `mmap` `MAP_FIXED` 多次映射**到三个不同虚拟地址段（marked0 / marked1 / remapped）。GC 切换颜色 = 切换访问哪段虚拟地址 = 物理页**零拷贝**地"重新标记"——把工作甩给 MMU。

---

## 九、答题模板（60 秒话术）

> **MMU 是 CPU 内的硬件地址翻译单元，每次访存自动把虚拟地址翻成物理地址**，翻译靠 OS 维护的多级页表（x86_64 4 级）。
>
> MMU 自带一个 cache 叫 **TLB**，缓存最近的页表项——**TLB hit 1 cycle，miss 要走 page walk 大约 100 cycle**。它和 CPU 的 L1/L2/L3 cache 是两套不同的 cache：TLB 解决"地址在哪"，L1~L3 解决"数据在哪"，串联工作。**这两套 cache 之所以能命中，全靠程序访问的局部性原理——时间局部性（刚访问的还会再访问）+ 空间局部性（A 旁边的也会被访问）**。所以 cache line 一次拉 64B、CPU 有预取器、HugePage 提速本质都是在放大空间局部性。
>
> **缺页中断**是按需分配机制：JVM `-Xmx8g` 只占虚拟地址（Reserved），首次访问触发 **minor fault** 分配物理页（RSS 上涨）；如果页被换到 swap 再访问就是 **major fault**，毫秒级阻塞——所以生产**关 swap**、延迟敏感服务开 `-XX:+AlwaysPreTouch` 预触发。
>
> JVM 四指标分层：**VSZ ≥ Reserved ≥ Committed ≥ RSS**，容器和 cgroup 看的是 RSS。JVM RSS 经常大于 -Xmx，因为 Metaspace、Direct Buffer、线程栈、Code Cache、glibc arena、GC 元数据都不在 -Xmx 内。容器内经验配比 **`-Xmx ≈ limit × 70%`**。

---

## 十、相关文档

- [JVM 运行时数据区](./内存区域.md) — JVM 进程内的逻辑内存划分（堆/栈/方法区/直接内存）
- [JVM 调优](./jvm调优.md) — THP / HugePage / NUMA / AlwaysPreTouch 实战
- [线上问题排查](./线上问题排查.md) — RSS 虚高 / OOM Killer 案例
- [JMM 内存模型](../Concurrency/JMM内存模型.md) — **注意区分**：语言层多线程语义，与本篇 OS 硬件层正交
- [内存屏障](./内存屏障.md) — CPU cache 一致性（MESI），同样硬件层但比 MMU 更贴近指令
- [Network / 零拷贝](../Network/零拷贝.md) — mmap / sendfile 的应用层用法
- [Redis / 持久化](../Redis/持久化.md) — fork + COW，虚拟内存最经典的应用之一
