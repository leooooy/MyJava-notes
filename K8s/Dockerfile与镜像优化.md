# Dockerfile 与镜像优化

> **镜像不是压缩包，而是按指令一层层叠出来的只读层**——每条 `RUN/COPY/ADD` 都生成一个新层，**缓存命中靠"上一条指令是否变了"**，多阶段构建靠"丢掉构建期产物只留运行期"把 Java 镜像从 1.5G 压到 200M。
>
> 本篇要解决面试官四个连环追问：
>
> ① **为什么 Dockerfile 里 RUN 要用 `&&` 串而不是分开写？**——每条 RUN = 一层，分开写会膨胀镜像
> ② **多阶段构建凭什么瘦身？**——丢掉 Maven / 编译器 / 测试工具，只留运行期产物
> ③ **构建缓存怎么命中？**——按指令哈希 + 上下文哈希逐层比对，命中复用
> ④ **COPY vs ADD / CMD vs ENTRYPOINT / ARG vs ENV 怎么选？**——每对都有踩过坑的标准答案
>
> 跟其它模块的关系：
> - 前置：[Docker 容器原理](./Docker容器原理.md) 中 UnionFS 章节是镜像分层的根基
> - 配套：[Docker 存储与数据卷](./Docker存储与数据卷.md) 讲容器层之外的持久化
> - 上层：[K8s 架构总览](./K8s架构总览.md) 中 kubelet 拉取镜像的链路

---

## 一、为什么镜像分层与瘦身这么重要？

镜像不是普通文件——它是**容器交付的标准包装**，影响 4 件事：

| 维度 | 1.5G 镜像 | 200M 镜像 |
| --- | --- | --- |
| Pull 时间（千兆内网） | 12s | 1.6s |
| 节点缓存能存几个版本 | 5 个 | 40 个 |
| CI / CD 流水线总时长 | 8min | 3min |
| 安全攻击面 | 完整 OS + 工具链 | 仅 JRE + 业务 jar |

**核心矛盾**：构建期需要的工具（Maven / GCC / npm / git）大多数运行期不需要——但传统单阶段 Dockerfile 把它们全打进了镜像。**多阶段构建是 Docker 17.05 后的标准答案**。

---

## 二、Dockerfile 指令全景

```
FROM        ← 起点（基础镜像）
ARG         ← 构建期变量（不进运行环境）
ENV         ← 运行期环境变量（进运行环境）
WORKDIR     ← 工作目录
COPY/ADD    ← 复制文件进镜像（每条一层）
RUN         ← 执行命令（每条一层 → 谨慎合并）
USER        ← 切换执行用户（生产用非 root）
EXPOSE      ← 文档作用，声明端口（不会真的开端口）
HEALTHCHECK ← 容器健康检查（容器层面，跟 K8s Probe 是两回事）
ENTRYPOINT  ← 容器主进程（不可被 docker run 覆盖）
CMD         ← 默认参数（可被 docker run 覆盖）
```

**指令分两类**：
- **影响镜像分层**的：`FROM / RUN / COPY / ADD`——每条生成一个新只读层
- **只改元数据**的：`ENV / WORKDIR / USER / EXPOSE / CMD / ENTRYPOINT / HEALTHCHECK / LABEL / ARG`——不生成层，只改 image config

> **关键直觉**：每多一层 = 多一次写、多一份元数据、多一次 OverlayFS lookup。**层数太多（>50）会拖慢 mount 和拉取**，所以要合理合并 RUN。

---

## 三、多阶段构建（Multi-Stage Build）

### 3.1 Java 多阶段：1.5G → 200M

**单阶段（反例）**：

```dockerfile
FROM maven:3.9-openjdk-17    # 包含 Maven、JDK、git、curl，约 600M
WORKDIR /app
COPY . .
RUN mvn clean package -DskipTests
CMD ["java", "-jar", "target/app.jar"]
# 最终镜像 ≈ 1.5G（Maven + JDK + 源码 + .m2 缓存 + jar）
```

**多阶段（标准答案）**：

