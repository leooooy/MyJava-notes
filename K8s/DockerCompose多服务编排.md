# Docker Compose 多服务编排（本地开发实战）

> **Docker Compose 是"单机版的多服务编排"**——一个 `docker-compose.yml` 描述一组容器（DB / 缓存 / 消息队列 / 业务服务）的镜像、端口、依赖、网络，`docker compose up` 一键拉起。它是**本地开发环境的 K8s 平替**：K8s 解决"生产集群多节点编排"，Compose 解决"本地一台机器把整套依赖跑起来"。理解 Compose 的 **profiles（按需启动）、环境变量插值、depends_on 健康检查、容器网络与端口映射**，既是日常开发刚需，也能反向加深对 K8s 同类机制的理解。
>
> 本篇从一次真实的"本地起项目全挂"排错出发，讲清 4 个高频坑：
>
> ① **profiles 按需启动**：怎么只起一个子集，base 服务为什么总跟着起
> ② **`${VAR}` 插值**：为什么 `env_file` 配了却还报变量为空
> ③ **全量校验**：没选中的服务为什么也能让整个 project 非法
> ④ **WebRTC/容器网络**：容器里的服务对外宣告了错误 IP，浏览器连不上
>
> 跟其它篇的关系：
> - 前置：[Docker 网络](./Docker网络.md)（端口映射 / NAT 是本篇 WebRTC 坑的底层）
> - 对照：[工作负载](./工作负载.md) / [Service 与 kube-proxy](./Service与kube-proxy.md)（Compose 的 service ≈ K8s 的 Deployment+Service 的简化版）
> - 配置：[ConfigMap 与 Secret](./ConfigMap与Secret.md)（Compose 的 `.env` / `env_file` ≈ K8s 的 ConfigMap/Secret）

---

## 一、Compose vs K8s：本地编排 vs 集群编排

| 维度 | Docker Compose | Kubernetes |
| --- | --- | --- |
| 定位 | 单机多容器编排 | 多节点集群编排 |
| 描述文件 | `docker-compose.yml` | 一堆 `Deployment/Service/...` YAML |
| 一个服务 | `services:` 下一项 | Deployment + Service + ... |
| 按需启动 | `profiles` + `--profile` | namespace / label / kustomize overlay |
| 配置注入 | `.env`（插值）+ `env_file`（容器环境） | ConfigMap / Secret |
| 依赖顺序 | `depends_on` + `condition: service_healthy` | initContainer / readinessProbe |
| 服务发现 | service 名即 DNS（同 network） | Service ClusterIP + CoreDNS |
| 扩缩容 | `--scale`（少用） | Deployment replicas + HPA |

> **一句话**：Compose 是"把 K8s 那套声明式编排砍到单机、够本地开发用"的版本。本地起一套带 Postgres / Redis / MinIO / Milvus / LiveKit / Kafka 的依赖栈，Compose 比手动 `docker run` 一串方便太多。

---

## 二、profiles：按需启动一个子集

一个大 `docker-compose.yml` 往往定义了几十个服务（所有团队成员、所有场景共用）。**profiles** 让你只启动需要的子集。

```yaml
services:
  postgres:            # 没有 profiles → 永远启动（base 服务）
    image: postgres:16-alpine
  milvus:
    image: milvusdb/milvus:v2.4.17
    profiles: [milvus]   # 只有 --profile milvus 才起
  kafka:
    image: ${KAFKA_IMAGE}
    profiles: [im]       # 只有 --profile im 才起
```

```bash
docker compose up -d                              # 只起 base（无 profiles 的服务）
docker compose --profile milvus --profile livekit up -d   # base + milvus + livekit
```

**关键认知**：

- **没有 `profiles:` 键的服务 = base，永远启动**，无论你选了哪些 profile。
- profile 只做**加法**（把额外服务加进来），不会减少 base。

