# Ingress 与网关

> **Service 是 L4（IP+端口），暴露 HTTP/HTTPS 不够用**——Ingress 是 **L7 路由规则**（按 Host / Path 转发到不同 Service），由 **Ingress Controller**（Nginx / Traefik / Istio Gateway）实现。新一代 **Gateway API**（K8s 1.24+ 标准化）正在取代 Ingress，把 Listener / Route / Backend 三层职责切清，跨命名空间复用。
>
> 本篇要解决面试官四个连环追问：
>
> ① **Ingress 跟 Service 区别？为什么需要 Ingress？**——L7 vs L4，Host/Path 路由
> ② **Ingress Resource 跟 Ingress Controller 怎么协作？**——前者是 K8s 对象，后者是真正干活的
> ③ **Gateway API 解决了什么 Ingress 的痛点？**——角色分离、跨命名空间、L4 支持
> ④ **怎么做灰度 / TLS 终结 / 限流？**——Annotation 扩展点
>
> 跟其它模块的关系：
> - 前置：[Service 与 kube-proxy](./Service与kube-proxy.md)（Ingress 后端是 Service）
> - 关联：[Microservice/SpringCloudGateway](../Microservice/SpringCloudGateway.md)（应用层网关 vs 平台层网关）
> - 关联：[Middleware/Nginx](../Middleware/Nginx.md)（Nginx Ingress Controller 底层就是 nginx）

---

## 一、为什么需要 Ingress？

Service 4 种类型暴露 HTTP/HTTPS 都有问题：

| 方案 | 痛点 |
| --- | --- |
| ClusterIP | 集群内访问，外部进不来 |
| NodePort | 端口范围 30000-32767（不是 80/443）；裸暴露节点 IP |
| LoadBalancer（云） | **每个 Service 一个云 LB（一个公网 IP）**——10 个 Service 要 10 个 LB，成本爆炸 |
| ExternalName | 仅 DNS 别名，不解决暴露问题 |

**Ingress 的价值**：**一个 LB 入口 + L7 路由分发到多个 Service**，按 Host / Path 拆：

```
                Cloud LB (1 个公网 IP)
                       │
                       ▼
              Ingress Controller (Nginx Pod)
              监听 80/443
                       │
            ┌──────────┴──────────────┐
            │                         │
   Host: api.example.com    Host: shop.example.com
   Path: /users → user-svc  Path: /orders → order-svc
        /products → prod-svc      /payments → pay-svc
```

**核心收益**：
- 多 Service 共享一个 LB / 公网 IP（**省钱省 IP**）
- 集中做 L7 能力：TLS 终结、灰度路由、限流、鉴权、改写 Header
- 域名管理统一（cert-manager 自动续证）

---

## 二、Ingress Resource：YAML 路由规则

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx          # 哪个 Controller 处理
  tls:
  - hosts: [shop.example.com]
    secretName: shop-tls           # TLS 证书 Secret
  rules:
  - host: shop.example.com         # 按域名匹配
    http:
      paths:
      - path: /api(/|$)(.*)         # 按路径匹配
        pathType: ImplementationSpecific
        backend:
          service:
            name: api-svc
            port:
              number: 80
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-svc
            port:
              number: 80
```

**3 段结构**：
- **Rules**：Host + Path 匹配 → 后端 Service
- **TLS**：HTTPS 证书（来自 Secret）
- **Annotations**：扩展能力（限流 / 灰度 / 鉴权 ……）

---

## 三、Ingress Resource vs Ingress Controller

```
[Ingress Resource] = YAML 配置，纯声明，K8s 对象
                            ↓ watch
[Ingress Controller] = 实际跑在集群里的 Pod（如 nginx-ingress-controller）
                       负责 watch Ingress 资源 → 渲染 Nginx 配置 → reload
                            ↓
