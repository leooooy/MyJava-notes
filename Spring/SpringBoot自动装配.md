# Spring Boot 自动装配

> Spring Boot 的核心卖点。面试不仅问"是什么"，还会追问 **`spring.factories` 和 `AutoConfiguration.imports` 的差异、`@Conditional` 怎么实现的、自己怎么写一个 Starter**。
> 答得清这三个就是高级。

---

## 一、为什么有自动装配

Spring 时代写一个 Web + JPA 项目要做的事：

```xml
<!-- web.xml -->
<servlet>
    <servlet-name>dispatcher</servlet-name>
    <servlet-class>org.springframework.web.servlet.DispatcherServlet</servlet-class>
</servlet>

<!-- spring-mvc.xml -->
<mvc:annotation-driven/>
<context:component-scan base-package="com.foo"/>

<!-- spring-jpa.xml -->
<bean id="dataSource" class="...">
    <property name="url" value="jdbc:mysql://localhost:3306/db"/>
    ...
</bean>
<bean id="entityManagerFactory" .../>
<bean id="transactionManager" .../>
<tx:annotation-driven/>
```

每个新项目都重复一份 100+ 行的 XML。Spring Boot 的回答：**约定大于配置 + 自动装配**。引入 `spring-boot-starter-web`、`spring-boot-starter-data-jpa`，就自动有了：DispatcherServlet、嵌入式 Tomcat、JSON 转换、JPA、事务管理、连接池——零配置可跑。

> **核心思想**："如果你引入了某个 jar，那大概率你想用它的默认配置；如果不想用默认的，再覆盖。"

---

## 二、`@SpringBootApplication` 解构

```java
@Target(TYPE)
@Retention(RUNTIME)
@SpringBootConfiguration                  // 等价于 @Configuration
@EnableAutoConfiguration                  // ★ 自动装配的真正开关
@ComponentScan(...)                       // 默认从启动类所在包扫描
public @interface SpringBootApplication { ... }
```

三块拆开看：

| 注解 | 作用 |
| --- | --- |
| `@SpringBootConfiguration` | 标记当前类是配置类（同 `@Configuration`），可以包含 `@Bean` 方法 |
| `@EnableAutoConfiguration` | **自动装配开关**——本篇主角 |
| `@ComponentScan` | 扫描 `@Component` / `@Service` / `@Repository` / `@Controller`，默认范围是启动类所在包及其子包 |

---

## 三、`@EnableAutoConfiguration` 的实现链路

### 3.1 注解定义

```java
@Target(TYPE)
@Retention(RUNTIME)
@AutoConfigurationPackage                              // 把启动类所在包记下来（给 JPA 等用）
@Import(AutoConfigurationImportSelector.class)         // ★ 关键
public @interface EnableAutoConfiguration { ... }
```

### 3.2 `AutoConfigurationImportSelector` 干什么

它是 `DeferredImportSelector` 的实现——会在 `@Configuration` 解析的最后阶段被调用，返回一组类名，Spring 会把这些类当作 `@Configuration` 处理。

```java
public class AutoConfigurationImportSelector implements DeferredImportSelector {
    
    public String[] selectImports(AnnotationMetadata metadata) {
        AutoConfigurationEntry entry = getAutoConfigurationEntry(metadata);
        return StringUtils.toStringArray(entry.getConfigurations());
    }
    
    protected AutoConfigurationEntry getAutoConfigurationEntry(AnnotationMetadata metadata) {
        // 1. 读取所有候选自动配置类（key 步骤）
        List<String> configurations = getCandidateConfigurations(metadata, attributes);
        // 2. 去重
        configurations = removeDuplicates(configurations);
        // 3. 排除（@SpringBootApplication(exclude=...) 或 spring.autoconfigure.exclude）
        Set<String> exclusions = getExclusions(metadata, attributes);
        configurations.removeAll(exclusions);
        // 4. 按 @Conditional 过滤一遍（提前过滤，减少后续计算）
        configurations = getConfigurationClassFilter().filter(configurations);
        // 5. 触发 AutoConfigurationImportEvent（用于 Spring Boot Actuator 报告）
        fireAutoConfigurationImportEvents(configurations, exclusions);
        return new AutoConfigurationEntry(configurations, exclusions);
    }
}
```

