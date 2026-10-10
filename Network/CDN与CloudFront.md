# CDN 与 CloudFront

> ① **CDN 是把反向代理复制到全球几百个机房，并给每个机房配一份缓存。** 用户连最近的边缘节点，命中缓存就地返回，未命中再回源。面试里它常和"HTTP 缓存""反向代理""高可用入口"串在一起问，生产上它是**整条链路最外层的那一跳**：504 是不是它回的、回源超时多少、缓存了不该缓存的东西，都是它的事。
> ② 本篇解决 5 个问题：① 为什么动态 API 不缓存也值得过一层 CDN；② 缓存键 / TTL / 失效怎么定，为什么"缓存策略"和"回源请求策略"要拆开；③ 回源的连接 / 读超时与重试规则，504 到底是谁回的；④ 源站怎么保护，才不会被绕过 CDN 直连；⑤ 以 AWS CloudFront 为例的配置取舍和真实踩坑。
> ③ 前置：[反向代理](./反向代理.md)（CDN = 分布式反向代理 + 边缘缓存）、[HTTP 协议](./HTTP协议.md)（`Cache-Control` / TLS）。

---

## 一、为什么需要 CDN

问题出在**物理距离**。源站在美西，上海的用户到美西 RTT 约 150~200 ms。一次全新的 HTTPS 请求要先 TCP 握手 1 RTT、TLS 1.3 握手 1 RTT，然后才发请求 1 RTT。也就是说，**还没开始处理业务，就已经花了 3 个 RTT（约 0.5 秒）**。如果再碰上跨洋公网丢包，TCP 重传会把耗时拉到秒级。

CDN 的解法是"把入口搬到用户旁边"：

| 收益 | 怎么来的 | 对谁有用 |
|---|---|---|
| **握手变快** | TCP + TLS 在离用户几十毫秒的边缘节点完成 | 所有请求，**包括不缓存的 API** |
| **回源更稳** | 边缘 → 源站走云厂商骨干网，且边缘与源站之间保持长连接复用 | 动态请求 |
| **少回源** | 命中缓存时直接在边缘返回 | 静态资源、可共享的 GET 响应 |
| **扛攻击** | DDoS 在边缘被吸收；WAF 挂在边缘 | 所有请求 |
| **隐藏源站** | 用户只知道 CDN 域名 | 前提是源站做了"只许 CDN 访问"（见 §3.5） |

所以"API 都是动态的，上 CDN 没意义"是**错的**：缓存只是收益之一，握手就近和骨干网回源对动态请求同样有效。

---

## 二、核心原理：一次请求怎么走

### 骨架类比：多级缓存

把 CDN 当成 CPU 的多级缓存来理解，后面所有机制都能对上：

```
CPU：  寄存器 → L1 → L2 → L3 → 内存
CDN：  浏览器缓存 → 边缘节点 POP → 区域边缘缓存 REC → (Origin Shield) → 源站
       (每个用户)   (几百个，离用户近)   (十几个，容量大)    (可选，全局唯一一层)
```

| CPU 缓存概念 | CDN 对应物 |
|---|---|
| cache line 的地址 | **缓存键**（cache key）：URL + 你选进来的 query / header / cookie |
| 替换策略 | TTL 到期 + 冷对象被挤出（低频对象在边缘活不长） |
| 写失效 | **失效（invalidation）** 或换文件名 |
| 缓存穿透到内存 | **回源**（miss 后逐级往上找，最后到源站） |
| 多核同时 miss 同一行 | 多个边缘同时回源 → 用 REC / Origin Shield 合并 |

### 请求链路

```
 用户 ──DNS──▶ dxxxx.cloudfront.net（按延迟/地理解析到最近的 POP）
  │
  └─HTTPS──▶ 边缘 POP ① 终止 TLS（证书配在 CDN 上）
                │   ② 按路径匹配 cache behavior → 决定"缓不缓、转发什么、回哪个源"
                │   ③ 用缓存键查本地缓存
                │
                ├─ hit ──────────────────────────────▶ 直接返回（X-Cache: Hit from cloudfront）
                │
                └─ miss / 不缓存 ─▶ 区域边缘缓存 REC ─▶ (Origin Shield) ─▶ 源站
                                       │                                   ALB / S3 / 自建
                                       └ 边缘到源站：骨干网 + 长连接复用 + 可选 HTTPS
```

