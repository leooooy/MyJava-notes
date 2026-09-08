# SLF4J 绑定排查实录：从 kubectl logs 看不到业务日志 到 传递依赖里的 logback 抢走 SLF4J binder

> 一次真实的 Spring Cloud 微服务生产日志故障排查。
> 表象是 cms 服务 `kubectl logs` **看不到业务 INFO 日志**，同期发布的 mybill 完全正常，最终定位到 **新引入的图片处理库 `scrimage-webp` 传递依赖里塞了 `logback-classic`，抢走了 SLF4J binder，把项目自带的 `log4j2-prod.xml` 整份配置废掉**。
>
> 本篇覆盖：现象 → 第一刀「日志格式对比」→ 第二刀「SLF4J 启动告警」→ 第三刀「dependency:tree」→ 底层原理（SLF4J 多绑定机制 / Spring Boot logback 默认配置）→ 修复 → 顺带踩到的两个坑（误判双同名 AsyncLogger、`System.out.println` 漏网）→ 排查思路复盘 → 预防方案。

---

## 一、现象

cms 服务部署到 EKS preprod 集群后：

- `kubectl logs -f cms-deploy-xxx` 只能看到 Spring Boot 启动那几行，之后业务 INFO 日志**全部消失**
- HTTP 接口能正常返回 → 服务**没挂**，只是看不见日志
- 同一天发布的 mybill 服务、用的同一套日志模板（`log4j2-prod.xml`），`kubectl logs` 完全正常

cms 日志摘要：

```
SLF4J: Class path contains multiple SLF4J bindings.
SLF4J: Found binding in [...logback-classic-1.2.9.jar...]
SLF4J: Found binding in [...log4j-slf4j-impl-2.17.0.jar...]
SLF4J: Actual binding is of type [ch.qos.logback.classic.util.ContextSelectorStaticBinder]
[INFO ] [2026-05-28 12:13:14] [background-preinit] ==> HV000001: Hibernate Validator 6.2.0.Final

  ...Spring Boot banner...

2026-05-28 12:13:15.678  INFO 1 --- [           main] c.a.n.c.c.impl.LocalConfigInfoProcessor  : LOCAL_SNAPSHOT_PATH:/root/nacos/config
2026-05-28 12:13:15.769  INFO 1 --- [           main] c.a.nacos.client.config.impl.Limiter     : limitTime:5.0
... 之后业务日志一片空白 ...
{"popup":false,"latestVersion":"2.44.0","needUpdate":false, ...}   ← 还有裸 JSON 在刷
```

mybill 日志摘要：

```
[INFO ] [2026-05-28 12:00:40] [background-preinit] ==> HV000001: Hibernate Validator 6.2.0.Final
[INFO ] [2026-05-28 12:00:41] [main] ==> LOCAL_SNAPSHOT_PATH:/root/nacos/config
... 业务 INFO + DEBUG SQL 全部正常 ...
[INFO ] [2026-05-28 12:04:29] [http-nio-9003-exec-1] ==> 开始请求, ip=3.101.27.217, url=/offerActivity/getAvailableActivityList
```

**最反常的细节**：cms 的日志里出现**两种完全不同格式**：

- `[INFO ] [2026-05-28 12:13:14] [background-preinit] ==>`（背景预初始化阶段）
- `2026-05-28 12:13:15.678  INFO 1 --- [           main] c.a.n.c.c.impl ...`（Spring Boot 启动后）

格式不一致本身就是异常信号。

---

## 二、第一刀：日志格式对比 — 30 秒锁定"配置没生效"

观察两台服务的日志格式：

| 服务 | 日志格式 | 来源 |
| --- | --- | --- |
| mybill | `[INFO ] [2026-05-28 12:00:40] [main] ==> ...` | `log4j2-prod.xml` 里定义的 `LOG_PATTERN`：<br>`[%-5p] [%d{YYYY-MM-dd HH:mm:ss}] [%t] ==> %msg%n` |
| cms | `2026-05-28 12:13:15.678  INFO 1 --- [ main] c.a.n.c.c.impl ... : ...` | **Spring Boot logback 默认 pattern**：<br>`%d{yyyy-MM-dd HH:mm:ss.SSS} %5p ${PID} --- [%t] %-40.40logger{39} : %m%n` |

