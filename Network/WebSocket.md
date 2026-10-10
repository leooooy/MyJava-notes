# WebSocket

> IM / 实时游戏 / 协同编辑 / 股票行情 / 直播弹幕 必备 —— **服务端主动推消息**的标准协议。
> 本篇要解决：
> ① **HTTP 长轮询 / SSE / WebSocket** 推送方案的演进与取舍
> ② **WebSocket 协议**：握手（HTTP Upgrade）+ 帧格式 + 控制帧
> ③ **Netty 实现 WebSocket** 的标准代码与心跳保活
> ④ **千万长连接架构**：分层、连接管理、广播、跨服推送
> ⑤ 生产踩坑：粘包、心跳、断连重连、鉴权、消息可靠性

> 大厂面试问 WebSocket 重点：**握手过程 + 跟 SSE 的区别 + 海量长连接的架构 + 心跳设计**。

---

## 一、为什么需要 WebSocket

HTTP 是**请求-响应模型**——服务端无法主动给客户端推消息。早期推送方案：

| 方案 | 原理 | 缺点 |
| --- | --- | --- |
| **轮询**（短轮询） | 客户端每 N 秒发请求问"有新消息吗" | 实时性差 + 浪费带宽 |
| **长轮询**（Long Polling） | 客户端发请求，服务端**hang 住**直到有数据或超时 | 仍要每次重新建连，单向 |
| **iframe 流** | 隐藏 iframe 持续接收 | 浏览器兼容差，已废 |
| **SSE**（Server-Sent Events） | 基于 HTTP，**单向**服务端推 | 单向（client→server 还得用 HTTP） |
| **WebSocket** ⭐ | 协议升级，**双向全双工** | 需要协议支持（中间代理可能阻塞） |

**WebSocket 核心价值**：
- ✅ **双向全双工**：Server / Client 谁都能主动发消息。
- ✅ **持久连接**：握手一次后长连接，省 HTTP 头开销。
- ✅ **低延迟**：消息 frame 几个字节头部 + 数据，无 HTTP header。
- ✅ **复用 80/443 端口**：穿越防火墙友好（HTTPS 走 443）。

---

## 二、WebSocket vs SSE vs 长轮询（**面试必问**）

| 维度 | 长轮询 | SSE | WebSocket |
| --- | --- | --- | --- |
| 协议 | HTTP | HTTP | TCP（HTTP 升级） |
| 方向 | 单向（Server→Client） | **单向**（Server→Client） | **双向** |
| 协议开销 | 大（每次新 HTTP 请求） | 中（首次 HTTP 后保持） | **小**（几字节帧头） |
| 实时性 | 差（一次请求一次响应） | 好 | **极好** |
| 二进制 | ❌ | ❌（仅文本） | ✅ |
| 自动重连 | 业务自己实现 | **内置**（EventSource API） | 业务自己实现 |
| 浏览器支持 | 全 | 全（IE 没有，但极小） | 全 |
| 复杂度 | 简单 | 简单 | 中 |

**怎么选**：
- 只要服务端推（如股票行情、新闻流、AI 流式输出 ChatGPT）→ **SSE**（更简单 + 自动重连 + HTTP 友好，可复用 HTTP/2 流）。
- 双向交互（IM、游戏、协同编辑）→ **WebSocket**。
- 老浏览器兼容 → **长轮询**兜底。

> ⚠️ ChatGPT 这类 LLM 流式输出**用的就是 SSE**——单向推送，不需要 WebSocket 的复杂度。

---

## 三、WebSocket 协议

### 3.1 握手（基于 HTTP Upgrade）

