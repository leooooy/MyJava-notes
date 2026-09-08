# RPC 原理

> "RPC 跟 HTTP 有什么区别？"——这是中间件面试**入门级筛选题**，能答到"序列化 / 协议头 / IDL 桩文件 / 服务发现"才是合格回答。
> 本篇要解决：
> ① 一次 RPC 调用从**调用方代码**到**网络字节流**的完整旅程
> ② **序列化**对比：Hessian / Kryo / Protobuf / JSON 各自的取舍
> ③ **HTTP vs RPC**——两者本质和工程实践上的差异
> ④ RPC 框架要解决的核心问题：函数映射、网络通信、负载均衡、容错
> ⑤ **gRPC / Dubbo / Thrift / Brpc** 主流框架横评

---

## 一、RPC 是什么 / 为什么必须有

**RPC = Remote Procedure Call**，目标是让远程调用**写起来像调用本地方法**。

```java
// 本地调用
int result = paymentService.pay(orderId, amount);

// RPC 调用 —— 看起来一模一样！
@DubboReference
private PaymentService paymentService;

int result = paymentService.pay(orderId, amount);   // 实际跨进程跨机器
```

**为什么需要 RPC（而不是直接 HTTP）**：

| 维度 | HTTP/JSON | RPC |
| --- | --- | --- |
| 编程模型 | URL + 序列化对象 | 像调本地方法 |
| 序列化 | JSON（文本，体积大） | 二进制（Protobuf/Hessian，小 5-10x） |
| 协议头 | HTTP/1.1 几百字节 header | 自定义协议头 ~20 字节 |
| 服务发现 | 需自己整合 | **框架内置**（注册中心） |
| 负载均衡 | 需要网关或客户端 | **框架内置** |
| 失败重试 | 需手写 | **框架内置** |
| 性能 | 中 | **高 5-10x** |

**结论**：内部微服务调用用 RPC（性能 + 工程化），对外开放 API 用 HTTP（通用、跨语言、调试友好）。

---

## 二、一次 RPC 调用的完整旅程（**面试核心题**）

```
   ┌─── 客户端 ─────────────────────────┐                       ┌─── 服务端 ────────────────────────┐
   │                                    │                       │                                   │
   │  ① 业务代码: payment.pay(123, 500) │                       │  ⑦ 反序列化 → ServerStub          │
   │            ↓                       │                       │            ↓                      │
   │  ② 客户端代理 (动态代理)            │                       │  ⑧ 反射调用 PaymentServiceImpl     │
   │            ↓                       │                       │            ↓                      │
   │  ③ 序列化 (Protobuf/Hessian)       │                       │  ⑨ 序列化 result                  │
   │            ↓                       │                       │            ↓                      │
   │  ④ 协议封装 [magic|len|reqId|body] │  ─── 网络传输 (TCP) ──►│  ⑩ 协议封装 [magic|len|reqId|body]│
   │            ↓                       │                       │            ↓                      │
   │  ⑤ Netty 写出                       │  ◄── 网络传输 (TCP) ── │  ⑪ Netty 写出                      │
   │            ↓                       │                       │                                   │
   │  ⑥ 等待响应 (Future)               │                       │                                   │
   │            ↓                       │                       │                                   │
   │  ⑫ 通过 reqId 匹配响应 → 反序列化  │                       │                                   │
   │            ↓                       │                       │                                   │
   │  ⑬ 返回结果给业务代码              │                       │                                   │
   └────────────────────────────────────┘                       └───────────────────────────────────┘
```

**面试展开点**：
- 步骤 ② **动态代理**：JDK Proxy（基于接口）/ CGLIB / Javassist。
- 步骤 ③ **序列化**：见第三节。
- 步骤 ④ **协议设计**：自定义协议头 vs HTTP/2，长度字段防粘包。
- 步骤 ⑥/⑫ **请求-响应匹配**：每个请求一个 **reqId**，客户端用 `Map<reqId, Future>` 异步等结果。
- 步骤 ⑧ **反射开销**：高性能框架用字节码增强（ASM/Javassist）替代反射。

