# Starter 机制

> Spring Boot 的"插件化"基础设施。这道题面试经常和"自动装配"混在一起问，但侧重点不同：
> - **自动装配** 关注"配置类怎么被发现并条件性生效"
> - **Starter** 关注"一个第三方组件怎么打包成可拔插的 jar 让业务方一行依赖就用"
>
> 本篇关注后者——**怎么写、怎么组织、怎么避坑**。

---

## 一、什么是 Starter

> "把一个组件需要的所有依赖、自动配置、默认参数打成一个 jar，业务方只引一个依赖、一行配置就能用。"

```xml
<!-- 业务方 pom.xml 只需一行 -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-redis</artifactId>
</dependency>
```

引入后自动获得：
- `spring-data-redis`、`lettuce-core`、`commons-pool2` 三个 jar
- `RedisAutoConfiguration` 把 `RedisTemplate` 注册到容器
- `RedisProperties` 把 `spring.redis.*` 配置自动绑定
- 默认连接池、默认序列化器

**Starter = 依赖整合 + 自动配置 + 默认参数 + 可覆盖**。

---

## 二、Starter 的命名约定

| 来源 | 格式 | 示例 |
| --- | --- | --- |
| **官方** | `spring-boot-starter-{name}` | `spring-boot-starter-web` / `-data-jpa` / `-actuator` |
| **第三方** | `{name}-spring-boot-starter` | `mybatis-spring-boot-starter` / `mysql-spring-boot-starter` |

**为什么第三方不能用 `spring-boot-starter-*`**：保留前缀给 Spring 官方，避免命名冲突 + 让用户一眼看出哪些是官方的、哪些是社区的。

---

## 三、官方 Starter 的内部结构

以 `spring-boot-starter-data-redis` 为例：

```
spring-boot-starter-data-redis/      ← 这是个空 jar，只起依赖聚合作用
└── pom.xml
    └── 依赖：
        spring-boot-starter           (基础)
        spring-data-redis             (功能)
        lettuce-core                  (实现)
        commons-pool2                 (连接池)
```

```
spring-boot-autoconfigure/           ← 真正的自动配置在这里
└── org/springframework/boot/autoconfigure/data/redis/
    ├── RedisAutoConfiguration.java
    ├── RedisProperties.java
    ├── LettuceConnectionConfiguration.java
    └── ...
```

```
spring-boot-autoconfigure/META-INF/spring/
└── org.springframework.boot.autoconfigure.AutoConfiguration.imports
    ↑ 这里注册了所有官方自动配置类
```

> **官方设计**：把"依赖聚合"和"自动配置"拆成两个 module。
> - `spring-boot-starter-xxx`：一个空壳 jar，只在 pom 里声明依赖
> - `spring-boot-autoconfigure`：所有官方组件的自动配置类集中在一个 jar
>
> 这样业务方哪怕只引 `spring-boot-starter`，也能拿到全部官方自动配置——只要 classpath 上有对应组件就生效（`@ConditionalOnClass`）。

---

## 四、写一个最简 Starter（完整示例）

需求：写一个 `myapp-rate-limit-spring-boot-starter`，提供基于注解的限流能力。

### 4.1 项目结构

```
myapp-rate-limit-spring-boot-starter/
├── pom.xml
├── src/main/java/com/myapp/ratelimit/
│   ├── annotation/RateLimit.java                ← 业务方使用的注解
│   ├── aspect/RateLimitAspect.java              ← AOP 实现
│   ├── service/RateLimitService.java            ← 限流逻辑
│   ├── properties/RateLimitProperties.java      ← 配置类
│   └── config/RateLimitAutoConfiguration.java   ← 自动配置类
└── src/main/resources/META-INF/
    ├── spring/
    │   └── org.springframework.boot.autoconfigure.AutoConfiguration.imports
    └── spring-configuration-metadata.json       ← IDE 提示用（可选）
```

### 4.2 pom.xml

```xml
<artifactId>myapp-rate-limit-spring-boot-starter</artifactId>
<dependencies>
    <!-- 必备依赖：自动配置 + AOP -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter</artifactId>
    </dependency>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-aop</artifactId>
    </dependency>
    
    <!-- 可选依赖：业务方需要时自己引 -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-data-redis</artifactId>
        <optional>true</optional>
    </dependency>
    
    <!-- 配置元数据生成（IDE 提示） -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-configuration-processor</artifactId>
        <optional>true</optional>
    </dependency>
</dependencies>
```