**一个关键结论**：用户的 TLS 只到 POP 为止。POP 到源站是**另一条连接**，协议、超时、重试都单独配置。这正是"两段连接"的反向代理模型（见 [反向代理](./反向代理.md) 第二节），只不过前一段被分散到了全球。

---

## 三、关键机制详解（以 CloudFront 为例）

### 3.1 分发、源站、行为：就是一份 Nginx 配置

| CloudFront 概念 | 对应的 Nginx 概念 | 说明 |
|---|---|---|
| Distribution（分发） | 一个 `server {}` | 有一个 `dxxxx.cloudfront.net` 域名，可绑自定义域名（Alternate domain / CNAME） |
| Origin（源站） | `upstream` | ALB、S3、EC2、任意公网域名；一个分发可以有多个 |
| Cache behavior（行为） | `location` | 按路径匹配（`/static/*`、`/api/*`），**按顺序匹配，最后兜底的是 Default (`*`)** |
| Cache policy | `proxy_cache_key` + `proxy_cache_valid` | 缓存键 + TTL |
| Origin request policy | `proxy_set_header` / `proxy_pass_request_headers` | 回源时带哪些头、cookie、query |
| Response headers policy | `add_header` | CORS、安全头 |

### 3.2 缓存键与 TTL：为什么要拆成两个策略

早期 CloudFront 只有一个配置项：**转发给源站的 header，自动进缓存键**。结果是想把 `Authorization` 转给后端，就得把它放进缓存键，命中率直接归零。

现在拆成两个策略：

- **Cache policy**：决定缓存键（哪些 query / header / cookie 参与）和 TTL；
- **Origin request policy**：决定回源时额外带什么，**不影响缓存键**。

常用的托管策略：

| 托管 Cache policy | 缓存键 | TTL（最小 / 默认 / 最大） | 适用 |
|---|---|---|---|
| **CachingOptimized** | 只有 URL 路径，不含 query / header / cookie | 1s / **86400s** / 1 年 | 带版本号文件名的静态资源 |
| **CachingDisabled** | — | 全 0，不缓存 | **API**、强一致的私有媒体 |
| **UseOriginCacheControlHeaders** | 路径 + Host 等 | 完全听源站的 `Cache-Control` | 需要按对象精细控制时效 |

TTL 的计算规则：**源站的 `Cache-Control: max-age` / `s-maxage` 优先，但会被策略的最小和最大 TTL 截断；源站不给这两个头，就用默认 TTL**。所以 CachingOptimized 加上一个不带 `Cache-Control` 的对象，结果就是**缓存一整天**。

### 3.3 失效与更新

| 方式 | 机制 | 代价 |
|---|---|---|
| **版本化文件名**（`app.3f9a1c.js`） | 新内容 = 新 URL，旧的自然过期 | 零成本、立即生效；需要构建工具配合 |
| **Invalidation** | 向全网边缘广播删除某些路径 | 通常几分钟生效；每月前 1000 个路径免费，超出按路径收费，`/*` 算一个路径 |
| **短 TTL** | 让它自己过期 | 命中率下降、回源变多 |

**发布别依赖 invalidation**：它是异步的，生效前不同边缘会返回新旧不一的版本。HTML 入口文件用短 TTL 或者不缓存，JS / CSS 用带版本号的文件名加长 TTL，这是标准组合。

**错误响应也会被缓存**：GET / HEAD 请求遇到源站返回 404 / 500 / 502 / 503 / 504 时，CloudFront 默认把这个错误缓存 **10 秒**（error caching minimum TTL）。源站已经恢复，用户可能还会再看到 10 秒错误。**CachingDisabled 策略下不缓存错误**。反过来，缓存里有一个已过期对象时，如果源站返回 5xx，CloudFront 会继续返回这个旧对象。可以用 `stale-if-error` 把这个兜底时间延长。

### 3.4 回源：超时、重试、504 是谁回的

| 参数 | 默认 | 范围 | 含义 |
|---|---|---|---|
| Connection attempts | 3 | 1~3 | 连源站最多尝试几次 |
| Connection timeout | 10s | 1~10s | 每次建连等多久 |
| Response timeout（origin read timeout） | **30s** | 可申请提额 | 发出请求后等第一个包的时间，**以及两个包之间的间隔** |
| Response completion timeout | 不设 | ≥ response timeout | 整个响应的总时长上限 |
| Keep-alive timeout | 5s | 可申请提额 | 边缘与源站之间的空闲连接保留多久 |

