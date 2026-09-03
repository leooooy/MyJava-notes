# Netty

> Netty 是大厂中间件**面试 TOP 1** 的必考——RocketMQ / Dubbo / Spark / gRPC-Java / ES Transport / SkyWalking 全都用 Netty 做网络通信。
> 本篇要解决：
> ① Netty 架构 = **NIO 多路复用 + Reactor 模式 + Pipeline 责任链 + 内存池 + 协议封装** 的组合拳
> ② **EventLoop 线程模型**：为什么"一个 channel 绑定一个线程"是无锁的钥匙
> ③ **ByteBuf** 比 JDK ByteBuffer 强在哪、池化怎么做的
> ④ **Pipeline + Handler** 责任链：Inbound / Outbound 数据流向、ChannelHandler 生命周期
> ⑤ 经典生产坑：**TCP 粘包拆包、内存泄漏、心跳与空闲检测**

> 答这块要点：能说清 **为什么不用 JDK NIO** + **Reactor 三种模型** + **Pipeline 数据流向** + **ByteBuf 池化** ——基本就过 P6+ 了。

---

## 一、Netty 是什么 / 解决什么

JDK 原生 NIO 直接用有 5 大坑：

| JDK NIO 痛点 | Netty 解法 |
| --- | --- |
| API 复杂（Selector/Channel/Buffer 三件套） | 封装为 `Bootstrap` / `Channel` / `ChannelHandler` 链式 API |
| epoll 空轮询 BUG | 自动重建 Selector |
| ByteBuffer 设计反人类（position/limit/flip） | ByteBuf 双指针（readerIndex / writerIndex） + 池化 |
| 缺协议（粘包/拆包/编解码全要自己写） | 提供 LengthFieldBasedFrameDecoder / 各种 Codec |
| 缺心跳、空闲检测、流控 | IdleStateHandler / FlowControl / Backpressure |

**所以 Netty 不是 NIO 的替代品，而是 NIO 之上的工程化封装**。RocketMQ / Dubbo / Elasticsearch 不愿自己造轮子，全选 Netty。

---

## 二、整体架构（一图流）

```
┌──────────────────────────────────────────────────────────────────────────┐
│                            Netty 架构                                     │
│                                                                          │
│  ┌─────────────────────┐         ┌─────────────────────┐                │
│  │   BossGroup         │         │   WorkerGroup       │                │
│  │  (NioEventLoop[1])  │         │  (NioEventLoop[N])  │                │
│  │   ┌───────────┐     │         │   ┌───────────┐     │                │
│  │   │ Selector  │     │ accept  │   │ Selector  │     │                │
│  │   │  + queue  │ ──► │ 派发    │   │  + queue  │     │                │
│  │   └─────┬─────┘     │         │   └─────┬─────┘     │                │
│  │         │           │         │         │           │                │
│  └─────────┼───────────┘         └─────────┼───────────┘                │
│            │                               │                            │
│            ▼                               ▼                            │
│  ServerSocketChannel            SocketChannel (per connection)          │
│                                          │                              │
│                                          ▼                              │
│                              ┌─────────────────────┐                    │
│                              │   ChannelPipeline   │                    │
│                              │  ┌───────────────┐  │                    │
│                       数据流  │  │ HeadHandler   │  │                    │
│                          ──► │  └──────┬────────┘  │                    │
│                              │  ┌──────▼────────┐  │                    │
│                              │  │ Decoder       │  │ ← Inbound          │
│                              │  └──────┬────────┘  │                    │
│                              │  ┌──────▼────────┐  │                    │
│                              │  │ BizHandler    │  │                    │
│                              │  └──────┬────────┘  │                    │
│                              │  ┌──────▼────────┐  │ ← Outbound         │
│                              │  │ Encoder       │  │                    │
│                              │  └──────┬────────┘  │                    │
│                              │  ┌──────▼────────┐  │                    │
│                              │  │ TailHandler   │  │                    │
│                              │  └───────────────┘  │                    │
│                              └─────────────────────┘                    │
│                                                                          │
│   ┌──── 池化堆外内存（PooledByteBufAllocator） ────┐                       │
│   │  Arena → ChunkList → Chunk → Page → Subpage    │                    │
│   └─────────────────────────────────────────────────┘                    │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 三、核心组件

### 3.1 Bootstrap / ServerBootstrap（启动器）

```java
EventLoopGroup boss = new NioEventLoopGroup(1);                  // 主 Reactor，accept 用
EventLoopGroup worker = new NioEventLoopGroup();                  // 从 Reactor，IO 读写
                                                                  // 默认 cpu*2

