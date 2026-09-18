# AI Agent 面试模块

> AI Agent / LLM 应用开发已经是 2025-2026 年大厂后端面试的"必问加分项"。无论你做的是 Java / Go / Python 后端，简历里只要写过 RAG、Agent、Function Calling，面试官就会按这条线一直追问到底。
>
> 本模块从**后端工程化视角**切入：不教你训 Transformer、不写 Attention 公式，而是回答一个工程师真正会被追问的问题——**"你怎么把 LLM 接进生产系统、怎么保证它稳定、便宜、可观测？"**
>
> 整个模块按 **基础协议 → 核心能力 → 工程化 → 评估生产** 四层组织，13 篇内容文，每篇 15-25KB，强制带「原理 + 取舍 + 面试追问 + 生产踩坑 + 答题模板」五件套。

---

## 一、模块导航

### Layer 1 — 基础与协议（3 篇）

| 文档 | 一句话定位 |
|---|---|
| [LLM 基础与面试视角](LLM基础与面试视角.md) | Token / 上下文窗口 / 推理参数 / 主流模型对比 / 流式 vs 非流式 / Token 计费与成本估算 |
| [Prompt Engineering](PromptEngineering.md) | 角色机制 / Few-shot / CoT / 结构化输出 / **Prompt 注入与防御**（生产高危） |
| [Function Calling 与 Tool Use](FunctionCalling与ToolUse.md) | OpenAI / Anthropic / Gemini 协议对比 / 并行调用 / 流式 Tool Call / Schema 设计 / 防死循环 |

### Layer 2 — 核心能力（3 篇）

| 文档 | 一句话定位 |
|---|---|
| [RAG 检索增强生成](RAG检索增强生成.md) | 文档切分 / Embedding 选型 / Rerank / 混合检索 / HyDE / Query Rewrite / 引用可追溯 |
| [向量数据库与 Embedding](向量数据库与Embedding.md) | Milvus / pgvector / ES / Redis 选型 / HNSW vs IVF / 维度与量化 / 容量成本估算 |
| [Agent 架构模式](Agent架构模式.md) | ReAct / Plan-and-Execute / Reflection / Multi-Agent / 状态机 / 死循环防御 |

### Layer 3 — 工程化（4 篇）

| 文档 | 一句话定位 |
|---|---|
| [Agent 框架对比](Agent框架对比.md) | LangChain / LangGraph / AutoGen / Dify / **Spring AI / LangChain4j** Java 视角选型 |
| [上下文与记忆管理](上下文与记忆管理.md) | 短期 / 长期记忆 / 滑动窗口 / Summary Buffer / 重要性评分 / Memory Retrieval |
| [MCP 协议](MCP协议.md) | Model Context Protocol 全景 / Transport / Resource / Prompt / Tool / 与 Function Calling 区别 |
| [LLM 应用工程化](LLM应用工程化.md) | 流式 SSE / Token 限流 / Prompt Cache / 语义缓存 / 超时降级 / Fallback / 成本治理 |

### Layer 4 — 评估与生产（2 篇）

| 文档 | 一句话定位 |
|---|---|
| [Agent 评估与可观测性](Agent评估与可观测性.md) | 离线指标 / 在线指标 / LLM-as-Judge / RAGAS / Trace（Langfuse / OpenTelemetry GenAI） |
| [RAG 与 Agent 生产踩坑](RAG与Agent生产踩坑.md) | 10+ 真实案例：幻觉爆发 / 上下文超限 / 工具死循环 / 注入事故 / 成本爆炸 / 召回失配 |

### 番外 — 模型与工具（1 篇）

| 文档 | 一句话定位 |
|---|---|
| [Claude 介绍](Claude介绍.md) | Claude 模型家族（Opus/Sonnet/Haiku）/ Constitutional AI / Claude Code 作为自主编码 Agent 样本 / 终端 spinner 178 词彩蛋（含从二进制实抓的完整词表） |

---

## 二、面试高频题 → 文档映射

> 按面试官从浅到深的追问顺序排列。带 ⭐ 的是 **必背高频题**。

