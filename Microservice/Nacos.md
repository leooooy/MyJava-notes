# Nacos

> Spring Cloud Alibaba 主推、国内微服务事实标准。
> 这道题面试的"段位差"在三点：
> ① 能不能讲清 **临时实例 vs 永久实例** 的差异和适用场景
> ② 能不能讲清 **配置中心长轮询和 2.x gRPC 长连接** 的演进
> ③ 能不能讲清 Nacos 在 CAP 上的 **AP/CP 双模式**（用 Distro 还是 Raft）

---

## 一、Nacos 是什么

Nacos = **Na**ming + **Co**nfiguration + **S**ervice。

- **服务发现 / 注册中心**：取代 Eureka / Consul / ZK
- **配置中心**：取代 Spring Cloud Config / Apollo
- **服务管理**：流量治理、健康检查、元数据

> **核心卖点**：服务发现 + 配置中心 **二合一**——一个 Nacos 集群搞定两件事。Eureka 时代要单独再起一个 Spring Cloud Config，Nacos 直接省了。

---

## 二、Nacos vs 同类对比

| 维度 | **Nacos** | Eureka | Consul | ZooKeeper |
| --- | --- | --- | --- | --- |
| **CAP** | **AP / CP 可切换** | AP | CP | CP |
| **协议** | HTTP（1.x）/ gRPC（2.x） | HTTP | HTTP / DNS | TCP（自定义） |
| **配置中心** | **✅ 一体** | ❌ | ✅（KV） | ❌ |
| **健康检查** | 心跳 + 主动探测 | 心跳 | 多种（HTTP/TCP/Script） | 会话 |
| **多语言** | Java / Go / Python / Node ... | Java 为主 | 多语言 | 多语言 |
| **集群一致性** | Distro（AP）/ Raft（CP） | P2P 复制 | Raft | ZAB |
| **维护现状** | 阿里持续维护 | **已停更** | HashiCorp | Apache |
| **大厂落地** | 阿里、字节、美团、B 站 | Netflix（已迁走） | 海外为主 | 老项目 |

---

## 三、注册中心：核心概念

### 3.1 临时实例 vs 永久实例

Nacos 把服务实例分两类：

| 维度 | **临时实例**（默认） | **永久实例** |
| --- | --- | --- |
| 元数据存储 | 内存 | 持久化（数据库 / 文件） |
| 健康检查 | **客户端心跳**（5s 一次） | **服务端主动探测**（HTTP/TCP） |
| 心跳超时（不健康） | 15s 没心跳标记不健康 | 由探测决定 |
| 心跳超时（剔除） | 30s 没心跳从注册表删除 | **永久保留**（即使不健康） |
| 适用场景 | **微服务自身**（Spring Cloud 应用） | **基础设施**（DB / Redis / 第三方服务） |

> **生产追问**：为什么会有这两种？
> - 微服务实例上下线频繁，注册不上来或网络抖一下就剔除——临时实例。
> - DB / MySQL 这种基础设施由运维手工注册到 Nacos，进程不主动心跳，但需要 Nacos 持续探测健康——永久实例。

### 3.2 数据模型

```
namespace（环境隔离：dev / test / prod）
   └─ group（业务线分组：DEFAULT_GROUP / PAY_GROUP / ...）
      └─ service（服务名：user-service）
         └─ cluster（集群：北京 / 上海，跨机房路由用）
            └─ instance（具体实例：192.168.1.5:8080）
```

`namespace` 是物理隔离（数据库表里 namespace_id 不同就完全分开）；`group` 是逻辑分组（同 namespace 下 group 不同就视为不同服务）。

---

## 四、注册中心：协议演进

### 4.1 1.x 版本：HTTP

```
客户端                          Nacos Server
   │                                │
   │  POST /nacos/v1/ns/instance    │
   │ ─────────────────────────────▶ │  注册
   │                                │
   │  PUT  /v1/ns/instance/beat     │  心跳（5s 一次）
   │ ─────────────────────────────▶ │
   │                                │
   │  GET  /v1/ns/instance/list     │  拉取服务列表
   │ ─────────────────────────────▶ │
```

