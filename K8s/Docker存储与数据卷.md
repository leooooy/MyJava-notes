# Docker 存储与数据卷

> **容器内写数据走的是 UnionFS 写时复制层——容器删了数据就没**。要持久化必须挂载到容器外，三种方式：**Volume**（Docker 管理目录，标准答案）、**Bind Mount**（挂宿主机绝对路径，开发调试用）、**tmpfs**（内存，敏感数据用）。K8s 的 PV/PVC 就是把这套抽象上升到集群级。
>
> 本篇要解决面试官四个连环追问：
>
> ① **为什么容器内不能放数据？**——UnionFS CoW + 写性能差 + 容器删数据就没
> ② **Volume / Bind Mount / tmpfs 怎么选？**——三种各有适用场景
> ③ **为什么 Java 应用日志写到容器层是反模式？**——磁盘炸 + 性能 + 故障排查
> ④ **容器数据怎么演进到 K8s PV/PVC？**——从单机到集群的存储抽象
>
> 跟其它模块的关系：
> - 前置：[Docker 容器原理](./Docker容器原理.md) UnionFS 章节
> - 下游：[存储与持久化](./存储与持久化.md) 是这套思想的集群级版本

---

## 一、为什么容器层不能放数据？

容器启动时 OverlayFS 在镜像之上叠了一个**可写层（upperdir）**，所有未挂载到 Volume 的写入都落到这一层。**问题三连**：

```
1. 容器删了，写过的数据全丢
   docker rm container → upperdir 整个删除
   生产事故：MySQL 跑容器层，容器一重启数据没了

2. 写性能差
   第一次改文件 → CoW：从 lower 复制整文件到 upper（GB 级文件可能卡住）
   高频写场景：日志、临时文件、热数据 → 性能直降 50%+

3. 占节点本地磁盘 inode
   100 个容器各产生 GB 级日志 → 节点磁盘炸 → kubelet evict Pod
   K8s 节点 NotReady 经典根因
```

**铁律**：容器层只放**镜像内容 + 启动期一次性配置**；任何运行期产生的数据（日志、缓存、用户上传、DB 数据）必须挂 Volume。

---

## 二、三种挂载方式

### 2.1 全景对比

| 维度 | **Volume** | **Bind Mount** | **tmpfs** |
| --- | --- | --- | --- |
| 管理者 | Docker（`/var/lib/docker/volumes/`） | 用户（任意宿主路径） | 内存（不落盘） |
| 路径可见性 | Docker 内部路径，宿主难直接看 | 用户指定，完全可见 | 不存在物理路径 |
| 跨主机 | 配 driver 可以（nfs / 云盘） | ❌ 仅本机 | ❌ 仅当前容器 |
| 容器删 | Volume 保留（`-v` 创建），需 `docker volume rm` 显式删 | 宿主目录不动 | tmpfs 直接消失 |
| 性能 | 接近原生 | 接近原生 | 最快（内存） |
| 适用 | **生产首选** | 开发调试 / 配置文件挂载 | 敏感数据（密钥）/ 临时缓存 |
| docker run 语法 | `-v vol_name:/path` | `-v /host/abs:/path` | `--tmpfs /path` 或 `--mount type=tmpfs` |

### 2.2 Volume 实操

```bash
# 创建命名 Volume
docker volume create app_data
docker volume ls
docker volume inspect app_data

# 启动容器挂载
docker run -d -v app_data:/var/lib/mysql --name db mysql

# 删除 Volume（容器先删 / Volume 不被引用）
docker volume rm app_data

# 自动清理无主 Volume
docker volume prune
```

**Volume 在宿主上的真实位置**：`/var/lib/docker/volumes/app_data/_data/`——但**生产不要直接读写这个路径**，应通过 Docker API 操作。

### 2.3 Bind Mount 实操

```bash
# 挂宿主路径进容器（双向同步）
docker run -d -v /opt/myapp/conf:/etc/nginx/conf.d:ro nginx

# :ro = 容器内只读（防容器误改宿主）
# :z / :Z = SELinux 标签（CentOS 必用）
```

