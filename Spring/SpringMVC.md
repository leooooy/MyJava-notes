# Spring MVC

> 后端服务 Web 层的标准答案。这道题的"段位差"在两点：
> ① 能不能讲清 **`DispatcherServlet` 9 大组件协作流程**
> ② 能不能讲清 **`HandlerInterceptor` vs `Filter` vs `@ControllerAdvice` vs AOP** 各自适合在哪一层做什么
> 答得出这两块就是高级。

---

## 一、为什么要 Spring MVC

Servlet 原生写法：

```java
public class UserServlet extends HttpServlet {
    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) {
        String userId = req.getParameter("userId");           // 手工取参
        if (userId == null) { resp.sendError(400); return; }
        try {
            User u = userService.findById(Long.parseLong(userId));  // 类型转换
            resp.setContentType("application/json");
            resp.getWriter().write(toJson(u));                       // 手工序列化
        } catch (Exception e) {
            resp.setStatus(500);
            resp.getWriter().write(toJson(Map.of("err", e.getMessage())));
        }
    }
}
```

**痛点**：
1. 每个接口都重复"取参 → 校验 → 调业务 → 序列化"
2. URL 路由要在 web.xml 里手工映射，散乱
3. 异常处理散落在每个 Servlet
4. 没法插钩子（认证、日志、监控）

Spring MVC 把这一切抽象成**前端控制器（Front Controller）模式**——所有请求进 `DispatcherServlet`，按"组件分工"流水线处理。

---

## 二、9 大核心组件

```
┌─────────────────── DispatcherServlet ──────────────────┐
│  HTTP 请求入口，负责 orchestration（协调）              │
└─┬───────────────────────────────────────────────────────┘
  │
  │  1. HandlerMapping            URL → 哪个 Controller 方法
  │  2. HandlerAdapter            适配不同类型的 Handler，统一调用
  │  3. HandlerInterceptor        拦截器（前置/后置/finally 钩子）
  │  4. HandlerExceptionResolver  异常 → ModelAndView 转换
  │  5. HandlerMethodArgumentResolver   参数解析（@RequestParam 等）
  │  6. HandlerMethodReturnValueHandler 返回值处理（@ResponseBody 等）
  │  7. ViewResolver              逻辑视图名 → View 对象
  │  8. View                      渲染响应
  │  9. MultipartResolver         文件上传解析
  │  + LocaleResolver / ThemeResolver / FlashMapManager （非核心）
```

每个组件都是接口，Spring 提供默认实现，开发者也可以自定义注入容器替代。这是 **策略模式 + 模板方法** 的教科书式应用。

---

## 三、完整请求处理流程（13 步）

```
                        浏览器/调用方
                            │
                            ▼ HTTP Request
              ┌──────────── DispatcherServlet ─────────────┐
              │                                              │
   ① doDispatch(request)                                     │
   │                                                         │
   ② getHandler(request) ─── HandlerMapping                  │
   │      ↓                                                  │
   │   HandlerExecutionChain (Handler + Interceptor[])      │
   │                                                         │
   ③ getHandlerAdapter(handler) ─── HandlerAdapter           │
   │                                                         │
   ④ Interceptor.preHandle()  ←─── 拦截器前置                │
   │     (返回 false → 直接结束)                             │
   │                                                         │
   ⑤ HandlerAdapter.handle()                                 │
   │      ↓                                                  │
   │   ⑤.1 ArgumentResolver 解析参数 (@RequestParam/Body)   │
   │   ⑤.2 反射调用 Controller 方法                         │
   │   ⑤.3 ReturnValueHandler 处理返回值                    │
   │           (@ResponseBody → HttpMessageConverter 序列化) │
   │      ↓                                                  │
   │   返回 ModelAndView (REST 接口下为 null)               │
   │                                                         │
   ⑥ Interceptor.postHandle()  ←─── 拦截器后置（视图渲染前） │
   │                                                         │
   ⑦ processDispatchResult                                   │
   │   ⑦.1 异常 → ExceptionResolver → ModelAndView          │
   │   ⑦.2 ViewResolver 解析视图（REST 跳过）                │
   │   ⑦.3 View.render() 渲染                                │
   │                                                         │
   ⑧ Interceptor.afterCompletion() ←─── 拦截器 finally 钩子 │
   │                                                         │
              └────────────────────┬───────────────────────┘
                                    ▼ HTTP Response
                              浏览器/调用方
```