[Nginx 进程] = 真正处理流量
```

**关键认知**：K8s 自带 Ingress API 但**不自带 Controller**——必须自己装。常见 Controller：

| Controller | 实现 | 特点 |
| --- | --- | --- |
| **Nginx Ingress** | nginx + watch → 渲染 nginx.conf → reload | **国内主流**，Annotation 丰富 |
| Traefik | 原生 watch + 动态路由（无 reload） | 配置即热更新 |
| HAProxy Ingress | HAProxy + Data Plane API | 性能好 |
| Istio Gateway | Envoy + Service Mesh | 大集群 / Service Mesh 体系 |
| Cloud LB Ingress | 云厂商 ALB（AWS）/ ApplicationLB | 直接用云 LB |

---

## 四、Nginx Ingress Controller 工作机制

### 4.1 启动后的事

```
1. 启动 Nginx 进程
2. 启动 controller goroutine
3. watch Service / Endpoints / Ingress / ConfigMap / Secret
4. 任何变更 → 重新渲染 nginx.conf
5. reload nginx（master 进程平滑重启 worker）
```

### 4.2 配置生成示例

YAML：

```yaml
spec:
  rules:
  - host: shop.example.com
    http:
      paths:
      - path: /api
        backend: api-svc:80
```

渲染成的 nginx.conf（简化）：

```nginx
upstream api-svc {
    server 10.244.1.5:8080;
    server 10.244.1.6:8080;
}

server {
    listen 80;
    server_name shop.example.com;
    
    location /api {
        proxy_pass http://api-svc;
    }
}
```

### 4.3 Annotation 扩展能力

Nginx Ingress 的扩展全靠 annotation：

| Annotation | 作用 |
| --- | --- |
| `nginx.ingress.kubernetes.io/rewrite-target` | URL 改写 |
| `nginx.ingress.kubernetes.io/canary: "true"` + `canary-weight: "20"` | **金丝雀 20% 流量** |
| `nginx.ingress.kubernetes.io/canary-by-header: x-canary` | 按 Header 灰度（精准用户） |
| `nginx.ingress.kubernetes.io/limit-rps: "100"` | 限流 100 RPS |
| `nginx.ingress.kubernetes.io/proxy-body-size: 10m` | Body 大小上限 |
| `nginx.ingress.kubernetes.io/auth-type: basic` | Basic Auth |
| `nginx.ingress.kubernetes.io/ssl-redirect: "true"` | HTTP 强制跳 HTTPS |
| `nginx.ingress.kubernetes.io/cors-allow-origin: "*"` | CORS |
| `nginx.ingress.kubernetes.io/whitelist-source-range: "10.0.0.0/8"` | IP 白名单 |
| `nginx.ingress.kubernetes.io/upstream-vhost: my.host.com` | 改请求 Host 头 |

**生产灰度**：

```yaml
# 主 Ingress：100% → v1
metadata:
  name: api-v1
spec:
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        backend: { service: { name: api-v1, port: { number: 80 } } }

---
# 金丝雀 Ingress：按 Header 走 v2
metadata:
  name: api-v2-canary
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-by-header: "x-canary"
    nginx.ingress.kubernetes.io/canary-by-header-value: "true"
spec:
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        backend: { service: { name: api-v2, port: { number: 80 } } }

# 测试时带 Header: x-canary: true → 走 v2；不带的 → v1
# 没问题后改成按比例：canary-weight: 20（20% 流量到 v2）
```

---

## 五、Gateway API：下一代

K8s 1.24 标准化的新 API，目标是替代 Ingress——解决 Ingress 4 大痛点：

| Ingress 痛点 | Gateway API 解法 |
| --- | --- |
| 表达能力弱（高级能力全靠 annotation） | 原生支持 header / weight / mirror / retry |
| 角色不分（一个 Ingress 既配监听又配路由） | **角色分离**：Gateway（监听）/ Route（路由） |
| 跨命名空间难（Ingress 只能引用同 ns 的 Service） | **ReferenceGrant** 跨 ns 显式授权 |
| 只支持 HTTP/HTTPS | **HTTPRoute / TCPRoute / TLSRoute / GRPCRoute** |

### 5.1 4 个核心资源

```yaml
# 1. GatewayClass：定义"哪个 Controller 实现"（类似 IngressClass）
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: nginx-gateway
spec:
  controllerName: nginx.org/gateway-controller