```
   Client                                          Server
     │                                              │
     │ GET /chat HTTP/1.1                          │
     │ Host: example.com                           │
     │ Upgrade: websocket                          │ ← 升级协议
     │ Connection: Upgrade                          │
     │ Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ== │ ← 16 字节随机 base64
     │ Sec-WebSocket-Version: 13                    │
     │ Sec-WebSocket-Protocol: chat                │ ← 子协议（可选）
     │ ────────────────────────────────────────────►│
     │                                              │
     │ HTTP/1.1 101 Switching Protocols             │
     │ Upgrade: websocket                            │
     │ Connection: Upgrade                          │
     │ Sec-WebSocket-Accept: s3pPLMBiTxaQ9kY...     │ ← 服务端校验后回的
     │ ◄─────────────────────────────────────────── │
     │                                              │
     │           （之后 TCP 通道用 WebSocket frame） │
     │ ◄─────────────────────────────────────────► │
```

**`Sec-WebSocket-Accept` 怎么算**：
1. Server 把 `Sec-WebSocket-Key` 拼接固定 GUID `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`。
2. SHA-1 哈希。
3. Base64 编码。

**目的**：防止非 WebSocket 客户端误连（如缓存的旧 HTTP 响应）。

### 3.2 帧格式（Frame）

```
   0                   1                   2                   3
   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  ┌─┬─┬─┬─┬───────┬─┬─────────────┬───────────────────────────────┐
  │F│R│R│R│ opcode│M│  Payload len │  Extended payload length      │
  │I│S│S│S│  (4)  │A│     (7)      │             (16/64)           │
  │N│V│V│V│       │S│              │   (if payload len==126/127)   │
  │ │1│2│3│       │K│              │                                │
  ├─┴─┴─┴─┴───────┴─┴─────────────┴───────────────────────────────┤
  │     Masking-key (32 bits, only if MASK==1)                     │
  ├───────────────────────────────────────────────────────────────┤
  │                       Payload Data                              │
  └───────────────────────────────────────────────────────────────┘
```

**关键字段**：
- **FIN**：是否最后一帧（0 = 还有续帧，分片传输用）。
- **Opcode**：帧类型。
- **MASK**：客户端→服务端必须 mask（防代理缓存污染）；服务端→客户端不 mask。
- **Payload len**：≤125 直接表示；126 = 后面 2 字节真长度；127 = 后面 8 字节真长度（最大支持 2^63 字节）。

### 3.3 Opcode（帧类型）

| Opcode | 类型 | 说明 |
| --- | --- | --- |
| 0x0 | Continuation | 续帧（分片消息的中间帧） |
| 0x1 | **Text** | UTF-8 文本 |
| 0x2 | **Binary** | 二进制（IM 文件、Protobuf） |
| 0x8 | **Close** | 关闭帧 |
| 0x9 | **Ping** | 心跳请求 |
| 0xA | **Pong** | 心跳响应 |

**控制帧**（Close / Ping / Pong）规则：
- Payload ≤ 125 字节。
- 不可分片（FIN 必须 1）。
- 优先级高于数据帧。

---

## 四、Netty 实现 WebSocket（生产标准代码）

