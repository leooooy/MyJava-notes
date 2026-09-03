# Java 后端面试与架构笔记

> 一份**面向 3~10 年 Java 后端工程师**的学习与面试笔记，按大厂面试高频考点组织，覆盖 JVM / 并发 / Spring / MySQL / Redis / MQ / 分布式 / 微服务 / 中间件等核心模块。
>
> **写作视角**：以 10 年资深后端架构师 + 大厂面试官身份，重点讲清「**为什么这么设计**」「**踩过哪些生产坑**」「**面试官还会追问什么**」，而不只是堆砌「是什么」。

---

## 适合谁读

- **正在准备跳槽 / 面试的后端开发**：直接刷各模块的「答题模板」「面试高频追问」就能上场。
- **想跳出 CRUD、深入原理的工程师**：每篇文都从设计动机讲到 trade-off，不停留在 API 表面。
- **架构师候选人**：重点关注 **Distributed / Microservice / Middleware** 的事故复盘 / 性能优化。

---

## 模块速览

| 分类 | 模块 | 核心内容 |
| --- | --- | --- |
| **运行时基础** | [Java](Java/README.md) | 数据类型、集合、Lambda、Stream、异常、泛型、反射 |
|  | [JVM](JVM/README.md) | 内存模型、GC、G1、JIT、调优、线上排查 |
|  | [Concurrency](Concurrency/README.md) | JMM、Volatile、AQS、线程池、虚拟线程、伪共享 |
| **框架** | [Spring](Spring/README.md) | IoC、AOP、事务、SpringBoot 自动装配、Bean 生命周期 |
| **存储与中间件** | [MySQL](MySQL/README.md) | InnoDB、索引、MVCC、锁、事务、主从、分库分表 |
|  | [Redis](Redis/README.md) | 数据结构、持久化、集群、分布式锁、双写一致性 |
|  | [MQ](MQ/README.md) | RocketMQ 架构、可靠性、幂等、顺序、事务、堆积 |
| **网络与中间件** | [Network](Network/README.md) | TCP/HTTP/WebSocket、IO 模型、多路复用、零拷贝 |
|  | [Middleware](Middleware/README.md) | Netty、Nginx、RPC、Dubbo、Elasticsearch |
| **分布式** | [Distributed](Distributed/README.md) | CAP/BASE、一致性算法、分布式事务/锁/ID、一致性哈希、**Seata** |
|  | [Microservice](Microservice/README.md) | 服务注册发现、服务治理、限流、链路追踪、**Spring Cloud 全家桶**（Nacos/Feign/Sentinel/Gateway） |
| **云原生** | [K8s](K8s/README.md) | Docker 容器原理（Namespace/Cgroups/UnionFS）、Pod / Workload / Service / Ingress、调度、HPA、滚动发布 |
| **AI / 智能应用** | [AIAgent](AIAgent/README.md) | LLM 基础、Prompt、Function Calling、RAG、向量库、Agent 架构与框架、MCP、上下文/记忆、应用工程化、评估可观测、生产踩坑 |
| **其它** | [Software](Software/README.md) | 工具/软件速查（Maven 私仓、SSH、Excel）、[学习资料](Software/学习资料.md) |

---

## 推荐路径

- **新手入门（按依赖顺序）**：`Java → JVM → Concurrency → Spring → MySQL → Redis → MQ → Network → Middleware → Distributed → Microservice → K8s → AIAgent`
- **面试速通（30 天）**：每模块只看 README 的「面试高频题」+「答题模板」小节，每天 1 个模块。
- **架构方向**：重点深读 **Distributed / Microservice / Middleware** 中事故复盘 / 性能优化。

---

## 写作规范

每篇技术文档统一采用「**引子 → 原理图 → 关键机制 → 配置/取舍 → 对比选型 → 生产踩坑 → 面试追问 → 答题模板 → 相关文档**」九段结构，强调真实生产数字（线程池 200 / Buffer Pool 命中率 99% / 慢 SQL 0.5s 等），拒绝「大量」「很快」「较好」之类的空话。

详见 [CLAUDE.md](CLAUDE.md) 中的**面试文章通用规范**。

---

## 本地构建

仓库基于 [Honkit](https://github.com/honkit/honkit)（GitBook v3 维护版分叉）构建：

```bash
npm install              # 一次性安装 honkit + 插件
npx honkit serve         # 本地预览：http://localhost:4000
npx honkit build         # 生成静态站点到 _book/
```

> ⚠️ 不要使用全局安装的 `gitbook-cli`（已废弃，Node ≥ 14 会因 `graceful-fs` polyfill 报错）。详细说明见 [CLAUDE.md](CLAUDE.md)。

---

## 反馈与贡献

- 笔记中任何**事实性错误 / 过时信息**（如 JDK 版本演进、新版数据库特性），欢迎通过 issue 指出。
- 如需添加新笔记，请遵循 [CLAUDE.md](CLAUDE.md) 中的写作规范，并在 [SUMMARY.md](SUMMARY.md) 同步索引——这是最容易遗漏的步骤。