### 3.3 候选类从哪里读？

**Spring Boot 2.7 之前**：

```properties
# spring-boot-autoconfigure-2.6.x.jar/META-INF/spring.factories
org.springframework.boot.autoconfigure.EnableAutoConfiguration=\
  org.springframework.boot.autoconfigure.web.servlet.WebMvcAutoConfiguration,\
  org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration,\
  org.springframework.boot.autoconfigure.data.jpa.JpaRepositoriesAutoConfiguration,\
  ...
```

**Spring Boot 2.7+ / 3.x**：

```
# spring-boot-autoconfigure-3.x.jar/META-INF/spring/
#   org.springframework.boot.autoconfigure.AutoConfiguration.imports
org.springframework.boot.autoconfigure.web.servlet.WebMvcAutoConfiguration
org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration
org.springframework.boot.autoconfigure.data.jpa.JpaRepositoriesAutoConfiguration
```

**为什么 2.7+ 改了**：
- ① `spring.factories` 一个文件存所有类型的扩展（Listener、Initializer、AutoConfig 混在一起）→ 改成专用文件
- ② 旧格式按 `=` 分割 + 反斜杠续行 → 新格式一行一个，更清晰
- ③ 新格式 IDE 能高亮和跳转

> **兼容性**：Spring Boot 2.7+ 仍兼容旧格式（启动时会有 deprecation 警告），3.0+ 完全移除。

---

## 四、`@Conditional` 系列：决定哪些自动配置生效

光读到候选类还不够——很多场景需要 **"只有特定条件满足才生效"**。比如 `DataSourceAutoConfiguration` 只在 classpath 有 `DataSource` 类时才生效。

### 4.1 常用条件注解

| 注解 | 含义 |
| --- | --- |
| `@ConditionalOnClass(name)` | classpath 上**有**指定类才生效 |
| `@ConditionalOnMissingClass` | 没有指定类才生效 |
| `@ConditionalOnBean` | 容器里**已有**指定 bean 才生效 |
| `@ConditionalOnMissingBean` | 容器里**没有**指定 bean 才生效（最常用！） |
| `@ConditionalOnProperty(name, havingValue, matchIfMissing)` | 配置项满足条件才生效 |
| `@ConditionalOnWebApplication(type)` | 是 Web 应用才生效 |
| `@ConditionalOnNotWebApplication` | 不是 Web 应用才生效 |
| `@ConditionalOnExpression` | SpEL 表达式 |
| `@ConditionalOnResource` | classpath 上有指定资源 |

### 4.2 经典示例：`DataSourceAutoConfiguration`

```java
@AutoConfiguration
@ConditionalOnClass({ DataSource.class, EmbeddedDatabaseType.class })  // 有 DataSource 类
@ConditionalOnMissingBean(type = "io.r2dbc.spi.ConnectionFactory")     // 没注 R2DBC
@AutoConfigureBefore(SqlInitializationAutoConfiguration.class)
@EnableConfigurationProperties(DataSourceProperties.class)             // 把 spring.datasource.* 映射到对象
@Import({ DataSourcePoolMetadataProvidersConfiguration.class, ... })
public class DataSourceAutoConfiguration {
    
    @Configuration
    @Conditional(EmbeddedDatabaseCondition.class)            // h2 / hsql 这些内嵌库
    @ConditionalOnMissingBean({ DataSource.class, XADataSource.class })  // 用户没自定义 DataSource
    @Import(EmbeddedDataSourceConfiguration.class)
    protected static class EmbeddedDatabaseConfiguration { }
    
    @Configuration
    @Conditional(PooledDataSourceCondition.class)
    @ConditionalOnMissingBean({ DataSource.class, XADataSource.class })  // ★ 用户自定义就跳过
    @Import({ HikariJpa..., TomcatPool..., DbcpPool... })
    protected static class PooledDataSourceConfiguration { }
}
```

