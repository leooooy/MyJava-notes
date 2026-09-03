# Maven 私有仓库使用

> 几乎每家公司都有自己的 Maven 私仓，原因有三：
> ① **内部组件分发**——团队的 API / SDK / common 包，不能也不该传到 Maven 中央仓库；
> ② **代理外部仓库**——中央仓库国内访问慢，私仓做一层缓存代理；
> ③ **安全管控**——审计依赖来源，避免直接从公网拉未审核的 jar。
>
> 本篇覆盖：私仓选型 → `settings.xml` 三段配置（servers / mirrors / profiles）→ 项目 `pom.xml` 配置 → `mvn deploy` 命令 → 常见 401/部署错误。

---

## 一、私仓选型

| 方案 | 优点 | 缺点 | 适用场景 |
| --- | --- | --- | --- |
| **Nexus**（Sonatype） | 开源免费、生态最广、支持 Maven/npm/Docker/PyPI 多协议 | UI 略旧、企业版功能要付费 | 中小团队首选，自己搭 |
| **Artifactory**（JFrog） | 企业级权限/审计、与 CI/CD 集成更深 | 商业版收费、社区版功能受限 | 大型企业、合规要求强 |
| **阿里云效 / 腾讯 CODING 制品仓库** | 免运维、与云上 CI/CD 打通 | 锁定云厂商、跨云迁移有成本 | 已上云的中小团队 |
| **GitHub Packages / GitLab Package Registry** | 与代码仓库一体 | 私网访问需配额外鉴权、企业级用得不多 | 开源项目分发 |

> 这里以**最常见的 Nexus**为例展开。Artifactory/云效的概念基本一致，只是 UI 不同。

---

## 二、Nexus 仓库三种角色

Nexus 里的 repository 分三种类型，理解这个再看后续配置才不会懵：

```
┌──────────────────────────────────────────────────────────────┐
│  hosted（宿主仓库）：存内部上传的 jar                         │
│      ├── releases     正式版（不允许覆盖）                    │
│      └── snapshots    快照版（同 version 可反复覆盖）         │
│                                                              │
│  proxy（代理仓库）：缓存外部仓库                              │
│      ├── central      代理 Maven Central                     │
│      └── aliyun       代理阿里云镜像（国内加速）              │
│                                                              │
│  group（仓库组）：聚合多个仓库，对外暴露一个 URL              │
│      └── public       通常聚合 hosted + proxy                 │
└──────────────────────────────────────────────────────────────┘
```

**关键点**：开发者在 `settings.xml` 里只配 `group` 的 URL（如 `<nexus>/repository/maven-public/`）就够了——Nexus 内部自己决定从 hosted 还是 proxy 取。

---

## 三、`settings.xml` 完整配置

`settings.xml` 路径：`~/.m2/settings.xml`（用户级），或 Maven 安装目录下的 `conf/settings.xml`（全局）。

### 3.1 `<servers>`：仓库凭据

```xml
<servers>
    <server>
        <!-- id 必须和 mirrors / pom 中引用的 id 一致，否则 401 -->
        <id>company-nexus</id>
        <username>your-username</username>
        <password>your-password</password>
        <!-- 生产环境推荐用 master password 加密：mvn --encrypt-password -->
    </server>
</servers>
```

> ⚠️ **最常见踩坑**：`server.id` ≠ `mirror.id` 或 `repository.id`，部署/拉取时报 `401 Unauthorized`。Maven 是按 id 匹配凭据的，不是按 URL。

### 3.2 `<mirrors>`：镜像

```xml
<mirrors>
    <mirror>
        <id>company-nexus</id>
        <!-- mirrorOf 决定哪些请求走这个镜像 -->
        <mirrorOf>*,!central</mirrorOf>
        <name>Company Nexus</name>
        <url>https://nexus.your-company.com/repository/maven-public/</url>
    </mirror>
</mirrors>
```

`mirrorOf` 写法对比：

| 写法 | 含义 | 何时用 |
| --- | --- | --- |
| `*` | 所有仓库请求都走该镜像 | 公司强制全量走私仓（最常见） |
| `*,!central` | 除 `central` 外都走镜像 | 让中央依赖直连 Maven Central（速度可能更快） |
| `external:*` | 仅代理外部仓库（不代理 localhost / file://） | 调试时常用 |
| `central` | 仅代理中央仓库 | 只想加速中央，私仓直连 |

> 推荐写 `*` 强制走私仓——这是大多数公司的标准做法，便于审计和缓存。

