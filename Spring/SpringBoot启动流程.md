# Spring Boot 启动流程

> 面试常见问题之一。回答 90% 的人停在"`SpringApplication.run` → `refresh` → 启动 Tomcat"——这只是骨架。
> 资深答法的关键：
> ① 讲清 **`SpringApplication` 构造期** 干了什么（不是 `run` 才开始）
> ② 讲清 **8 个 ApplicationListener / ApplicationContextInitializer 钩子** 在哪触发、有什么用
> ③ 讲清 **嵌入式 Tomcat 是从哪一步启起来的**

---

## 一、启动入口

```java
@SpringBootApplication
public class App {
    public static void main(String[] args) {
        SpringApplication.run(App.class, args);
    }
}
```

`SpringApplication.run` 是个静态方法，等价于：

```java
new SpringApplication(App.class).run(args);
```

---

## 二、整体流程鸟瞰

```
┌──────────── 阶段 1：构造 SpringApplication（同步耗时 < 100ms）──────────────┐
│  · 推断应用类型（Web / Reactive / 非 Web）                                   │
│  · 读取 META-INF/spring.factories 加载所有 ApplicationListener / Initializer│
│  · 推断主配置类                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────── 阶段 2：run(args)：12 个步骤 ────────────────────────────────────┐
│  ① 启动 SpringApplicationRunListeners（事件总线）                            │
│  ② 创建并配置 Environment（读 application.yml、profiles、命令行参数）        │
│  ③ printBanner（打印那个 Spring Boot 字样）                                  │
│  ④ 创建 ApplicationContext（按应用类型选具体类型）                           │
│  ⑤ exception reporter 准备好（启动失败的友好报错）                          │
│  ⑥ prepareContext（应用 Initializer，注册主配置类）                          │
│  ⑦ ★ refreshContext —— 调 AbstractApplicationContext.refresh() 12 步        │
│        · 在 onRefresh 这步启动嵌入式 Tomcat！                               │
│  ⑧ afterRefresh（钩子，默认空）                                             │
│  ⑨ 打印启动耗时（"Started Application in 3.5 seconds"）                    │
│  ⑩ 触发 ApplicationStartedEvent                                             │
│  ⑪ 调用 CommandLineRunner / ApplicationRunner                              │
│  ⑫ 触发 ApplicationReadyEvent → 应用真正可用                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 三、阶段 1：`SpringApplication` 构造

```java
public SpringApplication(ResourceLoader resourceLoader, Class<?>... primarySources) {
    this.resourceLoader = resourceLoader;
    this.primarySources = new LinkedHashSet<>(Arrays.asList(primarySources));
    
    // 1. 推断应用类型
    this.webApplicationType = WebApplicationType.deduceFromClasspath();
    
    // 2. 加载 BootstrapRegistryInitializer（Spring Boot 2.4+）
    this.bootstrapRegistryInitializers = new ArrayList<>(
        getSpringFactoriesInstances(BootstrapRegistryInitializer.class));
    
    // 3. 加载 ApplicationContextInitializer（来自 spring.factories）
    setInitializers((Collection) getSpringFactoriesInstances(ApplicationContextInitializer.class));
    
    // 4. 加载 ApplicationListener（来自 spring.factories）
    setListeners((Collection) getSpringFactoriesInstances(ApplicationListener.class));
    
    // 5. 推断主类（看是哪个类调了 main 方法）
    this.mainApplicationClass = deduceMainApplicationClass();
}
```

### 3.1 应用类型推断

| 类型 | 推断依据 | 创建的 ApplicationContext |
| --- | --- | --- |
| **SERVLET** | classpath 有 `Servlet`、`ConfigurableWebApplicationContext` | `AnnotationConfigServletWebServerApplicationContext` |
| **REACTIVE** | 有 `DispatcherHandler`，无 `DispatcherServlet` | `AnnotationConfigReactiveWebServerApplicationContext` |
| **NONE** | 都没有 | `AnnotationConfigApplicationContext`（普通容器） |

> **追问**：为什么要推断？因为同一个 `SpringApplication.run()` 入口要支持 Web / 响应式 / 命令行 / 定时任务等不同形态的应用。

### 3.2 `spring.factories` 加载机制

`SpringFactoriesLoader.loadFactories(...)` 扫描所有 jar 的 `META-INF/spring.factories`：

```properties
# spring-boot/META-INF/spring.factories
org.springframework.context.ApplicationContextInitializer=\
  org.springframework.boot.context.ConfigurationWarningsApplicationContextInitializer,\
  org.springframework.boot.context.ContextIdApplicationContextInitializer,\
  org.springframework.boot.context.config.DelegatingApplicationContextInitializer

