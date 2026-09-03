# 网络 IO 模型（BIO / NIO / AIO + Reactor）

> 这是中间件面试的**入门门槛**——Netty / Tomcat / Redis / Nginx / Kafka 全都建立在 IO 模型之上。
> 本篇要解决：
> ① **5 种 IO 模型**到底差在哪（同步/异步、阻塞/非阻塞 是两个正交维度，别混淆）
> ② Java 的 **BIO/NIO/AIO** 各自对应 OS 哪一种
> ③ **Reactor 模式**为什么是高并发服务器的标准答案，单/主从 Reactor 怎么演进
> ④ 一个连接 → 内核 → 用户线程的完整数据流

---

## 一、为什么必须先讲 IO 模型

任何 I/O 操作（read / write / send / recv）本质是 **用户进程委托内核**，跨 用户态 ↔ 内核态。性能瓶颈点：

1. **等数据到达**（数据没到，内核怎么处理调用方？）
2. **数据从内核拷贝到用户**（必然要拷贝，能否异步？）

不同 IO 模型就是对这两步的**不同答卷**。一句话总结：

| 模型 | 等数据到达 | 拷贝阶段 | 性能 |
| --- | --- | --- | --- |
| 同步阻塞 BIO | 阻塞 | 阻塞 | 最差 |
| 同步非阻塞 NIO | 轮询返回 EAGAIN | 阻塞 | 一般 |
| **IO 多路复用**（NIO/Reactor） | 一个线程监听 N 个 fd | 阻塞 | **主流** |
| 信号驱动 IO | 异步通知 | 阻塞 | 用得少 |
| 异步 IO（AIO） | 异步通知 | **异步** | 理想 |

> **同步 vs 异步**：看的是**数据从内核到用户**这一步谁负责拷贝。同步=用户线程拷；异步=内核拷完通知。
> **阻塞 vs 非阻塞**：看的是**调用没准备好**时是挂起还是立即返回。

**面试坑**：很多人把 NIO 等同于"非阻塞"，其实 Java NIO 的核心是 **多路复用**（Selector），单纯非阻塞 socket 性能并没好多少。

---

## 二、整体流程图（一次 read 的完整旅程）

```
   用户态                                内核态                             硬件
┌─────────┐                          ┌──────────────┐                ┌──────────┐
│ Java App│   read(fd, buf)          │  Socket 缓冲区│                │  网卡 NIC │
│ 用户缓冲 │ ───────────────────────► │  recv buffer │ ◄──────────────│  收到包  │
│  buf    │                          │              │     DMA        │          │
│         │ ◄──────────────────────  │              │                │          │
└─────────┘   数据拷贝到用户          └──────────────┘                └──────────┘
   ↑↑                                       ↑
   │└── ② 拷贝阶段（CPU memcpy）            │
   │                                        │
   └── ① 等待数据阶段（数据是否已到达 recv buffer）
```

**所有 IO 模型的差异**就在 ① 和 ② 这两步如何处理。

---

## 三、5 种 IO 模型详解

### 3.1 同步阻塞 BIO（Blocking IO）

**模型**：调用 `read()` → 整个线程睡眠直到 ① 数据到 + ② 拷贝完。

```java
ServerSocket serverSocket = new ServerSocket(8888);
while (true) {
    Socket socket = serverSocket.accept();          // 阻塞 1：等连接
    new Thread(() -> {
        InputStream in = socket.getInputStream();
        byte[] buffer = new byte[1024];
        int len = in.read(buffer);                  // 阻塞 2：等数据
        process(buffer, len);
    }).start();
}
```

**问题**：**一个连接一个线程**（C10K 灾难）。1 万并发 = 1 万线程，光线程栈就 ~10GB（默认 1MB/线程），上下文切换打爆 CPU。

**典型场景**：早期 Tomcat（BIO Connector，已废弃）、传统 Web 容器、DB 客户端。

**优化兜底**：线程池 + 队列（PoolThreadModel），但仍然挡不住瞬时高并发。

---

### 3.2 同步非阻塞 NIO（Non-blocking IO）

**模型**：`fcntl(fd, F_SETFL, O_NONBLOCK)` → `read()` 数据没到立即返回 `EAGAIN`，用户线程**轮询**。

