# Network 网络与 IO 面试模块

> 大厂后端 P6+/高级岗的**底子**——TCP 握手 / HTTP 演进 / 网络 IO 模型 / epoll / 零拷贝答不上来，分布式 / MQ / Redis / Netty 全都讲不深。
>
> 本模块定位为 "**网络协议 + IO 基础设施**" 层，是上面所有应用层中间件的**前置必修**：
>
> ① **网络协议**（TCP / HTTP / HTTPS / WebSocket）—— 所有上层通信的根基
> ② **IO 三件套**（BIO/NIO/AIO + select/poll/epoll + 零拷贝）—— Netty / Nginx / Redis / Kafka 全建立于此
>
> 跟相邻模块的边界：
>
> - 应用层中间件（Netty / Nginx / Dubbo / Elasticsearch / RPC）→ [Middleware 模块](../Middleware/README.md)
> - Spring Cloud 微服务工程（注册中心 / 网关 / 限流 / 链路追踪）→ [Microservice 模块](../Microservice/README.md)
> - 缓存 / 消息 / 数据库 → [Redis](../Redis/README.md) / [MQ](../MQ/README.md) / [MySQL](../MySQL/README.md)

---

## 一、模块导航

### 网络协议（4 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [TCP 协议](./TCP协议.md) | 三次握手 / 四次挥手 / TIME_WAIT / 半连接队列 / Nagle / 拥塞控制 |
| [HTTP 协议](./HTTP协议.md) | 1.0→1.1→2→3 演进 / HTTPS TLS 握手 / 缓存 / CORS / 状态码 |
| [WebSocket](./WebSocket.md) | HTTP Upgrade 握手 / 帧格式 / 心跳 / 海量长连接架构 |
| [WebRTC 与 ICE](./WebRTC与ICE.md) | 信令/媒体/ICE 三大件 / candidate(host/srflx/relay) / STUN/TURN / SFU / 容器 node_ip 坑 |

### 网络 IO 基础（3 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [网络 IO 模型](./网络IO模型.md) | BIO / NIO / AIO 五种模型对比 + Reactor 主从架构 |
| [多路复用](./多路复用.md) | select / poll / epoll 深度对比 + LT/ET + SO_REUSEPORT 惊群 |
| [零拷贝](./零拷贝.md) | mmap / sendfile / splice + Kafka/Netty/RocketMQ 实战 |

### 流量入口（1 篇）

| 文档 | 一句话定位 |
| --- | --- |
| [反向代理](./反向代理.md) | 正向 vs 反向 / L4-L7 / 与 LB&网关&CDN 边界 / X-Forwarded-For 真实 IP 透传 |

---

## 二、面试高频题 → 文档映射

### TCP 协议

| 高频题 | 跳转 |
| --- | --- |
| 三次握手为什么不是两次？ | [TCP](./TCP协议.md) |
| 四次挥手为什么不是三次？ | [TCP](./TCP协议.md) |
| TIME_WAIT 为什么 2MSL？ | [TCP](./TCP协议.md) |
| CLOSE_WAIT 堆积怎么排查？ | [TCP](./TCP协议.md) |
| 半连接 / 全连接队列？SYN flood？ | [TCP](./TCP协议.md) |
| Nagle / TCP_NODELAY / Cork？ | [TCP](./TCP协议.md) |
| 拥塞控制四件套 / BBR？ | [TCP](./TCP协议.md) |
| TCP 粘包根因？ | [TCP](./TCP协议.md) |
| tcp_tw_reuse vs recycle？ | [TCP](./TCP协议.md) |

### HTTP 协议

| 高频题 | 跳转 |
| --- | --- |
| HTTP 1.0 / 1.1 / 2 / 3 演进？ | [HTTP](./HTTP协议.md) |
| HTTP/2 多路复用怎么实现？ | [HTTP](./HTTP协议.md) |
| HTTP/3 为什么用 UDP？ | [HTTP](./HTTP协议.md) |
| HTTPS 混合加密原理？ | [HTTP](./HTTP协议.md) |
| TLS 1.2 vs 1.3 握手？ | [HTTP](./HTTP协议.md) |
| 0RTT 是什么？有什么风险？ | [HTTP](./HTTP协议.md) |
| 缓存机制（强缓存 / 协商缓存）？ | [HTTP](./HTTP协议.md) |
| CORS 跨域怎么实现？ | [HTTP](./HTTP协议.md) |
| 301 vs 302 vs 307 vs 308？ | [HTTP](./HTTP协议.md) |