### 3.1 关键节点源码（`DispatcherServlet.doDispatch`）

```java
protected void doDispatch(HttpServletRequest request, HttpServletResponse response) {
    HandlerExecutionChain mappedHandler = null;
    Exception dispatchException = null;
    try {
        // 1. 找 Handler
        mappedHandler = getHandler(request);
        if (mappedHandler == null) { noHandlerFound(...); return; }
        
        // 2. 找 HandlerAdapter
        HandlerAdapter ha = getHandlerAdapter(mappedHandler.getHandler());
        
        // 3. 拦截器前置
        if (!mappedHandler.applyPreHandle(request, response)) return;
        
        // 4. 调用 Controller
        ModelAndView mv = ha.handle(request, response, mappedHandler.getHandler());
        
        // 5. 拦截器后置
        mappedHandler.applyPostHandle(request, response, mv);
        
        // 6. 处理结果（视图渲染或异常）
        processDispatchResult(request, response, mappedHandler, mv, null);
    } catch (Exception ex) {
        dispatchException = ex;
        processDispatchResult(request, response, mappedHandler, null, dispatchException);
    } finally {
        // 7. 拦截器 finally
        if (mappedHandler != null) {
            mappedHandler.triggerAfterCompletion(request, response, dispatchException);
        }
    }
}
```

---

## 四、`HandlerMapping`：URL 怎么映射到方法

### 4.1 实现演进

| 实现 | 时代 | 现状 |
| --- | --- | --- |
| `BeanNameUrlHandlerMapping` | Spring 2.x | 已弃用 |
| `SimpleUrlHandlerMapping` | XML 配置时代 | 已弃用 |
| **`RequestMappingHandlerMapping`** | Spring 3.1+ 注解时代 | **现在用的** |

### 4.2 `@RequestMapping` 处理流程

启动时：
```
ApplicationContext 启动
└─ RequestMappingHandlerMapping.afterPropertiesSet()
   └─ 扫描所有 @Controller / @RestController bean
      └─ 检查每个方法上的 @RequestMapping / @GetMapping / @PostMapping
         └─ 解析 url、method、params、headers、produces、consumes
         └─ 构建 RequestMappingInfo
         └─ 注册到 Map<RequestMappingInfo, HandlerMethod>
```

运行时：
```
请求到来
└─ 取出 URL / Method
└─ 在 Map 里匹配（按 URL 精度、HTTP method、params 等多维度匹配）
└─ 找到 HandlerMethod（Controller 实例 + Method 对象）
└─ 包装成 HandlerExecutionChain（含拦截器）
```

### 4.3 URL 匹配优先级

多个 `@RequestMapping` 都能匹配时，按精度排序：

```
具体路径 > 通配路径
/users/123       优先于    /users/*
/users/*         优先于    /users/**
/users/**        优先于    /**
```

---

## 五、参数解析（HandlerMethodArgumentResolver）

`@Controller` 方法的参数怎么自动从 request 取出来？答案是 `HandlerMethodArgumentResolver` 这个接口。

| 参数注解 / 类型 | 解析器 | 数据来源 |
| --- | --- | --- |
| `@RequestParam` | `RequestParamMethodArgumentResolver` | `request.getParameter()` |
| `@PathVariable` | `PathVariableMethodArgumentResolver` | URL 模板变量 |
| `@RequestBody` | `RequestResponseBodyMethodProcessor` | request body（JSON → 对象） |
| `@RequestHeader` | `RequestHeaderMethodArgumentResolver` | request header |
| `@CookieValue` | `ServletCookieValueMethodArgumentResolver` | cookie |
| `@ModelAttribute` | `ModelAttributeMethodProcessor` | request param + path + body 综合 |
| `HttpServletRequest` | `ServletRequestMethodArgumentResolver` | 直接传 request |
| `Principal` | `PrincipalMethodArgumentResolver` | Spring Security |

### 5.1 自定义参数解析器（生产常用）

需求：所有接口都自动注入当前登录用户。