org.springframework.context.ApplicationListener=\
  org.springframework.boot.ClearCachesApplicationListener,\
  org.springframework.boot.builder.ParentContextCloserApplicationListener,\
  ...
```

> **Spring Boot 2.7+ 改动**：`@EnableAutoConfiguration` 配置从 `spring.factories` 移到了 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`（一行一个全限定类名）。但 `ApplicationListener` / `ApplicationContextInitializer` 仍走 `spring.factories`。

---

## 四、阶段 2：`run(args)` 详解

### 4.1 完整源码骨架

```java
public ConfigurableApplicationContext run(String... args) {
    long startTime = System.nanoTime();
    DefaultBootstrapContext bootstrapContext = createBootstrapContext();
    ConfigurableApplicationContext context = null;
    configureHeadlessProperty();
    
    // 1. 启动事件总线
    SpringApplicationRunListeners listeners = getRunListeners(args);
    listeners.starting(bootstrapContext, this.mainApplicationClass);
    
    try {
        ApplicationArguments applicationArguments = new DefaultApplicationArguments(args);
        
        // 2. 准备 Environment
        ConfigurableEnvironment environment = prepareEnvironment(listeners, bootstrapContext, applicationArguments);
        configureIgnoreBeanInfo(environment);
        
        // 3. Banner
        Banner printedBanner = printBanner(environment);
        
        // 4. 创建 ApplicationContext
        context = createApplicationContext();
        context.setApplicationStartup(this.applicationStartup);
        
        // 5. exception reporter
        // 6. prepareContext
        prepareContext(bootstrapContext, context, environment, listeners, applicationArguments, printedBanner);
        
        // 7. ★ refreshContext —— 容器初始化的核心
        refreshContext(context);
        
        // 8. afterRefresh
        afterRefresh(context, applicationArguments);
        
        // 9. 启动耗时
        Duration timeTakenToStartup = Duration.ofNanos(System.nanoTime() - startTime);
        new StartupInfoLogger(this.mainApplicationClass).logStarted(getApplicationLog(), timeTakenToStartup);
        
        // 10. ApplicationStartedEvent
        listeners.started(context, timeTakenToStartup);
        
        // 11. 调用 Runner
        callRunners(context, applicationArguments);
    } catch (Throwable ex) {
        handleRunFailure(context, ex, listeners);
        throw new IllegalStateException(ex);
    }
    
    try {
        // 12. ApplicationReadyEvent
        Duration timeTakenToReady = Duration.ofNanos(System.nanoTime() - startTime);
        listeners.ready(context, timeTakenToReady);
    } catch (Throwable ex) {
        handleRunFailure(context, ex, null);
        throw new IllegalStateException(ex);
    }
    
    return context;
}
```

### 4.2 prepareEnvironment 关键步骤

```
1. 创建 Environment（按应用类型，Web 用 StandardServletEnvironment）
2. configureEnvironment：
   · 添加 ConversionService（@Value 类型转换）
   · configurePropertySources：把命令行参数（--xxx=yyy）作为最高优先级 PropertySource
   · configureProfiles：处理 spring.profiles.active
3. 触发 ApplicationEnvironmentPreparedEvent  
   ★ ConfigFileApplicationListener / ConfigDataEnvironmentPostProcessor 在这里加载 application.yml
```

> **追问**：`application.yml` 是什么时候加载的？答：**ApplicationEnvironmentPreparedEvent 触发时**，由 `ConfigDataEnvironmentPostProcessor`（Spring Boot 2.4+）扫描并加载 `application[-profile].yml/properties`。

### 4.3 prepareContext 关键步骤

