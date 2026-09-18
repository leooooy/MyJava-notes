# IoC 容器

> Spring 一切的起点。面试基本必问，但被问到时大多数人只会背"控制反转就是把创建对象交给容器"——这种回答和工作 1 年的同事没区别。
> 本篇要解决：
> ① IoC / DI 到底"反转"了什么，没有 IoC 时代码长什么样
> ② BeanFactory 和 ApplicationContext 的真实区别（不是"功能多少"这种废话）
> ③ `refresh()` 12 步在干嘛、每步对应面试哪个高频追问
> ④ Bean 作用域、循环依赖、`@Autowired` 失败的根因

---

## 一、为什么要有 IoC：没有它的世界

```java
// 没有 IoC 的传统写法
public class OrderService {
    private UserDao userDao = new UserDaoImpl();        // 强耦合
    private PayClient pay   = new PayClient("prod");    // 配置写死在代码里
    private Logger logger   = LoggerFactory.create();   // 创建逻辑散落各处
}
```

**痛点**：
1. **依赖创建** 散落在每个调用点 → 想换实现类要改一片代码
2. **依赖配置**（地址、超时、密钥）写死在 `new` 里 → 测试时无法替换
3. **生命周期** 没人管 → 谁来 `close()`？谁来重连？
4. **依赖关系** 隐藏在代码深处 → 看不出系统的整体结构

IoC 把这四件事抽出来：**对象由容器创建、依赖由容器注入、生命周期由容器管理、配置由容器统一读取**。代码只剩业务逻辑。

> **"反转"的是什么**：原本 *被调方* 是被使用者主动 `new` 出来的，现在变成 *容器* 主动把它送给使用者。控制权从代码内反转到了容器外。

### 1.1 IoC vs DI vs DL

| 名词 | 全称 | 含义 |
| --- | --- | --- |
| **IoC** | Inversion of Control | 思想：控制权交给框架 |
| **DI** | Dependency Injection | 实现方式：框架"注入"依赖 |
| **DL** | Dependency Lookup | 实现方式：代码主动"查找"依赖（如 JNDI） |

Spring 用的是 **DI**。DL 是早期 EJB 的方式，已被淘汰——因为代码还要写 lookup 逻辑，没真正解耦。

---

## 二、BeanFactory vs ApplicationContext

很多人答"ApplicationContext 功能更多"——这是**错的方向**。两者最核心的差异是 **加载时机** 和 **设计定位**。

### 2.1 接口继承关系

```
BeanFactory                              ← 顶层接口，定义最基本的"工厂"语义
   ↑
HierarchicalBeanFactory                  ← 父子容器
   ↑
ListableBeanFactory                      ← 可枚举所有 bean
   ↑
ConfigurableBeanFactory
   ↑
ApplicationContext  +  ResourceLoader / EnvironmentCapable / MessageSource / ApplicationEventPublisher
   ↑
ConfigurableApplicationContext           ← 加上 refresh() / close()
   ↑
AnnotationConfigApplicationContext / ClassPathXmlApplicationContext / 
AnnotationConfigServletWebServerApplicationContext (Spring Boot Web)
```

ApplicationContext **继承** 了 BeanFactory，并组合了 4 个企业能力接口。它本身就是个 BeanFactory，只是站得更高。

### 2.2 关键差异表

| 维度 | BeanFactory | ApplicationContext |
| --- | --- | --- |
| **加载时机** | 懒加载（`getBean()` 时才创建） | 启动时预实例化所有非懒单例 |
| **BeanPostProcessor** | 需要手动调用 `addBeanPostProcessor` | 启动时自动注册并应用 |
| **国际化（MessageSource）** | ❌ | ✅ |
| **事件机制（ApplicationEvent）** | ❌ | ✅ |
| **资源加载（Resource）** | 仅基础 | 完整 ResourceLoader |
| **环境抽象（Environment）** | ❌ | ✅ |
| **典型实现** | `XmlBeanFactory`（已废弃） | `AnnotationConfigApplicationContext` |

### 2.3 为什么 ApplicationContext 要预实例化？

**问题暴露在启动期，而不是请求期**。如果一个 bean 配置错了：
- BeanFactory：第一次访问时报错——可能是凌晨 3 点的定时任务
- ApplicationContext：启动失败——CI/CD 直接拦下

**代价**：启动慢、内存占用高。但生产系统这两点远不如"配置错了能否在发布时立刻发现"重要。

