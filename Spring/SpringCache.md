# Spring Cache

> 业务里几乎每个 Service 都在用，但 90% 的人讲不清三件事：
> ① **Spring Cache 是抽象层**——不是缓存实现，背后是 Caffeine / Redis / EhCache
> ② `@Cacheable` 内部走的是 **AOP 代理 + 责任链 + key 生成器** 这套组合拳
> ③ Spring Cache **不防穿透 / 雪崩 / 击穿**——这些要业务自己加
>
> 答得清这三块就是高级。

---

## 一、Spring Cache 是什么

**Spring Cache 是缓存抽象（abstraction），不是缓存实现**。

```
                业务代码（@Cacheable）
                      │
                      ▼
            ┌─────────────────────┐
            │  Spring Cache 抽象  │  ← Spring 提供的统一接口（Cache / CacheManager）
            └──────────┬──────────┘
                        │
       ┌────────┬───────┼────────┬────────────┐
       ▼        ▼       ▼        ▼            ▼
  ConcurrentMap Caffeine EhCache Redis    自定义实现
   (默认)      (本地)   (本地)  (分布式)
```

**为什么要抽象**：
- ① 业务代码不绑定具体缓存实现——切 Caffeine 换 Redis 不改业务代码
- ② 注解式 API（`@Cacheable` / `@CacheEvict`）比手写 `redis.get/set` 简洁 80%
- ③ 统一了多种缓存的"生命周期、key 生成、序列化、SpEL 表达式"

**反面**：
- ❌ Spring Cache 抽象的能力是子集——具体实现的高级特性（Redis Pipeline、Lua 脚本）用不到
- ❌ **不防穿透 / 雪崩 / 击穿**——这些是 Redis 业务层概念，Spring Cache 不负责（详见 [../Redis/缓存雪崩，击穿，穿透.md](../Redis/缓存雪崩，击穿，穿透.md)）
- ❌ 不支持二级缓存（要自己组合 Caffeine + Redis）

---

## 二、5 个核心注解

| 注解 | 语义 | 时机 |
| --- | --- | --- |
| `@Cacheable` | **缓存读**：先查缓存，命中返回；未命中执行方法、把返回值放缓存 | 方法执行前 |
| `@CachePut` | **强制写缓存**：方法一定执行，把返回值放缓存（无论是否命中） | 方法执行后 |
| `@CacheEvict` | **删除缓存**：方法执行后清掉对应缓存 | 方法执行后 |
| `@Caching` | 组合多个上述操作（一次操作多个缓存） | 同上 |
| `@CacheConfig` | 类级别默认值（cacheNames / keyGenerator） | 类上 |

### 2.1 `@Cacheable` 完整用法

```java
@Cacheable(
    cacheNames = "user",                              // 缓存区名
    key = "#id",                                      // SpEL 表达式生成 key
    condition = "#id > 0",                            // 满足条件才缓存
    unless = "#result == null",                       // 结果不为 null 才缓存
    sync = true                                       // 同 key 并发只一个调用方法
)
public User getById(Long id) {
    return userDao.findById(id);
}
```

### 2.2 `@CacheEvict` 用法

```java
@CacheEvict(cacheNames = "user", key = "#user.id")
public void update(User user) { ... }

@CacheEvict(cacheNames = "user", allEntries = true)   // 清空整个缓存区
public void rebuildAll() { ... }

@CacheEvict(cacheNames = "user", key = "#id", beforeInvocation = true)
public void delete(Long id) { ... }                   // 方法执行前就清（防止 DB 删失败但缓存已删）
```

### 2.3 `@Caching` 组合操作

```java
@Caching(
    put = { @CachePut(cacheNames = "user", key = "#user.id") },
    evict = { @CacheEvict(cacheNames = "userList", allEntries = true) }
)
public User update(User user) { ... }
```

---

## 三、底层原理：从注解到缓存读写

### 3.1 整体链路