```java
public class WebSocketServer {
    public static void main(String[] args) {
        EventLoopGroup boss = new NioEventLoopGroup(1);
        EventLoopGroup worker = new NioEventLoopGroup();
        try {
            ServerBootstrap b = new ServerBootstrap()
                .group(boss, worker)
                .channel(NioServerSocketChannel.class)
                .childHandler(new ChannelInitializer<SocketChannel>() {
                    protected void initChannel(SocketChannel ch) {
                        ChannelPipeline p = ch.pipeline();
                        // ① HTTP 编解码（握手阶段是 HTTP）
                        p.addLast(new HttpServerCodec());
                        // ② 大文件流式
                        p.addLast(new ChunkedWriteHandler());
                        // ③ HTTP 消息聚合（合并 chunked 为完整 FullHttpRequest）
                        p.addLast(new HttpObjectAggregator(64 * 1024));
                        // ④ WebSocket 协议处理（处理握手 + 帧编解码 + Close 帧）
                        p.addLast(new WebSocketServerProtocolHandler(
                            "/chat",                  // 路径
                            null,                     // 子协议
                            true,                     // 允许扩展
                            65536,                    // 单帧最大长度
                            false,                    // 检查 origin
                            true                      // 允许扩展头部
                        ));
                        // ⑤ 业务 Handler
                        p.addLast(new WebSocketBizHandler());
                        // ⑥ 心跳：60s 读空闲触发
                        p.addLast(new IdleStateHandler(60, 0, 0, TimeUnit.SECONDS));
                    }
                });
            ChannelFuture f = b.bind(8080).sync();
            f.channel().closeFuture().sync();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } finally {
            boss.shutdownGracefully();
            worker.shutdownGracefully();
        }
    }
}

// 业务 Handler
public class WebSocketBizHandler extends SimpleChannelInboundHandler<WebSocketFrame> {

    protected void channelRead0(ChannelHandlerContext ctx, WebSocketFrame frame) {
        if (frame instanceof TextWebSocketFrame) {
            String text = ((TextWebSocketFrame) frame).text();
            // 处理文本消息
            ctx.writeAndFlush(new TextWebSocketFrame("echo: " + text));
        } else if (frame instanceof BinaryWebSocketFrame) {
            // 处理二进制
        } else if (frame instanceof PingWebSocketFrame) {
            // Netty 已自动响应 Pong，业务一般不用处理
        }
    }

    @Override
    public void userEventTriggered(ChannelHandlerContext ctx, Object evt) {
        if (evt instanceof IdleStateEvent) {
            // 60s 读空闲 → 主动 Ping，超时关连接
            if (((IdleStateEvent) evt).state() == IdleState.READER_IDLE) {
                ctx.writeAndFlush(new PingWebSocketFrame()).addListener(future -> {
                    if (!future.isSuccess()) ctx.close();
                });
            }
        }
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
        cause.printStackTrace();
        ctx.close();
    }
}
```

**关键 Pipeline 顺序（不能错）**：
1. HttpServerCodec：HTTP 编解码（握手用）。
2. HttpObjectAggregator：合并 chunked → FullHttpRequest（升级请求需要完整 HTTP）。
3. **WebSocketServerProtocolHandler**：握手 + 帧解码（最关键，握手成功后**自动从 Pipeline 移除 HTTP Handler**）。
4. 业务 Handler。

---

## 五、心跳设计（**生产必问**）

### 5.1 为什么要心跳

WebSocket 看起来是长连接，但实际中：
- **NAT 设备 / 防火墙** 5 分钟无流量会清表，连接静默断开（双方不知道）。
- **代理 / LB** 也有 idle timeout（Nginx 默认 60s）。
- **客户端进程被 kill / 网络断开**，TCP 不会立即通知（要等 keepalive，默认 2 小时）。

### 5.2 心跳方案

| 方案 | 实现 | 优劣 |
| --- | --- | --- |
| **TCP keepalive** | 内核级 | 默认 2 小时太晚，**不靠谱** |
| **WebSocket Ping/Pong** | 协议级（Opcode 0x9/0xA） | **推荐**——浏览器自动响应 Pong |
| **应用层心跳消息** | 业务自定义（如 `{"type":"ping"}`） | 可携带业务信息，但流量略大 |

### 5.3 心跳间隔

```
客户端发 Ping 间隔 < 服务端读超时 < NAT/LB idle timeout
       30s        <       60s       <       180s
```

**生产配置**：
- 客户端：每 30s 发 Ping。
- 服务端：60s 读空闲触发警告，120s 没收到任何帧关连接（IdleStateHandler）。
- LB：keepalive_timeout 调到 300s。

### 5.4 浏览器自动 Pong

**好消息**：浏览器（Chrome / Firefox / Safari）收到 Ping 帧**自动回 Pong**，业务代码不用处理。
**坏消息**：浏览器**不暴露 Ping/Pong API**——浏览器代码不能主动发 Ping，只能用应用层心跳。

```javascript
// 浏览器只能用应用层心跳
const ws = new WebSocket('wss://example.com/chat');
setInterval(() => ws.send(JSON.stringify({type: 'ping'})), 30000);
```

---

## 六、海量长连接架构（千万级）

