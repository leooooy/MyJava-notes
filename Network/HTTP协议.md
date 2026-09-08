# HTTP 协议（1.0 / 1.1 / 2 / 3 + HTTPS）

> Web / 微服务 / 网关 / 浏览器面试必问。
> 本篇要解决：
> ① **HTTP 1.0 → 1.1 → 2 → 3** 演进的痛点驱动——每一代解决了上一代什么问题
> ② **HTTP/1.1 的 HoL blocking**、**HTTP/2 的多路复用**、**HTTP/3 = QUIC over UDP** 各自的取舍
> ③ **HTTPS = HTTP + TLS**，TLS 1.2 vs 1.3 握手差异、对称/非对称加密怎么协作、**1RTT / 0RTT** 是什么
> ④ HTTP **状态码 / Header / Cookie / 缓存** 的核心点
> ⑤ **跨域 CORS**、**幂等性方法**、**RESTful**、**断点续传** 等高频追问

> 答这块要点：能讲清 **每一代的痛点 + 解法**（不只是版本号）+ **TLS 握手过程**——基本就过 P6+ 网络题。

---

## 一、HTTP 是什么

HTTP = HyperText Transfer Protocol，**应用层** 协议（基于 TCP，HTTP/3 基于 UDP+QUIC）。

**核心特点**：
- **无状态**：每个请求独立，服务端不保存请求间状态（要状态靠 Cookie / Session / Token）。
- **请求-响应模型**：Client 发 Request，Server 回 Response。
- **明文文本**（HTTP/1.x）/ **二进制帧**（HTTP/2+）。

---

## 二、HTTP 报文格式（1.x）

### 2.1 Request

```
GET /api/user/123 HTTP/1.1                    ← 请求行 (Method URL Version)
Host: api.example.com                         ← Header
User-Agent: Mozilla/5.0 ...
Accept: application/json
Accept-Encoding: gzip, br
Cookie: session=abc123
Connection: keep-alive
                                              ← 空行（CRLF）
{"name": "alice"}                             ← Body（GET 通常无）
```

### 2.2 Response

```
HTTP/1.1 200 OK                               ← 状态行
Content-Type: application/json
Content-Length: 27
Cache-Control: max-age=3600
Set-Cookie: token=xyz; HttpOnly
                                              ← 空行
{"id": 123, "name": "alice"}                  ← Body
```

### 2.3 9 种 Method（重点）

| Method | 幂等 | 安全 | 用途 |
| --- | --- | --- | --- |
| **GET** | ✅ | ✅ | 查询，不改变服务端状态 |
| **POST** | ❌ | ❌ | 新增 / 不幂等更新（重试可能重复） |
| **PUT** | ✅ | ❌ | **整体替换**资源（幂等） |
| **PATCH** | ❌ / ✅ 看实现 | ❌ | 部分更新 |
| **DELETE** | ✅ | ❌ | 删除（幂等：再删返回 404 也算成功） |
| **HEAD** | ✅ | ✅ | 只要响应头不要 body（探活、查 Content-Length） |
| **OPTIONS** | ✅ | ✅ | 查询服务端能力 / **CORS 预检** |
| TRACE | ✅ | ✅ | 回显诊断（生产禁用，有 XST 攻击） |
| CONNECT | ❌ | ❌ | 建立隧道（HTTPS over Proxy） |

> **幂等性** = 多次请求结果与一次相同。**安全** = 不改变服务端状态。

---

## 三、HTTP 1.0 vs 1.1（**第一代演进**）

### 3.1 HTTP/1.0（1996）的痛点

- **每个请求一个 TCP 连接**：建立连接 3 次握手 + 拆连接 4 次挥手 → 一个页面 30 个资源 = 30 次握手 + 拆连接 → 慢。
- 不支持 Host 头 → 一个 IP 只能一个网站（虚拟主机不支持）。
- 缓存机制弱（只有 If-Modified-Since）。

### 3.2 HTTP/1.1（1997）的改进

#### ① **Persistent Connection（keep-alive）**

```http
Connection: keep-alive       ← 1.1 默认开启
Keep-Alive: timeout=60, max=100
```

复用 TCP 连接（一个 TCP 多个请求），省下 N 次握手。

#### ② **Pipelining（管道化，理论存在但生产不用）**