> **追问点**：那如何让某些 bean 仍然懒加载？`@Lazy` 注解或 `<bean lazy-init="true">`。Spring Boot 2.2+ 还支持全局懒加载 `spring.main.lazy-initialization=true`，用于压缩冷启动时间（如 Serverless）。

---

## 三、`refresh()` 12 步：Spring 启动的核心

`AbstractApplicationContext.refresh()` 是整个 Spring 容器的"上帝方法"，所有 ApplicationContext 都最终调它。**这 12 步是 Spring 高级面试的命门**——能讲清每一步在做什么，基本就能拿下 IoC 部分。

### 3.1 全局流程图

```
┌──────────────────────────────────────────────────────────────┐
│ AbstractApplicationContext.refresh()                          │
├──────────────────────────────────────────────────────────────┤
│  1. prepareRefresh()                  环境校验 / 启动时间戳     │
│  2. obtainFreshBeanFactory()          创建 / 加载 BeanFactory  │
│  3. prepareBeanFactory()              BF 标准化（ClassLoader…） │
│  4. postProcessBeanFactory()          子类钩子（Web 容器扩展）  │
│  5. invokeBeanFactoryPostProcessors() 执行 BFPP（解析 @Config） │
│  6. registerBeanPostProcessors()      注册 BPP（不执行）        │
│  7. initMessageSource()               i18n                     │
│  8. initApplicationEventMulticaster() 事件广播器                │
│  9. onRefresh()                       子类钩子（启动 Tomcat）   │
│ 10. registerListeners()               注册监听器                │
│ 11. finishBeanFactoryInitialization() ★ 实例化所有非懒单例     │
│ 12. finishRefresh()                   ContextRefreshedEvent    │
└──────────────────────────────────────────────────────────────┘
```

### 3.2 每一步详解

**Step 1 — `prepareRefresh`**
做启动前置：记录启动时间、设置 `closed=false`、`active=true`、校验必需的环境变量（`requiredProperties`）。生产场景：`@PropertySource` 校验配置缺失就在这步抛错。

**Step 2 — `obtainFreshBeanFactory`**
创建 `DefaultListableBeanFactory`，加载 `BeanDefinition`（XML / 注解扫描 / `@Configuration` 解析）。**注意**：此时 bean 还没创建，只是有了"图纸"。

> **`BeanDefinition` 是什么**：bean 的元数据描述——类名、scope、依赖、init/destroy 方法、是否懒加载、是否抽象。可以理解为"创建 bean 的菜谱"。容器先收集所有菜谱，再统一开火。

**Step 3 — `prepareBeanFactory`**
BeanFactory 标准化配置：
- 设置 ClassLoader、SpEL 表达式解析器
- 注册 `ApplicationContextAwareProcessor`（让 bean 能拿到 ApplicationContext）
- 忽略某些自动装配接口（`BeanFactoryAware` 等不参与 byType 装配）
- 注册环境相关 bean：`environment` / `systemProperties` / `systemEnvironment`

**Step 4 — `postProcessBeanFactory`** 🪝
子类钩子，给 Web 容器之类的扩展用。例如 `AnnotationConfigServletWebServerApplicationContext` 在这里注册 `WebApplicationContextServletContextAwareProcessor`。

**Step 5 — `invokeBeanFactoryPostProcessors`** ⭐
执行所有 `BeanFactoryPostProcessor`（BFPP）。关键的两个子类：
- `ConfigurationClassPostProcessor`：扫描 `@Configuration` / `@Component` / `@Import` / `@Bean`，把扫到的类转成 BeanDefinition 注册到容器
- `PropertySourcesPlaceholderConfigurer`：把 `${...}` 占位符替换成实际值

> **BFPP 在 BPP 之前执行**——前者改"图纸"，后者改"成品"。理解这个顺序就理解了 Spring 的扩展点设计。

**Step 6 — `registerBeanPostProcessors`** ⭐
**只注册不执行** 所有 `BeanPostProcessor`（BPP）。注册顺序按 `PriorityOrdered → Ordered → 普通`。AOP 的 `AnnotationAwareAspectJAutoProxyCreator` 就在这步入场——但还没干活。

**Step 7-10** 配套设施：i18n、事件广播器、子类的 `onRefresh`（**Spring Boot Web 在这步启动 Tomcat！**）、注册 `ApplicationListener`。

