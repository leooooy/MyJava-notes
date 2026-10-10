# Agent 框架对比

> 引子：写 Agent 的方式有 100 种，但生产能跑的就 5-6 个主流框架。**这一篇是选型指南**，回答面试常问的：
>
> ① **大厂为什么不爱用 LangChain**？
> ② **LangChain / LangGraph / AutoGen / CrewAI / Dify / Coze 各自定位是什么**？
> ③ **Java 后端怎么做 Agent**？Spring AI 和 LangChain4j 的区别？什么时候应该自实现 Loop？
> ④ **框架选型的隐藏陷阱**：版本断崖、黑盒、依赖膨胀、Production 不友好——是后端工程师才会问到的痛。
>
> 本篇覆盖 8 个主流框架（含 Java 系），最后给一张生产级选型决策矩阵。

---

## 一、为什么需要 Agent 框架

### 1.1 自实现 vs 用框架

```
┌──────────────────────────────────────────────────────┐
│  自实现 Agent 你需要写：                                 │
│  - LLM 客户端（多家适配 / 流式 / 重试 / 限流 / 错误）     │
│  - Function Calling 协议解析                          │
│  - Agent Loop（思考 → 工具 → 观察 → 思考）             │
│  - 状态管理 + 持久化                                   │
│  - 多 Agent 协调                                      │
│  - 上下文管理（Token 计算 / 滑动窗口 / 摘要）            │
│  - Tool 注册 / 元信息 / Schema 校验                   │
│  - 流式 SSE 输出                                       │
│  - 限流 / 缓存 / Trace                                │
│  - RAG 检索集成                                       │
└──────────────────────────────────────────────────────┘
```

工作量大约 **2-4 人月**起步。框架的价值是把这些通用基础抽象出来。

### 1.2 框架的代价

但框架也有代价：

- **黑盒**：调试时不知道 Prompt 实际长什么样
- **版本断崖**：LangChain 0.0.x → 0.1 → 0.2 → 0.3 多次破坏式升级
- **依赖膨胀**：拉依赖动辄几百 MB
- **抽象错位**：你的需求和框架抽象不匹配时，写的全是 workaround
- **性能损耗**：框架的事件循环 / 拦截器叠加层数

> **生产经验**：**简单场景用框架（PoC / 快速上线），复杂场景自实现 Loop（控制力 + 性能）**。LangChain 几乎所有大厂生产环境都不直接用，但用它的子组件（如向量库 wrapper）。

---

## 二、Python 系框架

### 2.1 LangChain：先驱 + 重灾区

**定位**：最早期的 LLM 应用框架，尝试封装一切。Chain / Agent / Tool / Memory 抽象层多。

**优势**：
- 生态最大（无数集成 / 教程 / 示例）
- 入门门槛低（一行代码跑通）
- 提供大量 PoC 模板

**劣势**：
- **抽象层过多**——简单事情绕弯路
- **版本不稳**——0.0.x → 0.1 → 0.2 → 0.3 多次破坏式升级
- **Prompt 黑盒**——你不知道实际发给 LLM 长什么样
- **生产不友好**——重试 / 限流 / 监控等工程化能力差
- **依赖混乱**——`langchain` / `langchain-core` / `langchain-community` / `langchain-openai` 拆得稀烂

**典型代码**：

```python
from langchain.chains import LLMChain
from langchain.prompts import PromptTemplate
from langchain_openai import ChatOpenAI

llm = ChatOpenAI(model="gpt-5")
prompt = PromptTemplate(input_variables=["topic"], template="解释 {topic}")
chain = LLMChain(llm=llm, prompt=prompt)
result = chain.run("Function Calling")
```

**面试信号**：

> "你们生产用 LangChain 吗？"
>
> "没有。**LangChain 适合 PoC 和教学，生产场景我们用 LangGraph / 自实现**。LangChain 的 Chain / Agent 抽象层过多，调试时看不到真实 Prompt，版本升级破坏性强，依赖混乱。用它的向量库 / Tool wrapper 子组件可以，整套 Agent 流不建议。"

