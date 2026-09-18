# Nginx

> Web 流量入口的事实标准——**全球最大、活跃度最高的 Web Server / 反向代理**。
> 本篇要解决：
> ① **Master + Worker 多进程模型**——单 Worker 怎么扛百万并发（epoll + 异步事件驱动）
> ② **反向代理 / 负载均衡 / 动静分离**三大核心使用场景
> ③ Nginx 内置的 **限流（leaky bucket / 令牌桶）+ 缓存 + 限连**
> ④ **HTTPS 卸载 + HTTP/2 / HTTP/3** 配置
> ⑤ 跟 **OpenResty / Tengine / APISIX / Envoy** 的关系与选型

> 大厂面试问 Nginx 重点：**进程模型 + 为什么这么快 + 平滑重启 + 限流 + 网关定位**。

---

## 一、Nginx 是什么 / 解决什么

**Nginx**（Engine X）= 高性能 HTTP 服务器 + 反向代理 + 负载均衡 + 邮件代理 + TCP/UDP 代理。

**典型用途**（生产几乎都跑这些）：
1. **静态资源服务**：HTML / JS / CSS / 图片 / 视频。
2. **反向代理**：前端流量 → 后端 Tomcat / Spring Boot / Node 集群。
3. **负载均衡**：多机器流量分发（轮询 / 加权 / IP hash）。
4. **HTTPS 卸载**：在边缘解 TLS，内网用 HTTP 减负后端。
5. **限流 / 限连 / 黑白名单**：防爆量、防爬虫、防 DDoS。
6. **动静分离**：静态资源 Nginx 直接返，动态请求转后端。
7. **API 网关**（OpenResty / Kong / APISIX）：鉴权、限流、灰度、监控。

**vs Apache HTTPD**：

| 维度 | Nginx | Apache |
| --- | --- | --- |
| 架构 | **多进程 + 异步事件驱动** | 多进程 / 多线程，每连接一线程（也可改 event MPM） |
| 静态文件 | **极快**（sendfile + epoll） | 一般 |
| 动态内容 | 反代下游（不内置脚本） | 内置 mod_php 等 |
| 并发 | **百万级** | 万级 |
| 配置 | 简洁（block 嵌套） | 复杂（.htaccess） |
| 内存占用 | 低 | 较高 |

**结论**：Nginx 几乎完全取代 Apache 做 Web 入口；Apache 仅在 PHP 场景偶见。

---

## 二、架构：Master + Worker 多进程（**面试核心**）

```
                                  ┌─────────────────┐
                                  │   Master 进程    │ ← root 启动 (绑定端口)
                                  │  - 加载配置      │
                                  │  - 启动 Workers  │
                                  │  - 处理信号      │
                                  └────────┬────────┘
                                           │ fork
              ┌────────────────────────────┼────────────────────────────┐
              ▼                            ▼                            ▼
       ┌────────────┐               ┌────────────┐               ┌────────────┐
       │ Worker 1   │               │ Worker 2   │      ...      │ Worker N   │
       │ (nobody)   │               │ (nobody)   │               │ (nobody)   │
       │            │               │            │               │            │
       │ epoll loop │               │ epoll loop │               │ epoll loop │
       │ ┌────────┐ │               │ ┌────────┐ │               │ ┌────────┐ │
       │ │  conn  │ │               │ │  conn  │ │               │ │  conn  │ │
       │ │  conn  │ │               │ │  conn  │ │               │ │  conn  │ │
       │ │  ...   │ │               │ │  ...   │ │               │ │  ...   │ │
       │ └────────┘ │               │ └────────┘ │               │ └────────┘ │
       └────────────┘               └────────────┘               └────────────┘
```

### 2.1 Master 职责

- **加载、解析配置文件** → 启动 Workers。
- **监听信号**：`HUP`（reload）/`USR2`（热升级）/`QUIT`（优雅停）/`TERM`（强停）。
- **不处理网络流量**——只管 Worker。

### 2.2 Worker 职责

- **每个 Worker 一个进程，一个 epoll loop**（单线程）。
- **接受连接 + 处理请求 + 反代上游**——全在一个事件循环内。
- 多个 Worker **独立**——一个 Worker 崩了不影响其他（Master 重启它）。

### 2.3 Worker 数量怎么定

