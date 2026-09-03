# 反应式 I/O Reactor — Redis / Netty / Nginx / Node.js 同构设计

> 引子：
> ① **是什么**：把"等 I/O 完成"从同步阻塞变成"注册事件 → 事件就绪时回调"，**单线程通过多路复用同时管 N 个连接**。Redis 单线程能扛 10w QPS、Netty 撑百万连接、Nginx 一个 Worker 几万并发、Node.js 单线程跑后端——全是同一个范式：**Reactor + epoll**。
> ② **面试为什么必考**：上几篇的 Pattern 都隐隐依赖它——长轮询能挂起 10 万请求靠它、Raft 心跳 50ms 一次靠它、主从复制大量长连接靠它。讲不清 Reactor，所有"高并发"故事都站不住。
> ③ **本篇要解决**：① 同步阻塞 / 同步非阻塞 / 多路复用 / 异步 IO 到底有什么差别 ② Redis 单线程为什么能这么快 ③ 主从 Reactor 是怎么演进出来的 ④ epoll 比 select 快在哪。

---

## 一、为什么需要 Reactor

### 1.1 原始问题：传统 BIO 一个连接一个线程

```java
// 阻塞 IO（BIO）：一个连接一个线程
while (true) {
    Socket socket = serverSocket.accept();      // 阻塞等连接
    new Thread(() -> {
        InputStream in = socket.getInputStream();
        byte[] buf = new byte[1024];
        in.read(buf);                            // 阻塞等数据
        process(buf);
    }).start();
}
```

**为什么不行**：每个连接占一个线程，**线程是有限且昂贵的**：
- 单线程栈默认 1MB，1 万线程占 10GB
- 线程切换上下文 ~1µs，10 万线程频繁切换 CPU 全耗在切换
- Linux 默认线程数上限几万（pid_max / ulimit）

所以 BIO 模型上限就是几千连接。要扛百万连接，必须**让一个线程同时管多个连接**。

### 1.2 Reactor 的核心 idea

不让线程"阻塞等某一个连接的数据"，而是让线程"等任何一个连接的事件":

```
传统：thread1 阻塞 read(socket1)，thread2 阻塞 read(socket2)，... N 个线程
新思路：thread 调 epoll_wait(socket1, socket2, ...) → 返回"哪个 socket 有数据"
```

**关键转变**：**N 个线程管 N 个连接** → **1 个线程管 N 个连接**。

通过把"等 I/O" 集中到一个内核机制（select / poll / epoll）上，一个线程能监听任意多个 fd——就绪了就回调对应处理器。这就是 Reactor 模式。

---

## 二、共性骨架：四种系统都长一样

### 2.1 Reactor 通用结构

```
                       ┌──────────────────┐
                       │  Reactor Thread  │
                       │ (Event Loop)     │
                       └────────┬─────────┘
                                │
                                │ ① 注册 fd
                                ▼
                       ┌──────────────────┐
                       │ epoll / kqueue   │  ← OS 提供的多路复用机制
                       │ (内核)            │
                       └────────┬─────────┘
                                │
                                │ ② 等事件
                                │
            事件就绪 ◄──────────┘
                │
                ▼
       ┌────────┴────────┐
       │ 事件分发器       │
       │ (Demultiplexer)  │
       └────────┬────────┘
                │
       ┌────────┼────────┬────────┐
       ▼        ▼        ▼        ▼
    Accept    Read     Write    Close
    Handler   Handler  Handler  Handler

                       事件循环（Event Loop）：
                        while (true) {
                            events = epoll_wait(...)
                            for (e : events) {
                                dispatcher.dispatch(e)
                            }
                        }
```

**三件套**：
1. **多路复用器**（epoll / kqueue / IOCP）：内核机制，知道哪些 fd 有事件
2. **事件循环**：用户态线程，循环调 epoll_wait + 分发
3. **事件处理器**：accept / read / write / close 各自的处理函数