### 2.2 LangGraph：LangChain 团队的"翻新版"

**定位**：把 Agent 抽象成**有向图状态机**（StateGraph），节点是 Python 函数，边是状态转移条件。

**优势**：
- **可控可审计**——状态机模式，每条转移可日志
- **生产友好**——内置 Checkpointing（断点恢复）、Human-in-the-Loop
- **不绑死 LLM**——节点是 Python 函数，灵活
- **代码透明**——节点函数你自己写，没有黑盒抽象

**劣势**：
- 学习曲线（要懂 StateGraph 思维）
- 还是 LangChain 系，依赖复杂
- 简单 Agent 反而显得 overkill

**典型代码**：

```python
from langgraph.graph import StateGraph, END
from typing import TypedDict, Annotated

class AgentState(TypedDict):
    messages: list
    next_action: str

def agent_node(state: AgentState):
    # 调 LLM 决定下一步
    response = llm.invoke(state["messages"])
    return {"messages": [response], "next_action": parse_action(response)}

def tool_node(state: AgentState):
    result = execute_tool(state["next_action"])
    return {"messages": [result]}

graph = StateGraph(AgentState)
graph.add_node("agent", agent_node)
graph.add_node("tool", tool_node)
graph.add_edge("tool", "agent")
graph.add_conditional_edges(
    "agent",
    lambda s: "tool" if s["next_action"] else END,
)
graph.set_entry_point("agent")

app = graph.compile(checkpointer=MemorySaver())
result = app.invoke({"messages": [user_msg]}, config={"thread_id": "user_123"})
```

**适用场景**：复杂 Agent / 多步骤工作流 / 合规要求高。**LangChain 系当前最推荐的生产框架**。

### 2.3 AutoGen（Microsoft）

**定位**：专注 **Multi-Agent 对话**。Agent 之间通过消息互相沟通完成任务。

**优势**：
- Multi-Agent 抽象一流（GroupChat / Sequential / Hierarchical 都直接支持）
- 内置代码执行 Agent（可自动跑 Python 验证结果）
- 微软背书，长期维护

**劣势**：
- Multi-Agent 模式 Token 消耗高
- 学术风重，生产案例少
- 1.0 版本架构变动大（从 v0.2 → v0.4 重写）

**典型代码**：

```python
from autogen import AssistantAgent, UserProxyAgent, GroupChat, GroupChatManager

writer = AssistantAgent("writer", llm_config={"model": "gpt-5"})
critic = AssistantAgent("critic", system_message="挑文章的逻辑漏洞")
user = UserProxyAgent("user")

group = GroupChat(agents=[user, writer, critic], max_round=10)
manager = GroupChatManager(groupchat=group, llm_config=...)

user.initiate_chat(manager, message="写一篇关于 RAG 的文章")
```

**适用场景**：研究 / 论文复现 / 真的需要多 Agent 讨论的场景。

### 2.4 CrewAI

**定位**：用 **角色（Role） + 任务（Task）** 抽象的 Multi-Agent 框架，比 AutoGen 更面向业务。

**优势**：
- 角色抽象贴近业务理解（"研究员 + 编辑 + 校对"）
- 任务可串行 / 并行 / 层级
- 上手快

**劣势**：
- 同样 Multi-Agent Token 高
- 比 AutoGen 年轻，稳定性次

**典型代码**：

```python
from crewai import Agent, Task, Crew

researcher = Agent(role="研究员", goal="收集资料", llm=...)
writer = Agent(role="撰稿人", goal="撰写文章", llm=...)

task1 = Task(description="搜集 RAG 最新进展", agent=researcher)
task2 = Task(description="基于资料撰写", agent=writer)

crew = Crew(agents=[researcher, writer], tasks=[task1, task2])
result = crew.kickoff()
```

### 2.5 Dify / Coze（低代码平台）

**定位**：**可视化拖拽** + 工作流 + Agent。面向产品 / 业务人员，不是开发者。