```c
while (1) {
    int n = read(fd, buf, sizeof(buf));
    if (n > 0) { process(buf, n); break; }
    if (n == -1 && errno == EAGAIN) continue;       // 数据没到，再来
}
```

**问题**：**CPU 100% 空转**。看似非阻塞，实际是用 CPU 换响应性，比 BIO 还差。

**结论**：**单纯的非阻塞 IO 没人用**——必须配合多路复用（select/poll/epoll）才有意义，所以下一节才是真正的"NIO 实战"。

---

### 3.3 IO 多路复用（Reactor 真正的基石）⭐

**模型**：用户线程调一次 `select/poll/epoll_wait`，**一次性监听 N 个 fd**，内核把"哪些 fd 就绪"告诉用户线程，再针对性 `read`。

```
        ┌────── 1 个线程 ──────┐
        │   epoll_wait()       │ ← 阻塞在这一行，监听上万 fd
        └─────────┬────────────┘
                  ↓ 返回 ready_list (e.g. fd=3, fd=17, fd=99)
        ┌─────────┴────────────┐
        │ for fd in ready_list │
        │   read(fd)           │ ← 数据已就绪，几乎不阻塞
        └──────────────────────┘
```

**关键转变**：**1 线程管 N 连接**。Redis 单线程能扛 10w QPS、Nginx worker 能扛百万连接，全靠这个。

**Java NIO 三大件**：

| 组件 | 对应 OS 概念 | 作用 |
| --- | --- | --- |
| `Channel` | fd（文件描述符） | 双向数据通道 |
| `Buffer`（ByteBuffer） | 用户态缓冲区 | 替代流，position/limit/capacity 三指针 |
| `Selector` | epoll 实例 | 事件多路复用器 |

```java
Selector selector = Selector.open();
ServerSocketChannel server = ServerSocketChannel.open();
server.bind(new InetSocketAddress(8080));
server.configureBlocking(false);                            // 必须非阻塞
server.register(selector, SelectionKey.OP_ACCEPT);          // 注册感兴趣事件

while (true) {
    selector.select();                                      // 阻塞，等任意 fd 就绪
    Iterator<SelectionKey> it = selector.selectedKeys().iterator();
    while (it.hasNext()) {
        SelectionKey key = it.next();
        it.remove();                                        // 必须 remove，否则下次还会处理

        if (key.isAcceptable()) {
            SocketChannel client = server.accept();
            client.configureBlocking(false);
            client.register(selector, SelectionKey.OP_READ);
        } else if (key.isReadable()) {
            ByteBuffer buf = ByteBuffer.allocate(1024);
            ((SocketChannel) key.channel()).read(buf);
            // 业务处理
        }
    }
}
```

**面试坑**：
- ✅ Java NIO 的 Selector 在 Linux 上**默认用 epoll**（看 `EPollSelectorProvider`），Windows 用 IOCP-like，macOS 用 kqueue。
- ❌ 很多人认为 NIO 是"异步"——错了。**多路复用本质还是同步 IO**，数据拷贝阶段用户线程仍要参与（`channel.read(buf)` 是同步的）。

---

### 3.4 信号驱动 IO（用得少）

**模型**：先调 `sigaction(SIGIO, ...)` 注册信号处理器，数据到达时内核发信号 SIGIO，用户线程在信号处理器里 `read`。

**问题**：信号是异步的、不可靠（多个 fd 同时就绪只触发一次信号），编程模型反人类。**生产几乎不用**。

---

### 3.5 异步 IO AIO（理想模型）

**模型**：用户调 `aio_read(fd, buf, ...)` 立即返回，**数据到 + 拷贝完后**内核回调通知用户。① 和 ② 都不阻塞。

**Java AIO（NIO.2）**：

```java
AsynchronousServerSocketChannel server = AsynchronousServerSocketChannel.open();
server.bind(new InetSocketAddress(8080));
server.accept(null, new CompletionHandler<>() {
    public void completed(AsynchronousSocketChannel client, Object att) {
        ByteBuffer buf = ByteBuffer.allocate(1024);
        client.read(buf, buf, new CompletionHandler<>() {
            public void completed(Integer n, ByteBuffer buf) { /* 数据已就绪+已拷贝 */ }
            public void failed(Throwable e, ByteBuffer buf) { }
        });
    }
    public void failed(Throwable e, Object att) { }
});
```