格式不一致 → 说明 cms 用的根本不是项目自带的 `log4j2-prod.xml`，是 Spring Boot 的 logback 默认配置（`base.xml`）。

**这一刀的价值**：直接绕开"是不是 logger level 配低了 / appender 没引 / profile 没生效"这一长串猜测。比对完格式就知道**整份 Log4j2 配置都没被加载**，问题在更上游。

> 💡 心得：发现日志异常时，先看日志**格式**而不是看日志**内容**。格式是日志框架"身份证"，比 logger 配置更接近根因。
>
> 常见的格式特征：
> - logback 默认（Spring Boot base.xml）：`%d %5p ${PID} --- [%t] %-40.40logger{39} : %m%n`，最显眼的是 ` --- [` 这部分
> - log4j2 项目自定义：通常带方括号和 `==>` 分隔符
> - JUL（java.util.logging）：`月份 日, 年份 时:分:秒 类.方法\n级别: 消息`，两行式
> - System.out.println：完全裸文本，无任何前缀

---

## 三、第二刀：SLF4J 启动告警是铁证

回头细看 cms 启动日志最前面 4 行，本来以为是"无害警告"，其实是**完整答案**：

```
SLF4J: Class path contains multiple SLF4J bindings.
SLF4J: Found binding in [jar:file:/metaxsire/cms-service.jar!/BOOT-INF/lib/logback-classic-1.2.9.jar!/org/slf4j/impl/StaticLoggerBinder.class]
SLF4J: Found binding in [jar:file:/metaxsire/cms-service.jar!/BOOT-INF/lib/log4j-slf4j-impl-2.17.0.jar!/org/slf4j/impl/StaticLoggerBinder.class]
SLF4J: Actual binding is of type [ch.qos.logback.classic.util.ContextSelectorStaticBinder]
```

三个关键信息：

1. **`Class path contains multiple SLF4J bindings`** — jar 里同时有两个 SLF4J 实现
2. **两条 `Found binding in`** — 列出所有竞争者：`logback-classic-1.2.9.jar` 和 `log4j-slf4j-impl-2.17.0.jar`
3. **`Actual binding is of type [...logback...]`** — **最终绑了 logback**，是确定的、不用猜

第三行直接坐实：cms 进程里 SLF4J → logback，跟项目用的 log4j2 没关系了。`log4j2-prod.xml` 里写的所有 logger 配置、appender、pattern 全部失效。

> 💡 这条 `Actual binding is of type` 是 SLF4J 1.x 的"自检接口"，等同于让 JVM 自己告诉你"我用的是谁"。看到 SLF4J 多绑定警告**永远不要忽略**，本质上就是埋雷。

### SLF4J 2.x 的变化（顺带说一句）

SLF4J 2.0+ 改用 `ServiceLoader` 机制加载 `org.slf4j.spi.SLF4JServiceProvider`，启动告警形式变了：

```
SLF4J: Class path contains SLF4J bindings targeting slf4j-api versions 1.7.x or earlier.
SLF4J: Ignoring binding found at [...]
SLF4J(I): Actual provider is of type [...]
```

但**"多绑定 → 谁赢取决于发现顺序"的本质没变**，只是 SPI 接口换了一层。

---

## 四、第三刀：`mvn dependency:tree` 定位污染源

确认 logback-classic 不该出现后，找谁拖进来的：

```bash
mvn dependency:tree -Dincludes=ch.qos.logback -Ppreprod -pl :cms-service
```

输出：

```
[INFO] Building cms-service 1.0.0
[INFO]  \- com.sksamuel.scrimage:scrimage-webp:jar:4.0.39:compile
[INFO]     +- ch.qos.logback:logback-core:jar:1.2.9:runtime  (version managed from 1.1.2)
[INFO]     \- ch.qos.logback:logback-classic:jar:1.2.9:runtime
```

凶手是最近为 wiki 模块新加的 `com.sksamuel.scrimage:scrimage-webp:4.0.39`。`version managed from 1.1.2` 这个细节顺便说明：本来 scrimage 想拉的是 1.1.2，被项目里 dependencyManagement 锁版本到了 1.2.9，但**完全没有排除**。

加 `-Dverbose=true` 可以看完整链路（被忽略的传递依赖也显示）：