### 6.1 单机限制

**单机 WebSocket 连接数瓶颈**：
- 文件描述符上限：`ulimit -n` 默认 1024，调到 100w+。
- 端口范围：服务端用一个端口接所有连接（不受 65535 限制）；客户端发起方受端口限制。
- TCP 连接元数据 = 内存：每连接 ~10KB → 100w 连接 = 10GB。
- **CPU**：心跳 + 业务处理是真正瓶颈（连接数本身不耗 CPU，**业务消息量**才是）。

**单机经验值**：现代机器（32 核 + 64GB）+ Netty + 优化后，**单机 50w~100w 长连接**没问题。

### 6.2 千万长连接架构

```
                     ┌─────────────────┐
                     │   LB (Nginx /    │ ← TCP 直通（stream），不解 HTTP
                     │   F5 / SLB)      │
                     └─────────┬────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        ▼                      ▼                      ▼
   ┌─────────────┐       ┌─────────────┐       ┌─────────────┐
   │ WS 接入层 1 │       │ WS 接入层 2 │  ...  │ WS 接入层 N │ ← 每台 50w 连接
   │ (Netty)     │       │             │       │             │
   └──────┬──────┘       └──────┬──────┘       └──────┬──────┘
          │                     │                     │
          └─────────┬───────────┴───────────┬─────────┘
                    │                       │
                    ▼                       ▼
          ┌──────────────────┐   ┌──────────────────┐
          │  消息总线 Kafka  │   │  Redis (uid →    │ ← 用户在哪台接入机器
          │ (业务异步)        │   │ ws_node) 路由表 │
          └──────────────────┘   └──────────────────┘
                    │
                    ▼
          ┌──────────────────┐
          │   业务服务集群    │
          │  (用户 / 消息 /   │
          │   推送决策)       │
          └──────────────────┘
```

**关键设计**：
1. **接入层无状态**：连接来了随机分配；用户登录后用 Redis 记录 `uid → ws_node`。
2. **下发消息时查路由**：业务系统发消息给 uid → 查 Redis 拿到 ws_node → 用 RPC / Kafka 把消息派给该 node → node 找到对应 channel push。
3. **断线重连**：客户端记 sessionId，重连时 Server 在 Redis 找回历史会话。
4. **跨机房灾备**：每个机房一组 LB + 接入层，DNS 切换。

### 6.3 广播 / 群聊场景

**问题**：1 万人群聊一条消息要复制 1 万份。

**典型方案**：
- **小群（< 200）**：扇出（fan-out）—— 每条消息查群成员表，给每个用户路由分发。
- **大群（千人 / 万人 / 万人粉丝）**：拉模式 —— 群里只存最新 N 条，每个用户重连时主动拉。
- **超大群（百万直播间）**：分片广播 —— 用户按机房 / 节点分组，节点间用 Kafka 广播 → 节点内推送。

---

## 七、断连重连策略

### 7.1 客户端重连

```javascript
let reconnectInterval = 1000;        // 1s 起
function connect() {
    const ws = new WebSocket('wss://example.com/chat');
    ws.onopen = () => { reconnectInterval = 1000; /* 重置 */ };
    ws.onclose = () => {
        setTimeout(connect, reconnectInterval);
        reconnectInterval = Math.min(reconnectInterval * 2, 30000);  // 指数退避，max 30s
    };
}
```

**关键点**：
- **指数退避 + 上限**：避免雪崩。
- **抖动 jitter**：重连时间加随机扰动（如 ±20%），避免百万客户端同时重连。
- **重连后状态恢复**：上传 sessionId 让 Server 找回会话。

### 7.2 服务端

- **Session 不绑定 channel**：channel 断了 Session 还在 Redis（短暂保留 30s）。
- **重连验证**：客户端重连带 token + sessionId，验证后接管旧 Session。

---

## 八、消息可靠性

WebSocket 协议本身不保证消息送达——**TCP 保证字节流可靠，但客户端应用没收到就崩**了 / **消息在网络中**时连接断了，都会丢。

