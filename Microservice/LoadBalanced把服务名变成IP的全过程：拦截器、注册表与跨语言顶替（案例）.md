# @LoadBalanced 把服务名变成 IP 的全过程：拦截器、注册表与跨语言顶替（案例）

> **一句话**：`@LoadBalanced` 不是魔法——它只是给 `RestTemplate` 塞了一个 `ClientHttpRequestInterceptor`，把 URL 的 **host 段当成服务名**丢给注册中心换一个真实的 `ip:port`，重写 URI 之后再发出去。
>
> 由此推出一个反直觉的结论：**注册表里那行记录背后是什么语言、什么框架、甚至是不是个 JVM 进程，调用方完全不知道也不关心**。所以一个 Go 服务可以悄无声息地顶替掉一个 Spring Boot 服务，老调用方一行代码都不用改——**只要它在 HTTP 层面把契约对齐**。
>
> 这道题的"段位差"在三点：① 能不能把 `http://service-name/path` 到真实 IP 的**完整调用链**讲到类名级；② 知不知道注册表里的实例**有三种不同来路**、怎么从元数据反推；③ 顶替一个服务时，**除了路径还要对齐哪几件事**——漏掉任何一件都是线上事故。

---

## 一、现象：Nacos 里出现了一个不是 Java 写的 `ai-scheduler`

一个真实的生产拓扑：老 Spring Cloud 单体群（`spring-cloud 2020.0.4` + `spring-cloud-alibaba 2021.1`）里有个服务叫 `ai-scheduler`，被 `xgame`、`cms`、`aipartner` 等多个模块调用。调用代码长这样：

```java
@Component
public class AiTaskClient {
    private static final String SERVICE_NAME = "ai-scheduler";
    private static final String BASE_URL = "http://" + SERVICE_NAME;   // ← host 段就是服务名
    private static final String CREATE_TASK_URI = "/aiTask/create";

    @Resource
    private RestTemplate aiLoadBalanced;

    public AiTaskVO create(AiJobCreateDTO dto) {
        MultiValueMap<String, String> formData = new LinkedMultiValueMap<>();
        formData.add("taskName", dto.getTaskName());
        formData.add("notifyUrl", dto.getNotifyUrl());
        // ... multipart/form-data
        ResponseEntity<String> response =
            aiLoadBalanced.postForEntity(BASE_URL + CREATE_TASK_URI, requestEntity, String.class);
        ...
    }
}
```

那个 `aiLoadBalanced` 的定义：

```java
@Bean(name = "aiLoadBalanced")
@LoadBalanced                       // ← 关键就这一个注解
public RestTemplate aiLoadBalanced() { ... }
```

某天去 Nacos 控制台看这个服务，实例列表里有两行：

| IP:Port | 元数据 | 状态 |
| --- | --- | --- |
| `39.170.5.161:30835` | *(空)* | 上线 |
| `172.31.16.216:9008` | `preserved.register.source=SPRING_CLOUD` | **已下线** |

第二行才是原来那个 Spring Boot 应用（已被人工摘掉），第一行指向的是一台 K8s 节点的 **NodePort**——背后跑的是一个 **Go 重写版**。老 Java 的 `AiTaskClient` 一个字都没改，请求正常打到 Go 服务上，任务正常创建、回调正常返回。

**这怎么做到的？** 得把 `@LoadBalanced` 拆开看。

---

## 二、完整链路：从 `http://ai-scheduler/` 到 `http://39.170.5.161:30835/`

### 2.1 `@LoadBalanced` 本身只是个「标记」

```java
@Target({ ElementType.FIELD, ElementType.PARAMETER, ElementType.METHOD })
@Retention(RetentionPolicy.RUNTIME)
@Inherited
@Qualifier                          // ← 全部秘密就在这里
public @interface LoadBalanced {}
```

它是个 **`@Qualifier` 派生注解**，本身没有任何行为。作用是给 Bean 打个标签，让自动配置能把「带这个标签的 `RestTemplate`」筛出来。

