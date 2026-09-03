# Maven 编译排查实录：从 NoClassDefFoundError 到 ECJ 软错误字节码

> 一次真实的 Spring Cloud 多模块项目启动故障排查。  
> 表象是 `NoClassDefFoundError: DynamicDataSource`（注意没有包名！），最终定位到 **Eclipse JDT 编译器（ECJ）的"软错误字节码"机制**。
>
> 本篇覆盖：现象 → 排查思路 → 关键证据 → 底层原理 → 修复方案 → 一些顺带的知识点（`-DskipTests` vs `-Dmaven.test.skip=true`、`-pl/-am`、`file.encoding`）。

---

## 一、现象

多模块项目里，只有部分服务（mybill、ugc）启动失败，cms 等其他服务正常。失败栈：

```
java.lang.IllegalStateException: Error processing condition on
    com.metaxsire.common.validate.config.ValidateConfig.emailValidator
Caused by: java.lang.IllegalStateException: Failed to introspect Class
    [com.metaxsire.mybillservice.config.MultiDataSourceConfig]
    from ClassLoader [sun.misc.Launcher$AppClassLoader@18b4aac2]
Caused by: java.lang.NoClassDefFoundError: DynamicDataSource     ← 关键点！
    at java.lang.Class.getDeclaredMethods0(Native Method)
Caused by: java.lang.ClassNotFoundException: DynamicDataSource
```

**最诡异的地方**：`NoClassDefFoundError: DynamicDataSource` 报的类名**没有包前缀**（不是 `com/metaxsire/common/core/config/DynamicDataSource`）。

JVM 正常报 `NoClassDefFoundError` 时一定带 binary name（即 `com/foo/Bar` 形式），所以这种"没包名"的报错本身就是异常信号。

---

## 二、第一轮误判：以为是缓存过期

**思路**：源码 `import` 完整、`target/classes` 里的 `.class` 也对，可能是 IDEA 增量编译缓存有问题。

**让用户试的操作**：
1. `Build → Rebuild Project`
2. `Invalidate Caches and Restart`
3. `mvn clean install`

**结果**：用户做了 Invalidate Caches，还是同样的报错堆栈，**一字不差**。说明不是缓存过期问题。

---

## 三、第二轮关键发现：`.class` 文件被污染了

### 证据 1：检查 cms（能启动）和 ugc（启动失败）的 `.class` 文件差异

```bash
javap -v application/cms/cms-service/target/classes/com/metaxsire/cmsservice/config/MultiDataSourceConfig.class | grep Class
# 输出干净，引用 com/metaxsire/common/core/config/BaseMultiDataSourceConfig

javap -v application/ugc/ugc-service/target/classes/com/metaxsire/ugcservice/config/MultiDataSourceConfig.class
```

ugc 的 `.class` 文件里赫然出现：

```
#10 = String "Unresolved compilation problems:
    The import com.metaxsire.common.core.config.BaseMultiDataSourceConfig cannot be resolved
    The import com.metaxsire.common.core.config.DynamicDataSource cannot be resolved
    BaseMultiDataSourceConfig cannot be resolved to a type
    DynamicDataSource cannot be resolved to a type ..."
#35 = Utf8 "()LDynamicDataSource;"     ← 默认包简单名！
#50 = Class #51 // DynamicDataSource     ← 常量池里就是这个！
```

**关键认知**：编译失败时，方法签名 / 常量池里的类名居然是**默认包（无包名）的简单名**。这正好解释了为什么 JVM 报 `NoClassDefFoundError: DynamicDataSource`（无包名）。

### 证据 2：这种字节码是 ECJ 特有的

这种 "Unresolved compilation problems" 字符串 + `throw new Error(...)` 的"软错误"字节码，是 **Eclipse JDT 编译器（ECJ）** 的独特行为：

| 编译器 | 编译失败时的行为 |
| --- | --- |
| **javac** | 直接 fail，不生成 `.class` 文件 |
| **ECJ** | 生成"残废" `.class`：能加载，但方法体被替换成 `throw new Error("Unresolved ...")` |

ECJ 这个行为的初衷是支持 Eclipse "运行带编译错误的代码"，让用户能跑测试用例验证别的部分。代价就是：**字节码里残留了用默认包简单名表达的、本来无法解析的类引用**。

---

## 四、底层原理：ECJ 软错误字节码长什么样

正常 javac 编译 `public DynamicDataSource dataSource() { ... }` 产出：

```
descriptor: ()Lcom/metaxsire/common/core/config/DynamicDataSource;
Code: ... new com/metaxsire/common/core/config/DynamicDataSource ...
```

ECJ 在 import 解析失败时产出：

```java
// 反编译后等价于
public DynamicDataSource dataSource() {
    throw new Error("Unresolved compilation problems: \n\t..."); 
}
```

```
descriptor: ()LDynamicDataSource;                    // 默认包简单名！
Code: ldc "Unresolved compilation problems: ..."     // 字符串常量
      new java/lang/Error
      athrow
```

JVM 在 Spring 反射枚举 `@Bean` 方法时，需要解析 `()LDynamicDataSource;` 里的返回类型 → 在 classpath 里找 `DynamicDataSource`（默认包） → 找不到 → `NoClassDefFoundError: DynamicDataSource`。

**所以"NoClassDefFoundError 没有包名"本身就是 ECJ 污染的特征**，看到这个特征基本可以直接定位。

---

## 五、为什么 ECJ 会跑出来

项目 `pom.xml` 里 `maven-compiler-plugin` 是默认配置（javac），按理不会用 ECJ。问题出在 **IDEA 的后台编译**：