### 2.2 四种系统的同构对照

| 维度 | **Redis** | **Netty** | **Nginx** | **Node.js** |
| --- | --- | --- | --- | --- |
| **Reactor 数量** | 1（命令执行线程）| 主从（boss + worker）| 多 Worker 独立 | 1（主线程）|
| **多路复用器** | epoll（Linux）/ kqueue（macOS）| Java NIO Selector → epoll | epoll | libuv → epoll |
| **事件循环载体** | aeEventLoop（C）| NioEventLoop | ngx_event_loop | event loop |
| **业务逻辑在哪跑** | 同 Reactor 线程（单线程串行）| Worker EventLoop（默认）或独立业务线程池 | 同 Worker 线程 | 同主线程（JS 回调）|
| **多核怎么用** | 6.0+ 多线程 IO + 单线程命令；多实例部署 | 多 Worker（CPU 核数）| 多 Worker（CPU 核数）| 多 Worker 模式 / cluster 模块 |
| **典型并发** | 10w QPS / 实例 | 百万连接 / 实例 | 百万连接 / Worker | 几万 QPS / 实例 |
| **业务阻塞会怎样** | 慢命令卡全实例 | 阻塞 EventLoop 卡所有 channel | 阻塞 Worker 卡所有连接 | 阻塞主线程卡所有请求 |
| **多路复用版本** | epoll LT | epoll LT 或 ET | epoll ET | epoll LT |

### 2.3 一张图看清"为啥都长一样"

```
                共性骨架：epoll + 事件循环 + 事件回调
                                │
        ┌───────────────────────┼─────────────────────────┐
        │                       │                         │
   单 Reactor              主从 Reactor              多 Reactor
   单线程到底              （boss + worker）          （SO_REUSEPORT）
        │                       │                         │
   ┌────┴────┐             ┌────┴────┐                ┌───┴────┐
 Redis 6.0-              Netty 默认                  Nginx
 Node.js                 RocketMQ NameServer        新 Linux
                         Dubbo
```

**全都是一个范式的不同变体**。差别只在"一个 Reactor 还是几个"、"业务跑在 Reactor 里还是丢去线程池"——本质骨架完全一致。

---

## 三、Reactor 的三种演进

这是面试经典题——能讲清演进过程的，立刻看出"懂"和"不懂"的差距。

### 3.1 单 Reactor 单线程

```
   ┌──────────────────────────────┐
   │  Reactor Thread              │
   │  ┌─────┐                      │
   │  │epoll│ ──事件──► dispatch    │
   │  └─────┘     │                 │
   │              ├─► Accept        │
   │              ├─► Read          │
   │              ├─► Process（业务）│  ← 致命：业务在这里跑
   │              └─► Write         │
   └──────────────────────────────┘
```

**代表**：Redis 6.0-、Node.js。

**优点**：实现极简、无锁、上下文切换零。

**致命缺陷**：业务慢 → 整个事件循环卡住 → 所有连接卡死。所以**业务必须超快**——Redis 命令必须 µs 级，Node.js 业务必须用回调而非同步阻塞。

### 3.2 单 Reactor 多线程

```
   ┌──────────────────────────────┐
   │  Reactor Thread              │
   │  ┌─────┐                      │
   │  │epoll│ ──事件──► dispatch    │
   │  └─────┘     │                 │
   │              ├─► Accept        │
   │              ├─► Read          │
   │              └─► [线程池]      │  ← 业务丢线程池
   │                    │           │
   │                    ▼           │
   │              Worker1 / Worker2 │
   │              ...             ──┼─► Write 回 Reactor
   └──────────────────────────────┘
```

**代表**：Tomcat NIO、早期 Netty 配置。

**好处**：业务在线程池跑，Reactor 不被业务阻塞。

**缺陷**：accept 和 read 还在一个 Reactor 线程上——**单 Reactor 是新的瓶颈**（百万连接时 accept QPS 上不去）。