### 3.3 `<profiles>`：私仓 SNAPSHOT 支持

默认情况下，**Maven 中央仓库不允许 SNAPSHOT**——必须显式声明私仓支持 SNAPSHOT，否则 `mvn install` 拉不到团队的 `1.0-SNAPSHOT` 包：

```xml
<profiles>
    <profile>
        <id>company</id>
        <repositories>
            <repository>
                <id>company-nexus</id>
                <url>https://nexus.your-company.com/repository/maven-public/</url>
                <releases>
                    <enabled>true</enabled>
                </releases>
                <snapshots>
                    <enabled>true</enabled>
                    <updatePolicy>always</updatePolicy>  <!-- 每次都检查更新 -->
                </snapshots>
            </repository>
        </repositories>
    </profile>
</profiles>

<activeProfiles>
    <activeProfile>company</activeProfile>
</activeProfiles>
```

`updatePolicy` 可选值：

| 值 | 行为 |
| --- | --- |
| `always` | 每次构建都检查更新（团队协作必选，否则拿不到最新 SNAPSHOT） |
| `daily`（默认） | 一天检查一次 |
| `interval:N` | 每 N 分钟检查一次 |
| `never` | 不检查 |

---

## 四、项目 `pom.xml` 配置部署目标

只有需要**上传 jar 到私仓**的项目才需要这段（普通业务项目不需要）：

```xml
<distributionManagement>
    <repository>
        <!-- id 必须和 settings.xml 中 server.id 一致 -->
        <id>company-nexus</id>
        <name>Company Releases</name>
        <url>https://nexus.your-company.com/repository/maven-releases/</url>
    </repository>
    <snapshotRepository>
        <id>company-nexus</id>
        <name>Company Snapshots</name>
        <url>https://nexus.your-company.com/repository/maven-snapshots/</url>
    </snapshotRepository>
</distributionManagement>
```

> Maven 会根据当前 `<version>` 是否带 `-SNAPSHOT` 后缀，自动选择推到哪个仓库。

---

## 五、上传 jar 到私仓

### 5.1 标准方式：`mvn deploy`

```bash
# 清空 → 编译 → 打包源码 → 上传（跳过测试）
mvn clean source:jar deploy -DskipTests
```

**API 包必须打 source jar**，否则使用方在 IDE 里看不到方法注释/参数说明。在 `pom.xml` 加：

```xml
<plugin>
    <groupId>org.apache.maven.plugins</groupId>
    <artifactId>maven-source-plugin</artifactId>
    <executions>
        <execution>
            <id>attach-sources</id>
            <goals>
                <goal>jar</goal>
            </goals>
        </execution>
    </executions>
</plugin>
```

### 5.2 已有 jar 文件直接上传：`deploy:deploy-file`

适合**没有源码、只有第三方 jar** 要传到私仓的场景（比如某个内部 SDK 只给了 jar）：

```bash
mvn deploy:deploy-file \
    -DgroupId=com.example \
    -DartifactId=my-sdk \
    -Dversion=1.0.0 \
    -Dpackaging=jar \
    -Dfile=/path/to/my-sdk-1.0.0.jar \
    -Durl=https://nexus.your-company.com/repository/maven-releases/ \
    -DrepositoryId=company-nexus
```

> `-DrepositoryId` 必须和 `settings.xml` 的 `server.id` 对应，否则 401。

### 5.3 SNAPSHOT vs RELEASE 区别

| 维度 | SNAPSHOT | RELEASE |
| --- | --- | --- |
| 版本号 | `1.0.0-SNAPSHOT` | `1.0.0` |
| 重复部署 | ✅ 允许覆盖（同 version 多次 deploy） | ❌ 不允许（需删了重传或换 version） |
| 客户端缓存 | 按 `updatePolicy` 重新拉 | 一次缓存永久使用 |
| 适用场景 | 开发阶段日常迭代 | 对外正式发布 |

**生产线版本必须是 RELEASE**，不允许引用 SNAPSHOT——因为 SNAPSHOT 内容会变，今天能跑，明天可能跑不了。

---

## 六、生产踩坑 TOP 5

### 1. `401 Unauthorized` 部署失败

**根因**：90% 是 `<server>` / `<mirror>` / `<repository>` 的 `id` 不一致。

**排查**：

```bash
# 加 -X 看完整请求（含使用了哪个凭据）
mvn deploy -X | grep -i 'auth\|server'
```

### 2. `Cannot deploy artifact from the local repository`

**根因**：试图把本地仓库（`~/.m2/repository`）里的 jar 直接上传，Maven 不允许。

