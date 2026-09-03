# AOP

> 大厂面试 Spring 三连之三。
> 这道题的"段位差"在三个地方：
> ① 能不能讲清 **JDK 动态代理 vs CGLIB** 的本质差异和性能拐点
> ② 能不能讲清 AOP 织入发生在 Bean 生命周期的 **哪一步**、为什么
> ③ 能不能讲清 **`this` 调用 AOP 失效** 的根因和 4 种修法
> 答得出这三个，基本就稳了。

---

## 一、为什么要 AOP

业务代码里散落着大量"非业务但又必须做"的横切关注点（cross-cutting concerns）：

- **日志**：每个接口入参出参打日志
- **事务**：每个写操作开事务、commit、rollback
- **权限**：每个接口校验登录态
- **性能监控**：每个慢操作打 metric
- **缓存**：每个查询查缓存、写缓存

**没 AOP 时**：

```java
public Order createOrder(Long userId) {
    log.info("createOrder begin: userId={}", userId);
    long start = System.currentTimeMillis();
    Transaction tx = txManager.begin();
    try {
        if (!securityCtx.isAuthed()) throw new AuthException();
        Order order = ...;            // 真正的业务（10 行里只有这 2 行有意义）
        tx.commit();
        return order;
    } catch (Exception e) {
        tx.rollback();
        throw e;
    } finally {
        long cost = System.currentTimeMillis() - start;
        metric.record("createOrder", cost);
        log.info("createOrder end: cost={}ms", cost);
    }
}
```

业务和非业务比例 1:5。AOP 就是把那 5 抽出去：

```java
@Transactional
@Auditable
public Order createOrder(Long userId) {
    return ...;          // 只剩业务
}
```

> **核心思想**：把"做什么"（业务）和"什么时候顺带做什么"（横切关注点）解耦——OOP 解决纵向继承复用，AOP 解决横向行为复用。

---

## 二、核心术语

```
┌──────────────────── 切面 Aspect ────────────────────┐
│                                                      │
│   切入点 Pointcut + 通知 Advice = 切面 Aspect         │
│                                                      │
│   "在西站这个【地点】，8 点【时机】下车【动作】"      │
│      └─切入点─┘    └─时机─┘   └─通知─┘            │
└──────────────────────────────────────────────────────┘
```

| 术语 | 中文 | 含义 | 代码长什么样 |
| --- | --- | --- | --- |
| **JoinPoint** | 连接点 | 程序执行中能插入切面的"点"——方法调用、字段访问、异常抛出。Spring AOP 只支持 **方法级** 连接点 | 任意方法 |
| **Pointcut** | 切入点 | 在哪些 JoinPoint 上织入（"地点"） | `@Pointcut("execution(* com.foo.service..*.*(..))")` |
| **Advice** | 通知 | 织入什么逻辑（"动作"），含执行时机 | `@Before` / `@After` / `@Around` |
| **Aspect** | 切面 | Pointcut + Advice 的组合 | `@Aspect` 标注的类 |
| **Target** | 目标对象 | 被代理的原始对象 | 你写的 Service |
| **Proxy** | 代理对象 | 包了一层增强逻辑的对象，注入到调用方 | Spring 自动生成 |
| **Weaving** | 织入 | 把切面应用到目标对象、生成代理的过程 | Spring 在 BPP 里做 |

### 2.1 五种通知（Advice）

| 注解 | 时机 | 典型场景 |
| --- | --- | --- |
| `@Before` | 目标方法 **执行前** | 入参打印、权限校验 |
| `@AfterReturning` | 目标方法 **正常返回后** | 出参打印、缓存写入 |
| `@AfterThrowing` | 目标方法 **抛异常后** | 异常告警 |
| `@After` | 目标方法 **结束后**（无论正常/异常，类似 finally） | 释放资源 |
| `@Around` | **包围**目标方法（最强大） | 事务、性能监控、缓存 |

> **`@Around` 为什么最强**：可以在调用前后任意点切入，可以决定是否调用目标方法（`pjp.proceed()`），可以修改入参出参，可以吞异常。日志、事务、缓存都用它。

---

## 三、Spring AOP 实现原理：动态代理

### 3.1 两种代理对比

