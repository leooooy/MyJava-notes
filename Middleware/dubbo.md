# Dubbo

> 国内 Java RPC **事实标准**——阿里开源，2018 进 Apache 顶级项目，2021 Dubbo 3.0 成为云原生 RPC。
> 本篇要解决：
> ① Dubbo 的**分层架构**（10 层）每一层在做什么、扩展点在哪
> ② **SPI 微内核**——Dubbo 灵活性的灵魂，与 JDK SPI 区别
> ③ 一次 Dubbo 调用从 `@DubboReference` 到字节流的**完整时序**
> ④ **集群容错 + 负载均衡 + 路由**三大件的协作
> ⑤ Dubbo 2.x → 3.x **核心变化**（Triple 协议、应用级注册）

---

## 一、Dubbo 是什么 / 解决什么

**Dubbo = 高性能 Java RPC 框架 + 服务治理**。Spring Cloud 用 HTTP+JSON+Eureka 解决微服务，Dubbo 用 **二进制 RPC + Hessian + 注册中心**——**性能高 5-10 倍**。

**核心特性**：
- 透明远程调用（注解 + Spring 集成）。
- 多协议（dubbo / triple / rest / grpc / hessian / thrift）。
- 多注册中心（Nacos / ZK / Redis）。
- 内置软负载均衡 + 容错策略。
- **微内核 + SPI**：所有组件都可替换。
- 服务治理（限流 / 熔断 / 路由 / 灰度）。

**Dubbo vs Spring Cloud**：

| 维度 | Dubbo | Spring Cloud |
| --- | --- | --- |
| 协议 | TCP + 自定义二进制 / HTTP/2 (Triple) | HTTP + JSON |
| 性能 | **高 5-10x** | 中 |
| 注册中心 | Nacos / ZK / Redis | Eureka / Nacos / Consul |
| 配置 | 简单（注解为主） | 全家桶组件多 |
| 跨语言 | Dubbo3 起 | 天然跨语言（HTTP） |
| 生态 | 中（国内强） | **极广**（全球生态） |
| 适合 | 内部微服务、性能敏感 | 通用、对外、跨部门 |

---

## 二、分层架构（10 层，**面试必背**）

```
   ┌────────────────────────────────────────────────────────────────┐
   │  ① Service       业务层（用户写的接口/实现）                       │ ← API
   ├────────────────────────────────────────────────────────────────┤
   │  ② Config        配置层（@DubboService、ServiceConfig）           │
   │  ③ Proxy         代理层（动态代理 ProxyFactory）                  │ ← 动态代理生成 Stub
   ├────────────────────────────────────────────────────────────────┤
   │  ④ Registry      注册中心层(Nacos / ZK 注册发现)                   │
   │  ⑤ Cluster       集群容错层(Failover、负载均衡、路由)              │ ← 选哪个 Provider
   │  ⑥ Monitor       监控层(调用次数、耗时统计)                        │
   ├────────────────────────────────────────────────────────────────┤
   │  ⑦ Protocol      远程调用层(封装 Invoker，dubbo/triple/grpc 等)    │ ← 协议适配
   │  ⑧ Exchange      信息交换层(Request/Response 模型)                 │
   │  ⑨ Transport     网络传输层(Netty / Mina / Grizzly)                │ ← Netty 实现
   │  ⑩ Serialize     序列化层(Hessian / Kryo / PB / JSON)              │
   └────────────────────────────────────────────────────────────────┘
```

**面试展开点**：
- 上 3 层是 **API 层**（Service / Config / Proxy）：用户接触面。
- 中 3 层是 **服务发现 + 集群** 层：服务治理核心。
- 下 4 层是 **网络通信** 层：协议、传输、序列化。
- **每一层都是 SPI 扩展点**——可替换，这是 Dubbo 的灵魂。

---

## 三、Dubbo SPI（微内核）⭐

### 3.1 跟 JDK SPI 的区别（必考）

| 维度 | JDK SPI | Dubbo SPI |
| --- | --- | --- |
| 配置位置 | `META-INF/services/接口全名` | `META-INF/dubbo/接口全名`（或 `internal/`） |
| 配置内容 | 实现类全名 | **key=实现类全名**（按 key 取） |
| 加载方式 | `ServiceLoader.load()`，**全部加载**（耗费） | **按 key 懒加载**（只 new 用到的） |
| 失败处理 | 抛异常，整个加载失败 | 单实现失败不影响其他 |
| **依赖注入** | ❌ | ✅（IoC：实现里 setter 自动注入其他 SPI） |
| **AOP 包装** | ❌ | ✅（Wrapper 类自动包装） |
| **自适应**（Adaptive） | ❌ | ✅（运行期根据参数选实现） |