```bash
mvn dependency:tree -Dverbose -Dincludes=ch.qos.logback -Ppreprod -pl :cms-service
```

### IDEA 等价操作（不想敲命令行）

IDEA 2022.3+ 内置 **Dependency Analyzer**，比 `dependency:tree` 命令更直观。注意它**不是独立的 Tool Window**（在 `View → Tool Windows` 里找不到），只能从 Maven 工具窗口的工具栏唤起：

#### 入口：Maven 工具窗口 → Analyze Dependencies

```
1. Alt+9 切到工具窗口区域，再点右侧 Maven 图标（或直接点 IDEA 右侧栏的 m 图标）打开 Maven 工具窗口
2. Maven 工具窗口顶部工具栏找放大镜图标 🔍，鼠标悬停 tooltip 是 "Analyze Dependencies..."
3. 点击，左侧分屏出现 "Dependency Analyzer" 面板
```

也可以从 `pom.xml` 右键 → **Maven → Analyze Dependencies...**（同一个入口的不同触发路径）。

#### Dependency Analyzer 面板布局

```
┌────────────────────────────────┬─────────────────────────────┐
│ Dependency Analyzer            │                             │
│ ─────────────────────          │                             │
│ [cms-service ▾]  [Q logback]   │  Usages of logback-classic  │
│ Scope: Any ▾                   │                             │
│                                │   cms-service               │
│ Resolved Dependencies          │     └ scrimage-webp:4.0.39  │
│   logback-classic:1.2.9 ◀━━━━━━│        └ logback-classic:1.2.9
│   logback-core:1.2.9           │                             │
│   log4j-slf4j-impl:2.17.0      │                             │
│   ...                          │                             │
└────────────────────────────────┴─────────────────────────────┘
```

- **左上模块下拉**：选要分析的模块（cms-service / mybill-service / ...）
- **搜索框**：输入关键字过滤，例如 `logback` 把所有 logback 相关 artifact 都列出来
- **Scope 下拉**：可以筛 compile / runtime / test / provided 等
- **告警按钮**（黄色三角）：只看版本冲突项；冲突项左侧自动标红
- **左侧列表**：当前模块解析后的全部依赖（`Resolved Dependencies`），点中其中一项
- **右侧面板 `Usages of X`**：自动展开**从根模块到该依赖的完整传递路径**（树形展示），等价于 `mvn dependency:tree -Dincludes=X`

#### 这次场景的最快路径（4 步定位污染源）

```
1. 打开 Maven 工具窗口 → 点 "Analyze Dependencies..." 放大镜图标
2. 模块下拉选 cms-service
3. 搜索框输 logback
4. 点中 logback-classic → 右侧 "Usages of logback-classic" 直接显示：
   cms-service
     └ scrimage-webp:4.0.39
        └ logback-classic:1.2.9
```

#### IDEA vs 命令行的取舍

| 场景 | 推荐方式 |
| --- | --- |
| 本地日常排查、来回试不同 scope / 关键字 | **IDEA Dependency Analyzer**（交互、快、可视） |
| CI / 远程容器 / 没装 IDEA 的环境 | `mvn dependency:tree -Dincludes=X` |
| 需要把完整传递链贴到 PR / 文档 | `mvn dependency:tree -Dverbose -Doutput=tree.txt`（输出可直接复制） |
| 看依赖图谱（节点 + 连线可视化） | `Ctrl+Alt+Shift+U`，或 `pom.xml` 右键 → **Diagrams → Show Dependencies** |
| 只看模块层级 / 项目结构 | Maven 工具窗口 → 展开 `Dependencies` 节点（每个 IDEA 版本都有，最朴素） |

---

## 五、根因：SLF4J 多绑定机制

### 5.1 SLF4J 1.x 是怎么决定"用谁"的

SLF4J 1.x 通过 **classpath 上唯一的 `org/slf4j/impl/StaticLoggerBinder.class`** 决定绑定哪个实现。每个实现 jar（`logback-classic`、`log4j-slf4j-impl`、`slf4j-simple` 等）都自己提供一份 `StaticLoggerBinder.class`，**故意冲突**。

正常项目应该保证 classpath 里只有一个。如果有多个，SLF4J 在 `LoggerFactory.bind()` 里调用 `Class.forName("org.slf4j.impl.StaticLoggerBinder")` —— 由 ClassLoader 决定加载哪一个，**先到先得**。