允许一次发多个请求不等响应。**问题**：响应必须按请求顺序返回 → **HoL blocking（队头阻塞）**——前一个慢则后面全卡。**几乎所有浏览器都不开启**，生产用并行多 TCP 连接（默认 6 个/host）替代。

#### ③ **Host 头**

```http
Host: api.example.com
```

支持虚拟主机（一个 IP 多个域名）。

#### ④ **Chunked Transfer Encoding**

```http
Transfer-Encoding: chunked

7\r\n
Mozilla\r\n
9\r\n
Developer\r\n
0\r\n
\r\n                          ← 终止块
```

**用途**：流式响应（提前知道有数据但不知道总大小，如服务端推送 / 大文件流式生成）。

#### ⑤ **缓存机制完善**

- `Cache-Control`（max-age=3600）取代 `Expires`。
- `If-None-Match` + `ETag` 取代 `If-Modified-Since`（精度更高）。

#### ⑥ **Range 请求（断点续传）**

```http
GET /file.zip HTTP/1.1
Range: bytes=1024-2047       ← 只要这一段

HTTP/1.1 206 Partial Content
Content-Range: bytes 1024-2047/10240
```

迅雷 / B 站 / Netflix 等大文件下载都靠它。

### 3.3 1.1 仍然没解决的核心问题

- **应用层 HoL blocking**（响应必须按请求顺序）→ 浏览器开 6 个 TCP 并发缓解，但有上限。
- **header 重复传输**：每个请求都带 cookie / user-agent / accept，几 KB 重复。
- **明文协议**：解析慢（要找 `\r\n`）、易被攻击（HTTP 劫持）。

---

## 四、HTTP/2（2015，**面试高频**）

### 4.1 五大改进

#### ① **二进制分帧层**（核心架构）

```
HTTP/1.1 (文本):
   GET /api HTTP/1.1\r\nHost: x\r\n...\r\n\r\n

HTTP/2 (二进制):
   ┌────────────────────────────┐
   │ Frame Header (9 字节)       │  Length / Type / Flags / Stream ID
   ├────────────────────────────┤
   │ Frame Payload              │  HEADERS / DATA / SETTINGS / ...
   └────────────────────────────┘
```

**所有通信都是 Frame**，Frame 类型：HEADERS / DATA / SETTINGS / PING / GOAWAY / WINDOW_UPDATE / RST_STREAM / PUSH_PROMISE / PRIORITY。

#### ② **多路复用（Multiplexing）**⭐⭐ 解决 HoL blocking

**HTTP/1.1**：
```
TCP1: req1 → resp1, req2 → resp2, req3 → resp3   (串行 + HoL)
TCP2: ... (浏览器最多 6 个并发)
```

**HTTP/2**：
```
TCP1: req1 / req2 / req3 → 交错的 Frame → resp1 / resp2 / resp3
       └── 同一连接 N 个 Stream 并行 ──┘
```

每个请求 = 一个 **Stream**（有唯一 Stream ID），同 TCP 上多个 Stream 交错传输的 Frame，接收端按 Stream ID 重组。

**收益**：浏览器一个 TCP 连接搞定一切，省连接数 / 省握手 / 省 TLS。

> ⚠️ **HTTP/2 仍有 TCP 层的 HoL blocking**——某个 Stream 丢一个 TCP 包，整个 TCP 连接的所有 Stream 都得等重传。这是 **HTTP/3 用 UDP+QUIC 解决的核心问题**。

#### ③ **头部压缩 HPACK**⭐

**问题**：每个请求带几 KB 重复 header（cookie / user-agent / accept）。
**解法**：
- **静态字典**：61 个常用 header（`:method=GET`、`:path=/`、`:status=200` 等）已编码为索引（1 字节即可表达）。
- **动态字典**：连接上首次出现的 header 加入字典，后续只发索引。
- **霍夫曼编码**：值字段做霍夫曼编码进一步压缩。

**实测**：第一个请求 header 几 KB，后续请求只剩几十字节，节省 80%+。

#### ④ **Server Push**（服务端推送，已被弃用）

Server 主动给 Client 推 Client 即将需要的资源（如请求 HTML 时连带推 CSS/JS）。