| 维度 | Dify | Coze |
|---|---|---|
| 来源 | 开源（语言开放） | 字节跳动 |
| 部署 | 自部署 / SaaS | SaaS（国内 / 海外两版） |
| 工作流编辑器 | ✅ | ✅ |
| 知识库内建 | ✅ | ✅ |
| Agent 节点 | ✅ | ✅ |
| API 二次开发 | ✅ | ✅ |
| 国产模型支持 | ✅ | ✅✅（豆包深度集成） |

**适用场景**：
- 业务人员快速搭建 Bot（不需要写代码）
- 内部工具 / 客服 / 知识问答
- 不适合：高度定制化逻辑、需要源码控制的关键业务

**面试信号**：

> "你们用低代码平台吗？"
>
> "**业务侧轻量场景用 Dify 自部署**——非技术员工也能维护知识库 / 调 Prompt；**核心交易 / Agent 写在代码里**，因为低代码平台对版本控制 / 灰度 / 监控不友好。"

---

## 三、Java 系框架（重点）

> Java 后端面试这块是必拷打——"你做 AI 用 Java 怎么搞？"

### 3.1 Spring AI

**定位**：Spring 官方 LLM 集成模块，对标 Python LangChain。**Spring Boot 生态原生集成**。

**核心抽象**：
- `ChatModel` / `ChatClient`：统一的 LLM 调用接口
- `Advisors`：拦截器 / 中间件链（类似 Spring AOP）
- `Tools` / `@Tool`：注解式工具定义
- `VectorStore`：向量库统一抽象
- `RetrievalAugmentationAdvisor`：RAG 一键集成

**优势**：
- **Spring Boot 原生**——配置 / 依赖注入 / Actuator / Profile 一切融合
- **Advisor 链**清晰——日志 / 限流 / 缓存 / RAG 都可作为 Advisor 插入
- **官方维护**——Spring 团队背书 + 长期支持
- **多模型适配**——OpenAI / Claude / Bedrock / Ollama / Vertex 都有 starter

**劣势**：
- 起步晚，生态不如 Python 系丰富
- 文档相对薄
- Multi-Agent 支持还很初期

**典型代码**：

```java
// 1. 依赖
// spring-ai-openai-spring-boot-starter

// 2. 配置 application.yml
// spring.ai.openai.api-key=${OPENAI_API_KEY}

// 3. 注入使用
@RestController
public class ChatController {
    private final ChatClient chatClient;

    public ChatController(ChatClient.Builder builder) {
        this.chatClient = builder
            .defaultSystem("你是客服助手")
            .defaultAdvisors(
                new MessageChatMemoryAdvisor(memory),    // 对话记忆
                new QuestionAnswerAdvisor(vectorStore),  // RAG 一键集成
                new SimpleLoggerAdvisor()                // 日志
            )
            .defaultTools(new OrderQueryTool())          // 工具
            .build();
    }

    @GetMapping("/chat")
    public Flux<String> chat(@RequestParam String q) {
        return chatClient.prompt()
            .user(q)
            .stream()
            .content();
    }
}

// 4. Tool 定义（注解式）
public class OrderQueryTool {
    @Tool(description = "查询用户订单状态")
    public OrderInfo queryOrder(@ToolParam(description = "订单号") String orderId) {
        return orderService.getOrder(orderId);
    }
}
```

### 3.2 LangChain4j

**定位**：Python LangChain 的 Java 移植 + 改良。**AI Service** 抽象一流。

**核心抽象**：
- `ChatLanguageModel` / `StreamingChatLanguageModel`
- **AI Service**——用接口定义 LLM 调用，类似 Spring Data JPA
- `ChatMemory`：对话记忆抽象
- `EmbeddingStore`：向量库抽象
- `Tools` 注解：工具定义

**优势**：
- **AI Service 抽象优雅**——接口式声明，自动绑定 LLM
- **集成丰富**——25+ 模型 / 15+ 向量库
- **不强依赖 Spring**——纯库可用任何框架（也有 Spring Boot Starter）
- **社区活跃**——更新比 Spring AI 快