**问题**：HTTP 短连接频繁建立和销毁——大量服务实例时连接成本高。

### 4.2 2.x 版本：gRPC 长连接

```
客户端                          Nacos Server
   │                                │
   │ ═══ gRPC stream ═══════════════│  长连接，启动时建立
   │                                │
   │ ── InstanceRequest ──────────▶ │  注册
   │ ◀── InstanceResponse ─────────│
   │                                │
   │ ── 心跳通过连接级保活 ──────────│  无需独立心跳请求
   │                                │
   │ ◀── ConfigChangeNotifyReq ────│  配置 / 服务变更主动推送
```

**优点**：① 推送实时（毫秒级）；② 减少连接开销；③ 双向通信。
**代价**：需要额外开放 9848 / 9849 端口，升级时容易因防火墙挂。

### 4.3 兼容性

Nacos 2.x server **同时** 支持 HTTP（1.x 客户端可继续用）和 gRPC（2.x 客户端用）。

---

## 五、注册中心：服务注册和发现流程

```
启动期
└─ Spring Cloud bean 初始化阶段
   └─ NacosServiceRegistryAutoConfiguration → NacosAutoServiceRegistration
      └─ ApplicationStartedEvent 触发 register()
         └─ NamingService.registerInstance(serviceName, ip, port, ...)
            └─ 1.x：HTTP POST 注册 + 启动 5s 心跳定时任务
            └─ 2.x：通过 gRPC 流注册 + Redo 机制（连接断开重连后自动重新注册）

运行期（A 调 B）
└─ Feign / RestTemplate 发起 lb://user-service/...
   └─ LoadBalancer 取实例列表
      └─ NamingService.selectInstances("user-service", true)  // true = 只要健康的
         └─ 1.x：HTTP 拉取（带本地缓存，10s 一次更新）
         └─ 2.x：本地订阅 + gRPC 推送（变更秒级感知）
   └─ 按算法选一个实例
   └─ 发起 HTTP 调用

关闭期
└─ Spring 容器关闭
   └─ ApplicationContextEvent (closing)
      └─ NamingService.deregisterInstance()  // 主动注销
         └─ 立即从注册表删除（不等心跳超时）
```

### 5.1 客户端服务发现的本地缓存

```java
// ServiceInfoHolder
private final ConcurrentHashMap<String, ServiceInfo> serviceInfoMap;
```

订阅过的服务列表存在内存。**好处**：
- ① Nacos 短暂不可用时，客户端仍能用最后一次的列表调用
- ② 启动时 Nacos 慢，客户端从本地磁盘快照恢复（路径 `~/nacos/naming/...`）

---

## 六、配置中心

### 6.1 配置数据模型

```
namespace + group + dataId  →  唯一配置
```

dataId 命名规则（Spring Cloud Alibaba 默认）：

```
${spring.application.name}-${spring.profiles.active}.${file-extension}
例如：user-service-prod.yaml
```

### 6.2 长轮询机制（1.x）

```
客户端                          Nacos Server
   │                                │
   │ POST /v1/cs/configs/listener   │  长轮询请求（Hold 30s）
   │ ─────────────────────────────▶ │
   │                                │  Server 端：
   │                                │    if (配置变化) 立即返回
   │                                │    else 等 30s 后空响应
   │                                │
   │ ◀───── 30s 后空响应 ───────────│
   │                                │
   │ POST 再发一次                  │  循环
```

**好处**：① 服务端不主动推送（不需要客户端公网可达）；② 实时性接近推送（变更几乎立即返回）。

### 6.3 gRPC 长连接（2.x）

直接用 gRPC stream 推送配置变更，连接级保活。

### 6.4 客户端动态刷新

```java
@RestController
@RefreshScope                                  // ★ 关键
public class FooController {
    @Value("${myapp.foo:default}")
    private String foo;
    
    @GetMapping("/foo")
    public String foo() { return foo; }
}
```

