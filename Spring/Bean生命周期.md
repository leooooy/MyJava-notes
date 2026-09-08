# Bean 生命周期

> 大厂面试 Spring 核心三连之一（生命周期 / 循环依赖 / AOP）。
> 这道题的"段位差"特别明显——初级答得出"实例化、属性注入、初始化、销毁"4 步，中级能补 Aware、`BeanPostProcessor`、`InitializingBean`，**资深要能讲清每个扩展点是干嘛的、Spring 自己怎么用、生产怎么踩坑**。
> 本篇按这个段位线展开。

---

## 一、为什么要管 Bean 的"生命周期"

如果一个对象只是 `new` 出来用一下，不存在"生命周期"。Spring 给 bean 加了一整套生命周期，是因为：

1. **依赖装配**——bean A 需要 bean B，B 必须先创建
2. **AOP 织入**——业务对象需要被代理（事务、日志、缓存）
3. **资源管理**——bean 持有的连接、线程池、文件句柄需要在容器关闭时释放
4. **扩展点**——给框架（Spring 自身、Spring Boot、MyBatis 等）和业务一个干预 bean 创建过程的机会

整个生命周期围绕一句话：**"创建出对象，把它装配好，让所有人有机会修改它，最后干净地销毁。"**

---

## 二、全景流程图

```
┌──────────────── BeanDefinition 阶段（refresh 第 5 步前完成）────────────────┐
│  扫描 / 解析 → BeanDefinition → 合并父子 BD → 缓存到 beanDefinitionMap        │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                    │
                  getBean(name) →   │
                                    ▼
┌─────────────── 单例三级缓存检查（解决循环依赖）─────────────────────────────┐
│  singletonObjects → earlySingletonObjects → singletonFactories               │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                    │ 没有 → 走创建流程
                                    ▼
┌──────────────────────────── 1. 实例化前 ────────────────────────────────────┐
│  InstantiationAwareBeanPostProcessor.postProcessBeforeInstantiation()       │
│  ▶ 返回非 null 直接跳过后续，作为最终 bean（罕用，AOP 强制场景才走）         │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
┌──────────────────────────── 2. 实例化（createBeanInstance）─────────────────┐
│  推断构造器：Supplier > FactoryMethod > 有参 @Autowired 构造器 > 默认无参    │
│  ▶ 此时 bean 是个"空壳"，只有 new 出来的对象，属性全是 null                  │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
┌──────────────────────────── 3. MergedBeanDefinitionPostProcessor ───────────┐
│  扫描注解（@Autowired / @Resource / @Value），缓存注入元信息                │
│  典型实现：AutowiredAnnotationBeanPostProcessor                              │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
┌──────────────────── 4. 提前曝光：addSingletonFactory（三级缓存）─────────────┐
│  把 ObjectFactory 放入 singletonFactories                                    │
│  ▶ 用于解决循环依赖，AOP 代理也在这一步按需触发                              │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
┌──────────────────────────── 5. 属性注入（populateBean）─────────────────────┐
│  ① InstantiationAwareBPP.postProcessAfterInstantiation()  → false 跳过注入  │
│  ② autowireByName / autowireByType                                          │
│  ③ InstantiationAwareBPP.postProcessProperties()  ← @Autowired 字段在此注入 │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
┌──────────────────────────── 6. 初始化（initializeBean）─────────────────────┐
│  ① invokeAwareMethods           ← BeanNameAware / BeanFactoryAware           │
│  ② BPP.postProcessBeforeInitialization                                       │
│     · ApplicationContextAwareProcessor 注入 ApplicationContext               │
│     · CommonAnnotationBPP 调用 @PostConstruct                                │
│  ③ invokeInitMethods                                                         │
│     · InitializingBean.afterPropertiesSet()                                  │
│     · 自定义 init-method                                                     │
│  ④ BPP.postProcessAfterInitialization  ← AOP 代理在此创建（绝大多数情况）   │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
┌──────────────────────────── 7. 注册销毁回调 ─────────────────────────────────┐
│  registerDisposableBeanIfNecessary                                           │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
┌──────────────────────────── 8. 加入一级缓存，bean 可用 ──────────────────────┐
│  singletonObjects.put(name, bean)                                            │
│  earlySingletonObjects / singletonFactories 移除                             │
└──────────────────────────────────────────────────────────────────────────────┘

────────────── 容器关闭时（ApplicationContext.close）──────────────
  ① DestructionAwareBPP.postProcessBeforeDestruction  ← @PreDestroy
  ② DisposableBean.destroy()
  ③ 自定义 destroy-method
```