**Step 11 — `finishBeanFactoryInitialization`** 🔥（核心）
```java
beanFactory.preInstantiateSingletons();
```
遍历所有 BeanDefinition，对非抽象、单例、非懒加载的 bean 调 `getBean(name)`。`getBean` 内部走的就是经典的 **Bean 生命周期**（参见 [Bean生命周期.md](Bean生命周期.md)）。

最后还会找出所有 `SmartInitializingSingleton`，调它们的 `afterSingletonsInstantiated()` ——所有单例都创建完后的回调。

**Step 12 — `finishRefresh`**
- 清理资源缓存（`clearResourceCaches`）
- 初始化 `LifecycleProcessor` 并调 `onRefresh()`（启动 `SmartLifecycle` 类型的 bean）
- 发布 `ContextRefreshedEvent` —— Spring Boot 启动日志里 "Started Application in X seconds" 的事件源

---

## 四、Bean 作用域

| Scope | 说明 | 典型场景 |
| --- | --- | --- |
| **singleton**（默认） | 容器内唯一 | 99% 的业务 bean、Service、DAO |
| **prototype** | 每次 `getBean` 新建一个 | 有状态 bean（如带用户上下文的工具类） |
| **request** | 每个 HTTP 请求一个 | Web 上下文，请求级数据 |
| **session** | 每个会话一个 | 用户偏好类 |
| **application** | ServletContext 内唯一 | 全应用共享 |
| **websocket** | 每个 WS 连接一个 | 长连接场景 |

> **追问 — singleton 的 prototype 依赖怎么办？**
> 一个 singleton bean 注入了 prototype bean，结果 prototype 也只创建了一次。两个解决方案：
> 1. 实现 `ApplicationContextAware`，每次手动 `getBean()`
> 2. 用 `@Lookup` 让 Spring 用 CGLIB 重写方法（推荐）
> 3. 注入 `Provider<T>` 或 `ObjectFactory<T>`，调 `get()` 时再创建

---

## 五、依赖注入的三种方式

### 5.1 构造器注入（推荐）

```java
@Service
public class OrderService {
    private final UserDao userDao;       // final 强约束
    private final PayClient payClient;
    
    // Spring 4.3+ 单构造器可省略 @Autowired
    public OrderService(UserDao userDao, PayClient payClient) {
        this.userDao = userDao;
        this.payClient = payClient;
    }
}
```

**优点**：
- ✅ `final` 修饰，**对象不可变**（线程安全）
- ✅ **必填依赖在编译期就显式声明**，不能漏
- ✅ **不会出现循环依赖**——出现就启动报错（早暴露）
- ✅ 单元测试不需要 Spring，直接 `new`

### 5.2 Setter 注入

```java
@Service
public class OrderService {
    private UserDao userDao;
    
    @Autowired  // 可省略
    public void setUserDao(UserDao userDao) {
        this.userDao = userDao;
    }
}
```

适合**可选依赖**或需要后期重新注入的场景。可解决循环依赖（依赖三级缓存）。

### 5.3 字段注入（不推荐）

```java
@Service
public class OrderService {
    @Autowired
    private UserDao userDao;       // ❌ 不能 final
}
```

**为什么 IDEA 会黄色警告**：
- ❌ 强依赖 Spring 容器，不能脱离 Spring 测试
- ❌ 可以注入任意数量依赖 → 容易导致单类职责膨胀（5+ 个 `@Autowired` 就是个信号）
- ❌ 不能 final，对象状态可变

> **生产规约**：**永远用构造器注入**。Spring 官方文档、阿里 Java 开发手册、《Spring 实战》都是这个结论。

---

## 六、`@Autowired` vs `@Resource` vs `@Inject`

| 维度 | `@Autowired` | `@Resource` | `@Inject` |
| --- | --- | --- | --- |
| 来源 | Spring | JSR-250（JDK） | JSR-330 |
| 默认装配方式 | **byType** | **byName** | byType |
| 找不到时 | 报错（除非 `required=false`） | 报错 | 报错 |
| 是否支持 `@Qualifier` | ✅ | 自带 `name` 属性 | 配合 `@Named` |

> **byType 找到多个怎么办？** 报 `NoUniqueBeanDefinitionException`。三种解决：
> 1. 加 `@Primary` 标注首选实现
> 2. 用 `@Qualifier("beanName")` 指定
> 3. 字段名 = beanName，Spring 会自动按名匹配

---