**问题**：浏览器缓存命中时推送浪费带宽 + 推送资源不可控。**Chrome 106 已移除 Push 支持**，业界基本不用。

#### ⑤ **优先级 / 流控**

每个 Stream 可设优先级（PRIORITY 帧），重要资源（HTML > CSS > 图片）先传。

### 4.2 升级到 HTTP/2 的代价

- 必须 **HTTPS**（浏览器规定，HTTP 上不支持 h2）。
- 服务端要支持 ALPN（Application-Layer Protocol Negotiation）→ TLS 握手时协商 h2/http1.1。
- 部分代理 / WAF 不支持 → 退回 HTTP/1.1。

### 4.3 怎么验证用了 HTTP/2

```bash
curl -I --http2 https://www.cloudflare.com -v 2>&1 | grep -i "alpn\|http"
# 看到 ALPN, server accepted to use h2
```

Chrome DevTools → Network → Protocol 列。

---

## 五、HTTP/3 = QUIC over UDP（2022，**热点**）

### 5.1 为什么需要 HTTP/3

HTTP/2 的最大遗留问题：**TCP 层的 HoL blocking**。
- HTTP/2 在应用层解决了 HoL，但**底下还是单 TCP 连接**——TCP 是有序字节流，**任何一个 segment 丢了就阻塞所有 Stream**。
- 移动网络 / Wi-Fi 切换场景丢包率不低，HTTP/2 的多路复用收益打折。

### 5.2 QUIC 怎么解决

**QUIC（Quick UDP Internet Connections）= 用户态可靠传输协议**，建立在 UDP 之上：

| 解决的问题 | QUIC 的做法 |
| --- | --- |
| TCP HoL blocking | 每个 Stream 独立流控 + 重传，**一个 Stream 丢包不影响其他** |
| 握手慢（TCP + TLS = 2-3 RTT） | **0-RTT 握手**（首次 1 RTT，后续 0 RTT 复用 ticket） |
| 网络切换（Wi-Fi → 4G）连接断开 | **Connection ID** 替代四元组——IP 变化连接不断 |
| TCP 内核态升级慢 | QUIC 在用户态实现，应用直接升级 |
| TCP 没加密 | QUIC **强制集成 TLS 1.3** |

### 5.3 QUIC 协议栈

```
HTTP/1.1   HTTP/2     HTTP/3
   │          │           │
   ▼          ▼           ▼
TLS 1.2 / 1.3        QUIC (含 TLS 1.3)
   │                      │
   ▼                      ▼
  TCP                    UDP
   │                      │
   ▼                      ▼
   IP                     IP
```

### 5.4 部署现状（2026）

- **Google / Facebook / Cloudflare / Akamai** 全面铺开。
- Chrome / Edge / Firefox / Safari 都支持。
- Nginx 1.25+ 实验支持，主流是 LiteSpeed / Caddy / Cloudflare 边缘。
- 国内 阿里 / 腾讯 / 字节 部分边缘 CDN 已上。
- **企业内网少用**——TCP 已经够用 + UDP 在企业网络容易被防火墙阻塞。

### 5.5 面试题：HTTP/3 vs HTTP/2

| 维度 | HTTP/2 | HTTP/3 |
| --- | --- | --- |
| 传输层 | TCP | UDP + QUIC |
| 队头阻塞 | 应用层无，**TCP 层有** | 完全消除 |
| 握手 | TCP 1RTT + TLS 1.3 1RTT = 2RTT | **1RTT（首次）/ 0RTT（复用）** |
| 连接迁移 | 不支持（IP 变化断连） | **支持 Connection ID** |
| 加密 | 可选（实际必 HTTPS） | **强制 TLS 1.3** |
| 兼容性 | 主流支持 | 部分代理 / 企业内网阻塞 UDP |

---

## 六、HTTPS = HTTP + TLS（**面试必问**）

### 6.1 HTTPS 解决什么

HTTP 的三大风险：
1. **窃听**（明文传输，密码 / cookie 全暴露）。
2. **篡改**（中间人改包）。
3. **冒充**（伪造服务端）。

**HTTPS 三大保证**：
- ✅ **机密性**（对称加密）。
- ✅ **完整性**（HMAC / AEAD）。
- ✅ **身份认证**（数字证书 + CA）。