---

## 三、关键阶段详解

### 3.1 实例化（`createBeanInstance`）

Spring 创建对象的优先级：

```
Supplier (BeanDefinition.setInstanceSupplier) 
   ↓ 没有
factoryMethod / @Bean 方法
   ↓ 没有
推断构造器：
   - 唯一构造器（不管是否标 @Autowired）→ 用它
   - 有 @Autowired(required=true) 的构造器 → 用它
   - 默认无参构造器 → 用它（绝大多数业务 bean 走这条）
```

**追问 — 为什么要推断构造器**：因为可能有多个构造器，且要在不知道参数能否被注入时做选择。Spring 4.3+ 单构造器场景可省略 `@Autowired`，就是推断逻辑做的。

### 3.2 属性注入（`populateBean`）

**注意**：`@Autowired`、`@Resource`、`@Value` 注解的字段注入 **不走** `autowireByName/byType`，而是走 `InstantiationAwareBeanPostProcessor.postProcessProperties()`，由 `AutowiredAnnotationBeanPostProcessor` 和 `CommonAnnotationBeanPostProcessor` 实现。

`autowireByName/byType` 只在 XML 配置 `<bean autowire="byType">` 或 `@Bean` 设置 `autowire` 属性时才走——现在的注解项目几乎用不到。

### 3.3 Aware 接口回调

按以下顺序回调：

| 接口 | 回调时机 | 拿到什么 |
| --- | --- | --- |
| `BeanNameAware` | 初始化前（直接调用） | 当前 bean 的 name |
| `BeanClassLoaderAware` | 初始化前 | ClassLoader |
| `BeanFactoryAware` | 初始化前 | BeanFactory |
| `ApplicationContextAware` | `BeanPostProcessor` 阶段 | ApplicationContext |
| `EnvironmentAware` | BPP 阶段 | Environment |

> 前 3 个是 `invokeAwareMethods` 直接调，后面那批是 `ApplicationContextAwareProcessor` 这个 BPP 在 `postProcessBeforeInitialization` 里调。**这个差异很容易考**——为什么要区分？因为 `BeanFactory` 是 BeanFactory 自己就有的，但 ApplicationContext 是上层概念，BeanFactory 看不到，所以必须靠 BPP 注入。

### 3.4 初始化方法的 4 种写法

| 方式 | 触发时机 | 推荐度 |
| --- | --- | --- |
| `@PostConstruct` | `CommonAnnotationBPP` 在 `postProcessBeforeInitialization` 里调 | ⭐⭐⭐⭐⭐（推荐） |
| `InitializingBean.afterPropertiesSet()` | `invokeInitMethods` 第一步 | ⭐⭐（耦合 Spring API） |
| XML `init-method` / `@Bean(initMethod=)` | `invokeInitMethods` 第二步 | ⭐⭐⭐ |
| `BeanPostProcessor.postProcessAfterInitialization` | 注入式扩展 | ⭐⭐⭐⭐（写 Starter 用） |

**调用顺序**：`@PostConstruct` → `afterPropertiesSet()` → `init-method`。`@PostConstruct` 来自 JSR-250，不绑 Spring，迁移成本最低。

### 3.5 销毁方法的 3 种写法

| 方式 | 推荐度 |
| --- | --- |
| `@PreDestroy` | ⭐⭐⭐⭐⭐ |
| `DisposableBean.destroy()` | ⭐⭐ |
| `@Bean(destroyMethod=)` / `destroy-method` | ⭐⭐⭐ |

**注意**：`prototype` scope 的 bean **不会** 触发销毁回调——容器不缓存，自然也无从销毁。需要业务自己 `close`。

---

## 四、`BeanPostProcessor` 全家桶

`BeanPostProcessor` 是 Spring 最重要的扩展点。生命周期里几乎每个关键节点都有一个 BPP 子接口介入：