| # | 题目 | 文档 |
|---|---|---|
| 1 ⭐ | LLM 的上下文窗口是什么？1M context 意味着什么？为什么不是越长越好？ | [LLM 基础](LLM基础与面试视角.md) |
| 2 ⭐ | Token 是怎么算的？一个汉字几个 Token？英文呢？怎么估算 API 调用成本？ | [LLM 基础](LLM基础与面试视角.md) |
| 3 | temperature 和 top_p 的区别？什么场景该调到 0？ | [LLM 基础](LLM基础与面试视角.md) |
| 4 | 流式输出怎么实现？SSE 和 WebSocket 怎么选？流式中断了 Token 怎么算？ | [LLM 基础](LLM基础与面试视角.md) / [工程化](LLM应用工程化.md) |
| 5 | 主流大模型怎么选？Claude / GPT / Gemini / DeepSeek / Qwen 各自强在哪？ | [LLM 基础](LLM基础与面试视角.md) |
| 6 ⭐ | Prompt 注入是什么？你们怎么防的？ | [Prompt Engineering](PromptEngineering.md) |
| 7 | System Prompt 和 User Prompt 的区别？为什么 System 不能完全防越狱？ | [Prompt Engineering](PromptEngineering.md) |
| 8 | CoT（Chain-of-Thought）有什么用？什么时候没用？ | [Prompt Engineering](PromptEngineering.md) |
| 9 | 怎么让 LLM 稳定输出 JSON？JSON Mode、Structured Output、Tool Use 强约束有啥区别？ | [Prompt Engineering](PromptEngineering.md) |
| 10 ⭐ | Function Calling 的底层协议是什么？OpenAI 和 Anthropic 写法有何不同？ | [Function Calling](FunctionCalling与ToolUse.md) |
| 11 | 并行 Tool Call 怎么处理？如果一个工具失败了，要不要重试？怎么告诉模型？ | [Function Calling](FunctionCalling与ToolUse.md) |
| 12 ⭐ | Tool 调用陷入死循环怎么办？你们生产怎么防的？ | [Function Calling](FunctionCalling与ToolUse.md) / [Agent 架构](Agent架构模式.md) |
| 13 | Tool Schema 的 description 字段重要吗？写得好和差差距有多大？ | [Function Calling](FunctionCalling与ToolUse.md) |
| 14 ⭐ | RAG 的完整流程画一下？为什么不能直接把所有文档拼到 Prompt 里？ | [RAG](RAG检索增强生成.md) |
| 15 ⭐ | 文档切分（Chunking）有哪些策略？固定切 / 语义切 / Late Chunking 怎么选？ | [RAG](RAG检索增强生成.md) |
| 16 | Embedding 模型怎么选？OpenAI / BGE / Voyage / Cohere？维度选 768 还是 1536？ | [RAG](RAG检索增强生成.md) / [向量库](向量数据库与Embedding.md) |
| 17 | Rerank 是干什么的？BGE-Reranker 和 Cohere Rerank 选哪个？延迟代价是多少？ | [RAG](RAG检索增强生成.md) |
| 18 | BM25 + 向量检索的混合检索怎么融合？RRF 是什么？ | [RAG](RAG检索增强生成.md) |
| 19 | 用户问"对比 A 和 B"，向量检索召回不准怎么办？HyDE 和 Query Rewrite 哪个好？ | [RAG](RAG检索增强生成.md) |
| 20 ⭐ | 向量数据库选型：Milvus / pgvector / ES dense_vector / Redis 怎么选？数据量边界在哪？ | [向量库](向量数据库与Embedding.md) |
| 21 | HNSW 和 IVF 的原理与取舍？写多读多的场景哪个好？ | [向量库](向量数据库与Embedding.md) |
| 22 | 1000 万文档 × 1024 维要多少内存？怎么用量化压缩到 1/4？ | [向量库](向量数据库与Embedding.md) |
| 23 | 元数据过滤（pre-filter vs post-filter）的性能差别？踩过什么坑？ | [向量库](向量数据库与Embedding.md) |
| 24 ⭐ | ReAct 模式 vs Plan-and-Execute 模式的区别？什么场景该用哪个？ | [Agent 架构](Agent架构模式.md) |
| 25 | Multi-Agent 的几种拓扑（Supervisor / Hierarchical / Network）什么场景用？ | [Agent 架构](Agent架构模式.md) |
| 26 | Agent 怎么防死循环？步数上限、Token 上限、成本上限怎么设？ | [Agent 架构](Agent架构模式.md) |
| 27 ⭐ | LangChain / LangGraph / AutoGen / Spring AI 怎么选？为什么大厂生产很少用 LangChain？ | [Agent 框架](Agent框架对比.md) |
| 28 | Java 后端怎么搞 Agent？Spring AI 和 LangChain4j 的区别？OpenAI SDK 直连有啥问题？ | [Agent 框架](Agent框架对比.md) |
| 29 | 上下文窗口快爆了怎么办？滑动窗口、Summary Buffer、向量记忆哪个适合 ToB 客服？ | [上下文与记忆](上下文与记忆管理.md) |
| 30 ⭐ | Anthropic Prompt Cache 是怎么省钱的？什么时候不命中？ | [工程化](LLM应用工程化.md) / [上下文与记忆](上下文与记忆管理.md) |
| 31 | MCP 是什么？跟 Function Calling 是什么关系？为什么 2025 年突然火？ | [MCP 协议](MCP协议.md) |
| 32 | MCP Server 的 stdio / SSE / Streamable HTTP 三种 Transport 区别？生产怎么选？ | [MCP 协议](MCP协议.md) |
| 33 ⭐ | 你怎么对 LLM 应用做限流？TPM 和 RPM 是什么？多租户怎么分配？ | [工程化](LLM应用工程化.md) |
| 34 ⭐ | LLM 应用怎么做语义缓存？Embedding 命中阈值设多少？怎么防错命中？ | [工程化](LLM应用工程化.md) |
| 35 | 主模型挂了或限流了怎么 Fallback？兜底链路怎么设计？ | [工程化](LLM应用工程化.md) |
| 36 ⭐ | RAG 怎么评估？RAGAS 五大指标是什么？为什么人工标注不可少？ | [评估与可观测](Agent评估与可观测性.md) |
| 37 | LLM-as-Judge 可信吗？怎么校准？ | [评估与可观测](Agent评估与可观测性.md) |
| 38 | 生产 LLM 应用怎么做 Trace？OpenTelemetry GenAI Convention 是什么？ | [评估与可观测](Agent评估与可观测性.md) |
| 39 ⭐ | 你们 RAG 在生产遇到的最大坑是什么？怎么解决的？ | [生产踩坑](RAG与Agent生产踩坑.md) |
| 40 ⭐ | LLM 应用一个月烧了多少钱？怎么砍下来？ | [工程化](LLM应用工程化.md) / [生产踩坑](RAG与Agent生产踩坑.md) |