```
                 JDK 动态代理              CGLIB 代理
                 ─────────────────         ─────────────────
适用对象         实现了接口的类             所有类（含未实现接口）
代理生成方式     反射，运行时在内存生成     字节码工具（ASM）生成子类
代理对象类型     接口的实现类               目标类的子类
final 类         不能代理                  不能代理（没法继承）
final 方法       会代理但不增强            不能增强（继承不了）
private 方法     不能代理                  不能代理（继承不到）
性能（创建）     稍快                      慢（生成字节码）
性能（调用）     反射 invoke 慢            直接方法调用快（JIT 后接近原生）
依赖             JDK 内置                  需要 cglib jar
```

### 3.2 何时用哪种？

| 场景 | Spring 选择 |
| --- | --- |
| 目标类**实现了接口** | JDK 动态代理（默认） |
| 目标类 **没实现接口** | CGLIB |
| `@EnableAspectJAutoProxy(proxyTargetClass = true)` | 强制 CGLIB |
| Spring Boot 2.0+ | **默认 CGLIB**（即使有接口） |

> **Spring Boot 为什么默认改 CGLIB**：避免开发者忘记把方法声明为接口方法导致 AOP 失效。CGLIB 的副作用（不能代理 final 方法）远比"找不到接口报错"友好。

### 3.3 JDK 动态代理底层

```java
// JDK 提供的 API
Object proxy = Proxy.newProxyInstance(
    classLoader,
    new Class[]{TargetInterface.class},
    new InvocationHandler() {
        @Override
        public Object invoke(Object proxy, Method method, Object[] args) {
            // 前置增强
            Object result = method.invoke(target, args);  // 反射调用
            // 后置增强
            return result;
        }
    }
);
```

**生成的代理类**（运行时在内存里）：

```java
public final class $Proxy0 extends Proxy implements TargetInterface {
    public Object foo(int x) {
        return super.h.invoke(this, m_foo, new Object[]{x});  // 走 InvocationHandler
    }
}
```

**为什么要求实现接口**：JDK 代理通过 `extends Proxy implements XxxInterface` 来让代理对象"看起来像"原对象——多态依赖接口。

### 3.4 CGLIB 底层

```java
Enhancer enhancer = new Enhancer();
enhancer.setSuperclass(TargetClass.class);
enhancer.setCallback(new MethodInterceptor() {
    @Override
    public Object intercept(Object obj, Method method, Object[] args, MethodProxy proxy) {
        // 前置增强
        Object result = proxy.invokeSuper(obj, args);  // FastClass 直接调用，比反射快
        // 后置增强
        return result;
    }
});
Object proxy = enhancer.create();
```

CGLIB 通过 ASM 生成目标类的**子类**，重写所有非 final 方法，调用前先经过 `MethodInterceptor`。

> **MethodProxy.invokeSuper 比反射快**：CGLIB 用 FastClass 机制——为目标类和代理类各生成一个 `FastClass`，每个方法分配一个 index，通过 switch 直接调用，避免了反射的开销。

### 3.5 性能对比（参考数字）

| 操作 | 直接调用 | JDK 代理 | CGLIB 代理 |
| --- | --- | --- | --- |
| 创建 1 万次 | 1ms | 30ms | 300ms |
| 调用 1 亿次 | 100ms | 1500ms（反射） | 200ms（FastClass） |

**结论**：高频调用场景 CGLIB 完胜。Spring 选 CGLIB 默认，不只是为了避免接口要求，性能也更优。

---

## 四、AOP 在 Bean 生命周期的哪一步织入？

### 4.1 正常情况：`postProcessAfterInitialization`

```java
// AbstractAutoProxyCreator (extends BeanPostProcessor)
public Object postProcessAfterInitialization(Object bean, String beanName) {
    Object cacheKey = getCacheKey(bean.getClass(), beanName);
    if (this.earlyProxyReferences.remove(cacheKey) != bean) {
        return wrapIfNecessary(bean, beanName, cacheKey);   // 创建代理
    }
    return bean;
}
```

`wrapIfNecessary` 内部决策：

```java
protected Object wrapIfNecessary(Object bean, String beanName, Object cacheKey) {
    // 1. 收集 advisor（与该 bean 匹配的 @Aspect 切面）
    Object[] specificInterceptors = getAdvicesAndAdvisorsForBean(bean.getClass(), beanName, null);
    
    if (specificInterceptors != DO_NOT_PROXY) {
        // 2. 创建代理（JDK 或 CGLIB）
        Object proxy = createProxy(bean.getClass(), beanName, specificInterceptors, new SingletonTargetSource(bean));
        return proxy;
    }
    return bean;
}
```

