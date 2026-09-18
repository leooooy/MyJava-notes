# WebRTC 与 ICE

> 音视频通话 / 语音 AI / 实时互动 / 屏幕共享 必备 —— **浏览器之间直接传媒体流**的标准。
> 跟 WebSocket 的根本区别：WebSocket 是**服务端中转**的可靠 TCP 长连接（适合 IM 文本）；WebRTC 是**端到端 P2P 的 UDP 媒体流**（适合低延迟音视频）。
>
> 本篇要解决：
> ① **WebRTC 三大件**：信令（signaling）/ 媒体（SRTP over UDP）/ 连通性（ICE）各管什么
> ② **ICE 是什么**：为什么 P2P 连接需要它，candidate / STUN / TURN 各是什么
> ③ **NAT 穿透**：ICE 怎么在两个内网端点之间"找路"
> ④ **P2P vs SFU vs MCU**：为什么生产用 SFU（如 LiveKit）而不是纯 P2P
> ⑤ 生产踩坑：容器化部署时 ICE candidate 宣告了错误 IP，导致连不上（真实案例）

> 大厂/音视频岗面试重点：**ICE 的候选收集与连通性检查 + STUN/TURN 区别 + NAT 穿透 + SFU 架构**。

---

## 一、WebRTC 三大件：信令 / 媒体 / 连通性

WebRTC 不是单一协议，而是一套组合。建立一次通话要三条线各就位：

| 组件 | 干什么 | 用什么协议 | 类比 |
| --- | --- | --- | --- |
| **信令 Signaling** | 交换"会话描述"（SDP）和网络候选（ICE candidate） | **WebRTC 不规定**，自选（常用 WebSocket） | 打电话前先互相"约好怎么连" |
| **连通性 ICE** | 在两端之间找出一条真正能通的网络路径 | ICE + STUN + TURN | 试遍所有路，挑通的那条 |
| **媒体 Media** | 真正传音视频 | **SRTP over UDP**（加密的 RTP） | 接通后说话的声音流 |

**关键认知**：信令通道（比如一条 WebSocket）只负责**协商**，一旦 ICE 找到路、媒体通道建好，**音视频不再经过信令服务器**（纯 P2P 时）。所以「WebSocket 连上了 ≠ 通话能通」——信令通、媒体（ICE）断，是最常见的故障形态。

---

## 二、ICE 是什么：P2P 连接的"找路"协议

**ICE = Interactive Connectivity Establishment（交互式连接建立）**，RFC 8445。解决的核心问题：**两个端点隔着 NAT / 防火墙 / 多网卡，到底用哪个 `IP:端口` 能连上对方？**

### 为什么需要它（NAT 问题）

两台机器多半都在内网（`192.168.x.x` / `10.x.x.x`），各自前面有 NAT。内网 IP 对方根本不可达，公网 IP 又被 NAT 动态映射、还可能被防火墙挡。直接连基本连不上 —— ICE 就是来系统性解决这个的。

### ICE 三步走

**① 收集候选（candidate gathering）**：每个端点把"我可能被连到的地址"全列出来，每个叫一个 **candidate**，分三类：

| candidate 类型 | 来源 | 例子 | 可达性 |
| --- | --- | --- | --- |
| **host** | 本机网卡直连地址 | `192.168.0.81`、`127.0.0.1` | 同内网/本机可达 |
| **srflx**（server reflexive） | 经 **STUN** 看到的自己公网映射地址 | `203.0.113.7:54321` | 穿 NAT 后公网可达 |
| **relay** | 经 **TURN** 服务器中转的地址 | TURN 服务器的 `IP:端口` | 兜底，一定能通 |

**② 交换候选**：双方通过**信令通道**把各自候选列表发给对方。

**③ 连通性检查（connectivity check）**：两边把候选**两两配对**，挨个发 STUN 探测包试通；选出**优先级最高且双向能通**的一对（nominate），媒体流就走它。优先级一般 host > srflx > relay（relay 要中转、延迟高、耗服务器带宽，最后才用）。