---

## 三、推荐学习路径

### 路径 A：新手 / 转岗（按依赖顺序读）

```
LLM 基础  →  Prompt Engineering  →  Function Calling
                ↓
RAG 检索增强  →  向量数据库与 Embedding
                ↓
Agent 架构模式  →  Agent 框架对比
                ↓
上下文与记忆  →  MCP 协议
                ↓
LLM 应用工程化  →  评估与可观测性  →  生产踩坑
```

读完上面这条线，你能独立设计一个 ToB 客服 Agent + RAG 知识库。

### 路径 B：面试速通（30-60 分钟刷答题模板）

只看每篇的「答题模板（60 秒话术）」+「面试高频追问」两节即可：

1. **必背 5 篇**：[LLM 基础](LLM基础与面试视角.md) / [Function Calling](FunctionCalling与ToolUse.md) / [RAG](RAG检索增强生成.md) / [Agent 架构](Agent架构模式.md) / [LLM 应用工程化](LLM应用工程化.md)
2. **加分 4 篇**：[Prompt Engineering](PromptEngineering.md) / [向量数据库](向量数据库与Embedding.md) / [MCP](MCP协议.md) / [评估与可观测](Agent评估与可观测性.md)
3. **谈项目压箱底**：[生产踩坑](RAG与Agent生产踩坑.md)（背 2-3 个真实案例 + 修复方案，足够撑起 15 分钟项目深挖）

---