```java
@Target(PARAMETER)
@Retention(RUNTIME)
public @interface CurrentUser {}

@Component
public class CurrentUserResolver implements HandlerMethodArgumentResolver {
    @Override
    public boolean supportsParameter(MethodParameter parameter) {
        return parameter.hasParameterAnnotation(CurrentUser.class)
            && parameter.getParameterType().equals(User.class);
    }
    
    @Override
    public Object resolveArgument(MethodParameter parameter, ModelAndViewContainer mavContainer,
                                   NativeWebRequest webRequest, WebDataBinderFactory binderFactory) {
        String token = webRequest.getHeader("Authorization");
        return tokenService.parse(token);    // 从 token 解析出 User
    }
}

// 注册
@Configuration
public class WebConfig implements WebMvcConfigurer {
    @Resource private CurrentUserResolver currentUserResolver;
    
    @Override
    public void addArgumentResolvers(List<HandlerMethodArgumentResolver> resolvers) {
        resolvers.add(currentUserResolver);
    }
}

// 使用
@GetMapping("/profile")
public User profile(@CurrentUser User user) { ... }
```

---

## 六、返回值处理（HandlerMethodReturnValueHandler）

### 6.1 `@ResponseBody` / `@RestController` 怎么序列化

`@RestController = @Controller + @ResponseBody`，标了之后所有返回值都被 `RequestResponseBodyMethodProcessor` 处理：

```
返回值
└─ 选择 HttpMessageConverter
   ├─ MappingJackson2HttpMessageConverter  (JSON, 默认)
   ├─ MappingJackson2XmlHttpMessageConverter (XML)
   ├─ ByteArrayHttpMessageConverter         (byte[])
   ├─ StringHttpMessageConverter            (String)
   └─ ...
└─ 按请求头 Accept 决定具体哪个
└─ writeWith() 写入 response body
```

> **追问**：Spring Boot 默认用 Jackson 还是 Gson？**Jackson**——通过 `spring-boot-starter-web` 引入。可以排除 Jackson 依赖换成 Gson 或 Fastjson2。

### 6.2 自定义 ResponseBodyAdvice 包装统一返回格式

需求：所有接口统一包成 `{"code": 0, "data": ...}`：

```java
@RestControllerAdvice
public class ResponseWrapper implements ResponseBodyAdvice<Object> {
    @Override
    public boolean supports(MethodParameter ret, Class<? extends HttpMessageConverter<?>> conv) {
        return true;
    }
    
    @Override
    public Object beforeBodyWrite(Object body, MethodParameter ret, MediaType contentType,
                                   Class<? extends HttpMessageConverter<?>> conv,
                                   ServerHttpRequest req, ServerHttpResponse resp) {
        if (body instanceof ApiResp) return body;     // 已包装，不重复
        return ApiResp.success(body);
    }
}
```

---

## 七、Filter / Interceptor / AOP / `@ControllerAdvice` 怎么选

**这是高频追问**。四者都能"在请求/方法前后做事"，但所处层级、能拿到的信息、能控制的行为完全不同。

```
┌─────────────────────────────────────────────────────┐
│  Servlet Filter         （Servlet 容器层）           │
│   ↓                                                  │
│  DispatcherServlet                                   │
│   ↓                                                  │
│  HandlerInterceptor    （Spring MVC 层）            │
│   ↓                                                  │
│  Controller Method                                   │
│   ↓                                                  │
│  AOP                    （Spring 容器层，可在任何 bean）│
│   ↓                                                  │
│  Service / Dao                                       │
└─────────────────────────────────────────────────────┘
```

| 机制 | 层级 | 能拿到 | 能做什么 | 典型场景 |
| --- | --- | --- | --- | --- |
| **Filter** | Servlet | request / response | 改 request、改 response、过滤所有 URL（含静态资源） | CORS、字符编码、XSS 过滤、压缩 |
| **HandlerInterceptor** | Spring MVC | request、HandlerMethod、ModelAndView | 知道命中了哪个 Controller 方法、可读注解 | 登录校验、权限、日志 |
| **AOP** | Spring 容器 | 方法签名、参数、返回值 | 拦截任何 bean 的方法（不只是 Controller） | 事务、缓存、Service 层日志 |
| **`@ControllerAdvice`** | Spring MVC | 方法返回值 / 异常 | 全局异常处理、返回值包装 | 统一异常响应、参数预处理 |