**Bind Mount 经典用法**：
- 开发期挂源码进容器（改代码立即生效，不重新构建镜像）
- 挂配置文件（nginx.conf / application.yml）
- 挂日志目录到宿主（外部日志收集器读取）

**安全风险**：`-v /:/host` 类操作 = 容器内 root 能改宿主任何文件 → 等于把宿主交出去。生产**禁止挂宿主敏感路径**（/、/etc、/var/run/docker.sock）。

### 2.4 tmpfs 实操

```bash
# 挂内存盘到容器
docker run -d --tmpfs /tmp:rw,size=100m,mode=1777 nginx

# 用途
# 1. 敏感数据：密钥临时文件（不落盘 → 容器删完全消失）
# 2. 高频 IO 临时缓存：每个请求生成的临时文件
# 3. 测试 / 隔离：tmpfs 不影响宿主磁盘
```

**关键属性**：
- 容器停止 → tmpfs 消失（连数据带"目录"）
- 大小受限于内存 + 算入容器 cgroup memory limit
- 不能跨容器共享

---

## 三、Volume Driver：跨主机共享存储的桥

```bash
# 安装 NFS driver（local-persist / convoy / netshare 等）
# 或用内置 local driver + NFS mount option

docker volume create \
  --driver local \
  --opt type=nfs \
  --opt o=addr=192.168.1.100,rw \
  --opt device=:/exports/data \
  shared_vol

docker run -v shared_vol:/data app
```

**Driver 类型**：
- **local**（默认）：本机磁盘 / NFS / CIFS
- **云盘**：AWS EBS / Azure Disk / GCE PD（每家云厂商一个 plugin）
- **分布式存储**：Ceph RBD / GlusterFS / Portworx

**这套思想 → K8s 的 CSI（Container Storage Interface）**：CSI 把存储驱动从容器运行时解耦出来，每家存储厂商写一个 CSI 插件，K8s 通过 CSI 调用。详见 [存储与持久化](./存储与持久化.md)。

---

## 四、Volume vs Bind Mount 选择决策树

```
要持久化数据？
   ├─ 是
   │   ├─ 生产环境？
   │   │   ├─ 是 → Volume（Docker 管，可对接云盘 / NFS）
   │   │   └─ 否（开发）
   │   │       ├─ 需要修改源码立即生效？→ Bind Mount（挂宿主 src 目录）
   │   │       └─ 否 → Volume（行为更接近生产）
   │   └─ 跨主机共享？
   │       ├─ 是 → Volume + NFS/Ceph driver
   │       └─ 否 → 任意
   └─ 否（临时数据）
       ├─ 敏感数据 / 不能落盘 → tmpfs
       ├─ 仅当前容器 → 不挂载（容器层就好，反正会删）
       └─ 用完即丢 → tmpfs（性能最优）
```

---

## 五、与 K8s PV/PVC 的承接关系

```
单机 Docker：
  docker run -v app_data:/var/lib/mysql ...
            └─ 直接指定 Volume

K8s（多节点 / 集群级）：
  Pod yaml 写：
    volumes:
      - name: data
        persistentVolumeClaim:
          claimName: mysql-pvc      ← 申请单（PVC）
                          │
                          ▼
                     PVC 绑到一个 PV（集群级存储资源）
                          │
                          ▼
                     PV 实际指向 NFS / 云盘 / Ceph
                     （由 StorageClass + CSI 驱动动态创建）
```

**为什么要这么复杂？**——单机 Volume 跟节点绑定（节点挂了数据就没），K8s 要的是**节点透明的存储**：Pod 调度到任何节点都能挂到同一个 PV。详见 [存储与持久化](./存储与持久化.md)。

**K8s Volume 类型对照（与 Docker 对应）**：