---

## 三、序列化（RPC 性能的核心）

### 3.1 横向对比

| 方案 | 大小 | 速度 | 跨语言 | 字段兼容 | 自描述 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| **Java 原生** | ★ | ★ | ❌ | 中（serialVersionUID） | ✅ | 安全漏洞频发，**禁用** |
| **JSON** | ★ | ★★ | ✅ | 强 | ✅ | HTTP 接口默认，调试友好 |
| **XML** | ☆ | ☆ | ✅ | 强 | ✅ | 老旧，已淘汰 |
| **Hessian** | ★★★ | ★★★ | ✅（弱） | 中 | ✅ | Dubbo 默认（hessian2） |
| **Kryo** | ★★★★ | ★★★★ | ❌ | 弱 | ✅ | Java 内部高性能，Spark 用 |
| **Protobuf** ⭐ | ★★★★★ | ★★★★ | ✅ | **强**（tag 兼容） | ❌（要 .proto） | gRPC 标配 |
| **Thrift** | ★★★★ | ★★★★ | ✅ | 强 | ❌（要 IDL） | Facebook，Cassandra 用 |
| **Avro** | ★★★★ | ★★★ | ✅ | 强（schema） | ❌（要 schema） | Hadoop / Kafka 用 |
| **MessagePack** | ★★★★ | ★★★★ | ✅ | 弱 | ✅ | Redis、轻量场景 |
| **FlatBuffers** | ★★★★★ | ★★★★★ | ✅ | 强 | ❌ | **零拷贝反序列化**，游戏后端 |
| **FST** | ★★★★ | ★★★★ | ❌ | 中 | ✅ | Java 高性能替代 Kryo |

⭐ **生产最广**：Protobuf > Hessian > Kryo > JSON。

### 3.2 选型决策树

```
 跨语言?
  ├── 是
  │   └── 性能关键? ──── 是 → Protobuf / Thrift
  │                   └── 否 → JSON
  └── 否（纯 Java）
      └── 性能关键? ──── 是 → Kryo / FST
                       └── 否 → Hessian
```

### 3.3 序列化协议踩坑

**坑 1：字段加减导致反序列化失败**
- Java 原生：删字段直接报错。
- Protobuf：每字段有 **tag number**，删字段需"deprecated"保留 tag，新字段用新 tag → **完全向前/向后兼容**。
- Hessian：靠字段名，类型不变兼容；改名等同删字段。

**坑 2：JSON 反序列化攻击（Fastjson 系列）**
JSON 反序列化遇到 `@type` 字段会动态加载类 → 加载恶意类执行命令。**Fastjson 1.x 全版本告急**，生产换 Fastjson2 / Jackson 并禁用 autoType。

**坑 3：Protobuf 的 0/null/默认值傻傻分不清**
Protobuf 3 默认值不传输 → 反序列化拿到 `int=0` 不知道是真 0 还是没传。修复：用 `optional` 关键字（proto3.15+）或包装类型 `Int32Value`。

**坑 4：Kryo 注册类和不注册类性能差异巨大**
未注册时每次序列化都写完整类名（几十字节），注册后只写 1 字节 ID。生产必须 `kryo.register(MyClass.class)`。

---

## 四、协议设计（自定义二进制协议）

### 4.1 典型 RPC 协议头（以 Dubbo 为例）

```
0      1      2      3      4      5      6      7      8      9     10     11    ...
┌──────┬──────┬──────┬──────┬───────────────────────┬───────────────────────────┐
│ MAGIC      │ FLAG │STATUS│        REQUEST ID         │      DATA LENGTH          │
│ 0xdabb     │      │      │       (8 bytes)           │       (4 bytes)           │
└──────┴──────┴──────┴──────┴───────────────────────┴───────────────────────────┘
                                                                              ↓ 之后是 BODY
                                                                  序列化后的请求体（method+args+attachments）
```