| ClassLoader 行为 | 谁的 StaticLoggerBinder 被加载 |
| --- | --- |
| 标准 `URLClassLoader` | 按 classpath URL 顺序，第一个找到的 jar 赢 |
| Spring Boot `LaunchedURLClassLoader` | 按 `BOOT-INF/lib/*.jar` 的**字典序**遍历 |
| Tomcat `WebappClassLoader` | parent-first 或 web-first，看配置 |

**所以"谁赢"高度依赖运行环境**：

- 本地 IDE 跑：classpath 顺序可能跟 fat-jar 不同 → IDE 里 log4j2 赢、容器里 logback 赢，**本地复现不了**
- 不同版本的 Spring Boot Loader：`LaunchedURLClassLoader` 的实现细节有过变化，jar 顺序可能不同
- fat-jar repackage：jar 文件名字典序就是关键

### 5.2 cms 这次为什么是 logback 赢

fat-jar `BOOT-INF/lib/` 下：

- `logback-classic-1.2.9.jar` 字典序排在
- `log4j-slf4j-impl-2.17.0.jar` 前面

Spring Boot `LaunchedURLClassLoader` 优先扫到 logback-classic，`StaticLoggerBinder` 来自 logback。后面遇到 log4j-slf4j-impl 里的同名类，被 ClassLoader 的双亲委派/同名类规则忽略。

### 5.3 logback 绑了之后会怎么找配置

logback 启动时按以下顺序找配置文件：

| 优先级 | 位置 | 备注 |
| --- | --- | --- |
| 1 | `logback.configurationFile` 系统属性指向的文件 | |
| 2 | classpath 根目录 `logback-test.xml` | 测试场景 |
| 3 | classpath 根目录 `logback.xml` | 标准位置 |
| 4 | Spring Boot 的 `logback-spring.xml` | Spring Boot 扩展，支持 `<springProfile>` |
| 5 | 都没有 → 用 Spring Boot 内置的 `base.xml` 兜底 | console appender，root=INFO |

cms 项目里有 `log4j2-prod.xml` 但**没有任何 logback 配置文件** → logback 走 Spring Boot `base.xml` → console pattern 是默认的 `%d %5p ${PID} --- [%t] %-40.40logger{39} : %m%n` —— 完美匹配观察到的 cms 日志格式。

### 5.4 为什么 mybill 没事

横向对比 mybill 的 `dependency:tree`，**没有任何 logback 依赖**。它的 SLF4J 唯一 binder 是 `log4j-slf4j-impl`，自然加载 `log4j2-prod.xml`，工作正常。

mybill 跟 cms 用的是**完全一样的日志模板**，唯一差异就是 cms 多了个带 logback 的 `scrimage-webp` —— **横向对比是这类故障最快的判定路径**。

---

## 六、修复方案

### 治标：在引入处排除 logback

```xml
<dependency>
    <groupId>com.sksamuel.scrimage</groupId>
    <artifactId>scrimage-webp</artifactId>
    <version>4.0.39</version>
    <exclusions>
        <exclusion>
            <groupId>org.slf4j</groupId>
            <artifactId>slf4j-simple</artifactId>
        </exclusion>
        <!-- 排除 logback，避免 SLF4J 绑定覆盖 log4j2 导致 log4j2-prod.xml 失效 -->
        <exclusion>
            <groupId>ch.qos.logback</groupId>
            <artifactId>logback-classic</artifactId>
        </exclusion>
        <exclusion>
            <groupId>ch.qos.logback</groupId>
            <artifactId>logback-core</artifactId>
        </exclusion>
    </exclusions>
</dependency>
```

验证：

```bash
mvn dependency:tree -Dincludes=ch.qos.logback -Ppreprod -pl :cms-service
# 应该没有任何输出（除了 Building 那一行）
```

重新打镜像部署后日志立刻恢复正常。

### 治本：CI 兜底，防止类似依赖污染再发生

**1）Maven Enforcer Plugin 的 `bannedDependencies` 规则**

在 root `pom.xml` 配：

