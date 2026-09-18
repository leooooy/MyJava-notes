# TCP 协议

> **后端面试必问 TOP 1 协议题**——三次握手、四次挥手、TIME_WAIT 几乎每场面试都考一道。
> 本篇要解决：
> ① 三次握手为什么**必须三次**（不是两次/四次）；四次挥手为什么**必须四次**（不是三次）
> ② **TIME_WAIT** 为什么是 2MSL，CLOSE_WAIT 堆积怎么排查
> ③ **半连接队列 / 全连接队列**——SYN flood 攻击的根源
> ④ **滑动窗口 / 流量控制 / 拥塞控制**（慢启动 / 拥塞避免 / 快重传 / 快恢复）
> ⑤ **粘包根因 + Nagle / TCP_NODELAY / Cork** 之间的取舍
> ⑥ Linux 内核参数调优（生产用得到的 10 个 sysctl）

> 这块答得深的标志：能讲到 **TIME_WAIT 的两个目的**、**SYN cookie**、**RTO 计算**——基本就过 P6 网络题。

---

## 一、TCP 是什么 / 跟 UDP 区别

### 1.1 一句话定位

**TCP** = 面向连接、可靠、基于字节流的传输层协议。在不可靠的 IP 网络上提供**字节流的可靠传输**。

### 1.2 vs UDP

| 维度 | TCP | UDP |
| --- | --- | --- |
| 连接 | 面向连接（三次握手） | 无连接 |
| 可靠性 | **可靠**（重传 + ACK + 序号） | 不可靠（丢就丢） |
| 顺序 | **保证顺序** | 不保证 |
| 流控 / 拥塞 | 有 | 无 |
| 首部 | 20+ 字节 | 8 字节 |
| 通信模式 | 1:1 | 1:1 / 1:N / N:M |
| 速度 | 慢（要握手 / 确认） | 快 |
| 应用 | HTTP/1.1, HTTP/2, MySQL, RPC, Email | DNS, NTP, 视频/音频流, QUIC（HTTP/3） |

**面试题**："QUIC 既然要可靠为什么用 UDP？"——答：QUIC 在 UDP 上**用户态**实现可靠性，避免 TCP 内核态的握手开销 + HoL blocking + OS 升级慢的问题，详见 [HTTP 协议](./HTTP协议.md)。

---

## 二、TCP 报文格式

```
   0      4      8     12     16     20     24     28     31
   ┌───────────────────────┬───────────────────────────────┐
   │      Source Port       │     Destination Port           │  ← 16 + 16 bit
   ├───────────────────────┴───────────────────────────────┤
   │                  Sequence Number (seq)                │  ← 32 bit ⭐
   ├───────────────────────────────────────────────────────┤
   │              Acknowledgment Number (ack)              │  ← 32 bit ⭐
   ├──────┬───┬───┬───┬───┬───┬───┬───────────────────────┤
   │ HLen │R│R│URG│ACK│PSH│RST│SYN│FIN│   Window Size      │  ← 6 标志位 ⭐
   ├──────┴───┴───┴───┴───┴───┴───┴───┴───────────────────┤
   │     Checksum             │     Urgent Pointer          │
   ├───────────────────────────────────────────────────────┤
   │                Options (variable, 0-40 bytes)         │ ← MSS / Window Scale / SACK / Timestamp
   └───────────────────────────────────────────────────────┘
                            Payload (data)
```

**6 个核心标志位**：
| 标志 | 作用 |
| --- | --- |
| **SYN** | 同步序号，发起连接 |
| **ACK** | 确认（对应 ack 字段有效） |
| **FIN** | 发送方完成发送，请求关闭 |
| **RST** | 复位连接（异常关闭，立即回收） |
| PSH | 提示接收方立即上交（不缓冲） |
| URG | 紧急数据（很少用） |

---

## 三、三次握手（TCP Handshake）⭐

### 3.1 完整流程

```
        Client                                              Server
   ┌──────────────┐                                  ┌──────────────┐
   │   CLOSED     │                                  │    LISTEN    │ ← bind+listen
   └──────┬───────┘                                  └──────┬───────┘
          │                                                 │
          │ 1. SYN, seq=x                                   │
          │────────────────────────────────────────────────►│
          │                                                 │
   ┌──────▼───────┐                                  ┌──────▼───────┐
   │   SYN_SENT   │                                  │   SYN_RCVD   │ ← 半连接队列
   └──────┬───────┘                                  └──────┬───────┘
          │                                                 │
          │           2. SYN+ACK, seq=y, ack=x+1            │
          │◄────────────────────────────────────────────────│
          │                                                 │
   ┌──────▼───────┐                                         │
   │ ESTABLISHED  │                                         │
   └──────┬───────┘                                         │
          │                                                 │
          │ 3. ACK, seq=x+1, ack=y+1                        │
          │────────────────────────────────────────────────►│
          │                                                 │
          │                                          ┌──────▼───────┐
          │                                          │ ESTABLISHED  │ ← 全连接队列 → accept()
          │                                          └──────────────┘
```