> 类位置：`org.springframework.cloud.client.loadbalancer.LoadBalanced`（在 `spring-cloud-commons` 包里，Ribbon 和 LoadBalancer 两代通用）。

### 2.2 自动配置把拦截器装上去

`LoadBalancerAutoConfiguration` 做两件事：

```java
@LoadBalanced
@Autowired(required = false)
private List<RestTemplate> restTemplates = Collections.emptyList();   // ① 按 @Qualifier 收集

@Bean
public SmartInitializingSingleton loadBalancedRestTemplateInitializerDeprecated(
        final ObjectProvider<List<RestTemplateCustomizer>> restTemplateCustomizers) {
    return () -> restTemplateCustomizers.ifAvailable(customizers -> {
        for (RestTemplate restTemplate : LoadBalancerAutoConfiguration.this.restTemplates) {
            for (RestTemplateCustomizer customizer : customizers) {
                customizer.customize(restTemplate);                    // ② 挨个装拦截器
            }
        }
    });
}
```

内部类 `LoadBalancerAutoConfiguration$LoadBalancerInterceptorConfig` 提供那个 customizer：

```java
@Bean
public LoadBalancerInterceptor loadBalancerInterceptor(
        LoadBalancerClient loadBalancerClient, LoadBalancerRequestFactory requestFactory) {
    return new LoadBalancerInterceptor(loadBalancerClient, requestFactory);
}

@Bean
public RestTemplateCustomizer restTemplateCustomizer(final LoadBalancerInterceptor lbInterceptor) {
    return restTemplate -> {
        List<ClientHttpRequestInterceptor> list = new ArrayList<>(restTemplate.getInterceptors());
        list.add(lbInterceptor);                    // ← 就是往拦截器链里 add 一个
        restTemplate.setInterceptors(list);
    };
}
```

**到这里已经没有魔法了**：`@LoadBalanced` = 「往这个 RestTemplate 的拦截器链里加一个 `LoadBalancerInterceptor`」。

### 2.3 拦截器：把 host 当服务名

`LoadBalancerInterceptor#intercept` 是整条链路的核心，只有几行：

```java
public ClientHttpResponse intercept(final HttpRequest request, final byte[] body,
        final ClientHttpRequestExecution execution) throws IOException {
    final URI originalUri = request.getURI();
    String serviceName = originalUri.getHost();                    // ★ host 段 = 服务名
    Assert.state(serviceName != null,
            "Request URI does not contain a valid hostname: " + originalUri);
    return this.loadBalancer.execute(serviceName,
            this.requestFactory.createRequest(request, body, execution));
}
```

`URI.getHost()` 对 `http://ai-scheduler/aiTask/create` 返回的就是字符串 `"ai-scheduler"`。**这就是为什么服务名必须写在 host 的位置**——写成 `http://gateway/ai-scheduler/...` 是不行的，那样 `getHost()` 拿到的是 `gateway`。

> 也正因为走的是 `URI.getHost()`，**服务名里不能有下划线**。`URI` 解析遵循 RFC 3986，`my_service` 这种 host 在部分 JDK 版本下 `getHost()` 直接返回 `null`，然后你会收到那句莫名其妙的 `Request URI does not contain a valid hostname`。这是个高频踩坑点。

### 2.4 选实例并重写 URI

`BlockingLoadBalancerClient#execute`（`org.springframework.cloud.loadbalancer.blocking.client`）：

```java
ServiceInstance serviceInstance = choose(serviceId, lbRequest);   // ← 选一个实例
if (serviceInstance == null) {
    // 没有可用实例 → 这里抛，报错是 "No instances available for xxx"
}
return execute(serviceId, serviceInstance, lbRequest);
```

`choose()` 最终落到 `RoundRobinLoadBalancer`（`org.springframework.cloud.loadbalancer.core`）——默认轮询，底层从 `ServiceInstanceListSupplier` 拿列表，而 Nacos 的实现由 `spring-cloud-starter-alibaba-nacos-discovery` 提供，数据来自本地缓存的注册表（定时从 Nacos 拉取 + 推送更新）。

拿到 `ServiceInstance` 后，URI 重写发生在 `ServiceRequestWrapper`：