```xml
<plugin>
    <groupId>org.apache.maven.plugins</groupId>
    <artifactId>maven-enforcer-plugin</artifactId>
    <executions>
        <execution>
            <id>enforce-banned-dependencies</id>
            <goals>
                <goal>enforce</goal>
            </goals>
            <configuration>
                <rules>
                    <bannedDependencies>
                        <searchTransitive>true</searchTransitive>
                        <excludes>
                            <!-- 项目统一用 log4j2，任何模块都不准引入 logback -->
                            <exclude>ch.qos.logback:*</exclude>
                            <!-- 顺带禁掉常见的 SLF4J 双绑定来源 -->
                            <exclude>org.slf4j:slf4j-simple</exclude>
                            <exclude>org.slf4j:slf4j-jdk14</exclude>
                            <exclude>org.slf4j:slf4j-jcl</exclude>
                            <exclude>commons-logging:commons-logging</exclude>
                        </excludes>
                    </bannedDependencies>
                </rules>
                <fail>true</fail>
            </configuration>
        </execution>
    </executions>
</plugin>
```

任何模块的传递依赖里引入 logback，构建直接失败 —— 比代码 review 靠谱。

**2）PR 模板加一条 checklist**

> 引入新的第三方依赖时，必须贴一段 `mvn dependency:tree -Dincludes=ch.qos.logback,org.apache.logging.log4j,org.slf4j,commons-logging` 输出到 PR 描述。

**3）观测兜底：监控 SLF4J 多绑定告警**

容器日志采集到 ELK 后，告警规则：

```
match: "SLF4J: Class path contains multiple SLF4J bindings"
level: WARN
notify: 后端值班群
```

新服务部署后第一次启动时如果撞到，5 分钟内就能定位 —— 不用等业务方反馈"看不到日志"。

---

## 七、顺带踩到的两个坑

### 坑 1：误判 `log4j2-prod.xml` 里的双同名 AsyncLogger 是根因

排查初期看 `log4j2-prod.xml`，发现项目里**两个同名 `<AsyncLogger name="com.metaxsire">`**：

```xml
<!-- 第一个：info 级别，console + file_log -->
<AsyncLogger name="com.metaxsire" additivity="false" level="info">
    <AppenderRef ref="console"/>
    <AppenderRef ref="file_log"/>
</AsyncLogger>

<!-- 第二个：error 级别，LOG_HOME + console -->
<AsyncLogger name="com.metaxsire" level="error" additivity="false" includeLocation="true">
    <AppenderRef ref="LOG_HOME"/>
    <AppenderRef ref="console"/>
</AsyncLogger>
```

凭直觉判定"后者覆盖前者，level 被改成 error，INFO 被吞" —— **错误判断**。

**反证**：mybill 用的是同一份模板（双 AsyncLogger 写法一样），它的 INFO 业务日志和 DEBUG SQL 都正常输出。说明 Log4j2 实际行为是**同名 logger 的 AppenderRef 会合并**，并不会简单覆盖 level。

**心得**：排查时**横向对比是先于深挖配置文件的**。如果两个相似服务用同一份配置，一好一坏，问题大概率不在配置上而在外部环境（依赖、JVM 参数、profile、网络）。

### 坑 2：`System.out.println` 漏在线上，刷裸 JSON 到 stdout

修依赖之前，cms 日志里还在持续刷：

```
{"popup":false,"latestVersion":"2.44.0","needUpdate":false,"forceUpdate":false,"upgradeLog":"..."}
{"popup":true,"latestVersion":"2.45.0",...}
{"popup":false,...}
```

裸 JSON，没有时间戳、没有日志级别、没有线程名 —— 是 `System.out.println` 直接打到 stdout。

`grep` 后定位到 `VersionCheckService.java:112`：

```java
jsonObject.put("upgradeLog", i18n.t(appVersion.getUpgradeLog()));
if (needUpdate) {
    jsonObject.put("downloadUrl", appVersion.getDownloadUrl());
}
System.out.println(jsonObject);   // ← 调试代码漏在了线上
return ResponseResult.success(jsonObject);
```

类似的还有 `LiteAppVersionController.java:116`、`AppVersionController.java:131`。

**预防**：靠 code review 拦不住，得用静态检查工具：

- **PMD** 规则 `SystemPrintln`
- **SpotBugs** 规则 `DM_DEFAULT_ENCODING` / `Dm: Method invokes System.out.println`
- **Checkstyle** 规则 `RegexpSinglelineJava` 自定义匹配 `System\.out\.println`