### 4.2 循环依赖场景：`getEarlyBeanReference` 提前织入

```java
// AbstractAutoProxyCreator 实现 SmartInstantiationAwareBPP
public Object getEarlyBeanReference(Object bean, String beanName) {
    Object cacheKey = getCacheKey(bean.getClass(), beanName);
    this.earlyProxyReferences.put(cacheKey, bean);   // 标记"已提前代理"
    return wrapIfNecessary(bean, beanName, cacheKey);
}
```

后续 `postProcessAfterInitialization` 检查 `earlyProxyReferences`，如果已存在就跳过，避免重复代理。

> **设计精髓**：AOP 默认在最后一步织入（保证 init-method 等都作用在原始对象）；只有循环依赖时被迫提前——这是 Spring 三级缓存设计的真正动机。详见 [循环依赖.md](循环依赖.md)。

---

## 五、`this` 调用 AOP 失效（高频送命题）

### 5.1 现象

```java
@Service
public class OrderService {
    
    @Transactional
    public void createOrder() {
        // ... 写库
        sendMq();              // ❌ 期望也走 @Transactional 但失效
    }
    
    @Transactional(propagation = REQUIRES_NEW)
    public void sendMq() {
        // ... 写另一个库
    }
}
```

`createOrder` 抛异常时，`sendMq` 不应回滚（`REQUIRES_NEW` 独立事务）——但实际上整个全部回滚了。

### 5.2 根因

Spring 注入的是**代理对象**，但 `this.sendMq()` 是 **原始对象自己调自己**——直接走方法调用，不经过代理。

```
调用方
  ↓
[OrderService 代理对象]   ← 这一层有 @Transactional 拦截
  ↓ proxy.createOrder()
[OrderService 原始对象]   ← this 指向这里
  ↓ this.sendMq()         ← ❌ 这里直接跳过代理
[OrderService.sendMq()]   ← @Transactional 完全没生效
```

### 5.3 4 种修法

**方法 1：拆到另一个 bean**（推荐）

```java
@Service
public class OrderService {
    @Autowired private MqService mqService;
    
    @Transactional
    public void createOrder() {
        mqService.sendMq();    // 跨 bean 调用，走代理
    }
}
```

**方法 2：注入自身**（Spring 4.3+ 支持）

```java
@Service
public class OrderService {
    @Resource private OrderService self;       // ✅ 注入的是代理对象
    
    @Transactional
    public void createOrder() {
        self.sendMq();
    }
}
```

> **追问**：注入自己不会循环依赖吗？Spring 4.3+ 对自注入做了特殊处理，单例场景三级缓存能正常解决。

**方法 3：通过 `AopContext.currentProxy()`**

```java
// 启动类加：@EnableAspectJAutoProxy(exposeProxy = true)

public void createOrder() {
    ((OrderService) AopContext.currentProxy()).sendMq();
}
```

把当前代理放 ThreadLocal，业务里取出来调。**侵入业务代码，不优雅，少用**。

**方法 4：`@Async` 场景下显式 `ApplicationContext.getBean`**

直接从容器拿，等价于方法 2，但更"原始"。

---

## 六、`@AspectJ` 写一个完整的切面

```java
@Aspect
@Component
@Order(1)                                      // 多切面时控制顺序
@Slf4j
public class OperationLogAspect {
    
    /** 切入点：所有标了 @Auditable 的方法 */
    @Pointcut("@annotation(com.foo.annotation.Auditable)")
    public void auditable() {}
    
    @Around("auditable()")
    public Object around(ProceedingJoinPoint pjp) throws Throwable {
        long start = System.currentTimeMillis();
        MethodSignature sig = (MethodSignature) pjp.getSignature();
        Method method = sig.getMethod();
        Auditable ann = method.getAnnotation(Auditable.class);
        
        try {
            Object result = pjp.proceed();             // 调用目标方法
            long cost = System.currentTimeMillis() - start;
            log.info("op={}, cost={}ms, args={}", ann.value(), cost, pjp.getArgs());
            return result;
        } catch (Throwable t) {
            log.error("op={} FAILED", ann.value(), t);
            throw t;
        }
    }
}
```

### 6.1 切入点表达式