### 3.2 为什么是三次？不是两次？四次？（**必考**）

**两次为什么不行**：

```
场景：Client 发 SYN，被卡在网络中没到 Server，Client 超时重发 SYN，正常建连。
之后那个旧的 SYN 才到达 Server → Server 以为是新连接 → 回 SYN+ACK
若两次握手立即建立 → 旧连接被强行复活 → Server 资源浪费。

→ 三次握手让 Client 有机会 ACK"我没要建立这个连接"，避免**历史连接**复活。
```

**核心目的**（背下来）：
1. **防止历史连接复活**（最重要的目的）。
2. **同步双方的 ISN（初始序号）**——双向都要确认对方收到 ISN。
3. **协商参数**（MSS、Window Scale、SACK 等通过 Option 字段）。

**为什么不四次**：第二次的 SYN 和 ACK 可以合并，没必要拆成两次。

### 3.3 ISN 为什么不固定（每次随机）

**安全性**：固定 ISN 时攻击者可预测序号 → 伪造数据包注入连接。RFC 6528 推荐用基于时钟 + 哈希的随机 ISN。

### 3.4 半连接队列 / 全连接队列（**必问**）

```
       SYN 来了
          │
          ▼
    ┌───────────────┐  ← 半连接队列 (SYN queue)
    │  SYN_RCVD 状态 │  容量: net.ipv4.tcp_max_syn_backlog
    └───────┬───────┘
            │ 第三次 ACK 来了
            ▼
    ┌───────────────┐  ← 全连接队列 (Accept queue)
    │ ESTABLISHED   │  容量: min(somaxconn, listen() 第二参数 backlog)
    └───────┬───────┘
            │ 应用调 accept()
            ▼
        业务处理
```

**关键参数**：
```bash
# 半连接队列上限
net.ipv4.tcp_max_syn_backlog = 8192            # /proc/sys/net/ipv4/

# 全连接队列上限（取 min）
net.core.somaxconn = 65535                     # /proc/sys/net/core/
listen(fd, backlog)                            # 应用代码传的

# 全连接队列满时的策略
net.ipv4.tcp_abort_on_overflow = 0             # 0=丢 ACK 让客户端重试; 1=直接 RST
```

**全连接队列满的症状**：
- `netstat -s | grep "overflowed"` 数字飙升。
- 客户端 `connect` 偶发超时或 RST。
- **修复**：调大 `somaxconn` + listen backlog；或加机器。

### 3.5 SYN Flood 攻击

**原理**：攻击者疯狂发 SYN（假源 IP），Server 回 SYN+ACK 后等 ACK → 半连接队列瞬间打满 → 正常用户连不上。

**两种防御**：
1. **缩短 SYN 重传时间**：`net.ipv4.tcp_synack_retries = 2`（默认 5）。
2. **SYN Cookie**：`net.ipv4.tcp_syncookies = 1`——Server 不分配半连接资源，把状态编码到 SYN+ACK 的 seq 字段（cookie），第三次 ACK 回来再解码恢复状态。**牺牲 Window Scale 等部分功能**，但能扛住攻击。

### 3.6 第三次 ACK 丢失会怎么样

- Server 状态停在 SYN_RCVD（占半连接队列）。
- Server 重发 SYN+ACK（默认 5 次，每次间隔翻倍：1s, 2s, 4s, 8s, 16s = 31s 后放弃）。
- 期间 Client 视角已 ESTABLISHED 可能直接发数据 → 数据携带 ACK，Server 一看 ACK 合法 → 进入 ESTABLISHED。

---

## 四、四次挥手（TCP Wave）⭐

### 4.1 完整流程