**劣势**：
- Spring 集成不如 Spring AI 深入（自家不是 Spring 出品）
- 与 Java 生态某些规范偏离（部分 API 风格 Pythonic）

**典型代码**：

```java
// 1. AI Service 定义（接口式）
interface CustomerSupportAgent {
    @SystemMessage("你是客服助手，使用资料库回答问题")
    String chat(@MemoryId String userId, @UserMessage String message);
}

// 2. 构建
ChatLanguageModel model = OpenAiChatModel.builder()
    .apiKey(System.getenv("OPENAI_API_KEY"))
    .modelName("gpt-5")
    .build();

ContentRetriever retriever = EmbeddingStoreContentRetriever.builder()
    .embeddingStore(milvusStore)
    .embeddingModel(embeddingModel)
    .maxResults(5)
    .build();

CustomerSupportAgent agent = AiServices.builder(CustomerSupportAgent.class)
    .chatLanguageModel(model)
    .chatMemoryProvider(userId -> MessageWindowChatMemory.withMaxMessages(20))
    .contentRetriever(retriever)
    .tools(new OrderTool())
    .build();

// 3. 使用
String reply = agent.chat("user_123", "我的订单到哪了");
```

### 3.3 Spring AI vs LangChain4j

| 维度 | Spring AI | LangChain4j |
|---|---|---|
| Spring 集成 | ⭐⭐⭐⭐⭐ 原生 | ⭐⭐⭐⭐ 有 Starter |
| AI Service 抽象 | ❌（用 ChatClient） | ⭐⭐⭐⭐⭐ |
| Advisors 拦截器链 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |
| 模型集成数 | ~10 家 | 25+ 家 |
| 向量库支持 | ~10 个 | 15+ 个 |
| Multi-Agent | 初步 | 初步 |
| 文档与示例 | 中等 | 丰富 |
| 社区活跃度 | 增长中 | 高 |
| 长期支持承诺 | ⭐⭐⭐⭐⭐ Spring 官方 | ⭐⭐⭐ 社区维护 |

**选择建议**：
- **重 Spring 生态 / 主流大厂**：Spring AI（官方背书 + Advisor 设计优）
- **不绑 Spring / 多模型 + 多向量库**：LangChain4j（生态广 + AI Service 优）
- **PoC 阶段**：两个都能跑通，按团队熟悉度选

### 3.4 自实现 Loop（OpenAI / Anthropic SDK 直连）

**适用场景**：
- 简单 Agent，不需要框架抽象
- 复杂 Agent，框架抽象不匹配
- 性能敏感，要榨干每毫秒

**典型代码（Anthropic SDK 直连）**：

```java
public class CustomAgent {
    private final AnthropicClient client;
    private final List<Tool> tools;
    private final ToolRegistry registry;

    public AgentResult run(String userInput, AgentConfig cfg) {
        AgentState state = new AgentState(userInput);
        long startMs = System.currentTimeMillis();

        for (int i = 0; i < cfg.maxIterations(); i++) {
            checkBudget(state, cfg, startMs);

            Message resp = client.messages().create(MessageCreateParams.builder()
                .model("claude-sonnet-4-6")
                .maxTokens(4096)
                .system(buildSystemPrompt(state))
                .messages(state.getMessages())
                .tools(toolDefinitions())
                .build());

            state.addAssistantMessage(resp);

            if (resp.stopReason() == StopReason.END_TURN) {
                return state.toResult();
            }

            if (resp.stopReason() == StopReason.TOOL_USE) {
                List<ToolUse> uses = resp.toolUses();
                if (isLooping(state.recentToolCalls(), uses)) {
                    return abortWithFallback(state);
                }
                List<ToolResult> results = executeParallel(uses);
                state.addToolResults(uses, results);
            }
        }
        return abortWithFallback(state);
    }
}
```

**优势**：
- 最大控制力
- 最小依赖
- 性能最优