```
启动期
└─ @EnableCaching
   └─ @Import(CachingConfigurationSelector)
      └─ 注册 ProxyCachingConfiguration
         ├─ CacheInterceptor (AOP 拦截器)
         └─ BeanFactoryCacheOperationSourceAdvisor (Advisor)
   └─ Bean 创建时 BPP 检查方法是否有缓存注解，匹配则生成代理

运行期
└─ 业务调用 userService.getById(123)
   └─ 经过 CacheInterceptor.invoke()
      └─ CacheAspectSupport.execute()
         ├─ ① 解析方法上的 @Cacheable 等注解 → CacheOperation
         ├─ ② 用 KeyGenerator 生成 key（默认 SimpleKeyGenerator）
         ├─ ③ 用 CacheManager 拿到对应的 Cache 对象
         ├─ ④ Cache.get(key) 查缓存
         │   ├─ 命中：直接返回（不调方法）
         │   └─ 未命中：调方法 → Cache.put(key, result)
         └─ ⑤ 返回结果
```

### 3.2 `CacheInterceptor` 核心代码

```java
public Object invoke(MethodInvocation invocation) throws Throwable {
    Method method = invocation.getMethod();
    return execute(invocation::proceed, method, invocation.getArguments());
}

protected Object execute(CacheOperationInvoker invoker, Object target, Method method, Object[] args) {
    // 解析 @Cacheable / @CachePut / @CacheEvict
    Collection<CacheOperation> operations = getCacheOperationSource()
        .getCacheOperations(method, target.getClass());
    
    if (!operations.isEmpty()) {
        return execute(invoker, method, new CacheOperationContexts(operations, ...));
    }
    return invoker.invoke();   // 没有注解直接执行
}
```

### 3.3 抽象核心两个接口

```java
public interface CacheManager {
    Cache getCache(String name);     // 按名字拿到 Cache 实例
    Collection<String> getCacheNames();
}

public interface Cache {
    String getName();
    Object getNativeCache();          // 拿底层实现（如 RedisTemplate）
    ValueWrapper get(Object key);
    void put(Object key, Object value);
    void evict(Object key);
    void clear();
    <T> T get(Object key, Callable<T> valueLoader);   // 原子加载（防穿透）
}
```

不同实现：

| CacheManager | Cache 实现 |
| --- | --- |
| `ConcurrentMapCacheManager`（默认） | `ConcurrentMapCache` |
| `CaffeineCacheManager` | `CaffeineCache`（内部 `com.github.benmanes.caffeine.cache.Cache`） |
| `RedisCacheManager` | `RedisCache`（基于 RedisTemplate） |
| `EhCacheCacheManager` | `EhCacheCache` |

---

## 四、Key 生成

### 4.1 默认 `SimpleKeyGenerator`

```java
方法没参数         → key = SimpleKey.EMPTY
1 个参数           → key = 参数本身
N 个参数（N ≥ 2）  → key = SimpleKey(arg1, arg2, ..., argN)
```

> **生产坑**：参数是普通 POJO 时，默认 key 等于 `SimpleKey + 调用 toString`——POJO 的 `equals/hashCode` 必须重写，否则缓存命中率为 0。

### 4.2 SpEL 表达式

```java
@Cacheable(cacheNames = "user", key = "#id")                    // 取 id 参数
@Cacheable(cacheNames = "user", key = "#user.name")             // 取对象字段
@Cacheable(cacheNames = "user", key = "#root.method.name")      // 方法名
@Cacheable(cacheNames = "user", key = "#root.targetClass.simpleName + ':' + #id")
@Cacheable(cacheNames = "user", key = "T(java.util.Objects).hash(#id, #type)")
```

可用变量：
- `#参数名` —— 直接引用参数（编译期需 `-parameters`，否则用 `#a0` / `#p0`）
- `#root.method` / `#root.target` / `#root.targetClass` / `#root.args` / `#root.caches`
- `#result` —— **方法返回值**（仅 `unless` / `condition` 在方法后求值时可用）

### 4.3 自定义 `KeyGenerator`

```java
@Component("myKeyGenerator")
public class MyKeyGenerator implements KeyGenerator {
    @Override
    public Object generate(Object target, Method method, Object... params) {
        return target.getClass().getSimpleName() + ":" + method.getName() + ":"
             + Arrays.stream(params).map(String::valueOf).collect(Collectors.joining(","));
    }
}

@Cacheable(cacheNames = "user", keyGenerator = "myKeyGenerator")
public User getById(Long id) { ... }
```