**可靠投递三件套**（IM 必备）：

| 机制 | 解释 |
| --- | --- |
| **消息 ID + ACK** | Server 发消息带 msgId，Client 收到回 ACK；Server 收不到 ACK 重发 |
| **去重** | Client 用 msgId 去重，避免重复入库 / 显示 |
| **离线消息** | Client 不在线时存 Redis / DB，上线时拉取 |
| **顺序保证** | 同一会话用单分区 / 单线程处理，Client 用 seqId 重排 |

**对应 MQ 模块**：[MQ / 消息可靠性](../MQ/消息可靠性.md) 的思路完全可复用——At-Least-Once + 业务幂等。

---

## 九、Nginx 反代 WebSocket（生产配置）

```nginx
location /chat {
    proxy_pass http://ws_backend;

    # 关键三行：必须显式开 Upgrade
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "Upgrade";

    # 长连接超时调长（默认 60s 不够）
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;

    # 客户端 IP
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

**坑**：
- ❌ 不加 Upgrade / Connection 头 → Nginx 当普通 HTTP 处理 → 握手失败。
- ❌ proxy_read_timeout 默认 60s → 连接 1 分钟无消息就断（要么调长要么应用层心跳 < 60s）。

---

## 十、生产踩坑

### 坑 1：浏览器无法主动发 Ping 帧

浏览器 WebSocket API 没暴露 Ping → 客户端心跳只能用应用层（自定义消息）。

### 坑 2：跨机房 / Wi-Fi → 4G 切换连接断

WebSocket 不像 QUIC 支持 Connection ID → IP 一变就断。
**修复**：客户端检测网络变化主动重连 + 上传 sessionId 接管旧会话。

### 坑 3：海量长连接下 GC 卡顿

长连接对象常驻堆 → 老年代爆 → Full GC 几秒 → 全员超时断连。
**修复**：
- 用堆外内存（Netty PooledByteBufAllocator + Direct）。
- G1 / ZGC（停顿 < 10ms）。
- 监控 + 限制单机连接数（如 50w 满了就拒绝）。

### 坑 4：心跳没设导致 NAT 后连接静默失效

5 分钟无流量 NAT 清表 → 客户端发消息收到 RST。
**修复**：客户端 30s 心跳，远小于 NAT 默认超时（5 分钟）。

### 坑 5：未鉴权直接接受 WebSocket

WebSocket 握手是 HTTP，但**很多人忽略握手时鉴权**，导致任意用户能连。
**修复**：
- 握手 URL 带 token（`wss://...?token=xxx`）。
- HttpServerHandler 解析 token 校验，不通过则握手前关闭。
- **不要把 token 放 Subprotocol**（容易被代理记录）。

### 坑 6：单帧无上限 → OOM

恶意客户端发 8GB 单帧 → Netty 缓冲区爆。
**修复**：`WebSocketServerProtocolHandler` 第 4 个参数 `maxFramePayloadLength` 设合理上限（如 64KB）。

### 坑 7：分片消息没处理

WebSocket 支持把大消息分多帧发（FIN=0 续帧）。
**修复**：用 Netty 的 `WebSocketFrameAggregator` 自动合并：

```java
p.addLast(new WebSocketFrameAggregator(1024 * 1024));   // 最大合并 1MB
```

### 坑 8：广播消息阻塞 EventLoop

群聊 1w 人，写循环 `for (Channel ch : group) ch.writeAndFlush(msg)` → 单线程串行写 → 卡死。
**修复**：用 ChannelGroup 的 `writeAndFlush(msg)` 内部并行；超大群用消息总线（Kafka）异步广播。

### 坑 9：CPU 100% → 才发现是 SSL handshake 风暴

千万级断连 + 重连同时发生（如服务发版重启）→ TLS 握手压垮 CPU。
**修复**：
- 客户端重连指数退避 + 抖动。
- TLS 1.3 + session resumption（0/1 RTT 握手）。
- Nginx 边缘 TLS 卸载。