1. 用户执行 `mvn clean install`（javac 跑完，`target/classes` 是干净的）
2. 紧接着 **IDEA 检测到文件变化**，触发后台 `Make`
3. 此时 IDEA 的项目模型（module 依赖）还没完全恢复（特别是 Invalidate Caches 之后），看不到 common-core
4. IDEA 调用 ECJ 增量编译，import 解析失败 → 生成"软错误" `.class`
5. 这些坏 `.class` **覆盖了 Maven 编出来的好 `.class`**
6. 用户启动应用 → 加载坏 `.class` → 炸

为什么 cms 没事？因为 cms 在本次 Invalidate 之前就被 IDEA 编过、Maven 后续 install 时它又被 javac 重新编了，最终态是干净的。mybill/ugc 没有这种"双重保险"，被 IDEA 后台编译覆盖了。

---

## 六、修复方案

### 治标：把被污染的 `.class` 重新编出来 + 不让 IDEA 再编

```bash
# 1. 把 IDEA 完全关闭（任务管理器确认 idea64.exe 没了）

# 2. cmd 里手动删 target，绕开 IDEA 重编
rmdir /s /q application\ugc\ugc-service\target
mvn install -pl application/ugc/ugc-service -am -Dmaven.test.skip=true -Ptest

# 3. 验证 .class 干净（应该没有任何输出）
javap -v application\ugc\ugc-service\target\classes\com\metaxsire\ugcservice\data\po\LiteMediaVideo$LiteMediaVideoModelMapperImpl.class | findstr /i unresolved

# 4. 命令行启动（不要打开 IDEA）
java -Dfile.encoding=UTF-8 -jar application\ugc\ugc-service\target\ugc-service.jar --spring.profiles.active=test
```

### 治本：改 IDEA 设置

**File → Settings → Build, Execution, Deployment → Compiler → Java Compiler**
- `Use compiler:` 改成 **Javac**（如果是 Eclipse 一定要改回来）

**File → Settings → Build, Execution, Deployment → Compiler**
- 取消勾选 `Build project automatically`（避免后台自动编译）

**Run → Edit Configurations → Before launch**
- 移除 `Build` 这一步（避免 IDEA 在启动前重新编译）

> 注意：即便把 `Use compiler` 设成了 Javac，如果有 MarsCode 之类的 AI 插件在后台跑自己的编译，照样可能产生 ECJ 软错误字节码。彻底解决最稳妥的方式是临时关闭 IDEA 或禁用相关插件。
>
> **更要命的是：肇事者不止 IDEA。** `Use compiler: Javac` 只管 IDEA 自己——**VSCode 的 "Java" 扩展（Red Hat / 底层 Eclipse JDT = ECJ）是另一个进程、另一套 ECJ，IDEA 的设置完全管不到它**。同理 Cursor / Eclipse 也是。详见 §11.4「比插件更根本：编辑器本身就是 ECJ」。

---

## 七、顺带踩到的两个坑

### 坑 1：`-DskipTests` ≠ `-Dmaven.test.skip=true`

| 参数 | 测试编译 | 测试运行 | 适用场景 |
| --- | --- | --- | --- |
| `-DskipTests` | ✅ 编 | ❌ 不跑 | 想编译测试代码但不执行 |
| `-Dmaven.test.skip=true` | ❌ 不编 | ❌ 不跑 | 测试代码本身有编译错误时跳过 |

如果测试代码引用了已经被删除/重命名的类（很常见），`-DskipTests` 救不了你，必须用 `-Dmaven.test.skip=true`。

### 坑 2：Windows 上 `java -jar` 默认 charset 不是 UTF-8

现象：

```
org.yaml.snakeyaml.error.YAMLException:
    java.nio.charset.MalformedInputException: Input length = 1
```

原因：Windows 上 JVM 默认 `file.encoding=GBK`，从 Nacos 拉下来的 yaml 用 UTF-8 编码，被 GBK 解码就炸。

**IDEA 不会撞这个坑**，因为 IDEA 启动子进程时自动加 `-Dfile.encoding=UTF-8`（可以从 Run 控制台贴出来的完整 `java.exe ...` 命令行里验证）。

命令行启动加上即可：

```cmd
java -Dfile.encoding=UTF-8 -jar xxx.jar
```

Java 18+ 默认就是 UTF-8 了（JEP 400），但 Java 8/11/17 还需要手动指定。

---

## 八、`-pl` 和 `-am` 顺带补充

多模块项目里，只想编某个模块时：

| 参数 | 含义 |
| --- | --- |
| `-pl module/path` | 只构建指定模块（`--projects`） |
| `-am` | 同时构建被选模块**依赖**的本地模块（`--also-make`） |
| `-amd` | 同时构建**依赖**被选模块的本地模块（`--also-make-dependents`） |
| `-pl '!module/path'` | 排除某模块 |
| `-rf :artifactId` | 从指定模块**重新开始**构建（resume from） |

```bash
# 只编 ugc 链路（推荐日常用）
mvn clean install -Dmaven.test.skip=true -Ptest -pl application/ugc/ugc-service -am

# 改了 common-core，验证下游所有用它的服务能编过
mvn install -pl common/common-core -amd
```

---

## 九、排查思路复盘

| 步骤 | 动作 | 结论 |
| --- | --- | --- |
| 1 | 读异常堆栈，定位"哪个 class 加载失败" | `DynamicDataSource` 无包名 |
| 2 | 注意到"无包名"这个反常细节 | JVM 正常不会这么报，说明字节码有问题 |
| 3 | `javap -v` 看坏服务的 `.class` 常量池 | 发现 `Unresolved compilation problems` 字样 |
| 4 | 对比能跑的服务的 `.class` | 干净 vs 污染，定位差异 |
| 5 | 识别 ECJ 软错误字节码特征 | 这是 Eclipse JDT 独有的产物 |
| 6 | 反推编译器来源 | IDEA 后台编译 / 插件污染 |
| 7 | 关闭 IDEA + 走 Maven + 验证 `.class` 干净 | 彻底解决 |