### IO 模型与多路复用

| 高频题 | 跳转 |
| --- | --- |
| BIO/NIO/AIO 区别？ | [网络IO模型](./网络IO模型.md) |
| 同步异步、阻塞非阻塞 关系？ | [网络IO模型](./网络IO模型.md) |
| Redis 单线程为什么能扛 10w QPS？ | [网络IO模型](./网络IO模型.md) |
| Reactor 主从模型？ | [网络IO模型](./网络IO模型.md) |
| select/poll/epoll 区别？ | [多路复用](./多路复用.md) |
| epoll 红黑树和就绪链表？ | [多路复用](./多路复用.md) |
| LT 和 ET 区别？ | [多路复用](./多路复用.md) |
| epoll 是 mmap 共享内存吗？ | [多路复用](./多路复用.md) |
| 惊群问题怎么解决？ | [多路复用](./多路复用.md) |
| io_uring 跟 epoll 区别？ | [多路复用](./多路复用.md) |

### 零拷贝

| 高频题 | 跳转 |
| --- | --- |
| Kafka 为什么这么快？ | [零拷贝](./零拷贝.md) |
| 传统 IO 4 次拷贝 4 次切换在哪？ | [零拷贝](./零拷贝.md) |
| mmap 和 sendfile 区别和选型？ | [零拷贝](./零拷贝.md) |
| Netty 的零拷贝有几种？ | [零拷贝](./零拷贝.md) |
| sendfile + DMA gather 怎么实现 0 拷贝？ | [零拷贝](./零拷贝.md) |

### WebSocket

| 高频题 | 跳转 |
| --- | --- |
| WebSocket 跟 SSE 怎么选？ | [WebSocket](./WebSocket.md) |
| 握手过程？Sec-WebSocket-Key 干嘛？ | [WebSocket](./WebSocket.md) |
| 怎么设计心跳？ | [WebSocket](./WebSocket.md) |
| Nginx 怎么反代 WebSocket？ | [WebSocket](./WebSocket.md) |
| 千万长连接怎么架构？ | [WebSocket](./WebSocket.md) |
| 消息可靠性怎么保证？ | [WebSocket](./WebSocket.md) |
| 鉴权放在哪做？ | [WebSocket](./WebSocket.md) |
| 浏览器能主动发 Ping 帧吗？ | [WebSocket](./WebSocket.md) |

### 反向代理

| 高频题 | 跳转 |
| --- | --- |
| 正向代理 vs 反向代理一句话区分？ | [反向代理](./反向代理.md) |
| L4 代理和 L7 代理区别？各用在哪？ | [反向代理](./反向代理.md) |
| 反向代理、负载均衡、API 网关、CDN 关系？ | [反向代理](./反向代理.md) |
| 后端为什么拿不到真实客户端 IP？怎么解决？ | [反向代理](./反向代理.md) |
| X-Forwarded-For 被伪造怎么办？ | [反向代理](./反向代理.md) |
| L4 代理怎么透传真实 IP（PROXY protocol）？ | [反向代理](./反向代理.md) |
| HTTPS 卸载在哪做？后端怎么知道原始协议？ | [反向代理](./反向代理.md) |
| 反向代理是单点吗？怎么做高可用？ | [反向代理](./反向代理.md) |

---

## 三、依赖关系图

```
              [TCP 协议]
              三次握手 / 四次挥手
              TIME_WAIT / 拥塞控制
                    │
        ┌───────────┼───────────┐
        ▼           ▼           ▼
   [HTTP 协议]  [WebSocket]  [网络 IO 模型]
   1.0→1.1→2→3  HTTP Upgrade  BIO/NIO/AIO
   HTTPS / TLS  长连接帧格式   Reactor 模式
                                │
                     ┌──────────┴──────────┐
                     ▼                     ▼
                [多路复用]              [零拷贝]
                select/poll/epoll       mmap/sendfile/splice
                     │                     │
                     └──────────┬──────────┘
                                │
                                ▼ 提供基础设施
                       (../Middleware/ 应用层中间件)
                       Netty / Nginx / RPC / Dubbo / ES
```