---
# 2. Gateway：监听端口 + 协议（基础设施团队管）
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shop-gw
  namespace: gateway-ns
spec:
  gatewayClassName: nginx-gateway
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
      - { name: shop-tls }

---
# 3. HTTPRoute：路由规则（业务团队管，可在不同 ns）
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop-route
  namespace: shop-ns
spec:
  parentRefs:
  - name: shop-gw
    namespace: gateway-ns       # 跨 ns 引用 Gateway
  hostnames: ["shop.example.com"]
  rules:
  - matches:
    - path: { type: PathPrefix, value: /api }
    backendRefs:
    - name: api-svc
      port: 80
      weight: 80               # 80% 到 v1
    - name: api-v2-svc
      port: 80
      weight: 20               # 20% 到 v2（原生权重，无需 annotation）

---
# 4. ReferenceGrant：允许 HTTPRoute 跨 ns 引用 Gateway
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: shop-allow
  namespace: gateway-ns
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: shop-ns
  to:
  - group: gateway.networking.k8s.io
    kind: Gateway
```

### 5.2 角色清晰

```
Cluster Operator（运维）→ GatewayClass + Gateway（基础设施）
                                  ↓ 跨 ns 暴露
Application Developer（开发）→ HTTPRoute（业务路由）
```

---

## 六、TLS 终结与证书自动化

### 6.1 TLS 终结模式

| 模式 | 行为 | 用途 |
| --- | --- | --- |
| **Terminate** | LB 解 TLS，后端用 HTTP | 标准（最常用，省后端资源） |
| **Passthrough** | LB 不解 TLS，原始包转后端 | 后端要拿到 client cert / 端到端加密 |
| **Reencrypt** | LB 解 TLS，重新加密发后端 | 集群内也要加密（合规） |

### 6.2 cert-manager 自动续证

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: ops@example.com
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: nginx

---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
  - hosts: [shop.example.com]
    secretName: shop-tls       # cert-manager 自动创建 + 90 天前续期
```

**Let's Encrypt 配额**：单域名每周 50 次签发——批量域名注意速率限制。

---

## 七、生产踩坑

### 坑 1：Nginx Ingress reload 抖断长连接

**现象**：发布期间 WebSocket / SSE / 长 HTTP 连接突然断，客户端报 connection reset。

**根因**：Ingress 任何资源变化（Service 加 Pod）→ Controller 重渲染 nginx.conf → `nginx -s reload` → 老 worker 等连接耗尽，但**新连接打到新 worker，老连接被强制 30s 后中断**（worker_shutdown_timeout）。

**修复**：
- 调大 `nginx.ingress.kubernetes.io/upstream-keepalive-timeout`
- 用 Traefik / Envoy 不需要 reload 的实现
- 减少 reload 频率（避免频繁修改 Service / Pod）

### 坑 2：Path 优先级反直觉

**现象**：写了两条规则 `/api` 和 `/api/v1`，访问 `/api/v1/users` 走了 `/api`。

**根因**：Ingress 多条规则匹配同一请求时，**最长前缀优先 ≠ 最先写优先**——但行为依赖 Controller 实现，不可预期。

**修复**：
- 改 `pathType: Exact` 严格匹配
- 检查具体 Controller 的匹配规则
- 用 Gateway API（明确定义 specificity）

### 坑 3：Annotation 写错触发 nginx.conf 全部失效

**现象**：改了 Ingress annotation 后，**所有** Ingress 规则失效（不止改的那条）。