```
1. context.setEnvironment(environment)
2. postProcessApplicationContext：
   · 注册 BeanNameGenerator（如果有自定义）
   · 设置 ResourceLoader / ClassLoader
3. ★ applyInitializers：
   · 遍历所有 ApplicationContextInitializer，逐个调 initialize(context)
   · 典型用途：自定义读取额外配置、注册 BFPP
4. listeners.contextPrepared(context)
   触发 ApplicationContextInitializedEvent
5. ★ load(context, sources)
   · 把主配置类（@SpringBootApplication）注册到 BeanDefinitionRegistry
   · 此时只是注册，还没实例化
6. listeners.contextLoaded(context)
   触发 ApplicationPreparedEvent
   ★ LoggingApplicationListener 在这里完成 Logback 重新初始化
```

### 4.4 refreshContext —— 核心中的核心

调用 `AbstractApplicationContext.refresh()` 走 12 步（详见 [IoC容器.md](IoC容器.md)）。**Spring Boot Web 的两个关键差异**：

```java
// AnnotationConfigServletWebServerApplicationContext
@Override
protected void onRefresh() {
    super.onRefresh();
    try {
        createWebServer();              // ★ 这里启动嵌入式 Tomcat！
    } catch (Throwable ex) {
        throw new ApplicationContextException("Unable to start web server", ex);
    }
}

private void createWebServer() {
    WebServer webServer = this.webServer;
    ServletContext servletContext = getServletContext();
    if (webServer == null && servletContext == null) {
        ServletWebServerFactory factory = getWebServerFactory();   // 默认 TomcatServletWebServerFactory
        this.webServer = factory.getWebServer(getSelfInitializer());
        // ★ 注册一个销毁回调，shutdown 时优雅停止 Tomcat
        getBeanFactory().registerSingleton("webServerGracefulShutdown",
            new WebServerGracefulShutdownLifecycle(this.webServer));
    }
}
```

> **关键时点**：嵌入式 Tomcat 在 **refresh() 第 9 步 `onRefresh` 时启动**，此时所有 BFPP 已执行（`@Configuration` 已解析），但单例 bean **还没全部实例化**（那是第 11 步）。
>
> **为什么这个顺序很重要**：Spring Boot 在第 11 步实例化 bean 时如果有 bean 依赖了 `ServletContext`，那时 Tomcat 已经启动好了。

---

## 五、Spring Boot 启动事件 8 个钩子

| 事件 | 触发时机 | 典型监听器 / 用途 |
| --- | --- | --- |
| `ApplicationStartingEvent` | run 入口，environment 创建前 | 日志系统初始化、FailureAnalyzer 注册 |
| `ApplicationEnvironmentPreparedEvent` | environment 创建后，context 创建前 | **加载 application.yml**、加载 profile |
| `ApplicationContextInitializedEvent` | context 创建后、Initializer 执行后 | 框架级扩展点 |
| `ApplicationPreparedEvent` | context 加载主配置类后，refresh 前 | **Logback 重新初始化**（用配置文件覆盖默认） |
| `ContextRefreshedEvent`（Spring 内置） | refresh() 第 12 步 | **业务最常用的"启动完成"信号** |
| `ApplicationStartedEvent` | refresh 完成、Runner 调用前 | 监控系统打点 |
| `ApplicationReadyEvent` | Runner 调用后，应用真正可用 | **健康检查放行**、向注册中心注册 |
| `ApplicationFailedEvent` | 启动失败 | 报错告警 |

### 5.1 业务怎么用

最常用的是 `ApplicationReadyEvent`：

```java
@Component
@Slf4j
public class ReadyListener {
    @EventListener(ApplicationReadyEvent.class)
    public void onReady() {
        log.info("应用启动完成，开始预热缓存...");
        cacheService.warmUp();
        // 此刻可以向注册中心注册
    }
}
```

> **`ContextRefreshedEvent` vs `ApplicationReadyEvent`**：前者是 Spring 容器层面的"刷新完成"（refresh() 末尾），后者是 Spring Boot 层面的"应用就绪"（Runner 都跑完）。**业务初始化**用前者，**对外宣告就绪**用后者。

---

## 六、`CommandLineRunner` vs `ApplicationRunner`

```java
// 启动后立即执行的钩子，常用于数据预热、定时任务初始化
@Component
public class WarmupRunner implements ApplicationRunner {
    @Override
    public void run(ApplicationArguments args) {
        if (args.containsOption("warmup")) {
            cache.warm();
        }
    }
}
```

| 维度 | `CommandLineRunner` | `ApplicationRunner` |
| --- | --- | --- |
| 参数类型 | `String[] args` | `ApplicationArguments`（解析后的，可按 name 取） |
| 推荐 | 简单场景 | **推荐**，用法更结构化 |