**代价**：
- 工程量大（Loop / 重试 / 流式 / 缓存全自己写）
- 维护成本高

---

## 四、选型决策矩阵

### 4.1 按场景

| 场景 | 推荐 | 备选 |
|---|---|---|
| Java 后端通用 LLM 应用 | **Spring AI** | LangChain4j |
| Java 后端复杂 Agent | **LangChain4j** + 部分自实现 | Spring AI + Advisor |
| Python PoC / 快速验证 | LangChain | LlamaIndex |
| Python 复杂 Agent / 工作流 | **LangGraph** | 自实现 |
| Multi-Agent 学术 / 研究 | AutoGen | CrewAI |
| Multi-Agent 业务落地 | CrewAI | LangGraph |
| 业务低代码 / 内部工具 | **Dify**（自部署） | Coze（SaaS） |
| 极致控制 / 性能 / 简洁 | 官方 SDK 自实现 | — |

### 4.2 按团队规模

| 规模 | 推荐 |
|---|---|
| 1-3 人，PoC 阶段 | Dify / Spring AI（快速跑通） |
| 5-10 人，业务落地 | Spring AI / LangChain4j（标准框架） |
| 20+ 人，大型 Agent 平台 | 自研框架 + 公共组件（参考 LangGraph 思想） |

### 4.3 隐藏陷阱清单

- **版本断崖**：选成熟版本（LangChain 选 0.3+ / Spring AI 选 1.0+），别追前沿 alpha
- **依赖膨胀**：检查 `langchain[all]` 之类的包，按需引入子模块
- **黑盒 Prompt**：上线前打开 verbose 模式确认实际 Prompt 长什么样
- **流式 / 取消**：测试中途断开是否真的取消了模型推理（避免 Token 继续烧）
- **Token 计费**：框架是否准确埋点 input / output / cache token？
- **Trace 可观测**：是否容易接入 OpenTelemetry / Langfuse？
- **多租户**：框架是否原生支持 tenant 隔离 / 配额 / 限流？

---

## 五、生产踩坑

### 坑 1：LangChain 升级版本，所有 Chain 用法全失效

**现象**：用 LangChain 0.0.x 写的应用，升级到 0.1 后 LLMChain / SimpleSequentialChain 等核心 API 全 deprecated，迁移工作量 2 周。

**根因**：LangChain 在 0.0.x → 0.1 → 0.2 → 0.3 多次重构，破坏式升级是常态。社区跟不上，文档滞后。

**修复**：
- 锁版本（`langchain==0.3.x`）+ CI 跑全量测试
- 关键应用从 LangChain 迁移到 LangGraph（更稳）
- 抽象层夹一层 facade，未来切换框架易

### 坑 2：LangChain4j 流式 + Tool Use，partial JSON 拼接错位

**现象**：用 LangChain4j 流式调 Claude，遇到并行 Tool Use 时 partial JSON 拼接错位，工具参数解析失败。

**根因**：LangChain4j 0.x 早期版本对 Anthropic 流式 Tool Use 的 partial_json 处理有 bug，多个 tool_use 的 partial json 没按 id 分桶。

**修复**：
- 升级到 1.0 版本（已修复）
- 用前先跑流式 + 并行工具调用回归测试
- 关键场景考虑直接用 Anthropic SDK 自实现解析

### 坑 3：Spring AI Advisor 顺序错，缓存先于 Memory

**现象**：Spring AI 的 Advisor 链配置：`[CacheAdvisor, MemoryAdvisor, RAGAdvisor]`，发现缓存命中时跳过了 Memory，多轮对话失忆。

**根因**：Advisor 顺序错——缓存应该在所有 Advisor 之后（或在最末），先 Memory 注入历史 → 再 RAG 检索 → 最后看缓存命中。

**修复**：
- 调整顺序：`[MemoryAdvisor, RAGAdvisor, CacheAdvisor, LoggerAdvisor]`
- 缓存命中时也要写入 Memory（不写下游不知道这轮发生了什么）
- 文档化每个 Advisor 的位置约定