```
配置变更
└─ NacosConfigService 接收推送
└─ 触发 RefreshEvent
└─ ContextRefresher 处理：
   ├─ 重新加载 PropertySource
   ├─ 重新绑定 @ConfigurationProperties
   └─ 销毁所有 @RefreshScope bean，下次访问时重新创建
```

---

## 七、CAP：AP/CP 双模式

### 7.1 何时是 AP，何时是 CP

| 数据类型 | 协议 | 模式 |
| --- | --- | --- |
| 临时实例（心跳维护） | **Distro** | **AP** |
| 永久实例 | **Raft**（1.x）/ **JRaft**（2.x） | **CP** |
| 配置中心 | **Raft** | **CP** |

### 7.2 Distro 协议（AP）

每个 Nacos 节点负责**一部分** 服务的"权威数据"，节点间异步同步。当某节点挂了，其他节点接管它的责任。

```
节点 A：负责 user-service 的注册数据
节点 B：负责 order-service 的注册数据
节点 C：负责 pay-service 的注册数据

   客户端注册 user-service →  路由到 A（按一致性 Hash）
   节点 A 立即返回成功（不等其他节点同步）
   异步推送给 B / C 做副本
```

**特点**：
- ✅ 写入快（不等多数派）
- ✅ 网络分区时仍可写（AP）
- ❌ 短时间内副本可能不一致

适合**临时实例**：服务实例上下线频繁，对一致性要求弱、对可用性要求强。

### 7.3 Raft 协议（CP）

经典 Raft 算法——Leader 写入，多数派确认才返回。一致性强，但 Leader 选举期间不可写。

适合**永久实例 + 配置中心**：实例注册不频繁，配置不能读到旧值。

### 7.4 切换方式

注册时指定：

```yaml
spring:
  cloud:
    nacos:
      discovery:
        ephemeral: true     # 默认 true 临时实例 AP
        # ephemeral: false  # 永久实例 CP
```

> **追问**：能不能整个集群强制切到 CP？2.x 推荐 ephemeral 注册时控制；1.x 有全局开关 `nacos.naming.dataMode=raft`。

---

## 八、生产部署

### 8.1 集群模式

```
[Nacos-1]  [Nacos-2]  [Nacos-3]    ← Nacos Server 集群（奇数节点）
     │         │          │
     └─────────┼──────────┘
               │
        共享 MySQL 持久化
        （存配置和永久实例）
        
        临时实例数据
        在内存（Distro 协议同步）
```

`cluster.conf` 配置节点列表：

```
192.168.1.10:8848
192.168.1.11:8848
192.168.1.12:8848
```

### 8.2 高可用要点

- ① **奇数节点**（3 / 5）—— Raft 多数派要求
- ② **MySQL 高可用**——主从或 RDS（永久实例和配置都依赖）
- ③ **Nacos 前面加 SLB**（Nginx / 公有云 LB）—— 客户端只配 SLB 地址
- ④ **客户端缓存**—— Nacos 全挂时业务仍能跑（用最后一次的服务列表）

### 8.3 容量参考（生产）

| 节点规模 | 配置 | 容量 |
| --- | --- | --- |
| 单节点 | 4C8G | < 5k 服务实例，< 1k 配置项 |
| 3 节点 | 8C16G | 数万实例，万级配置项 |
| 5 节点 | 16C32G | 数十万实例，十万级配置 |

---

## 九、生产踩坑

### 坑 1：1.x → 2.x 升级后客户端注册不上

升级 server 到 2.x，客户端没换代码，启动后注册成功**但服务发现拉不到**。
**根因**：2.x 默认走 gRPC，客户端 1.x 还在用 HTTP；server 端两套数据通道，数据没自动迁移。
**修法**：① 客户端也升级到 2.x；② 临时降级 server 配置 `nacos.naming.snapshot.useHttpToFetch=true`。

### 坑 2：防火墙没开 9848 / 9849