`@Order` 控制多个 Runner 的执行顺序。**Runner 抛异常会导致启动失败**——把可失败的逻辑放在 `try` 里。

---

## 七、自动配置生效原理（速览，详见专篇）

```
@SpringBootApplication
  = @SpringBootConfiguration   (= @Configuration)
  + @EnableAutoConfiguration   ★ 自动配置开关
  + @ComponentScan
  
@EnableAutoConfiguration
  = @Import(AutoConfigurationImportSelector.class)
  
AutoConfigurationImportSelector.selectImports()
  → 读取 META-INF/spring/...AutoConfiguration.imports（2.7+）
  → 返回所有 XxxAutoConfiguration 类名
  → @Configuration 解析期把这些 @Bean 方法注册到容器
  → @Conditional* 决定哪些 @Bean 真正生效
```

详见 [SpringBoot自动装配.md](SpringBoot自动装配.md)。

---

## 八、生产踩坑

### 坑 1：启动慢

线上启动 60 秒，本地 8 秒。

**排查方法**：用 `ApplicationStartup` API（Spring 5.3+）打开启动追踪：

```java
SpringApplication app = new SpringApplication(App.class);
app.setApplicationStartup(new BufferingApplicationStartup(2048));
app.run(args);
```

启动后 dump 出来用 Java Flight Recorder / Spring Boot Actuator 的 `/actuator/startup` 看。

**常见耗时点**：
- ❌ 大量懒加载也没必要的 bean → 开 `spring.main.lazy-initialization=true`（注意：会延迟暴露问题）
- ❌ 错误的 ClassLoader 反复扫描 → 检查 `@ComponentScan` 范围
- ❌ 数据库连接池初始化慢（连接到不可达的 DB） → 缩短 timeout
- ❌ 类加载文件多（高版本 jvm + Netty）→ AppCDS / GraalVM

### 坑 2：Tomcat 端口被占用

```
Web server failed to start. Port 8080 was already in use.
```

Spring Boot 默认会清晰报错（FailureAnalyzer），改端口或杀进程。

**生产建议**：用 `server.port=0` 让系统自动分配端口（容器化场景）；用 `${random.int(8000,9000)}` 更可控。

### 坑 3：`@PostConstruct` 在启动时报错导致整个应用挂

```java
@Component
public class CacheLoader {
    @PostConstruct
    public void init() {
        loadFromDb();      // ❌ DB 暂时不可达，整个应用启不起来
    }
}
```

**修法**：把"启动期可失败"的初始化挪到 `ApplicationReadyEvent`，并加重试：

```java
@EventListener(ApplicationReadyEvent.class)
public void init() {
    retryTemplate.execute(ctx -> { loadFromDb(); return null; });
}
```

### 坑 4：`@SpringBootApplication` 扫描范围错

启动类放在 `com.foo.app`，业务代码在 `com.bar.service`，启动后 `@Service` 找不到。
**根因**：`@SpringBootApplication` 默认只扫描启动类所在包及其子包。
**修法**：调包结构（推荐）或 `@SpringBootApplication(scanBasePackages={"com.foo","com.bar"})`。

### 坑 5：启动时大量 `BeanCurrentlyInCreationException`

升级到 Spring Boot 2.6+ 后启动失败。
**根因**：默认禁止循环依赖。
**修法**：见 [循环依赖.md](循环依赖.md)。

---

## 九、面试高频追问

**Q1：`SpringApplication.run` 主要做了什么？**
A：12 步：① 启动事件总线；② 准备 Environment（**加载 application.yml**）；③ 打印 banner；④ 创建 ApplicationContext；⑤ 准备失败报告器；⑥ prepareContext（应用 Initializer + 注册主配置类）；⑦ **refresh**（调 12 步刷新，在 `onRefresh` **启动 Tomcat**）；⑧ afterRefresh；⑨ 打印启动耗时；⑩ ApplicationStartedEvent；⑪ 调用 Runner；⑫ ApplicationReadyEvent。

**Q2：嵌入式 Tomcat 是怎么启动的？**
A：Spring Boot 用了一个特殊的 ApplicationContext —— `AnnotationConfigServletWebServerApplicationContext`，它重写了 `onRefresh`（refresh 第 9 步），在里面通过 `ServletWebServerFactory`（默认 `TomcatServletWebServerFactory`）创建并启动嵌入式 Tomcat。Servlet（包括 DispatcherServlet）通过 `ServletContextInitializer` 注册进去。