```dockerfile
# 第一阶段：构建（用完即扔）
FROM maven:3.9-eclipse-temurin-17 AS builder
WORKDIR /app
# 先 copy pom.xml 单独下载依赖（依赖变化频率低，用缓存）
COPY pom.xml .
RUN mvn dependency:go-offline -B
# 再 copy 源码（变化频繁，独立成层）
COPY src ./src
RUN mvn package -DskipTests -B

# 第二阶段：运行（轻量基础镜像）
FROM eclipse-temurin:17-jre-jammy        # 仅 JRE，约 230M
WORKDIR /app
COPY --from=builder /app/target/app.jar app.jar
USER 1000:1000                           # 非 root
EXPOSE 8080
ENTRYPOINT ["java", "-XX:+UseContainerSupport", "-XX:MaxRAMPercentage=75", "-jar", "app.jar"]
# 最终镜像 ≈ 240M（JRE + jar）
```

**核心机制**：`FROM ... AS builder` 命名阶段；`COPY --from=builder` 只把产物拷过来，构建阶段镜像直接丢弃。

### 3.2 Go 多阶段：200M → 15M（极致）

```dockerfile
FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY go.mod go.sum .
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o app .

# scratch = 完全空镜像（只有你 COPY 进去的东西）
FROM scratch
COPY --from=builder /src/app /app
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
ENTRYPOINT ["/app"]
# 最终镜像 ≈ 15M
```

**为什么 Go 能用 scratch**：静态编译（`CGO_ENABLED=0`）后是单一二进制，不依赖任何 libc。**Java 用不了 scratch**——JVM 依赖 glibc/musl。

### 3.3 Node 多阶段：node_modules 的痛

```dockerfile
FROM node:20-alpine AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production    # 只装生产依赖

FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci                      # 装全部依赖（含构建工具）
COPY . .
RUN npm run build

FROM node:20-alpine
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
USER node
CMD ["node", "dist/main.js"]
```

---

## 四、构建缓存命中机制

Docker 构建逐层执行，**每层都做缓存命中判断**：

```
对每条指令 i：
  key = hash(指令文本 + 上一层结果 hash + COPY/ADD 涉及的源文件 hash)
  if 本地有这个 key 的层缓存:
      复用 → 跳过执行
  else:
      执行该指令 → 生成新层
      之后所有指令的缓存都失效（因为 parent hash 变了）
```

**关键推论**：**指令顺序决定缓存命中率**——把变化频率低的放上面，变化频率高的放下面。

### 反例（坏顺序）

```dockerfile
FROM maven:3.9-openjdk-17
WORKDIR /app
COPY . .                       # ❌ 整个项目放第一行
RUN mvn dependency:go-offline  # 改任何源码都会让这层失效，重下所有依赖
RUN mvn package
```

每次代码改一个字符 → COPY 层失效 → 后面所有层全失效 → 重新下 .m2 依赖（首次几分钟）。

### 正例（好顺序）

```dockerfile
FROM maven:3.9-openjdk-17
WORKDIR /app
COPY pom.xml .                 # ✅ 先 copy 不变频率低的
RUN mvn dependency:go-offline  # 依赖只在 pom 改时重下
COPY src ./src                 # 源码放后面
RUN mvn package
```

源码改了只重跑后两层，依赖层缓存命中——构建从 5min 降到 30s。

### BuildKit `--mount=type=cache`

Docker 18.09+ 启用 BuildKit 后还可以挂载缓存目录：

```dockerfile
# syntax=docker/dockerfile:1.4
FROM maven:3.9-openjdk-17
WORKDIR /app
COPY pom.xml .
# .m2 目录挂成持久化缓存（跨构建复用）
RUN --mount=type=cache,target=/root/.m2 mvn dependency:go-offline
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 mvn package
```

**收益**：即使 pom.xml 改了（增量加几个依赖），不会全部重下；只下新增的。

### `.dockerignore`

构建上下文（context）= COPY 的源——默认是 Dockerfile 所在目录全部内容。**不写 `.dockerignore` 的后果**：`.git/`、`node_modules/`、`target/`、IDE 配置全被传进 docker daemon，构建慢且镜像可能泄露。

```
# .dockerignore
.git
.gitignore
node_modules
target
*.log
.env
.idea
.vscode
README.md
```

---

## 五、镜像瘦身策略对比