ServerBootstrap b = new ServerBootstrap()
    .group(boss, worker)
    .channel(NioServerSocketChannel.class)                        // Linux 可换 EpollServerSocketChannel
    .option(ChannelOption.SO_BACKLOG, 1024)                       // accept queue 长度
    .childOption(ChannelOption.TCP_NODELAY, true)                 // 关闭 Nagle
    .childOption(ChannelOption.SO_KEEPALIVE, true)
    .childHandler(new ChannelInitializer<SocketChannel>() {
        protected void initChannel(SocketChannel ch) {
            ch.pipeline()
              .addLast(new LengthFieldBasedFrameDecoder(...))     // 解决粘包
              .addLast(new ProtobufDecoder(...))                  // 解码
              .addLast(new IdleStateHandler(60, 0, 0))            // 空闲检测
              .addLast(new BizHandler());
        }
    });

ChannelFuture f = b.bind(8080).sync();
f.channel().closeFuture().sync();
```

**关键参数**：
- `option`：作用于 ServerChannel（接收连接的）。
- `childOption`：作用于每个新连接的 SocketChannel。

---

### 3.2 EventLoop / EventLoopGroup（线程模型）⭐

**EventLoop = 一个线程 + 一个 Selector + 一个任务队列**。

```
NioEventLoop:
  Thread (单一线程)
  Selector (一个 epoll 实例)
  taskQueue (MPSC 队列：主线程往里 add task)
  scheduledTaskQueue (优先队列：定时任务)

  while (!shutdown) {
    ① select(timeoutMillis)             // 等 IO 事件
    ② processSelectedKeys()             // 处理 IO
    ③ runAllTasks()                      // 执行队列里的非 IO 任务
  }
```

**核心机制：一个 Channel 绑定一个 EventLoop（线程） 终生不变**。

带来的好处：
- ✅ **无锁编程**：同一连接的所有读写都在同一线程，不需要锁。
- ✅ **线程亲和（CPU 亲和）**：cache 命中率高。
- ✅ **顺序保证**：消息处理顺序天然有序。

带来的坑：
- ❌ **业务慢拖死整个 EventLoop**——这个 channel 卡了，同一线程上的其他 channel 也卡。

**正确写法**（业务异步化）：

```java
public void channelRead0(ChannelHandlerContext ctx, Msg msg) {
    bizExecutor.execute(() -> {                                  // 业务派发到独立线程池
        Result r = doBusiness(msg);
        ctx.writeAndFlush(r);                                     // 写回会被 EventLoop 调度
    });
}
```

或者注册时用 `EventExecutorGroup`：

```java
ch.pipeline().addLast(bizGroup, new BizHandler());                // 该 Handler 在 bizGroup 上执行
```

---

### 3.3 Channel / ChannelHandlerContext

- `Channel`：一条网络连接的抽象（读、写、连接状态）。
- `ChannelHandlerContext`（ctx）：Channel 的**门面**，每个 Handler 绑一个 ctx。
  - `ctx.write()`：从**当前 Handler** 往前找 Outbound Handler。
  - `channel.write()`：从 **Pipeline 末尾**（TailHandler）往前找。
  - 性能：`ctx.write` 比 `channel.write` 少遍历几次。

---

### 3.4 ChannelPipeline + ChannelHandler（责任链）⭐

**Pipeline 是双向链表**，HeadHandler ↔ ... ↔ TailHandler。

```
                Inbound 流向 →                    ← Outbound 流向
   ┌────────────┐    ┌────────────┐    ┌────────────┐    ┌────────────┐
   │ HeadHandler│ ── │ Decoder    │ ── │ BizHandler │ ── │ Encoder    │ ── TailHandler
   └────────────┘    └────────────┘    └────────────┘    └────────────┘
   socket.read                                            ctx.write/flush 后
   触发 channelRead                                       Outbound 流向左走