### 7.1 选型决策

| 需求 | 应该用 |
| --- | --- |
| 全局异常处理 | `@RestControllerAdvice + @ExceptionHandler` |
| 登录认证 | `HandlerInterceptor` 或 Spring Security Filter |
| 字符编码 / CORS | `Filter` |
| 接口耗时统计 | `HandlerInterceptor`（要看 controller 方法名） |
| Service 层耗时统计 | AOP |
| 接口入参出参打印 | AOP（更精确）或 `@RestControllerAdvice` |
| 文件上传大小限制 | `Filter` 或 `MultipartResolver` |
| API 限流 | Filter（早拦截） |

### 7.2 Filter vs Interceptor 顺序

```
Filter1.before
  Filter2.before
    Interceptor1.preHandle
      Interceptor2.preHandle
        Controller
      Interceptor2.postHandle
    Interceptor1.postHandle
    [视图渲染]
    Interceptor2.afterCompletion
    Interceptor1.afterCompletion
  Filter2.after
Filter1.after
```

**Filter 是洋葱皮，Interceptor 也是洋葱皮，但 Interceptor 在内层**。

---

## 八、`@ControllerAdvice` 全局异常处理

```java
@RestControllerAdvice
@Slf4j
public class GlobalExceptionHandler {
    
    @ExceptionHandler(BizException.class)
    public ApiResp<Void> handleBiz(BizException e) {
        return ApiResp.fail(e.getCode(), e.getMessage());
    }
    
    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ApiResp<Void> handleValid(MethodArgumentNotValidException e) {
        String msg = e.getBindingResult().getFieldErrors().stream()
                .map(fe -> fe.getField() + ": " + fe.getDefaultMessage())
                .collect(Collectors.joining("; "));
        return ApiResp.fail(400, msg);
    }
    
    @ExceptionHandler(Exception.class)
    public ApiResp<Void> handleAll(Exception e, HttpServletRequest req) {
        log.error("uri={}", req.getRequestURI(), e);
        return ApiResp.fail(500, "系统繁忙");
    }
}
```

**优先级**：精确匹配的异常先于父类异常。`BizException` 优先于 `Exception`。

---

## 九、生产配置与最佳实践

### 9.1 必备配置

```yaml
spring:
  servlet:
    multipart:
      max-file-size: 10MB           # 单文件大小
      max-request-size: 50MB        # 整个请求大小
  mvc:
    throw-exception-if-no-handler-found: true   # 404 抛异常（让 ControllerAdvice 接到）
  resources:
    add-mappings: false             # 禁用静态资源映射（纯 API 项目）

server:
  tomcat:
    threads:
      max: 200                       # 工作线程数（默认 200，按 QPS 调）
      min-spare: 10
    accept-count: 100                # 等待队列
    max-connections: 8192
    connection-timeout: 5000ms
```

### 9.2 参数校验

```java
// 启用 JSR-303
@Valid + @NotNull/@NotBlank/@Min/@Max/@Pattern...

@PostMapping("/user")
public ApiResp<Void> create(@Valid @RequestBody CreateUserReq req) { ... }

@Data
public class CreateUserReq {
    @NotBlank(message = "用户名不能为空")
    private String name;
    @Email
    private String email;
    @Min(0) @Max(150)
    private int age;
}
```

校验失败抛 `MethodArgumentNotValidException`，由 `@ControllerAdvice` 统一处理。

---

## 十、生产踩坑

### 坑 1：跨域配置错位

前端报 `Access-Control-Allow-Origin` 错误。
**根因**：CORS 配置加在 `WebMvcConfigurer.addCorsMappings`，但 Spring Security 在前面拦截了 OPTIONS 预检请求。
**修法**：CORS 必须在 Filter 链最前（早于 Security），用 `CorsFilter` 注册为高优先级 Filter。

```java
@Bean
public FilterRegistrationBean<CorsFilter> corsFilter() {
    FilterRegistrationBean<CorsFilter> bean = new FilterRegistrationBean<>(new CorsFilter(corsSource));
    bean.setOrder(Ordered.HIGHEST_PRECEDENCE);
    return bean;
}
```

### 坑 2：`@RequestBody` 参数为 null