| K8s Volume 类型 | 等价于 Docker | 用途 |
| --- | --- | --- |
| `emptyDir` | tmpfs / 节点本地空目录 | Pod 生命周期内临时数据 |
| `hostPath` | Bind Mount | 挂节点路径（跟节点绑定，慎用） |
| `configMap` / `secret` | Bind Mount + 文件生成 | 配置 / 密钥注入 |
| `persistentVolumeClaim` | Volume + Driver | 跨节点持久化（生产标准） |
| `csi` | Volume Driver 升级版 | 厂商存储接入 |

---

## 六、生产踩坑

### 坑 1：日志写容器层 → 节点磁盘炸

**现象**：节点磁盘 90%+，kubelet 触发 evict 把所有 Pod 撵走 → 节点 NotReady → 业务雪崩。`du -sh /var/lib/docker/overlay2/<container>/diff` 看到某容器 200G。

**根因**：Java 应用 log4j 默认写到 `/app/logs/`——这个目录没挂 Volume，全在容器层。容器从来不删（Pod 只重启不删容器），日志一直涨。

**修复**：
- **正确做法**：日志写 stdout/stderr → Docker 自动落到节点 `/var/lib/docker/containers/<id>/<id>-json.log` → fluentd / vector 采集到 ELK
- **次选做法**：log 目录挂 emptyDir Volume + sidecar 容器读取转发
- **最差做法**：挂 hostPath（跟节点绑定，迁移就丢）

### 坑 2：MySQL 数据没挂 Volume → 容器重启数据没

**现象**：开发环境 MySQL 跑容器，PR merge 触发重新部署 → 数据没了。

**根因**：`docker run mysql` 没加 `-v`，数据全在容器层 upperdir。

**修复**：

```bash
docker run -d \
  -v mysql_data:/var/lib/mysql \      # 命名 Volume
  -e MYSQL_ROOT_PASSWORD=xxx \
  --name mysql mysql:8.0
```

K8s 等价：StatefulSet + VolumeClaimTemplate（详见 [工作负载](./工作负载.md)）。

### 坑 3：Bind Mount 权限问题

**现象**：容器内进程用 UID=1000 跑，宿主目录 owner 是 root → 容器进程写不了。

**根因**：Bind Mount 不改文件 owner，容器内 UID 跟宿主 UID 是同一个数字（USER Namespace 默认不开）。

**修复**：
- 宿主目录 `chown 1000:1000 /opt/myapp/data`
- 或容器以 root 跑（牺牲安全）
- 或开 USER Namespace 做 UID 映射（复杂）

K8s 中靠 `securityContext.fsGroup`：

```yaml
securityContext:
  fsGroup: 1000     # K8s 自动 chgrp 挂载目录到 1000
```

### 坑 4：删容器没删 Volume → 磁盘悄悄涨

**现象**：节点磁盘逐月增长，找不到大文件占用——`docker volume ls` 一看，1000+ 个 dangling Volume。

**根因**：`docker run -v /data ...` 不指定名字会创建匿名 Volume；`docker rm` 容器但不带 `-v` 不会删 Volume。

**修复**：
- 删容器加 `-v`：`docker rm -v container`
- 定期 `docker volume prune` 清理无主 Volume
- 用命名 Volume，方便管理

### 坑 5：Bind Mount 挂 docker.sock 安全灾难

**现象**：CI 容器为了用 docker 命令挂了 `-v /var/run/docker.sock:/var/run/docker.sock` → 容器逃逸 = 拿到宿主 root。

**根因**：docker.sock 是 dockerd 的 Unix socket，有它就等于有宿主 root 权限——能 docker run 任何容器、能挂宿主 / 进容器、能访问所有数据。

**修复**：
- 用 **socket-proxy**（精细化授权）
- 用 **kaniko / buildah** 在 Pod 里直接构建镜像，不依赖 dockerd
- 实在要挂用 rootless docker

---

## 七、面试高频追问

**Q1：为什么容器层不能放数据？**

A：① **持久性差**：容器删了 upperdir 整个删；② **写性能差**：CoW 第一次改文件要复制整个文件到 upper（GB 级文件卡死）；③ **磁盘炸**：日志这种持续增长的数据写容器层 → 节点磁盘满 → kubelet evict → NotReady。**铁律**：运行期产生的数据（日志、DB、缓存、用户上传）必须挂 Volume。