### 4.3 配置类

```java
@ConfigurationProperties(prefix = "myapp.ratelimit")
@Data
public class RateLimitProperties {
    private boolean enabled = true;
    private int defaultLimit = 100;     // 默认 100 QPS
    private long defaultPeriod = 1000;  // 1 秒窗口
    private Backend backend = Backend.MEMORY;
    
    public enum Backend { MEMORY, REDIS }
}
```

### 4.4 注解

```java
@Target(METHOD)
@Retention(RUNTIME)
public @interface RateLimit {
    int limit() default 100;
    long period() default 1000;
    String key() default "";
}
```

### 4.5 自动配置类（核心）

```java
@AutoConfiguration
@EnableConfigurationProperties(RateLimitProperties.class)
@ConditionalOnProperty(prefix = "myapp.ratelimit", name = "enabled", havingValue = "true", matchIfMissing = true)
public class RateLimitAutoConfiguration {
    
    @Bean
    @ConditionalOnMissingBean
    public RateLimitService rateLimitService(RateLimitProperties props,
                                             @Autowired(required = false) StringRedisTemplate redis) {
        return switch (props.getBackend()) {
            case MEMORY -> new MemoryRateLimitService(props);
            case REDIS  -> {
                if (redis == null) throw new IllegalStateException("Redis backend requires StringRedisTemplate");
                yield new RedisRateLimitService(redis, props);
            }
        };
    }
    
    @Bean
    @ConditionalOnMissingBean
    public RateLimitAspect rateLimitAspect(RateLimitService service) {
        return new RateLimitAspect(service);
    }
}
```

### 4.6 imports 文件

`META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`：

```
com.myapp.ratelimit.config.RateLimitAutoConfiguration
```

### 4.7 业务方使用

```xml
<dependency>
    <groupId>com.myapp</groupId>
    <artifactId>myapp-rate-limit-spring-boot-starter</artifactId>
</dependency>
```

```yaml
myapp:
  ratelimit:
    backend: redis
    default-limit: 200
```

```java
@RestController
public class OrderController {
    @RateLimit(limit = 50, period = 1000)
    @PostMapping("/order")
    public ApiResp<?> create(@RequestBody OrderReq req) { ... }
}
```

---

## 五、Starter 设计原则

### 5.1 单一职责

一个 Starter 解决一类问题。**不要做大而全的 Starter**——业务方拿不到精细控制权。

❌ 坏例子：`myapp-common-spring-boot-starter` 里既做限流、又做加密、又做日志、又做监控。

✅ 好例子：`myapp-rate-limit-...`、`myapp-encrypt-...`、`myapp-monitoring-...` 各自独立。

### 5.2 默认值合理

引入 starter **不配任何东西** 时也要能跑起来（或明确报错，不能默默失败）：

```java
@ConfigurationProperties(prefix = "myapp.cache")
@Data
public class CacheProperties {
    private boolean enabled = true;          // ✅ 默认开启
    private long ttl = 5 * 60 * 1000;        // ✅ 默认 5 分钟
    private int maxSize = 10000;             // ✅ 默认 1 万条
    
    @NotBlank
    private String redisHost;                // ❌ 没有默认值，必须配置
}
```

### 5.3 提供 `@ConditionalOnMissingBean` 让出

让业务方能覆盖：

```java
@Bean
@ConditionalOnMissingBean(CacheService.class)        // ✅ 业务方写了自己的就让位
public CacheService cacheService(...) { ... }
```

### 5.4 可选依赖用 `<optional>true</optional>`

```xml
<dependency>
    <groupId>...</groupId>
    <artifactId>some-heavy-lib</artifactId>
    <optional>true</optional>            <!-- 只有业务方真用到才引 -->
</dependency>
```

并在自动配置类用 `@ConditionalOnClass` 防御：

```java
@ConditionalOnClass(SomeHeavyLib.class)
public class HeavyLibFeatureAutoConfiguration { ... }
```

### 5.5 提供配置元数据（IDE 提示）

加 `spring-boot-configuration-processor` 依赖，编译期会自动生成 `META-INF/spring-configuration-metadata.json`，IDE 输入 `myapp.ratelimit.` 时就有提示和文档。