**心得**：`javap -v` 是排查"编译时和运行时类不一致"问题的核武器，比反编译工具更接近真相（反编译会把 ECJ 软错误"美化"成普通方法）。

---

## 十、`javap -v` 速查

### 它是什么

`javap` 是 **JDK 自带**的 class 文件反汇编工具（路径 `$JAVA_HOME/bin/javap`），把二进制 `.class` 还原成可读的"汇编态"信息：类头、常量池、方法签名、JVM 字节码指令。

和 IDEA / `jd-gui` 这类**反编译**工具（还原成 Java 源码）的本质区别：

| 工具 | 输出 | 用途 |
| --- | --- | --- |
| `javap` | JVM 视角：常量池、descriptor、bytecode | 排障、看实际类型签名、验证编译产物 |
| IDEA decompiler / jd-gui | Java 源码（猜测还原） | 看大致逻辑、读别人代码 |

**关键**：反编译会把异常情况"美化"。比如 ECJ 软错误，反编译看上去就是个抛 `Error` 的普通方法，看不出来是"编译失败的残骸"。`javap` 不美化，常量池里的字符串和奇怪 descriptor 一目了然。

### 常用参数

| 参数 | 作用 | 何时用 |
| --- | --- | --- |
| `-v` / `-verbose` | **最全**：常量池 + 方法字节码 + 局部变量表 + LineNumberTable | 排障首选 |
| `-p` / `-private` | 显示 private 成员 | 默认只显示 public，配合其他参数 |
| `-c` | 显示方法字节码（不带常量池） | 看具体指令序列时 |
| `-s` | 显示方法 / 字段的 internal signature（descriptor） | 看 JVM 视角的真实签名 |
| `-l` | 显示行号表和局部变量表 | 调试位置信息 |
| `-constants` | 显示 `static final` 常量值 | 看编译时被 inline 的常量 |

实战常用组合：

```bash
javap -v Foo.class                 # 一把梭，输出最全
javap -p -s Foo.class              # 看所有方法（含 private）的 descriptor
javap -p -c Foo.class | less       # 看所有方法的字节码
```

### 输出的关键区块

```
Classfile /path/to/Foo.class
  Last modified ...; size 1179 bytes
  MD5 checksum ...
  Compiled from "Foo.java"
public class com.foo.Foo extends ...               ← 类头
  minor version: 0
  major version: 52                                ← Java 8 = 52, Java 11 = 55, Java 17 = 61
  flags: (0x0021) ACC_PUBLIC, ACC_SUPER
  this_class: #6
  super_class: #7

Constant pool:                                     ← 常量池：所有字符串、类引用、方法引用
   #1 = Methodref          #17.#59
   #6 = Class              #38     // com/foo/Foo
   #9 = Methodref          #6.#62  // com/foo/Foo.bar:(I)V
   ...

  public void bar(int);                            ← 方法签名（人类可读）
    descriptor: (I)V                               ← descriptor（JVM 视角）
    Code:                                          ← 字节码
       0: iload_1
       1: ireturn
```

### 怎么读 descriptor

JVM 内部用 descriptor 描述类型，**和 Java 源码写法不一样**：

| Java | descriptor |
| --- | --- |
| `int` | `I` |
| `long` | `J` |
| `boolean` | `Z` |
| `void` | `V` |
| `String` | `Ljava/lang/String;` |
| `String[]` | `[Ljava/lang/String;` |
| `int[][]` | `[[I` |
| `void foo(int, String)` | `(ILjava/lang/String;)V` |

排障时盯着 descriptor 看，能直接发现：
- 类引用是否带完整包名（`Lcom/foo/Bar;` vs `LBar;` —— 后者就是 ECJ 软错误的特征）
- 泛型擦除后的实际签名（看是 `Object` 还是具体类）
- lambda / inner class 的实际方法名

### 排查 ECJ 软错误的固定动作

```bash
# Linux/Mac
javap -v Foo.class | grep -i unresolved

# Windows cmd
javap -v Foo.class | findstr /i unresolved

# Windows PowerShell（注意 $ 转义）
javap -v Foo.class | Select-String -Pattern unresolved
```

**有输出 = class 被 ECJ 污染，需重编**。这种检查可以脚本化对项目所有 class 做巡检。

### 其他实战场景

| 场景 | 命令 / 关注点 |
| --- | --- |
| 验证某个方法的真实参数类型（泛型擦除后） | `javap -p -s Foo.class` 看 descriptor |
| 排查 `java.lang.NoSuchMethodError` | 比对调用方和被调用方的 descriptor 是否一致 |
| 看 `static final` 常量是否被编译时 inline | `javap -constants -v Foo.class` —— 如果常量被 inline，编译产物里不会有引用 |
| 看 lambda 的实际生成方法名 | `javap -p Foo.class` 看 `lambda$xxx$N` |
| 看 Spring CGLIB 代理类的字段 | `javap -p Foo$$EnhancerBySpringCGLIB$$xxx.class` |
| 确认 class 编译用的 JDK 版本 | 看 `major version`（52/55/61 = 8/11/17） |

### 配合 `jar` 命令查 jar 包里的 class

如果要看的 class 在 jar 里：

```bash
# 解压单个 class（Linux/Mac）
unzip -p some.jar com/foo/Foo.class > /tmp/Foo.class && javap -v /tmp/Foo.class

# Windows 用 jar 命令（JDK 自带）
jar xf some.jar com/foo/Foo.class
javap -v com\foo\Foo.class
```

---

## 十一、补充：新案例与新认知（2026-05-28，mybill 多次踩坑）

> 同一天对 mybill 打了三次包，遇到**两种不同形态**的故障，又掉进**新的触发模式**。把这些案例和它们暴露的盲区一并补进来。

### 11.1 另一种故障形态：jar 漏装 class（不是 ECJ 软错误）

#### 现象