### 3.3 主从 Reactor 多线程（默认）

```
   ┌────────────────────────────┐
   │  Main Reactor (boss)        │  只管 accept
   │  ┌─────┐                     │
   │  │epoll│ ──Accept事件──►新连接│ 注册到子 Reactor
   │  └─────┘                     │
   └──────────┬──────────────────┘
              │
              ▼
   ┌────────────────────────────────────────────────┐
   │  Sub Reactor 1 / 2 / ... / N（worker，= CPU 核数）│
   │  每个有独立的 epoll                              │
   │  各自管自己分到的连接的 Read / Write              │
   │                                                  │
   │  业务可以同步跑（轻量）或丢业务线程池（重的）     │
   └────────────────────────────────────────────────┘
```

**代表**：Netty（默认）、Nginx（多 Worker）、RocketMQ NameServer。

**为什么是终极形态**：
- accept 单点不再瓶颈（boss 只做 accept 极快）
- 读写并行分摊到多核（多个 sub Reactor 各跑一核）
- 业务可灵活选 EventLoop 内还是线程池

**Netty 默认**：boss = 1 个 EventLoop，worker = CPU 核数 × 2。

---

## 四、关键机制详解

### 4.1 epoll vs select / poll：核心差距

| 维度 | select | poll | **epoll** |
| --- | --- | --- | --- |
| **fd 上限** | 1024（FD_SETSIZE）| 无 | 无（OS 限制几十万）|
| **每次调用传 fd 集合** | ✅ 全量传 | ✅ 全量传 | ❌ 注册一次即可 |
| **内核扫描方式** | O(N) 轮询 | O(N) 轮询 | **O(1) 回调 + 就绪链表** |
| **返回结果** | 修改原 fd_set，需自己扫 | events 数组扫 | 直接给"哪些 fd 就绪" |
| **触发模式** | LT | LT | **LT 或 ET** |

**epoll 的精妙**：
- `epoll_create` 创建实例（含红黑树 + 就绪链表）
- `epoll_ctl` **注册一次** fd 到红黑树
- `epoll_wait` 内核**只返回就绪的 fd**——不用应用扫描全部 fd

**关键洞察**：`select` 是"我要监听这 10000 个 fd"，每次都传 10000 个；`epoll` 是"我注册了 10000 个 fd，告诉我哪些有事就行"，返回的是事件列表。**10000 个 fd 但只有 10 个就绪时，select 还要走全量扫描，epoll 直接返回那 10 个**——这是性能差几个数量级的根本原因。

→ 细节见 [Network/多路复用.md](../Network/多路复用.md)

### 4.2 LT vs ET：水平触发 vs 边缘触发

```
水平触发（Level Triggered）：
  socket 缓冲区有数据 → 每次 epoll_wait 都通知
  → 读不完没关系，下次还会通知
  → 编程简单
  → Redis / Node.js 默认

边缘触发（Edge Triggered）：
  socket 缓冲区从无→有数据时通知一次
  → 必须一次读完所有数据（直到 EAGAIN）
  → 通知次数少，CPU 效率高
  → 编程复杂（要循环读直到空）
  → Nginx / Netty Native epoll 默认
```

**为什么 Nginx 选 ET**：百万连接场景下，每个事件少通知一次都是显著收益。但代价是必须循环 read 到 EAGAIN——少写就丢事件。

**为什么 Redis 选 LT**：单线程模型本来就要快速循环，LT 编程简单、不易出 bug。

### 4.3 Redis 为什么"单线程"还这么快

经典面试题。**初级答案**："基于内存"——这是错的（Memcached 也基于内存，差别没那么大）。

**真正的答案**：

| 因素 | 贡献 |
| --- | --- |
| **1. 全内存操作** | 数据在内存，纳秒级访问 |
| **2. 高效数据结构** | dict / 跳表 / 压缩列表都为低复杂度优化 |
| **3. 单线程 + 无锁** | 零锁竞争、零上下文切换、无死锁 |
| **4. IO 多路复用（epoll）** | 一个线程同时管 10w 连接 |
| **5. 协议简单 + Pipeline** | RESP 协议解析快，pipeline 摊平 RTT |