| 表达式 | 含义 |
| --- | --- |
| `execution(* com.foo.service..*.*(..))` | service 包及子包所有方法 |
| `within(com.foo.service..*)` | service 包及子包所有类的所有方法 |
| `@annotation(com.foo.Auditable)` | 标了 `@Auditable` 注解的方法 |
| `@within(org.springframework.stereotype.Service)` | 类上标了 `@Service` 的所有方法 |
| `bean(orderService)` | 名为 orderService 的 bean 的所有方法 |
| `args(java.lang.String, ..)` | 第一个参数是 String 的方法 |

`execution` 语法：`execution(修饰符 返回类型 包名.类名.方法名(参数))`，每段都可以用 `*` 通配。

### 6.2 多切面执行顺序

```
@Around(切面 A) {
    @Around(切面 B) {
        @Before(切面 C) → 目标方法 → @After(切面 C)
    }
}
```

`@Order` 数字小的在外层。同一个切面内，`@Around` 包住其他通知。

---

## 七、生产配置 & 取舍

### 7.1 强制 CGLIB

```yaml
spring:
  aop:
    proxy-target-class: true   # Spring Boot 2.0+ 默认就是 true
```

### 7.2 暴露代理（解决 `this` 失效的折中方案）

```java
@SpringBootApplication
@EnableAspectJAutoProxy(exposeProxy = true)
public class App { }
```

代价：每次代理调用要把代理放 ThreadLocal，**有性能损失**（虽然小）。能拆 bean 就拆 bean，别用这个。

### 7.3 关闭 AOP（极少场景）

```yaml
spring:
  aop:
    auto: false
```

只有极简的工具应用 / Job 才考虑——99% 的业务系统都需要事务，关闭 AOP = 关闭事务。

---

## 八、生产踩坑

### 坑 1：`this` 调用 AOP 失效（前面详述）

90% 的事务失效都是这个根因。

### 坑 2：`@Transactional` 标在 private 方法上

```java
@Service
public class OrderService {
    public void outer() { inner(); }
    
    @Transactional
    private void inner() { ... }       // ❌ AOP 没法增强 private
}
```

JDK 代理只代理接口方法（接口方法本就 public）；CGLIB 代理是子类，**子类访问不到 private**。
**修法**：改 public，或拆到独立 bean。

### 坑 3：`@Transactional` 标在 final 方法上（CGLIB 场景）

CGLIB 通过子类重写实现，final 方法无法重写——AOP 失效。**编译期不报错，运行时悄悄失效**。
**修法**：去掉 final，或改用 JDK 代理（要求接口）。

### 坑 4：异步线程里 AOP 上下文丢失

```java
@Transactional
public void createOrder() {
    new Thread(() -> sendMq()).start();   // ❌ 子线程看不到事务上下文
}
```

事务通过 `ThreadLocal` 绑定，子线程拿不到。`@Async` 同理。
**修法**：用 `TransactionTemplate.execute(...)` 显式开启事务，或在子线程里独立开事务。

### 坑 5：切入点表达式写错，悄悄不生效

```java
@Pointcut("execution(* com.foo.UserService.*(..))")    // ❌ 没匹配子包
```

切入点只是字符串匹配，写错了启动不报错，**只是没切到任何方法**。
**修法**：每写一个切面立即写测试验证；用 `execution(* com.foo.service..*.*(..))` 时记得 `..` 表示包及子包，`.` 表示当前包。

### 坑 6：JDK 代理强转目标类失败

```java
@Autowired
private OrderServiceImpl orderService;     // ❌ JDK 代理的是接口，不能强转实现类
```

JDK 代理对象是接口实现，不是 `OrderServiceImpl`。
**修法**：注入接口类型，或开 `@EnableAspectJAutoProxy(proxyTargetClass = true)` 改用 CGLIB。

---

## 九、面试高频追问

**Q1：AOP 实现的两种代理是什么？什么时候用哪种？**
A：JDK 动态代理（基于接口，`Proxy.newProxyInstance`）和 CGLIB（基于继承，ASM 生成子类）。Spring 默认：有接口用 JDK，没接口用 CGLIB；Spring Boot 2.0+ 默认全部 CGLIB。CGLIB 不能代理 final 类 / final 方法 / private 方法。

**Q2：JDK 代理为什么必须实现接口？**
A：JDK 代理生成的代理类是 `extends Proxy implements XxxInterface`——通过实现相同接口来让代理对象在多态时能替换原对象。没接口就没多态依赖，JDK 代理没法工作。

**Q3：CGLIB 能代理任何类吗？**
A：不能。① final 类（没法继承）；② final 方法（重写不了）；③ private 方法（子类访问不到）。