**重试规则按 HTTP 方法区分**（官方行为）：

- `GET` / `HEAD`：读超时后按 connection attempts **重试**；
- `POST` / `PUT` / `PATCH` / `DELETE` / `OPTIONS`：读超时后**直接放弃、不重试**，交给客户端决定。原因是非幂等请求可能已经在源站执行了一半。这和 Nginx `proxy_next_upstream` 默认不重试非幂等请求的考虑一致（见 [反向代理](./反向代理.md) 坑 6）。

**最坏耗时**：连接阶段要失败 3 次、每次等 10 秒，才放弃，即 30 秒。读超时如果配成 120 秒，一个卡住的 GET 请求最长可能被拖到几分钟。

**5xx 的来源判定**：

| 用户看到 | 谁生成的 | 典型原因 |
|---|---|---|
| CloudFront 504 | CloudFront | 连不上源站，或者等响应超过 response timeout |
| CloudFront 502 | CloudFront | 回源 TLS 失败（源站证书域名对不上 origin domain）、响应格式非法 |
| ALB 504 | ALB | 10 秒内连不上目标，或目标超过 idle timeout 没有响应 |
| 业务 5xx | 应用 | 原样透传 |

**怎么区分**：CloudFront 自己生成的错误页带 `Server: CloudFront`，响应体是它的模板页（"Generated by cloudfront (CloudFront)"）。源站生成的错误带的是源站自己的 `Server` 头和响应体。**不要看 `X-Cache: Error from cloudfront`**：只要状态码是 4xx / 5xx，不管是谁生成的，它都这么标（实测：源站返回 404 时也是这个值）。

### 3.5 源站保护：别让人绕过 CDN

CDN 上的 WAF、限速、地理封锁只对**经过 CDN 的流量**生效。如果源站本身可以被公网直接访问，攻击者直连源站就能绕过这些防护。

| 源站类型 | 做法 |
|---|---|
| S3 | **OAC（Origin Access Control）**：桶保持私有，桶策略只允许 `cloudfront.amazonaws.com` 以本分发的 `SourceArn` 读取。旧方案 OAI 已不推荐 |
| ALB / EC2 | ① 安全组入站只放行托管前缀列表 `com.amazonaws.global.cloudfront.origin-facing`；② 分发给回源请求加一个**密钥自定义头**，ALB 规则不带这个头就返回 403（前缀列表是所有 CloudFront 共用的，只靠它挡不住别人自己建的分发）；③ 更彻底的做法是 **VPC origin**，ALB 放在私有子网，根本没有公网入口 |
| 私有内容给特定用户 | **Signed URL / Signed Cookie**：链接带过期时间和签名，在边缘验签 |

回源协议同样要注意：`http-only` 表示边缘到源站之间是**明文**传输。用户看到的是 HTTPS，但后半程没有加密。

### 3.6 边缘计算

| | CloudFront Functions | Lambda@Edge |
|---|---|---|
| 触发点 | 只有 viewer request / response | viewer + origin request / response 四个 |
| 语言 / 能力 | 轻量 JS，不能访问网络 | Node.js / Python，可以访问网络 |
| 延迟 | 亚毫秒 | 毫秒级，有冷启动 |
| 典型用途 | URL 改写、加安全头、简单鉴权、A/B 分流 | 按用户动态选源站、复杂鉴权、改写响应体 |

### 3.7 可观测：指标在 us-east-1

- **CloudFront 是全局服务，CloudWatch 指标统一在 `us-east-1`**，切到源站所在区域是查不到的。
- 默认免费指标：`Requests`、`BytesDownloaded`、`4xxErrorRate`、`5xxErrorRate`、`TotalErrorRate`。**`CacheHitRate`、`OriginLatency`、按状态码细分的错误率属于附加指标，要单独开启并付费**。
- 默认**不开访问日志**。不开的话出了故障只能看 5 分钟粒度的比率，查不到单条请求。标准日志写到 S3 / CloudWatch Logs；实时日志走 Kinesis。
- 响应头排查三件套：`X-Cache`（Hit / Miss / RefreshHit / Error）、`X-Amz-Cf-Pop`（哪个边缘节点）、`X-Amz-Cf-Id`（请求 ID，找 AWS 支持时提供）。