---

## 五、Redis 缓存实现配置

```java
@Configuration
@EnableCaching
public class CacheConfig {
    
    @Bean
    public CacheManager cacheManager(RedisConnectionFactory cf) {
        RedisCacheConfiguration defaultConfig = RedisCacheConfiguration.defaultCacheConfig()
            .entryTtl(Duration.ofMinutes(10))                 // 默认 TTL 10 分钟
            .serializeKeysWith(RedisSerializationContext.SerializationPair.fromSerializer(new StringRedisSerializer()))
            .serializeValuesWith(RedisSerializationContext.SerializationPair.fromSerializer(new GenericJackson2JsonRedisSerializer()))
            .disableCachingNullValues();                      // 不缓存 null
        
        // 不同缓存区不同 TTL
        Map<String, RedisCacheConfiguration> configMap = new HashMap<>();
        configMap.put("user",     defaultConfig.entryTtl(Duration.ofMinutes(30)));
        configMap.put("hot-data", defaultConfig.entryTtl(Duration.ofSeconds(60)));
        
        return RedisCacheManager.builder(cf)
            .cacheDefaults(defaultConfig)
            .withInitialCacheConfigurations(configMap)
            .build();
    }
}
```

**Key 在 Redis 里长什么样**：
```
user::123        ← cacheNames + "::" + key
hot-data::abc
```

`::` 是 `RedisCacheConfiguration` 默认分隔符，可改 `computePrefixWith(...)`。

---

## 六、二级缓存（Caffeine + Redis）

业务诉求：本地缓存够快、Redis 跨节点共享，组合使用。

```
读：先查 Caffeine（< 100ns） → 没命中查 Redis（ms 级） → 没命中查 DB → 写入两级
写：删 Redis + 删 Caffeine（本节点） + 通过 Redis Pub/Sub 通知其他节点删 Caffeine
```

### 6.1 自定义 CacheManager

```java
public class TwoLevelCacheManager implements CacheManager {
    private final CacheManager localManager;       // CaffeineCacheManager
    private final CacheManager remoteManager;      // RedisCacheManager
    
    @Override
    public Cache getCache(String name) {
        return new TwoLevelCache(localManager.getCache(name), remoteManager.getCache(name));
    }
}

public class TwoLevelCache implements Cache {
    private final Cache local;
    private final Cache remote;
    
    @Override
    public ValueWrapper get(Object key) {
        ValueWrapper v = local.get(key);                  // L1
        if (v != null) return v;
        v = remote.get(key);                              // L2
        if (v != null) {
            local.put(key, v.get());                      // 回填 L1
        }
        return v;
    }
    
    @Override
    public void put(Object key, Object value) {
        remote.put(key, value);                           // 先写 L2
        local.put(key, value);
        publishEvictEvent(getName(), key);                // 通知其他节点删 L1
    }
}
```

> **生产替代**：自己造轮子有坑（节点间一致性、Pub/Sub 阻塞），推荐用现成框架——**JetCache**（阿里开源）、**Cache2k**、Redisson 的 LocalCachedMap。

---

## 七、生产踩坑

### 坑 1：自调用 `@Cacheable` 失效

```java
@Service
public class UserService {
    public User outer() { return inner(123L); }    // ❌ this.inner 不走代理，缓存失效
    
    @Cacheable(cacheNames = "user", key = "#id")
    public User inner(Long id) { ... }
}
```

**根因**：和 `@Transactional` 一样的 AOP 自调用问题。**修法**：拆 bean / 自注入 / `AopContext.currentProxy()`，详见 [AOP.md](AOP.md)。

### 坑 2：缓存穿透

```java
@Cacheable(cacheNames = "user", key = "#id")
public User getById(Long id) {
    return userDao.findById(id);   // 不存在时返回 null
}
```

`disableCachingNullValues()` 配置下，每次查 null 都会穿透到 DB——攻击者拿不存在的 id 刷接口可打挂 DB。