```
Caused by: java.lang.ClassNotFoundException: 
    Cannot find class: com.metaxsire.mybillservice.model.Subscription
```

注意：**类名是带完整包名的**（`com.metaxsire.mybillservice.model.Subscription`），不是 ECJ 软错误那种"无包名简单名"。这是关键的形态差异。

#### 初查发现

```powershell
# target/classes 里 Subscription.class 存在
Test-Path target\classes\com\metaxsire\mybillservice\model\Subscription.class
# True

# javap 检查 class 内容 → 干净，常量池全是完整包名引用，没有 unresolved
javap -v target\classes\...\Subscription.class | findstr unresolved
# （无输出）
```

`.class` 文件存在且内容正常，但程序运行时找不到。问题出在哪？

#### 关键诊断动作：class 列表对账

对比 **`target/classes/` 实际产物** 和 **jar 包 `BOOT-INF/classes/` 实际打入** 的差异：

```powershell
$inTarget = Get-ChildItem -Path 'target\classes\com\foo' -Recurse -Filter *.class `
    | ForEach-Object { $_.FullName -replace [regex]::Escape("$pwd\target\classes\"),'' -replace '\\','/' }

$inJar = jar tf target\xxx.jar `
    | Where-Object { $_ -like 'BOOT-INF/classes/com/foo/*' } `
    | ForEach-Object { $_ -replace 'BOOT-INF/classes/','' }

Compare-Object -ReferenceObject $inTarget -DifferenceObject $inJar `
    | Where-Object { $_.SideIndicator -eq '<=' }
```

输出 **target 有但 jar 没有** 的列表：

```
com/metaxsire/mybillservice/model/Subscription.class
com/metaxsire/mybillservice/model/Subscription$SubscriptionModelMapper.class
com/metaxsire/mybillservice/dao/SubscriptionMapper.class
com/metaxsire/mybillservice/controller/SubscriptionController.class
com/metaxsire/mybillservice/admin/controller/SysSubscriptionController.class
com/metaxsire/mybillservice/vo/SubscriptionVo.class
```

精确缺 6 个 class，全部围绕 Subscription 链路。

#### 时间戳证据

```
jar 文件修改时间:       22:39:12
6 个缺失 class 时间:    22:39:12 ~ 22:39:13
```

`mvn-jar-plugin` 收集 class 的瞬间，这些 class **还没落盘**（或刚刚落盘，恰好错过 jar 的收集快照）。`mybill-service.jar.original`（spring-boot repackage 之前）里也缺这 6 个 → 问题不在 repackage 阶段，在更早的 `jar` 阶段。

#### 根因

MapStruct 的注解处理器在第一轮 javac 之后才生成 mapper 实现类，触发第二轮编译。整条链路（model → 内部 Mapper 接口 → dao → controller → vo）的最终落盘时刻可能**晚于 mvn-jar-plugin 的 class 收集时刻**。

Maven 单模块内 phase 严格串行，正常不会出这种问题。但 **IDEA 后台进程在 mvn 运行期间向 `target/classes` 抢写**，就会制造这种"jar 已经收完，落盘还在继续"的并发污染。

#### 形态对比表

| | 形态 A：ECJ 软错误（§三 案例） | 形态 B：jar 漏装 class（本节案例） |
|---|---|---|
| 异常类名 | **无包名**（`DynamicDataSource`） | **有完整包名**（`com.foo.Subscription`） |
| `target/classes` | 文件存在，**内容污染** | 文件存在，**内容干净** |
| jar 里 | class 在 jar 里，但损坏 | **class 根本没在 jar 里** |
| 诊断手段 | `javap -v *.class \| findstr unresolved` | `Compare-Object` (target/classes ↔ jar BOOT-INF/classes) |
| 上游根因 | IDEA ECJ 后台编译污染了 `.class` 内容 | IDEA 后台进程抢写 `target/classes` 与 jar 收集竞态 |

两种形态的最终肇事者都是 **IDEA 后台进程**，但它"赢"的时机不同，产生不同表象。

---

### 11.2 新触发模式：Maven profile 切换

#### 观察到的触发规律

| 操作序列 | 结果 |
|---|---|
| IDEA 启动用 test → 命令行 `mvn -Ppreprod` 打包 | **炸** |
| 命令行 `mvn -Ppreprod` 打包 → 命令行 `mvn -Pappprod` 打包 | **炸** |
| 单独打一次（任意 profile）| 通常正常 |

#### profile 内容差异其实极小

```xml
<profile>
    <id>preprod</id>
    <properties>
        <profile.name>prod</profile.name>
        <config.namespace>toy-prod</config.namespace>
    </properties>
</profile>
<profile>
    <id>appprod</id>
    <activation><activeByDefault>true</activeByDefault></activation>
    <properties>
        <profile.name>prod</profile.name>
        <config.namespace>app-prod</config.namespace>   <!-- 唯一不同 -->
    </properties>
</profile>
```

只差一个 `config.namespace` 字符串。**没有改任何编译器配置、源码目录、annotation processor**。理论上无论哪个 profile 编出来的 class 字节码应当**逐字节相同**。

#### 那为什么切 profile 触发问题？

不是 profile 本身污染了 class —— 是 **profile 切换让 IDEA 检测到 effective pom 变化，触发后台 sync / 模型重建**：

```
切 profile  →  IDEA 监听 pom effective 变化
            →  IDEA 触发 "Reload Maven projects" / 模块同步
            →  IDEA 后台进程（可能是 ECJ）重编模块
            →  与 mvn package 抢 target/classes
            →  污染（形态 A 或 形态 B）
```

#### 经验

> profile 切换 = "IDEA 项目模型与 mvn 实际执行视角不一致" 的最常见触发器。任何时候你在命令行执行 `mvn` 用的 profile 和 IDEA 当前激活的 profile 不一样，就在创造这种错位。

---

### 11.3 `<activeByDefault>` 是隐藏陷阱

#### 机制

任何 profile 标了 `<activation><activeByDefault>true</activeByDefault></activation>`，IDEA 启动读 pom 时**默认就激活这个 profile**。但当你在命令行用 `-P<other>` 指定别的 profile 打包：

| | IDEA 视角 | 命令行 Maven 视角 |
|---|---|---|
| 激活 profile | activeByDefault 那个 | `-P` 指定那个 |
| `${profile.name}` | （前者的值） | （后者的值） |
| `${config.namespace}` | （前者的值） | （后者的值） |
| effective pom | 一份 | 另一份 |

→ 两边的项目模型**不一致** → IDEA 试图 reconcile → 触发后台编译。

#### Maven 优先级（顺带记一下）

```
mvn -P<id>           （命令行）          ← 最高
settings.xml 的 <activeProfiles>
<activation> 条件（OS / JDK / file）
<activeByDefault>true</activeByDefault>  ← 最低
```

**任何一个高优先级激活后，所有 `activeByDefault` 自动失效**。所以"命令行选 prod，但 pom 里 test 标了 activeByDefault" → Maven 实际只激活 prod，test 的 activeByDefault 不生效 —— 但 **IDEA 不一定按这个规则走**，它读到 activeByDefault 就当真。错位由此而来。

#### 推荐做法

```xml
<!-- 删掉所有 profile 的 activeByDefault -->
<profile>
    <id>test</id>
    <!-- 不要写 <activation>...</activation> -->
    <properties>...</properties>
</profile>
```

- 命令行始终 `-P<id>` 显式指定
- IDEA 右侧 Maven 面板 → `Profiles` 区域手动勾选当前要用的那个
- 两边视角始终一致，不会触发"reconcile"

---

### 11.4 IDEA 设置"看起来都对"也可能污染

#### 已验证过的安全设置

- `Settings → Build, Execution, Deployment → Compiler → Java Compiler`：`Use compiler: Javac` ✓
- `Settings → Build, Execution, Deployment → Compiler`：`Build project automatically` **未勾选** ✓

即使以上都符合 §六 治本方案，**ECJ 软错误仍然会发生**。说明 IDEA 还有其他路径可以触发后台编译。

#### 仍未被这些设置拦截的路径

| 触发路径 | 说明 |
|---|---|
| 用户主动 Ctrl+F9 / Build 菜单 | 显式触发，必然编译 |
| Run / Debug 配置启动前的 Make | 隐式触发，在 "Run Configuration → Before launch" 里 |
| `Rebuild module on dependency change`（默认开） | 检测到依赖模块变了 → 自动重编下游 |
| 打开项目时的初次同步 | IDEA 启动后会跑一次完整 sync |
| profile 切换 / pom 改动 → 触发 sync | 见 §11.2 |
| **第三方插件自带的编译器** | 完全绕过 IDEA Compiler 设置 |

#### 第三方插件这个隐藏雷点

下列插件**可能**为了实时代码分析跑自己的 ECJ 编译器，**不受 `Use compiler: Javac` 控制**：

- AI 类：MarsCode、Trae、通义灵码、豆包、Codeium、Continue、GitHub Copilot
- 代码质量类：SonarLint、Qodana、CheckStyle-IDEA、SpotBugs
- 任何宣传"实时语义分析 / 智能补全"的插件

排查动作：

```
Settings → Plugins → Installed
→ 看 AI / Code Analysis 类插件清单
→ 全部禁用后单独测试一次打包
→ 如果不再污染，逐个启用定位真凶
```

#### 比插件更根本：编辑器本身就是 ECJ（不止 IDEA）

把"肇事者"锁定成 IDEA 是不够的——**真正的肇事者是任何基于 Eclipse JDT（ECJ）的后台编译器**。常见的几个都用 ECJ，对 Maven 项目经 m2e / JDT 把输出目录设成 `target/classes`，autobuild 默认开启，**打开项目就在后台往 `target/classes` 增量编译**：

| 编辑器 / 工具 | 底层编译器 | 关掉后台编译的开关 |
| --- | --- | --- |
| IntelliJ IDEA | 可配 Javac / ECJ；插件可能强行 ECJ | 见 §六（Use Javac + 关 Build automatically + 退出） |
| **VSCode + "Java" 扩展（Red Hat / redhat.java）** | **Eclipse JDT = ECJ** | `settings.json` 设 `"java.autobuild.enabled": false`，或禁用扩展，或退出 VSCode |
| Cursor / Windsurf 等 VSCode 系 | 同上（装了 Java 扩展就是 JDT） | 同 VSCode |
| Eclipse / STS 本体 | ECJ | Project → 取消 `Build Automatically` |

**关键认知**：`Use compiler: Javac` 只管 IDEA 自己；**VSCode 的 Java 扩展是另一个进程、另一套 ECJ，IDEA 的设置管不到它**。所以"我关了 IDEA / 设了 Javac"≠ 安全——只要还有一个带 Java 扩展的 VSCode（或 Cursor）开着，它照样在后台用 ECJ 写 `target/classes`。**两个编辑器常开 = 两个 ECJ 同时和 `mvn` 抢 `target/classes`，这往往就是"频繁"出问题的真正原因。**

> 实例（2026-06-12）：在 VSCode 里编辑期间，`FeedbackService.updateById(...)` 被标红「方法未定义」，但命令行 `mvn compile` 是 BUILD SUCCESS。这就是 **VSCode 的 JDT 正在活跃、且它的 classpath 模型（`IBaseService` 继承链）与真实 classpath 脱节**的铁证——同样的脱节一旦写进 `target/classes`，就是软错误 class。修这种 LSP 误报：命令面板 → `Java: Clean Java Language Server Workspace`。

判断"是不是某个 IDE 在偷偷写"：**不跑 mvn**，隔 30s 看目标 class 的修改时间会不会自己变：

```bash
ls -la application/.../target/classes/.../MultiDataSourceConfig.class
# 等一会儿再看一次，时间戳自己变了 = 有 IDE 在后台编译
```

#### 最稳妥的兜底（仍然推荐）

打包前**退出所有基于 ECJ 的编辑器**——不只 IDEA（任务管理器确认 `idea64.exe` 消失），也包括带 Java 扩展的 **VSCode / Cursor**（退出，或至少设 `"java.autobuild.enabled": false`）。确认没有任何后台编译进程后再 `mvn package`。这是 100% 有效、不依赖任何单一 IDE 设置的方案。

---

### 11.5 防御性 build.bat：检测 IDEA 是否运行

在 build.bat 开头加一段提示，避免无意识带着 IDEA 打包：

```bat
@echo off
tasklist /FI "IMAGENAME eq idea64.exe" 2>NUL | find /I "idea64.exe">NUL
if "%ERRORLEVEL%"=="0" (
    echo.
    echo [WARN] IDEA is running.
    echo [WARN] IDEA background compilation may corrupt target\classes
    echo [WARN] during mvn package, causing ECJ-contaminated bytecode
    echo [WARN] or missing classes in the resulting jar.
    echo.
    choice /C YN /M "Continue anyway?"
    if errorlevel 2 exit /b 1
)
:: ... 后续原 build.bat 流程
```

类似地，Linux 的 build.sh 可加：

```bash
if pgrep -f "idea" > /dev/null; then
    echo "[WARN] IDEA is running. May corrupt class files during mvn package."
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi
```

---

### 11.6 更新版排查流程

故障出现时按这个顺序判断：

```
1. 看异常类名是否带包名
   ├─ 无包名（默认包简单名）
   │     → 形态 A：ECJ 软错误
   │     → javap -v *.class | findstr unresolved 验证
   │     → 修复：删 target/，关 IDEA，mvn 重编（见 §六）
   │
   └─ 有完整包名
         → 检查 target/classes 里 class 文件
         ├─ 不存在
         │     → 源码或 pom 真有问题，正常排查
         │
         └─ 存在且 javap 无 unresolved
               → 对账 jar 包：Compare-Object target ↔ BOOT-INF/classes
               ├─ jar 里有
               │     → 类加载器 / 反射 / classpath 问题，不在本文范围
               │
               └─ jar 里没有
                     → 形态 B：jar 漏装 class
                     → 重打 + 关 IDEA + 验证

2. 找出触发场景 —— 通常是以下之一
   - profile 切换（命令行 vs IDEA 不一致）
   - 紧接着两次 mvn 之间没等 IDEA 同步完
   - IDEA 同时在跑（哪怕只是初次启动同步）
   - pom 里有 <activeByDefault> 制造错位

3. 治本：去 activeByDefault + 关 IDEA + 禁用可疑插件
```

---

## 十三、补记（2026-06-03）：`mvn clean` 后 IDEA 单模块启动，连环「找不到符号 / NoClassDefFoundError」

> 又一次真实排查。这次不是 ECJ 软错误，而是**多模块依赖没编/没装，IDEA 只编了被启动的那一个模块**。
> 背景：刚给 mybill 做了「订阅争议账号锁定」的改动（去掉 cms Feign 调用，改成 mybill 经 `@MyDataSource` 直写 `metaxsire_user` + 清 Redis 缓存）。代码本身用 `mvn -o clean test -pl mybill-service -am -Ptest` 验证过——**编译 + 4 个单测全过**。但用户在 IDEA 里点 Run 启动 `MybillApplication` 却一路报错。

### 13.1 三个表象（逐个变化，像打地鼠）

每次启动/构建，卡在**不同的类**上，但本质是同一个：

| # | 报错 | 卡在哪个类 |
|---|---|---|
| 1 | `NoClassDefFoundError: Could not initialize class ...model.XcoinProduct`，深层是 ECJ `Unresolved compilation problems: import ...vo.XcoinProductVo cannot be resolved` | `XcoinProductVo`（MapStruct 生成类） |
| 2 | `NoClassDefFoundError: PayPalClient` / `ClassNotFoundException: PayPalClient` | `common-pay-paypal` 模块的类 |
| 3 | IDEA Build Output：`mybill-service [install]` → `compile 5 errors`，全是 `找不到符号`，落在 `PayPalSubCancelSchedule.java:7`、`PayPalSubscriptionServiceImpl.java:23/25`、`SubOperationRecordServiceImpl.java:14/15` | 全部是 `import com.metaxsire.common.pay.paypal.*` 行 |

第 3 个把根因彻底暴露了：**5 个「找不到符号」全部落在 `common.pay.paypal.*` 的 import 行上**。

### 13.2 根因：单模块构建 + 依赖模块既没编也没装

触发链：

1. 用户跑了 `mvn clean` —— **清空了所有模块的 `target/`**（含 MapStruct 在 `target/generated-sources` 里生成的 `XcoinProductVo`）。
2. IDEA 点 Run/install 时，**只针对 `mybill-service` 这一个模块**编译（Build 标题就是 `mybill-service [install]`）。
3. mybill-service 依赖的兄弟模块 `common-pay-paypal`、`mybill-api` 等：
   - `target/classes` 被第 1 步清空了 → 拿不到 class；
   - 又**从来没 `install` 进本地仓库** → 也拿不到 jar。
4. 于是 Maven 把 `common-pay-paypal` 当成「缺失的外部 jar」，它里面的 `PayPalClient`、`SubscriptionCancelReq` 等全部「找不到符号」。

> 对照表象 1 的 `XcoinProductVo`：它是 **MapStruct 注解处理生成**的源码，躺在 `target/generated-sources`，`mvn clean` 一并删了；IDEA 单模块编译又没触发注解处理重新生成它 → ECJ 把「import 解析不到」编成软错误字节码（机制见 §六），运行时 `NoClassDefFoundError`。

**为什么命令行 `mvn ... -am` 没事，IDEA 却炸？**
`-am`（also make）会把依赖模块拉进 reactor **按依赖顺序先编**；IDEA 默认的「Build」只编被启动的单模块，不会先编 `common-pay-paypal`。差别就在这。

### 13.3 处理与结果

按「先治本、再防复发」两步：

**① 一次性把整个 reactor 装进本地仓库**（让单模块构建以后能找到兄弟模块的 jar）

GUI 做法：Maven 工具窗 → 选**最外层根父工程**（不是 mybill-service！Build 标题要是 `<根工程> [install]`）→ Lifecycle → 双击 `install`。
等价命令：`mvn install -pl application/mybill/mybill-service -am -Ptest`（`-am` 先编 `common-pay-paypal`/`mybill-api` 等，再编 mybill，并逐个装进仓库）。

**② 勾选 IDEA「Delegate IDE build/run actions to Maven」**
`Settings → Build Tools → Maven → Runner` 里勾上。
- **为什么**：勾上后，点绿色 Run/Debug 时 IDEA **把编译交给 Maven**，Maven 会按模块依赖顺序编译（自动先编 `common-pay-paypal`）并跑注解处理（生成 `XcoinProductVo`）。不勾的话，IDEA 用自己的增量编译器只编单模块 → 必然缺 paypal 符号、缺 MapStruct 生成类。
- 不想勾也行，但每次 `mvn clean` 后**第一次启动前必须手动 `Build → Rebuild Project`**（编译整个工程所有模块，不是单模块）。

**③ 设置 `maven.test.skip=true`**（否则 ① 的 install 会被测试卡住）
`Settings → Build Tools → Maven → Runner → Properties` 加一行 `maven.test.skip = true`。
- **为什么是 `maven.test.skip=true` 而不是 `-DskipTests`**：根工程 install 会把**所有模块**的测试也跑一遍，其中某个（可能跟本次改动无关的旧）测试没过，整个 install 就失败。
  - `-DskipTests`（IDEA 那个试管图标）：跳过**运行**，但**仍会编译**测试代码——若有模块的测试代码本身编不过，照样失败。
  - `maven.test.skip=true`：测试**编译 + 运行全跳**，最干净，目的只是把各模块 jar 装进仓库、让应用能起来。
  - 详见本文 §九对两者的对比。

**结果**：① 跑出 `BUILD SUCCESS` 后，paypal 那 5 个「找不到符号」消失；之后点 Debug 正常启动。改的业务代码（去 Feign 改 DB 直写）与本故障无关，命令行早已验证编译 + 测试通过。

### 13.4 速查：这一类故障怎么判

```
症状：mvn clean 后，IDEA 启动单个服务报「找不到符号 / ClassNotFoundException」，
      且卡住的类全部来自【同一个兄弟模块】（如 common-pay-paypal）或 MapStruct 生成类
  │
  ├─ 看 IDEA Build 标题是不是「<单模块> [install/compile]」
  │     → 是 → 就是只编了单模块，没编依赖模块
  │
  ├─ 治本：对【根工程】install 一次（或 -pl xxx -am），把所有模块 jar 装进本地仓库
  ├─ 防复发：勾「Delegate IDE build/run actions to Maven」（点 Run 即走 Maven 全量编）
  └─ install 被测试卡住：Runner 里加 maven.test.skip=true
```

要点：**`mvn clean` 会清掉本地仓库以外的所有 `target/`**。清完后若只编单模块，必然缺兄弟模块的符号——要么 `-am`，要么对根工程编，要么让 IDEA 委托给 Maven。

---

## 十四、补记（2026-06-12）：本地仓库残缺 jar + `clean / compile / package / install` 区别

> 又一次"代码和 pom 都没错，却编译失败"。这次肇事者不是 IDEA 后台污染（§三~§十三的主线），而是 **`~/.m2` 本地仓库里躺着一个残缺的 jar**。
> 顺带把 `clean / compile / package / install` 四个命令的本质区别补齐——因为这次的修复，恰恰是靠 **`package` 与 `install` 的差异**才说得清。

### 14.1 现象

跑全量 `mvn ... package`，唯独 `live-service` 编译失败：

```
[ERROR] LiveChannelServiceImpl.java:[211,50] 无法访问IBaseService
  找不到IBaseService的类文件
```

而第 211 行只是普通一句调用：

```java
String userId = metaxsireSecretKeyService.getUserIdBySecretKey(secretKey);
```

`MetaxsireSecretKeyService`（来自 `common-upms`）的定义是 `extends IBaseService<MetaxsireSecretKey, Long>`，而 `IBaseService` 在 `common-core`。**`live-service` 的 pom 明确依赖了 `common-core`**——典型的"依赖都在，却找不到类文件"。

> 编译器报"无法访问 X / 找不到 X 的类文件"的本质：javac 解析 `metaxsireSecretKeyService.xxx()` 时，要加载 `MetaxsireSecretKeyService` 的**整条继承链**（含父接口 `IBaseService`）。继承链上任一类型在编译 classpath 里缺失，就报这个错——错的不是你写的那行，是它**间接**引用的父类型。

### 14.2 诊断：reactor 产物有，`.m2` 的 jar 却没有

```bash
# ① 本次 reactor 13:07 编出来的 target/classes 里，IBaseService.class 在
ls common/common-core/target/classes/com/metaxsire/common/core/base/service/IBaseService.class
# 存在

# ② 但本地仓库那个 jar（6-08 的旧产物）里——
unzip -l ~/.m2/repository/com/metaxsire/common-core/1.0.0/common-core-1.0.0.jar \
    | grep base/service
#   BaseService.class
#   BaseDictService.class
#   IBaseDictService.class
#   …… 唯独没有 IBaseService.class
```

**矛盾点**：`IBaseService` 自 2023 init 就存在，且 `BaseService implements IBaseService`。正常编译产物里**不可能**出现"有 `BaseService.class` 却缺 `IBaseService.class`"。→ 结论：`.m2` 里这个 jar 是**残缺/损坏产物**（上次某次打包被中断，或半成品被 `install` 进了仓库）。

### 14.3 根因：单模块 / 部分构建时，下游链到了残缺 jar

| 构建方式 | 模块间依赖从哪取 | 会不会踩残缺 jar |
|---|---|---|
| 全量 reactor（所有模块一起 build） | 彼此的 `target/classes` | 不会（根本不碰 `.m2`） |
| `-pl` 只构建部分模块 / IDEA 单模块编译 | 被依赖模块从 **`.m2` 取 jar** | **会**——取到残缺的那个 |

`live-service` 这次解析 `common-core` 时回退到了 `.m2` 的残缺 jar，里面没有 `IBaseService.class` → 报错。

> 与 §十三 的关系：都是"下游找不到兄弟模块的符号"，但根因细分不同——
> - §十三：依赖模块**从没 `install`**（`.m2` 里压根没有）。
> - 本例：依赖模块 **`install` 过，但装进去的是个残缺 jar**（`.m2` 里有，但不完整）。

### 14.4 修复：用 `install` 覆盖掉残缺 jar

```bash
mvn clean install -Dmaven.test.skip=true -pl common/common-core
# 重新打出完整 jar 并写回 .m2，覆盖那个残缺的

unzip -l ~/.m2/repository/com/metaxsire/common-core/1.0.0/common-core-1.0.0.jar \
    | grep IBaseService.class
#   6771  2026-06-12 13:16   …/IBaseService.class   ← 这次有了
```

之后 `live-service` 重新编译即通过。注意修复**必须用 `install`**，`package` 不行——原因见下。

### 14.5 顺带补齐：`clean / compile / package / install` 到底差在哪

Maven 有**两套生命周期**，同一生命周期内的阶段**累积执行**（跑后面的会把前面的都带跑）：

- `clean` —— 独立的 **clean 生命周期**。
- `compile / test / package / verify / install / deploy` —— **default 生命周期**，顺序固定：
  `validate → compile → test → package → verify → install → deploy`

所以 `mvn clean package` = 先清理，再从头跑到 `package`（compile、test 顺带都跑了）。

| 命令 | 做了什么 | 产物在哪 | 跑测试? | 能被「其它模块/别次构建」引用? |
|---|---|---|---|---|
| `clean` | 删除 `target/` | —（清空） | 否 | — |
| `compile` | 编译 `src/main/java` → `target/classes`，拷贝 resources | `target/classes/`（只有 `.class`） | 否 | ❌ 没打 jar |
| `package` | compile+test 之后打成 **jar/war** | `target/xxx.jar` | ✅（除非 skip） | ⚠️ 仅同一次全量 reactor 内（走 `target`） |
| `install` | package 之后，把 **jar + pom 复制进 `~/.m2`** | `target/` **和** `~/.m2/...` | ✅ | ✅ 本机任何项目 / 任何次构建都能引用 |

**一句话抓住本质**：

> `package` 解决"这个模块**能不能编出来**"；`install` 解决"**别的模块、别次构建能不能拿到它**"。
> `package` 的产物只待在各模块自己的 `target/`，**不进 `.m2`**。只有 `install` 写 `.m2`。

这正是 14.4 必须用 `install` 的原因：要覆盖的残缺 jar 在 `.m2` 里，只有 `install` 能写回去；`package` 改的只是 `target/`，对 `.m2` 毫无影响。

（`deploy` 再往后一步：推到**远程私服**（Nexus 等）供团队拉取，见 [Maven 私仓](Maven%20私仓.md)，本地开发用不到。）

### 14.6 判别速查

```
症状：某模块编译报「无法访问 X / 找不到 X 的类文件」，
      而它的 pom 确实依赖了 X 所在的模块
  │
  ├─ 本次 reactor 编出的 target/classes 里有 X.class 吗 → 有
  │     （没有 → 是源码 / pom 真问题，正常排查）
  │
  ├─ 看 .m2 里那个依赖 jar：unzip -l <jar> | grep X.class
  │     ├─ 没有 X.class（但有同包其它类）→ 残缺 jar（本节案例）
  │     ├─ 整个 jar 时间很旧 / 缺一批类 → 旧产物
  │     └─ 压根没这个 jar → 依赖从没 install（见 §十三）
  │
  └─ 修复：mvn clean install -pl <该依赖模块>   ← 用完整 jar 覆盖 .m2
            （package 没用，它不写 .m2）
```

**经验**：

- 改了**公共 / 底层模块**（`common-*`、`*-api`）且要给别的模块用：随手 `mvn clean install -pl 该模块` 一次，保证 `.m2` 是完整最新的。
- 遇到"依赖明明在、却找不到类"这类诡异编译错误：先怀疑 **`.m2` 里有残缺 / 过期 jar**，`install` 重装即根治。
- 想从源头避免残缺 jar 残留：全量构建用 `install` 而非 `package`，让所有模块最新产物都进 `.m2`。

---

## 十五、参考

- [Maven 私仓](Maven%20私仓.md)
- ECJ 软错误参考：[ECJ Batch Compiler Documentation](https://help.eclipse.org/latest/index.jsp?topic=%2Forg.eclipse.jdt.doc.user%2Ftasks%2Ftask-using_batch_compiler.htm)
- JEP 400：[UTF-8 by Default](https://openjdk.org/jeps/400)
- Maven Profile 激活优先级官方文档：[Introduction to build profiles](https://maven.apache.org/guides/introduction/introduction-to-profiles.html)