**3 和 4 是别的内存 KV 也有的吗**？Memcached 用的是多线程 + 加锁——锁竞争和上下文切换在 100k QPS 量级就抵消了多核优势。Redis 单线程在中等并发下反而更快。

**6.0 的"多线程"改了什么**：

```
6.0+：
  IO 线程池：读 socket + 解析协议 / 写 socket（多线程）
  主线程：命令执行（仍然单线程串行）
```

**核心命令执行还是单线程**——这是 Redis 无锁设计的根基不能动。改的只是 IO 部分（read/write/parse），因为这部分容易并行化且不涉及数据结构。

→ 细节见 [Redis/工作流程.md](../Redis/工作流程.md)

### 4.4 Nginx 多 Worker + SO_REUSEPORT 防惊群

老 Nginx 的问题：所有 Worker 监听同一个 listen socket → 新连接到来 → **所有 Worker 都被唤醒** → 但只有一个能 accept → 其它空跑——**惊群（Thundering Herd）**。

```
老解法：accept_mutex
  Worker 抢锁后才 epoll_wait
  ✅ 无惊群
  ❌ 锁开销 + 不均衡（抢到锁的拿连接多）

新解法：SO_REUSEPORT（Linux 3.9+，Nginx 1.9.1+ 默认）
  每个 Worker 独立 listen socket（同一端口）
  内核做四元组哈希分发新连接
  ✅ 无惊群
  ✅ 连接分发均衡
  ✅ 无锁
```

**SO_REUSEPORT 是"内核级 Reactor 分片"**——把单 listen socket 拆成 N 个，内核负责负载均衡。这是现代 Linux 高并发服务器的标配。

### 4.5 Netty 为什么不直接用 JDK NIO

JDK NIO 的 Selector 有几个坑：
1. **空轮询 bug**：epoll_wait 在某些条件下返回 0 但不阻塞，导致 CPU 100% 空转。Netty 检测到连续 N 次空轮询会**重建 Selector** 绕过 bug
2. **Buffer 管理粗糙**：ByteBuffer 没有池化，频繁分配 / GC 压力大。Netty 自己实现 ByteBuf + 内存池（jemalloc 风格）
3. **API 难用**：JDK NIO 直接面向 OP_READ / OP_WRITE，业务要自己写状态机。Netty 用 Pipeline 责任链
4. **Linux epoll 不能直接调**：JDK NIO 在 Linux 上还是 epoll，但 Netty 提供原生 epoll（绕过 JNI、支持 ET、性能更好）

**Netty 不是"NIO 的封装"，是"Reactor 框架"**——把 NIO 上面缺的工程化能力（连接管理、协议解析、内存池、流控）都补齐了。

→ 细节见 [Middleware/Netty.md](../Middleware/Netty.md)

---

## 五、生产踩坑

### 踩坑 1：Reactor 线程跑了一个慢业务，所有连接卡死

**现象**：Netty 服务突然所有连接都不响应，但没报错。

**根因**：业务 Handler 里直接调了同步阻塞的 DB 查询 / RPC 调用——耗时 5s。这 5s 内 EventLoop 线程被独占，**该 EventLoop 上所有 channel 都不能处理事件**。

**修复**：① 业务异步化（用 CompletableFuture）；② 重业务用独立 `EventExecutorGroup` 跑 Handler；③ 监控 EventLoop 的 `pendingTasks` 和 `taskExecutionTime`，超阈值告警。

**通用教训**：**Reactor 线程"沾"不得任何阻塞操作**——一个慢业务卡 N 个连接是 Reactor 模式的固有局限。

### 踩坑 2：Redis 跑了一个 KEYS * 卡了整个实例