### 3.2 Dubbo SPI 三大特性

#### ① 按 key 加载（懒加载）

```java
// 接口必须加 @SPI 注解
@SPI("dubbo")                                              // 默认值
public interface Protocol { ... }

// 配置文件 META-INF/dubbo/org.apache.dubbo.rpc.Protocol
// dubbo=org.apache.dubbo.rpc.protocol.dubbo.DubboProtocol
// triple=org.apache.dubbo.rpc.protocol.tri.TripleProtocol
// grpc=org.apache.dubbo.rpc.protocol.grpc.GrpcProtocol

// 用法
Protocol p = ExtensionLoader.getExtensionLoader(Protocol.class)
                            .getExtension("dubbo");        // 只加载需要的
```

#### ② IoC（依赖注入）

```java
public class DubboProtocol implements Protocol {
    private Exchanger exchanger;                            // 自动注入
    public void setExchanger(Exchanger e) { this.exchanger = e; }
    // setExchanger 会被 Dubbo 自动调用 → 注入 SPI 实例
}
```

#### ③ AOP（Wrapper 包装）

```java
// 配置文件中如果某个实现类的构造方法接收同接口的参数 → 它是 Wrapper
public class ProtocolFilterWrapper implements Protocol {
    private final Protocol protocol;
    public ProtocolFilterWrapper(Protocol p) { this.protocol = p; }   // 包装
    public Exporter export(Invoker inv) {
        // before：执行 filter 链
        return protocol.export(buildFilterChain(inv));
        // after
    }
}
```

实际加载顺序：`真实实现 → ProtocolFilterWrapper → ProtocolListenerWrapper → ...` 层层包装，类似 Spring AOP。

#### ④ Adaptive（自适应）⭐⭐

**问题**：Protocol 有 dubbo / triple / grpc 多种实现，**调用时才知道用哪个**（URL 里 `protocol=dubbo`），但代码是编译期写好的。

**解法**：动态生成代理类（`Adaptive`），运行期从 URL 里取 `protocol` 参数 → 反查 SPI。

```java
@Adaptive("protocol")                                      // 标注哪个参数决定实现
public Exporter export(Invoker invoker);

// Dubbo 在运行期生成的代码（伪）：
public class Protocol$Adaptive implements Protocol {
    public Exporter export(Invoker invoker) {
        URL url = invoker.getUrl();
        String name = url.getParameter("protocol", "dubbo");
        Protocol real = ExtensionLoader.getExtensionLoader(Protocol.class).getExtension(name);
        return real.export(invoker);                       // 转交真实实现
    }
}
```

**这是 Dubbo 微内核的灵魂**——所有可扩展点都通过 `$Adaptive` 在调用时根据 URL 参数动态选择实现。

---

## 四、一次 Dubbo 调用的完整链路

### 4.1 服务暴露（Provider 端启动）

```
@DubboService 注解扫描
  → ServiceConfig.export()
  → ProxyFactory.getInvoker(ref, interfaceClass, url)         ← 把实现类包装成 Invoker
  → Protocol.export(invoker)                                  ← Adaptive 选 DubboProtocol
      → DubboProtocol.export()
          → openServer()                                      ← 启动 Netty Server (20880 端口)
          → 把 invoker 缓存到 Map<serviceKey, Exporter>
  → Registrar.register(url)                                   ← 注册到 Nacos/ZK
```

### 4.2 服务引用（Consumer 端启动）

```
@DubboReference 注解扫描
  → ReferenceConfig.get()
  → Registry.subscribe()                                      ← 订阅注册中心
      → 收到 providers 列表 → 转成 List<Invoker>
  → Cluster.join(directory)                                   ← 包装成 ClusterInvoker（FailoverClusterInvoker 等）
  → ProxyFactory.getProxy(clusterInvoker)                     ← 生成接口的动态代理
  → 注入到 Spring Bean
```

### 4.3 业务调用