也可以手动写补充元数据 `META-INF/additional-spring-configuration-metadata.json`：

```json
{
  "properties": [
    {
      "name": "myapp.ratelimit.backend",
      "type": "com.myapp.ratelimit.properties.RateLimitProperties$Backend",
      "description": "限流后端：MEMORY / REDIS",
      "defaultValue": "MEMORY"
    }
  ]
}
```

---

## 六、Starter 与自动装配的协作

```
业务方                       Starter                            自动装配机制
─────                        ───────                            ─────────────
引入 starter pom    →    传递依赖：                                
                             1. 实现 jar (业务库)                   
                             2. autoconfigure jar (含 @AutoConfiguration)  
                                ↓                                       
                          jar 里的 META-INF/spring/...imports 文件    →  AutoConfigurationImportSelector 读取
                                ↓                                       
                          XxxAutoConfiguration 类                      →  按 @Conditional 过滤
                                ↓                                       
                          @Bean 方法                                  →  注册到容器
                                ↓                                       
应用启动后                @Resource 注入                                
```

> **核心**：Starter 通过 `META-INF/spring/.../AutoConfiguration.imports` 把自己的自动配置类"挂到"Spring Boot 自动装配体系上。Spring Boot 启动时自动扫描 classpath 上所有 jar 的这个文件——所以引依赖就生效。

---

## 七、生产踩坑

### 坑 1：Starter 不生效

业务方引入后 bean 没注入。**排查清单**：
1. ❌ `imports` 文件路径错——必须 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`，文件名一字不差
2. ❌ Maven 没 `mvn install`，本地 jar 没出来
3. ❌ 自动配置类被 `@Conditional*` 过滤掉——开 `debug=true` 看 CONDITIONS REPORT
4. ❌ 自动配置类被 `@SpringBootApplication(exclude=...)` 排除
5. ❌ Starter 模块没打到业务依赖里——`mvn dependency:tree` 验证

### 坑 2：Starter 之间冲突

业务方同时引了 `mybatis-spring-boot-starter` 和自家 `myapp-data-spring-boot-starter`，两个都注册了 `SqlSessionFactory`，启动报 `BeanDefinitionOverrideException`。

**修法**：
- Starter 提供方加 `@ConditionalOnMissingBean` 让位
- 业务方手动 exclude 一个 starter
- 用 `@AutoConfigureBefore` / `@AutoConfigureAfter` 控制顺序

### 坑 3：传递依赖污染业务

新人在 starter 里引了 fastjson、jodatime 等大量依赖，业务方一引就背着 50 个 jar。

**修法**：
- 只声明必需的依赖
- 可选 / 大依赖用 `<optional>true</optional>`
- starter 自身不引 logback / commons 等业务方常用的（避免版本冲突）

### 坑 4：配置类被业务 `@ComponentScan` 扫描

```java
// 业务启动类
@SpringBootApplication(scanBasePackages = "com.myapp")    // 扫了 starter 的包
```

```java
// starter 里
package com.myapp.ratelimit;
@AutoConfiguration                  // ← 也是 @Configuration，会被扫到
public class RateLimitAutoConfiguration { ... }
```

**根因**：starter 的包名前缀和业务包前缀重合，被业务的 `@ComponentScan` 直接当组件扫描——这不会出错，但绕过了自动配置的 `@Conditional` 过滤，行为不可控。

**修法**：
- starter 用独立包前缀（`com.myappstarter.ratelimit`）
- 或在自动配置类避免 `@Component` / `@Service` 标注

### 坑 5：IDE 没有配置提示

业务方在 `application.yml` 里输入 `myapp.ratelimit.` 不弹出提示。

**修法**：starter 加 `spring-boot-configuration-processor` 依赖，编译时生成 `spring-configuration-metadata.json`。

### 坑 6：spring.factories 升级阵痛

老 starter 用 `spring.factories` 注册自动配置：

```properties
org.springframework.boot.autoconfigure.EnableAutoConfiguration=\
  com.myapp.ratelimit.config.RateLimitAutoConfiguration