```
BeanPostProcessor                          (基础：初始化前后)
├── InstantiationAwareBeanPostProcessor    (实例化前后 + 属性注入)
│       └─ SmartInstantiationAwareBPP      (推断构造器、获取早期引用)
├── DestructionAwareBeanPostProcessor      (销毁前)
└── MergedBeanDefinitionPostProcessor      (BD 合并后)
```

| BPP 接口 | 方法 | Spring 自带的实现 / 用途 |
| --- | --- | --- |
| `postProcessBeforeInstantiation` | 实例化前 | AOP 在此处理标了 `@Aspect` 自身的类（避免被代理） |
| `postProcessAfterInstantiation` | 实例化后、属性注入前 | 返回 false 可跳过属性注入 |
| `postProcessProperties` | 属性注入 | `AutowiredAnnotationBPP` 处理 `@Autowired`、`@Value` |
| `postProcessMergedBeanDefinition` | BD 合并后 | `AutowiredAnnotationBPP` 扫描 `@Autowired` 元数据 |
| `getEarlyBeanReference` | 三级缓存返回早期引用 | AOP 提前生成代理（循环依赖场景） |
| `postProcessBeforeInitialization` | 初始化前 | `ApplicationContextAwareProcessor`、`@PostConstruct` |
| `postProcessAfterInitialization` | 初始化后 | **AOP 代理 99% 在这里创建** |
| `postProcessBeforeDestruction` | 销毁前 | `@PreDestroy` |

---

## 五、源码核心片段

### `doCreateBean` 主流程

```java
protected Object doCreateBean(String beanName, RootBeanDefinition mbd, Object[] args) {
    // ========== 1. 实例化 ==========
    BeanWrapper instanceWrapper = createBeanInstance(beanName, mbd, args);
    Object bean = instanceWrapper.getWrappedInstance();

    // ========== 2. MergedBeanDefinitionPostProcessor ==========
    synchronized (mbd.postProcessingLock) {
        if (!mbd.postProcessed) {
            applyMergedBeanDefinitionPostProcessors(mbd, beanType, beanName);
            mbd.postProcessed = true;
        }
    }

    // ========== 3. 提前曝光（三级缓存）==========
    boolean earlySingletonExposure = (mbd.isSingleton() && this.allowCircularReferences
            && isSingletonCurrentlyInCreation(beanName));
    if (earlySingletonExposure) {
        addSingletonFactory(beanName, () -> getEarlyBeanReference(beanName, mbd, bean));
    }

    // ========== 4. 属性注入 ==========
    Object exposedObject = bean;
    populateBean(beanName, mbd, instanceWrapper);

    // ========== 5. 初始化（Aware + BPP + init-method）==========
    exposedObject = initializeBean(beanName, exposedObject, mbd);

    // ========== 6. 注册销毁回调 ==========
    registerDisposableBeanIfNecessary(beanName, bean, mbd);

    return exposedObject;
}
```

### `initializeBean` 核心

```java
protected Object initializeBean(String beanName, Object bean, RootBeanDefinition mbd) {
    // (1) Aware 回调
    invokeAwareMethods(beanName, bean);

    // (2) BPP - postProcessBeforeInitialization
    Object wrappedBean = applyBeanPostProcessorsBeforeInitialization(bean, beanName);

    // (3) afterPropertiesSet + init-method
    invokeInitMethods(beanName, wrappedBean, mbd);

    // (4) BPP - postProcessAfterInitialization  ← AOP 代理通常在这里创建
    wrappedBean = applyBeanPostProcessorsAfterInitialization(wrappedBean, beanName);

    return wrappedBean;
}
```

---

## 六、AOP 代理在生命周期的哪一步织入？

**绝大多数情况**：第 6 步初始化的 `postProcessAfterInitialization` —— 此时 bean 已经完全创建好，BPP 把它包装成代理对象返回。

**循环依赖场景**：第 4 步提前曝光时，通过 `getEarlyBeanReference` 提前生成代理。