```
业务代码: paymentService.pay(orderId, amount)
  → InvokerInvocationHandler.invoke()                         ← JDK Proxy 拦截
  → ClusterInvoker.invoke(invocation)
      → Directory.list(invocation)                            ← 拿到 List<Invoker>
      → Router.route(invokers)                                ← 标签路由 / 灰度路由
      → LoadBalance.select(invokers)                          ← 选一个（Random/RoundRobin/...）
      → Filter Chain.invoke()                                 ← 经过 ConsumerContextFilter / MonitorFilter / ...
      → Invoker.invoke()                                      ← DubboInvoker
          → 序列化 Request → Netty 写出
          → DefaultFuture.get(timeout)                        ← 等待响应
              ↓ TCP
   ┌────────────────────────────────────────────────────────────┐
   │ Provider 端                                                │
   │   ChannelEventRunnable.run()                               │
   │   → HeaderExchangeHandler.received()                       │
   │   → DubboProtocol.requestHandler()                         │
   │   → Filter Chain → ProtocolFilterWrapper                   │
   │   → invoker.invoke(invocation)                             │
   │   → 反射调用实现类                                          │
   │   → 序列化 Response → 写回 Channel                          │
   └────────────────────────────────────────────────────────────┘
              ↓ TCP
  → DefaultFuture.received() 唤醒
  → 反序列化 Response → 业务拿到结果
```

### 4.4 Filter 链（类似 Servlet Filter）

每次调用前后会经过一系列 Filter，可自定义。Dubbo 内置：

| Filter | 作用 |
| --- | --- |
| ConsumerContextFilter | 设置 RpcContext 上下文 |
| MonitorFilter | 调用次数 / 耗时统计 |
| FutureFilter | 异步调用回调 |
| TpsLimitFilter | TPS 限流 |
| ExecuteLimitFilter | 并发限制 |
| TokenFilter | 服务端令牌验证 |
| AccessLogFilter | 访问日志 |
| ExceptionFilter | 异常包装 |

自定义 Filter 用 SPI：`@Activate(group = {"consumer"})`。

---

## 五、集群容错 + 负载均衡 + 路由（**面试必问**）

### 5.1 Cluster（集群容错策略）

| 策略 | 行为 | 适用 |
| --- | --- | --- |
| **Failover**（默认） | 失败重试其他节点（默认 2 次重试 = 共 3 次调用） | **读操作**、幂等接口 |
| **Failfast** | 失败立即抛异常 | **写操作**（避免重试导致重复） |
| **Failsafe** | 异常吞掉只打日志 | 日志、审计类 |
| **Failback** | 异步重试（失败请求放队列定时重发） | 通知类（异步可达） |
| **Forking** | **并行调多个**节点取最快返回 | 读 + 强一致 + 高 CPU 成本 |
| **Broadcast** | 广播调用所有节点，任一失败即失败 | 通知所有 Provider 缓存更新 |
| **Available** | 调用第一个可用节点 | 简单场景 |
| **Mergeable** | 调多个节点结果合并 | 类 MapReduce |

**配置**：
```yaml
dubbo:
  reference:
    payment-service:
      cluster: failover
      retries: 2                                        # 重试次数
```

### 5.2 LoadBalance（负载均衡）

| 算法 | 说明 |
| --- | --- |
| **Random**（默认） | 加权随机，按权重概率选 |
| **RoundRobin** | 加权轮询（平滑加权 RR） |
| **LeastActive** ⭐ | **最少活跃数**——优先选当前并发最少的，**自动避开慢节点** |
| **ConsistentHash** | 一致性哈希——同参数总打到同节点（场景：用户粘性） |
| **ShortestResponse**（Dubbo 2.7+） | 最短响应时间——避开慢节点更激进 |
| **P2C / EDF**（Dubbo 3.0+） | Power of 2 Choices，业界主流 |

**面试题**：怎么避免慢节点拖死整个服务？
- LeastActive / ShortestResponse 自动减少慢节点流量。
- 配合熔断（Sentinel）。
- 详见 [Microservice / 服务治理](../Microservice/服务治理.md)。

### 5.3 Router（路由）

| Router | 作用 |
| --- | --- |
| ConditionRouter | 条件路由（基于 URL 参数） |
| TagRouter ⭐ | **标签路由**（灰度发布）：consumer 带 tag=gray → 只路由到 tag=gray 的 provider |
| ScriptRouter | 脚本路由（JavaScript / Groovy） |
| MeshRuleRouter（Dubbo 3） | **流量染色**（Service Mesh 集成） |

**典型场景：灰度发布**

```yaml
# Provider A (老版本): 不打 tag
# Provider B (新版本): 打 tag=gray
# Consumer: ctx.setAttachment("dubbo.tag", "gray")
# → 只调用 B
```

---

## 六、协议层

### 6.1 dubbo 协议（默认，二进制）