**现象**：监控显示 Redis 实例 5 秒内没响应任何命令，所有上游服务超时。

**根因**：业务跑了 `KEYS pattern*`，扫描 1000 万 key 耗时 5 秒——Redis 单线程被这一条命令独占。

**修复**：① 生产严禁 `KEYS *` / `FLUSHALL` / `HGETALL`（大 hash）这类 O(N) 命令，重命名屏蔽；② 用 SCAN 游标分批扫；③ 慢查询监控 `slowlog-log-slower-than 10000`（10ms 阈值）。

**Redis 单线程的代价**：任何慢命令都会卡所有客户端。这是 Reactor 单线程的最大 bug。

### 踩坑 3：JDK NIO 空轮询 CPU 100%

**现象**：JDK 1.7 时代生产环境出现 CPU 长期 100%、火焰图全是 `EPollSelectorImpl.epollWait`。

**根因**：JDK NIO Selector 在某些 Linux 内核 + JDK 版本下有空轮询 bug——epoll_wait 立即返回 0 但 Selector 认为有事件 → 死循环。

**修复**：升级 JDK / 用 Netty（Netty 内置空轮询检测 + Selector 重建）。

### 踩坑 4：Nginx worker_processes 设错性能反而下降

**现象**：把 `worker_processes` 从 16（CPU 核数）改到 64，QPS 反而下降。

**根因**：Worker 数 > 核数时，多个 Worker 抢同一个核，CPU cache 频繁失效 + 上下文切换。Nginx 设计就是 **Worker 数 ≈ CPU 核数 + 绑核**。

**修复**：
```nginx
worker_processes auto;        # = CPU 核数
worker_cpu_affinity auto;     # 自动绑核
```

### 踩坑 5：Node.js 主线程做 CPU 密集任务，所有请求超时

**现象**：Node 服务做了一个 JSON.parse 解析 50MB 数据，期间所有请求 30s 超时。

**根因**：Node.js 单线程主循环——CPU 密集任务直接卡住事件循环。

**修复**：① CPU 密集任务用 `worker_threads` 模块跑独立线程；② 拆成异步小任务（setImmediate / process.nextTick 让出主循环）；③ 重活儿丢 RPC 给其它语言。

**通用模式**：**单 Reactor 模型必须严格区分 "I/O 等待" 和 "CPU 计算"**——前者 OK，后者必须扔出主线程。

### 踩坑 6：Netty 长连接百万但 Direct Memory OOM

**现象**：服务运行几天后 Native Memory 持续增长直到 OOM。

**根因**：Netty 默认用 Direct ByteBuf（堆外内存）减少 GC，但堆外内存不归 JVM 管。如果业务忘了 `buf.release()`，引用计数泄漏，堆外内存持续涨。

**修复**：① 业务严格遵守"谁分配谁释放"；② 启动加 `-Dio.netty.leakDetection.level=PARANOID` 检测泄漏；③ 关键路径用 `try-with-resources` 包 ByteBuf；④ 监控 `PlatformDependent.usedDirectMemory()`。

→ 细节见 [Middleware/Netty.md](../Middleware/Netty.md)

---

## 六、面试高频追问

### Q1：为什么 Redis 单线程能扛 10 万 QPS？

四件套缺一不可：① 全内存（命令执行 µs 级）；② 高效数据结构（dict O(1) / 跳表 O(logN)）；③ epoll 多路复用（单线程管 N 连接）；④ 无锁设计（零竞争零切换）。

光"基于内存"是初级答案——Memcached 也基于内存但多线程加锁，反而比 Redis 慢。**单线程 + 多路复用** 才是 Redis 快的真正原因。

### Q2：BIO / NIO / AIO / Reactor 区别？