```
        Client (主动方)                                   Server (被动方)
   ┌──────────────┐                                  ┌──────────────┐
   │ ESTABLISHED  │                                  │ ESTABLISHED  │
   └──────┬───────┘                                  └──────┬───────┘
          │                                                 │
          │ 1. FIN, seq=x                                   │
          │────────────────────────────────────────────────►│
          │                                                 │
   ┌──────▼───────┐                                  ┌──────▼───────┐
   │  FIN_WAIT_1  │                                  │  CLOSE_WAIT  │ ← 应用 read 返回 0
   └──────┬───────┘                                  └──────┬───────┘
          │           2. ACK, ack=x+1                       │
          │◄────────────────────────────────────────────────│
   ┌──────▼───────┐                                         │
   │  FIN_WAIT_2  │                                         │ 应用代码 close()
   └──────┬───────┘                                         │
          │                                                 │
          │           3. FIN, seq=y                         │
          │◄────────────────────────────────────────────────│
          │                                                 │
   ┌──────▼───────┐                                  ┌──────▼───────┐
   │  TIME_WAIT   │                                  │   LAST_ACK   │
   │   (2MSL)     │                                  └──────┬───────┘
   └──────┬───────┘                                         │
          │ 4. ACK, ack=y+1                                 │
          │────────────────────────────────────────────────►│
          │                                                 ▼
          │                                          ┌──────────────┐
          │                                          │   CLOSED     │
          │                                          └──────────────┘
   等 2MSL ↓
   ┌──────▼───────┐
   │   CLOSED     │
   └──────────────┘
```

### 4.2 为什么是四次？（**必考**）

**问题**：握手时第二次 `SYN+ACK` 合并成一次，挥手时第二次 `ACK` 和第三次 `FIN` 为什么不能合并？

**答案**：握手时 Server 的 SYN 和 ACK 是**同时**发的（无业务数据）；挥手时 Client 发 FIN 表示"我没数据要发了"，**但 Server 可能还有数据要发完**——所以：
- 第二次（ACK）：Server 立即 ACK 表示"知道你要关了"。
- 第三次（FIN）：Server 自己也发完数据后才发 FIN。
- 中间这段时间 Server 处于 **CLOSE_WAIT**（被动关闭状态），可以继续 send。

### 4.3 TIME_WAIT 为什么是 2MSL（**必考**）

MSL = Maximum Segment Lifetime（报文最大生存时间，Linux 默认 60s 即 `tcp_fin_timeout`）。

**TIME_WAIT = 2 MSL（默认 60s 而不是 120s——Linux 简化了）**，存在两个目的：

#### 目的 1：保证最后一个 ACK 能到达对端

如果第四次 ACK 丢失 → Server 重发 FIN（处于 LAST_ACK）→ 主动方在 TIME_WAIT 状态能再次 ACK；如果直接 CLOSED 就没法响应了，Server 永远死在 LAST_ACK。

#### 目的 2：让本连接的旧报文在网络中消亡

如果立即建立同四元组（src ip+port, dst ip+port）的新连接 → 旧连接的延迟报文可能被新连接误收。

### 4.4 TIME_WAIT 的危害与调优

**危害**：高并发短连接场景（如压测、某些反向代理后端）→ 主动关闭方 TIME_WAIT 暴涨（可达数万），占用端口。

**症状**：
```bash
ss -an | awk '/tcp/{print $1}' | sort | uniq -c       # 看各状态数量
netstat -an | grep TIME_WAIT | wc -l                  # 同上
# 或：
ss -tan state time-wait | wc -l
```

**修复**（**注意权衡**）：

```bash
# ❌ tcp_tw_recycle —— Linux 4.12 已移除（NAT 环境会丢包）
# ✅ tcp_tw_reuse —— 允许 TIME_WAIT 端口被新连接复用（仅限发起方）
net.ipv4.tcp_tw_reuse = 1

# 缩短 FIN_TIMEOUT（即缩短 TIME_WAIT）
net.ipv4.tcp_fin_timeout = 30                          # 默认 60，可调到 30s

# 扩大本地端口范围（缓解端口耗尽）
net.ipv4.ip_local_port_range = 1024 65000

# 应用层：用长连接 / 连接池 替代短连接（**最优解**）
```

### 4.5 CLOSE_WAIT 堆积（**生产排查必问**）

**现象**：`netstat | grep CLOSE_WAIT` 越来越多，最终连接数耗尽。

**根因**：被动方应用层**没调用 close()**——TCP 协议栈收到 FIN 后回了 ACK 进入 CLOSE_WAIT，等应用调 close 才能进入 LAST_ACK。

**典型场景**：
- 业务代码在 `try` 中 socket 用完没 close（异常路径漏 close）。
- 用了线程池但 channel 未释放。
- HTTP Client 没设连接池或没 close 响应。

**排查**：
```bash
# 1. 看是哪个进程
ss -tnp state close-wait

# 2. lsof 找具体 fd
lsof -p <pid> | grep CLOSE_WAIT

# 3. jstack 看栈，定位漏 close 的代码
```