```
┌──────┬──────┬──────┬──────┬───────────────────────┬─────────────────┐
│ 0xda │ 0xbb │ FLAG │STATUS│    REQUEST ID (8B)     │  DATA LEN (4B)  │
└──────┴──────┴──────┴──────┴───────────────────────┴─────────────────┘
                                                                      ↓
                                                           BODY (Hessian2 序列化)
```

特性：
- 单连接 + 多路复用（reqId 区分请求）。
- 二进制 + Hessian2 序列化。
- 性能极高（百万 QPS+）。

**痛点**：跨语言不友好（Hessian 是 Java 系生态）、不支持流式。

### 6.2 Triple 协议（Dubbo 3 新协议）⭐

**问题**：Dubbo 2 的 dubbo 协议跨语言难，Service Mesh 时代要兼容 gRPC。
**解法**：Triple = **gRPC over HTTP/2 + Dubbo 特性**。

特性：
- HTTP/2 流式（Streaming RPC）。
- 兼容 gRPC（直接和 gRPC 服务互通）。
- Protobuf / Hessian / JSON 三种序列化。
- 保留 Dubbo 的 attachment、注册中心、负载均衡。

**配置**：
```yaml
dubbo:
  protocol:
    name: tri                                           # Triple 协议
    port: 50051
```

### 6.3 协议对比

| 协议 | Dubbo 版本 | 序列化 | 流式 | 跨语言 | 适用 |
| --- | --- | --- | --- | --- | --- |
| dubbo | 2.x / 3.x | Hessian2 | ❌ | 弱 | Java 内部、性能极致 |
| triple | 3.x | PB / Hessian / JSON | ✅ | **强** | 云原生、跨语言 |
| rest | 2.x / 3.x | JSON | ❌ | 强 | 对外 HTTP API |
| grpc | 3.x | PB | ✅ | 强 | 直接复用 gRPC 生态 |

---

## 七、Dubbo 2 vs Dubbo 3（**面试热点**）

### 7.1 Triple 协议（已讲）

### 7.2 应用级服务发现（**重要变化**）

**Dubbo 2.x：接口级注册**

```
注册中心:
  /dubbo/com.xxx.PaymentService/providers/
    └── 192.168.1.1:20880?application=payment-app&...
  /dubbo/com.xxx.UserService/providers/
    └── 192.168.1.1:20880?application=payment-app&...
```

**问题**：一个应用 100 个接口 → 注册中心存 100 条 URL 包含相同的应用元数据 → **元数据爆炸**（阿里内部上线时注册中心扛不住）。

**Dubbo 3.x：应用级注册（仿 Spring Cloud）**

```
注册中心（Nacos）:
  payment-app:
    └── 192.168.1.1:20880

元数据中心（Nacos / ZK 配置项）:
  payment-app:
    interfaces: [PaymentService, UserService, OrderService, ...]
```

**收益**：注册中心只存"应用-实例"映射（百万级实例可承载），接口元数据另放元数据中心。

### 7.3 其它新特性

- **Service Mesh** 集成（与 Istio / Envoy 协同）。
- **流量染色**（统一灰度模型）。
- **AOT / GraalVM Native Image** 支持。

---

## 八、生产踩坑

### 坑 1：Provider 优雅下线丢请求

**场景**：发版时 Provider 收到 SIGTERM → 立即 close 端口 → 已发出但未到达的请求丢失。

**修复**：
```yaml
dubbo:
  application:
    shutwait: 30s                                       # 关闭前等待时间
```
内部流程：
1. 收到信号 → 注册中心反注册（Consumer 30s 内拉到新列表）。
2. 拒绝接收新请求。
3. 等待在途请求完成。
4. 关闭 Netty Server。

### 坑 2：超时设置错误导致雪崩

**典型**：A 调 B 超时 5s，B 调 C 超时 10s → C 慢时 B 慢慢累积请求。
**正确**：**下游超时 < 上游超时 - 处理时间**。一般链路总时长 < 2s。

### 坑 3：retries 用在写接口导致重复扣款

**场景**：Failover 重试 3 次，转账接口非幂等 → 用户被扣 3 次钱。
**修复**：写接口设 `cluster=failfast` 或 `retries=0` + 幂等设计（详见 [幂等](../Distributed/幂等.md)）。

### 坑 4：Provider 单台机器慢拖整个服务

**场景**：1 台 Provider 触发 Full GC，所有 Consumer 仍按 Random LB 派 1/N 流量过去 → 该机器请求堆积 → 超时蔓延。