**Q3：DispatcherServlet 是怎么注册到 Tomcat 的？**
A：`DispatcherServletAutoConfiguration` 把 DispatcherServlet 注册成 `ServletRegistrationBean`。在 `createWebServer` 时通过 `ServletContextInitializer` 把所有 ServletRegistrationBean 注册到 ServletContext，等价于在 web.xml 里写 `<servlet-mapping>`。

**Q4：`ApplicationContextInitializer` 和 `ApplicationListener` 区别？**
A：
- **Initializer**：在 `prepareContext` 阶段调用，能直接操作 ApplicationContext（注册 BFPP、修改 Environment）
- **Listener**：监听事件（11 个事件），通过事件对象间接操作

**Q5：`spring.factories` 何时被读取？**
A：在 `SpringApplication` 构造器里就开始读了——加载 `BootstrapRegistryInitializer` / `ApplicationContextInitializer` / `ApplicationListener`。自动配置类（`@EnableAutoConfiguration`）2.7+ 改读 `META-INF/spring/.../AutoConfiguration.imports` 文件。

**Q6：Spring Boot 启动失败时怎么定位？**
A：Spring Boot 自带 `FailureAnalyzer` 体系——常见错误（端口占用、Bean 创建失败、循环依赖）会输出友好的诊断信息。看不出来的看完整堆栈：`logging.level.org.springframework=DEBUG` 启动期开 debug。

**Q7：怎么自定义启动逻辑？**
A：按需选：
- 容器还没创建：`BootstrapRegistryInitializer`
- 容器准备阶段：`ApplicationContextInitializer`
- 监听某个事件：`ApplicationListener<XxxEvent>`
- 启动完成后：`@EventListener(ApplicationReadyEvent.class)` 或 `ApplicationRunner`

**Q8：怎么实现"启动后异步预热"？**
A：

```java
@EventListener(ApplicationReadyEvent.class)
@Async
public void warmUp() {
    cache.preload();
}
```

注意 `@Async` 要 `@EnableAsync`，且要配置线程池避免用默认 SimpleAsyncTaskExecutor。

---

## 十、答题模板（60 秒）

> Spring Boot 启动分两阶段：
>
> **构造期**（`new SpringApplication`）：① 推断应用类型（Servlet/Reactive/普通）；② 读 `spring.factories` 加载所有 `ApplicationContextInitializer` 和 `ApplicationListener`；③ 推断主配置类。
>
> **运行期**（`run(args)`）12 步：① 启动事件总线；② 准备 Environment（**`ApplicationEnvironmentPreparedEvent` 触发时加载 application.yml**）；③ 打 banner；④ 创建 `ApplicationContext`（Web 是 `AnnotationConfigServletWebServerApplicationContext`）；⑤ 准备失败报告器；⑥ `prepareContext`（执行 Initializer + 注册主配置类）；⑦ **`refresh`** —— 走 `AbstractApplicationContext.refresh()` 12 步，**在 `onRefresh` 这步启动嵌入式 Tomcat**；⑧⑨⑩ 后置；⑪ 调 `CommandLineRunner / ApplicationRunner`；⑫ 触发 `ApplicationReadyEvent`。
>
> 关键事件 8 个：`ApplicationStartingEvent` / `ApplicationEnvironmentPreparedEvent`（**加载配置文件**）/ `ApplicationContextInitializedEvent` / `ApplicationPreparedEvent`（Logback 重新初始化）/ `ContextRefreshedEvent`（容器刷新完成）/ `ApplicationStartedEvent` / **`ApplicationReadyEvent`**（**应用真正可用，对外注册的最佳时机**）/ `ApplicationFailedEvent`。

---

## 十一、相关文档

- 前置：[IoC容器.md](IoC容器.md) — `refresh()` 12 步详解
- 配套：[SpringBoot自动装配.md](SpringBoot自动装配.md) — `@EnableAutoConfiguration` 原理
- 配套：[Starter机制.md](Starter机制.md) — Starter 如何与启动流程协作
- 配套：[InitializingBean和SmartInitializingSingleton.md](InitializingBean和SmartInitializingSingleton.md) — bean 维度的初始化时机