**修法**：
- ① 不要 `disableCachingNullValues`，让 null 也缓存（设短 TTL，如 60s）
- ② 用布隆过滤器拦截无效 id（[../Redis/布隆过滤器.md](../Redis/布隆过滤器.md)）

### 坑 3：缓存击穿（热点 key 过期）

热点 key TTL 到了的瞬间，N 个并发请求同时打到 DB。

**修法**：`@Cacheable(sync = true)`——同 key 并发只允许一个线程执行方法，其他等待。

```java
@Cacheable(cacheNames = "hot", key = "#id", sync = true)
public Item getHot(Long id) { ... }
```

> ⚠️ `sync = true` **只在单进程内有效**——跨节点的 N 个 JVM 都同时过期还是会击穿。生产用 Redisson 分布式锁或 Redis Lua 脚本。

### 坑 4：缓存雪崩（大量 key 同时过期）

刚启动时批量 warm up，所有 key TTL 一样——10 分钟后同时过期，DB 瞬间被打爆。

**修法**：TTL 加随机抖动：

```java
@Bean
public CacheManager cacheManager(...) {
    return RedisCacheManager.builder(cf)
        .cacheDefaults(RedisCacheConfiguration.defaultCacheConfig()
            .entryTtl(Duration.ofMinutes(10 + ThreadLocalRandom.current().nextInt(5))))   // 10-15 分钟
        .build();
}
```

### 坑 5：序列化方式选错导致 ClassCastException

默认用 JDK 序列化——存进 Redis 的是二进制，跨服务版本变化会反序列化失败。

**修法**：用 JSON 序列化（`GenericJackson2JsonRedisSerializer`）。但要注意 JSON 反序列化 LocalDateTime 等需要配置 ObjectMapper：

```java
ObjectMapper om = new ObjectMapper();
om.activateDefaultTyping(LaissezFaireSubTypeValidator.instance, ObjectMapper.DefaultTyping.NON_FINAL);
om.registerModule(new JavaTimeModule());
GenericJackson2JsonRedisSerializer serializer = new GenericJackson2JsonRedisSerializer(om);
```

### 坑 6：`@Cacheable` 缓存了异常

旧版 Spring Cache 在方法抛异常时也会缓存——后续调用拿到的是异常对象。

**Spring 5.3+ 已修复**：异常默认不缓存。但如果用旧版要注意。

### 坑 7：`unless` vs `condition` 时机搞错

```java
// condition：方法执行前求值，可读 #参数 不可读 #result
@Cacheable(condition = "#id > 0", unless = "#result == null")
public User getById(Long id) { ... }
```

`condition` 在方法执行**前**判断（决定是否走缓存逻辑），`unless` 在方法执行**后**判断（决定结果是否放缓存）。**写错位置不报错，行为不正确**。

### 坑 8：分布式环境下本地缓存不一致

`ConcurrentMapCacheManager` / `CaffeineCacheManager` 是**进程内**缓存——节点 A 更新数据后清了本地缓存，节点 B 还在用旧值。

**修法**：分布式场景必须用 Redis；要用本地缓存就配二级缓存 + Pub/Sub 失效广播。

---

## 八、面试高频追问

**Q1：Spring Cache 是缓存实现吗？**
A：**不是，是抽象层**。Spring Cache 提供 `Cache` / `CacheManager` 两个接口和 `@Cacheable` 等注解；具体实现是 ConcurrentMap（默认） / Caffeine / Redis / EhCache 等。换实现不改业务代码。

**Q2：`@Cacheable` 怎么实现的？**
A：本质是 AOP。`@EnableCaching` 注册 `CacheInterceptor`（Advice）和 Advisor，BPP 给标注了缓存注解的方法生成代理。运行时进入 `CacheInterceptor.invoke()` → 解析注解 → 生成 key → 拿 Cache → 查缓存命中返回 / 未命中执行方法并写缓存。

**Q3：Spring Cache 怎么防穿透 / 雪崩 / 击穿？**
A：**Spring Cache 自身不防**。
- 穿透：① 缓存 null + 短 TTL；② 布隆过滤器
- 雪崩：TTL 加随机抖动
- 击穿：`@Cacheable(sync = true)`（单进程）；分布式用 Redisson 锁或 Lua 脚本