Inbound  事件: channelActive / channelRead / channelReadComplete / exceptionCaught
Outbound 事件: bind / connect / write / flush / close
```

**关键点**：
- **Inbound**：从 socket 读到的字节流 → Head → Decoder → Biz（**从前往后**走）。
- **Outbound**：业务调 `ctx.write` 写出去 → Encoder → Head → socket（**从后往前**走）。
- **顺序敏感**：Decoder 必须在 BizHandler **之前**，Encoder 必须在 BizHandler **之后**（从写出方向看）。

**ChannelHandler 类型**：

| 类型 | 接口 | 职责 |
| --- | --- | --- |
| Inbound | ChannelInboundHandler | 处理读事件、连接生命周期 |
| Outbound | ChannelOutboundHandler | 处理写事件、bind/connect |
| Codec | ChannelDuplexHandler / ByteToMessageCodec | Inbound + Outbound 合体 |

**Handler 生命周期**：

```
handlerAdded → channelRegistered → channelActive
  → channelRead × N → channelReadComplete
→ channelInactive → channelUnregistered → handlerRemoved
```

---

### 3.5 ByteBuf（核心数据容器）⭐

**JDK ByteBuffer 的痛点**：
- 单指针 position/limit/capacity，**读写共用 position**，要 `flip()` 切换 → 极易出错。
- 不能扩容。
- 不支持引用计数（GC 控制不可预测）。

**ByteBuf 的解药**：

```
   ┌──────────────────────────────────────────────────────────┐
   │ discardable │   readable    │   writable   │              │
   │   bytes     │     bytes     │    bytes     │              │
   └──────────────────────────────────────────────────────────┘
   0          readerIndex    writerIndex     capacity     maxCapacity
```

- **双指针**：readerIndex / writerIndex 各自独立 → 读写不需要 flip。
- **可扩容**：写满了自动扩到 `maxCapacity`（默认 Integer.MAX_VALUE）。
- **引用计数**：`refCnt`，retain() / release()，**手动控制内存生命周期**。
- **池化**：`PooledByteBufAllocator` 复用堆外内存，省 alloc/free 开销。

**ByteBuf 类型对照**：

| 维度 | 选项 | 说明 |
| --- | --- | --- |
| 内存位置 | Heap / Direct | Heap 在 JVM 堆，GC 管；Direct 堆外，Cleaner 释放 |
| 是否池化 | Pooled / Unpooled | Pooled 复用，**生产首选** |
| 安全性 | Safe / Unsafe | Unsafe 用 sun.misc.Unsafe 直接操作内存，更快 |

**默认（Netty 4.x）**：`PooledByteBufAllocator` + Direct，分配速度比 JDK 快 5-10 倍。

**面试高频**：
- "为什么 Netty 用堆外内存？" → 减少 IO 时 JVM 堆 → Native 堆的拷贝（Java NIO 限制：channel.write 必须从堆外缓冲区发）。
- "PooledByteBufAllocator 怎么实现池化？" → 类似 jemalloc 算法：Arena → ChunkList → Chunk(16MB) → Page(8KB) → Subpage（细粒度切分）。

---

### 3.6 Future / Promise（异步编程）

```java
ChannelFuture f = channel.writeAndFlush(msg);
f.addListener(future -> {
    if (future.isSuccess()) log.info("sent");
    else log.error("failed", future.cause());
});
```

`ChannelFuture extends Future`：
- Netty 不要求 `f.get()` 阻塞。
- 用 listener 做回调，异步链式编排。
- 比 JDK Future 强：可被多个 listener 监听、有 sync 方法但不推荐。

---

## 四、Reactor 模型在 Netty 的实现

| Reactor 模型 | 配置方式 |
| --- | --- |
| 单 Reactor 单线程 | `bootstrap.group(new NioEventLoopGroup(1))` |
| 单 Reactor 多线程 | `bootstrap.group(new NioEventLoopGroup(1))` + 业务用独立 `EventExecutorGroup` |
| **主从 Reactor 多线程**（默认） | `bootstrap.group(bossGroup, workerGroup)` |

### 4.1 默认线程数

```java
// io.netty.util.concurrent.DefaultThreadFactory + NettyRuntime
new NioEventLoopGroup();                     // = 默认 cpu * 2
```

调优：
- IO 密集：cpu * 2（默认）。
- 业务在 IO 线程做轻量计算：cpu * 1。
- BossGroup 1 个就够（单端口 accept 单线程足够）。

### 4.2 EventLoop 调度

每个 EventLoop 一轮事件循环包括：

```
1. selector.select(...)              // 等 IO 事件
2. processSelectedKeys()              // 处理可读、可写、accept
3. runAllTasks(ioRatio)               // 执行非 IO 任务
   - ioRatio 默认 50（IO : 任务 = 1:1）
   - ioRatio = 100 表示无限制跑任务（不推荐）