---

## 四、配置取舍：三类流量三种配法

```yaml
# ① 静态资源（JS/CSS/图片，文件名带 hash）
path: /static/*
cache_policy: CachingOptimized        # 只用路径做键，默认缓存 1 天
origin_request_policy: none           # 不转发 cookie/header，避免污染缓存键
# 源站上传时写 Cache-Control: max-age=31536000, immutable，发布靠换文件名而非 invalidation

# ② 动态 API
path: Default (*)
cache_policy: CachingDisabled         # 一律不缓存，错误也不缓存
origin_request_policy: AllViewerExceptHostHeader   # 头/cookie/query 原样带给后端
allowed_methods: [GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE]
origin_protocol: https-only           # 后半程也加密（http-only 是明文）
origin_read_timeout: 30               # 要比 LB/网关的超时更长，让里层先失败、先返回有意义的错误
# 源站：安全组只放 CloudFront 前缀列表 + 校验密钥头

# ③ 私有媒体（撤销后立即失效）
path: /share/*
origin: S3 + OAC                      # 桶不公开
cache_policy: CachingDisabled         # 对象一删，下一个请求就是 403
# 想要缓存：上传时写 Cache-Control: max-age=N，换 UseOriginCacheControlHeaders，
# 撤销时效就变成"max-age + 错误缓存 10s"，要同步告诉业务方
```

| 取舍点 | 选 A | 选 B |
|---|---|---|
| API 要不要经过 CDN | ✅ 握手就近、WAF、隐藏源站 ❌ 多一跳、多一层超时要对齐 | 直连 LB：✅ 链路短 ❌ 跨洋握手慢、没有边缘防护 |
| 私有媒体缓存与否 | 缓存：✅ 拖动进度条快 ❌ 撤销有延迟 | 不缓存：✅ 撤销立即生效 ❌ 每次 Range 请求都回源 |
| 发布更新 | 版本化文件名：✅ 原子、免费 | invalidation：❌ 异步、可能收费、新旧混杂 |

---

## 五、对比与选型

| 维度 | CloudFront | Cloudflare | AWS Global Accelerator |
|---|---|---|---|
| 层级 | L7 CDN | L7 CDN + 安全 | **L4**（TCP/UDP），不缓存 |
| 接入方式 | CNAME 到 `cloudfront.net` | 通常把 DNS 整个托管给它 | 两个 Anycast 静态 IP |
| 与 AWS 源站 | OAC、VPC origin、骨干网，集成最深 | 走公网回源 | 直接进 AWS 骨干网 |
| 适用 | 源站在 AWS 的网站、API、媒体 | 多云、要一体化安全 | 游戏、语音、非 HTTP 协议、需要固定 IP |

**CDN 和 Global Accelerator 的区别**：前者是七层，能缓存、能按路径路由、能终止 TLS；后者只是让 TCP/UDP 流量尽早进入 AWS 骨干网，它不理解 HTTP。实时语音、自定义协议这类流量用 GA，HTTP 用 CDN。

---

## 六、生产踩坑

### 坑 1：超时链倒挂，网关卡死时每一层都在"等"

**现象**：一台中间件机重启后 Redis 没有自启。网关的全局过滤器对每个请求都同步调用依赖服务，而且**没有设超时**，结果请求全部卡住。CloudFront 5xx 错误率持续 3.5 小时维持在 30%~85%，ALB 每 5 分钟自己生成 900~8900 个 504。
**根因**：从外到内的超时分别是 CloudFront 读超时 120s、ALB idle 300s、网关调下游无限等待，**越往里越长**。里层不先失败，外层只能干等到自己超时，然后返回一个看不出原因的 504。连接越积越多，最后 ALB 连新请求都接不进去。
**修复**：超时要**从外到内逐层递减**，比如客户端 35s > CDN 30s > LB 25s > 网关 10s > 下游调用 2s，让最靠近故障的那一层先失败，返回能看出原因的错误并降级。网关调下游必须同时配连接超时和响应超时。
**监控**：CloudFront `5xxErrorRate`、ALB `HTTPCode_ELB_504_Count` 与 `UnHealthyHostCount`（**按 TargetGroup 拆**）。
（完整排查过程见 运维事故记录 #2）

### 坑 2：套餐计费的分发不能挂自定义缓存策略