接口接收 JSON，但 `req` 一直是 null。
**可能根因**：
- ❌ Content-Type 不是 `application/json`（前端漏了）
- ❌ 实体类没默认无参构造（Jackson 反序列化要求）
- ❌ 字段名 / Json 字段不一致且没 `@JsonProperty`
**排查**：开 `logging.level.org.springframework.web=DEBUG` 看请求详情。

### 坑 3：拦截器拿不到 Controller 方法上的注解

```java
public boolean preHandle(HttpServletRequest req, HttpServletResponse resp, Object handler) {
    if (!(handler instanceof HandlerMethod)) return true;   // 静态资源等
    HandlerMethod hm = (HandlerMethod) handler;
    Auditable ann = hm.getMethodAnnotation(Auditable.class); // ✅ 正确取法
    ...
}
```

不判 `instanceof HandlerMethod` 直接强转，404 路径或静态资源时 NPE。

### 坑 4：异步 / `@Async` 导致请求 ThreadLocal 丢失

```java
@RequestMapping("/api")
public ApiResp<?> api() {
    asyncService.run();         // @Async 子线程拿不到 RequestContextHolder
    return ApiResp.success();
}
```

子线程里 `RequestContextHolder.getRequestAttributes()` 返回 null。
**修法**：在 `RequestContextHolder.setRequestAttributes(attrs, true)` 时第二个参数传 true（继承到子线程），或用 `TaskDecorator` 显式传递。

### 坑 5：上传大文件 OOM

`@RequestParam("file") MultipartFile file` 接收 1GB 文件 → JVM 直接 OOM。
**根因**：`MultipartFile` 默认全部加载到内存。
**修法**：① 配置阈值 `spring.servlet.multipart.file-size-threshold=10MB`（超过这个就写磁盘）；② 用流式 API：`HttpServletRequest.getInputStream()` 自己读。

---

## 十一、面试高频追问

**Q1：完整描述一下 Spring MVC 的请求处理流程**
A：① 请求进入 `DispatcherServlet.doDispatch`；② `HandlerMapping` 按 URL 找到 `HandlerExecutionChain`（Handler + Interceptor[]）；③ 选 `HandlerAdapter`；④ 执行 `Interceptor.preHandle`；⑤ `HandlerAdapter.handle` 内部用 `ArgumentResolver` 解析参数 → 反射调 Controller → `ReturnValueHandler` 处理返回值（`@ResponseBody` 走 `HttpMessageConverter` 序列化）；⑥ `Interceptor.postHandle`；⑦ 异常 → `ExceptionResolver`，正常 → `ViewResolver` + `View.render`（REST 接口跳过）；⑧ `Interceptor.afterCompletion`。

**Q2：`HandlerInterceptor` 三个方法什么时候触发？**
A：
- `preHandle`：Controller 调用前。返回 false 中断后续。
- `postHandle`：Controller 调用后、视图渲染**前**。可以改 `ModelAndView`。
- `afterCompletion`：整个请求结束后（无论成功失败），相当于 finally。可以拿到 Exception。

**Q3：`@RequestParam` 和 `@RequestBody` 区别？**
A：`@RequestParam` 从 query string 或表单（`application/x-www-form-urlencoded`）取；`@RequestBody` 从 request body 取（一般是 JSON）。**两者用的解析器不同**——前者 `RequestParamMethodArgumentResolver`，后者 `RequestResponseBodyMethodProcessor`（走 `HttpMessageConverter`）。

**Q4：`@PathVariable` 怎么实现的？**
A：URL 模板（如 `/user/{id}`）在启动时被解析成 `UriTemplate`，`RequestMappingHandlerMapping` 把 `id` 部分用正则提取。运行时 `PathVariableMethodArgumentResolver` 从 `request.getAttribute(URI_TEMPLATE_VARIABLES)` 取值，做类型转换后注入参数。

**Q5：`HttpMessageConverter` 是干什么的？**
A：HTTP body 和 Java 对象的双向转换接口。`@RequestBody` 把 body → 对象（`read`），`@ResponseBody` 把对象 → body（`write`）。Spring Boot 默认装的有 Jackson（JSON）、StringHttpMessageConverter、ByteArrayHttpMessageConverter 等。按 `Content-Type` / `Accept` 头匹配选用。