### 坑 4：CrewAI Multi-Agent，Token 消耗 6 倍

**现象**：用 CrewAI 跑"产品分析报告" 5-Agent 任务，单次 Token 消耗 30 万、成本 $5、时长 8 分钟。

**根因**：
- Sequential 拓扑下每个 Agent 都拿到了前面所有 Agent 的完整对话
- 没有摘要压缩
- LLM 用了 GPT-5 而不是分级使用（简单 Agent 用 Haiku）

**修复**：
- 拓扑改为 Hierarchical（Manager + Workers），关键决策由 Manager 集中
- Agent 间传 **summary** 而不是完整对话
- 简单 Agent 用便宜模型（Haiku / DeepSeek），关键 Agent 用 Opus
- 评估替换为单 Agent + 多 Tool 是否够用

### 坑 5：Dify 工作流改个分支，业务全断

**现象**：Dify 上配的工作流增加一个分支，保存后线上立即生效，导致已有用户流量走到未完整测试的分支报错。

**根因**：Dify 没有版本管理 / 灰度发布机制（开源版本相对原始）。

**修复**：
- 关键工作流走代码（Spring AI / LangChain4j）+ 完整 CI/CD
- Dify 仅用于内部工具 / 业务侧实验
- 建立 Dify 工作流变更的"双签"流程（业务 + 技术 review）

---

## 六、面试高频追问

**Q1：LangChain / LangGraph / 自实现 怎么选？**

PoC 阶段 LangChain 快；生产复杂 Agent **LangGraph**（StateGraph + Checkpointing 支持断点恢复）；极致控制 / 性能 / 调试简洁场景**自实现 Loop**（用 OpenAI/Anthropic SDK 直连）。**大厂生产几乎不直接用 LangChain Chain / Agent，但用它的子组件（向量库 wrapper、tool 定义）。**

**Q2：Java 后端做 Agent，Spring AI 还是 LangChain4j？**

**重 Spring 生态用 Spring AI**（Advisor 设计优雅、官方背书、Spring Boot 原生）；**重多模型 / 多向量库 / AI Service 抽象用 LangChain4j**（生态广、接口式 API 简洁）。两个都成熟，团队熟悉度 + Spring 依赖深度是主要决策因素。**复杂场景两者都不够时考虑自实现**。

**Q3：什么时候应该自实现 Agent Loop？**

四种场景：① 业务逻辑复杂到框架抽象不匹配；② 性能敏感（榨毫秒）；③ 强控制力（每个 LLM 调用都要审计）；④ 依赖最小化（边缘部署 / 银行内网）。代价是工程量 2-4 人月起步、维护成本高。**典型大厂做法**：核心场景自实现 + 通用场景框架 + 框架选型严格筛选。

**Q4：Multi-Agent 框架选 AutoGen 还是 CrewAI？**

研究 / 论文复现选 **AutoGen**（功能全、Multi-Agent 抽象一流，但学术风重）；业务落地选 **CrewAI**（Role/Task 抽象贴近业务，上手快）。生产 Multi-Agent **优先 LangGraph 实现 Supervisor 拓扑**——可控性 / 可观测性 / 与代码集成都更好。

**Q5：Dify 适合什么场景？**

业务人员快速搭建 Bot（不需要写代码）、内部工具 / 客服 / 知识问答。**不适合**核心交易 / 关键业务——低代码平台版本控制 / 灰度 / 监控薄弱。生产模式：业务侧轻量场景 Dify，核心交易写代码。

**Q6：LangChain 和 LlamaIndex 区别？**

LangChain 是**通用 LLM 应用框架**（Agent + Chain + Tool + Memory + RAG 都做）；LlamaIndex 早期专注 **RAG**（数据接入 + 索引 + 检索），后来扩展到 Agent。**生产经验**：RAG 重度场景 LlamaIndex 比 LangChain 好（数据接入 / 切分 / 召回组件更专业），通用场景 LangGraph / Spring AI / LangChain4j。