## 四、关键速记表

### 4.1 主流模型快速参考（2026 年初）

| 模型 | 上下文窗口 | 输入价/M Token | 输出价/M Token | 强项 |
|---|---|---|---|---|
| Claude Opus 4.7 | 1M | $15 | $75 | 复杂推理 / 长上下文 / Tool Use 稳定 |
| Claude Sonnet 4.6 | 1M | $3 | $15 | 平衡性价比 / Agent 主力 |
| Claude Haiku 4.5 | 200K | $1 | $5 | 高吞吐 / 简单分类 |
| GPT-5 | 400K | $5 | $15 | 通用能力 / Function Calling 生态成熟 |
| Gemini 2.5 Pro | 2M | $1.25 | $5 | 超长文本 / 多模态 |
| DeepSeek V3 | 128K | $0.27 | $1.10 | 国产首选 / 中文 / 价格屠夫 |
| Qwen 3 Max | 256K | $0.6 | $2.4 | 阿里云生态 / 国内合规 |

> **价格/M Token** 指每 100 万 Token 的费用。Claude / GPT 是美元，国产模型可对照人民币。

### 4.2 Embedding 模型对比（2026 年初）

| 模型 | 维度 | 价格 | 中文 | MIT 排行 | 适用 |
|---|---|---|---|---|---|
| `text-embedding-3-large` (OpenAI) | 3072（可降） | $0.13/M | ✅ | 中上 | 闭源应用 / 默认稳健 |
| `text-embedding-3-small` (OpenAI) | 1536（可降） | $0.02/M | ✅ | 中上 | 成本敏感 |
| `BGE-M3` (智源) | 1024 | 自部署 | ✅✅ | 顶尖（中文） | 国产 / 中英文混合 / 多语种 |
| `Voyage-3` | 1024 | $0.06/M | ✅ | 顶尖（英文） | RAG 专用 / 语义召回好 |
| `Cohere embed-v3` | 1024 | $0.10/M | ✅ | 中上 | 企业 / 多语种 |

### 4.3 向量数据库选型决策

| 场景 | 推荐方案 |
|---|---|
| 数据量 < 100 万、想快速 PoC | `pgvector`（已有 PG 直接加） / `Chroma`（本地嵌入式） |
| 数据量 100 万 ~ 10 亿、要专业向量库 | `Milvus`（云原生 / 集群） / `Qdrant`（Rust / 轻量） |
| 已有 ES 集群、不想多一套组件 | `Elasticsearch dense_vector` + HNSW |
| 已有 Redis、低延迟（< 5ms）小规模 | `Redis Search`（≤ 100 万向量） |
| Serverless / 不想运维 | `Pinecone`（贵但省心） |

详见 [向量数据库与 Embedding](向量数据库与Embedding.md)。

### 4.4 Agent 模式对比

| 模式 | 适用场景 | 优点 | 缺点 |
|---|---|---|---|
| **单 Agent + ReAct** | 简单任务、工具数 ≤ 10 | 实现简单 / 灵活 | 长链路易跑偏 / 步数失控 |
| **Plan-and-Execute** | 多步骤、可拆解任务 | 鲁棒 / 可中断 | 计划不准时全盘 GG |
| **Reflection / Self-Critique** | 高质量要求场景 | 输出质量 ↑ | Token 翻倍 |
| **Multi-Agent (Supervisor)** | 跨领域 / 角色分工 | 可扩展 | 协调成本高 / 难调试 |
| **状态机驱动** | 工作流型 / 业务约束强 | 可控 / 可审计 | 灵活性差 |

### 4.5 LLM 应用关键阈值速查

| 维度 | 典型值 | 说明 |
|---|---|---|
| 单次请求超时 | 流式 60s / 非流式 30s | 超过用户基本会跳出 |
| Tool 调用步数上限 | 8 ~ 15 步 | 超过强制中断防死循环 |
| 单次 Tool 错误重试 | 1 ~ 2 次 | 多次只会让模型更乱 |
| RAG Top-K 召回 | 5 ~ 20 | Rerank 后取 Top-3 ~ 5 |
| Embedding 命中相似度阈值 | 0.85 ~ 0.92 | 太低错命中、太高近似全 miss |
| Prompt Cache 命中阈值 | ≥ 1024 Token | Anthropic 文档中的最低长度 |
| TPM 限流 | Tier 1 ≈ 40K-80K | 看 OpenAI/Anthropic 账户层级 |
| 流式首 Token 延迟（TTFT） | 200ms ~ 1s | 超 2s 用户体感卡顿明显 |