2.x 客户端报 `Client not connected, current status:STARTING`。
**根因**：Nacos 2.x 用 gRPC，需要额外开 9848（gRPC 主端口）和 9849（gRPC 副端口），都是 8848 + 1000 / + 1001。
**修法**：防火墙 / 安全组放开。

### 坑 3：连接数飙升打挂 Nacos

200 个微服务，每个 50 实例 = 1 万实例。每实例和 Nacos 保持长连接，server 内存爆。
**根因**：Nacos 2.x 长连接模型，每个客户端实例是一个连接。
**修法**：① 增加 Nacos 节点；② 升级 Nacos 版本（2.2+ 优化了连接管理）；③ 调大 server 内存和 ulimit。

### 坑 4：配置变更不生效

修改 Nacos 配置后业务 bean 没刷新。
**可能根因**：
1. ❌ bean 没标 `@RefreshScope`
2. ❌ 静态字段（`@Value` 注入静态字段不生效）
3. ❌ `@ConfigurationProperties` 没加 `@RefreshScope`（Spring Cloud 2020+ 自动刷新，1.x 需要手动加）
4. ❌ 配置文件 `dataId` 写错（多了 `.yaml` 后缀等）

**修法**：业务 bean 加 `@RefreshScope`；`@ConfigurationProperties` 在 Spring Cloud 1.x 也要加；监听 `RefreshScopeRefreshedEvent` 验证。

### 坑 5：Nacos 控制台被外网访问导致泄漏

Nacos 默认控制台账号 `nacos/nacos`，公网暴露后被扫到，配置全被读走。
**修法**：① 控制台放内网；② 启用鉴权 `nacos.core.auth.enabled=true` + `nacos.core.auth.server.identity.key/value`。

### 坑 6：服务实例数突增 / 突降导致下游打满

服务发布期间瞬间 50 个实例同时下线——客户端有 10s 缓存延迟，仍把流量打到已下线实例。
**修法**：① 优雅下线（先从 Nacos 注销，等 10s 再停服务）；② 缩短客户端缓存间隔（`nacos.config.long-poll.timeout`）；③ 用 K8s Readiness Probe 控制流量。

---

## 十、面试高频追问

**Q1：Nacos 和 Eureka 区别？**
A：① Nacos 集成了配置中心，Eureka 没有；② Nacos AP/CP 可切，Eureka 纯 AP；③ Nacos 2.x 用 gRPC 长连接，Eureka HTTP 短连接；④ Nacos 健康检查更丰富（心跳+主动探测），Eureka 只有心跳；⑤ Nacos 持续维护，Eureka 已停更。**新项目优先 Nacos**。

**Q2：临时实例 vs 永久实例？**
A：
- 临时实例（默认）：内存存储、客户端心跳、超时剔除——**适合微服务自身**
- 永久实例：持久化存储、服务端主动探测、不健康也不剔除——**适合 DB / Redis 等基础设施**（运维手工注册）

**Q3：Nacos 服务发现的协议？**
A：
- 1.x：HTTP REST + 5s 客户端心跳 + 客户端 10s 拉取
- 2.x：gRPC 长连接 + 流式推送（变更秒级）

升级 2.x 要注意防火墙开 9848 / 9849。

**Q4：Nacos 在 CAP 上是什么？**
A：**AP/CP 双模式**：
- 临时实例 + Distro 协议 = AP（节点负责部分数据，异步同步副本）
- 永久实例 + Raft = CP
- 配置中心 + Raft = CP

**为什么这样选**：服务发现允许"拿到旧数据"——AP；配置不能读旧值——CP。

**Q5：Nacos 配置变更怎么实时推到客户端？**
A：
- 1.x：**长轮询**（客户端 POST 一个 30s 的请求 hold 在服务端，配置变化立即返回）
- 2.x：**gRPC 流推送**（变更秒级到达）

变更后客户端触发 `RefreshEvent`，`@RefreshScope` 标注的 bean 销毁重建，重新读取最新配置。