**修复**：
- 用 **LeastActive** / **ShortestResponse** 负载均衡，自动减少慢节点流量。
- 配合熔断（Sentinel）。

### 坑 5：泛化调用反序列化攻击

**场景**：网关用 GenericService 转发，恶意客户端构造特殊参数触发 RCE。
**修复**：升级 Hessian2、Dubbo 版本 ≥ 2.7.16 / 3.1.5（修复多个 CVE）。

### 坑 6：注册中心抖动导致大量服务下线

**场景**：ZooKeeper 网络抖动 → 临时节点失效 → Consumer 拉到空列表 → "no provider available"。
**修复**：
- Dubbo Consumer 端默认有**故障保护**：拉到空列表保留旧的 provider 列表（不清空）。
- ZK Session Timeout 调大（默认 60s）。
- 用 Nacos 替代 ZK（Nacos 主从复制 + AP 模式更稳定）。

### 坑 7：长连接没心跳 → 网络空闲被中间设备断开

**症状**：连接闲置 10 分钟后，发请求收到 "Connection reset"。
**修复**：Dubbo 默认开启 60s 心跳（HeartBeat），但要确认 `heartbeat=60000` 没被覆盖。

### 坑 8：metadata-center 没配置导致 3.x 报错

**Dubbo 3.x 应用级注册** 必须配 metadata-center，否则注册的接口元数据没地方放：

```yaml
dubbo:
  metadata-report:
    address: nacos://localhost:8848
```

### 坑 9：序列化字段不兼容

**场景**：Provider 加了字段，Consumer 没更新 jar → 反序列化报错。
**修复**：
- 用 Hessian2（容忍字段加减）+ 字段加 `@SerializedField`。
- 升级用 Protobuf（tag 兼容更强）。

### 坑 10：dubbo 协议默认单连接成瓶颈

**场景**：Consumer 调 Provider 默认共用 1 个 TCP 连接 + 多路复用 → 单消息处理慢拖累所有请求。
**修复**：调 `connections=4`（每个 Provider 4 个连接），或大消息接口拆出来。

---

## 九、面试高频追问

**Q1：Dubbo 的 10 层架构每层做啥？**
（详见第二节）记住分组：API 层（Service/Config/Proxy）→ 服务治理层（Registry/Cluster/Monitor）→ 通信层（Protocol/Exchange/Transport/Serialize）。

**Q2：Dubbo SPI 跟 JDK SPI 区别？**
关键：**懒加载（按 key）+ IoC + AOP（Wrapper）+ Adaptive 自适应**。Adaptive 是灵魂——运行期生成 `$Adaptive` 代理，根据 URL 参数选实现。

**Q3：服务暴露和引用流程？**
（详见 4.1 / 4.2）服务暴露 = ProxyFactory 包 Invoker → Protocol 启动 Server → 注册中心；服务引用 = 订阅注册中心 → ClusterInvoker → 动态代理 → Spring Bean。

**Q4：一次 Dubbo 调用怎么走？**
（详见 4.3）业务调用 → JDK Proxy 拦截 → ClusterInvoker → 路由 + LB 选 Invoker → Filter 链 → 序列化 → Netty 写出 → Provider 接收 → 反序列化 → 反射调用 → 写回。

**Q5：Cluster 和 LoadBalance 区别？**
- Cluster 决定**怎么处理失败**（重试/快失败/广播/...）。
- LoadBalance 决定**调哪个节点**（Random/RR/最少活跃/...）。
- 顺序：Cluster 先选策略 → 内部调 LB 选节点 → 失败按 Cluster 策略重试。

**Q6：怎么做灰度发布？**
- TagRouter：Provider 打 tag=gray，Consumer 请求时设 attachment dubbo.tag=gray → 只路由到灰度节点。
- ConditionRouter：基于 IP / 用户 ID 的精细化路由。
- Dubbo 3 提供统一**流量染色** + Service Mesh 集成。

**Q7：Dubbo 3 跟 Dubbo 2 核心区别？**
- **应用级注册**：解决接口级元数据爆炸。
- **Triple 协议**：HTTP/2 + Protobuf + Streaming，跨语言友好，兼容 gRPC。
- **Service Mesh** 集成。
- **AOT / GraalVM** 支持。

**Q8：Triple 跟 gRPC 啥关系？**
Triple = gRPC 协议 + Dubbo 特性。基于 HTTP/2 + Protobuf，**直接和 gRPC 服务互通**——但保留 Dubbo 的注册中心、负载均衡、attachment 等。