### 6.2 加密基础（30 秒带过）

| 类型 | 速度 | 例子 | 用途 |
| --- | --- | --- | --- |
| 对称加密（AES / ChaCha20） | **快**（GB/s） | 一把钥匙加解 | 加密大量数据 |
| 非对称加密（RSA / ECC） | **慢**（KB/s） | 公钥加 / 私钥解 | 交换对称密钥 + 数字签名 |
| 哈希 / MAC（SHA-256 / HMAC） | 极快 | 不可逆 | 完整性 |

**HTTPS 用混合加密**：用非对称加密**协商对称密钥**，之后用对称加密传数据。

### 6.3 数字证书 / CA / 证书链

```
根 CA  ──签名──►  中间 CA  ──签名──►  服务端证书 (example.com)
(浏览器内置)
```

服务端证书内容：
- 域名 / 公司信息（CN / SAN）。
- 公钥。
- 颁发者 CA。
- 有效期。
- CA 用私钥对上面信息签名。

**校验**：浏览器拿 CA 公钥（自带）验签 → 一路验到根 CA → 都通过则信任。

### 6.4 TLS 1.2 握手（**面试核心**）

```
   Client                                              Server
     │                                                  │
     │ ① ClientHello                                    │
     │   - 支持的密码套件 (cipher suites)               │
     │   - 支持的 TLS 版本                               │
     │   - Client Random (随机数1)                       │
     │ ────────────────────────────────────────────────►│
     │                                                  │
     │ ② ServerHello                                    │
     │   - 选定的密码套件 (e.g. ECDHE-RSA-AES128-GCM)    │
     │   - Server Random (随机数2)                       │
     │ Certificate (服务端证书链)                        │
     │ ServerKeyExchange (ECDHE 公钥参数)                │
     │ ServerHelloDone                                   │
     │ ◄─────────────────────────────────────────────── │
     │                                                  │
     │ ③ 验证证书链 (浏览器干)                            │
     │ ④ 用 ECDHE 算出 pre_master_secret                 │
     │   ClientKeyExchange (Client 的 ECDHE 公钥)        │
     │   ChangeCipherSpec (通知 Server 切换加密)          │
     │   Finished (用对称密钥加密 + HMAC 全过程)          │
     │ ────────────────────────────────────────────────►│
     │                                                  │
     │ ⑤ Server 也算出同一个 pre_master_secret           │
     │   ChangeCipherSpec                               │
     │   Finished (用对称密钥加密)                       │
     │ ◄─────────────────────────────────────────────── │
     │                                                  │
     │           应用数据 (对称加密 AES-GCM)              │
     │ ◄────────────────────────────────────────────►   │
```

**关键点**：
- **3 个随机数**（Client Random / Server Random / Pre-Master）合成 **Master Secret** → 派生出**对称加密 key**。
- **ECDHE**（椭圆曲线 Diffie-Hellman）算法支持 **前向保密**（Forward Secrecy）——即使私钥泄露，过去抓的包也解不开。
- **2 RTT** 才能开始传应用数据。

### 6.5 TLS 1.3（2018，**重大优化**）

**重大变化**：
1. **1-RTT 握手**：合并 ClientHello + ClientKeyExchange，第一次往返就能开始传数据。
2. **0-RTT**（resumption）：复用上次 session ticket，**首次握手就能带应用数据**——但有重放风险，慎用。
3. **必强制使用前向保密**（仅 ECDHE，废弃 RSA 密钥交换）。
4. **裁剪密码套件**：移除 RC4 / 3DES / SHA1 / CBC 模式等不安全算法，只剩 AES-GCM / ChaCha20-Poly1305。
5. **加密 ServerHello 之后所有内容**（隐藏证书、SNI 在 ECH 扩展中加密）。

### 6.6 HTTPS 性能优化

| 手段 | 效果 |
| --- | --- |
| **HTTP/2 / HTTP/3** | 减少连接数 |
| **Session Resumption / Ticket** | 复用握手，0~1 RTT |
| **OCSP Stapling** | Server 主动带证书状态，免去浏览器去 CA 查证书 |
| **HSTS**（Strict-Transport-Security） | 强制 HTTPS，避免 301 重定向 RTT |
| **TLS 终止**（卸载到 LB / CDN） | 内网用 HTTP 减负 |
| **AES-NI 硬件加速** | CPU 指令集加速对称加密 |