**Q7：Spring AI 的 Advisor 是什么？相当于什么？**

类似 Spring AOP 的拦截器链。每次调 LLM 前后都会走 Advisor 链——`MessageChatMemoryAdvisor`（注入历史）、`QuestionAnswerAdvisor`（RAG 检索拼 Prompt）、`SafeGuardAdvisor`（敏感词过滤）、`LoggerAdvisor`（日志）、`SimpleCacheAdvisor`（语义缓存）等。**Advisor 顺序很重要**——错了会绕过 Memory / Cache 导致 bug。

**Q8：LangChain4j 的 AI Service 是什么？**

接口式声明 LLM 调用，**类似 Spring Data JPA**。你定义一个接口（含 `@SystemMessage` / `@UserMessage` / `@MemoryId` 等注解），LangChain4j 在运行时生成实现。优点是**业务代码看起来像普通 Java 接口调用**，背后藏了 LLM、Memory、Tool、RAG 全套。是 LangChain4j 最优雅的设计。

**Q9：流式 + 框架选型有什么坑？**

① 测试**中途取消是否真的停了底层 LLM 推理**（很多框架只断了 SSE 输出，模型还在烧 Token）；② 流式 + Tool Use 的 partial JSON 是否正确按 tool_id 分桶（早期 LangChain4j 1.0 前有 bug）；③ Spring AI 的 streaming Advisor 链顺序与非流式不一定一致（验证）。**生产上线前必须测**：流式 + 并行 Tool + 中途取消 + 重连四个组合。

**Q10：框架的 Token 计费和 Trace 怎么对接？**

Spring AI / LangChain4j 都暴露 `Usage` 元信息（input / output / cache token），通过 Advisor 或 Listener 拿到后埋点到 Prometheus / 自家计费系统。Trace 通过 OpenTelemetry / Micrometer 的标准接口接入 Langfuse / Honeycomb / Jaeger。**注意**：框架自动重试 / 降级时**多次调用都要计费**，别只统计成功的那次。

---

## 七、答题模板（60 秒）

> "Agent 框架核心选型看 **生态层级 / 控制力 / 团队语言栈** 三维。"
>
> "**Python 系**：PoC 用 LangChain，生产用 **LangGraph**（StateGraph + Checkpointing），Multi-Agent 业务用 CrewAI / 学术用 AutoGen，业务低代码用 Dify。"
>
> "**Java 系**：重 Spring 生态用 **Spring AI**（Advisor 拦截器链优雅、官方维护），多模型 / AI Service 抽象用 **LangChain4j**，复杂场景自实现 Loop（Anthropic / OpenAI SDK 直连）。"
>
> "**生产经验**：① 大厂几乎不直接用 LangChain Chain/Agent，子组件可用；② 关键场景代码 + 标准框架 + 灰度，业务低代码场景才上 Dify；③ 框架版本断崖、Prompt 黑盒、依赖膨胀是三大坑，**上线前打开 verbose 看真实 Prompt + 流式取消测试 + Token 计费埋点**必做。"

---

## 八、相关文档

- [Function Calling 与 Tool Use](FunctionCalling与ToolUse.md) — 框架背后的协议层
- [Agent 架构模式](Agent架构模式.md) — ReAct / Plan-and-Execute / Multi-Agent 五种模式
- [LLM 应用工程化](LLM应用工程化.md) — 限流 / 缓存 / Trace 框架对接
- [Agent 评估与可观测性](Agent评估与可观测性.md) — 框架 Token / Trace 埋点
- [上下文与记忆管理](上下文与记忆管理.md) — Memory 抽象选择
- [RAG 检索增强生成](RAG检索增强生成.md) — Spring AI / LangChain4j 的 RAG 集成
- [MCP 协议](MCP协议.md) — 框架与 MCP 工具的对接
- [Spring/SpringBoot 启动流程](../Spring/SpringBoot启动流程.md) — Spring AI Auto-Configuration 背景