```java
public class ServiceRequestWrapper extends HttpRequestWrapper {
    @Override
    public URI getURI() {
        URI uri = this.loadBalancer.reconstructURI(this.instance, getRequest().getURI());
        return uri;                  // http://ai-scheduler/aiTask/create
    }                                //   → http://39.170.5.161:30835/aiTask/create
}
```

`reconstructURI` 只替换 **scheme / host / port**，**path、query、body、header 全部原样保留**。

### 2.5 全链路一图

```
RestTemplate.postForEntity("http://ai-scheduler/aiTask/create", ...)
      ↓
拦截器链（@LoadBalanced 往里 add 的那个）
      ↓
LoadBalancerInterceptor#intercept
      ├─ originalUri.getHost() → "ai-scheduler"          ★ host 当服务名
      ↓
BlockingLoadBalancerClient#execute("ai-scheduler", req)
      ├─ choose() → RoundRobinLoadBalancer
      │     └─ ServiceInstanceListSupplier（Nacos 实现）
      │           └─ 本地注册表缓存 ← 定时拉取 + 服务端推送
      ↓  选中 ServiceInstance{ip=39.170.5.161, port=30835}
ServiceRequestWrapper#getURI
      ├─ reconstructURI() 只换 scheme/host/port
      ↓
实际发出：POST http://39.170.5.161:30835/aiTask/create
          （path / body / header 一字未改）
```

> **版本提示**：Spring Cloud **2020.0.x（Ilford）起彻底移除了 Ribbon**，默认实现换成 Spring Cloud LoadBalancer。本案例项目 `pom.xml` 里 `spring-cloud.version=2020.0.4` 并显式引入了 `spring-cloud-starter-loadbalancer`，走的就是 `BlockingLoadBalancerClient` 这条路。老项目（Hoxton 及以前）走的是 `RibbonLoadBalancerClient`，**入口的 `LoadBalancerInterceptor` 和「host 当服务名」的机制完全一致**，只是 `choose()` 背后换成了 Ribbon 的 `ILoadBalancer`。详见 [SpringCloud 通用](./SpringCloud通用.md) 的组件演进表。

---

## 三、为什么能跨语言：注册表是一张表，不是一个契约

回到最初的问题。把上面链路里**调用方实际依赖的东西**列出来：

| 调用方依赖什么 | 从哪儿来 |
| --- | --- |
| 服务名 `ai-scheduler` 能查到至少一个实例 | 注册表的一行记录 |
| 那行记录里的 `ip` 和 `port` 可达 | 网络层 |
| 目标机器在那个端口上说 HTTP | 传输层 |
| 目标能处理 `POST /aiTask/create` + multipart 表单 | **应用层契约** |

**这四条里没有任何一条要求对方是 Java。** 注册中心存的是 `ip:port` 加一点元数据，它既不校验实例背后的技术栈，也不知道对方实现了哪些接口——**服务发现只解决「往哪儿发」，不解决「发过去能不能被理解」**。

这既是 Spring Cloud 的灵活之处，也是它最锋利的地方：

- **好的一面**：老系统可以按服务粒度逐个重写，调用方零改动。本案例就是 Java → Go 的渐进式迁移。
- **危险的一面**：往注册表里写一行是**没有门槛**的操作。谁都能注册一个同名实例把流量吸走——这就是经典的**服务注册投毒**。Nacos 如果没开鉴权（`nacos.core.auth.enabled`）且端口对外可达，等于把内部调用的路由表开放给了任何人。

> 本案例的 Nacos 恰好就是无鉴权 + 公网可达的状态：不带任何 token 就能 `GET /nacos/v1/ns/instance/list` 读出全部实例，`POST /nacos/v1/ns/instance` 就能写。这对应 [Microservice 模块 README](./README.md) 「生产踩坑 TOP 14」的第 6 条，但那条说的是**控制台**弱口令，实际上**开放 API 比控制台更危险**——它不需要登录页，也不会留下登录日志。

---

## 四、注册表里的实例有三种来路，元数据能反推

这是个很实用的排查技巧。看回最开始那两行实例的差异：