> **踩坑（脚本依赖）**：项目常用一个 `start.sh` 包装，按"要起哪个业务"自动算出 profiles。本案例的脚本用 `yq`（YAML 命令行解析器）从一个 `services.yaml` 读出每个业务对应的 profiles：
>
> ```bash
> mapfile -t svc_profiles < <(yq ".services.${svc}.profiles[]" "$SERVICES_FILE" 2>/dev/null || true)
> ```
>
> **`yq` 没装时**，`2>/dev/null || true` 把错误**静默吞掉** → profiles 解析为空 → 拼成不带 `--profile` 的裸 `docker compose up` → 触发下面第三节的"全量校验"崩溃。表象是"compose 报错"，真因是"yq 缺失"。排查脚本类问题，要警惕这种被 `|| true` 吃掉的静默失败。

---

## 三、`${VAR}` 插值 vs `env_file`：两个完全不同的东西

这是 Compose 最反直觉的坑。`docker-compose.yml` 里有两处都跟"环境变量"有关，但来源完全不同：

| 写法 | 谁来填值 | 作用 |
| --- | --- | --- |
| `image: ${KAFKA_IMAGE}` | **compose 文件插值**：只从 **shell 环境** 或 **同目录 `.env`** 读 | 渲染 compose 文件本身 |
| `env_file: .env.openim` | 把文件内容注入**容器运行时环境** | 给容器进程用 |

**致命误区**：以为 `env_file: .env.openim` 能给 `${KAFKA_IMAGE}` 提供值。**不能！** `env_file` 只影响**容器内部环境**，对 compose 文件里的 `${...}` **插值无效**。`${...}` 插值只认两个来源：shell 里 `export` 的变量，或 compose 文件**同目录下的 `.env`**（compose 默认自动加载的那个）。

**本案例的崩溃链**：

```
base 里 kafka:  image: ${KAFKA_IMAGE}
${KAFKA_IMAGE} 的值在 .env.openim 里，但它只被当 env_file 用、不被插值读
同目录又没有 .env
→ ${KAFKA_IMAGE} 渲染成空字符串
→ image: ""
→ service "kafka" has neither an image nor a build context specified: invalid compose project
→ 整个 project 非法，什么都起不来
```

**修法**（二选一）：

```bash
# A. 显式指定 env-file 供插值
docker compose -f docker-compose.yml --env-file .env.openim --profile milvus up -d

# B. 造一个同目录 .env（compose 默认自动加载）
cp .env.openim .env
```

> **对照 K8s**：K8s 里 ConfigMap/Secret 注入的是容器环境（≈ `env_file`），而 YAML 模板的参数化（≈ `${VAR}` 插值）是 Helm values / kustomize 干的——两层也是分开的，别混。

---

## 四、Compose 会"全量校验"——没选中的服务也能拖垮整个 project

承接上一节一个反直觉点：即使你 `--profile milvus --profile livekit`（**没**选 `im`，本不该起 kafka），compose **仍然会校验整个文件里所有服务**的 image 插值。kafka 的 `image: ""` 让 compose 在**解析阶段**就判定 `invalid compose project` → **连 milvus/livekit 都起不来**。

```bash
# 即便不选 im，这条也会因为 kafka 空 image 而整体失败：
docker compose --profile milvus --profile livekit config   # 退出码 1
```

**启示**：Compose 的合法性是**全文件级**的，不是"只校验本次要起的服务"。所以**任何一个服务的 `${IMAGE}` 变量为空**，都会让整个 project 无法启动——哪怕那个服务这次根本不打算起。这也是为什么"base 服务的镜像变量"必须始终有值（用 `.env` 或 `--env-file` 兜住）。

> 排查手法：`docker compose ... config` 只做"渲染+校验"不真启动，是定位这类问题的利器；`--dry-run up` 能看"实际会创建哪些容器"而不真拉起。

---

## 五、WebRTC / LiveKit 在 Docker 里的网络坑（接 Docker 网络篇）

容器里跑的实时音视频服务（LiveKit）有个 Docker 网络特有的坑，直接关联 [Docker 网络](./Docker网络.md) 的端口映射与 NAT。

**现象**：浏览器连 LiveKit，**信令（WebSocket :7880）通了**，但 `could not establish pc connection`（PeerConnection 建不起来，媒体走不通）。