**根因**：Nginx Ingress Controller 是把所有 Ingress 渲染到一个 nginx.conf；某个 annotation 写错 → `nginx -t` 校验失败 → 整个 reload 拒绝 → **新规则没用，老规则也用不上**（如果是新启动）。

**修复**：
- 改 annotation 前 `kubectl exec ingress-nginx-xxx -- nginx -T` 看渲染结果
- 装 ingress-nginx 的 admission webhook：annotation 错直接拒绝 apply

### 坑 4：Controller Pod CrashLoopBackOff

**现象**：Ingress Controller 不断重启。

**根因**：① 内存不够（Service 多导致 nginx.conf 几十万行 → 解析占内存）；② Lua 模块（rate-limit / 定制 plugin）bug 段错误；③ 集群证书过期 webhook 调用失败。

**修复**：
- 给 Controller 加 limits（4Gi 内存起步）
- 升级 Controller 版本（修 bug）

### 坑 5：跨命名空间引用 Service 失败

**现象**：Ingress 在 ns-A 想引用 ns-B 的 Service `web-svc.ns-B`——失败。

**根因**：Ingress v1 规范**只支持引用同 ns 的 Service**——跨 ns 不行。

**修复**：
- 用 `ExternalName` Service 在本 ns 起个别名
- 或迁 Gateway API（原生支持跨 ns + ReferenceGrant）

---

## 八、面试高频追问

**Q1：Ingress 跟 Service 区别？**

A：**Service 是 L4（IP+端口），Ingress 是 L7（HTTP/HTTPS）**：① Service 不识别 HTTP Host/Path，做不到按域名 / 路径分发；② Service 没有 TLS 终结、限流、鉴权、灰度等 L7 能力。**Ingress 的核心价值**：一个外部 LB（一个公网 IP）通过 L7 路由分发到多个 Service，**省 IP / 省 LB 成本 / 集中 L7 治理**。Ingress 的后端是 Service；Service 的后端是 Pod——两层关系。

**Q2：Ingress Resource 跟 Ingress Controller 怎么协作？**

A：**Ingress Resource 是声明（YAML 对象）**，K8s 自带 API 但不自带实现；**Ingress Controller 是真正干活的 Pod**（如 nginx-ingress-controller）—— watch Ingress 资源 → 渲染配置（nginx.conf）→ reload 生效。装 K8s 不会自动有 Ingress 能力——必须装 Controller。生产常见 Controller：Nginx Ingress（国内主流）、Traefik（动态配置无 reload）、HAProxy、Istio Gateway、云厂商 ALB Controller。

**Q3：Ingress 怎么做灰度发布？**

A：**Nginx Ingress 用 canary annotation**：① **按比例**：`canary: "true"` + `canary-weight: "20"`（20% 流量到金丝雀 Service）；② **按 Header**：`canary-by-header: "x-canary"` + `canary-by-header-value: "true"`（带 Header 的请求走金丝雀，**精准用户灰度**——内部测试 / 客户白名单）；③ **按 Cookie**：`canary-by-cookie`。流程：先按 Header 给内部测 → 没问题切按比例（5% → 20% → 50% → 100%）→ 验证后下旧 Service。**Gateway API** 直接用 `weight` 字段，更原生。

**Q4：Gateway API 跟 Ingress 区别？为什么搞这个？**

A：**Ingress 4 大痛点**：① 表达能力弱（高级能力全靠 annotation，各 Controller 不通用）；② 角色不分（运维和开发改同一个 Ingress 对象）；③ 只支持 HTTP/HTTPS（gRPC / TCP 用不了）；④ 跨命名空间难（只能引用同 ns Service）。**Gateway API 4 大改进**：① **GatewayClass + Gateway + HTTPRoute** 角色分离（基础设施团队管 Gateway，开发管 Route）；② **HTTPRoute / TCPRoute / TLSRoute / GRPCRoute** 多协议；③ **ReferenceGrant** 跨 ns 显式授权；④ **原生支持 weight / header / mirror**，不靠 annotation。K8s 1.24 标准化，1.30 Beta GA，未来取代 Ingress。