| 策略 | 收益 | 代价 |
| --- | --- | --- |
| **多阶段构建** | 镜像 1.5G → 200M | Dockerfile 略复杂 |
| **基础镜像换 slim/alpine/distroless** | 200M → 50M | musl libc 与 glibc 兼容性问题（少数 native 库需 glibc） |
| **scratch（仅 Go）** | 15M | 无 shell、无调试工具，排查全靠 logs |
| **合并 RUN + 删缓存** | 减少 100~500M | 单条 RUN 太长不可读，容错差 |
| **`.dockerignore`** | 构建快、镜像稳 | 几乎无 |
| **`--squash`（实验功能）** | 把多层压一层 | 失去层缓存复用、不推荐 |

### 5.1 基础镜像 5 档选型

| 镜像 | 大小 | 自带 | 适用 |
| --- | --- | --- | --- |
| `eclipse-temurin:17` | ~450M | 完整 JDK + Ubuntu 工具链 | 开发期 / 需要 jcmd / jstack 调试 |
| `eclipse-temurin:17-jre` | ~230M | JRE only + Ubuntu | 生产标准选择 |
| `eclipse-temurin:17-jre-alpine` | ~170M | JRE + Alpine（musl libc） | 极致瘦身、不依赖 glibc |
| `gcr.io/distroless/java17-debian12` | ~190M | JRE only，**无 shell** | 安全敏感、最小攻击面 |
| `scratch` | 0 | 啥也没有 | 仅 Go 静态二进制 |

**Alpine 经典坑**：musl libc 跟 glibc 不完全兼容——某些 Java native 库（特别是 Netty 的 epoll 原生实现）在 Alpine 上要装 `libc6-compat`，或干脆换 `eclipse-temurin:17-jre-jammy`（Ubuntu）。

### 5.2 RUN 合并

```dockerfile
# ❌ 反例：每条 RUN 一层，且 apt 缓存进了层
RUN apt-get update
RUN apt-get install -y curl wget vim
RUN apt-get install -y nginx

# ✅ 正例：单层 + 删缓存
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl wget vim nginx \
 && rm -rf /var/lib/apt/lists/*
```

**为什么删缓存要在同一个 RUN 里？**——每个 RUN 单独提交一层，删除操作只能减少**当前层**的内容；分两个 RUN 的话，删除层之上看不到旧文件，但下层还在，镜像总大小不变。

---

## 六、关键指令对：踩过坑的选择

### 6.1 COPY vs ADD

```
COPY src dest    → 单纯复制文件 / 目录
ADD  src dest    → 复制 + 自动解压 tar / 自动下载 URL
```

**生产准则**：**永远用 COPY**。`ADD` 的两个"魔法"都是坑：
- ADD `app.tar.gz /app` 会自动解压——但有时你就想要 tar 包本身
- ADD `https://example.com/x.zip /` 会自动下载——但下载失败处理不友好、缓存语义乱

要解压 / 下载就显式 `RUN curl ... && tar ...`，可控。

### 6.2 CMD vs ENTRYPOINT

| 指令 | 角色 | 是否可被 `docker run xxx` 覆盖 |
| --- | --- | --- |
| `ENTRYPOINT` | 主进程 | **不能**（用 `--entrypoint` 才行） |
| `CMD` | ENTRYPOINT 的默认参数 / 默认主进程 | **能**（`docker run img xx` 中 xx 替换 CMD） |

**生产标准用法**：

```dockerfile
ENTRYPOINT ["java", "-jar", "app.jar"]   # 主进程不可变
CMD ["--spring.profiles.active=prod"]    # 默认参数，可被覆盖
# docker run img --spring.profiles.active=test → 走测试环境
```

**`exec` 形式（数组）vs `shell` 形式（字符串）**：

```dockerfile
# ❌ shell 形式：实际上跑的是 /bin/sh -c "java -jar app.jar"
CMD java -jar app.jar
# 副作用：sh 是 PID 1，java 是子进程 → SIGTERM 给 sh，java 收不到 → K8s 优雅停机失效

# ✅ exec 形式：java 直接是 PID 1，能收 SIGTERM
CMD ["java", "-jar", "app.jar"]
```

**Pod 优雅停机失败 90% 的根因就是这里**——详见 [发布与弹性伸缩](./发布与弹性伸缩.md)。