**Q6：Filter 和 Interceptor 区别？**
A：① 层级：Filter 在 Servlet 容器层，Interceptor 在 Spring MVC 层；② 拦截范围：Filter 拦所有请求（含静态资源），Interceptor 只拦 DispatcherServlet 处理的请求；③ 能力：Interceptor 能拿到 `HandlerMethod`（知道是哪个 Controller 方法），Filter 拿不到；④ 注入：Interceptor 是 Spring bean 能 `@Autowired`，Filter 默认不是（除非用 `@Component` + `FilterRegistrationBean`）。

**Q7：`@ControllerAdvice` 和 `HandlerExceptionResolver` 是什么关系？**
A：`@ExceptionHandler` 注解的方法被 `ExceptionHandlerExceptionResolver`（一种 `HandlerExceptionResolver` 实现）处理。`@ControllerAdvice` 是把 `@ExceptionHandler` 方法集中到一个 bean，让多 Controller 共用——本质上还是走的 `HandlerExceptionResolver` 流水线。

**Q8：DispatcherServlet 是单例还是多例？线程安全吗？**
A：单例（Servlet 规范）。线程安全——它本身不持有可变状态，每个请求来到时所有数据都在 method 局部变量或 request scope。所有持状态的部分（HandlerMapping、HandlerAdapter）都是初始化时构建好不变的。

**Q9：拦截器和 AOP 选哪个？**
A：在 web 层（Controller）做权限/日志/耗时统计 → 拦截器更合适（能拿到 HandlerMethod、能看注解、性能更好）；在 service / dao 层 → 必须 AOP（拦截器看不到这些）。两者都能做的事，**优先 Spring MVC 自带的，其次 AOP**。

**Q10：Spring MVC 有几个 ApplicationContext？**
A：传统 Web（非 Spring Boot）有两个：
- **Root WebApplicationContext**：由 `ContextLoaderListener` 启动，含 Service / Dao / DataSource
- **Servlet WebApplicationContext**：由 `DispatcherServlet` 启动，是 Root 的子上下文，含 Controller / ViewResolver

子能看到父的 bean，反之不行。所以 Service 不能注入 Controller。
**Spring Boot** 只有一个 ApplicationContext——简化了上下文层级。

---

## 十二、答题模板（60 秒）

> Spring MVC 是 **前端控制器（Front Controller）模式** 的实现：所有请求进 `DispatcherServlet`，按 9 大组件流水线处理。
>
> 核心流程：① `HandlerMapping` URL → `HandlerExecutionChain`；② `HandlerAdapter` 适配；③ `Interceptor.preHandle`；④ `ArgumentResolver` 解析参数（`@RequestParam` / `@RequestBody` 等）；⑤ 反射调用 Controller；⑥ `ReturnValueHandler` 处理返回值（`@ResponseBody` 走 `HttpMessageConverter` 序列化为 JSON）；⑦ `Interceptor.postHandle`；⑧ 异常 → `ExceptionResolver`（`@ControllerAdvice` 走这条），正常 → `ViewResolver` + `View.render`；⑨ `Interceptor.afterCompletion`。
>
> 四种"拦截"机制选型：**Filter** 在 Servlet 层（CORS / 编码 / 限流），**Interceptor** 在 MVC 层能拿 HandlerMethod（认证 / 接口日志），**AOP** 在容器层任意 bean（事务 / Service 日志），**`@ControllerAdvice`** 做全局异常和返回值包装。**拿到 HandlerMethod 用 Interceptor，拦 Service 用 AOP，全局异常用 ControllerAdvice，CORS / 编码用 Filter**。
>
> 生产高频坑：① CORS 必须在 Security 之前生效；② `@RequestBody` 接 null 大概率是 Content-Type 错或缺无参构造；③ 拦截器要先判 `instanceof HandlerMethod`；④ `@Async` 子线程拿不到 RequestContextHolder。

---

## 十三、相关文档

- 前置：[IoC容器.md](IoC容器.md) — DispatcherServlet 是怎么从父子容器中拿 bean 的
- 前置：[AOP.md](AOP.md) — 拦截器 vs AOP 选型
- 配套：[SpringBoot启动流程.md](SpringBoot启动流程.md) — DispatcherServlet 何时注册到 Servlet 容器
- 配套：[Spring事务.md](Spring事务.md) — Service 层的 AOP 应用