```nginx
worker_processes auto;            # 推荐 = CPU 核数（避免 CPU 跨核切换）
worker_cpu_affinity auto;         # 绑核（提升 cache 命中）
worker_rlimit_nofile 65535;       # 单 Worker 最大 fd 数
```

### 2.4 单 Worker 扛百万并发的秘密（**必问**）

**关键三件套**：
- **epoll**（Linux 多路复用）：单线程监听上万 fd，详见 [多路复用](../Network/多路复用.md)。
- **完全异步非阻塞**：所有 IO（accept / read / write / 后端转发）都注册到 epoll，从不阻塞 Worker 线程。
- **事件驱动**：每个连接是一个**状态机**（不像 Apache 一线程一连接），状态保存在 `ngx_connection_t` 结构里。

**对比 Apache prefork**：
- Apache：1 conn 1 process，1w 连接 = 1w 进程，内存几 GB + 上下文切换打死 CPU。
- Nginx：1 Worker N conn，N 可达 10w+，内存几 MB。

### 2.5 惊群问题与 SO_REUSEPORT

**老 Nginx 的问题**：所有 Worker 都监听同一个 listen socket → 新连接到来时**所有 Worker 都被唤醒** → 但只有一个能 accept → 其他空跑（**惊群**）。

**解法演进**：
- **Nginx 1.9.1+ 默认开 SO_REUSEPORT**：每个 Worker 独立 listen socket（同一端口），内核做四元组哈希分发 → **无惊群、连接均衡**。
- 老版本用 `accept_mutex on`：Worker 抢锁后才 epoll_wait，但锁开销 + 不均衡。