---

## 三、STUN 与 TURN：ICE 的两个帮手

| | STUN | TURN |
| --- | --- | --- |
| 全称 | Session Traversal Utilities for NAT | Traversal Using Relays around NAT |
| 作用 | 帮端点**发现自己的公网映射地址**（srflx 候选） | P2P 实在打不通时**中转媒体流**（relay 候选） |
| 流量 | 只在握手期帮你"照镜子"，**不转媒体** | **媒体全程经它中转**，吃带宽 |
| 成本 | 极低（无状态、几乎不耗流量） | 高（要转发所有音视频） |
| 何时用 | 大多数能 P2P 直连的场景 | 对称 NAT / 严格防火墙，直连失败的兜底 |

> 口诀：**STUN 帮你"看见自己的公网地址"，TURN 帮你"借它的服务器中转"**。ICE 优先 STUN 直连，不行才退化到 TURN 中转。

---

## 四、P2P vs SFU vs MCU：为什么生产不用纯 P2P

纯 P2P 两人通话没问题，但**多人**会爆炸：N 个人两两连，每人要发 N-1 路上行，是 O(N²) 连接。生产用**媒体服务器**：

| 架构 | 拓扑 | 上行 | 服务器开销 | 代表 |
| --- | --- | --- | --- | --- |
| **Mesh（纯 P2P）** | 人人互连 | N-1 路 | 0（无服务器） | 2-4 人小通话 |
| **SFU**（选择性转发） | 都连到中心服务器，服务器**只转发不解码** | 1 路 | 中（只转发） | **LiveKit**、主流方案 |
| **MCU**（混流） | 服务器把多路**解码+混合**成一路再发回 | 1 路 | 高（要转码） | 老电话会议 |

**LiveKit 是 SFU**：每个浏览器只跟 LiveKit 建一次 WebRTC 连接（上行 1 路），LiveKit 把别人的流转发给你。注意：**浏览器↔SFU 这一跳仍然是完整的 WebRTC（仍要走 ICE）**，所以下面的容器坑照样存在。

---

## 五、生产踩坑：容器化部署时 ICE candidate 宣告了错误 IP

**真实案例（metaXsire，LiveKit 跑在 Docker）**：浏览器连 LiveKit，**信令（WebSocket :7880）通了**，但报 `could not establish pc connection`——PeerConnection 建不起来。

**根因（用本篇知识解释）**：LiveKit 作为 SFU 也要参与 ICE、提供自己的 **host candidate**。但它在 Docker 容器里，默认只知道**容器内网 IP（172.x）**——浏览器在宿主机上，对 `172.x` 不可达 → 这个 host candidate 配对全失败 → 又没有可用的 srflx/relay → ICE 选不出能通的路 → 媒体建不起来。

**配置修复**（`livekit.yaml`）：

```yaml
rtc:
  udp_port: 7881
  tcp_port: 7882
  node_ip: 127.0.0.1   # 手动指定 LiveKit 宣告的 host candidate IP
```

```yaml
# docker-compose.yml — RTC 端口必须映射到宿主，否则即使 IP 对了媒体也进不来
ports:
  - "7880:7880"       # 信令 WS
  - "7881:7881/udp"   # ← RTC 媒体 UDP，缺它媒体必断
  - "7882:7882"       # RTC 媒体 TCP 回退
```

- 本机浏览器调试：`node_ip: 127.0.0.1`（配合端口映射，loopback 直达容器）。
- 跨设备（手机连 PC）：写 **PC 的局域网 IP**，否则手机连不到 `127.0.0.1`。
- 曾踩的坑：`node_ip` 被同事提交成**他机器的 IP**（`192.168.0.40`），别人拉下来浏览器去连那个不存在的地址 → ICE 失败。这种"机器相关配置"本不该写死提交。