**Q9：泛化调用是什么？**
不依赖接口 jar 包就能调（参数用 Map，返回也是 Map）。用于网关、测试工具：

```java
GenericService gs = (GenericService) reference.get();
Object result = gs.$invoke("pay", new String[]{"long","int"}, new Object[]{123L, 500});
```

**Q10：Dubbo 限流降级怎么做？**
- 内置 TpsLimitFilter / ExecuteLimitFilter 简单限流。
- 推荐集成 Sentinel（[Spring / Sentinel](../Microservice/Sentinel.md)）做精细化限流 + 熔断。

**Q11：Dubbo 怎么和 Spring Cloud 互通？**
Dubbo 3 + Nacos 注册中心 + 应用级注册 → Spring Cloud 应用可以发现 Dubbo 应用。但协议不同（HTTP vs Triple/dubbo）→ 用 rest 协议或 Triple（兼容 gRPC）。

**Q12：服务调用上下文怎么传递？**
RpcContext.getContext() 在 Consumer / Provider 端独立存在，调用前 setAttachment，过网络后 Provider getAttachment。**注意线程切换会丢**——异步要手动传递。

**Q13：Dubbo 怎么调试？**
- qos 端口 22222 提供命令行：ls / online / offline / count 等。
- AccessLogFilter 打访问日志。
- 集成 Skywalking / Pinpoint 链路追踪。

**Q14：dubbo 协议和 Triple 选哪个？**
- 纯 Java + 性能极致 + 不需流式 → dubbo。
- 跨语言 / 流式 / 云原生 → Triple。
- 新项目首选 Triple（功能全 + 兼容性好）。

---

## 十、答题模板（60 秒话术）

> "Dubbo 是国内 Java 主流 RPC 框架，定位是 **'高性能 RPC + 服务治理'**——比 Spring Cloud 性能高 5-10 倍，因为用**自定义二进制协议 + Hessian2 序列化 + 长连接多路复用**。
>
> **架构 10 层**分三块：
> - API 层（Service/Config/Proxy）：用户接触的注解和动态代理。
> - 治理层（Registry/Cluster/Monitor）：服务注册发现 + 集群容错 + 监控。
> - 通信层（Protocol/Exchange/Transport/Serialize）：协议封装 + Netty 网络层 + 序列化。
>
> **微内核 + SPI** 是 Dubbo 灵魂：所有组件都是扩展点，通过 **`@SPI` + `@Adaptive`** 运行期根据 URL 参数动态选实现，加上 IoC 和 Wrapper（AOP），灵活性远超 JDK SPI。
>
> **调用流程**：业务代码调接口 → JDK Proxy 拦截 → ClusterInvoker（Failover/Failfast 等）→ Router 路由 → LoadBalance 选节点（Random/最少活跃/一致性哈希）→ Filter 链 → 序列化 → Netty → Provider 反射执行 → 写回。
>
> **Dubbo 3 三大变化**：
> ① **应用级注册**：解决接口级元数据爆炸（百万实例可承载）。
> ② **Triple 协议**：HTTP/2 + Protobuf + 流式 + 兼容 gRPC，跨语言友好。
> ③ Service Mesh 集成 + GraalVM AOT 支持。
>
> **生产踩坑 TOP 3**：
> ① **优雅下线**：发版必先反注册再等 30s。
> ② **超时**：下游必须严格小于上游，避免雪崩。
> ③ **写接口禁用 retries**：Failover 默认重试 3 次会导致重复扣款，必改 Failfast 或确保幂等。"

---

## 十一、相关文档

- [RPC 原理](./RPC原理.md) — RPC 通用原理（Dubbo 是其工业实现）
- [Netty](./Netty.md) — Dubbo 网络层
- [网络IO模型](../Network/网络IO模型.md) — 底层通信
- [Spring / Nacos](../Microservice/Nacos.md) — Dubbo 注册中心首选
- [Spring / Sentinel](../Microservice/Sentinel.md) — Dubbo 限流降级
- [Spring / Feign](../Microservice/Feign.md) — Spring Cloud 的 HTTP RPC（对比）
- [Microservice / 服务治理](../Microservice/服务治理.md) — 负载均衡 / 熔断
- [Microservice / 服务注册与发现](../Microservice/服务注册与发现.md) — Nacos/ZK
- [Distributed / 一致性哈希](../Distributed/一致性哈希.md) — Dubbo LB 算法
- [Distributed / 幂等](../Distributed/幂等.md) — 写接口必备