**Q6：怎么实现 Nacos 配置的动态刷新？**
A：① bean 上加 `@RefreshScope`；② `@Value` 字段会被刷新；③ `@ConfigurationProperties` 在 Spring Cloud 2020+ 自动刷新（1.x 需要在类上加 `@RefreshScope`）。**注意**：static 字段、AOP 拦截不到的内部调用不会刷新。

**Q7：Nacos 集群节点挂一个会怎样？**
A：
- 奇数节点（3、5）—— 多数派仍然存活，集群继续工作
- 临时实例（AP）：挂掉的节点负责的服务列表会被其他节点接管（Distro）
- 永久实例 / 配置（CP）：如果挂的是 Leader，触发 Raft 重新选举，几秒内恢复

**Q8：Nacos 配置中心和 Apollo 怎么选？**
A：
- **Nacos**：注册 + 配置一体，运维简单，性能好。**国内中小企业首选**。
- **Apollo**：功能更全（环境隔离、集群管理、灰度发布、操作审计、权限控制），但运维复杂度高（依赖 Eureka + Portal + 数据库）。**大厂或多团队场景**。
- 二选一原则：人少 / 简单业务 → Nacos；多团队 / 严格审计 → Apollo。

**Q9：Nacos 客户端启动时怎么获取配置？**
A：

```
启动期
└─ NacosBootstrapConfiguration（最早期）
   └─ 拉取 ${app}-${profile}.yaml 等所有 dataId
   └─ 加入 Environment 的 PropertySource（高优先级）
└─ 后续 @Value / @ConfigurationProperties 都能读到
```

如果 Nacos 启动时不可达——可以从本地快照（`~/nacos/config/...`）兜底。

**Q10：Nacos 多环境隔离？**
A：用 `namespace`（推荐）。每个环境（dev / test / prod）一个 namespace，不同 namespace 数据完全隔离（数据库表里 namespace_id 不同）。

```yaml
spring:
  cloud:
    nacos:
      discovery:
        namespace: prod-${UUID}     # 用 UUID 形式
      config:
        namespace: prod-${UUID}
```

避免用 `group`——`group` 是逻辑分组，不是隔离。

---

## 十一、答题模板（60 秒）

> Nacos = **服务发现 + 配置中心 二合一**，Spring Cloud Alibaba 主推、国内事实标准。
>
> **服务发现**：① 临时实例（默认）—— 内存 + 客户端心跳，适合微服务自身；② 永久实例 —— 持久化 + 服务端主动探测，适合 DB / Redis 等基础设施。客户端本地缓存服务列表，Nacos 短暂不可用时仍能调用。
>
> **协议演进**：1.x HTTP REST + 5s 心跳 + 10s 拉取；2.x **gRPC 长连接 + 流式推送**（变更秒级感知）。升级注意防火墙开 9848 / 9849。
>
> **CAP 双模式**：临时实例走 **Distro 协议（AP）**——每个节点负责部分数据异步复制；永久实例 + 配置中心走 **Raft（CP）**——多数派强一致。这样服务发现保可用性，配置中心保一致性。
>
> **配置中心**：1.x 长轮询，2.x gRPC 推送；客户端 `@RefreshScope` + `@Value` / `@ConfigurationProperties` 实现秒级动态刷新。
>
> **生产高频坑**：① 1.x→2.x 升级防火墙 9848；② 客户端连接数过大打爆 server（升级 2.2+）；③ `@RefreshScope` 漏标导致配置不刷新；④ 控制台默认 `nacos/nacos` 千万别公网暴露；⑤ 发布时优雅下线避免流量打到已停实例。

---

## 十二、相关文档

- 上层：[SpringCloud通用.md](SpringCloud通用.md) — 注册中心 / 配置中心选型对比
- 配套：[Feign.md](Feign.md) — Feign 调用如何用 Nacos 发现实例
- 配套：[../Distributed/](../Distributed/README.md) — CAP / Raft 理论