**Q2：Volume 和 Bind Mount 区别？**

A：① **管理权**：Volume 由 Docker 管（`/var/lib/docker/volumes/`），Bind Mount 用户指定任意路径；② **生命周期**：删容器 Volume 默认保留（要 `rm -v`），Bind Mount 的宿主目录从不变；③ **跨主机**：Volume 配 driver 能接 NFS / 云盘；Bind Mount 仅本机；④ **生产场景**：Volume 是首选；Bind Mount 主要开发期挂源码、配置文件用。

**Q3：tmpfs 用在什么场景？**

A：① **敏感数据**：密钥 / token 临时文件，不落盘 → 容器删数据完全消失；② **高频 IO 临时缓存**：每请求生成临时文件不写磁盘；③ **测试隔离**：避免影响宿主。**注意**：算入容器 cgroup memory limit；容器停 tmpfs 跟着没。K8s 的 `emptyDir` 加 `medium: Memory` 等价于 tmpfs。

**Q4：写时复制（CoW）的代价是什么？**

A：第一次写大文件要**把整个文件从 lowerdir 复制到 upperdir**——GB 级文件可能卡几秒到几十秒。还有 **inode 翻倍**（merged + upper 都占）、**page cache 浪费**（修改后老文件的 cache 还在）。所以生产**容器层禁止存放频繁写入的大文件**——必须挂 Volume，让数据走真实文件系统的 inode 而不是 OverlayFS。

**Q5：Java 应用日志怎么收集才对？**

A：**绝对不要写容器层**。三种正确方式：① **Stdout/Stderr 直出**——log4j appender 配 ConsoleAppender，Docker 自动落到节点 JSON 日志，fluentd / vector 采集 → ELK；② **挂 emptyDir + sidecar**——logs 目录挂 Volume，sidecar 容器读取后发 Kafka；③ **集中式日志库**（log4j 直接 send 到 Kafka / Loki）。**最坑做法**：挂 hostPath（节点绑死、迁移丢）；挂 PVC（共享读写有锁问题）。

**Q6：怎么备份 Docker Volume 的数据？**

A：

```bash
# 经典做法：用辅助容器挂 Volume + 宿主目录，tar 打包
docker run --rm \
  -v mydata:/data \
  -v $(pwd):/backup \
  alpine \
  tar czf /backup/mydata-$(date +%F).tar.gz -C /data .

# 恢复
docker run --rm \
  -v mydata:/data \
  -v $(pwd):/backup \
  alpine \
  tar xzf /backup/mydata-2024-01-15.tar.gz -C /data
```

K8s 中用 **Velero**（PVC 级备份 + 恢复）或存储厂商自带快照（CSI snapshot）。

**Q7：Bind Mount 挂宿主目录，容器和宿主 UID 对应吗？**

A：**默认完全对应**——容器内 UID=1000 = 宿主 UID=1000，因为 USER Namespace 默认不开。所以容器 root（UID=0）== 宿主 root，在 Bind Mount 路径上想干嘛干嘛——**这就是 docker.sock 挂载 = 宿主 root 权限的根本原因**。开 USER Namespace 后映射成宿主非 root（如 100000），但兼容性问题多，生产较少用。

**Q8：从 Docker Volume 怎么演进到 K8s PV/PVC？**

A：单机 Volume → K8s 加了**集群级抽象**：① **PV（PersistentVolume）** = 集群里的存储资源（背后是 NFS / Ceph / 云盘）；② **PVC（PersistentVolumeClaim）** = 用户的申请单（"我要 5G 块存储"）；③ **StorageClass** = 动态创建模板（按 PVC 自动创 PV）；④ **CSI** = 存储厂商插件接口。**好处**：Pod 调度到任何节点都能挂到同一存储；管理员管 PV，开发只填 PVC，职责分离。

**Q9：emptyDir 适用场景？**

