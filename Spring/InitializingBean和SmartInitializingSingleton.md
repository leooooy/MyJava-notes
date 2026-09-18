# InitializingBean vs SmartInitializingSingleton

> 看似冷门，但**写过 Starter / 中间件初始化逻辑** 的人都被坑过。
> 区分点很简单：**单 bean 维度 vs 全部单例维度**。但很多人讲不出"为什么要有两个"——这是面试官真正想听的。

---

## 一、为什么需要两个接口

设想三种"启动后做点事"的需求：

| 需求 | 时机 |
| --- | --- |
| ① 当前 bean 自己注入完属性后做校验 | bean 自身初始化时 |
| ② 当前 bean 依赖了 N 个其他 bean，要等它们都好了我才能跑 | 当前 bean 创建之后？不对，依赖的可能更晚 |
| ③ 全部单例都好了，我做个全局 warm-up | 容器完全启动后 |

`InitializingBean` 解决①；`SmartInitializingSingleton` 解决③；②只能靠 `@DependsOn` + ① 或 ③。

**两个接口本质不同**：
- `InitializingBean.afterPropertiesSet()` —— **每个 bean 自己完成初始化的钩子**
- `SmartInitializingSingleton.afterSingletonsInstantiated()` —— **所有单例都完成后的全局钩子**

---

## 二、`InitializingBean`

```java
public interface InitializingBean {
    void afterPropertiesSet() throws Exception;
}
```

### 2.1 触发时机

属于 Bean 生命周期的初始化阶段，在 `invokeInitMethods` 中调用：

```
Bean 实例化
  ↓
属性注入
  ↓
Aware 接口回调
  ↓
BPP.postProcessBeforeInitialization (含 @PostConstruct)
  ↓
★ InitializingBean.afterPropertiesSet()       ← 这里
  ↓
自定义 init-method
  ↓
BPP.postProcessAfterInitialization (AOP 代理)
```

### 2.2 替代方案

| 方式 | 推荐度 | 备注 |
| --- | --- | --- |
| `@PostConstruct` | ⭐⭐⭐⭐⭐ | JSR-250 标准，不绑 Spring，迁移成本低 |
| `InitializingBean` | ⭐⭐ | 耦合 Spring API |
| `@Bean(initMethod="init")` | ⭐⭐⭐ | 无侵入，对第三方类适用 |
| XML `init-method` | ⭐ | 古早 |

> **生产规约**：业务代码用 `@PostConstruct`；写中间件 / Spring 内部框架代码才用 `InitializingBean`（因为不能依赖 JSR-250 注解、性能敏感）。

### 2.3 调用顺序

如果一个 bean 同时用了三种：

```
@PostConstruct     →   afterPropertiesSet()    →   custom init-method
```

三者都会调，按上面顺序执行。

---

## 三、`SmartInitializingSingleton`

```java
public interface SmartInitializingSingleton {
    void afterSingletonsInstantiated();
}
```

Spring 4.1 引入。**接口名直译**："聪明的初始化时机感知者"——比 `InitializingBean` 知道更晚的时机。

### 3.1 触发时机

在 `DefaultListableBeanFactory.preInstantiateSingletons` 末尾——**所有非懒加载单例都创建完成后**统一回调：

```java
public void preInstantiateSingletons() throws BeansException {
    List<String> beanNames = new ArrayList<>(this.beanDefinitionNames);
    
    // ========== 第一遍：创建所有单例 ==========
    for (String beanName : beanNames) {
        RootBeanDefinition bd = getMergedLocalBeanDefinition(beanName);
        if (!bd.isAbstract() && bd.isSingleton() && !bd.isLazyInit()) {
            if (isFactoryBean(beanName)) {
                Object bean = getBean(FACTORY_BEAN_PREFIX + beanName);
                ...
            } else {
                getBean(beanName);                // 走完整生命周期
            }
        }
    }
    
    // ========== 第二遍：所有单例创建完后，回调 SmartInitializingSingleton ==========
    for (String beanName : beanNames) {
        Object singletonInstance = getSingleton(beanName);
        if (singletonInstance instanceof SmartInitializingSingleton smartSingleton) {
            smartSingleton.afterSingletonsInstantiated();
        }
    }
}
```