---

## 七、状态码（速查）

### 7.1 五大类

| 类别 | 含义 | 典型 |
| --- | --- | --- |
| **1xx** 信息 | 中间状态 | 100 Continue, 101 Switching Protocols（WebSocket） |
| **2xx** 成功 | 处理 OK | 200 OK, 201 Created, 204 No Content, 206 Partial（断点续传） |
| **3xx** 重定向 | 资源换地方 | 301 永久, 302 临时, 304 Not Modified（缓存命中） |
| **4xx** 客户端错 | 请求有问题 | 400 Bad Request, 401 未认证, 403 无权限, 404 找不到, 405 方法不允许, 409 冲突, 413 body 太大, 429 限流 |
| **5xx** 服务端错 | 服务有问题 | 500 内部错, 502 网关错, 503 服务不可用, 504 网关超时 |

### 7.2 常被混淆

| 对 | 区别 |
| --- | --- |
| 401 vs 403 | 401 = 没登录；403 = 登了但**没权限** |
| 301 vs 302 | 301 = 永久重定向（浏览器记住）；302 = 临时（每次还问原地址） |
| 502 vs 504 | 502 = 网关收到上游**错误响应**；504 = 网关等上游**超时** |
| 200 vs 204 | 200 = 有 body；204 = 处理 OK 但**无 body** |

---

## 八、Header 核心字段

### 8.1 缓存（**面试必问**）

```http
# 强缓存 (浏览器不发请求)
Cache-Control: max-age=3600              ← 推荐
Expires: Mon, 09 May 2026 12:00:00 GMT   ← 老式（绝对时间，时区坑）

# 协商缓存 (发请求，但服务端没变就 304)
Last-Modified / If-Modified-Since
ETag / If-None-Match                     ← 推荐（hash 比时间精确）

# Cache-Control 组合
no-store      → 完全不缓存
no-cache      → 缓存但每次校验
private       → 仅浏览器缓存（不缓存到中间代理）
public        → 中间代理也可缓存
must-revalidate → 过期后必须校验
```

**缓存决策树**：
```
请求 → 有 Cache-Control / Expires 且未过期？
      ├── 是 → 直接用本地（200 from cache，不发请求）
      └── 否 → 发请求带 If-None-Match / If-Modified-Since
              ├── 服务端 304 Not Modified → 用本地
              └── 服务端 200 → 用新数据
```

### 8.2 跨域（CORS）

**同源策略**：浏览器限制脚本只能访问同源（协议+域名+端口都同）的资源。

**CORS 解法**：
```http
# 简单请求（GET / HEAD / POST + 简单 header）
Origin: https://app.example.com
↓ Server 回
Access-Control-Allow-Origin: https://app.example.com    ← 必须明确白名单
Access-Control-Allow-Credentials: true                  ← 允许带 cookie

# 复杂请求（PUT / DELETE / 自定义 header）→ 先发 OPTIONS 预检
OPTIONS /api HTTP/1.1
Origin: https://app.example.com
Access-Control-Request-Method: PUT
Access-Control-Request-Headers: X-Token

↓ Server 回
Access-Control-Allow-Methods: GET, POST, PUT, DELETE
Access-Control-Allow-Headers: X-Token
Access-Control-Max-Age: 86400                           ← 预检结果缓存 1 天
```

**坑**：`Access-Control-Allow-Origin: *` 时**不能** `Allow-Credentials: true`（带 cookie 必须明确域名）。

### 8.3 Cookie

```http
Set-Cookie: token=abc; Path=/; Domain=.example.com;
            Expires=Wed, 09 May 2027 12:00:00 GMT;
            HttpOnly;          ← JS 不可访问，防 XSS
            Secure;            ← 仅 HTTPS 发送
            SameSite=Strict;   ← 防 CSRF (Strict / Lax / None)
```

**SameSite 三档**：
- `Strict`：跨站请求**完全**不发 Cookie。
- `Lax`（Chrome 默认）：导航类请求（顶级跳转）发 Cookie，AJAX 不发。
- `None`：跨站发，但**必须 Secure**（仅 HTTPS）。

### 8.4 安全 Header（生产必加）