**两个排错信号**：
1. **信令通、媒体断**（能进房但 `pc connection` 失败）→ 几乎一定是 ICE/candidate 问题，先查 node_ip 和 UDP 端口映射。
2. 浏览器 `chrome://webrtc-internals` 能看到收集到的 candidate 列表和连通性检查结果，是定位 ICE 的利器。

---

## 六、对照 WebSocket / TCP（与本模块其它篇的边界）

| 维度 | WebRTC | WebSocket | 裸 TCP |
| --- | --- | --- | --- |
| 传输层 | **UDP**（媒体）+ DTLS/SRTP 加密 | TCP | TCP |
| 拓扑 | P2P / 经 SFU | 客户端↔服务端 | 点对点 |
| 可靠性 | 不可靠（丢包就丢，重传影响实时性） | 可靠有序 | 可靠有序 |
| 延迟 | 极低（实时音视频） | 低 | 低 |
| 适合 | 音视频、屏幕共享、低延迟数据 | IM 文本、推送、弹幕 | 通用 |
| 信令 | **借** WebSocket 等做信令 | 自身就是通道 | — |

> 一句话边界：**WebSocket 负责"可靠的文本/信令通道"，WebRTC 负责"低延迟的 P2P 媒体流"**，二者常配合——WebRTC 用 WebSocket 当信令通道交换 SDP 和 ICE candidate。

---

## 七、小结速查

```
WebRTC 三大件
├── 信令 signaling   交换 SDP + ICE candidate（协议自选，常用 WebSocket）
├── 连通性 ICE       收集候选 → 交换 → 连通性检查 → 选出能通的路
└── 媒体 media       SRTP over UDP，P2P 时不经信令服务器

ICE 三类 candidate
├── host    本机网卡地址（内网/本机可达）
├── srflx   STUN 探到的公网映射地址（穿 NAT）
└── relay   TURN 中转地址（兜底，吃带宽）

STUN = 看见自己的公网地址；TURN = 借服务器中转媒体
架构：Mesh(纯P2P) → SFU(只转发,主流,LiveKit) → MCU(混流)
```

| 知识点 | 一句话 |
| --- | --- |
| ICE | WebRTC 的"找路"协议：列全候选地址，探测选出能通的那条 |
| host/srflx/relay | 本机地址 / STUN 探的公网地址 / TURN 中转地址 |
| STUN vs TURN | STUN 帮你发现公网地址（不转媒体）；TURN 中转媒体（兜底） |
| 信令通≠媒体通 | WebSocket 信令通了，ICE 失败照样连不上媒体 |
| SFU | 浏览器只连中心服务器、服务器只转发；LiveKit 就是 SFU，仍走 ICE |
| 容器 node_ip 坑 | SFU 在 Docker 里要宣告宿主可达 IP + 映射 UDP 端口，否则媒体断 |

---

## 📌 案例出处（metaXsire）

- LiveKit RTC 配置（node_ip / udp_port / tcp_port）：`infra/dev/livekit.yaml`
- LiveKit 端口映射（7880 信令 / 7881-udp / 7882-tcp）：`infra/dev/docker-compose.yml`
- 浏览器侧 WebRTC 连接（拿 token 后连 LiveKit）：`apps/xfan/web-admin` 的 LiveKit 接入页

---

## 相关篇

- [WebSocket](./WebSocket.md)——WebRTC 常用它当信令通道；二者是"信令 + 媒体"的搭档
- [TCP 协议](./TCP协议.md)——WebRTC 媒体走 UDP（不可靠换低延迟），对照 TCP 的可靠有序
- [Docker Compose 多服务编排](../K8s/DockerCompose多服务编排.md)——本篇容器 node_ip/端口映射坑的 Compose 视角
- [反向代理](./反向代理.md)——为什么 Ingress/反代一般只转 HTTP/WS、不转 WebRTC 的 UDP 媒体流