| 来路 | 怎么产生 | `metadata` 特征 |
| --- | --- | --- |
| **① SDK 自动注册** | 应用引入 `spring-cloud-starter-alibaba-nacos-discovery`，启动时自注册 | Nacos 服务端**强制打上** `preserved.register.source=SPRING_CLOUD` |
| **② 代码主动注册** | 业务代码里自己调 `NamingService#registerInstance(name, ip, port)` | **空**（三参重载不传 metadata） |
| **③ OpenAPI / 控制台** | `POST /nacos/v1/ns/instance` 或控制台「添加实例」 | **空** |

所以看到一条**元数据为空**的实例，就能断定它**不是某个 Spring Boot 应用自注册的**——要么是谁写代码手动注册的，要么是拿 API 塞进去的。

② 这种「代注册」在老项目里比想象中常见。本案例的同一个代码库里就有：

```java
@Component
@RefreshScope
public class NacosClientConfig implements InitializingBean {
    @Override
    public void afterPropertiesSet() throws Exception {
        Properties properties = new Properties();
        properties.put(PropertyKeyConst.SERVER_ADDR, nacosServer);
        properties.put(PropertyKeyConst.NAMESPACE, namespace);
        this.naming = NamingFactory.createNamingService(properties);

        if (isProd()) {
            // todo 临时增加到这里，后面应该由目标程序自己注册
            naming.registerInstance("simswap-service",   "172.31.21.100", 6006);
            naming.registerInstance("partner-face-swap", "18.237.132.214", 6666);
        } else {
            naming.registerInstance("sd-service", "192.168.0.5", 7799);
            naming.registerInstance("sadTalker",  "192.168.0.5", 7007);
        }
    }
}
```

一个 Java 应用**替一堆 GPU 机上的 Python 服务代注册**——那些服务自己不会说 Nacos 协议，于是找个 Java 进程帮它们登记。注释里那句 "todo 临时增加到这里" 已经躺了很久。

这带出一个**必须警惕的耦合**：

> `registerInstance()` 注册的是**临时实例**（ephemeral，默认 true），靠**注册方持续发心跳**续约——5s 一次，15s 不续标记不健康，30s 摘除。代注册意味着**心跳是那个 Java 应用发的**。这个 Java 应用一重启/一下线，**它代注册的所有外部服务会在 30 秒内集体从注册表消失**，哪怕那些 Python 服务活得好好的。
>
> 正确做法是注册成**永久实例**（`ephemeral=false`，靠服务端主动探测健康），或者让目标程序自己注册。临时/永久实例的机制差异见 [Nacos](./Nacos.md)。

---

## 五、查注册表时的三个坑

排查过程中，我拿这条 URL 去查那个实例，结果被报错误导了：

```
GET /nacos/v1/ns/instance?serviceName=ai-scheduler&ip=39.170.5.161&port=30835
→ caused: no ips found for cluster DEFAULT in service DEFAULT_GROUP@@ai-scheduler
```

「查不到」——差点据此认定实例已经掉了。实际上实例好好地活着。

**坑 1：不传 `namespaceId` 默认查 `public`。** 而那个实例注册在 `app-prod` 命名空间里。namespace 是 Nacos 最外层的硬隔离，跨 namespace 完全不可见，而报错信息**不会提示你 namespace 可能选错了**：

```bash
# 先列出所有 namespace（这个接口不需要 namespaceId）
curl "http://<nacos>:8848/nacos/v1/console/namespaces"

# 查询时必须带上
curl "http://<nacos>:8848/nacos/v1/ns/instance/list?serviceName=ai-scheduler&namespaceId=app-prod"
```

**坑 2：`/instance/list` 不返回 `enabled=false` 的实例。** 控制台显示两行，API 只返回一行——因为这个接口是**给消费者用的**，下线（`enabled=false`）的实例本就不该被下发。控制台用的是 `/v1/ns/catalog/instances`，那个才显示全部。