**修复**：代码层 `try-with-resources` 或 finally 必 close。

---

## 五、TCP 状态机（状态全景图）

```
                              CLOSED
                                │ listen
                                ▼
                              LISTEN
       ┌──────accept SYN───────┘  └────send SYN───────┐
       │                                              │
       ▼                                              ▼
    SYN_RCVD ◄──── SYN+ACK ────────────────────── SYN_SENT
       │                                              │
       │ recv ACK                                     │ recv SYN+ACK, send ACK
       ▼                                              ▼
                          ESTABLISHED ◄──────────────┘
                          │            │
                  send FIN│            │recv FIN
                          ▼            ▼
                   FIN_WAIT_1      CLOSE_WAIT
                       │ recv ACK     │ send FIN
                       ▼               ▼
                   FIN_WAIT_2       LAST_ACK
                       │ recv FIN     │ recv ACK
                       ▼               ▼
                    TIME_WAIT       CLOSED
                       │ 2MSL
                       ▼
                    CLOSED
```

**11 个状态记忆口诀**：
- **建连接**：CLOSED → LISTEN（被）/ SYN_SENT（主） → SYN_RCVD → ESTABLISHED。
- **关连接 主动方**：ESTABLISHED → FIN_WAIT_1 → FIN_WAIT_2 → TIME_WAIT → CLOSED。
- **关连接 被动方**：ESTABLISHED → CLOSE_WAIT → LAST_ACK → CLOSED。
- 还有 CLOSING（双方同时 close 的小概率状态）。

---

## 六、可靠性核心机制

### 6.1 序号 + ACK 累积确认

- 每个字节都有 seq number。
- ACK = 期望收到的下一个 seq（**累积确认**）。
- 例：收到 [1,1000] [1001,2000]，回 ACK=2001。

### 6.2 超时重传（RTO）

**RTO = Retransmission Timeout**。计算复杂：

```
RTT 平滑值 SRTT     = (1-α) * SRTT + α * RTT_sample           α=0.125
RTT 偏差    DevRTT = (1-β) * DevRTT + β * |RTT_sample - SRTT| β=0.25
RTO         = SRTT + 4 * DevRTT
```

**如果 RTO 触发**：
- 重发未确认报文。
- **RTO 翻倍**（指数退避）：1s, 2s, 4s, 8s...，避免拥塞恶化。

### 6.3 快重传（Fast Retransmit）

收到 **3 个重复 ACK** 立即重传（不等 RTO 超时）。例：收到 [1,1000] [2001,3000]，对方一直 ACK=1001 → 第 3 个重复 ACK 触发立刻重传 [1001,2000]。

### 6.4 SACK（Selective ACK）

**问题**：累积 ACK 在中间丢包时效率低（已收到的不连续段没法表达）。
**解法**：SACK option 携带"已收到的非连续段"信息，发送方只重传缺的段。
```bash
net.ipv4.tcp_sack = 1                    # 默认开启
```

---

## 七、流量控制（Sliding Window）

### 7.1 滑动窗口

接收方在 ACK 中告知 `window size` = "我现在还能收多少字节"。发送方控制**未确认数据 ≤ window size**。

```
发送方                             接收方
                                   接收缓冲 (8KB)
[已确认][未确认 in-flight][可发][..|.....已用 3KB....|...剩 5KB...]
       ^                  ^
       │                  │
       └── send window ───┘
            ≤ 接收方通告的 window size
```

### 7.2 零窗口与窗口探测

接收方满时通告 window=0 → 发送方停发。但如果窗口更新报文丢失 → 双方死锁。

**解法**：发送方周期性发**零窗口探测**包（1 字节），强制接收方回 ACK，避免死锁。

### 7.3 糊涂窗口综合症（Silly Window Syndrome）

接收方应用每次只读 1 字节 → 通告 window=1 → 发送方发 1 字节 → 浪费 40 字节首部传 1 字节。

**解法**：
- 接收方：window 小于 MSS/2 时通告 window=0，等积累足够空间再开放。
- 发送方：Nagle 算法（见下节）。

---

## 八、拥塞控制（**面试高频**）

> 流量控制（Flow Control）防止**接收方**爆掉，拥塞控制（Congestion Control）防止**网络**爆掉。

### 8.1 四个核心算法