```

**ioRatio 的意思**：IO 用了 X ns，那么任务最多也跑 (X * (100-ioRatio) / ioRatio) ns。这样可控制业务任务不会饿死 IO 处理。

---

## 五、协议层面的核心问题

### 5.1 TCP 粘包 / 拆包（**面试必问**）

**根因**：TCP 是**字节流**，不保留消息边界。Nagle 算法可能合并小包，MTU 限制可能拆大包 → 应用层收到的一段字节流不一定对应一条业务消息。

**4 种解码策略**：

| 解码器 | 策略 | 适用 |
| --- | --- | --- |
| **FixedLengthFrameDecoder** | 固定长度切分 | 协议字段长度固定 |
| **DelimiterBasedFrameDecoder** | 分隔符切分（如 \r\n） | 文本协议（Redis RESP、HTTP header） |
| **LineBasedFrameDecoder** | 按行（\n 或 \r\n）切分 | 简化版，专门拆行 |
| **LengthFieldBasedFrameDecoder**（最常用）⭐ | **header 里写 body 长度** | RPC、自定义二进制协议 |

**LengthFieldBasedFrameDecoder 的关键参数**：

```java
new LengthFieldBasedFrameDecoder(
    1024 * 1024,    // maxFrameLength：单帧最大长度
    0,              // lengthFieldOffset：长度字段在帧的哪个 offset
    4,              // lengthFieldLength：长度字段占几字节
    0,              // lengthAdjustment：length 字段值 + 这个 = body 实际长度
    4               // initialBytesToStrip：丢弃前 4 字节（即 length 字段本身）
);
```

例：`[length:4B][body:N]` → 配置 `(0, 4, 0, 4)`。

### 5.2 心跳与空闲检测

**为什么要心跳**：
- 防止 NAT 设备/防火墙 5 分钟无流量断连接。
- 检测对端进程已死但 TCP 没及时通知（半连接）。

**Netty 的 IdleStateHandler**：

```java
// 60 秒读空闲、30 秒写空闲、0 表示不监听全空闲
ch.pipeline().addLast(new IdleStateHandler(60, 30, 0, TimeUnit.SECONDS));
ch.pipeline().addLast(new ChannelInboundHandlerAdapter() {
    @Override
    public void userEventTriggered(ChannelHandlerContext ctx, Object evt) {
        if (evt instanceof IdleStateEvent) {
            IdleState state = ((IdleStateEvent) evt).state();
            if (state == IdleState.READER_IDLE) ctx.close();         // 读超时关连接
            if (state == IdleState.WRITER_IDLE) ctx.writeAndFlush(PING);
        }
    }
});
```

**实战**：Dubbo / RocketMQ 都用读超时 90s + 写空闲 30s 发心跳的策略。

---

## 六、零拷贝（Netty 层）

详见 [零拷贝](../Network/零拷贝.md#43-netty-的零拷贝广义零拷贝)，速记：

1. **CompositeByteBuf**：合并多个 ByteBuf 为一个**逻辑视图**，不真拷贝。
2. **slice / duplicate**：共享内存的子视图。
3. **Unpooled.wrappedBuffer(byte[])**：把字节数组**包装**成 ByteBuf。
4. **FileRegion + transferTo**：调 sendfile，OS 层零拷贝。
5. **DirectByteBuf**：堆外内存，省 JVM 堆 → Native 拷贝。

---

## 七、生产踩坑

### 坑 1：内存泄漏（最高频生产事故）

**现象**：服务跑几天后堆外内存涨到几十 G，OOM Killer 杀进程。

**根因**：ByteBuf 用完没 `release()`，PooledByteBufAllocator 无法回收。

**排查**：
```java
// JVM 启动加：
-Dio.netty.leakDetection.level=PARANOID
// 级别：DISABLED < SIMPLE（默认 1% 采样）< ADVANCED（堆栈）< PARANOID（每次都查）
```

**写法**（Netty 5.0+ 推荐）：

```java
// 1. 在最后一个 Handler 让 SimpleChannelInboundHandler 自动 release
public class BizHandler extends SimpleChannelInboundHandler<MyMsg> {
    protected void channelRead0(ChannelHandlerContext ctx, MyMsg msg) {
        // SimpleChannelInboundHandler 自动 release(msg)
    }
}