```http
Strict-Transport-Security: max-age=31536000; includeSubDomains    ← HSTS 强制 HTTPS
Content-Security-Policy: default-src 'self'                       ← CSP 防 XSS
X-Frame-Options: DENY                                              ← 防点击劫持
X-Content-Type-Options: nosniff                                    ← 防 MIME sniff
Referrer-Policy: strict-origin-when-cross-origin                   ← 控制 Referer 暴露
```

---

## 九、RESTful（面试常问）

**REST = Representational State Transfer**，一种 API 设计风格（不是协议）。

### 9.1 核心原则

1. **资源**：URL 是名词不是动词（`/users/123` 而不是 `/getUser?id=123`）。
2. **HTTP Method 是动作**：GET 查、POST 增、PUT 改、DELETE 删。
3. **无状态**：每个请求自包含。
4. **统一接口**：相同资源相同 URL，不同操作不同 method。

### 9.2 例子

| 操作 | RESTful | 反模式 |
| --- | --- | --- |
| 查列表 | `GET /users` | `GET /listUsers` |
| 查单个 | `GET /users/123` | `GET /getUser?id=123` |
| 新建 | `POST /users` | `POST /createUser` |
| 改 | `PUT /users/123` | `POST /updateUser` |
| 删 | `DELETE /users/123` | `POST /deleteUser?id=123` |

### 9.3 RESTful 不是教条

业务复杂时纯 RESTful 反而别扭（如批量操作、复杂查询）。**生产折中**：
- 复杂查询用 GraphQL / 自定义 query DSL。
- 批量操作 `POST /users/batch-delete`（务实）。
- RPC 风格 `POST /api/v1/payment.pay` 也广泛存在（gRPC、Dubbo）。

---

## 十、生产踩坑

### 坑 1：浏览器并发连接限制（每域名 6 个）

**现象**：页面 100 个图片串行加载慢。
**修复**：
- 用 HTTP/2（一个 TCP 任意并发）。
- 域名分片（HTTP/1.1 时代用，但 HTTP/2 后反而变慢——多 TCP 增加握手）。

### 坑 2：CORS 预检（OPTIONS）每个请求都发

**症状**：每个 PUT/DELETE 都先有 OPTIONS → API 慢一倍。
**修复**：服务端返回 `Access-Control-Max-Age: 86400` 缓存预检结果。

### 坑 3：Cookie 在 HTTPS 下 SameSite=None 但缺 Secure

Chrome 80+ 强制要求 `SameSite=None` 必须配 `Secure` → HTTPS 站点才能跨域带 cookie。

### 坑 4：HSTS 一旦设置浏览器永久记住

测试环境配 HSTS → 误操作扩散到生产 → 用户**永远**只能 HTTPS（即使你想关 HSTS）。
**修复**：开 HSTS 前慎重，先短 max-age（300s）测试，确认 OK 再延长到一年。

### 坑 5：HTTPS 证书链不全 → iOS 报错

Server 只发了服务端证书没发中间 CA 证书 → Chrome 自己网络拿可能能补全，iOS 严格 → 报"证书无效"。
**修复**：Nginx 配置 `ssl_certificate` 指向**包含完整链**的证书文件（fullchain.pem，不是单独 cert.pem）。

### 坑 6：HTTP/2 服务器配置不对回退到 HTTP/1.1

ALPN 没配 / 反向代理没传 → 浏览器协商不到 h2 → 性能不及预期。
**修复**：
```nginx
listen 443 ssl http2;        # Nginx 必须显式开 http2
```

### 坑 7：响应不带 Content-Length 也不带 Transfer-Encoding

→ 浏览器不知道 body 多长 → 等到连接关闭才结束 → 看起来"卡"。
**修复**：动态生成的响应用 `Transfer-Encoding: chunked`，静态文件用 `Content-Length`。

### 坑 8：CDN 缓存了带 cookie 的响应导致用户串号

Cache-Control 没设 `private` → CDN 把"用户 A"的响应缓存给了"用户 B"。
**修复**：用户级响应必须 `Cache-Control: private, no-store`。

### 坑 9：HTTP method 用错（用 GET 改数据）

爬虫 / 浏览器预取 / CDN 缓存 GET 请求 → 业务被意外触发。
**修复**：写操作必须 POST/PUT/DELETE。