> 对应到调用方：`enabled=false` 的实例**不会**出现在 `ServiceInstanceListSupplier` 给出的列表里，所以不会被 `RoundRobinLoadBalancer` 选中。「下线」是**逻辑摘流**，实例还在、心跳还在，只是不再被下发——这正是灰度/顶替时用来切流量的开关。

**坑 3：`healthy` 和 `enabled` 是两回事。**

| 字段 | 谁决定 | 含义 |
| --- | --- | --- |
| `healthy` | 心跳/健康检查 | 实例**活着吗** |
| `enabled` | 人工操作（上线/下线按钮） | 实例**允许被调用吗** |
| `ephemeral` | 注册时指定 | 临时（心跳续约）还是永久（服务端探测） |

只有 `healthy=true && enabled=true` 的实例才会进入调用方的候选列表。

---

## 六、顶替一个服务，要对齐的远不止路径

Go 版顶替 Java 版之所以能成功，是因为它把 HTTP 层的契约**逐项**对齐了。这份清单值得单独记——**漏掉任何一项，症状都是"调用失败"，但根因完全不同**：

| 维度 | 老 Java 服务端 | 新实现必须做到 | 漏了会怎样 |
| --- | --- | --- | --- |
| **路径** | `@RequestMapping("/aiTask")` + `@PostMapping("/create")` | 注册 `POST /aiTask/create` | 404 |
| **HTTP 方法** | `@RequestMapping("/delete")` **不限方法** | POST 和 GET **都要注册** | 客户端发 GET 就 404 |
| **请求编码** | `multipart/form-data` 表单 | 解析 multipart，**不能只收 JSON** | 400 / 参数全空 |
| **字段命名** | `taskName`、`notifyUrl`（camelCase） | 按 camelCase 收，不能用 snake_case | 参数静默为空 |
| **响应信封** | `ResponseResult<AiTaskVO>`（带 `success`/`data`） | 返回同构 JSON | 客户端反序列化炸 |
| **回调格式** | 接收端签名是 `doNotify(@RequestBody AiTaskVO)`——**裸 VO、无信封** | 回调发裸 VO | 回调方解析失败 |
| **鉴权** | **零鉴权**（集群内服务） | 这组路由**必须豁免**所有鉴权中间件 | 401 |

最后两行最值得展开。

**回调方向和查询方向的信封可以不一致。** 老服务 `/aiTask/view` 返回的是带 `ResponseResult` 信封的，但 webhook 推给调用方的却是**裸 `AiTaskVO`**——因为接收端方法签名是 `@RequestBody AiTaskVO`。这种不对称在老系统里非常常见，**必须逐个接口看接收端的签名，不能想当然**。

**「零鉴权」是一个必须被显式继承的属性。** 老服务之所以不做鉴权，是因为它是 ClusterIP、不挂 Ingress，**安全边界由网络位置保证**。新实现顶替时如果保留了自己的鉴权中间件，老客户端（编译好的 jar，不可能为此改造）会全部 401；但如果豁免了鉴权**却又把端口暴露到公网**，这层原本安全的内部接口就裸奔了。

> 本案例踩的正是后者：Go 版为兼容层写了明确的注释——「老 ai-scheduler 本身同样是零鉴权的集群内服务，安全边界靠只有 ClusterIP、不挂 Ingress 来保证，**切勿把 `/aiTask/*` 对外暴露**」——而实际部署用的是 `type: NodePort`，公网可直接访问。**代码作者预见到了风险并写在注释里，部署时还是违反了**：注释约束不了 YAML。这类跨制品的约束只能靠部署审查或策略引擎（如 OPA/Kyverno）来兜。

---

## 七、复盘要点

1. **`@LoadBalanced` 的全部实现是「往拦截器链里加一个拦截器」**，服务名从 `URI.getHost()` 取。理解这一点，服务名不能带下划线、服务名必须在 host 位、`reconstructURI` 只换 scheme/host/port 这几件事就全是推论。

2. **注册中心只解决「往哪儿发」，不解决「发过去能不能被理解」。** 注册表是一张 `服务名 → 实例列表` 的表，不是接口契约。这既让跨语言渐进迁移成为可能，也意味着**往表里写一行就能劫持流量**。