**Q5：TLS 终结 / 透传 / 重新加密怎么选？**

A：**Terminate**（LB 解 TLS，后端 HTTP）—— **99% 场景用这个**：省后端资源、统一证书管理。**Passthrough**（不解，原始包给后端）—— 后端要 client cert（mTLS）或合规要求端到端加密。**Reencrypt**（解后再加密）—— 集群内也要加密（金融 / 医疗合规），后端必须支持 TLS。**生产建议**：默认 Terminate + cert-manager 自动续 Let's Encrypt 证书。

**Q6：cert-manager 怎么工作？**

A：cert-manager 是 K8s 的证书管理 Operator——watch Certificate 资源（或 Ingress 上的 cert-manager annotation），调 ACME（如 Let's Encrypt）签证书，存进 Secret。**3 个核心对象**：① **Issuer / ClusterIssuer**：证书签发者配置（ACME / 自签 / Vault / 私有 CA）；② **Certificate**：要签的证书声明；③ **Secret**：实际存证书的 K8s 对象。**ACME 验证方式**：HTTP-01（在 Ingress 上加 `/.well-known/acme-challenge/` 路径）/ DNS-01（写 TXT 记录，支持泛域名）。**90 天前自动续**。

**Q7：Ingress 怎么做 IP 白名单 / 鉴权？**

A：**Nginx Ingress annotation**：

```yaml
nginx.ingress.kubernetes.io/whitelist-source-range: "10.0.0.0/8,172.16.0.0/12"
nginx.ingress.kubernetes.io/auth-type: basic
nginx.ingress.kubernetes.io/auth-secret: basic-auth
nginx.ingress.kubernetes.io/auth-url: "https://auth-svc/verify"   # OAuth 转发鉴权
```

**生产做法**：① 简单 IP 白名单：annotation 直接配；② OAuth / JWT：用 `auth-url` 转发到鉴权服务；③ 复杂业务鉴权：放业务网关（Spring Cloud Gateway）或 Service Mesh（Istio AuthorizationPolicy）。

**Q8：Ingress vs API Gateway vs Service Mesh 怎么选？**

A：**三层互补**：
- **Ingress**：平台层入口网关（南北流量），统一处理 TLS / 域名 / 简单路由 / 限流
- **API Gateway**（Spring Cloud Gateway / Kong）：应用层网关，业务网关——参数校验、协议转换、API 编排、复杂鉴权、API 计费
- **Service Mesh**（Istio）：东西向流量（服务间），透明做 mTLS / 细粒度路由 / 遥测

**生产架构**：外网 → Ingress（TLS+域名）→ API Gateway（业务）→ 应用 Pod（Sidecar Mesh 处理服务间调用）。

**Q9：Ingress 怎么处理 WebSocket？**

A：默认大部分 Ingress Controller 都支持——但**Nginx 默认 60s 空闲超时会断 WS**。修复：

```yaml
nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"     # 1 小时
nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
```

**注意**：Ingress reload 会断长连接（坑 1）；WS 大量场景考虑用 Traefik（动态配置无 reload）或专门的 WS 网关。

**Q10：Ingress 域名解析怎么对接 DNS？**

A：**两层**：① **外层 DNS**：把域名 `shop.example.com` 解析到 Ingress LB 的公网 IP（云 LB 或 NodePort 节点 IP）—— 在 Cloudflare / Route53 / DNSPod 配置 A 记录；② **集群内 DNS**：CoreDNS 处理 Service 名 → ClusterIP（这部分跟 Ingress 无关）。**外网 → 公网 DNS → LB IP → Ingress Controller Pod → Service → Pod**。**自动化**：external-dns Operator 可以根据 Ingress 自动写 DNS 记录（支持各大 DNS 厂商）。