> **`@ConditionalOnMissingBean` 是自动装配的灵魂**——它意味着"我提供默认实现，但用户自己写一个我就让位"。这是 Spring Boot **可覆盖默认值** 思想的代码体现。

### 4.3 `@ConditionalOnProperty` 经典用法

```java
@AutoConfiguration
@ConditionalOnProperty(prefix = "myapp.cache", name = "enabled", havingValue = "true")
public class MyCacheAutoConfiguration {
    @Bean
    public CacheService cacheService() { ... }
}
```

```yaml
myapp:
  cache:
    enabled: true        # 这一行决定是否启用
```

`matchIfMissing = true` 时表示"**没配置也算满足**"——更适合默认开启的场景。

---

## 五、写一个自定义 Starter（生产经验）

需求：写一个 `myapp-encrypt-spring-boot-starter`，自动装配一个 `EncryptService`，业务方只要引依赖就能注入用。

### 5.1 项目结构

```
myapp-encrypt-spring-boot-starter/
├── src/main/java/com/myapp/encrypt/
│   ├── EncryptService.java                         ← 核心服务
│   ├── EncryptProperties.java                      ← 配置类（@ConfigurationProperties）
│   └── EncryptAutoConfiguration.java               ← ★ 自动配置类
└── src/main/resources/
    └── META-INF/spring/
        └── org.springframework.boot.autoconfigure.AutoConfiguration.imports
```

### 5.2 `imports` 文件

```
com.myapp.encrypt.EncryptAutoConfiguration
```

### 5.3 配置类

```java
@ConfigurationProperties(prefix = "myapp.encrypt")
@Data
public class EncryptProperties {
    private String algorithm = "AES";
    private String key;
}
```

### 5.4 自动配置类

```java
@AutoConfiguration
@ConditionalOnClass(Cipher.class)                              // JDK 自带，必有
@EnableConfigurationProperties(EncryptProperties.class)
@ConditionalOnProperty(prefix = "myapp.encrypt", name = "key") // 没配 key 就不装
public class EncryptAutoConfiguration {
    
    @Bean
    @ConditionalOnMissingBean                                   // 用户自定义就让位
    public EncryptService encryptService(EncryptProperties props) {
        return new EncryptService(props.getAlgorithm(), props.getKey());
    }
}
```

### 5.5 业务方使用

```yaml
myapp:
  encrypt:
    key: "ABC123"
```

```java
@Service
public class UserService {
    @Resource private EncryptService encryptService;
    
    public String encrypt(String plain) {
        return encryptService.encrypt(plain);
    }
}
```

### 5.6 命名规约

- **官方 Starter**：`spring-boot-starter-{name}`
- **第三方 Starter**：`{name}-spring-boot-starter`（**不要冒充官方**）

---

## 六、自动配置的执行顺序

### 6.1 `@AutoConfigureBefore` / `@AutoConfigureAfter` / `@AutoConfigureOrder`

```java
@AutoConfiguration
@AutoConfigureAfter(DataSourceAutoConfiguration.class)   // DataSource 装好后再装我
@AutoConfigureBefore(JpaRepositoriesAutoConfiguration.class)  // 在 JPA 之前装好
public class HibernateJpaAutoConfiguration { ... }
```

### 6.2 实际生效顺序（拓扑排序）

Spring Boot 把所有自动配置类按依赖关系做拓扑排序：

```
① 没有依赖的最先（如基础设施类的 PropertyPlaceholderAutoConfiguration）
② 数据源相关（DataSourceAutoConfiguration）
③ ORM（JpaRepositoriesAutoConfiguration）
④ Web（WebMvcAutoConfiguration）
⑤ 业务上层
```