## 七、循环依赖（速览，详见专篇）

Spring 用 **三级缓存** 解决 setter / 字段注入的单例循环依赖：

| 缓存层级 | 名称 | 存什么 |
| --- | --- | --- |
| 一级 | `singletonObjects` | 完全初始化好的 bean |
| 二级 | `earlySingletonObjects` | 提前曝光的"半成品"（已实例化未填充属性） |
| 三级 | `singletonFactories` | 生成早期引用的 ObjectFactory（用于 AOP 代理提前生成） |

**不能解决的场景**：
- ❌ 构造器循环依赖（实例都没创建出来，谈何曝光）
- ❌ prototype scope（不缓存）
- ❌ `@Async` 方法循环依赖（代理对象和原始对象不一致）

详见 [循环依赖.md](循环依赖.md)。

---

## 八、生产踩坑

### 坑 1：`@Autowired` 在静态方法 / 字段上无效

```java
@Component
public class Util {
    @Autowired
    private static UserDao userDao;        // ❌ 永远是 null
}
```

**根因**：Spring 注入是基于实例的，静态字段属于类本身，容器无能为力。
**修法**：把工具类改为 Spring 管理的实例 bean，注入 ApplicationContext 后封装一个静态访问器；或用 `@PostConstruct` 在初始化后赋值给静态字段（仍不推荐）。

### 坑 2：`@Component` 扫描不到

```java
// 启动类在 com.foo.app
@SpringBootApplication
public class App { }

// Service 在 com.bar.service       ❌ 不在 @SpringBootApplication 默认扫描包下
@Service
public class UserService { }
```

**根因**：`@SpringBootApplication` 默认只扫描启动类**所在包及其子包**。
**修法**：调整包结构、或在启动类上加 `@ComponentScan(basePackages = {"com.foo", "com.bar"})`。

### 坑 3：内部方法调用 AOP / 事务失效

```java
@Service
public class OrderService {
    public void outer() {
        innerTx();           // ❌ 不走代理，事务失效
    }
    @Transactional
    public void innerTx() { ... }
}
```

**根因**：AOP 通过代理对象拦截，`this.innerTx()` 是直接调用，不经过代理。
**修法**：
- 把内部方法挪到另一个 bean
- 注入自身（`@Resource OrderService self; self.innerTx()`，Spring 4.3+ 支持）
- 用 `AopContext.currentProxy()`（需要开启 `@EnableAspectJAutoProxy(exposeProxy = true)`）

### 坑 4：Bean 重名导致覆盖（Spring Boot 2.1+ 默认禁止）

```
Annotation-specified bean name 'userService' for bean class 
[com.foo.UserService] conflicts with existing, non-compatible bean definition...
```

**根因**：两个不同包下的类同名 + 同 `@Service` 注解。
**修法**：显式指定 beanName `@Service("fooUserService")`；或开 `spring.main.allow-bean-definition-overriding=true`（**不推荐**，掩盖问题）。

### 坑 5：`@Value("${xxx}")` 默认值不生效

```java
@Value("${user.timeout}")           // ❌ 配置缺失直接启动失败
private int timeout;

@Value("${user.timeout:3000}")      // ✅ 默认值 3000
private int timeout;
```

冒号后的内容是默认值。生产配置 95% 应该带默认值，避免环境差异导致启动失败。

---

## 九、面试高频追问

**Q1：BeanFactory 和 FactoryBean 有什么区别？**
A：完全是两个东西。**BeanFactory 是容器**——管理 bean 的工厂；**FactoryBean 是 bean**——是放在容器里、用来生产某种复杂对象的特殊 bean。`getBean("xxx")` 拿到的是 FactoryBean 生产出的对象，`getBean("&xxx")`（前缀 `&`）才能拿到 FactoryBean 自身。MyBatis 的 `MapperFactoryBean`、Spring AOP 的 `ProxyFactoryBean` 都是经典案例。

**Q2：BeanPostProcessor 和 BeanFactoryPostProcessor 区别？**
A：
- **BFPP** 改 BeanDefinition（"图纸"），在 bean 实例化之前执行（refresh 第 5 步）。典型：`ConfigurationClassPostProcessor` 解析 `@Configuration`。
- **BPP** 改 bean 实例（"成品"），在每个 bean 初始化前后执行。典型：AOP 的 `AnnotationAwareAspectJAutoProxyCreator` 在 `postProcessAfterInitialization` 里把目标对象包成代理。