A：① **Pod 内多容器共享数据**——sidecar 模式（主容器写日志，sidecar 读日志发 Kafka）；② **临时缓存**——大 KV 解压后存放（Pod 重启会丢，但能省下次解压时间）；③ **MapReduce 中间结果**——Job 运行期间用。**关键属性**：跟 Pod 同生死，**Pod 重建数据没**——所以不能放任何不能丢的数据。

**Q10：为什么挂 docker.sock 有安全风险？**

A：docker.sock 是 dockerd 的 Unix socket——有它就能 `docker run 任意容器 --privileged -v /:/host`，**等于直接拥有宿主 root 权限**：① 能挂载宿主根目录读写；② 能跑特权容器修改宿主内核参数；③ 能访问其他容器的所有数据。CI / 构建场景历史上经常这么做（让容器内能 docker build），是最常见的容器逃逸路径。**生产替代**：用 kaniko / buildah 不依赖 dockerd 直接构建；或用 socket-proxy 限制只能调用安全 API。

**Q11：能跨容器共享数据吗？**

A：**3 种方式**：① **共享 Volume**（最常用）——多个容器 `-v shared_vol:/data` 挂同一个 Volume；② **`--volumes-from <container>`**——继承另一个容器的所有 Volume 挂载；③ **emptyDir（K8s）**——同一 Pod 内多容器自动共享。注意**并发写**：多个容器同时改一个文件没文件锁会冲突，需要应用层协调（DB / Redis 锁）。

**Q12：Volume 性能跟容器层比？**

A：**Volume 接近原生磁盘性能；容器层（OverlayFS upperdir）写性能损耗 30~50%**（CoW 开销 + OverlayFS 元数据查找）。所以**高 IO 应用必须挂 Volume**——MySQL / Kafka / Elasticsearch 在容器层跑性能直接打 5 折。生产 SSD 节点 + 块存储（云盘 / Ceph RBD）= 接近物理机性能。

---

## 八、答题模板（60 秒话术）

> Docker 容器内写数据走的是 **UnionFS 的写时复制层（upperdir）**——容器删了数据就没，且大文件 CoW 性能差。要持久化必须挂载到容器外，**3 种方式**：① **Volume**（Docker 管理目录，生产首选）；② **Bind Mount**（挂宿主任意路径，开发期挂源码 / 配置用）；③ **tmpfs**（内存，敏感数据 / 高频 IO 临时缓存）。
>
> **Volume 三件事要做对**：① 用**命名 Volume**（`docker volume create`），不要匿名；② 删容器加 `-v` 顺带删 Volume，否则 dangling Volume 慢慢吃掉磁盘；③ 跨主机用 **driver**（NFS / 云盘 / Ceph）—— 这套思想升级就是 K8s 的 CSI。
>
> **Java 应用日志**永远写 stdout/stderr，让 Docker 落 JSON 日志到节点，外部 fluentd 采集；**绝对不要写容器层**——节点磁盘炸是经典事故。
>
> **5 大生产坑**：① 日志写容器层炸节点；② MySQL 没挂 Volume 重启丢数据；③ Bind Mount UID 不匹配权限报错；④ 匿名 Volume 留尸偷偷涨；⑤ 挂 docker.sock = 宿主 root 权限（容器逃逸捷径）。
>
> **K8s 对应关系**：emptyDir = tmpfs/节点空目录；hostPath = Bind Mount（节点绑死慎用）；PVC + StorageClass + CSI = Volume Driver 集群级版本（PV/PVC 解耦管理员与开发，CSI 解耦存储厂商）。

---

## 九、相关文档

- 前置：[Docker 容器原理](./Docker容器原理.md) — UnionFS / 写时复制
- 下游：[存储与持久化](./存储与持久化.md) — K8s PV/PVC/StorageClass/CSI
- 配套：[工作负载](./工作负载.md) — StatefulSet 用 VolumeClaimTemplate
- 联动：[ConfigMap 与 Secret](./ConfigMap与Secret.md) — 配置注入也是 Volume 的一种