### 6.3 ARG vs ENV

```dockerfile
ARG VERSION=1.0          # 仅构建期可见，可被 --build-arg 覆盖
ENV APP_VERSION=$VERSION  # 运行期环境变量（进容器）
ENV LOG_LEVEL=INFO        # 运行期默认值
```

**安全坑**：**ARG 不要传密钥**——`docker history` 能看到 ARG 值；用 BuildKit 的 `--mount=type=secret`：

```dockerfile
# syntax=docker/dockerfile:1.4
RUN --mount=type=secret,id=npm_token \
    NPM_TOKEN=$(cat /run/secrets/npm_token) npm install
# docker build --secret id=npm_token,src=$HOME/.npmrc .
```

### 6.4 USER：必须切非 root

容器内默认 root 是经典反模式——一旦容器逃逸（参考 [Docker 容器原理](./Docker容器原理.md) runc CVE）就是宿主 root。

```dockerfile
# 创建专用非 root 用户
RUN groupadd -r app && useradd -r -g app -u 1000 app
USER 1000:1000
```

K8s 还可以通过 `securityContext.runAsNonRoot: true` 强制：镜像里没有 USER 指令的 Pod 直接拒绝调度。

---

## 七、生产踩坑

### 坑 1：层顺序错导致缓存全失效

**现象**：CI 上每次构建都要 5 分钟下 .m2 依赖（pom 没变）。

**根因**：Dockerfile 第一行就 `COPY . .`，整个项目改任何一个文件都让 dependency 层失效。

**修复**：分两次 COPY——先 `COPY pom.xml`，再 `RUN mvn dependency:go-offline`，最后 `COPY src`。构建时间 5min → 30s。

### 坑 2：ADD 自动解压坑

**现象**：`ADD config.tar.gz /app/config/` 部署后发现 /app/config 里直接是解压后的文件，找不到原 tar 包，下游脚本失败。

**根因**：ADD 对本地 tar 自动解压，且行为不文档化。

**修复**：改成 `COPY config.tar.gz /app/`，需要解压时显式 `RUN tar -xzf /app/config.tar.gz -C /app/config/`。

### 坑 3：镜像里残留密钥

**现象**：`docker history img:tag` 看到某层执行过 `RUN echo "API_KEY=xxx" > /app/.env`——密钥永久留在镜像层中（即便后续层 rm 也只是上层覆盖，下层还在）。

**根因**：把密钥写进 RUN 命令、或用 `ARG SECRET` 通过 `--build-arg` 传进来——`docker history` 都能看到。

**修复**：① BuildKit `--mount=type=secret` 不进层；② 运行期通过 K8s Secret 注入；③ `docker scout` / `trivy` 扫描镜像有没有泄密。

### 坑 4：Alpine 时区缺失 + DNS 行为差异

**现象**：迁到 Alpine 后日志全 UTC；某些 Java HTTP 客户端解析域名超慢。

**根因**：Alpine 默认不含 tzdata；musl 的 DNS 解析器并发查 IPv4/IPv6（glibc 串行），某些老 DNS 服务器返回 NXDOMAIN 慢。

**修复**：

```dockerfile
RUN apk add --no-cache tzdata \
 && cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
 && echo "Asia/Shanghai" > /etc/timezone

# 严重 DNS 问题考虑换 jammy/debian 基础镜像
```

### 坑 5：CMD 用 shell 形式 → 优雅停机失效

**现象**：K8s 滚动更新时连接突然断、客户端报错 502/connection reset。

**根因**：`CMD java -jar app.jar` → 实际跑 `/bin/sh -c "java -jar app.jar"` → sh 是 PID 1，java 是子进程；K8s 发 SIGTERM 给 PID 1（sh），sh 不转发，java 等到 30s 后被 SIGKILL 强杀。

**修复**：改成 `CMD ["java", "-jar", "app.jar"]` exec 形式。或装 `tini` 作为 PID 1 转发信号：`ENTRYPOINT ["/tini", "--"]`。

### 坑 6：构建上下文过大

**现象**：`docker build` 第一行打印 `Sending build context to Docker daemon  2.3GB`，传上下文就要 1 分钟。