### 4.6 Token 与字符换算（粗略经验）

| 语言 | 1 Token ≈ |
|---|---|
| 英文 | 4 字符 / 0.75 单词 |
| 中文 | 1.5 ~ 2 个字 |
| 代码 | 介于英文和中文之间，3 字符左右 |

> 估算公式：**英文 Token ≈ 词数 / 0.75；中文 Token ≈ 字数 × 1.7**。
>
> 详见 [LLM 基础与面试视角](LLM基础与面试视角.md)。

---

## 五、生产踩坑 TOP 10

> 跨文档汇总，是项目深挖环节面试官最爱听的故事。每一条都来自真实生产事故。

| # | 现象 | 根因 | 修复 | 详见 |
|---|---|---|---|---|
| 1 | 用户输入 "忽略前面所有指令" 后 LLM 真的就泄露了 System Prompt | 仅在 System 强调"不要泄露"不够，缺分隔符隔离 + 输出过滤 | 加结构化分隔符 + 输出层过滤敏感关键词 + Prompt 注入检测分类器 | [Prompt Engineering](PromptEngineering.md) |
| 2 | Tool 调用陷入死循环，单次对话烧了 200 美元 | 模型反复尝试同一个失败工具 + 没设步数上限 | 设 max_iterations=15 + Tool 失败标记不重试 + 成本上限熔断 | [Function Calling](FunctionCalling与ToolUse.md) / [Agent 架构](Agent架构模式.md) |
| 3 | RAG 召回率突然从 80% 跌到 20% | Embedding 模型从 v1 升级到 v2，旧索引未重建 | 灰度切换 + 双写双查 + 监控向量空间漂移 | [RAG](RAG检索增强生成.md) / [生产踩坑](RAG与Agent生产踩坑.md) |
| 4 | 上下文超过 128K 后 LLM 开始"中间遗忘" | 长上下文模型并非全段同等关注（Lost in the Middle） | 关键信息前置 / 后置 + Summary Buffer + 分段询问 | [上下文与记忆](上下文与记忆管理.md) |
| 5 | 月度账单从 5 千飞涨到 50 万 | 每次请求都重发 50K System Prompt，无 Cache | 启用 Anthropic Prompt Cache + 按租户成本上限 | [LLM 工程化](LLM应用工程化.md) |
| 6 | 大量并发把 OpenAI Tier 限流打穿，所有用户失败 | 单点单 Key + 无 Fallback | 多 Key 轮询 + 跨厂商 Fallback + 优先级队列 | [LLM 工程化](LLM应用工程化.md) |
| 7 | 流式响应中途断开，Token 重复计费 | 中断未通知模型，下一次重试又算一次 | 用 stream-id 幂等 + 收到首 Token 即扣额度 | [LLM 工程化](LLM应用工程化.md) |
| 8 | RAG 答案明明在文档里，就是召不回 | 用户问"对比 A 和 B 的区别"，纯向量检索语义太抽象 | 加 BM25 + Query Rewrite（拆成 A 是什么 / B 是什么 / 区别） + Rerank | [RAG](RAG检索增强生成.md) |
| 9 | MCP Server 给 Agent 暴露了 `delete_user` 工具，被注入触发 | MCP 工具未做权限边界 / Agent 信任所有工具 | 工具分级 + 写操作必须用户确认 + 危险工具白名单 | [MCP 协议](MCP协议.md) / [生产踩坑](RAG与Agent生产踩坑.md) |
| 10 | 评估指标看起来都好，用户却说体验变差 | 离线指标偏向召回准确率，没看延迟、Token 成本、用户反馈率 | 加在线 A/B + 用户点踩率 + Token 消耗预算监控 | [评估与可观测](Agent评估与可观测性.md) |

---

## 六、面试常被一连串追问的话题