**根因**：WebRTC 媒体走 **UDP + ICE**。LiveKit 要把"自己的可达地址"作为 ICE 候选告诉浏览器。在 Docker 里它默认只知道**容器内网 IP（172.x）**，浏览器在宿主上根本不可达 → ICE 失败 → PeerConnection 连不上。

配置里有个 `node_ip` 就是干这个的：

```yaml
# livekit.yaml
rtc:
  tcp_port: 7882
  udp_port: 7881
  node_ip: 127.0.0.1   # 宣告给浏览器的可达 IP
```

```yaml
# docker-compose.yml — 必须把 RTC 端口映射到宿主
ports:
  - "7880:7880"       # 信令 WS
  - "7881:7881/udp"   # RTC 媒体 UDP（缺它媒体必断）
  - "7882:7882"       # RTC 媒体 TCP 回退
```

**两个常见错法**：

1. `node_ip` 写成**别人机器的 IP**（如同事提交了 `192.168.0.40`）→ 你的浏览器去连那个 IP，连不上。本机浏览器调试应写 `127.0.0.1`（配合上面的端口映射，loopback 直达）；跨设备（手机连 PC）才写 PC 的局域网 IP。
2. **只映射了 7880（信令）没映射 7881/udp** → 信令通、媒体断，表现也是 `pc connection` 失败。

> **对照 K8s**：到了 K8s 里这个问题更复杂——WebRTC 这类需要大段 UDP 端口 + 宿主真实 IP 的服务，通常用 `hostNetwork: true` 或 NodePort 直接暴露，而不是走 ClusterIP/Ingress（Ingress 一般只代理 HTTP/WS，不转 UDP 媒体流）。本质和 Compose 这里一样：**让外部拿到一个真正能到达媒体端口的地址**。

---

## 六、小结速查

```
Compose 本地编排
├── profiles           无 profiles=base 永远起；--profile 做加法
├── ${VAR} 插值        只从 shell env / 同目录 .env 读，跟 env_file 无关
├── env_file           只注入容器运行时环境，不参与文件插值
├── 全量校验           任一服务 image 为空 → 整个 project 非法（哪怕没选中）
└── 排错工具           config（渲染+校验）、--dry-run up（看会起啥）

WebRTC/UDP 服务
├── node_ip            宣告宿主可达 IP（本机 127.0.0.1，跨设备用 LAN IP）
└── 端口映射           信令 + RTC UDP/TCP 都要映射，缺 UDP 则媒体断
```

| 坑 | 一句话 |
| --- | --- |
| profiles | 没 `profiles:` 的服务永远启动；脚本算 profile 常依赖 `yq`，缺了静默失败 |
| `${VAR}` vs `env_file` | 插值只读 shell/`.env`；`env_file` 只给容器进程，二者不通 |
| 空 image | 任一服务 `image: ${X}` 为空 → 整个 project invalid，连没选的服务也连累全场 |
| WebRTC node_ip | 容器要宣告宿主可达 IP + 映射 UDP 端口，否则信令通、媒体断 |

---

## 📌 案例出处（metaXsire）

- Compose profiles + base/im 划分：`infra/dev/docker-compose.yml`（`profiles: [milvus|livekit|im]`，kafka/postgres 无 profiles=base）
- `start.sh` 用 yq 读 profiles：`infra/dev/scripts/start.sh`（`yq ".services.${svc}.profiles[]"`）
- `${KAFKA_IMAGE}` 插值来源 `.env.openim`：`infra/dev/.env.openim`
- LiveKit RTC 配置（node_ip / udp_port）：`infra/dev/livekit.yaml`
- LiveKit 端口映射：`infra/dev/docker-compose.yml`（`7880` / `7881/udp` / `7882`）

---

## 相关篇

- [Docker 网络](./Docker网络.md)——端口映射 / NAT / bridge，本篇 WebRTC 坑的底层原理
- [ConfigMap 与 Secret](./ConfigMap与Secret.md)——K8s 版的配置注入，对照 Compose 的 `.env` / `env_file`
- [Service 与 kube-proxy](./Service与kube-proxy.md)——K8s 服务暴露，对照 Compose 的端口映射与 service 名 DNS
- [工作负载](./工作负载.md)——K8s 的 Deployment/StatefulSet，对照 Compose 的 service + depends_on