// 2. 中转时用 ReferenceCountUtil
ReferenceCountUtil.release(msg);

// 3. try-finally 保证释放
ByteBuf buf = ctx.alloc().directBuffer(1024);
try { ... } finally { buf.release(); }
```

### 坑 2：业务阻塞 EventLoop（次高频）

**现象**：QPS 突然崩溃，所有连接超时；线程 dump 看 NioEventLoop 卡在 DB 调用。

**修复**：业务务必用独立线程池。

```java
// 错误写法（DB 调用阻塞 EventLoop）
public void channelRead(...) {
    User u = userMapper.findById(id);                // 阻塞 100ms 拖死整个 EventLoop
    ctx.writeAndFlush(u);
}

// 正确写法
public void channelRead(...) {
    bizExecutor.execute(() -> {
        User u = userMapper.findById(id);
        ctx.writeAndFlush(u);
    });
}
```

### 坑 3：单条大消息撑爆内存

**现象**：解码器 `LengthFieldBasedFrameDecoder` 收到 length=1GB 的恶意包，分配 1GB 内存崩。

**修复**：`maxFrameLength` 设合理上限（如 16MB），超过自动断开。

### 坑 4：粘包/半包没处理 → 业务收到错乱字节

**现象**：业务直接 `channelRead` 处理，没加 LengthFieldBasedFrameDecoder。

**修复**：永远在 Pipeline 第一个加 frame decoder。

### 坑 5：DirectMemory 不受 -Xmx 控制 → 静默撑爆

**现象**：监控只看 JVM 堆没问题，进程突然被 Linux Killer 杀。

**修复**：
- 设置 `-XX:MaxDirectMemorySize=4g` 限制堆外。
- 监控 `BufferPoolMXBean` 暴露的 `direct.MemoryUsed`。

### 坑 6：写半包导致积压

**现象**：客户端连续发大消息，server 端 `OutboundBuffer` 积压几 GB。

**根因**：`channel.writeAndFlush` 把数据放 OutboundBuffer，但内核 socket buffer 满 → 数据卡在 OutboundBuffer → 内存涨。

**修复**：

```java
if (ctx.channel().isWritable()) {                            // 检查可写水位
    ctx.writeAndFlush(msg);
} else {
    // 暂停发送或丢弃
}
```

或调整水位线 `WRITE_BUFFER_WATER_MARK`（默认 32KB / 64KB）。

### 坑 7：epoll 空轮询 → CPU 100%

Netty 已自动修复（详见 [网络IO模型](../Network/网络IO模型.md#坑-1jdk-nio-的-epoll-空轮询-bug必考)），但**自定义 EventLoop 不要绕过 NioEventLoop 的 select() 实现**。

### 坑 8：连接数过万后 Selector.wakeup 慢

**现象**：连接数 5w+ 后，主线程 `channel.writeAndFlush` 偶尔卡 100ms。

**根因**：跨 EventLoop 写时调 `selector.wakeup()`，Linux 上是写 pipe 唤醒，开销随连接数 ↑。

**修复**：业务 channel 数控制在万级、用主从 Reactor 多 Worker 摊平。

---

## 八、面试高频追问

**Q1：为什么用 Netty 不用 JDK NIO？**
- JDK NIO API 复杂、有 epoll 空轮询 bug。
- Netty 提供 ByteBuf 池化、Pipeline 责任链、心跳/空闲检测、各种 Codec、协议封装。
- 主从 Reactor 默认实现，性能调优开关丰富。

**Q2：Netty 主从 Reactor 怎么工作？**
- BossGroup（默认 1）：监听端口，accept 新连接，把新 channel 注册到 WorkerGroup 中某个 EventLoop。
- WorkerGroup（默认 cpu*2）：每个 EventLoop 一线程，负责若干 channel 的 IO 读写。
- **一个 channel 绑定一个 EventLoop 终生不变** → 同 channel 无锁、有序。

**Q3：Netty 的 EventLoop 是什么？为什么无锁？**
EventLoop = 单线程 + Selector + 任务队列。同一 channel 的所有读写都派发到绑定的 EventLoop 执行 → 单线程操作不需锁。

**Q4：跨 channel 的数据怎么交互？**
- 用 EventLoop 的 `execute()` 把任务提交到目标 channel 的 EventLoop。
- 或用 `Channel.writeAndFlush()`，Netty 内部会判断当前线程是否 EventLoop，不是则转交。

**Q5：ByteBuf vs ByteBuffer 区别？**
- ByteBuf 双指针，ByteBuffer 单指针 + flip。
- ByteBuf 可扩容、有引用计数、支持池化。
- ByteBuf 性能在小包高并发下高 10 倍。

**Q6：Pipeline 的 Inbound 和 Outbound 顺序？**
- Inbound：HeadHandler → ... → TailHandler（**从前到后**）。
- Outbound：TailHandler → ... → HeadHandler（**从后到前**）。
- 添加顺序：Decoder 必须在 BizHandler 之前；Encoder 在 BizHandler 之前/之后都行（Outbound 反向走）。

**Q7：怎么处理 TCP 粘包/拆包？**
- 协议设计：定长 / 分隔符 / **header 里写 body length**（最通用）。
- Netty：用 LengthFieldBasedFrameDecoder。

**Q8：Netty 怎么做心跳？**
IdleStateHandler 触发 IdleStateEvent → 自定义 Handler 在 `userEventTriggered` 里发心跳或关闭连接。

**Q9：怎么排查 Netty 内存泄漏？**
启动加 `-Dio.netty.leakDetection.level=PARANOID`，泄漏时打印创建堆栈。检查所有 Handler 是否 release 了 ByteBuf。生产用 SimpleChannelInboundHandler 自动管理。

**Q10：业务慢怎么不阻塞 IO 线程？**
- 把 Handler 注册到独立 `EventExecutorGroup`：`pipeline.addLast(bizGroup, handler)`。
- 业务方法内自己派发到线程池（`executor.execute(...)`）。

**Q11：DirectByteBuf 和 HeapByteBuf 怎么选？**
- 写网络（IO）→ DirectByteBuf（避免 JVM 堆 → Native 拷贝）。
- 业务计算 → HeapByteBuf（GC 管，省心）。
- Netty 4.x 默认 Direct + Pooled。

**Q12：FastThreadLocal 是什么？比 ThreadLocal 快在哪？**
- ThreadLocal 用 ThreadLocalMap（开放寻址哈希）查找，O(1) 但有 hash + probe 开销。
- FastThreadLocal 给每个 FastThreadLocalThread 维护一个**数组 + 索引**——直接 `array[index]` 取值，**真正 O(1)**。
- 仅当线程是 FastThreadLocalThread（NioEventLoop 默认就是）时生效。

**Q13：Netty 的零拷贝有几种？**
（详见 [零拷贝](../Network/零拷贝.md#43-netty-的零拷贝广义零拷贝)）
- **应用层**：CompositeByteBuf、slice、wrappedBuffer。
- **OS 层**：FileRegion + transferTo（sendfile）。
- **JVM 层**：DirectByteBuf（避免堆内堆外拷贝）。

**Q14：Netty 在 Linux 用 epoll 比 NIO 快多少？**
JDK NioEventLoop 用 Java 层 Selector（也是 epoll，LT 模式），Netty 的 EpollEventLoop 直接 JNI 调 epoll（**支持 ET 边缘触发**），性能高 10%~30%。需 `EpollEventLoopGroup` 替换 `NioEventLoopGroup`。

**Q15：Netty 5 为什么消失了又回来了？**
Netty 5.0 alpha 在 2015 年砍掉了，原因是 ForkJoinPool 改造收益不明显但增加了复杂度。**Netty 5（2024）重新发布**，加了 io_uring 支持、ByteBuf API 重构、移除 Unsafe。生产仍以 4.1.x 为主流。

---

## 九、答题模板（60 秒话术）

> "Netty 是 Java 生态最广泛的网络通信框架，核心是**主从 Reactor + Pipeline + ByteBuf + 内存池**。
>
> **线程模型**：BossGroup 一个线程负责 accept，WorkerGroup 默认 cpu*2 个 EventLoop，每个 EventLoop 是 **单线程 + Selector + 任务队列**。**一个 Channel 绑定一个 EventLoop 终生不变**——同 channel 无锁、有序处理。
>
> **数据流**：每个 Channel 有一条 Pipeline（双向链表），Inbound 事件 Head → Tail 走，Outbound 事件 Tail → Head 走。Decoder 在前、Encoder 在后、业务 Handler 在中间。
>
> **ByteBuf** 比 JDK ByteBuffer 强在双指针读写不用 flip、可扩容、引用计数手动控制释放、池化（PooledByteBufAllocator 类似 jemalloc）。**生产默认 Pooled + Direct**。
>
> **协议层**：粘包用 LengthFieldBasedFrameDecoder，心跳用 IdleStateHandler。
>
> **解决了 JDK NIO 的所有痛点**：epoll 空轮询自动修复、提供完整协议解码、零拷贝 API（CompositeByteBuf 应用层 + FileRegion OS 层）。
>
> **生产踩坑 TOP 3**：
> ① **内存泄漏**：ByteBuf 必 release，开 PARANOID 级别检测。
> ② **业务阻塞 EventLoop**：DB / RPC 必派发到独立线程池。
> ③ **maxFrameLength 不设上限**：恶意包能 OOM。
>
> 应用：Dubbo / RocketMQ / Spark / Elasticsearch / gRPC-Java 全用 Netty。"

---

## 十、相关文档

- [网络IO模型](../Network/网络IO模型.md) — Netty 的 NIO 基础
- [多路复用](../Network/多路复用.md) — Netty Selector 底层 epoll
- [零拷贝](../Network/零拷贝.md) — Netty 零拷贝技术全解
- [RPC 原理](./RPC原理.md) — Netty 是大部分 RPC 框架的网络层
- [Dubbo](./Dubbo.md) — Dubbo 网络层默认用 Netty
- [MQ / RocketMQ 架构](../MQ/RocketMQ架构.md) — RocketMQ 通信层