```
   cwnd
   (拥塞窗口)
     │
     │              ┌─────── 拥塞避免（线性 +1）─────────┐
     │              │                                     │
ssthresh ───────────┤                                     │
     │              │                                     │ <── 检测到丢包
     │              │                                     ▼
     │              │                                ┌────────┐
     │              │                                │ 快恢复 │ ← 3 重复 ACK 触发
     │              │                                └────┬───┘
     │     慢启动    │                                     │
     │   (指数增长) │                                     │
     │     ┌────────┘                                     ▼
     │     │                                       直接慢启动 ← 超时触发
     │     │                                          (cwnd=1)
     └─────┴───────────────────────────────────────────────────► 时间
```

| 算法 | 目的 | 行为 |
| --- | --- | --- |
| **慢启动** | 摸索网络容量 | cwnd 从 1 开始，每 RTT 翻倍（指数）→ 达到 ssthresh 切换 |
| **拥塞避免** | 谨慎增长 | 每 RTT cwnd += 1（线性） |
| **快重传** | 及时发现丢包 | 收到 3 重复 ACK 立即重传 |
| **快恢复** | 不退到慢启动 | ssthresh = cwnd/2，cwnd 设为 ssthresh 继续拥塞避免 |

### 8.2 RTO 触发 vs 3 重复 ACK 触发

- **RTO 超时**（严重）：cwnd = 1，回到慢启动 → **吞吐崩溃**。
- **3 重复 ACK**（轻微）：进快恢复，cwnd 减半继续 → 不至于崩。

### 8.3 现代算法（生产用）

| 算法 | 思路 | 何时用 |
| --- | --- | --- |
| **Reno**（经典） | 上面四件套 | 早期实现 |
| **CUBIC**（Linux 默认） | 基于 cwnd 三次函数增长，长肥管道更友好 | Linux 内核默认 |
| **BBR**（Google 2016）⭐ | 基于**带宽 + RTT** 建模，**不依赖丢包**判断拥塞 | YouTube / 高 BDP 网络（跨洋链路）效果显著 |

```bash
# 查看当前算法
sysctl net.ipv4.tcp_congestion_control

# 切换 BBR（Linux 4.9+）
modprobe tcp_bbr
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p
```

**面试题**：BBR 比 CUBIC 强在哪？
- CUBIC 用丢包当拥塞信号——**Wi-Fi 等无线链路丢包不一定是拥塞**，结果误降速。
- BBR 主动测量瓶颈带宽 + 最小 RTT，更精确判断拥塞 → 跨洋传输 + 高丢包链路收益巨大。

---

## 九、Nagle 算法 / TCP_NODELAY / TCP_CORK（**RPC/IM 必问**）

### 9.1 Nagle 算法

**问题**：高频小包（如 telnet 每按一个键发 1 字节）→ 40 字节首部 + 1 字节数据 = 严重浪费。

**Nagle**：未收到上一个包的 ACK 之前，**累积数据**不发送（攒一攒再发）。规则：
- 上次发送的数据**所有都被 ACK** → 立即发送。
- 否则等积累到 MSS 再发，或等 ACK 来。

**好处**：减少小包数量，提升带宽利用率。
**坏处**：**增加延迟**——RPC / 实时游戏 / IM 一秒钟都不能等。

### 9.2 TCP_NODELAY（关闭 Nagle）

**90% 的 RPC 框架（Dubbo / gRPC / Netty）都默认开启 TCP_NODELAY**：

```java
// Netty
bootstrap.childOption(ChannelOption.TCP_NODELAY, true);

// Java NIO
socketChannel.setOption(StandardSocketOptions.TCP_NODELAY, true);
```

**为什么**：RPC 调用要的是低延迟，攒包带来的几十 ms 延迟无法接受。

### 9.3 TCP_CORK（极端攒包）

**TCP_CORK** = "塞住"，即使数据满了也等待 200ms 或显式 uncork。用于"先 header 再 body"的场景：
```c
setsockopt(fd, IPPROTO_TCP, TCP_CORK, &(int){1}, sizeof(int));
write(fd, header, sizeof(header));
write(fd, body, sizeof(body));
setsockopt(fd, IPPROTO_TCP, TCP_CORK, &(int){0}, sizeof(int));   // 一起发
```

**Nginx 的 `tcp_nopush on`** 底层就是 TCP_CORK。

### 9.4 三者对比

| 设置 | 行为 | 适用 |
| --- | --- | --- |
| 默认（Nagle on） | 攒小包 | 文本传输、远程登录 |
| **TCP_NODELAY** | 立即发 | **RPC / IM / 游戏**（绝大多数场景） |
| TCP_CORK | 完全攒满 / 显式触发 | sendfile + header（Nginx 静态文件） |

### 9.5 Nagle 跟延迟 ACK 共同导致 40ms 延迟（**经典 BUG**）