### 坑 10：URL 长度限制

Server / 反向代理对 URL 长度有上限（Nginx 默认 8KB，Tomcat 默认 8KB）。
**修复**：超长查询参数改用 POST body。

---

## 十一、面试高频追问

**Q1：HTTP 1.0 / 1.1 / 2 / 3 演进？**
- 1.0：无 keep-alive，每请求一连接。
- 1.1：keep-alive 默认 + Host + chunked + Range，但应用层 HoL blocking。
- 2：二进制 + 多路复用 + HPACK + 必 HTTPS，应用层无 HoL，但 TCP 层仍有。
- 3：QUIC over UDP，0/1RTT 握手 + 连接迁移 + 完全消除 HoL。

**Q2：HTTP/2 多路复用怎么实现的？**
所有通信变二进制 Frame，每个请求一个 Stream（唯一 ID），同 TCP 上多 Stream 的 Frame 交错传输，接收端按 Stream ID 重组。**仍然有 TCP 层 HoL**（一个包丢全部 Stream 等）。

**Q3：HTTP/3 为什么用 UDP？**
TCP 内核态升级慢、有不可避免的 HoL blocking、连接四元组绑定 IP（切网断连）。QUIC 在 UDP 上用户态实现可靠传输 + 加密 + 多路复用，**无 TCP HoL** + **0RTT** + **连接迁移**。

**Q4：HTTPS 为什么用混合加密？**
非对称加密慢 + 对称加密快 → 用非对称交换对称密钥（仅握手时几次），之后用对称加密传大量数据（GB/s）。

**Q5：TLS 1.2 握手过程？**
ClientHello（cipher / random）→ ServerHello（选 cipher / random）+ Certificate + ServerKeyExchange（ECDHE 公钥）→ Client 验证证书 + ClientKeyExchange + Finished → Server Finished → 应用数据。**2 RTT**。

**Q6：TLS 1.3 比 1.2 强在哪？**
- **1 RTT 握手**（合并 Hello 和 KeyExchange）。
- **0 RTT**（resumption 复用上次 ticket）。
- 强制前向保密（仅 ECDHE）。
- 裁剪不安全密码套件。
- 加密 ServerHello 后所有内容。

**Q7：什么是 0RTT？有什么风险？**
首次连接握手后保存 session ticket，下次连接直接拿 ticket 加密发应用数据 → 0 个 RTT。
**风险**：重放攻击——攻击者抓到 0RTT 数据可以重发。所以 0RTT 数据**必须幂等**（如 GET），写操作仍需等握手完成。

**Q8：HTTP/2 还有 HoL blocking 吗？**
应用层无（多路复用解决了），**TCP 层有**——TCP 是有序字节流，丢一个 segment 整个 TCP 上的所有 Stream 都得等重传。HTTP/3 用 QUIC 解决。

**Q9：HTTPS 怎么防中间人？**
- 服务端证书由 CA 签名，浏览器内置 CA 公钥验签 → 攻击者造不出有效证书。
- 攻击者强行做 HTTPS 中间人 → 浏览器看到证书不是目标域名（CN/SAN 对不上）→ 报警。
- HSTS 防止 SSL Strip 攻击（强制走 HTTPS）。

**Q10：什么是 Forward Secrecy？**
前向保密——即使将来私钥泄露，**过去抓的密文也解不开**。靠 ECDHE 实现（每次握手生成临时密钥，用完销毁）。RSA 密钥交换没有前向保密——TLS 1.3 已废弃 RSA 密钥交换。

**Q11：301 vs 302 vs 307 vs 308？**
- 301 永久重定向，浏览器记住下次直接跳（且 POST 可能转 GET）。
- 302 临时重定向（且 POST 可能转 GET，行为不一致）。
- **307** 临时（**强制保持原 method**，POST 还是 POST）。
- **308** 永久（**强制保持原 method**）。
- 现代场景推荐 307 / 308 避免 method 转换。

**Q12：GET 跟 POST 区别？**
- 语义：GET 查（幂等 + 安全），POST 改（不幂等）。
- 长度：GET 受 URL 限制（~8KB），POST body 几乎无限。
- 缓存：GET 可被缓存 / 收藏 / 历史记录，POST 不行。
- 编码：GET 在 URL（必须 URL 编码），POST 在 body（任意编码）。
- 安全性：HTTPS 下两者都加密；HTTP 下 GET 在 URL 更容易被日志记录。