> **关键**：先把所有单例都造出来 → 再统一回调。这就是 "Smart" 的语义。

### 3.2 与 `ContextRefreshedEvent` 的区别

| 维度 | `SmartInitializingSingleton` | `ContextRefreshedEvent` |
| --- | --- | --- |
| 触发位置 | `preInstantiateSingletons` 末尾（refresh 第 11 步） | `finishRefresh` 末尾（refresh 第 12 步） |
| 时序 | 早 | 晚 |
| 拿什么 | 自身被注入的所有 bean | 整个 ApplicationContext |
| 适用场景 | 框架内部逻辑（"所有 bean 都好了我做点收尾"） | 业务"启动完成"信号 |
| 用法 | 实现接口 | `@EventListener(ContextRefreshedEvent.class)` |

> **场景区分**：
> - 写业务"应用启动后预热缓存"——用 `ApplicationReadyEvent`（甚至更晚）
> - 写框架/中间件"所有 bean 装好我做内部初始化"——用 `SmartInitializingSingleton`

---

## 四、两者对比

| 维度 | `InitializingBean` | `SmartInitializingSingleton` |
| --- | --- | --- |
| 调用时机 | **每个 bean 自己** 初始化时 | **所有非懒单例** 都创建完后 |
| 调用次数 | 每个实现该接口的 bean 调一次 | 每个实现该接口的 bean 仍调一次（按 bean 维度），但**时刻不同** |
| 适用 scope | 任意（singleton / prototype 等） | **仅 singleton** |
| 是否对懒加载生效 | 是（首次 getBean 触发） | 否（preInstantiate 阶段不创建懒 bean） |
| 引入版本 | Spring 1.0 | Spring 4.1 |
| 适用场景 | 当前 bean 的初始化校验、状态准备 | 跨 bean 协调、依赖其他 bean 已就绪的全局逻辑 |

---

## 五、源码深入

### 5.1 `InitializingBean` 调用链

```java
// AbstractAutowireCapableBeanFactory.invokeInitMethods
protected void invokeInitMethods(String beanName, Object bean, RootBeanDefinition mbd) throws Throwable {
    boolean isInitializingBean = bean instanceof InitializingBean;
    if (isInitializingBean && (mbd == null || !mbd.hasAnyExternallyManagedInitMethod("afterPropertiesSet"))) {
        // 调 afterPropertiesSet
        ((InitializingBean) bean).afterPropertiesSet();
    }
    // 调自定义 init-method
    if (mbd != null && bean.getClass() != NullBean.class) {
        String initMethodName = mbd.getInitMethodName();
        if (StringUtils.hasLength(initMethodName) && ...) {
            invokeCustomInitMethod(beanName, bean, mbd);
        }
    }
}
```

### 5.2 `SmartInitializingSingleton` 在哪触发

只有 `DefaultListableBeanFactory.preInstantiateSingletons()` 末尾，没有别的入口。**这意味着**：
- 只对单例生效
- 只在 `finishBeanFactoryInitialization` 阶段（refresh 第 11 步）触发一次
- 懒加载 bean 即使最终被实例化，也不会被回调（因为它不在 `preInstantiateSingletons` 的范围内）

---

## 六、生产用法案例

### 6.1 框架级：`EventListenerMethodProcessor`（Spring 自带）

```java
public class EventListenerMethodProcessor implements SmartInitializingSingleton, ApplicationContextAware {
    @Override
    public void afterSingletonsInstantiated() {
        ConfigurableListableBeanFactory bf = ...;
        for (String beanName : bf.getBeanNamesForType(Object.class)) {
            // 扫描每个 bean 上的 @EventListener 方法，注册到事件多播器
            processBean(beanName, type);
        }
    }
}
```