```java
// AbstractAutoProxyCreator
public Object postProcessAfterInitialization(Object bean, String beanName) {
    if (!this.earlyProxyReferences.contains(cacheKey)) {
        return wrapIfNecessary(bean, beanName, cacheKey);   // 创建代理
    }
    // 循环依赖时已经在 getEarlyBeanReference 提前代理过，直接返回
    return bean;
}
```

> **追问**：为什么不在 `postProcessBeforeInitialization` 创建？因为在那之前还有 `@PostConstruct`、`afterPropertiesSet()`、自定义 init-method 要执行——这些方法都应该作用在 **原始 bean** 上，作用在代理对象上语义就乱了（`this` 指向变化）。

---

## 七、生产踩坑

### 坑 1：`@PostConstruct` 里调用了被代理的方法 → 事务/AOP 失效

```java
@Service
public class UserService {
    @PostConstruct
    public void init() {
        loadCache();          // ❌ 此时还没被 AOP 包装，事务不生效
    }

    @Transactional
    public void loadCache() { ... }
}
```

**根因**：`@PostConstruct` 在初始化前回调，AOP 代理在初始化**后**生成。这个时刻拿到的还是原始对象，`this.xxx()` 不走代理。
**修法**：把启动初始化逻辑移到 `ApplicationRunner` / `CommandLineRunner` / `ApplicationListener<ContextRefreshedEvent>`——这些都在容器完全启动后触发。

### 坑 2：循环依赖 + `@Async` → 启动报错

```
The bean 'xxx' could not be injected because it is a JDK dynamic proxy 
that implements: ... You should consider proxy mode 'targetClass'
```

**根因**：`@Async` 通过 BPP 在 `postProcessAfterInitialization` 生成代理，但 A 已经在循环依赖时把"原始引用"注入给 B 了，最终 A 的代理替换不掉 B 持有的原始引用——Spring 检测到不一致直接报错。
**修法**：
- 改用构造器注入，强制让循环依赖暴露在编译期
- 或者破坏循环（拆 bean、改架构）
- 或者 `@Lazy` 注入

### 坑 3：`@Autowired` 注入的字段在构造器里是 null

```java
@Service
public class UserService {
    @Autowired
    private UserDao userDao;       // 字段注入

    public UserService() {
        userDao.findAll();         // ❌ NPE！此时还没属性注入
    }
}
```

**根因**：构造器执行在属性注入**之前**。
**修法**：用构造器注入，或把初始化逻辑搬到 `@PostConstruct`。

### 坑 4：`destroy-method` 没被调用

**可能原因**：
1. bean 是 `prototype` scope —— Spring 不管销毁
2. JVM 直接 `kill -9` —— 没走优雅关闭
3. ApplicationContext 没有调 `close()`（在传统 Web 里要靠 `ContextLoaderListener`，Spring Boot 自带 shutdown hook）

**修法**：Spring Boot 默认行为已经够好；非 Spring Boot 项目要手动注册 shutdown hook：`((ConfigurableApplicationContext) ctx).registerShutdownHook();`

### 坑 5：`SmartInitializingSingleton` vs `InitializingBean` 用错

`InitializingBean.afterPropertiesSet()` 是 **每个 bean 自己** 创建完后调；`SmartInitializingSingleton.afterSingletonsInstantiated()` 是 **所有单例都创建完** 后调。**要做"启动时 warm up 缓存（依赖其他 bean 已就绪）"，必须用后者**。

---

## 八、面试高频追问

**Q1：完整描述 Bean 的生命周期**
A：4 阶段 + 11 个扩展点：
1. **实例化**：`createBeanInstance` 推断构造器 → new
2. **属性注入**：`populateBean`，`@Autowired` 在 `InstantiationAwareBPP.postProcessProperties` 完成
3. **初始化**：Aware → `BPP.before` (含 `@PostConstruct`) → `afterPropertiesSet` + init-method → `BPP.after` (AOP 代理)
4. **销毁**：`@PreDestroy` → `destroy()` → destroy-method

**Q2：`InitializingBean` 和 `@PostConstruct` 区别？**
A：
- 触发顺序：`@PostConstruct` 先（在 `BPP.before` 里），`afterPropertiesSet` 后
- 来源：前者 JSR-250、不绑 Spring；后者 Spring 接口、有耦合
- 推荐：`@PostConstruct`