任何一个都能在 CI 阶段拦住。

---

## 八、排查思路复盘

| 步骤 | 动作 | 结论 |
| --- | --- | --- |
| 1 | 看日志格式（不看内容） | mybill 是 log4j2 pattern，cms 是 logback 默认 pattern → cms 配置整份失效 |
| 2 | 翻 cms 启动头 4 行 SLF4J 告警 | `Actual binding is of type [...logback...]` 直接坐实 |
| 3 | `mvn dependency:tree -Dincludes=ch.qos.logback` | 凶手 = `scrimage-webp:4.0.39` 拖进来的 logback-classic |
| 4 | 对比 mybill 没有这个依赖 | 横向对比印证根因 |
| 5 | pom 加 `<exclusion>` 排除 | 重新打包验证 SLF4J 告警消失、日志格式恢复 log4j2 pattern |
| 6 | CI 加 enforcer-plugin banned-dependencies | 治本，防类似事故再发生 |

**心得三条**：

1. **日志格式 = 日志框架身份证**。看不见业务日志时，先看 1 行启动 banner 的格式，比翻 logger 配置快一个数量级。
2. **SLF4J 启动告警永远不要忽略**。`Class path contains multiple SLF4J bindings` 是定时炸弹，迟早炸，本地复现不了 ≠ 没问题。
3. **横向对比 > 单机深挖**。两台同期发布的服务一台坏一台好，差异点（依赖、profile、JVM 参数）就是答案 —— 类比生产 SRE 里"哪个变量改变了，找它"。

---

## 九、SLF4J 多绑定相关的类比 / 同类坑

这种"传递依赖 + SPI 静默劫持"的故障模式，在 Java 生态里极其常见，本质都是 **classpath 上同一类型有多个实现，谁先到谁赢**：

| 故障家族 | SPI 接管点 | 典型踩坑 |
| --- | --- | --- |
| **SLF4J 多绑定**（本篇） | `org/slf4j/impl/StaticLoggerBinder.class` | logback / log4j2 / slf4j-simple 互抢 |
| **JDBC Driver 接管** | `META-INF/services/java.sql.Driver` | MySQL Connector/J 8 和 6 共存时 `DriverManager.getConnection()` 拿到错版本 |
| **JAXP / SAX/DOM 解析器接管** | `META-INF/services/javax.xml.parsers.*` | Xerces / Crimson / 内置 JDK 三方竞争 |
| **ImageIO 解码器接管** | `META-INF/services/javax.imageio.spi.*` | 上一个 commit 排除 TwelveMonkeys imageio-jpeg 就是这个原因 |
| **Apache HttpClient 自动注册** | `META-INF/services/...` | OkHttp / Apache HC5 共存时 RestTemplate 行为不确定 |
| **Spring Boot Starter 自动装配冲突** | `META-INF/spring.factories` / `META-INF/spring/...AutoConfiguration.imports` | 多个 starter 注册同名 bean |

通用预防套路：

1. 对每个**家族**列一份"项目唯一选型"清单（log4j2 / Driver 8.x / Xerces 内置 / ...）
2. 用 `enforcer-plugin` 的 `bannedDependencies` 把竞争者全 ban 掉
3. 引入新依赖时跑一遍 `mvn dependency:tree -Dverbose` 看完整传递链
4. CI 启动冒烟测试时，grep 启动日志的 SLF4J 告警 / SPI 警告，命中即 fail

---

## 十、参考

- [Maven 编译排查实录](Maven%20编译排查实录.md) — 同类风格的依赖 / 字节码排障复盘
- [Maven 私仓](Maven%20私仓.md)
- SLF4J 多绑定官方说明：[SLF4J Codes: multiple_bindings](http://www.slf4j.org/codes.html#multiple_bindings)
- Log4j2 SLF4J Bridge 文档：[Log4j 2 SLF4J Binding](https://logging.apache.org/log4j/2.x/log4j-slf4j-impl.html)
- Spring Boot 日志默认配置：[Spring Boot Logging Reference](https://docs.spring.io/spring-boot/docs/2.5.8/reference/html/features.html#features.logging)
- Maven Enforcer Plugin `bannedDependencies` 规则：[Apache Maven Enforcer Rules](https://maven.apache.org/enforcer/enforcer-rules/bannedDependencies.html)