**Q3：单例 bean 是线程安全的吗？**
A：**Spring 不保证**。Spring 只保证容器内只有一个实例，不管线程安全。如果 bean 是无状态的（典型的 Service / DAO），天然安全；有状态的（持有可变成员变量）需要自己加锁或改用 ThreadLocal、`prototype` scope。

**Q4：构造器注入怎么处理可选依赖？**
A：
1. 单构造器无法处理可选——必填依赖才放构造器
2. 可选依赖用 setter / 字段注入 + `@Autowired(required = false)`
3. 或者注入 `Optional<T>`、`Provider<T>`

**Q5：`@Lazy` 在哪些地方有用？**
A：
1. 启动加速（仅在用到时创建）
2. 解决构造器循环依赖（被 `@Lazy` 标注的依赖会注入代理对象，真正用到时才解析）
3. 配合 `@Conditional` 实现按需加载

**Q6：refresh() 是幂等的吗？能调多次吗？**
A：默认情况下 **不能**。`AbstractApplicationContext` 用 `synchronized(startupShutdownMonitor)` 保护，调用前会先调 `cancelRefresh()` 清理，但完整重新 refresh 在 Web 容器下会出问题（Servlet 容器已绑定）。Spring Cloud 的 `@RefreshScope` 是另一个机制——它只是把 `@RefreshScope` 标注的 bean 销毁重建，不动整个容器。

**Q7：循环依赖能否用二级缓存解决？为什么必须三级？**
A：能 *不能 AOP* 时只用二级足够。三级缓存的作用是**延迟生成代理对象**——`singletonFactories.get(name).getObject()` 这一步才决定是否要包代理。若没循环依赖，AOP 在 `postProcessAfterInitialization`（生命周期最后一步）做代理；只有出现循环依赖时，才被迫提前到曝光时做。**三级缓存让"普通情况下代理在最后做"和"循环依赖时代理提前做"统一了。**

**Q8：Spring 的 BeanDefinition 是什么时候合并（merge）的？为什么要合并？**
A：bean 支持继承（`parent` 属性），子 BeanDefinition 可以只覆盖部分属性。`getMergedLocalBeanDefinition()` 会把父子 BD 合并成一个 `RootBeanDefinition` 用于实际创建。合并后的结果会缓存，避免重复合并。这也是 `MergedBeanDefinitionPostProcessor` 出现的原因——给 BPP 一个改"合并后图纸"的机会（典型：`AutowiredAnnotationBeanPostProcessor` 在这步扫描 `@Autowired` 字段）。

---

## 十、答题模板（60 秒）

> **IoC 是把对象的创建、依赖装配、生命周期管理从业务代码反转到容器**，业务代码只声明依赖，容器负责满足。Spring 的核心实现是 **DI（依赖注入）**，三种方式里 **构造器注入是工业标准**——不可变、必填显式、不能循环依赖、易测试。
>
> 容器分两层：**BeanFactory** 是顶层接口，懒加载；**ApplicationContext** 站在 BeanFactory 之上，加上 **预实例化、事件、i18n、资源、Environment**——生产用的都是 ApplicationContext。
>
> Spring 启动的核心是 `AbstractApplicationContext.refresh()` **12 步**，关键节点：第 5 步执行 **BeanFactoryPostProcessor**（解析 `@Configuration`）、第 6 步注册 **BeanPostProcessor**（AOP 代理在这入场）、第 11 步 **`finishBeanFactoryInitialization` 实例化所有非懒单例**——这步走的就是经典 Bean 生命周期。
>
> 高频踩坑：**内部方法调用 AOP 失效（this 不走代理）、`@Autowired` 不能注入静态字段、单例的 prototype 依赖只创建一次（用 `@Lookup` 解）、循环依赖三级缓存解决 setter 但解不了构造器**。

---

## 十一、相关文档

- 进阶：[Bean生命周期.md](Bean生命周期.md) — `getBean` 内部 8 阶段
- 进阶：[循环依赖.md](循环依赖.md) — 三级缓存原理
- 进阶：[AOP.md](AOP.md) — 代理在生命周期哪一步织入
- 进阶：[SpringBoot启动流程.md](SpringBoot启动流程.md) — `SpringApplication.run()` 如何调到 `refresh()`
- 配套：[设计模式.md](设计模式.md) — IoC 用的工厂、模板方法、观察者模式