详见 [多路复用 - 六、惊群问题](../Network/多路复用.md#六惊群问题thundering-herd)。

---

## 三、配置文件结构（速查）

```nginx
# 全局块
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;

# events 块
events {
    use epoll;                              # Linux 必选
    worker_connections 65535;               # 单 Worker 最大连接数
    multi_accept on;                        # 一次性 accept 所有就绪连接
}

# http 块（HTTP 协议）
http {
    sendfile on;                            # 开启零拷贝
    tcp_nopush on;                          # 配合 sendfile 用 TCP_CORK
    tcp_nodelay on;                         # 长连接保活时关闭 Nagle
    keepalive_timeout 65;
    keepalive_requests 100;

    # upstream 块（后端集群）
    upstream backend {
        server 192.168.1.1:8080 weight=3;
        server 192.168.1.2:8080 weight=1;
        keepalive 32;                       # 上游连接池
    }

    # server 块（虚拟主机）
    server {
        listen 80;
        listen 443 ssl http2;
        server_name api.example.com;

        ssl_certificate /etc/nginx/cert/fullchain.pem;
        ssl_certificate_key /etc/nginx/cert/privkey.pem;

        # location 块（路由）
        location /static/ {
            root /var/www/;
            expires 30d;
        }

        location /api/ {
            proxy_pass http://backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
    }
}

# stream 块（TCP/UDP 代理，1.9+）
stream {
    upstream mysql {
        server 192.168.1.10:3306;
    }
    server {
        listen 3306;
        proxy_pass mysql;
    }
}
```

---

## 四、反向代理 vs 正向代理（**入门必问**）

| 维度 | 正向代理 | 反向代理 |
| --- | --- | --- |
| 代理对象 | 客户端 | 服务端 |
| 用户感知 | 用户主动配置（如翻墙） | 用户感知不到（以为直接访问 Server） |
| 隐藏方 | 隐藏**用户** | 隐藏**真实服务器** |
| 例子 | VPN / Squid / 代理服务器 | **Nginx** / HAProxy / CDN |
| 部署位置 | 客户端侧 | 服务端机房入口 |

**反向代理的核心价值**：
- **安全**：后端 IP 隐藏，DDoS 打的是边缘。
- **横向扩展**：后端加机器无感知。
- **统一入口**：HTTPS 卸载、限流、鉴权、缓存集中处理。

---

## 五、负载均衡（**面试必问**）

### 5.1 内置算法

```nginx
upstream backend {
    # 1. round-robin（默认，加权轮询）
    server 192.168.1.1:8080 weight=3;
    server 192.168.1.2:8080 weight=1;
    server 192.168.1.3:8080 backup;          # backup 仅当主全挂时启用

    # 2. ip_hash（同 IP 同后端，session 粘性）
    # ip_hash;

    # 3. least_conn（最少连接数）
    # least_conn;

    # 4. hash（自定义 key）
    # hash $request_uri consistent;          # consistent = 一致性哈希

    # 5. random（Nginx Plus）
    # random two least_conn;
}
```

### 5.2 算法对比

| 算法 | 特点 | 适用 |
| --- | --- | --- |
| **round-robin**（默认） | 加权轮询 | 后端能力相近、无 session 粘性需求 |
| **ip_hash** | 同 IP 打同节点 | 有本地 session 的老应用 |
| **least_conn** | 选当前连接最少的 | 长连接、请求耗时差异大 |
| **hash $key** | 自定义 key 分发 | 缓存命中（同 user 同节点）、灰度 |
| **hash ... consistent** | 一致性哈希 | 节点增减时迁移最少（CDN 场景） |

**ip_hash 的坑**：
- NAT 后多用户同 IP → 流量不均。
- IP 变化（移动网络切换）→ session 失效。
- **生产推荐用 sticky cookie + Redis 共享 session 替代**。

### 5.3 健康检查

**开源版 Nginx** 只有**被动健康检查**：
```nginx
upstream backend {
    server 192.168.1.1:8080 max_fails=3 fail_timeout=30s;
    # 失败 3 次后摘除 30s
}
```

**主动健康检查**：
- Nginx Plus（商业版）。
- **Tengine**（阿里）开源版自带主动健检：`check interval=3000`。
- **Nginx 配 keepalived 等**做高可用。

### 5.4 跨集群高可用

```
   ┌──────────────────────────┐
   │   Keepalived (VRRP)      │ ← VIP 浮动
   └────┬──────────────┬──────┘
        │              │
   ┌────▼─────┐   ┌────▼─────┐
   │ Nginx M  │   │ Nginx S  │
   └──────────┘   └──────────┘
        │              │
        └──────┬───────┘
               ▼
        ┌──────────────┐
        │ Backend Pool │
        └──────────────┘
```

Keepalived 监控主备 Nginx → 主挂 VIP 漂移到备 → 用户无感知。

---

## 六、动静分离

```nginx
# 静态文件 Nginx 直接返
location ~* \.(jpg|png|css|js|html)$ {
    root /var/www/static;
    expires 30d;                                 # 浏览器缓存 30 天
    add_header Cache-Control "public, immutable";
    sendfile on;                                 # 零拷贝
    tcp_nopush on;
}

# 动态请求转后端
location / {
    proxy_pass http://backend;
    proxy_set_header Host $host;
}
```

**收益**：
- 静态文件用 sendfile **零拷贝**直发，吞吐数倍于业务后端。
- 后端只处理动态逻辑，Tomcat 不被静态资源拖累。

---

## 七、限流（**生产标配**）

### 7.1 limit_req（漏桶 leaky bucket）—— 限请求速率

```nginx
http {
    # 定义限流区
    limit_req_zone $binary_remote_addr zone=req_limit:10m rate=100r/s;
    #              ^限流 key（IP）        ^共享内存       ^速率 100/s

    server {
        location /api/ {
            limit_req zone=req_limit burst=200 nodelay;
            #                       ^突发桶容量   ^超出排队不延时直接拒
            proxy_pass http://backend;
        }
    }
}
```

**漏桶模型**：
- 桶以恒定速率（100r/s）漏水（处理请求）。
- 突发请求最多攒 burst=200 个等着漏。
- 超过 burst 的请求 → 503（或排队等待）。

### 7.2 limit_conn —— 限并发连接数

```nginx
http {
    limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

    server {
        location / {
            limit_conn conn_limit 10;        # 同 IP 最多 10 个并发连接
        }
    }
}
```

### 7.3 限流 key 怎么选

| key | 适用 |
| --- | --- |
| `$binary_remote_addr` | **IP 限流**（最常用，比 `$remote_addr` 省内存） |
| `$server_name` | 整个 server 总流量 |
| `$request_uri` | 单 URL 限流 |
| `$http_x_forwarded_for` | 多层代理后取真实 IP（注意伪造） |
| 用户 ID（OpenResty 取 cookie/jwt） | 用户级限流，最准确但需 Lua |

### 7.4 跟 Sentinel / 网关限流的关系

| 层 | 工具 | 优势 |
| --- | --- | --- |
| 边缘 / Web | **Nginx limit_req** | **不耗后端资源**，边缘拒绝 |
| 网关 | **Sentinel / APISIX** | 业务感知，可按用户 / API 维度细分 |
| 应用 | Sentinel 内嵌 | 最精细但已经吃服务资源 |

**生产实践**：**多层限流**——Nginx 拦住明显的爬虫攻击，网关做业务级精细限流。

---

## 八、缓存

### 8.1 静态资源浏览器缓存

```nginx
location ~* \.(jpg|png|js|css)$ {
    expires 30d;                            # 等价于 Cache-Control: max-age=2592000
    add_header Cache-Control "public, immutable";
}
```

### 8.2 反向代理缓存（缓存后端响应）

```nginx
http {
    proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=cache:100m max_size=10g
                     inactive=60m use_temp_path=off;

    server {
        location /api/articles/ {
            proxy_cache cache;
            proxy_cache_valid 200 10m;       # 200 缓存 10 分钟
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating http_500 http_502 http_503;
            proxy_cache_lock on;             # 同 key 并发只放一个回源（防雪崩）
            proxy_pass http://backend;

            add_header X-Cache-Status $upstream_cache_status;
        }
    }
}
```

**`proxy_cache_lock`** 是关键——CDN 防穿透雪崩：同 key 同时请求只放一个回源，其他等结果。

### 8.3 内容协商（304）

Nginx 自动支持 ETag / Last-Modified → 客户端命中条件请求时回 `304 Not Modified`，不传 body。

---

## 九、HTTPS 配置

### 9.1 基础 HTTPS

```nginx
server {
    listen 443 ssl http2;                    # http2 必须显式开
    server_name api.example.com;

    ssl_certificate /etc/nginx/cert/fullchain.pem;     # 必须完整证书链（fullchain！）
    ssl_certificate_key /etc/nginx/cert/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;           # 禁用 TLS 1.0 / 1.1
    ssl_ciphers 'ECDHE+AESGCM:ECDHE+CHACHA20:!aNULL';
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:50m;        # session 缓存（多 Worker 共享）
    ssl_session_timeout 1d;
    ssl_session_tickets off;                 # 关闭 session ticket（避免前向保密被弱化）

    # OCSP Stapling（减少浏览器去 CA 查证书）
    ssl_stapling on;
    ssl_stapling_verify on;

    # HSTS（强制 HTTPS）
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # HTTP → HTTPS 重定向
    if ($scheme = http) { return 301 https://$host$request_uri; }
}
```

### 9.2 HTTPS 卸载

边缘 Nginx 解 TLS → 内网 HTTP 转后端：

```
   Client ──HTTPS──► Nginx ──HTTP──► Backend
```

**收益**：
- 后端不耗 CPU 解 TLS。
- 证书集中管理。
- 后端日志 / 调试可见明文。

**坑**：后端拿不到客户端原始 IP/协议 → 必须传 X-Forwarded-For / X-Forwarded-Proto。

```nginx
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```

### 9.3 HTTP/3（QUIC）

Nginx 1.25+ 开始原生支持（之前要 patch / 用 LiteSpeed）。

```nginx
server {
    listen 443 quic reuseport;
    listen 443 ssl http2;

    ssl_protocols TLSv1.3;                    # HTTP/3 必须 TLS 1.3
    add_header Alt-Svc 'h3=":443"; ma=86400'; # 告诉浏览器支持 h3
}
```

国内生产环境 HTTP/3 还在小范围推（运营商对 UDP 限制较多），主流仍是 HTTP/2。

---

## 十、平滑重启 / 热升级（**生产必问**）

### 10.1 reload（平滑重启 = 不丢请求改配置）

```bash
nginx -s reload                              # 等价 kill -HUP <master_pid>
```

**流程**：
1. Master 收到 HUP → 解析新配置 → 启动**新 Workers**。
2. 通知**老 Workers**：不再接收新连接，处理完手头连接后退出。
3. 新 Workers 接管所有新流量。
4. 老 Workers 完成后退出。

**全程零丢包**——这是 Nginx 工程上的优雅之处。

### 10.2 热升级 Nginx 二进制（不停服务换版本）

```bash
# 1. 替换二进制文件
cp nginx-new /usr/sbin/nginx

# 2. 给 Master 发 USR2 → 启动新 Master + 新 Workers
kill -USR2 <old_master_pid>

# 3. 老 Master 改 pid 文件名为 nginx.pid.oldbin，新 Master 用 nginx.pid

# 4. 给老 Master 发 WINCH → 老 Workers 不再接新连接
kill -WINCH <old_master_pid>

# 5. 验证新版本 OK 后给老 Master 发 QUIT
kill -QUIT <old_master_pid>

# 如果新版本有问题，给老 Master 发 HUP 让它重启 Workers，再 QUIT 新 Master
```

---

## 十一、Nginx 衍生 / 网关生态

| 产品 | 关系 | 特色 |
| --- | --- | --- |
| **OpenResty** | Nginx + LuaJIT | **嵌入 Lua 脚本**做业务逻辑（鉴权 / 限流 / 灰度），性能不降 |
| **Tengine** | 阿里 fork Nginx | 主动健检 / 动态 upstream / 一致性哈希等增强 |
| **APISIX** | 基于 OpenResty 的云原生 API 网关 | etcd 配置中心 + 动态路由 + 插件丰富 |
| **Kong** | 基于 OpenResty | API 网关，插件市场丰富，但性能相比 APISIX 略低 |
| **Envoy** | C++，Cloud Native | Service Mesh sidecar 标配（Istio 数据面） |
| **HAProxy** | C，老牌 LB | 4/7 层负载均衡专精 |

**选型**：
- 静态站 / 简单反代 → **Nginx 开源**。
- 需要 Lua 嵌入业务（鉴权 / 限流 / 路由）→ **OpenResty**。
- 微服务 API 网关 → **APISIX** 或 Kong。
- Service Mesh → **Envoy**。

---

## 十二、生产踩坑

### 坑 1：worker_processes 设错

设过多（如 100）→ CPU 跨核切换严重；设过少 → 利用率低。
**修复**：`worker_processes auto`（= CPU 核数）+ `worker_cpu_affinity auto` 绑核。

### 坑 2：worker_connections 太小撑爆

默认 1024，高并发场景一开机就拒绝连接。
**修复**：调到 65535，配合 `worker_rlimit_nofile 65535` 和系统级 `ulimit -n 65535`。

### 坑 3：upstream 没开 keepalive 全短连接

默认 Nginx 到 Backend 是短连接，每次三次握手。
**修复**：
```nginx
upstream backend {
    server 192.168.1.1:8080;
    keepalive 32;                            # 每 Worker 维持 32 个长连接
    keepalive_requests 1000;                 # 每连接最多 1000 请求
    keepalive_timeout 60s;
}
location / {
    proxy_http_version 1.1;                  # 必 HTTP/1.1
    proxy_set_header Connection "";          # 清空 close
    proxy_pass http://backend;
}
```

### 坑 4：proxy_buffering 默认开导致大文件下载内存涨

下载大文件时 Nginx 想完全 buffer 后再返给客户端 → 内存爆。
**修复**：
```nginx
proxy_buffering off;                         # 大文件下载场景关掉
# 或调整 buffer 大小
proxy_buffers 8 64k;
proxy_buffer_size 64k;
```

### 坑 5：客户端真实 IP 拿不到

后端拿到的 `$remote_addr` 是 Nginx 的 IP。
**修复**：Nginx 转发时加 X-Forwarded-For，后端从 header 解析。**反复嵌套代理时**注意 X-F-F 是逗号分隔的列表，第一个是真实 IP（可被伪造，需配合可信代理白名单）。

### 坑 6：ip_hash 流量不均（NAT）

公司出口同一个 IP → 全员打到同一台后端 → 后端单机过载。
**修复**：去 ip_hash，用 sticky cookie + Redis 共享 session。

### 坑 7：limit_req 没配 burst 误杀正常请求

访问页面一个 HTML 带 30 个静态资源 → 100r/s 限制下单用户秒触发。
**修复**：合理设 burst（如 200）+ nodelay 不延时。

### 坑 8：HTTPS 证书链不全 → iOS / Java 客户端失败

Nginx 配的是单证书没拼中间证书。
**修复**：用 fullchain.pem（包含中间 CA），不要单 cert.pem。

### 坑 9：HTTP/2 没显式开，浏览器仍走 HTTP/1.1

```nginx
listen 443 ssl;                              # ❌ 默认不开 h2
listen 443 ssl http2;                        # ✅ 必须显式开
```

### 坑 10：reload 频繁导致文件句柄泄漏

老 Workers 还有长连接（如 WebSocket）没关 → 不退出 → 多次 reload 后老进程堆积。
**修复**：监控 `nginx -V` 看进程数；长连接业务用 `worker_shutdown_timeout 30s` 强制超时。

### 坑 11：sendfile + chunked 冲突

sendfile 默认不能用于 chunked 响应（动态生成）。
**修复**：静态文件路径开 sendfile，动态请求路径关闭 sendfile。

### 坑 12：日志写入磁盘成性能瓶颈

高 QPS 下日志同步写磁盘拖慢响应。
**修复**：
```nginx
access_log /var/log/nginx/access.log main buffer=64k flush=5s;
# 或:
access_log syslog:server=127.0.0.1:514 main;     # 走 syslog
# 或对静态资源关日志:
location /static/ { access_log off; }
```

---

## 十三、面试高频追问

**Q1：Nginx 为什么这么快？**
- **多进程模型** + **epoll 异步事件驱动** → 单 Worker 扛 10w+ 连接。
- **零拷贝**（sendfile）+ tcp_nopush 静态文件极致快。
- **C 语言 + 内存池**——内存分配成本极低。
- **配置编译期处理** → 路由查找快。

**Q2：Master + Worker 模型职责？**
- Master：root 启动，加载配置，管理 Worker（启动/重启/信号转发）。
- Worker：nobody 跑业务，每个 Worker 一个 epoll loop 处理上万连接。
- 一个 Worker 崩了 Master 重启它，不影响其他 Worker。

**Q3：worker_processes 怎么设？**
推荐等于 CPU 核数（`auto`），配合 `worker_cpu_affinity auto` 绑核。设过多反而上下文切换浪费。

**Q4：单 Worker 怎么扛百万并发？**
epoll 多路复用监听 N 个 fd → 每个连接是状态机（不是线程）→ 完全异步非阻塞 → 内存占用极低（每连接几 KB）。

**Q5：怎么解决惊群？**
Nginx 1.9.1+ 默认开 SO_REUSEPORT——每个 Worker 独立 listen socket，内核做负载均衡。老版本用 accept_mutex 抢锁。

**Q6：reload 是热更新吗？怎么做到不丢请求？**
是。Master 收到 HUP → 启新 Worker 接收新流量 → 通知老 Worker 处理完手头请求后退出 → 全程零丢包。

**Q7：负载均衡算法都有啥？怎么选？**
- round-robin（默认）：通用。
- ip_hash：session 粘性，但 NAT 后流量不均。
- least_conn：长连接、请求耗时差异大。
- hash $key consistent：一致性哈希，节点增减迁移最少。
- 生产推荐 round-robin + Redis 共享 session（避免 ip_hash 坑）。

**Q8：怎么做限流？**
- limit_req（漏桶）：限请求速率。
- limit_conn：限并发连接。
- key 用 `$binary_remote_addr`（省内存）或自定义。
- 配合 burst + nodelay 应对突发。

**Q9：反向代理 vs 正向代理？**
反代代理服务端（用户感知不到，访问域名实际是 Nginx），正代代理客户端（用户主动配置，如 VPN）。

**Q10：怎么做动静分离？**
location 按路径 / 后缀路由：静态资源 root 直返（sendfile 零拷贝），动态请求 proxy_pass 到后端。后端不再被静态资源拖累。

**Q11：Nginx 怎么做 HTTPS 卸载？**
边缘 Nginx 配置 ssl_certificate → 解 TLS → 转发后端用 HTTP，X-Forwarded-Proto 头告诉后端原始协议。收益：后端不耗 CPU 解 TLS、证书集中管理。

**Q12：upstream keepalive 默认开吗？**
**默认关**！这是常见生产坑——Nginx 到 Backend 短连接每次握手浪费。必须显式 `keepalive 32 + proxy_http_version 1.1 + proxy_set_header Connection ""`。

**Q13：proxy_buffering 是什么？**
默认开——Nginx 把后端响应缓存到内存或临时文件再发给客户端，避免慢客户端拖慢后端。但大文件下载场景会涨内存，要关掉。

**Q14：OpenResty 跟 Nginx 关系？**
OpenResty = Nginx + LuaJIT，可在 Nginx 各阶段嵌 Lua 写业务（鉴权 / 限流 / 路由 / 缓存）。性能基本不降（Lua JIT 接近 C），是写网关 / 业务逻辑的首选。

**Q15：Nginx vs Envoy？**
- Nginx：传统 Web Server / 反代，配置静态。
- Envoy：云原生 Service Mesh sidecar，xDS 动态配置，HTTP/2 / gRPC 一等公民。
- 微服务 API 网关 → APISIX（基于 Nginx）或 Envoy 都行；服务网格 → Envoy。

**Q16：怎么处理上游故障？**
- max_fails + fail_timeout 被动健检（开源版自带）。
- 主动健检要 Tengine / Nginx Plus。
- proxy_next_upstream 配置故障转移规则。

**Q17：Nginx 配置生效不重启可以吗？**
- 改配置 → `nginx -t` 校验 → `nginx -s reload`（平滑）。
- **完全不重启**改配置 → OpenResty + etcd / APISIX 动态路由（生产微服务网关方案）。

---

## 十四、答题模板（60 秒话术）

> "Nginx 是 Web 流量入口的事实标准，**核心架构是 Master + Worker 多进程模型**。Master 只管 Worker（启动 / 重启 / 信号），Worker 每个一个 **epoll 事件循环**——单线程异步非阻塞，**单 Worker 扛 10w+ 连接**，依赖 Linux epoll + 完全异步 + 状态机模型。
>
> **三大核心场景**：
> ① **反向代理**：隐藏后端 + 横向扩展 + HTTPS 卸载集中管理。
> ② **负载均衡**：round-robin / ip_hash / least_conn / 一致性哈希，生产推荐 round-robin + Redis 共享 session。
> ③ **动静分离**：静态资源 sendfile 零拷贝直发，动态请求转后端，后端不被拖累。
>
> **生产标配**：
> - **限流**：limit_req（漏桶限速率）+ limit_conn（限并发），用 `$binary_remote_addr` 省内存。
> - **缓存**：proxy_cache + proxy_cache_lock（同 key 并发只放一个回源防穿透）。
> - **HTTPS 卸载**：HTTP/2 必显式 `listen 443 ssl http2`，证书必用 fullchain。
>
> **Master + Worker 模型的工程亮点**是 **reload 平滑重启**：HUP 信号 → 启新 Worker 接管新流量 → 老 Worker 处理完老请求后退出 → 零丢包。USR2 还能热升级 Nginx 二进制不停服。
>
> **生产坑 TOP 3**：
> ① **upstream 没开 keepalive**——默认短连接，必显式 `keepalive 32 + proxy_http_version 1.1`。
> ② **ip_hash 流量不均**——NAT 出口同 IP，全员打一台。改用 sticky cookie + Redis 共享 session。
> ③ **proxy_buffering** 大文件下载内存爆——大文件路径单独关。
>
> **生态关系**：OpenResty = Nginx + Lua（写业务网关）；Tengine = 阿里增强版（主动健检）；APISIX / Kong = 云原生 API 网关；Envoy = Service Mesh 数据面。"

---

## 十五、相关文档

- [TCP 协议](../Network/TCP协议.md) — Nginx 调优用得到的 SO_REUSEPORT / TIME_WAIT
- [HTTP 协议](../Network/HTTP协议.md) — Nginx 配 HTTP/2 / HTTP/3 / HTTPS
- [多路复用](../Network/多路复用.md) — Nginx 单 Worker 扛百万的根因（epoll）
- [零拷贝](../Network/零拷贝.md) — sendfile 静态文件零拷贝
- [Microservice / 限流算法](../Microservice/限流算法.md) — Nginx limit_req / Sentinel 多层限流
- [Spring / Spring Cloud Gateway](../Microservice/SpringCloudGateway.md) — Java 网关对比