**修复**：把 jar 复制到其他目录后再用 `deploy:deploy-file`。

### 3. SNAPSHOT 没拉到最新

**根因**：`<snapshots><updatePolicy>` 是 `daily`（默认），同事 1 分钟前刚 deploy 你拉不到。

**修复**：改成 `always`，或加 `-U` 强制更新：

```bash
mvn clean install -U
```

### 4. 部分依赖走私仓，部分走中央仓库（混乱）

**根因**：`<mirrorOf>` 写得太宽（`*`），但又显式声明了 `<repository>`，导致走向不可控。

**修复**：要么全走私仓（`*` + 所有依赖都通过 group 仓库代理），要么明确分流（`*,!central`）。

### 5. 私仓重启后客户端构建失败：`Could not transfer artifact... (502)`

**根因**：Nexus 重启过程中代理仓库 metadata 还没恢复，客户端拿不到 `maven-metadata.xml`。

**修复**：等服务恢复后清理本地 `_remote.repositories` 缓存：

```bash
find ~/.m2/repository -name '_remote.repositories' -delete
mvn clean install -U
```

---

## 七、面试高频追问

### Q1：为什么 Nexus 要分 hosted / proxy / group 三种仓库？

让职责分离：hosted 存内部 jar、proxy 缓存外部 jar、group 对外只暴露一个 URL。客户端不关心来源，运维可以独立调整代理策略而不影响开发。

### Q2：SNAPSHOT 和 RELEASE 在 Nexus 里物理存储有差别吗？

有。SNAPSHOT 仓库**允许同 version 反复部署**，每次部署会生成带时间戳的物理文件（`my-api-1.0-20260101.123456-1.jar`），同时维护一个最新指针；RELEASE 仓库**禁止覆盖**，部署相同 version 会直接报错。

### Q3：`mirrorOf=*` 和 `mirrorOf=*,!central` 选哪个？

看公司策略：
- **强管控公司**：`*`，所有依赖必须经过私仓审计/缓存。
- **追求速度**：`*,!central`，让 Maven Central 直连官方 CDN，私仓只做内部包分发。

实际上 99% 的公司都选 `*`，因为合规和审计需求 > 速度。

### Q4：Maven 怎么知道一个依赖是 SNAPSHOT 还是 RELEASE？

**纯字符串匹配**：version 字段以 `-SNAPSHOT` 结尾就是快照版，否则就是正式版。Maven 完全按这个后缀决定走哪个仓库、是否允许覆盖。

### Q5：私仓怎么做权限控制？

Nexus / Artifactory 都支持基于 role 的访问控制：
- 开发账号：对 `releases` 仓库**只读**，对 `snapshots` 可读写。
- CI/CD 账号：对 `releases` 可写（CI 才能发布正式版本）。
- 匿名账号：通常关闭，避免泄露内部 jar。

### Q6：怎么排查"我同事 deploy 了，我却拉不到"？

四个排查点：
1. 同事是否真的 deploy 成功？去 Nexus UI 找一下对应的 GAV。
2. 你的 `<updatePolicy>` 是 `daily`？加 `-U` 试试。
3. 本地 `~/.m2/repository` 里是否有损坏的 `.lastUpdated` 文件？删掉重试。
4. 是否在多个 mirror/profile 下走错了仓库？`mvn help:effective-settings` 看实际生效配置。

---

## 八、答题模板（60 秒）

> Maven 私仓的核心价值是**内部包分发 + 外部包缓存代理 + 依赖审计**。
> 落地用 **Nexus / Artifactory**，仓库分三类：**hosted 存内部包**、**proxy 缓存外部包**、**group 对外聚合一个 URL**。
> 客户端配置在 `settings.xml`：
> ① **`<servers>`** 配凭据；
> ② **`<mirrors>`** 配 `mirrorOf=*` 让所有请求走私仓；
> ③ **`<profiles>`** 显式开启 `<snapshots>` 才能拉到团队的 SNAPSHOT 包。
> 项目部署时 `pom` 加 `<distributionManagement>` 区分 release / snapshot 仓库，`mvn deploy` 自动按 version 后缀路由。
> 最常见的坑是 **`server.id` 和 `mirror.id` 不一致导致 401**，其次是 SNAPSHOT 的 `updatePolicy=daily` 导致拉不到同事的最新版。

---

## 九、相关文档

- [配置 SSH 密钥](配置%20SSH%20密钥.md) — Git/服务器免密登录
- [Software 模块](README.md) — 工具/软件速查首页