**Q4：`@Cacheable` 和 `@CachePut` 区别？**
A：
- `@Cacheable`：先查缓存，命中跳过方法
- `@CachePut`：方法**一定执行**，把结果放缓存

**Q5：自调用导致 `@Cacheable` 失效怎么解？**
A：和 `@Transactional` 一样——AOP 自调用问题。修法：① 拆 bean；② 自注入；③ `AopContext.currentProxy()`。

**Q6：`condition` 和 `unless` 区别？**
A：
- `condition`：方法**执行前**求值（可读 `#参数`），决定是否走缓存逻辑
- `unless`：方法**执行后**求值（可读 `#result`），决定结果是否放缓存

**Q7：Spring Cache 怎么实现二级缓存？**
A：自定义 `CacheManager` 和 `Cache` 接口实现。L1 用 Caffeine，L2 用 Redis；读时先 L1 后 L2，写时双写并通过 Redis Pub/Sub 通知其他节点删 L1。生产推荐用 **JetCache** 这类成熟框架，自己造轮子有节点间一致性的坑。

**Q8：Redis 序列化怎么选？**
A：默认 JDK 序列化（不推荐——二进制、不跨语言、版本演进易坏）。生产用 `GenericJackson2JsonRedisSerializer`（JSON）—— 跨语言、可读、版本兼容好；性能敏感场景用 Kryo 或 Protostuff。

**Q9：`SimpleKeyGenerator` 默认 key 怎么生成？**
A：① 无参 → `SimpleKey.EMPTY`；② 1 参 → 参数本身；③ N 参 → `SimpleKey(arg1, arg2, ...)`。**坑**：参数是 POJO 时必须重写 `equals/hashCode`，否则同样数据每次生成的 key 不同——缓存命中率 0。

**Q10：Spring Cache 怎么做缓存预热？**
A：① 启动后 `ApplicationReadyEvent` 监听器里手动 `cache.put`；② 或调用 `@Cacheable` 方法触发；③ 大数据量用批量 SQL 拉数据 + Pipeline 写 Redis。**注意**：预热完别让所有 key 同时过期——TTL 加随机。

---

## 九、答题模板（60 秒）

> Spring Cache 是 **缓存抽象层**——提供 `Cache` / `CacheManager` 接口和 5 个注解（`@Cacheable` / `@CachePut` / `@CacheEvict` / `@Caching` / `@CacheConfig`），背后是 ConcurrentMap（默认） / Caffeine（本地） / Redis（分布式） / EhCache 等具体实现。
>
> **底层**：本质是 AOP。`@EnableCaching` 注册 `CacheInterceptor`，BPP 在初始化阶段给标注缓存注解的方法包代理。调用时拦截器 → 解析注解 → SpEL 生成 key → CacheManager 拿 Cache → get 命中直接返回 / 未命中走方法并 put。
>
> **重点设计**：① `key` 用 SpEL 表达式（`#id`、`#user.name`、`#result.code`）；② `condition` 方法前求值、`unless` 方法后求值；③ `sync = true` 单进程防击穿；④ `beforeInvocation = true` 让 `@CacheEvict` 在方法前清缓存（防止 DB 删失败但缓存已删）。
>
> **Spring Cache 不防穿透 / 雪崩 / 击穿**——这些要业务自己加：穿透缓存 null 或布隆过滤器；雪崩 TTL 加随机抖动；击穿单进程 `sync=true`、分布式用 Redisson 锁。
>
> **生产高频坑**：① `this` 自调用失效；② POJO 做 key 没重写 equals/hashCode 命中率为 0；③ JDK 序列化跨版本反序列化失败（用 JSON）；④ `condition` / `unless` 时机搞错。

---

## 十、相关文档

- 前置：[AOP.md](AOP.md) — `@Cacheable` 的代理机制
- 配套：[../Redis/缓存雪崩，击穿，穿透.md](../Redis/缓存雪崩，击穿，穿透.md) — 缓存三大问题
- 配套：[../Redis/布隆过滤器.md](../Redis/布隆过滤器.md) — 防穿透方案
- 配套：[../Redis/双写一致性.md](../Redis/双写一致性.md) — 缓存与数据库一致性