**调试方法**：开 `debug=true` 启动，会打印 `CONDITIONS EVALUATION REPORT`，列出哪些自动配置生效、哪些被排除、原因是什么。

---

## 七、生产踩坑

### 坑 1：自定义 Starter 不生效

新写的 Starter 引到业务项目后，bean 没注册。

**排查清单**：
1. ❌ `imports` 文件路径错——必须是 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`，**多一个空格、少一个目录都不行**
2. ❌ Maven `mvn clean install` 没执行——本地 jar 没打出来
3. ❌ 自动配置类被 `@Conditional*` 排除——开 `debug=true` 看 CONDITIONS EVALUATION REPORT
4. ❌ Starter 被 `@SpringBootApplication(exclude=...)` 排除了
5. ❌ 自动配置类被 `@ComponentScan` 扫到了（你不该让 starter 类被业务方扫到）

### 坑 2：自动配置和业务配置冲突

业务方自己写了一个 `RedisTemplate` 的 `@Bean`，但启动后用的还是自动装配的那个。

**根因**：`@ConditionalOnMissingBean` 是按 **类型** 判断，但顺序很关键——**业务的 `@Configuration` 通常在自动配置之前解析**，所以自动配置看到业务已有 bean 时会让位。如果反过来，业务 bean 还没解析时自动配置已经生效，就会冲突。

**修法**：
- 业务方在自己的 `@Bean` 上加 `@Primary`，或显式覆盖
- 检查启动顺序，确保业务配置类被优先扫到

### 坑 3：升级 Spring Boot 2.7+ Starter 报警告

```
Use of META-INF/spring.factories for AutoConfiguration is deprecated
```

**修法**：把 `spring.factories` 里的 `EnableAutoConfiguration` 项搬到新格式文件：

```
src/main/resources/META-INF/spring/
  org.springframework.boot.autoconfigure.AutoConfiguration.imports
```

每行一个全限定类名。其他类型（Listener / Initializer）保留在 `spring.factories`。

### 坑 4：`@ConfigurationProperties` 不生效

```java
@ConfigurationProperties(prefix = "myapp")
public class MyProps { ... }
```

业务里 `@Autowired MyProps`，启动报 No bean。
**根因**：`@ConfigurationProperties` 类必须用 `@EnableConfigurationProperties(MyProps.class)` 注册，**或者** 类上加 `@Component`（推荐前者，解耦）。

### 坑 5：starter 模块体积膨胀

新人写的 starter 直接依赖了 30 个 jar——业务方一引就背着 30 个传递依赖。

**修法**：starter 应该只依赖 **它自己的 API + 必要的运行时**，可选依赖用 `<optional>true</optional>`。

```xml
<dependency>
    <groupId>com.example</groupId>
    <artifactId>some-optional-lib</artifactId>
    <optional>true</optional>     <!-- 业务方需要时自己引 -->