### 坑 10：浏览器关闭页面但 Server 没收到 close 帧

浏览器突然关闭 / 进程被杀 → TCP 半关闭，Server 还以为连接活着 → 占资源。
**修复**：必须靠**心跳**检测——只信心跳，不信 close 帧。

---

## 十一、面试高频追问

**Q1：WebSocket 跟 HTTP 关系？**
WebSocket **借助 HTTP 升级**建立连接（GET + Upgrade: websocket → 101 Switching Protocols），握手后**协议升级为 WebSocket**——之后 TCP 通道用 WebSocket 帧通信，不再是 HTTP。

**Q2：WebSocket 跟 SSE 怎么选？**
- 单向（服务端推）→ SSE（基于 HTTP，**自动重连**，简单）。
- 双向（IM / 游戏）→ WebSocket。
- ChatGPT 流式输出用的是 SSE，不是 WebSocket。

**Q3：握手过程？Sec-WebSocket-Key 干嘛的？**
Client 发 Upgrade: websocket + 16 字节随机 Key（base64）→ Server 拼接固定 GUID 做 SHA-1 + base64 → 回 Sec-WebSocket-Accept。**目的**：防止非 WebSocket 客户端误连（如缓存的旧 HTTP 响应）。

**Q4：为什么 Client→Server 要 mask 但反向不用？**
防代理缓存污染——某些老代理把 WebSocket 流当 HTTP 缓存，mask 让数据看起来像随机字节，无法被缓存。Server→Client 没这个问题。

**Q5：怎么做心跳？**
- 协议层：WebSocket Ping/Pong 帧（浏览器自动响应 Pong）。
- 浏览器**不能主动发 Ping**——必须用应用层 JSON 心跳（`{"type":"ping"}`）。
- 服务端用 IdleStateHandler 监听读空闲，超时关连接。

**Q6：单机能扛多少长连接？**
理论上百万——`ulimit -n` 调大 + 内存够。生产**单机 50~100w** 是常见值，瓶颈通常是消息量带来的 CPU 而非连接数本身。

**Q7：千万长连接怎么架构？**
- 接入层无状态 + 横向扩展（每机 50w）。
- Redis 存 `uid → ws_node` 路由表。
- 业务下发消息时查路由 → RPC / Kafka 派给目标 node → node 找 channel push。
- 心跳 + Session 短保留 → 重连恢复。

**Q8：Nginx 怎么反代 WebSocket？**
必须三件套：
```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "Upgrade";
```
+ proxy_read_timeout 调长（默认 60s 不够）。

**Q9：消息可靠性怎么保证？**
WebSocket 协议本身不保证应用层送达。要做：
- 消息 ID + ACK + 重发。
- 去重（msgId 幂等）。
- 离线存储（不在线 → DB/Redis → 上线拉取）。
- 顺序（同会话单分区 / Client seqId 重排）。

**Q10：怎么鉴权？**
握手时（HTTP 阶段）解析 token，不通过则握手前关闭：

```java
public class AuthHandler extends SimpleChannelInboundHandler<FullHttpRequest> {
    protected void channelRead0(ChannelHandlerContext ctx, FullHttpRequest req) {
        String token = extractToken(req.uri());
        if (!validate(token)) {
            ctx.writeAndFlush(new DefaultFullHttpResponse(HTTP_1_1, UNAUTHORIZED))
               .addListener(ChannelFutureListener.CLOSE);
            return;
        }
        ctx.fireChannelRead(req.retain());          // 通过则继续
    }
}
```

**Q11：WebSocket 跟 Long Polling 比性能好多少？**
长轮询每条消息 = 1 次 HTTP 请求（几百字节 header + TLS 握手）→ 1k 用户每分钟 1 条消息 = 1k req/min HTTP 流量。
WebSocket 每条消息 = 几字节帧头 + 数据 → 流量小 5-10x，延迟低 10x（无握手）。