**为什么用 `SmartInitializingSingleton`**：要扫描所有 bean 的 `@EventListener` 注解，必须等所有 bean 都创建完才能扫全。`InitializingBean` 在每个 bean 自己创建时调，那时其他 bean 可能还没创建。

### 6.2 业务级：缓存预热

```java
@Component
public class CacheWarmer implements SmartInitializingSingleton {
    @Resource private UserService userService;
    @Resource private ProductService productService;
    
    @Override
    public void afterSingletonsInstantiated() {
        // 此时 UserService、ProductService 都已经完全初始化
        userService.preloadActiveUsers();
        productService.preloadHotProducts();
    }
}
```

> **更推荐 `ApplicationReadyEvent`**——更晚触发（Tomcat 也启好了），且不耦合 Spring 接口。`SmartInitializingSingleton` 适合 starter / 框架代码。

### 6.3 反例：用 `InitializingBean` 做全局协调

```java
@Component
public class BadExample implements InitializingBean {
    @Resource private SomeService someService;
    
    @Override
    public void afterPropertiesSet() {
        someService.preload();        // ❌ someService 可能还没完全初始化（取决于创建顺序）
    }
}
```

`InitializingBean` 触发时只保证当前 bean 自己的属性已注入，**不保证它注入的依赖也完全初始化**——尤其在循环依赖场景。

---

## 七、生产踩坑

### 坑 1：`afterPropertiesSet` 里发起重操作

```java
@Component
public class HeavyInit implements InitializingBean {
    @Override
    public void afterPropertiesSet() {
        loadHugeDataFromDb();    // ❌ 启动慢
    }
}
```

启动期间这种重操作让启动从 3 秒变 30 秒。
**修法**：挪到 `ApplicationReadyEvent` + `@Async`，让启动不被阻塞。

### 坑 2：`SmartInitializingSingleton` 里做事抛异常导致整个启动失败

```java
@Override
public void afterSingletonsInstantiated() {
    callRemote();    // ❌ 远程接口暂时不可达，整个应用挂
}
```

**修法**：try-catch 兜底，或挪到 `ApplicationReadyEvent` + 重试。

### 坑 3：`InitializingBean` 里访问被代理的方法

```java
@Component
public class UserService implements InitializingBean {
    @Override
    public void afterPropertiesSet() {
        loadCache();         // ❌ 此时还没生成 AOP 代理，事务等不生效
    }
    
    @Transactional
    public void loadCache() { ... }
}
```

**根因**：`afterPropertiesSet` 在 `BPP.postProcessAfterInitialization` 之前——AOP 代理是在那一步生成的。
**修法**：见 [Bean生命周期.md](Bean生命周期.md) 的 AOP 失效相关部分。

### 坑 4：`@Lazy` bean 的 `SmartInitializingSingleton` 不被调

```java
@Component
@Lazy
public class LazyBean implements SmartInitializingSingleton {
    @Override
    public void afterSingletonsInstantiated() {
        ...        // 永远不会被调（除非外部主动 getBean）
    }
}
```

**根因**：懒加载 bean 在 `preInstantiateSingletons` 阶段不创建，自然也不在回调列表里。
**修法**：去掉 `@Lazy`，或换 `ApplicationReadyEvent`。

---

## 八、面试高频追问

**Q1：`InitializingBean` 和 `@PostConstruct` 区别？**
A：① 来源：前者 Spring 接口，后者 JSR-250 标准注解；② 触发顺序：`@PostConstruct` 先（在 `BPP.postProcessBeforeInitialization` 里），`afterPropertiesSet` 后；③ 推荐用 `@PostConstruct`，迁移成本低。