**Q3：BeanPostProcessor 的 before 和 after 各做什么？**
A：
- **before**：注入框架级"内置依赖"（ApplicationContext、Environment）、调用 `@PostConstruct`
- **after**：**生成 AOP 代理**（绝大多数场景）、做 metric / tracing 的包装

**Q4：FactoryBean 的生命周期？**
A：FactoryBean 自身走完整生命周期。`getBean(name)` 拿到的是 `FactoryBean.getObject()` 产出的对象——**这个对象不走 Spring 生命周期**（不会有 BPP 加工、不会被 AOP 代理）。Spring Boot 里 MyBatis 的 Mapper 就是这么生成的。

**Q5：单例 bean 是何时创建的？**
A：默认是容器启动时（`finishBeanFactoryInitialization` → `preInstantiateSingletons`）。`@Lazy` 改为首次调用 `getBean` 时创建。

**Q6：bean 创建过程中，三级缓存何时用？**
A：
- **写入**：第 4 步 `addSingletonFactory` 把 `ObjectFactory` 放入三级缓存
- **读取**：当其他 bean 的属性注入需要它时，从三级缓存调 `getObject` 拿早期引用，并从三级移到二级
- **清理**：bean 完全初始化后，移除二、三级，写入一级

**Q7：为什么 Aware 接口要分两批回调？**
A：`BeanNameAware` / `BeanFactoryAware` 这批属于 BeanFactory 层就能给的——直接在 `invokeAwareMethods` 里调；`ApplicationContextAware` / `EnvironmentAware` 这批属于上层概念，BeanFactory 看不到，必须靠 `ApplicationContextAwareProcessor` 这个 BPP 在 `before-init` 里调。本质是 **BeanFactory 不应该知道自己被谁包着**——分层设计。

**Q8：父子容器中的 bean 生命周期？**
A：父容器的 bean 子容器能看到，子容器的 bean 父容器看不到。每个容器独立走完整生命周期。Spring MVC 的 `DispatcherServlet` 上下文是 Root 上下文（含 Service / DAO）的子容器——这就是为什么 `@Controller` 不能在 Root 上下文里。

---

## 九、答题模板（60 秒）

> Bean 生命周期分 **4 大阶段、8 个核心步骤、11 个扩展点**：
>
> **第一阶段实例化**：`createBeanInstance` 推断构造器 new 出对象。
> **第二阶段属性注入**：`populateBean`，`@Autowired` 由 `AutowiredAnnotationBeanPostProcessor` 在 `postProcessProperties` 完成。
> **第三阶段初始化**：① `Aware` 接口回调（BeanName / BeanFactory），② `BeanPostProcessor.postProcessBeforeInitialization`（这一步 `ApplicationContextAware` 注入 ctx、`@PostConstruct` 被调用），③ `InitializingBean.afterPropertiesSet()` 和自定义 init-method，④ `BeanPostProcessor.postProcessAfterInitialization`——**AOP 代理就在这一步生成**。
> **第四阶段销毁**：`@PreDestroy` → `DisposableBean.destroy()` → 自定义 destroy-method。
>
> 中间穿插的关键设计：第 3 步 `MergedBeanDefinitionPostProcessor` 解析注解元数据；第 4 步 `addSingletonFactory` 提前曝光到三级缓存（解循环依赖）；循环依赖场景 AOP 代理会被迫在 `getEarlyBeanReference` 提前生成。
>
> 高频踩坑：**`@PostConstruct` 里调本类被代理方法不生效（代理还没生成）、构造器里访问 `@Autowired` 字段 NPE（属性还没注入）、prototype 不触发销毁回调**。

---

## 十、相关文档

- 前置：[IoC容器.md](IoC容器.md) — `refresh()` 12 步如何驱动每个 bean 走生命周期
- 配套：[循环依赖.md](循环依赖.md) — 三级缓存如何与生命周期协作
- 配套：[AOP.md](AOP.md) — 代理在 `postProcessAfterInitialization` 怎么生成
- 配套：[InitializingBean和SmartInitializingSingleton.md](InitializingBean和SmartInitializingSingleton.md) — 两个初始化时机的差异