**场景**：
- 一端开 Nagle（默认）。
- 另一端开延迟 ACK（默认）→ 收到数据后等 40ms 看有无数据回送可以一起 ACK。
- 结果：A 发包 → B 不立即 ACK → A 等 ACK 才发下一包 → **每包多 40ms**。

**修复**：业务层至少一端关 Nagle（TCP_NODELAY=1）。

---

## 十、TCP 粘包（**老生常谈**）

### 10.1 根因

**TCP 是字节流，不保留消息边界**。
- Nagle 可能把多次 write 合并发送。
- MTU 限制可能拆大消息。
- 接收方一次 read 的字节数任意。

### 10.2 应用层解法

| 方案 | 例子 |
| --- | --- |
| 长度字段 | Dubbo / RocketMQ（`LengthFieldBasedFrameDecoder`） |
| 分隔符 | Redis RESP（`\r\n`）、HTTP（`\r\n\r\n`） |
| 固定长度 | 老协议、嵌入式 |

详见 [Netty / 5.1 TCP 粘包](../Middleware/Netty.md#51-tcp-粘包--拆包面试必问)。

> ⚠️ **粘包不是 BUG，是 TCP 特性**——UDP 就没粘包问题（保留消息边界）。

---

## 十一、TCP keepalive（不是应用心跳）

```bash
# 默认参数（生产偏长，要调短）
net.ipv4.tcp_keepalive_time   = 7200      # 空闲多久后开始探测（默认 2 小时）
net.ipv4.tcp_keepalive_intvl  = 75        # 探测间隔
net.ipv4.tcp_keepalive_probes = 9         # 探测次数
```

**TCP keepalive 的鸡肋之处**：
- 默认 2 小时太久，NAT/防火墙早把连接清了。
- 内核级，应用层无法感知中间网络异常。
- **生产基本靠应用层心跳**（Netty IdleStateHandler）替代。

**建议**（要用就调短）：

```bash
net.ipv4.tcp_keepalive_time = 600         # 10 分钟
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
```

---

## 十二、生产 sysctl 调优（10 个关键参数）

```bash
# /etc/sysctl.conf

# === 半连接 / 全连接 ===
net.ipv4.tcp_max_syn_backlog = 8192       # 半连接队列
net.core.somaxconn = 65535                # 全连接队列
net.ipv4.tcp_abort_on_overflow = 0        # 全连接溢出策略

# === 防 SYN flood ===
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2

# === TIME_WAIT 优化 ===
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.ip_local_port_range = 1024 65000

# === 缓冲区 ===
net.core.rmem_max = 16777216              # socket 接收缓冲最大 16MB
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216   # min default max
net.ipv4.tcp_wmem = 4096 65536 16777216

# === 拥塞控制 ===
net.ipv4.tcp_congestion_control = bbr     # 长肥管道用 BBR
net.core.default_qdisc = fq

# === keepalive ===
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
```

```bash
sysctl -p                                  # 生效
```

---

## 十三、生产踩坑

### 坑 1：CLOSE_WAIT 堆积导致服务挂

详见 [4.5](#45-close_wait-堆积生产排查必问)。**最高频生产事故**——上游线程池任务异常没 close 资源 → CLOSE_WAIT 累积 → 文件句柄耗尽。

### 坑 2：TIME_WAIT 占满端口

**场景**：压测客户端，主动关连接，几分钟后端口耗尽 `connect: Cannot assign requested address`。
**修复**：开 `tcp_tw_reuse=1`、用长连接 + 连接池、分散源端口、扩大端口范围。

### 坑 3：tcp_tw_recycle 在 NAT 后导致丢包

**老 Linux**（< 4.12）有 `tcp_tw_recycle` 参数允许快速回收 TIME_WAIT。但在 **NAT 后的客户端** → 多用户同 IP 不同时间戳 → 内核认为是过时报文丢弃 → **整个 NAT 后的用户连不上**。
**修复**：**永远不要开 tcp_tw_recycle**（4.12+ 已移除）。

### 坑 4：accept queue 满导致连接超时

**症状**：`netstat -s | grep -i "overflowed"` 增长。
**修复**：调大 somaxconn + listen() 参数 + Tomcat / Netty backlog 配置。

### 坑 5：TCP keepalive 不可靠

**场景**：Dubbo 客户端连不通服务端，但 TCP 层 keepalive 没断。
**根因**：keepalive 默认 2 小时才探测，期间 NAT 已清掉表项。
**修复**：应用层心跳（Netty IdleStateHandler）。

### 坑 6：MTU / MSS 不匹配

**场景**：跨 VPN / 隧道，包稍大就丢。
**根因**：MTU 默认 1500，VPN 加封装后实际可用 < 1500，但 MSS 仍按 1500 协商 → 大包被分片或丢弃。
**修复**：协商 MSS 时用 PMTUD（Path MTU Discovery）；或手动设 MSS（如 1380）。

### 坑 7：Nagle + Delayed ACK 40ms 延迟

详见 [9.5](#95-nagle-跟延迟-ack-共同导致-40ms-延迟经典-bug)。**RPC 必关 Nagle**。

### 坑 8：长连接 idle 后被中间设备断开

**场景**：长连接 5 分钟无流量 → 防火墙 / NAT 清除会话表 → 应用第二天发数据收到 RST。
**修复**：缩短应用心跳间隔（< NAT 超时时间，一般 < 4 分钟）。

### 坑 9：Linux 默认 backlog 太小（128）

老应用 listen(fd, 128) → 高并发下连接被拒。Tomcat 默认 100，必须调大到几千。

### 坑 10：socket buffer 太小限制吞吐

**长肥管道**（高带宽 + 高 RTT，如跨洋）→ `带宽延迟积 BDP = 带宽 × RTT` 大，但默认 `tcp_wmem` 上限只 4MB → 吞吐受限。
**修复**：调大 `net.ipv4.tcp_wmem` / `tcp_rmem`，或换 BBR。

---

## 十四、面试高频追问

**Q1：三次握手为什么不是两次？**
两次握手无法防止**历史连接复活**——旧的 SYN 卡在网络中后到达，Server 误认为新连接建立，资源浪费。第三次 ACK 让 Client 有机会确认"我没要建这个连接"。

**Q2：四次挥手为什么不能合并成三次？**
握手时 Server 的 SYN 和 ACK 可同时发（无业务负担），挥手时 Client 发 FIN 后 **Server 可能还有数据要发**——所以 ACK 必须立即发（确认已收到 FIN），FIN 等 Server 数据发完再发，中间这段时间是 CLOSE_WAIT。

**Q3：TIME_WAIT 为什么 2MSL？**
两个目的：① 保证最后一个 ACK 能到达对端（丢了对端会重发 FIN）；② 让本连接的旧报文在网络中消亡，避免被同四元组的新连接误收。

**Q4：CLOSE_WAIT 大量堆积怎么办？**
被动方应用层**没 close**——TCP 协议栈收到 FIN 回 ACK 后等应用 close。排查：lsof 看进程，jstack 看代码栈，定位漏 close 路径。修复：try-with-resources / finally。

**Q5：SYN flood 怎么防御？**
- `tcp_syncookies=1` 开 SYN cookie：不分配半连接资源，把状态编入 SYN+ACK seq。
- 缩短 `tcp_synack_retries=2`。
- WAF / 防火墙限速。

**Q6：半连接队列和全连接队列区别？**
- 半连接队列（SYN queue）：收到 SYN 后状态 SYN_RCVD，等第三次 ACK。
- 全连接队列（Accept queue）：第三次 ACK 收到后进入 ESTABLISHED，等应用 accept()。
- 半连接满 → 拒新 SYN；全连接满 → 默认丢第三次 ACK 让客户端重试。

**Q7：Nagle 算法 / TCP_NODELAY？**
Nagle：未确认上一包 ACK 前累积数据再发，减少小包但增加延迟。RPC / IM 必关（TCP_NODELAY=1）。Dubbo / gRPC / Netty 默认开 TCP_NODELAY。

**Q8：滑动窗口 vs 拥塞窗口？**
- 滑动窗口（rwnd）：接收方告诉发送方"我能收多少"，**防接收方爆掉**。
- 拥塞窗口（cwnd）：发送方根据网络情况算的，**防网络爆掉**。
- 实际发送 = min(rwnd, cwnd)。

**Q9：拥塞控制四件套？**
慢启动（指数增长，摸索）→ 拥塞避免（线性增长，谨慎）→ 快重传（3 重复 ACK 立即重传）→ 快恢复（cwnd 减半继续避免，不退到慢启动）。

**Q10：BBR 跟 CUBIC 区别？**
CUBIC 把"丢包"当拥塞信号，但 Wi-Fi / 跨洋链路丢包不一定是拥塞——会误降速。BBR 主动测瓶颈带宽 + 最小 RTT，**主动建模网络**——长肥管道 / 高丢包链路提升 2-10x 吞吐。Linux 4.9+ 可用，跨数据中心场景必开。

**Q11：RTO 怎么算的？**
基于 RTT 平滑值 + 偏差：`RTO = SRTT + 4 × DevRTT`。Linux 还有最小 RTO（200ms）和退避机制（每次重传 RTO 翻倍）。

**Q12：tcp_tw_reuse 跟 tcp_tw_recycle 区别？为什么 recycle 被移除？**
- reuse：允许 TIME_WAIT 端口被发起方新连接复用，**安全**。
- recycle：服务端快速回收 TIME_WAIT，**NAT 后导致丢包**——多用户同 IP 不同 TS，被误判为旧报文。Linux 4.12+ 已移除。

**Q13：什么是 0RTT / 1RTT 握手？**
- 1RTT：传统 TCP 三次握手 + TLS 1.2 → 至少 2 RTT 才能开始传数据。
- TLS 1.3 = 1RTT，QUIC（HTTP/3）= 0RTT（首次连接 1RTT，后续连接复用 ticket 实现 0RTT）。

**Q14：怎么排查"连接超时"？**
- `tcp_max_syn_backlog` 满 → 半连接拒绝。
- `somaxconn` / accept queue 满 → 第三次 ACK 被丢。
- 路由黑洞、防火墙 drop（不回 RST）→ 客户端等到 SYN 超时（默认 5 次重传 ~31s）。
- DNS 解析慢。
- `netstat -s` 各计数器、`ss -s` 看 summary。

**Q15：粘包跟分包根因？**
TCP 是字节流没消息边界。Nagle 攒包导致粘包；MTU 限制导致分包。应用层解法：长度字段 / 分隔符 / 固定长度。

**Q16：什么是长肥管道（LFN）？**
高带宽（如 10Gbps）+ 高 RTT（如 200ms 跨洋）→ BDP = 250MB，需要大 socket buffer 才能填满。默认 4MB 上限会严重限速。

---

## 十五、答题模板（60 秒话术）

> "TCP 是面向连接、可靠、基于字节流的传输层协议。**面试核心三件套**：握手 / 挥手 / TIME_WAIT。
>
> **三次握手**：Client 发 SYN → Server 回 SYN+ACK → Client 回 ACK。三次的核心目的是**防止历史连接复活**——旧 SYN 卡网络后到达 Server，没有第三次 ACK 就会误建连接。同时也是**双向同步 ISN + 协商 MSS / Window Scale**。
>
> **四次挥手**：FIN → ACK → FIN → ACK。四次是因为 Server 的 ACK 和 FIN 不能合并——Server 收到 Client 的 FIN 后**还可能要发数据**，所以 ACK 立即回，FIN 等数据发完才发。
>
> **TIME_WAIT 2MSL** 两个目的：① 保最后 ACK 到达；② 让旧报文消亡防止干扰新连接。生产高并发短连接场景 TIME_WAIT 暴涨，开 **tcp_tw_reuse**（不是 recycle，recycle 在 NAT 后会丢包）+ 缩短 fin_timeout + 用长连接池替代。
>
> **CLOSE_WAIT 堆积** = 被动方**应用没 close**——必须 try-with-resources 兜底。
>
> **半连接队列 / 全连接队列** 是 SYN flood 攻击的入口：开 tcp_syncookies + 调大 somaxconn。
>
> **拥塞控制** 四件套：慢启动 → 拥塞避免 → 快重传 → 快恢复。Linux 默认 CUBIC，**长肥管道 / 跨洋链路换 BBR**——BBR 主动测带宽不依赖丢包，效果显著。
>
> **Nagle 算法** 攒包减小流量，但增加延迟——**RPC / IM 必开 TCP_NODELAY 关 Nagle**。和延迟 ACK 配合容易导致 40ms 延迟黑洞。
>
> **TCP 粘包** 是字节流特性而非 BUG，应用层用长度字段 / 分隔符解决。
>
> **生产 sysctl** 必调：somaxconn=65535 / tcp_max_syn_backlog=8192 / tcp_tw_reuse=1 / fin_timeout=30 / 长肥管道开 BBR。"

---

## 十六、相关文档

- [HTTP 协议](./HTTP协议.md) — TCP 之上的应用协议
- [网络IO模型](./网络IO模型.md) — Socket 编程的 IO 模型
- [多路复用](./多路复用.md) — epoll 配合 TCP 的高并发
- [Netty](../Middleware/Netty.md) — TCP_NODELAY / SO_BACKLOG / 心跳实战
- [RPC 原理](../Middleware/RPC原理.md) — 长连接 + 多路复用 + 粘包解决
- [Nginx](../Middleware/Nginx.md) — TCP 反向代理 / Keepalive 配置