- **BIO**：一连接一线程，线程阻塞等数据——简单但上限几千
- **NIO（多路复用）**：单线程通过 epoll 管 N 连接——Reactor 的实现基础
- **AIO（异步 IO）**：内核完成 IO 后回调用户态——理论最优但 Linux epoll 实现得"假"，实际几乎没人用
- **Reactor**：**模式**，不是 API；本质就是"NIO + 事件循环 + 事件分发"

生产环境主流是 **NIO 多路复用 + Reactor 模式**（Netty / Nginx / Redis / Kafka 全是）。

### Q3：单 Reactor / 主从 Reactor 怎么演进？

```
单 Reactor 单线程（Redis）
  ↓ 业务慢就卡所有连接
单 Reactor 多线程（早期 Tomcat NIO）
  ↓ accept 还在单点
主从 Reactor 多线程（Netty / Nginx）
  ↓ accept 和 IO 都分摊到多核
```

主从 Reactor 是生产标准答案——boss 专门 accept、worker 各自管自己的连接读写。

### Q4：epoll 为什么比 select 快？

三个核心差距：① `select` 每次调用要传全量 fd 集合，`epoll` 注册一次即可；② `select` 内核 O(N) 扫描所有 fd，`epoll` 用红黑树 + 就绪链表 O(1)；③ `select` 返回时要应用层扫描结果，`epoll` 直接给"就绪的 fd 列表"。

**最关键的差距**：10000 个 fd 但只 10 个就绪时，select 走全量扫描，epoll 只返回这 10 个——百倍性能差距来自这。

### Q5：LT 和 ET 怎么选？

- LT（水平触发）：缓冲区有数据就反复通知，编程简单——Redis / Node.js / 一般业务首选
- ET（边缘触发）：状态变化通知一次，必须循环读到 EAGAIN，少通知一次都不行——Nginx 这种百万连接场景首选

工程经验：除非你做"网关 / 反代"这种连接数极大的场景，否则 LT 就够用了——别为了一点性能上 ET 然后死在编程坑里。

### Q6：Redis 6.0 多线程改了什么？

只改了 **IO 部分**（读 socket、解析协议、写 socket），**命令执行仍然单线程**串行。

为什么这么改：
- IO 部分容易并行（多个 client 互不依赖）
- 命令执行单线程是 Redis 无锁设计的根基——动了等于重写
- 多线程 IO 在大 value（如 1MB string）场景下显著提升吞吐

参数：`io-threads 4`（按 CPU 核数 / 2），`io-threads-do-reads yes`。

### Q7：Netty 为什么不用 JDK NIO 直接做？

四个理由：① JDK NIO 有空轮询 bug，Netty 自动 Selector 重建绕过；② JDK ByteBuffer 没池化，Netty 实现 ByteBuf + 内存池；③ JDK API 难用（要自己写状态机），Netty 用 Pipeline 责任链；④ Netty 提供原生 epoll（支持 ET、性能更好）。

**Netty 是 Reactor 框架，不是 NIO 封装**。

### Q8：百万连接的服务器需要多少 CPU？

经验值：
- Nginx：单 Worker（1 核）可扛 100w 长连接（绝大多数空闲）；活跃连接 1~5w
- Netty：单 NioEventLoop（1 核）扛 5~10w 活跃连接
- Redis 6.0+：单实例（4 IO 线程）10w QPS

百万连接服务器关键不是 CPU 数量，而是 **内存（每连接至少 4KB 内核 + 应用 buffer）+ 文件描述符（`ulimit -n`）+ 内核参数（`net.core.somaxconn` 等）**。

### Q9：Reactor 的"沾不得阻塞操作"具体什么意思？

EventLoop 线程负责"等事件 + 调回调"——只要它进入回调函数，**整个事件循环就停了**。回调里执行：
- `Thread.sleep(1000)` → 1 秒所有连接停摆
- 同步 DB 查询 → 慢查询期间所有连接停摆
- `JSON.parse(50MB)` → 解析期间所有连接停摆
- 大对象 GC → STW 期间所有连接停摆