**核心传导**：

- **协议层**：TCP 是地基；HTTP / WebSocket 都建在 TCP 上；HTTPS = HTTP + TLS。
- **IO 层**：BIO → NIO 多路复用（epoll）→ 零拷贝是中间件性能极致化的关键。
- **应用层**：Netty / Nginx / Redis / Kafka / RocketMQ 全都是"NIO 多路复用 + 零拷贝"的工业级实现。

---

## 四、跨模块联动

| 主题 | 本模块（基础） | 应用 / 实现 |
| --- | --- | --- |
| Netty 线程模型 | [网络 IO 模型](./网络IO模型.md) / [多路复用](./多路复用.md) | [Middleware/Netty](../Middleware/Netty.md) |
| 零拷贝 sendfile/mmap | [零拷贝](./零拷贝.md) | [MQ/存储机制](../MQ/存储机制.md)（CommitLog mmap + 消费 sendfile）<br>[MySQL/三大日志](../MySQL/日志.md)（部分 mmap） |
| epoll 多路复用 | [多路复用](./多路复用.md) | [Redis/工作流程](../Redis/工作流程.md)（单线程 + epoll）<br>[Middleware/Nginx](../Middleware/Nginx.md) |
| TCP 粘包 | [TCP 协议](./TCP协议.md) | [Middleware/Netty](../Middleware/Netty.md)（LengthFieldBasedFrameDecoder）<br>[Middleware/RPC 原理](../Middleware/RPC原理.md)（协议设计） |
| HTTP/2 + Reactor Netty | [HTTP 协议](./HTTP协议.md) | [Microservice/SpringCloudGateway](../Microservice/SpringCloudGateway.md) |
| WebSocket 长连接 | [WebSocket](./WebSocket.md) | [Middleware/Netty](../Middleware/Netty.md) + [Middleware/Nginx](../Middleware/Nginx.md) 反代 |

---

## 五、推荐学习路径

### 新手路径（按依赖顺序）

```
1. TCP 协议             ← 一切上层通信的根
2. HTTP 协议            ← Web 必修（含 HTTPS / TLS）
3. 网络 IO 模型          ← BIO/NIO/AIO 概念，Reactor 模式
4. 多路复用              ← 必学 epoll，搞懂 LT/ET
5. 零拷贝                ← 中间件性能基石
6. WebSocket            ← 长连接 / IM / 推送
   ↓ 进入应用层
转到 ../Middleware/  学 Netty / Nginx / RPC / Dubbo / ES
```

### 面试速通路径（30 分钟刷答题模板）

每篇都已配 **答题模板（60 秒话术）**——直接复述就是 senior 级回答：

- [TCP 协议 - 答题模板](./TCP协议.md)
- [HTTP 协议 - 答题模板](./HTTP协议.md)
- [网络 IO 模型 - 答题模板](./网络IO模型.md)
- [多路复用 - 答题模板](./多路复用.md)
- [零拷贝 - 答题模板](./零拷贝.md)
- [WebSocket - 答题模板](./WebSocket.md)
- [反向代理 - 答题模板](./反向代理.md)

---

## 六、关键速记表

### TCP 关键面试题速记

| 问题 | 一句话答案 |
| --- | --- |
| 三次握手为什么三次？ | 防历史连接复活 + 同步 ISN |
| 四次挥手为什么四次？ | Server ACK 立即回，FIN 等数据发完才发 |
| TIME_WAIT 2MSL？ | ① 保最后 ACK 到达；② 让旧报文消亡 |
| CLOSE_WAIT 堆积？ | 应用没 close（资源泄漏） |
| Nagle vs TCP_NODELAY？ | RPC 必关 Nagle |
| 拥塞控制 Linux 默认？ | CUBIC，长肥管道换 BBR |

### HTTP 演进速记

| 版本 | 痛点解决 | 引入 |
| --- | --- | --- |
| 1.0 | — | 基础 |
| 1.1 | 多次握手 | keep-alive / chunked / Range / Host |
| 2 | HoL + header 重复 | 二进制帧 + **多路复用** + HPACK |
| 3 (QUIC) | TCP HoL + 切网断连 | UDP + 0/1RTT + Connection ID |