**Q12：WebSocket 用 HTTP/2 / HTTP/3 吗？**
- HTTP/2：RFC 8441 定义了 "WebSocket over HTTP/2"，但**实际部署很少**——大多 WebSocket 仍用 HTTP/1.1 升级。
- HTTP/3：RFC 9220 定义 "WebSocket over HTTP/3"，更新。
- **生产基本都是 HTTP/1.1 升级**——简单 + 兼容性好。

**Q13：WebSocket 的子协议 Sec-WebSocket-Protocol 是什么？**
握手时双方协商的应用层协议（如 STOMP / MQTT-over-WebSocket）。Client 列出支持的，Server 选一个回。

**Q14：浏览器关 tab 后 Server 怎么知道？**
- 正常关闭：浏览器发 Close 帧。
- 异常关闭（kill 浏览器 / 拔网线）：**TCP 半关闭，Server 一段时间后才知道** → 必须靠心跳超时检测。

**Q15：WebSocket 跟 TCP socket 区别？**
- TCP socket 是**裸字节流**，要自己设计协议（粘包 / 心跳 / 帧）。
- WebSocket 是 TCP 之上的**应用层协议**，帮你解决了帧、心跳、关闭、握手等。
- 浏览器只能用 WebSocket（不能直接用 TCP）；服务端之间通信用 TCP / RPC 即可。

---

## 十二、答题模板（60 秒话术）

> "WebSocket 是基于 TCP 的双向全双工应用层协议，**借 HTTP 升级**握手——客户端发 Upgrade: websocket + 随机 Key，服务端校验后回 101 Switching Protocols，之后协议升级为 WebSocket。
>
> **跟 SSE 区别**：SSE 单向（Server→Client，基于 HTTP，自动重连），WebSocket 双向（基于 TCP，更灵活但要自己处理重连）。**ChatGPT 流式输出用的是 SSE 不是 WebSocket**——单向场景 SSE 更简单。
>
> **帧格式**：FIN + Opcode + Mask + Payload Len + Data。Opcode 0x1 文本、0x2 二进制、0x8 关闭、0x9 Ping、0xA Pong。**Client→Server 必须 mask**（防代理缓存污染），Server→Client 不 mask。
>
> **心跳必做**：NAT / LB 5 分钟无流量清表 → 连接静默失效。客户端 30s 应用层心跳（浏览器不能主动发 Ping 帧），服务端用 Netty IdleStateHandler 60s 读空闲超时关连接。
>
> **Nginx 反代三件套**：`proxy_http_version 1.1` + `Upgrade $http_upgrade` + `Connection "Upgrade"` + 调大 proxy_read_timeout。
>
> **海量长连接架构**：单机 50~100w，多机水平扩展，Redis 存 `uid → ws_node` 路由表，业务下发消息时查路由派给目标 node，再 push 给对应 channel。超大群用 Kafka 广播 + 节点内分发。
>
> **消息可靠性**：WebSocket 协议不保证，要应用层做 ACK + 重发 + 去重 + 离线消息 + 顺序保证。
>
> **生产坑**：① 浏览器不能主动 Ping，必应用层心跳；② Nginx 默认 60s 超时太短；③ 海量长连接 Full GC 卡顿——用 ZGC / 堆外内存；④ 单帧 maxFramePayloadLength 必设防 OOM；⑤ 鉴权要在 HTTP 握手阶段做不要等握手完。"

---

## 十三、相关文档

- [HTTP 协议](./HTTP协议.md) — WebSocket 握手依赖 HTTP Upgrade
- [TCP 协议](./TCP协议.md) — WebSocket 底层是 TCP（心跳 / NAT 失效根因）
- [Netty](../Middleware/Netty.md) — 实现 WebSocket 服务端的标准框架
- [Nginx](../Middleware/Nginx.md) — 反向代理 WebSocket 配置
- [MQ / 消息可靠性](../MQ/消息可靠性.md) — IM 消息可靠投递参考
- [Redis / 消息队列方案](../Redis/消息队列方案.md) — 长连接路由表 / 离线消息存储