**Reactor 是单线程的代价 = 业务必须异步或极快**。Redis 用慢查询监控+禁用慢命令；Node.js 用回调 / Promise 强制异步；Netty 用业务线程池兜底。

### Q10：长轮询能挂 10 万请求靠什么？

靠 Reactor。每个挂起的长轮询请求 = 一个 TCP 连接，不写响应就不归还连接。如果用 BIO 模型（一连接一线程），10 万长轮询 = 10 万线程 = OOM。

**长轮询规模化的前提是底层用 NIO + Reactor**：Nacos Server 用 Tomcat NIO 异步 Servlet，RocketMQ Broker 用 Netty——这就是上一篇《长轮询》没展开的"为什么能挂得起"。

→ 详见 [Patterns/长轮询.md](./长轮询.md)

---

## 七、答题模板（60 秒话术）

> **Reactor 是高并发服务器的标准范式**：单线程通过 epoll 同时监听 N 个 fd，事件就绪时回调对应处理器——把"一连接一线程"换成"一线程管 N 连接"，连接数上限从几千跳到百万。
>
> **三种演进**：① 单 Reactor 单线程（Redis、Node.js）——简单但业务慢就卡所有；② 单 Reactor 多线程——业务丢线程池但 accept 是新单点；③ 主从 Reactor 多线程（Netty、Nginx 默认）——boss 专 accept、worker 各管自己连接，是生产标准答案。
>
> **epoll 是 Reactor 的内核基础**：vs select 的核心差距是 fd 注册一次（select 每次传全量）+ 内核 O(1) 回调机制（select 是 O(N) 扫描）+ 只返回就绪 fd（select 要应用扫）。10000 fd 中 10 个就绪时，epoll 比 select 快百倍。LT 编程简单（Redis）、ET 通知少（Nginx）。
>
> **同构实现**：① **Redis**：单线程 + epoll，6.0+ 多线程 IO 但命令执行仍单线程；② **Netty**：主从 Reactor + Pipeline + ByteBuf 池，绕过 JDK NIO 空轮询 bug；③ **Nginx**：多 Worker + SO_REUSEPORT 防惊群，CPU 核数 + 绑核；④ **Node.js**：单线程事件循环，CPU 密集任务用 worker_threads 拆出去。
>
> **共同盲点**：Reactor 线程沾不得任何阻塞——业务慢一秒、所有连接卡一秒。生产用监控 EventLoop 任务排队、禁用 Redis 慢命令、Node 拆 CPU 密集任务三招兜底。
>
> **生产坑**：① Netty Handler 里同步调 DB 卡所有 channel；② Redis KEYS * 卡 5s 引发雪崩；③ JDK NIO 空轮询 CPU 100%；④ Nginx Worker 数错配性能下降；⑤ Netty Direct Memory 泄漏 OOM；⑥ Node CPU 密集卡主线程。

---

## 八、相关文档

### 本模块（横向）

- [长轮询 Long Polling](./长轮询.md) — Reactor 是长轮询能挂起 10w 请求的底层基础
- [心跳与租约](./心跳与租约.md) — 心跳的网络层载体也是长连接 + 多路复用
- [主从复制范式](./主从复制范式.md) — 主从间的大量长连接靠 Reactor 撑

### 具体实现（纵向，回到原模块）

- [Network/网络IO模型.md](../Network/网络IO模型.md) — BIO / NIO / AIO / Reactor 全景
- [Network/多路复用.md](../Network/多路复用.md) — select / poll / epoll 源码级对比
- [Network/零拷贝.md](../Network/零拷贝.md) — sendfile / mmap 减少用户态-内核态拷贝
- [Redis/工作流程.md](../Redis/工作流程.md) — Redis 单线程 + 6.0 多线程 IO
- [Middleware/Netty.md](../Middleware/Netty.md) — 主从 Reactor + Pipeline + 内存池
- [Middleware/Nginx.md](../Middleware/Nginx.md) — 多 Worker + SO_REUSEPORT