**Q11：Nginx Ingress 怎么避免 reload 的影响？**

A：**减少 reload 触发**：① Service 后端 Pod 变化不应触发 reload —— Nginx Ingress 用 **Lua + dynamic upstream**（开 `--enable-dynamic-configuration`），Pod 变化只更新内存里的 upstream，不 reload；② 配置（Ingress / annotation）变化才会真 reload；③ 用 **Traefik / Envoy** 这种**纯动态**架构（任何变化都不需要进程 reload）。**长连接业务（WS / SSE / gRPC）**优先选 Traefik / Envoy。

**Q12：能不能在多 Ingress Controller 共存？**

A：能——通过 `IngressClass` 区分。装多个 Controller（如 `nginx` 和 `traefik`），Ingress 资源声明 `ingressClassName: nginx` 走哪个。**典型场景**：① 内部服务用 Nginx Ingress，对外服务用 Traefik；② 主集群用 nginx，灰度用 cilium 网关；③ HTTP 用 Nginx，gRPC 用 Envoy。生产建议**默认一种**，特殊场景才分；多套 Controller 增加运维复杂度。

---

## 九、答题模板（60 秒话术）

> Service 是 L4 抽象（IP+端口），暴露 HTTP/HTTPS 不够用——**Ingress 是 L7 路由规则**，按 Host / Path 把流量分发到不同 Service。**核心价值**：一个外部 LB（一个公网 IP）+ L7 分发到 N 个 Service，**省 IP / 省 LB 钱 + 集中处理 TLS / 灰度 / 限流 / 鉴权**。
>
> **K8s 自带 Ingress API 不自带 Controller**——必须装 Ingress Controller（**Nginx Ingress** 国内主流 / Traefik / Envoy / 云厂商 ALB）。Controller 是 Pod，watch Ingress 资源 → 渲染配置（nginx.conf）→ reload。
>
> **Nginx Ingress 灰度**靠 canary annotation：① 按 Header（精准用户）；② 按 Cookie；③ 按权重（5% → 20% → 100%）。**TLS 终结** 配 cert-manager 自动续 Let's Encrypt 证书。**限流 / 鉴权 / IP 白名单** 全靠 annotation。
>
> **Gateway API（K8s 1.24+ 标准化）正在取代 Ingress**——解决 Ingress 4 痛点：① **角色分离**（Gateway 运维管 / HTTPRoute 开发管）；② **跨 ns 引用**（ReferenceGrant 显式授权）；③ **L4 支持**（HTTPRoute / TCPRoute / TLSRoute / GRPCRoute）；④ **原生 weight / header / mirror**，不靠 annotation。
>
> **三层网关边界**：Ingress（平台层 / 南北 / TLS+域名）→ API Gateway（应用层 / 业务 / 鉴权 + 协议转换）→ Service Mesh（东西向 / mTLS + 细粒度路由）。
>
> **5 大生产坑**：① Nginx reload 断长连接（WS/SSE 用 Traefik 或开 dynamic-configuration）；② Path 优先级依赖 Controller 实现（用 pathType: Exact）；③ annotation 写错导致整个 nginx.conf reload 失败（admission webhook 兜底）；④ Controller 内存不够 OOM（4Gi 起步）；⑤ Ingress 不能跨 ns 引用 Service（用 ExternalName 别名 / 迁 Gateway API）。

---

## 十、相关文档

- 前置：[Service 与 kube-proxy](./Service与kube-proxy.md) — Ingress 后端是 Service
- 配套：[发布与弹性伸缩](./发布与弹性伸缩.md) — Ingress canary 做金丝雀发布
- 联动：[Microservice/SpringCloudGateway](../Microservice/SpringCloudGateway.md) — 应用层网关 vs 平台层
- 联动：[Middleware/Nginx](../Middleware/Nginx.md) — Nginx Ingress 底层就是 Nginx