**现象**：想给私有媒体配一个"60 秒缓存"的自定义策略。staging 分发上配置成功，prod 分发上报错 `Distributions with the Pro pricing plan can't have the following features: Custom cache policy`。
**根因**：prod 的 CDN 域名用的是 CloudFront **flat-rate 套餐（Pro）**，套餐分发只能用托管策略；它的 WAF ACL 也不能再关联到别的分发。这些限制**在 `get-distribution-config` 里看不出来**，只在写入时报错。
**修复**：两个环境都改用 CachingDisabled（撤销立即生效，代价是每次都回源）。如果以后要缓存，就在上传时写 `Cache-Control`，再改用 UseOriginCacheControlHeaders。
**教训**：设计 CDN 方案前先确认分发是按量计费还是套餐计费。另外 staging 要和 prod 用同一种策略，否则 staging 冒烟测到的撤销时效不等于线上行为。

### 坑 3：源站对公网开放，WAF 形同虚设

**现象**：一次自查时发现，API 分发的源站 ALB 安全组对 `0.0.0.0/0` 开放了 80 / 443 端口。拿 ALB 自己的 DNS 名直接请求 443，接口返回 200，完全没有经过 CloudFront 和挂在上面的 WAF。同时回源协议配的是 `http-only`，边缘到 ALB 这一段是明文。
**根因**：CDN 和源站分开配置，"只许 CDN 访问"这一步没人负责。
**修复**：安全组改为只放行 CloudFront 托管前缀列表，再加上密钥头校验，或者改用 VPC origin；回源协议改为 `https-only`。
**监控**：ALB 访问日志里来源 IP 不在 CloudFront 网段的请求数。

### 坑 4：动态 GET 接口被缓存，用户之间串数据

**现象**：A 用户看到了 B 用户的个人信息。
**根因**：API 路径挂了 CachingOptimized，缓存键里不包含 `Authorization` 和 cookie，同一个 URL 的第一个响应被所有人共享。
**修复**：API 一律用 CachingDisabled；源站对个人数据返回 `Cache-Control: private, no-store` 作为第二道防线。参见 [HTTP 协议](./HTTP协议.md) 坑 8。

### 坑 5：源站已经恢复，用户还看到 10 秒 5xx

**现象**：故障恢复后，部分用户的 GET 请求仍然报 502 / 504。
**根因**：CloudFront 对可缓存行为默认缓存 5xx 10 秒（error caching minimum TTL）。
**修复**：动态路径用 CachingDisabled；静态路径可以把 error caching minimum TTL 调到 0~5 秒，同时配 `stale-if-error`，让源站故障期间继续返回旧内容。

### 坑 6：把 `X-Cache: Error from cloudfront` 当成 CDN 故障

**现象**：值班同学看到这个响应头，就判断"CloudFront 挂了"，开始提工单。
**根因**：这个头只表示状态码是 4xx / 5xx，源站返回的错误也会这么标。
**修复**：看 `Server` 头和响应体，判断错误是谁生成的；再把 CloudFront 5xx 的时段和 ALB `HTTPCode_Target_5XX` / `HTTPCode_ELB_5XX` 逐段对照。

---

## 七、面试高频追问

**Q1：API 都是动态的，为什么还要过 CDN？**
缓存只是收益之一。TCP + TLS 握手在边缘完成，跨洋场景每个新连接能省 2 个以上长距离 RTT；边缘到源站走骨干网和长连接复用；WAF / DDoS 防护挂在边缘；源站不暴露。代价是多一跳、多一层超时需要对齐。

**Q2：CDN 的缓存键怎么设计？为什么不能把 `Authorization` 放进去？**
缓存键决定"哪些请求共享同一份响应"。键越细命中率越低：把 `Authorization` 放进去，等于每个用户一份缓存，命中率接近 0。个人数据本来就不该缓存，正确做法是不缓存，而不是把用户身份塞进缓存键。需要转发给后端的头，放在 origin request policy 里。

**Q3：发布后用户还拿到旧 JS，怎么办？**
根治方法是文件名带内容 hash，长 TTL 加 `immutable`；HTML 入口不缓存或用短 TTL。invalidation 只用来救急：它是异步的，几分钟内各边缘的新旧版本不一致，超出免费额度还按路径收费。