3. **元数据能反推实例来路**：有 `preserved.register.source=SPRING_CLOUD` = SDK 自注册；空元数据 = 代码手动 `registerInstance` 或 OpenAPI 塞入。排查「这个实例哪来的」时，这是第一个该看的字段。

4. **代注册会把生命周期绑死在代注册方身上**。临时实例靠注册方心跳续约，代注册方一挂，被代注册的服务 30 秒内集体消失——**而那些服务其实活得好好的**。要么用永久实例，要么让目标自己注册。

5. **查不到 ≠ 不存在**。Nacos 查询不传 `namespaceId` 默认查 `public`，跨 namespace 完全不可见且报错不提示；`/instance/list` 还会过滤掉 `enabled=false` 的实例。**用错的查询参数得到的"空结果"，和"真的没有"长得一模一样**。这是个通用判据：**当一个否定结果有多种成因时，不能用它做肯定推论**——必须先排除掉「查询方式本身不对」这一类，才能把"查不到"读成"不存在"。

6. **顶替老服务时，契约清单要逐项对齐**：路径、HTTP 方法（注意 `@RequestMapping` 不限方法）、请求编码、字段命名、响应信封、回调格式、鉴权豁免。**每一项漏掉的症状都是"调用失败"，但根因完全不同**，所以要在动手前列清单，而不是靠联调时逐个撞。

7. **注释约束不了部署清单**。「切勿对外暴露」写在 Java/Go 源码里，YAML 里照样写 `type: NodePort`。跨制品的安全约束需要机器来强制。

---

## 八、面试追问点

> **Q：`@LoadBalanced` 为什么能让 RestTemplate 认识服务名？**
>
> A：它是个 `@Qualifier` 派生注解，本身没有行为。`LoadBalancerAutoConfiguration` 用它把带标记的 `RestTemplate` 收集起来，通过 `RestTemplateCustomizer` 往每个实例的拦截器链里加一个 `LoadBalancerInterceptor`。拦截器在 `intercept()` 里取 `request.getURI().getHost()` 当服务名，交给 `LoadBalancerClient#execute` 选实例，再用 `ServiceRequestWrapper#getURI()` 调 `reconstructURI` 把 scheme/host/port 换成真实地址，path 和 body 原样不动。
>
> **追问：那 Feign 也是这套吗？**
>
> A：机制同源但入口不同。Feign 走的是动态代理生成实现类，最终也会落到 `LoadBalancerClient` 选实例——2020.0.x 之后都是 `BlockingLoadBalancerClient`。区别是 RestTemplate 靠拦截器改 URI，Feign 在构造请求时就用服务名去查。详见 [Feign](./Feign.md)。
>
> **追问：一个非 Java 服务能注册进 Nacos 被 Spring Cloud 调用吗？**
>
> A：能，而且调用方无感知。注册中心存的只是 `ip:port` 和元数据，不校验技术栈。实际做法有三种：目标程序用 Nacos 的多语言 SDK 自注册、由别的服务代调 `registerInstance`、或者直接打 OpenAPI。要注意临时实例的心跳由谁发——代注册的话生命周期会绑在代注册方身上。真正的难点不在注册，在**把 HTTP 契约对齐**：路径、方法、编码、字段命名、响应信封、鉴权，一项都不能漏。

---

## 相关笔记

- [Nacos](./Nacos.md) —— 临时 vs 永久实例、AP/CP 双模式、配置中心长轮询与 2.x gRPC 长连接
- [服务注册与发现](./服务注册与发现.md) —— 客户端发现 vs 服务端发现、五大注册中心横向对比
- [Feign](./Feign.md) —— 另一个入口，同一套 `LoadBalancerClient` 底座
- [SpringCloud 通用](./SpringCloud通用.md) —— Ribbon → Spring Cloud LoadBalancer 的组件演进
- [服务治理](./服务治理.md) —— 顶替期间下游异常时的熔断/降级配合
- [Spring/IoC 容器](../Spring/IoC容器.md) —— `@Qualifier` 派生注解与按类型+限定符注入的底层机制