**为什么 Linux 上 AIO 用得少**：
- Linux 的 AIO（`io_submit`）只对**磁盘 IO** 友好，**网络 IO 实现是用 epoll 模拟的**——本质还是同步多路复用，性能并不优于 Netty 的 NIO 方案。
- Windows IOCP 是真正内核级 AIO，但 Java 服务端 95% 跑在 Linux 上。
- **`io_uring`**（Linux 5.1+，2019）才是真正高性能 AIO，Netty 5 已实验性支持。

**结论**：**生产环境主流仍是 NIO 多路复用 + Reactor**（Netty / Nginx / Redis / Kafka 全是）。AIO 在 Linux 上是"看起来美好"的方案。

---

## 四、四种模型横向对比

| 维度 | BIO | NIO（多路复用） | AIO | Reactor 主从 |
| --- | --- | --- | --- | --- |
| **同步/异步** | 同步 | 同步 | 异步 | 同步 |
| **阻塞/非阻塞** | 阻塞 | 非阻塞 | 非阻塞 | 非阻塞 |
| **线程数** | 1 conn / 1 thread | 1 thread / N conn | 内核回调 | M-thread / N-conn |
| **吞吐** | 低（C10K 极限） | 高（C100K+） | 理论最高 | **生产最高** |
| **编程难度** | 极易 | 中（事件驱动） | 难（回调地狱） | 中（Netty 封装） |
| **代表** | 老 Tomcat、JDBC | Java NIO、Redis | Java AIO（鸡肋） | **Netty、Nginx、Tomcat NIO** |

---

## 五、Reactor 模式（生产服务器的标准答案）

Reactor = **多路复用 + 事件分发** 的设计模式。本质是把"事件循环 + 业务处理"解耦。

### 5.1 单 Reactor 单线程

```
            ┌───────────────────────┐
            │      Reactor (1 thr)  │
            │   ┌───────────────┐   │
   client → │   │ Selector loop │   │
            │   └───────┬───────┘   │
            │           │           │
            │   ┌───────▼───────┐   │
            │   │ Acceptor /    │   │
            │   │ Handler.read  │   │
            │   │   .process    │   │ ← 业务处理也在这里
            │   │   .write      │   │
            │   └───────────────┘   │
            └───────────────────────┘
```

**代表**：**Redis 6 之前**。
- ✅ 简单，无锁。
- ❌ 业务慢则全员卡。Redis 之所以能用是因为内存操作 < 1μs。
- ❌ 多核打不满。

### 5.2 单 Reactor 多线程

```
   ┌──────────────────┐
   │ Reactor (1 thr)  │ ─── accept + read/write
   │ Selector + IO    │
   └────────┬─────────┘
            │ 把业务派发给
            ▼
   ┌──────────────────┐
   │ Worker Pool      │ ─── 业务计算
   │ (N threads)      │
   └──────────────────┘
```

**问题**：单个 Reactor 仍是瓶颈（百万连接的 accept + 读写都在它上面）。

### 5.3 主从 Reactor（生产首选）⭐

```
   ┌──────────────────┐
   │  MainReactor     │ ─── 只负责 accept
   │  (BossGroup)     │     新连接派发给 SubReactor
   └────────┬─────────┘
            │ register
            ▼
   ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
   │ SubReactor #0    │    │ SubReactor #1    │    │ SubReactor #N    │
   │ (WorkerGroup)    │ …  │                  │    │                  │
   │ 读写 + 编解码     │    │                  │    │                  │
   └────────┬─────────┘    └────────┬─────────┘    └────────┬─────────┘
            │                       │                       │
            ▼                       ▼                       ▼
   ┌──────────────────────────────────────────────────────────────┐
   │              Business Worker Pool（业务线程池）                │
   └──────────────────────────────────────────────────────────────┘
```

**对应 Netty**：

```java
EventLoopGroup boss = new NioEventLoopGroup(1);              // MainReactor
EventLoopGroup worker = new NioEventLoopGroup();             // SubReactor (默认 2*core)
ServerBootstrap b = new ServerBootstrap()
    .group(boss, worker)
    .channel(NioServerSocketChannel.class)
    .childHandler(new ChannelInitializer<>() {
        protected void initChannel(SocketChannel ch) {
            ch.pipeline().addLast(new BusinessHandler());
        }
    });
```