字段含义：
| 字段 | 长度 | 作用 |
| --- | --- | --- |
| MAGIC | 2B | 协议魔数 0xdabb，过滤非法包 |
| FLAG | 1B | bit 含义：req/resp、单向调用、序列化方式（hessian/json/kryo） |
| STATUS | 1B | 响应状态码（OK / TIMEOUT / SERVER_ERROR ...） |
| REQUEST ID | 8B | 全局 64 位唯一 ID，**响应通过它匹配请求** |
| DATA LENGTH | 4B | body 字节数，**用于解决 TCP 粘包** |
| BODY | N | 序列化后的请求/响应数据 |

### 4.2 解决粘包/拆包

**TCP 是字节流，无消息边界**——必须由协议层标识。三种主流方案：

| 方案 | 例子 |
| --- | --- |
| 长度字段 | Dubbo / RocketMQ / Thrift（`LengthFieldBasedFrameDecoder`） |
| 分隔符 | Redis RESP（`\r\n`）、HTTP（`\r\n\r\n` 分 header/body） |
| 固定长度 | 老协议、嵌入式 |

详见 [Netty / 5.1 TCP 粘包/拆包](./Netty.md#51-tcp-粘包--拆包面试必问)。

### 4.3 异步请求-响应匹配

客户端发请求时分配 reqId，服务端响应原样返回 → 客户端用 `Map<Long, CompletableFuture>` 找回调：

```java
// 客户端发送
long reqId = nextId();
CompletableFuture<Result> future = new CompletableFuture<>();
pendingMap.put(reqId, future);
channel.writeAndFlush(new Request(reqId, method, args));
return future;                                              // 业务代码 .get() 等结果

// 收到响应时
public void channelRead(Response resp) {
    CompletableFuture<Result> f = pendingMap.remove(resp.reqId);
    f.complete(resp.result);
}
```

**坑**：`pendingMap` 必须设**超时清理**（`HashedWheelTimer`），否则服务端没回响应会内存泄漏。

---

## 五、HTTP vs RPC（**面试必问**）

### 5.1 表面差异

| 维度 | HTTP/1.1 | gRPC（HTTP/2） | Dubbo（自定义 TCP） |
| --- | --- | --- | --- |
| 协议层 | TCP | TCP | TCP |
| 应用协议 | HTTP/1.1 | HTTP/2 | 自定义二进制 |
| 序列化 | JSON | Protobuf | Hessian/Kryo |
| 编程模型 | URL + Body | IDL 生成 stub | 接口动态代理 |
| 流式 | 不支持 | **双向流** | Dubbo3 支持 |
| 头部压缩 | 无 | **HPACK** | 自定义 |

### 5.2 性能差距来源

**HTTP/1.1 的"贵"**：
- 文本协议（每行 `\r\n`，header 大小写敏感解析慢）。
- 每请求一连接 / Keep-Alive 串行（HoL blocking）。
- header 重复传输（每个请求都带 cookie / user-agent）。

**HTTP/2 改善**：
- 二进制帧。
- **多路复用**（一个 TCP 连接并行发 N 个请求）。
- HPACK 压缩 header。
- 服务端推送。

**自定义 RPC 协议的"快"**：
- 二进制 + 短 header（20 字节 vs HTTP 几百字节）。
- 长连接 + 多路复用（reqId 区分）。
- 序列化用 Protobuf/Hessian/Kryo（比 JSON 小 5-10 倍）。

### 5.3 工程差异

**RPC 框架自带**（这是最大的差距）：
- 服务注册与发现（Nacos / ZooKeeper）。
- 负载均衡（Round Robin / Random / 一致性哈希 / 最小活跃）。
- 故障容错（Failover / Failfast / Forking / Broadcast）。
- 限流降级（Sentinel / Hystrix）。
- 链路追踪（Trace ID）。
- 协议升级、灰度发布。

**HTTP 调用要这些 → 必须套微服务网关 + Spring Cloud 全家桶**（Feign + Ribbon + Hystrix）。

### 5.4 怎么选？

| 场景 | 推荐 |
| --- | --- |
| 内部微服务（同 VPC） | **RPC**（Dubbo / gRPC） |
| 对外开放 API（前端 / 小程序 / 第三方） | **HTTP/REST + JSON** |
| BFF 网关聚合多个微服务 | HTTP（外）+ RPC（内） |
| 移动端 SDK | gRPC（流式 + Protobuf 省流量） |
| 简单内部脚本 | HTTP（开发快） |

---

## 六、主流 RPC 框架横评

| 框架 | 出身 | 协议 | 序列化 | 注册中心 | 跨语言 | 长项 | 短板 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Dubbo** | 阿里 | Dubbo TCP / Triple (HTTP/2) | Hessian2 / Kryo / PB | Nacos / ZK | Dubbo3 起跨语言 | **生态完整、中文社区** | 早期 Java only |
| **gRPC** | Google | HTTP/2 | Protobuf | 无（外接） | **极强**（13+ 语言） | **多语言、流式 RPC** | 生态偏轻、没注册中心 |
| **Thrift** | Facebook | TCP | Thrift | 无（外接） | **极强** | **多语言**、Cassandra 等用它 | 生态衰落 |
| **Brpc** | 百度 | 多种（自定义/HTTP/h2/Thrift） | PB / 自定义 | 无 | C++ 优先 | C++ 性能极致 | Java 不友好 |
| **Tars** | 腾讯 | TCP | Tars | TarsServer | C++/Java/Go | 腾讯系完整解决方案 | 生态相对小 |
| **Motan** | 微博 | TCP | Hessian2 / PB | ZK / Consul | Java 优先 | 微博内部成熟 | 社区活跃度一般 |
| **Spring Cloud OpenFeign** | Netflix/Pivotal | HTTP | JSON | Eureka/Nacos | Java | **Spring 全家桶** | 性能不及二进制 RPC |
| **HSF** | 阿里 | TCP | Hessian | ConfigServer | Java | 阿里内部 | 不开源（Dubbo 是开源版） |

**生产建议**：
- 国内 Java 大中型公司 → **Dubbo3**（兼容老 Dubbo 协议 + 新 Triple 协议跨语言）。
- 跨语言 / 云原生 → **gRPC**。
- 简单场景 → **OpenFeign**。

---

## 七、生产踩坑

### 坑 1：JDK 原生序列化反序列化漏洞（CVE）

**现象**：服务对外端口接收到精心构造的字节流 → 反序列化触发恶意类构造方法 → RCE。
**修复**：禁用 Java 原生序列化，全部换 Hessian / Protobuf。

### 坑 2：Hessian 反序列化栈溢出

**现象**：嵌套 List/Map 超过 100 层 → StackOverflow。
**修复**：升级 Hessian2 / 限制嵌套深度。

### 坑 3：客户端连接池耗尽

**现象**：高并发下大量请求 hang，dump 看堆栈卡在 `getConnection`。
**根因**：客户端连接池太小（如 Dubbo 默认 1 个连接 + 多路复用），单连接消息处理慢。
**修复**：调大连接数 `connections=4` 或确保业务异步化。

### 坑 4：超时设置不合理导致雪崩

**典型场景**：A 调 B 设 5s 超时，B 调 C 设 10s 超时 → C 慢时 B 慢慢累积 → A 池子满。
**正确做法**：**下游超时 < 上游超时**，且总链路超时控制在用户能忍受的范围（一般 2-3s）。

### 坑 5：Provider 优雅下线没做好导致丢请求

**现象**：发版时 Provider 收到 SIGTERM 立即关 Netty → 在途请求被中断。
**修复**：
- Provider 收到 SIGTERM 后**先注销注册中心**，等 30s 让 Consumer 拉到新列表。
- 不再接收新请求，等待在途请求处理完。
- Dubbo 的 `qos` + `Graceful Shutdown` 已内置。

### 坑 6：Provider 单台慢拖死整个服务

**现象**：1 台 Provider GC 卡顿 → 该机器请求堆积 → 整个服务超时率上升。
**修复**：用**最少活跃数（LeastActive）**或**响应时间加权**负载均衡，自动避开慢节点。

### 坑 7：协议头 magic 没校验导致 OOM

**现象**：恶意客户端发垃圾字节，DATA LENGTH 字段被解析为 1GB → 服务端分配 1GB ByteBuf 崩。
**修复**：
- 校验 magic（如 0xdabb），不匹配立即断连。
- `LengthFieldBasedFrameDecoder` 设置 `maxFrameLength`（如 16MB）。

### 坑 8：循环引用对象序列化死循环

**现象**：A 持有 B 引用、B 持有 A → JSON 序列化 StackOverflow。
**修复**：JSON 加 `@JsonIgnoreProperties` / `@JsonManagedReference`；Hessian/Protobuf 用 ID 引用。

---

## 八、面试高频追问

**Q1：RPC 的核心要解决什么问题？**
- 函数映射（怎么把"调用 paymentService.pay"翻译成网络消息）→ 动态代理 + IDL/接口约定。
- 网络通信（怎么传）→ TCP + 自定义协议 + Netty。
- 序列化（怎么编码）→ Protobuf / Hessian。
- 服务发现（找谁）→ 注册中心。
- 负载均衡 / 容错 / 限流 → 框架特性。

**Q2：HTTP 跟 RPC 区别？为什么内部用 RPC？**
（详见第五节）一句话：HTTP 是协议，RPC 是调用方式。RPC 通常基于自定义协议或 HTTP/2，**性能 + 工程化生态** 比 HTTP/1.1 强 5-10 倍。内部微服务追求性能选 RPC，对外通用选 HTTP。

**Q3：序列化怎么选？Protobuf 为什么这么快？**
Protobuf 快的原因：
- **变长编码（varint）**：小整数只占 1 字节。
- **Tag-based**：字段不传 0/默认值（除非 optional）。
- **预编译 stub**：生成代码直接读字节，不反射。
- **Schema 强类型**：不需要类型信息（JSON 要传 `"key":"value"`）。

**Q4：动态代理怎么实现的？JDK Proxy vs CGLIB？**
- JDK Proxy：基于接口，运行期生成 `$Proxy0` 代理类（用 ProxyGenerator 直接写 class 字节码）。
- CGLIB：基于继承，运行期用 ASM 生成子类，重写方法。
- Dubbo 默认用 Javassist（性能比 JDK Proxy 高 30%），还支持 BytecodeProxyFactory（更快）。

**Q5：怎么实现请求-响应匹配？**
每个请求分配唯一 reqId，客户端 `Map<reqId, Future>`。**关键**：Map 必须线程安全（ConcurrentHashMap）+ 超时清理（HashedWheelTimer）防止内存泄漏。

**Q6：长连接 vs 短连接？**
- 短连接：每次请求建立 TCP（三次握手 + 慢启动）→ 高并发崩。
- 长连接：连接复用，**多路复用**（reqId 区分）。RPC 必长连接。
- 注意 keepalive：业务层心跳（IdleStateHandler）+ TCP keepalive 都开。

**Q7：怎么做负载均衡？**
- 客户端负载均衡（Dubbo / gRPC）：客户端持有所有 Provider 列表，自己选。
- 服务端负载均衡（Nginx）：网关代理转发。
- 算法：Random / RoundRobin / 一致性哈希 / **最少活跃数（LeastActive）** / **响应时间加权**。
- 详见 [一致性哈希](../Distributed/一致性哈希.md)、[Microservice / 服务治理](../Microservice/服务治理.md)。

**Q8：怎么做容错？**
Dubbo 6 种 cluster 策略：
- Failover（失败重试）：默认，重试 2 次到其他节点。
- Failfast（快速失败）：写场景。
- Failsafe（异常忽略）：日志类。
- Failback（异步重试）：通知类。
- Forking（并行调多个，取最快）：读 + 强一致。
- Broadcast（广播全部）：通知所有 Provider。

**Q9：超时怎么设？**
- **下游 < 上游**（避免上游已超时下游还在跑）。
- 设具体方法粒度而不是全局。
- 配合熔断（Sentinel）+ 重试 + 隔离。

**Q10：泛化调用是什么？**
不依赖接口 jar 包就能调用 RPC（参数传 Map，返回也是 Map）。用于网关、测试工具。Dubbo `GenericService`。

**Q11：Dubbo 跟 gRPC 怎么选？**
- Java only + 国内 → Dubbo3（生态好、有注册中心、Triple 跨语言）。
- 多语言 + 云原生 → gRPC（流式、HTTP/2 通用）。
- Dubbo 3 兼容了 Triple 协议（基于 HTTP/2 + Protobuf），跨语言能力补齐。

**Q12：RPC 怎么做链路追踪？**
- 客户端生成 traceId + spanId 写入协议 attachments。
- 服务端解析后 ThreadLocal 存储，下游调用继续传递。
- 见 [Microservice / 链路追踪](../Microservice/链路追踪.md)。

---

## 九、答题模板（60 秒话术）

> "RPC 让远程调用看起来像本地方法调用，核心要解决 5 件事：**函数映射、网络通信、序列化、服务发现、容错治理**。
>
> **完整调用链**：业务代码 → 动态代理 → 序列化（Protobuf/Hessian）→ 协议封装（magic + reqId + length + body）→ Netty 写出 → 服务端解码 → 反射调用实现类 → 序列化结果回写 → 客户端通过 reqId 匹配回调。
>
> **跟 HTTP 的区别**：HTTP/1.1 文本 + JSON 体积大、header 重；RPC 用**自定义二进制协议 + Protobuf/Hessian**（小 5-10 倍）+ 长连接多路复用 + 框架自带服务发现/负载均衡/容错。**性能高 5-10 倍、工程化完整**，所以内部微服务都用 RPC。HTTP 用在对外开放 API。
>
> **序列化选型**：跨语言性能优先 → Protobuf；纯 Java → Kryo / Hessian；调试方便 → JSON。**禁用 Java 原生序列化**（反序列化漏洞）。
>
> **协议设计**：用长度字段（LengthFieldBasedFrameDecoder）解决 TCP 粘包；reqId 异步匹配请求响应；magic 校验防恶意包；maxFrameLength 防 OOM。
>
> **主流框架**：Dubbo3（国内 Java 首选）、gRPC（跨语言云原生）、Thrift（FB 系）。Dubbo 3 起兼容 Triple 协议（HTTP/2 + Protobuf），具备跨语言能力。
>
> **生产坑**：① 超时下游必须小于上游，否则雪崩；② Provider 优雅下线先注销注册中心；③ 用最少活跃数 LB 避开慢节点；④ 协议必须校验 magic + maxFrameLength。"

---

## 十、相关文档

- [Dubbo](./Dubbo.md) — 国内 Java RPC 主流框架
- [Netty](./Netty.md) — 大部分 RPC 框架的网络层
- [网络IO模型](../Network/网络IO模型.md) — RPC 通信底层
- [Microservice / 服务注册与发现](../Microservice/服务注册与发现.md) — RPC 必备的注册中心
- [Microservice / 服务治理](../Microservice/服务治理.md) — 负载均衡、熔断、限流
- [Microservice / 链路追踪](../Microservice/链路追踪.md) — RPC 调用链监控
- [Distributed / 一致性哈希](../Distributed/一致性哈希.md) — RPC 负载均衡算法
- [Spring / Feign](../Microservice/Feign.md) — Spring Cloud 的 HTTP RPC
