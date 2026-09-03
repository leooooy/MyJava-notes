# Software

> 开发过程中常用工具/软件的使用速查 + 学习资料外链合集：Maven 私仓、SSH、Excel、参考博客等。
>
> 这里的内容**不属于面试核心模块**，更偏「翻一下就能用」的备忘录性质，与 [Java](../Java/README.md) / [JVM](../JVM/README.md) / [MySQL](../MySQL/README.md) 等技术专题区分开来。

---

## 模块导航

| 文档 | 一句话定位 |
| --- | --- |
| [Maven 私仓](Maven%20私仓.md) | Nexus 三种仓库角色、`settings.xml` 三段配置、`mvn deploy` 命令、SNAPSHOT vs RELEASE、401 排查 |
| [Maven 编译排查实录](Maven%20编译排查实录.md) | 真实排障案例：`NoClassDefFoundError`（无包名）→ Eclipse JDT 软错误字节码 → `javap` 取证 → `-DskipTests` vs `-Dmaven.test.skip` 等 |
| [SLF4J 绑定排查实录](SLF4J%20绑定排查实录.md) | 真实排障案例：`kubectl logs` 看不到业务日志 → 日志格式对比 / SLF4J 启动告警 / `dependency:tree` 三刀定位 → 传递依赖里的 `logback-classic` 抢走 SLF4J binder 让 `log4j2-prod.xml` 整份失效 |
| [配置 SSH 密钥](配置%20SSH%20密钥.md) | Git/服务器免密登录：密钥生成、原理（公钥/私钥/authorized_keys）、多机共享、常见踩坑 |
| [Excel 速查](excel.md) | 高频公式备忘：列转行 `TEXTJOIN`、批量拼接 `PHONETIC` |
| [学习资料](学习资料.md) | 长期收藏的高质量学习资源外链：Arthas / Kafka / NIO / Redis 多级缓存 / K8s / 风控 / 优秀博主 |

---

## 收录原则

- **写一次能省事很多次**：每隔几个月就要查一下、记不住完整命令的小操作。
- **环境无关**：避免出现公司内网地址、账号密码等只在特定环境可用的内容（这类内容写在团队 Wiki 而不是这里）。
- **能直接复制**：命令、公式、配置片段优先，少长篇大论。