**代表**：**Netty / Tomcat NIO / Nginx**。
- ✅ Boss 只 accept，不会成瓶颈。
- ✅ Worker 多核充分利用。
- ✅ 业务用独立线程池，不阻塞 IO 线程。

---

## 六、生产踩坑

### 坑 1：JDK NIO 的 epoll 空轮询 BUG（必考）

**现象**：JDK 1.7 NIO 在 Linux epoll 下，无任何就绪事件时 `selector.select()` 应阻塞，**实际却立即返回**，导致 CPU 100%。

**根因**：内核的边缘条件（如 epoll 文件描述符被 dup、EPOLLHUP 等）触发了空唤醒，JDK 没正确处理。

**Netty 的修复**：

```java
// io.netty.channel.nio.NioEventLoop（简化）
int selectCnt = 0;
while (true) {
    selector.select(timeoutMillis);
    selectCnt++;
    if (events == 0 && selectCnt >= SELECTOR_AUTO_REBUILD_THRESHOLD /*512*/) {
        rebuildSelector();                                  // 重建 Selector
        selectCnt = 0;
    }
}
```

**面试题**："为什么 Netty 能用、JDK NIO 不能直接用？"——答案就是这个 BUG 的工程兜底。

### 坑 2：`selectedKeys` 忘记 `remove()`

```java
while (it.hasNext()) {
    SelectionKey key = it.next();
    // 忘了 it.remove();      ← 下一轮还会触发，重复处理
    handle(key);
}
```

**症状**：监听到 OP_ACCEPT 后疯狂建连接，或一条消息被读多次。

### 坑 3：NIO 写半包

NIO 的 `channel.write(buf)` 可能**只写入部分字节**（内核 socket 缓冲区满）。

**正确写法**：注册 `OP_WRITE` 事件，下次可写时继续写：

```java
int written = channel.write(buf);
if (buf.hasRemaining()) {
    key.interestOps(key.interestOps() | SelectionKey.OP_WRITE);  // 关注可写
}
```

Netty 的 `ChannelOutboundBuffer` 已自动处理。

### 坑 4：DirectBuffer 内存泄漏

`ByteBuffer.allocateDirect()` 用堆外内存（不受 -Xmx 控制），靠 `Cleaner` 在 GC 时回收。**问题**：堆压力小则不 GC，堆外内存涨到撑爆机器。

**修复**：
- 监控 `-XX:MaxDirectMemorySize`。
- Netty 用 `PooledByteBufAllocator` + 引用计数手动 release，避免依赖 GC。

### 坑 5：Tomcat 高并发下连接数瓶颈

Tomcat 8.5+ 默认用 **NIO Connector**（多路复用）；老版本/错误配置成 BIO Connector，10K 并发就崩。

```xml
<Connector port="8080" protocol="org.apache.coyote.http11.Http11NioProtocol"
           maxThreads="200" acceptCount="500"/>      <!-- maxThreads=业务线程数 -->
```

`maxThreads` 是**业务线程**，不是连接数。NIO 下连接数受限于 `maxConnections`（默认 10000）。

---

## 七、面试高频追问

**Q1：BIO/NIO/AIO 的区别？**
- BIO：① 阻塞 ② 阻塞，1 conn 1 thread。
- NIO（Java）：用多路复用 + 非阻塞 socket，① 非阻塞返回 ② 阻塞拷贝，1 thread N conn。
- AIO：① ② 全异步，内核搞定后回调。Linux 上网络 AIO 是 epoll 模拟的，性能没优势。
- **生产用什么**：NIO + Reactor（Netty / Tomcat NIO）。

**Q2：同步异步、阻塞非阻塞 是什么关系？**
两个**正交维度**。同步=数据拷贝由用户线程做；异步=内核拷完通知。阻塞=没准备好就挂起；非阻塞=立刻返回 EAGAIN。NIO 多路复用 = 同步 + 非阻塞。