```

业务方升级 Spring Boot 3.0 后，警告 + 不生效。
**修法**：迁移到 `META-INF/spring/.../AutoConfiguration.imports` 一行一个类名。

---

## 八、面试高频追问

**Q1：Starter 和自动配置类是什么关系？**
A：Starter 是"打包整合"——把依赖、自动配置、默认参数打成一个 jar；自动配置类是 Starter 的核心实现，**业务方拿到的"开箱即用"的 bean 来自这些自动配置类**。一个 starter 通常带 1-N 个 `XxxAutoConfiguration`。

**Q2：怎么写一个 Starter？**
A：5 步：① pom 聚合依赖（注意 optional）；② 写 `XxxProperties` 配置类，用 `@ConfigurationProperties`；③ 写 `XxxAutoConfiguration`，加 `@AutoConfiguration` + `@Conditional*` + `@ConditionalOnMissingBean`；④ 在 `META-INF/spring/.../AutoConfiguration.imports` 注册；⑤（可选）加配置元数据让 IDE 提示。

**Q3：Starter 的命名规约？**
A：官方 `spring-boot-starter-xxx`；第三方 `xxx-spring-boot-starter`。第三方不能用官方前缀，避免误导用户和命名冲突。

**Q4：Starter 怎么让业务方覆盖默认 bean？**
A：在自动配置类的 `@Bean` 方法上加 `@ConditionalOnMissingBean`——业务方写了自己的同类型 bean，自动配置就让位。

**Q5：自动配置类应该放哪个包？**
A：**独立包前缀**，避免被业务方 `@ComponentScan` 误扫。如 `com.myappstarter.ratelimit.config`，**不要** 和业务方常用前缀（`com.foo.app`）撞。

**Q6：Starter 之间有依赖怎么处理？**
A：在 starter 的 pom 里 `<dependency>` 直接引另一个 starter；自动配置类之间用 `@AutoConfigureBefore` / `@AutoConfigureAfter` 控制顺序。

**Q7：Spring Boot 3 的 Starter 和 2.x 的有什么不同？**
A：① 自动配置注册从 `spring.factories` 迁到 `META-INF/spring/.../AutoConfiguration.imports`；② Java 17+ baseline；③ Jakarta EE 9+（`javax.*` → `jakarta.*`）；④ `@AutoConfiguration` 替代 `@Configuration` 标记自动配置类（更明确）。

**Q8：写 Starter 的最佳实践？**
A：① 单一职责，一个 starter 解决一个领域问题；② 默认值合理，零配置可跑；③ `@ConditionalOnMissingBean` 让出；④ `optional=true` 控制传递依赖；⑤ 配置元数据让 IDE 友好；⑥ 独立包前缀避免被误扫；⑦ 给可观测能力（暴露 metric / 健康检查）。

---

## 九、答题模板（60 秒）

> Starter 是 Spring Boot 的"插件化"载体——**把组件需要的依赖、自动配置类、默认参数打成一个 jar**，业务方一行依赖就能用。
>
> **结构**：① pom 聚合传递依赖；② `XxxProperties` 用 `@ConfigurationProperties` 绑定配置；③ `XxxAutoConfiguration` 用 `@AutoConfiguration` + `@Conditional*` 决定是否生效；④ `META-INF/spring/...AutoConfiguration.imports` 注册自动配置类。
>
> **命名**：官方 `spring-boot-starter-xxx`，第三方 `xxx-spring-boot-starter`。
>
> **设计原则**：① 单一职责（一个 starter 一类问题）；② 默认值合理（零配置可跑）；③ `@ConditionalOnMissingBean` 让业务方覆盖；④ 重依赖标 `optional=true`；⑤ 包前缀和业务方分开；⑥ 加 `spring-boot-configuration-processor` 让 IDE 友好。
>
> **常见坑**：① imports 文件路径错；② 升级 Spring Boot 2.7+ 后旧的 `spring.factories` 警告；③ `@Conditional` 过滤导致 bean 没注册（用 `debug=true` 看 CONDITIONS REPORT 排查）；④ 多个 starter 注册同类型 bean 冲突。

---

## 十、相关文档

- 前置：[SpringBoot自动装配.md](SpringBoot自动装配.md) — `@EnableAutoConfiguration` 如何读取 imports 文件
- 前置：[SpringBoot启动流程.md](SpringBoot启动流程.md) — 自动配置在启动哪一步生效
- 配套：[IoC容器.md](IoC容器.md) — `@Configuration` 解析期