### IO 模型对比

| 模型 | 等数据 | 拷贝 | 线程数 | 代表 |
| --- | --- | --- | --- | --- |
| BIO | 阻塞 | 阻塞 | 1 conn 1 thread | 老 Tomcat / JDBC |
| NIO 多路复用 | 非阻塞 | 阻塞 | **1 thread N conn** | **Netty / Redis / Nginx** |
| AIO | 异步 | 异步 | 内核回调 | Java AIO（Linux 鸡肋） |

### 多路复用三代

| 维度 | select | poll | epoll |
| --- | --- | --- | --- |
| fd 上限 | **1024** | 无 | 无 |
| 数据结构 | 位图 | 数组 | **红黑树 + 就绪链表** |
| 复杂度 | O(n) 遍历 | O(n) 遍历 | **O(就绪数)** |
| fd 拷贝 | 全量 | 全量 | 注册一次 |
| 触发方式 | 主动遍历 | 主动遍历 | **中断回调** |

### 零拷贝技术

| 技术 | CPU 拷贝 | 切换 | 用在哪 |
| --- | --- | --- | --- |
| 传统 read+write | 2 | 4 | — |
| mmap + write | 1 | 4 | RocketMQ CommitLog 写入 |
| sendfile (2.1) | 1 | 2 | 老版本 |
| **sendfile + SG-DMA (2.4+)** | **0** | 2 | **Kafka / Nginx** |
| splice | 0 | 2 | HAProxy 代理 |

---

## 七、生产踩坑 TOP 6（跨文档汇总）

1. **JDK NIO epoll 空轮询 BUG**：CPU 100% → Netty 自动重建 Selector。→ [网络IO模型](./网络IO模型.md)
2. **MappedByteBuffer 内存泄漏**：JVM 堆压力小不 GC → mmap 不释放 → RES 涨爆。反射调 Cleaner.clean。→ [零拷贝](./零拷贝.md)
3. **CLOSE_WAIT 堆积**：应用没 close → 端口耗尽。→ [TCP 协议](./TCP协议.md)
4. **TIME_WAIT 端口耗尽**：高并发短连接 + 主动关闭方。→ [TCP 协议](./TCP协议.md)
5. **HTTPS 0RTT 重放攻击**：TLS 1.3 0RTT 数据可重放，敏感请求禁用。→ [HTTP 协议](./HTTP协议.md)
6. **WebSocket 心跳错配**：客户端不发 Ping，Nginx 60s 默认断连。→ [WebSocket](./WebSocket.md)

---

## 八、面试常被一连串追问的话题

按出现频率列出（每条主线对应至少一篇深度文档）：

1. **TCP**：三次握手 → ISN 同步 → SYN flood → 全/半连接队列 → 四次挥手 → TIME_WAIT 2MSL → CLOSE_WAIT 排查 → Nagle → 拥塞控制（CUBIC vs BBR）
2. **HTTP**：1.0→1.1→2→3 演进 → 多路复用 → HoL → HTTPS 混合加密 → TLS 1.3 → 0RTT → 缓存（强/协商）
3. **IO 模型**：BIO 怎么死的 → NIO 多路复用 → epoll 红黑树+就绪链表 → LT vs ET → io_uring
4. **零拷贝**：传统 IO 4 次拷贝 → mmap → sendfile → SG-DMA 真 0 拷贝 → Kafka/Netty 各用什么
5. **WebSocket**：握手 Upgrade → Sec-WebSocket-Key → 帧格式 → 心跳 → 海量长连接架构

---

## 九、相关模块

- [Middleware 模块](../Middleware/README.md) — Netty / Nginx / RPC / Dubbo / ES（**应用层，建立在本模块之上**）
- [Microservice 模块](../Microservice/README.md) — Spring Cloud Gateway 基于 Reactor Netty（HTTP/2 是其底层协议）
- [Redis 模块](../Redis/README.md) — 单 Reactor + epoll 极致案例
- [MQ 模块](../MQ/README.md) — RocketMQ Remoting 基于 Netty + 存储用 mmap/sendfile
- [JVM 模块](../JVM/README.md) — 堆外内存 / DirectByteBuffer / Cleaner
- [Concurrency 模块](../Concurrency/README.md) — Reactor 线程模型与并发原理