**Q4：AOP 织入发生在 Bean 生命周期哪一步？**
A：`BeanPostProcessor.postProcessAfterInitialization`——bean 完全初始化后被包成代理。如果发生循环依赖，会被迫提前到 `getEarlyBeanReference`（三级缓存触发时）。

**Q5：`@Transactional` 失效的常见场景？**
A：① 同类内 `this` 调用；② 标在 private / final 方法；③ 异常被 catch 没抛出；④ 抛的是 checked 异常但没声明 `rollbackFor`；⑤ 标在 `@Async` 方法上又跨线程调；⑥ bean 没被 Spring 管理。

**Q6：CGLIB 性能为什么比 JDK 反射好？**
A：JDK 代理通过 `Method.invoke` 反射调用，反射本身有较大开销（虽然 JDK 8+ 优化了不少）。CGLIB 用 FastClass 机制——为目标方法生成 index，通过 switch 直接调用字节码，避免反射，**热路径上接近原生方法调用**。

**Q7：能否用 AOP 拦截 controller 层？**
A：能，但更推荐用 Spring MVC 自带的 `HandlerInterceptor`、`@ControllerAdvice` + `@ExceptionHandler`、Filter——这些是为 web 场景设计的，能拿到 `HttpServletRequest`，比 AOP 更自然。AOP 适合拦截 service 层。

**Q8：`@Around` 和 `@Before + @AfterReturning` 有什么区别？**
A：`@Around` 是 **包围式**——能决定是否调用目标方法（`pjp.proceed()`）、修改入参出参、吞异常。`@Before` 只能在前面执行，没法影响目标方法的调用。能用 `@Around` 实现的，单独用其他通知都做不到。

**Q9：Spring AOP 和 AspectJ 是什么关系？**
A：
- **Spring AOP** 用 Spring 自己的 ProxyFactory，运行时代理，**只支持方法级**，性能稍慢，但不需要额外编译期工具。
- **AspectJ** 是独立的 AOP 框架，有完整的 AOP 实现：编译期织入（`ajc` 编译器）、加载期织入（LTW），支持字段级、构造器级。**Spring AOP 借用了 AspectJ 的注解和切入点表达式语法**——但织入实现是 Spring 自己的代理。
- 业务系统几乎全用 Spring AOP；中间件 / 性能极致场景才用 AspectJ。

**Q10：自调用 / final / private 都不能 AOP，怎么解？**
A：
- 自调用：拆 bean / 自注入 / `AopContext.currentProxy()`
- final 方法：去掉 final，或改 JDK 代理
- private 方法：改 public 或拆到独立 bean
- 终极方案：用 AspectJ 编译期织入——直接修改字节码，没有代理对象，任何方法都能拦。

---

## 十、答题模板（60 秒）

> AOP 解决的是横切关注点（事务、日志、权限、监控、缓存）和业务代码耦合的问题。Spring 用 **动态代理** 实现 AOP——目标类 **有接口用 JDK 代理**（`Proxy.newProxyInstance`，反射调用），**没接口用 CGLIB**（ASM 生成子类，FastClass 直接调用）。Spring Boot 2.0+ **默认 CGLIB**，避免开发者忘记接口导致 AOP 失效。
>
> 织入发生在 **Bean 生命周期初始化的最后一步**（`BeanPostProcessor.postProcessAfterInitialization`），由 `AbstractAutoProxyCreator` 收集 advisor 并生成代理。**循环依赖时会被迫提前**——这是三级缓存设计的真正动机。
>
> 五种通知中 `@Around` 最强，能控制目标方法是否执行、修改入参出参、吞异常——事务、缓存、监控都用它。
>
> **失效场景** 是面试和生产高频坑：① `this` 自调用（不走代理）；② private / final 方法（CGLIB 重写不了）；③ 异常被吃掉；④ checked 异常没声明 `rollbackFor`；⑤ 跨线程调用（事务 ThreadLocal 丢失）。**修法首选拆 bean，其次自注入或 `AopContext.currentProxy()`**。

---

## 十一、相关文档

- 前置：[Bean生命周期.md](Bean生命周期.md) — `postProcessAfterInitialization` 的位置
- 配套：[循环依赖.md](循环依赖.md) — `getEarlyBeanReference` 提前代理
- 配套：[Spring事务.md](Spring事务.md) — 事务是 AOP 最经典的应用
- 配套：[设计模式.md](设计模式.md) — 代理模式