**根因**：项目根有 `target/`、`node_modules/`、`.git/`，没写 `.dockerignore`。

**修复**：补全 `.dockerignore`；上下文压到 5MB 内。

---

## 八、面试高频追问

**Q1：Dockerfile 每条指令都生成一层吗？**

A：**只有 FROM / RUN / COPY / ADD 生成新只读层**。`ENV / WORKDIR / USER / CMD / ENTRYPOINT / EXPOSE / LABEL / ARG / HEALTHCHECK` 不生成层，只改 image config（镜像元数据）。所以"层数 = FROM + RUN + COPY + ADD 的总数"。

**Q2：为什么多阶段构建能瘦身？原理是什么？**

A：单阶段构建把构建期工具（Maven / GCC / npm）一起打进镜像；多阶段把构建拆成多个 `FROM` 阶段，最后一个阶段用轻量基础镜像，**只通过 `COPY --from=<stage>` 把产物（jar / 二进制 / dist）拷过来**，前面阶段的镜像直接被丢弃（不进最终镜像）。Java 典型场景从 1.5G 压到 200M（丢掉 Maven + .m2 + 源码）。

**Q3：构建缓存怎么命中？为什么改一行代码会让构建变慢？**

A：Docker 逐层执行，**每层 hash = 指令文本 + 上一层 hash + COPY/ADD 源文件内容 hash**——任何一个变了，本层及之后所有层缓存全失效。常见反例：Dockerfile 第一行就 `COPY . .` → 改任何一个源文件都让依赖下载层失效，重下整个 .m2。**修复**：把变化频率低的放前面（pom.xml → 依赖下载）、变化频率高的放后面（源码 → 编译）。

**Q4：COPY 和 ADD 有什么区别？应该用哪个？**

A：**COPY 单纯复制；ADD 多两个"魔法"——自动解压本地 tar、自动下载 URL**。生产**永远用 COPY**——ADD 的自动行为不可控（你想要 tar 包本身但被解压了）、URL 下载缓存不稳定。要解压就显式 `RUN tar -xzf`，要下载就 `RUN curl -fSL`，控制权在自己手里。

**Q5：CMD 和 ENTRYPOINT 有什么区别？怎么配合？**

A：**ENTRYPOINT 是主进程（不可被 docker run 覆盖）、CMD 是参数（可被 docker run 覆盖）**。生产标准：`ENTRYPOINT ["java", "-jar", "app.jar"]` + `CMD ["--profile=prod"]`，`docker run img --profile=test` 切环境。**还要用 exec 形式（数组）**——shell 形式（字符串）会通过 sh 执行，sh 成 PID 1 不转发 SIGTERM，K8s 优雅停机失效。

**Q6：怎么把 Java 镜像从 1.5G 瘦到 200M？**

A：**三件套**：① 多阶段构建（丢 Maven + 源码）；② 基础镜像换 `eclipse-temurin:17-jre-alpine`（仅 JRE + Alpine，170M）；③ 加 `.dockerignore` 不传无关文件。**还要小心**：删 apt 缓存必须在同一个 RUN 里（分层删除不减小镜像）；非 root 用 `USER 1000`；时区显式设 Asia/Shanghai。

**Q7：为什么删除文件没让镜像变小？**

A：镜像层是**叠加只读层**，删除操作只能在**当前层**生效——下层文件没变，依然占空间。比如：

```dockerfile
RUN curl -O big.tar.gz   # 第 1 层：+200M
RUN rm big.tar.gz        # 第 2 层：删除，但第 1 层 200M 还在
```

**修复**：合并到一个 RUN：`RUN curl -O big.tar.gz && tar ... && rm big.tar.gz`——同一层内 add/del 互相抵消。

**Q8：BuildKit 比传统构建好在哪？**

A：① **并行构建**：多个独立的 FROM 阶段并行执行；② **`--mount=type=cache`** 持久化缓存目录（跨构建复用 .m2 / npm / go mod cache）；③ **`--mount=type=secret`** 密钥不进层（解决坑 3）；④ **`--mount=type=ssh`** 复用宿主 SSH 私钥拉私有仓；⑤ **更智能的缓存**（比传统 layer cache 命中率高）。Docker 18.09+ 启用：`DOCKER_BUILDKIT=1` 或全局开。