</dependency>
```

---

## 八、面试高频追问

**Q1：`@SpringBootApplication` 等价于什么？**
A：`@SpringBootConfiguration` + `@EnableAutoConfiguration` + `@ComponentScan`。前者是 `@Configuration`、第二个是自动装配开关、第三个扫描组件。

**Q2：`@EnableAutoConfiguration` 怎么实现的？**
A：通过 `@Import(AutoConfigurationImportSelector.class)` 引入一个 `DeferredImportSelector`。它在 `@Configuration` 解析的最后阶段被调用，从 `META-INF/spring/.../AutoConfiguration.imports`（2.7+）读取所有候选自动配置类，过滤掉用户排除的，再按 `@Conditional*` 筛选，最终把保留的类作为 `@Configuration` 处理。

**Q3：`spring.factories` 和 `AutoConfiguration.imports` 区别？**
A：
- `spring.factories`：旧格式，多种扩展类型混在一起（Listener / Initializer / AutoConfig 等），按 `=` 分割。仍用于非自动配置的扩展点。
- `AutoConfiguration.imports`：Spring Boot 2.7+ 引入，**专用于自动配置类**，一行一个全限定类名。3.0+ 完全替代旧格式中的 `EnableAutoConfiguration` 项。

**Q4：自动配置怎么排除？**
A：3 种方式：
- `@SpringBootApplication(exclude = DataSourceAutoConfiguration.class)`
- `@SpringBootApplication(excludeName = "...")`
- `application.yml`：`spring.autoconfigure.exclude=...`

**Q5：`@Conditional` 怎么实现的？**
A：所有 `@ConditionalOnXxx` 注解都关联一个 `Condition` 实现类，框架在解析 `@Configuration` 时调 `Condition.matches(ConditionContext, AnnotatedTypeMetadata)`，返回 false 就跳过这个 `@Bean` 或 `@Configuration`。

**Q6：`@ConditionalOnMissingBean` 的判断时机是什么？**
A：在 `@Configuration` 解析期判断——根据当前 BeanDefinition 注册表里有没有指定类型的 BD。**不是** 等 bean 实例化才判断。这就是为什么自动配置类的执行顺序很重要——后注册的看不到先注册的。

**Q7：怎么自己写一个 Starter？**
A：①  新建模块，按命名规约 `xxx-spring-boot-starter`；② 写 `XxxAutoConfiguration` 类，加 `@AutoConfiguration` 和 `@Conditional*`；③ 写 `XxxProperties` 配置类，配 `@EnableConfigurationProperties`；④ 在 `META-INF/spring/.../AutoConfiguration.imports` 注册自动配置类；⑤ 注意 `@ConditionalOnMissingBean` 让出业务自定义。

**Q8：怎么调试自动配置生效情况？**
A：开 `debug=true` 启动，控制台会打印 `CONDITIONS EVALUATION REPORT`：
```
Positive matches:           哪些自动配置生效了
Negative matches:           哪些没生效，每个都附带原因（如某类不存在）
Exclusions:                 用户主动排除的
Unconditional classes:      无条件加载的（罕见）
```
**线上排查必备**。

---

## 九、答题模板（60 秒）

> Spring Boot 自动装配 = `@SpringBootApplication` 中的 `@EnableAutoConfiguration` + `@Conditional` + `META-INF` 配置文件。
>
> **流程**：① `@EnableAutoConfiguration` 通过 `@Import(AutoConfigurationImportSelector.class)` 引入选择器；② 选择器读取 **`META-INF/spring/...AutoConfiguration.imports`**（Spring Boot 2.7+，旧版用 `spring.factories`），拿到所有候选自动配置类；③ 按 `@Conditional*` 过滤——`@ConditionalOnClass`、`@ConditionalOnMissingBean`、`@ConditionalOnProperty` 等决定哪些真正生效；④ 留下来的当作 `@Configuration` 解析、注册 `@Bean`。
>
> **核心思想**：约定大于配置，**`@ConditionalOnMissingBean` 让自动装配可以被业务覆盖**——框架提供默认实现，业务自己写就让位。
>
> **写自定义 Starter** 三件事：① 写 `XxxAutoConfiguration` 加条件注解；② 配 `XxxProperties` 用 `@ConfigurationProperties`；③ 在 `META-INF/spring/.../AutoConfiguration.imports` 注册。命名第三方用 `xxx-spring-boot-starter`（不冒充官方）。
>
> **调试**：`debug=true` 启动，看 `CONDITIONS EVALUATION REPORT` 看每个自动配置生效与否的原因。

---

## 十、相关文档

- 前置：[SpringBoot启动流程.md](SpringBoot启动流程.md) — `AutoConfigurationImportSelector` 何时被调用
- 配套：[Starter机制.md](Starter机制.md) — Starter 包的组织
- 配套：[IoC容器.md](IoC容器.md) — `@Configuration` 解析期发生在 `refresh()` 第 5 步