**Q4：用户报 504，怎么判断是 CDN、LB 还是应用？**
先看响应：`Server: CloudFront` 加 CloudFront 模板页，说明是 CloudFront 生成的；否则看源站特征。再看指标：CloudFront `5xxErrorRate`（us-east-1）、ALB 的 `HTTPCode_ELB_504_Count`（LB 生成）和 `HTTPCode_Target_5XX_Count`（后端生成），后两个按 TargetGroup 拆。三条曲线在同一时段的对应关系，就能说明错误出在哪一层。

**Q5：为什么超时要外长内短？**
最里层最了解失败原因（哪个依赖、什么错误），由它先失败才能返回有意义的错误码、走降级。如果外层先超时，用户只拿到一个通用的 504，而里层的请求还在继续消耗连接和线程，形成"客户端已经放弃、服务端还在算"的空耗。

**Q6：CloudFront 回源超时后会重试吗？**
GET / HEAD 会按 connection attempts 重试；POST / PUT / PATCH / DELETE / OPTIONS 读超时后不重试，因为非幂等请求可能已经执行过。连接阶段失败才会对所有方法重试。

**Q7：怎么防止别人绕过 CDN 直接打源站？**
S3 用 OAC 加私有桶；ALB 用"安全组只放 CloudFront 前缀列表 + 密钥自定义头校验"，或者 VPC origin。只用前缀列表不够，因为任何人都能自己建一个 CloudFront 分发，回源 IP 也在这个网段里。

**Q8：源站挂了，CDN 能兜底吗？**
只能兜底已经在缓存里的内容：对象过期后源站返回 5xx，CloudFront 会继续返回旧对象，可以用 `stale-if-error` 延长这个时间。动态 API 没有缓存，就兜不了。要保证可用，需要用 origin group 配主备源站（主源站返回指定状态码或连接失败时切到备源站）。

**Q9：命中率低怎么排查？**
① 缓存键是否混进了高基数字段（时间戳 query、cookie、`User-Agent`）；② TTL 是否被源站 `Cache-Control: no-cache` 或很短的 max-age 压低；③ 长尾对象太分散，被边缘淘汰，可以开 Origin Shield 加一层集中缓存；④ 开附加指标看 `CacheHitRate`，按路径拆分。

**Q10：CDN 和 Global Accelerator 怎么选？**
CDN 是七层，能缓存、能按路径路由、能终止 TLS，适合 HTTP。GA 是四层 Anycast，只负责让流量尽早进入骨干网，不缓存，适合游戏、语音、自定义协议，或者需要固定 IP 的场景。

---

## 八、答题模板（60 秒话术）

> **CDN 就是把反向代理复制到全球边缘节点，再给每个节点配一份缓存**，可以当成多级缓存来理解：浏览器、边缘 POP、区域缓存、源站，命中就近返回，未命中逐级回源。
>
> 它的价值不只是缓存：**握手就近**（TLS 在离用户几十毫秒的地方完成）、**骨干网回源**、**边缘防护**（WAF / DDoS）、**隐藏源站**。所以动态 API 也值得经过 CDN，只是要配**不缓存**。
>
> 落地有三件事要做对：一是**缓存键**，只放决定内容的字段，个人数据不缓存，静态资源用 hash 文件名加长 TTL；二是**超时外长内短**，CDN、LB、网关、下游逐层递减，让最靠近故障的那一层先失败；三是**源站只许 CDN 访问**，S3 用 OAC，ALB 用前缀列表加密钥头，否则 WAF 会被绕过。
>
> 排查 504 时先分清是谁生成的：CloudFront、LB 还是应用，看 **`Server` 头**和**按目标组拆的 LB 指标**，不要只看 `X-Cache`。

---

## 九、相关文档

- [反向代理](./反向代理.md) — CDN 是地理分布式的反向代理；两段连接、超时三件套、非幂等重试
- [HTTP 协议](./HTTP协议.md) — `Cache-Control` / 强缓存与协商缓存 / TLS 握手 RTT；坑 8 CDN 串号
- [TCP 协议](./TCP协议.md) — 跨洋 RTT、握手与重传为什么慢
- [Middleware/Nginx](../Middleware/Nginx.md) — 单机版的"反向代理 + 缓存"，CloudFront 的概念可以逐项对上
- [K8s/Ingress 与网关](../K8s/Ingress与网关.md) — CDN 之后的那一层入口
- 运维事故记录 #2 — 超时链倒挂导致全站 504 的完整排查过程