**Q9：HEALTHCHECK 跟 K8s Probe 是一回事吗？**

A：**两套独立机制**。Dockerfile `HEALTHCHECK` 是 Docker 引擎层面的——`docker ps` 会看到 healthy/unhealthy；但 **K8s 完全无视它**，K8s 只看 Pod spec 里的 `livenessProbe / readinessProbe / startupProbe`。**所以容器化给 K8s 用，Dockerfile 里别写 HEALTHCHECK**（无效），全部交给 K8s Probe 配置。

**Q10：镜像安全扫描怎么做？**

A：标配 `trivy` / `docker scout` / `Snyk`：扫 CVE、扫密钥泄漏、扫 SBOM。**关键策略**：① 用最小基础镜像（distroless / alpine）减少攻击面；② CI 流水线集成扫描，CVE 高危直接拒绝合并；③ 定期 rebuild 拉最新基础镜像（CVE 补丁）；④ 私有 registry 禁用 latest tag，强制版本号。

**Q11：能不能在 Dockerfile 里 cd 然后 RUN？**

A：**不能用 cd**——`RUN cd /app` 只在该 RUN 子进程生效，下一条 RUN 又回到 / 了。**用 `WORKDIR /app`** 持久切换；`WORKDIR` 不生成新层，只改镜像 config。

**Q12：多个 ENTRYPOINT / CMD 会怎样？**

A：**只有最后一条生效**——前面的被覆盖。**ENTRYPOINT 和 CMD 是 image config 字段，不是层**——只能存一份。所以 `FROM` 一个有 ENTRYPOINT 的基础镜像后，自己又写 ENTRYPOINT 会完全覆盖父镜像的。

---

## 九、答题模板（60 秒话术）

> Docker 镜像是 **按 Dockerfile 指令一层层叠出来的只读层 + UnionFS 联合挂载**——每条 `FROM/RUN/COPY/ADD` 生成一层，`ENV/WORKDIR/USER/CMD` 这些只改元数据不生层。
>
> **缓存命中靠"上一条指令是否变了"**：每层 hash = 指令 + 上一层 hash + COPY 源文件 hash，任何一个变了之后所有层全失效。所以 **把变化频率低的放前面**（pom.xml → 下依赖）、变化频率高的放后面（源码 → 编译），构建时间从 5min 降到 30s。
>
> **多阶段构建是镜像瘦身核心手段**：`FROM ... AS builder` 跑 Maven 编译，最终 `FROM jre-slim` 只 `COPY --from=builder` 拿 jar。Java 镜像从 1.5G 压到 200M（丢 Maven + 源码 + .m2）；Go 加 `CGO_ENABLED=0` 静态编译能直接 `FROM scratch` 压到 15M。
>
> **生产 6 标配**：① 多阶段；② 基础镜像选 `eclipse-temurin:17-jre`（不要完整 JDK）；③ `.dockerignore` 排 `.git`/`node_modules`；④ `RUN ... && rm cache` 同层删；⑤ `USER 1000` 非 root；⑥ `CMD ["java", "-jar", "app.jar"]` exec 形式（shell 形式 sh 成 PID 1 → K8s 优雅停机失效）。
>
> **常见坑**：① ADD 自动解压不可控（永远用 COPY）；② ARG 传密钥能被 docker history 看到（用 BuildKit `--mount=type=secret`）；③ 分层删除不减小镜像（要同一 RUN 里 add 完再 rm）；④ HEALTHCHECK K8s 不认（全交给 Probe）。

---

## 十、相关文档

- 前置：[Docker 容器原理](./Docker容器原理.md) — UnionFS 分层 + CoW 是镜像分层的根基
- 配套：[Docker 网络](./Docker网络.md) / [Docker 存储与数据卷](./Docker存储与数据卷.md)
- 上层：[K8s 架构总览](./K8s架构总览.md) — kubelet 通过 CRI 调容器运行时拉镜像
- 联动：[发布与弹性伸缩](./发布与弹性伸缩.md) — 优雅停机依赖 ENTRYPOINT exec 形式
- 联动：[JVM/jvm 参数](../JVM/jvm参数.md) — 容器化 JVM 必配项