**Q13：Cookie / Session / Token 区别？**
- Cookie：浏览器存的小数据，自动随请求发。
- Session：服务端存的会话状态，靠 Cookie 里的 sessionId 关联。
- Token（JWT）：自包含的凭证，**无状态**——服务端不存，每次解析。

**Q14：CORS 怎么实现？**
浏览器执行 → 看响应 Header `Access-Control-Allow-Origin` 是否允许当前 Origin → 不允许就抛 CORS error 拒绝 JS 访问响应。复杂请求（PUT/DELETE/自定义 header）先发 OPTIONS 预检。

**Q15：怎么实现断点续传？**
Client 第二次请求带 `Range: bytes=N-` Header → Server 回 `206 Partial Content` + `Content-Range: bytes N-M/total`。HEAD 请求可以先查文件总长度。

**Q16：HTTP 长连接超时怎么定？**
- 服务端 keep-alive 短一点（如 60s），节省连接资源。
- 客户端心跳要 < 中间网络（NAT / 防火墙）的会话表 timeout（通常 5 分钟）。
- HTTP/2 / HTTP/3 长连接可以更长（一个连接复用所有请求）。

**Q17：HTTP 是无状态的，怎么实现登录？**
靠 Cookie / Token：Server 登录成功后下发 Cookie / JWT，后续请求自动带上。Server 验证 Cookie / Token 来识别用户。

---

## 十二、答题模板（60 秒话术）

> "HTTP 是应用层协议，演进经历 4 代，**每一代都是为了解决上一代的痛点**：
>
> **HTTP/1.0** 每请求一连接 → **HTTP/1.1** 引入 **keep-alive** 复用 TCP，加 chunked / Range / Host，但仍有应用层 **HoL blocking** 和 header 重复。
>
> **HTTP/2** 三大杀手锏：① **二进制分帧**取代文本；② **多路复用**——一个 TCP 上 N 个 Stream 并行，应用层无 HoL；③ **HPACK 头部压缩**——减少重复 header 80%。但 TCP 层 HoL 还在。
>
> **HTTP/3 = QUIC over UDP**——彻底消除 TCP HoL（每个 Stream 独立流控）+ **0/1 RTT 握手**（首次 1RTT 后续 0RTT）+ **连接迁移**（IP 变化不断连）+ 强制 TLS 1.3。Google / Cloudflare / 字节边缘 CDN 已大规模部署。
>
> **HTTPS = HTTP + TLS**，三大保证：机密性（对称 AES）+ 完整性（HMAC）+ 身份认证（CA 证书）。**握手过程**：ClientHello → ServerHello + Certificate + ECDHE 公钥 → Client 验证证书 + ECDHE 公钥 → 双方算出对称密钥 → 应用数据 AES-GCM 加密传输。**TLS 1.2 是 2RTT，TLS 1.3 优化到 1RTT，session 复用可 0RTT**。
>
> **生产坑**：① CORS 预检要 `Max-Age` 缓存；② Cookie 跨域要 `SameSite=None + Secure`；③ HSTS 谨慎开（永久记住）；④ 证书必须发完整链（iOS 严格）；⑤ Nginx HTTP/2 必须显式 `listen 443 ssl http2`。
>
> **缓存机制**：强缓存（Cache-Control / Expires，本地直接命中）+ 协商缓存（ETag / Last-Modified，发请求 304）。"

---

## 十三、相关文档

- [TCP 协议](./TCP协议.md) — HTTP 1.x / 2 的传输层基础
- [Nginx](../Middleware/Nginx.md) — 反向代理 / HTTPS 卸载 / HTTP/2 配置
- [WebSocket](./WebSocket.md) — 基于 HTTP Upgrade 的双向通信
- [RPC 原理](../Middleware/RPC原理.md) — HTTP vs RPC 性能对比
- [Netty](../Middleware/Netty.md) — HTTP/2 服务端实现底盘
- [Spring / Spring Cloud Gateway](../Microservice/SpringCloudGateway.md) — HTTP 网关