**Q3：为什么 Redis 单线程能扛 10w QPS？**
- 全内存操作（μs 级别）。
- IO 多路复用（epoll）让单线程管 N 连接。
- 无锁（避免锁竞争）、无上下文切换。
- Redis 6 的"多线程"只用于 IO 读写，命令执行仍是单线程。

**Q4：Netty 线程模型是什么？为什么是主从 Reactor？**
- BossGroup（默认 1 线程）：只 accept 连接 → 派发给 WorkerGroup。
- WorkerGroup（默认 2*core）：每个连接绑定一个 EventLoop（一个连接的所有 IO 都在同一线程，避免锁）。
- 业务可放 EventLoop（适合内存计算）或独立线程池（适合 DB/RPC）。

**Q5：Java NIO 在 Linux 上底层用什么？**
默认 `EPollSelectorProvider` 即 epoll（水平触发 LT 模式）。Netty 提供了 `EpollEventLoopGroup`（直接调 JNI epoll，支持边缘触发 ET，性能更好但只能 Linux）。

**Q6：select/poll/epoll 区别？**
（详见 [多路复用](./多路复用.md)）一句话：epoll 用红黑树注册 fd + 双向链表存就绪 fd，无需每次重传 fd 列表，O(1)。

**Q7：什么是 C10K / C10M 问题？**
C10K（2002）：单机 1 万并发连接，BIO 解决不了 → 催生 epoll/kqueue。
C10M：单机千万连接，需要 DPDK / 用户态协议栈（XDP）等绕过内核网络栈。

**Q8：Netty 为什么不直接用 JDK NIO？**
- 修复了 epoll 空轮询 bug。
- 提供更好的 ByteBuf（池化、引用计数、零拷贝）。
- 封装了协议解析、心跳、流控等。
- 提供原生 epoll/kqueue/io_uring transport（性能比 JDK NIO 好 10%~30%）。

**Q9：Reactor 中如果业务很慢怎么办？**
单/单 Reactor 模型必崩。三个选项：
1. 业务异步化（DB/RPC 用 CompletableFuture）。
2. 业务派发到独立线程池（Netty `EventExecutorGroup`）。
3. 主从 Reactor + 业务池分离（生产标准）。

**Q10：epoll 的 LT 和 ET 区别？**
- **LT（水平触发）**：只要 fd 可读就一直通知。**默认**，编程简单（少读没事下次还会通知）。
- **ET（边缘触发）**：仅在状态**变化**时通知一次。必须**一次读完**（`while(read)` 直到 EAGAIN），否则丢事件。Nginx / Netty epoll transport 用 ET，性能更好但门槛高。

---

## 八、答题模板（60 秒话术）

> "IO 模型有 5 种，但生产真正用的就两种：**BIO 和 NIO 多路复用**。
>
> BIO 是 **1 连接 1 线程**，C10K 就崩，老 Tomcat 是这种，已经被 NIO 替代。
>
> 主流方案是 **NIO + Reactor 模式**——单线程通过 `epoll` 监听上万个 fd，哪个就绪了就处理哪个，**1 线程管 N 连接**。Java 的 Selector 底层就是 epoll。
>
> 工业实现都是 **主从 Reactor**：BossGroup 只 accept，WorkerGroup 处理读写，业务用独立线程池——Netty / Tomcat NIO / Nginx 全是这个套路。
>
> AIO 理论最优（① ② 都异步），但 Linux 网络 AIO 是 epoll 模拟的，性能没优势，所以 Java 服务端基本不用，**未来看 io_uring**。
>
> 关键点：① 同步异步 是看**数据拷贝**谁做；② 阻塞非阻塞 是看**没准备好**怎么处理 ——这两个是正交的。NIO 是同步非阻塞 + 多路复用。"

---

## 九、相关文档

- [多路复用 select/poll/epoll](./多路复用.md) — IO 多路复用底层机制深挖
- [零拷贝](./零拷贝.md) — mmap / sendfile / splice
- [Netty](../Middleware/Netty.md) — 主从 Reactor 的工业实现
- [RPC 原理](../Middleware/RPC原理.md) — RPC 框架的网络层都建立在 NIO 上
- [Redis 工作流程](../Redis/工作流程.md) — 单 Reactor 的极致案例
- [Concurrency / 进程与线程](../Concurrency/进程与线程.md) — 线程模型基础