**Q2：`InitializingBean` 和 `SmartInitializingSingleton` 区别？**
A：核心差异是 **触发时机的范围**：
- `InitializingBean`：bean **自己**初始化阶段（其他 bean 可能还没创建）
- `SmartInitializingSingleton`：**所有非懒单例都创建完**后回调

举例：`EventListenerMethodProcessor` 要扫描所有 bean 的 `@EventListener`，必须用后者；当前 bean 自己做参数校验，用前者就够。

**Q3：为什么 `SmartInitializingSingleton` 只对单例生效？**
A：方法名直接说了——它的回调点在 `preInstantiateSingletons`。这个方法只创建单例非懒 bean，prototype 是按需创建的，没有"全部 prototype 都好了"这个概念。

**Q4：`SmartInitializingSingleton` 和 `ContextRefreshedEvent` 选哪个？**
A：
- 框架级、想拿到容器但不想 implements `ApplicationContextAware` —— `SmartInitializingSingleton`
- 业务级、想"启动后做点事" —— `ContextRefreshedEvent` 或 `ApplicationReadyEvent`（后者更晚，更安全）
- 区别：`SmartInitializingSingleton` 更早，`ContextRefreshedEvent` 在 refresh 末尾

**Q5：`afterPropertiesSet` 和 init-method 哪个先调？**
A：`afterPropertiesSet` 先，init-method 后。前者是接口约定，后者是 BD 配置 —— Spring 把接口路径优先级调得更高。

**Q6：`SmartInitializingSingleton` 在哪个类的方法里被调？**
A：`DefaultListableBeanFactory.preInstantiateSingletons()`——在 refresh() 第 11 步 `finishBeanFactoryInitialization` 中调用。

**Q7：实现这俩接口对单元测试有什么影响？**
A：`InitializingBean` 是 Spring 接口——单元测试如果不起 Spring 容器，需要手动调 `afterPropertiesSet`。`@PostConstruct` 同样也是初始化钩子但不强制调用——所以业务代码 **不应该把关键逻辑放在初始化钩子里**，提供单独的 `init()` public 方法供测试和业务都能调。

---

## 九、答题模板（45 秒）

> 两者都是 Spring 的**初始化钩子**，但触发的范围不同：
>
> **`InitializingBean.afterPropertiesSet()`**：每个实现该接口的 bean 在自己**属性注入完成**后调用，属于 Bean 生命周期初始化阶段（`invokeInitMethods` 内）。**当前 bean 自己的初始化校验**用它。
>
> **`SmartInitializingSingleton.afterSingletonsInstantiated()`**：在 **所有非懒加载单例都创建完成后**统一回调，由 `DefaultListableBeanFactory.preInstantiateSingletons()` 末尾触发。Spring 4.1 引入，典型用法：`EventListenerMethodProcessor` 扫描所有 bean 的 `@EventListener`——必须等所有 bean 都好才能扫全。
>
> 选型：
> - **业务代码** 用 `@PostConstruct`（不绑 Spring）或 `ApplicationReadyEvent`（更晚、更安全）
> - **写框架 / Starter** 才考虑 `InitializingBean`（性能敏感、不依赖 JSR-250）和 `SmartInitializingSingleton`（跨 bean 协调）
>
> 顺序：`@PostConstruct` → `afterPropertiesSet()` → `init-method` → AOP 代理 → `SmartInitializingSingleton.afterSingletonsInstantiated()` → `ContextRefreshedEvent` → `ApplicationStartedEvent` → `Runner` → `ApplicationReadyEvent`。

---

## 十、相关文档

- 前置：[Bean生命周期.md](Bean生命周期.md) — `invokeInitMethods` 的位置
- 前置：[IoC容器.md](IoC容器.md) — `preInstantiateSingletons` 在 refresh 第 11 步
- 配套：[SpringBoot启动流程.md](SpringBoot启动流程.md) — `ApplicationReadyEvent` 触发时机