> 面试官最常用的"链式追问"路径。准备好这 12 串，对应文档里都有完整答案。

1. **RAG 全链路追问**：你怎么切分文档？切多大？为什么？→ 用什么 Embedding？→ 怎么召回？Top-K 多少？→ 用 Rerank 吗？延迟代价？→ 召不回怎么办？→ 召回了但答错怎么办？→ 你们怎么评估？→ 引用怎么标？
2. **Function Calling 全链路**：协议长什么样？→ 并行调用怎么搞？→ 工具失败怎么处理？→ 死循环怎么防？→ Schema 怎么写才让模型听话？→ 流式 Tool Call 在 Java 怎么处理？
3. **上下文超限**：上下文要爆了怎么办？→ 滑动窗口、Summary Buffer、向量记忆选哪个？→ 长上下文模型为什么会"中间遗忘"？→ Anthropic Prompt Cache 是什么原理？怎么命中？
4. **Prompt 注入**：什么是 Prompt 注入？→ 直接注入和间接注入区别？→ 你们怎么防的？→ System Prompt 强化够吗？→ 输出层过滤具体怎么做？→ 检测分类器准确率多少？
5. **成本治理**：你们一个月花多少钱？→ 怎么算的？→ Token 怎么埋点？→ 怎么按部门 / 用户分摊？→ 限流怎么做？TPM 还是 RPM？→ 怎么砍成本？
6. **限流降级**：Anthropic Tier 限流被打穿怎么办？→ 多 Key 轮询怎么做幂等？→ Fallback 模型怎么选？→ 主备切换是不是要重新发 Prompt？Cache 还命中吗？
7. **Agent 选型**：LangChain 你们用吗？→ 为什么不用？→ LangGraph 为啥可以？→ Java 后端用什么？→ Spring AI 和 LangChain4j 区别？→ 自研有没有意义？
8. **MCP**：MCP 是什么？→ 跟 Function Calling 是替代关系吗？→ 三种 Transport 区别？→ 生产用 stdio 还是 HTTP？→ 自建 MCP Server 安全怎么做？
9. **流式 SSE**：怎么从后端把 LLM 流式推到前端？→ Spring 用 SseEmitter 还是 WebFlux？→ 中断断线怎么处理？→ Token 怎么扣？→ 浏览器超时 60s 怎么办？
10. **评估**：RAG 怎么评？→ RAGAS 五个指标是啥？→ Faithfulness 和 Answer Relevancy 区别？→ LLM-as-Judge 怎么校准？→ 人工标注怎么做？→ 上线后怎么监控？
11. **向量库容量**：你们多少向量？→ 多大？→ Milvus 还是 ES？→ HNSW 参数怎么调？→ 召回 P99 多少？→ 怎么扩容？
12. **生产事故**：你们遇到过最大的 LLM 事故是什么？→ 是怎么发现的？→ 监控覆盖了吗？→ 修了多久？→ 后续怎么防？

---

## 七、相关模块

| 模块 | 关联点 |
|---|---|
| [Redis](../Redis/README.md) | Redis Search 用作小规模向量库 / Prompt 语义缓存 / Token 限流计数器 |
| [Microservice](../Microservice/README.md) | Sentinel 给 LLM 接口做限流降级 / SpringCloudGateway 做 LLM 网关聚合多模型 |
| [Distributed](../Distributed/README.md) | LLM 调用幂等（流式中断重试场景）/ 分布式 ID 给 Trace 用 |
| [MQ](../MQ/README.md) | 异步 RAG 索引重建 / Embedding 异步化 / 用户反馈异步收集 |
| [Network](../Network/README.md) | SSE / WebSocket 流式 / HTTP/2 长连接复用 |
| Project | 系统设计 - IM 消息系统 给客服 Agent 当架构参考 |

---

> **写作约定**（与 [CLAUDE.md](../CLAUDE.md) 对齐）：本模块每篇都按 senior interview note 标准写——讲为什么、给取舍、附原理图、列踩坑、Q&A 追问、60 秒答题模板、相关文档。**生产数字必须真实**（Token 价格、向量维度、限流阈值、延迟数字），不能写"大量"、"较快"。
