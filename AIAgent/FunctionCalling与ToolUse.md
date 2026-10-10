# Function Calling 与 Tool Use

> 引子：**Function Calling / Tool Use 是 LLM 应用从"聊天玩具"升级到"生产 Agent"的分水岭**。简历写过 "做过 Agent / 用过 Tool Use"，面试官就会一直追问到底：
>
> ① **协议长什么样**：OpenAI / Anthropic / Gemini 三家 API 字段差异在哪？为什么不统一？
> ② **并行调用**：模型一次返回 5 个 Tool Call 怎么处理？要等所有结果才能继续吗？
> ③ **失败怎么办**：API 报 500、参数解析失败、重试还是放弃？
> ④ **死循环**：模型卡在"思考 → 调工具 → 思考 → 调工具" 200 步停不下来，烧了 200 美元——你怎么防的？
> ⑤ **Schema 设计**：description 字段为什么这么重要？少写一句话准确率掉 30%？
>
> 这篇是 Layer 1 三件套的最后一篇，也是面试**项目深挖最容易出彩**的一篇。

---

## 一、为什么需要 Tool Use

### 1.1 LLM 的天然短板

LLM 是 **预训练快照** + **自回归 Token 生成器**，天然不能：

| 能力 | 缺失原因 |
|---|---|
| 实时信息（天气 / 股价 / 新闻） | 训练数据有 cutoff，2024-01 的模型不知道 2025 年的事 |
| 计算（精确数学 / 大数运算） | Token 预测本质，"123456 × 789" 经常算错 |
| 访问私有数据 | 不在训练集（你公司的 CRM、数据库） |
| 副作用操作（发邮件、下订单） | 模型只会输出文字，不能实际"做事" |

**Function Calling / Tool Use 解决的就是这个问题**：让 LLM **决定调什么工具、用什么参数**，由开发者执行后**把结果回喂**给模型继续推理。

### 1.2 经典工作流

```
┌─────────────────────────────────────────────────────────────┐
│  用户："上海明天天气怎么样？要带伞吗？"                       │
└──────────────────────────┬──────────────────────────────────┘
                           ▼
              ┌────────────────────────┐
              │  LLM 第 1 轮思考        │
              │  "我需要查天气"          │
              │  → 输出 tool_use:        │
              │    get_weather("上海", "tomorrow") │
              └────────────┬─────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │  开发者代码：              │
              │  发 HTTP 调用天气 API     │
              │  返回："明天上海有雨 80%" │
              └────────────┬─────────────┘
                           ▼
              ┌────────────────────────┐
              │  LLM 第 2 轮思考         │
              │  收到 tool_result        │
              │  → 输出最终回答："明天上海有雨，建议带伞" │
              └────────────────────────┘
```

**关键认知**：模型本身不调用工具，**只是输出"我想调用 X 工具，参数是 Y"**。真正发起 HTTP / SQL / 命令的是**开发者代码**。这就是为什么权限边界 / 安全防御都在开发者侧。

---

## 二、三家协议对比（必背）

| 字段 | OpenAI | Anthropic | Gemini |
|---|---|---|---|
| 工具定义入参 | `tools=[{type:"function", function:{...}}]` | `tools=[{name, description, input_schema}]` | `tools=[{function_declarations:[...]}]` |
| 模型输出工具调用 | `message.tool_calls=[{id, function:{name, arguments}}]` | `content=[{type:"tool_use", id, name, input}]` | `parts=[{function_call:{name, args}}]` |
| 工具结果回传 | `role:"tool", tool_call_id, content` | `role:"user", content:[{type:"tool_result", tool_use_id, content}]` | `parts=[{function_response:{name, response}}]` |
| 强制调用某工具 | `tool_choice={type:"function", function:{name}}` | `tool_choice={type:"tool", name}` | `tool_config:{function_calling_config:{mode:"ANY"}}` |
| 阻止调用工具 | `tool_choice="none"` | `tool_choice={type:"none"}` | `tool_config:{mode:"NONE"}` |
| 让模型自己选 | `tool_choice="auto"`（默认） | `tool_choice={type:"auto"}`（默认） | `tool_config:{mode:"AUTO"}` |
| 并行调用 | 默认开 | 默认开 | 默认开 |
| 关闭并行 | `parallel_tool_calls=false` | `disable_parallel_tool_use=true` | （无显式选项） |

### 2.1 OpenAI 写法

```python
tools = [{
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "查询指定城市指定日期的天气",
        "parameters": {
            "type": "object",
            "properties": {
                "city": {"type": "string", "description": "城市名，例如 '上海'"},
                "date": {"type": "string", "description": "ISO 日期，例如 '2026-05-10'"}
            },
            "required": ["city", "date"],
            "additionalProperties": False
        },
        "strict": True   # 强 Schema 校验
    }
}]

response = client.chat.completions.create(
    model="gpt-5",
    messages=[{"role": "user", "content": "上海明天天气"}],
    tools=tools,
    tool_choice="auto"
)

# 模型输出
# response.choices[0].message.tool_calls = [
#   { "id": "call_abc", "function": { "name": "get_weather", "arguments": "{\"city\":\"上海\",\"date\":\"2026-05-10\"}" } }
# ]

# 回传结果
messages.append(response.choices[0].message)
messages.append({
    "role": "tool",
    "tool_call_id": "call_abc",
    "content": "明天上海有雨 80%，气温 18-22 度"
})
# 再次调用 client.chat.completions.create(...) 让模型基于结果继续
```

### 2.2 Anthropic 写法

```python
tools = [{
    "name": "get_weather",
    "description": "查询指定城市指定日期的天气",
    "input_schema": {
        "type": "object",
        "properties": {
            "city": {"type": "string"},
            "date": {"type": "string"}
        },
        "required": ["city", "date"]
    }
}]

response = client.messages.create(
    model="claude-sonnet-4-6",
    max_tokens=1024,
    tools=tools,
    messages=[{"role": "user", "content": "上海明天天气"}]
)

# 模型输出
# response.content = [
#   { "type": "tool_use", "id": "toolu_xxx", "name": "get_weather",
#     "input": { "city": "上海", "date": "2026-05-10" } }
# ]
# response.stop_reason == "tool_use"

# 回传结果
messages.append({"role": "assistant", "content": response.content})
messages.append({
    "role": "user",
    "content": [{
        "type": "tool_result",
        "tool_use_id": "toolu_xxx",
        "content": "明天上海有雨 80%，气温 18-22 度",
        "is_error": False     # 失败时设 True
    }]
})
```

### 2.3 关键差异点

```
┌────────────────────────────────────────────────────────────┐
│  OpenAI                                                     │
│    工具结果用专门的 role:"tool"                              │
│    arguments 是 JSON 字符串（不是对象）                      │
│    需要 client 侧自己 json.loads 解析                        │
│                                                             │
│  Anthropic                                                  │
│    工具结果伪装成 role:"user" + content[type:"tool_result"]│
│    input 是直接的对象（已 JSON.parse）                       │
│    is_error 字段显式标失败                                   │
│                                                             │
│  Gemini                                                     │
│    function_call / function_response 在同一个 parts 数组    │
│    更接近 protobuf 格式，对 JSON 友好度低一些               │
└────────────────────────────────────────────────────────────┘
```

> **生产建议**：自己封一层抽象（Tool Result 接口），底下适配三家。直接用 LangChain / LangChain4j 封装也行，但要意识到底层差异。

---

## 三、并行工具调用

### 3.1 什么是并行调用

模型在一次响应中可能输出**多个 tool_use 块**，比如：

用户："对比上海和北京明天的天气"

模型一次输出：
```json
[
  {"type": "tool_use", "id": "toolu_1", "name": "get_weather", "input": {"city": "上海", "date": "2026-05-10"}},
  {"type": "tool_use", "id": "toolu_2", "name": "get_weather", "input": {"city": "北京", "date": "2026-05-10"}}
]
```

**两个独立调用**，开发者可以并行发起，**等所有结果都回来才再调 LLM**。

### 3.2 必须等所有结果回来吗？

**Anthropic / OpenAI 都要求：所有 tool_use 必须有对应的 tool_result，缺一个就报错**。所以并行调用的客户端写法必须是：

```java
// Java 并行调用（CompletableFuture）
List<ToolUse> toolUses = response.getToolUses();
List<CompletableFuture<ToolResult>> futures = toolUses.stream()
    .map(tu -> CompletableFuture.supplyAsync(
        () -> executeTool(tu),
        toolExecutor    // 隔离的工具执行线程池
    ))
    .toList();

// 等所有完成（可加 timeout）
List<ToolResult> results = futures.stream()
    .map(f -> {
        try { return f.get(10, TimeUnit.SECONDS); }
        catch (Exception e) { return ToolResult.error(e.getMessage()); }
    })
    .toList();

// 拼回 messages 里再调 LLM
messages.addAll(buildToolResultMessages(toolUses, results));
```

### 3.3 关闭并行的场景

**默认开启并行**，但有些场景要强制串行：

```java
// 关闭并行（OpenAI / Anthropic 都支持显式关闭）
client.messages.create(
    tools=tools,
    disable_parallel_tool_use=true    // Anthropic
)
// 或
client.chat.completions.create(
    tools=tools,
    parallel_tool_calls=false          // OpenAI
)
```

**关闭场景**：
- 工具间**有依赖**（先 query_user 拿 ID 再 query_orders）
- 工具有**副作用**（先 lock_resource 再 update_resource，并行会冲突）
- **资源池受限**（数据库连接 / 第三方 API 限流）

### 3.4 并行 ≠ 智能。模型可能并行了不该并行的

**踩坑场景**：

```
用户："把订单 12345 标记为已退款"
模型：[mark_refunded(12345), send_email(...), update_inventory(...)]   ← 并行
开发者代码：三个工具同时跑
真实情况：邮件先发出去，但 mark_refunded 数据库失败回滚
结果：用户收到了"已退款"邮件，但订单状态仍是"待发货"
```

**修复**：
- 写操作 / 副作用类工具**强制串行**（`disable_parallel_tool_use=true`）
- 或者拆成多次调用：先标记 → 再返回 → 模型确认后再发邮件 → 再回模型 → 再更新库存
- **关键写操作必须有补偿 / 事务保护**

---

## 四、Tool 错误处理

### 4.1 错误的三种来源

| 来源 | 例子 | 处理 |
|---|---|---|
| **参数解析失败** | 模型给了 `date: "明天"` 而不是 ISO 日期 | 返回 `is_error=true` + 错误描述，让模型重试 |
| **工具内部失败** | API 504 / 数据库超时 | 返回 `is_error=true` + 简明错误，让模型决定换工具或放弃 |
| **工具不存在** | 模型幻觉调了个未注册工具 | 立即拦截，返回 "tool X not found" |

### 4.2 失败信息怎么写给模型看

**坏例子（太长）**：
```
{"is_error": true, "content": "java.sql.SQLException: Connection refused\n\tat com.mysql.cj.jdbc.exceptions.SQLError.createSQLException(SQLError.java:129)\n\tat ... [stack trace 50 lines]"}
```

模型看到长 stack trace 会被噪声干扰，且浪费 Token。

**好例子（精简、可操作）**：
```
{"is_error": true, "content": "数据库连接超时。建议：① 等 5 秒重试；② 询问用户是否需要换其他方式查询。"}
```

**模板**：
```java
public class ToolResult {
    public static ToolResult error(String shortMessage, String suggestion) {
        return new ToolResult(true, shortMessage + " " + suggestion);
    }
}

// 用法
return ToolResult.error(
    "weather API 返回 503",
    "建议：① 重试一次；② 用 search_web 工具搜索 '上海明日天气' 替代。"
);
```

### 4.3 是否重试？谁来重试？

```
┌─────────────────────────────────────────────────┐
│  Tool 错误重试策略                                │
├─────────────────────────────────────────────────┤
│  ① 客户端重试（不告诉模型）：                    │
│     瞬时网络错误（连接超时 / DNS 失败）           │
│     1-2 次，指数退避                              │
│     成功 → 正常 tool_result                      │
│     失败 → 进入 ②                                │
├─────────────────────────────────────────────────┤
│  ② 让模型决定：                                   │
│     业务错误（参数错、记录不存在、权限不足）      │
│     返回 is_error=true                           │
│     模型可能 a) 修正参数重试                      │
│              b) 换工具                            │
│              c) 告诉用户失败                      │
├─────────────────────────────────────────────────┤
│  ③ 立即终止：                                     │
│     成本 / 步数上限触发                           │
│     危险工具未授权                                │
│     直接返回用户错误，不再调 LLM                  │
└─────────────────────────────────────────────────┘
```

---

## 五、Schema 设计：决定准确率的 80%

### 5.1 description 字段是 Tool Use 的"灵魂"

**实测数据**：同一个工具 `search_kb`，两个不同的 description，准确率差 30%：

| description | 调用准确率 |
|---|---|
| `"搜索"` | 35% |
| `"全文搜索内部知识库（产品文档 / FAQ / 政策），返回 Top-5 相关段落。适用于回答用户关于产品功能、价格、政策的问题。"` | 92% |

**为什么差这么多**：模型选工具是基于 **工具名 + description + 用户意图** 的语义匹配。description 越具体（覆盖什么场景 / 不覆盖什么 / 返回什么），模型越能正确选用。

### 5.2 写 description 的 5 条原则

1. **说"是什么"也说"什么时候用"**：`查询订单状态。当用户提到订单号或询问"我的订单怎么样"时使用。`
2. **说"什么时候不该用"**：`仅查询订单状态。**不要用此工具修改订单**——修改请用 update_order。`
3. **说"返回什么"**：`返回 JSON：{ status, created_at, items }`
4. **覆盖参数边界**：`city 必须是中文，例如 "上海" 不是 "Shanghai"`
5. **避免歧义**：`get_user vs query_user`——名字相近的工具一定要在 description 里互相区分

### 5.3 Schema 设计反例

```json
// ❌ 坏例子
{
    "name": "search",
    "description": "搜索",
    "parameters": {
        "type": "object",
        "properties": {
            "q": {"type": "string"}
        }
    }
}

// ✅ 好例子
{
    "name": "search_knowledge_base",
    "description": "全文搜索公司内部知识库（产品文档、FAQ、政策），返回 Top-5 相关段落。适用于：用户询问产品功能、价格、退款政策、操作步骤。**不适用于**：实时数据查询、用户个人订单查询、外部新闻搜索。",
    "input_schema": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "中文检索语句，建议 5-30 字，避免过长。例如 '退款政策' 而不是 '我想知道退款政策具体是什么样的呢'"
            },
            "category": {
                "type": "string",
                "enum": ["product", "policy", "faq", "all"],
                "description": "限定搜索范围，all 表示全部"
            },
            "top_k": {
                "type": "integer",
                "minimum": 1,
                "maximum": 20,
                "default": 5,
                "description": "返回前 K 条结果"
            }
        },
        "required": ["query"]
    }
}
```

### 5.4 工具数量上限

| 工具数 | 模型表现 |
|---|---|
| 1-5 | 准确率最高 |
| 5-15 | 仍稳定，需要 description 写得好 |
| 15-30 | 开始混淆相似工具，准确率显著下降 |
| 30+ | 模型经常选错，**强烈不推荐** |

**修复 30+ 工具的方案**：
- **工具分组**：按场景拆 Agent，每个 Agent 只暴露 5-10 个工具
- **二级路由**：先用一个"router_agent"决定走哪类，再让对应子 Agent 调具体工具
- **MCP Server 分层**：每个 MCP Server 一个领域，主 Agent 按场景挂载（详见 [MCP 协议](MCP协议.md)）

---

## 六、流式 Tool Call

### 6.1 为什么流式 Tool Call 复杂

普通流式：
```
data: {"delta":"Hello"}
data: {"delta":" world"}
```

流式 Tool Call：
```
data: {"type":"content_block_start","content_block":{"type":"tool_use","id":"toolu_x","name":"get_weather"}}
data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}
data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"\"上海\""}}
data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"}"}}
data: {"type":"content_block_stop"}
```

工具的 `input` JSON 是**逐 Token 流式过来**的，必须等到 `content_block_stop` 才能拼出完整 JSON 解析。**不能边收边解析**——拼到一半的 JSON 不合法。

### 6.2 Java SSE 客户端处理

```java
public class ToolCallStreamHandler {
    private final Map<String, StringBuilder> partialJsonByToolId = new HashMap<>();
    private final Map<String, ToolUseBlock> toolUseBlocks = new HashMap<>();

    public void onEvent(SseEvent event) {
        switch (event.getType()) {
            case "content_block_start":
                if ("tool_use".equals(event.getBlockType())) {
                    String id = event.getId();
                    toolUseBlocks.put(id, new ToolUseBlock(event.getName()));
                    partialJsonByToolId.put(id, new StringBuilder());
                }
                break;

            case "content_block_delta":
                if (event.getDelta().getType().equals("input_json_delta")) {
                    String id = event.getId();
                    partialJsonByToolId.get(id).append(event.getDelta().getPartialJson());
                }
                break;

            case "content_block_stop":
                String id = event.getId();
                String fullJson = partialJsonByToolId.remove(id).toString();
                Map<String, Object> input = JSON.parseObject(fullJson, Map.class);
                ToolUseBlock block = toolUseBlocks.get(id);
                block.setInput(input);
                onToolReady(block);    // 工具完整准备好，可以执行
                break;

            case "message_stop":
                // 整个消息结束，所有工具都准备好了
                break;
        }
    }

    private void onToolReady(ToolUseBlock block) {
        // 异步发起工具调用，不阻塞 SSE 处理
        toolExecutor.submit(() -> {
            ToolResult result = toolRegistry.execute(block);
            saveResult(block.getId(), result);
        });
    }
}
```

### 6.3 流式 Tool Call 的用户体验

```
[用户] 上海北京明天天气对比
[模型流] 我帮你查...
[模型流] (开始 tool_use: get_weather city=上海) ← 前端可显示 "正在查询上海天气..."
[模型流] (开始 tool_use: get_weather city=北京) ← 前端可显示 "正在查询北京天气..."
[消息结束]
[开发者] 并行执行两个工具
[开发者] 把结果回灌进 messages，再次流式调 LLM
[模型流] 上海明天有雨 18-22 度，建议带伞...
```

> ⚠️ **不要让用户等到所有工具结束才看到任何内容**——前端在收到 `content_block_start: tool_use` 时就该显示进度提示。

---

## 七、防 Tool Loop 死循环（必考）

### 7.1 死循环的真实场景

**场景 1**：模型反复尝试同一个失败工具
```
模型 → search_kb("退款政策") → 工具返回 "无结果"
模型 → search_kb("退款规则")  → 工具返回 "无结果"
模型 → search_kb("退款规定")  → 工具返回 "无结果"
模型 → search_kb("退货政策")  → 工具返回 "无结果"
... 50 次
```

**场景 2**：A 工具结果让模型调 B 工具，B 结果让模型调 A
```
模型 → query_user(123) → 返回 user 数据
模型 → query_orders(user_id=456) → 返回订单
模型 → query_user(789) ← 模型搞乱了 ID 关系
模型 → query_orders(user_id=999)
... 200 步
```

**场景 3**：模型在思考但**不输出**
```
模型在 CoT 里反复推理，输出 100K Token 的"思考过程"，没调任何工具也没给最终答案
```

### 7.2 防御机制

```
┌──────────────────────────────────────────────────────────┐
│  Defense Layer 1：硬上限                                  │
│    max_iterations = 15                ← 工具调用步数上限  │
│    max_total_tokens = 100,000         ← 整个会话 Token 上限│
│    max_cost_usd = 1.0                 ← 单次会话成本上限  │
│    max_duration_seconds = 120          ← 总耗时上限        │
├──────────────────────────────────────────────────────────┤
│  Defense Layer 2：重复检测                                │
│    最近 3 次工具调用名+参数完全一致 → 中断                 │
│    最近 5 次工具调用同名 + 不同参数但都失败 → 中断          │
├──────────────────────────────────────────────────────────┤
│  Defense Layer 3：进展度检测                              │
│    连续 N 步未产生最终答案的 token → 强制让模型给结论       │
│    连续 N 步工具结果相似度高 → 提示模型换思路              │
├──────────────────────────────────────────────────────────┤
│  Defense Layer 4：兜底回复                                │
│    被中断后，给用户一个友好回复："抱歉这个问题我没处理好..."│
│    并把现场 Token / 工具调用日志告警出来                  │
└──────────────────────────────────────────────────────────┘
```

### 7.3 Java 实现示例

```java
public class AgentRunner {
    private static final int MAX_ITERATIONS = 15;
    private static final int MAX_TOKENS = 100_000;
    private static final double MAX_COST_USD = 1.0;
    private static final int MAX_DURATION_SEC = 120;

    public AgentResult run(String userInput) {
        AgentState state = new AgentState(userInput);
        long startMs = System.currentTimeMillis();

        for (int i = 0; i < MAX_ITERATIONS; i++) {
            checkDeadline(startMs);
            checkBudget(state);

            LlmResponse resp = llmClient.chat(state.getMessages(), tools);
            state.addAssistantMessage(resp);

            if (resp.getStopReason() == StopReason.END_TURN) {
                return state.toResult();   // 模型给了最终答案
            }

            if (resp.getStopReason() == StopReason.TOOL_USE) {
                List<ToolUse> uses = resp.getToolUses();

                // 重复检测
                if (isRepeated(state.recentToolCalls(), uses)) {
                    log.warn("Tool loop detected, forcing termination");
                    return abortWithFallback(state);
                }

                // 并行执行 + 容错
                List<ToolResult> results = executeParallel(uses);
                state.addToolResults(uses, results);
            }
        }

        // 步数上限被触发
        log.warn("Max iterations reached without final answer");
        return abortWithFallback(state);
    }

    private boolean isRepeated(List<ToolCall> recent, List<ToolUse> current) {
        if (recent.size() < 3) return false;
        // 最近 3 次完全相同
        return recent.stream().skip(recent.size() - 3)
                     .allMatch(c -> c.equalsByNameAndArgs(current.get(0)));
    }

    private void checkBudget(AgentState state) {
        if (state.getTotalTokens() > MAX_TOKENS) throw new BudgetExceededException("token");
        if (state.estimateCost() > MAX_COST_USD) throw new BudgetExceededException("cost");
    }
}
```

---

## 八、生产踩坑

### 坑 1：Schema description 写太简单，模型乱选工具

**现象**：客服 Agent 有 8 个工具：`search_kb` / `query_order` / `query_user` / `cancel_order` / `refund` / `submit_ticket` / `query_logistics` / `escalate_human`。用户问"我的订单到哪了"，模型有 30% 概率选 `search_kb` 而不是 `query_logistics`。

**根因**：
1. `query_logistics` 的 description 只写了 "查询物流"
2. `search_kb` description 太宽 "搜索知识库"——模型觉得"物流问题"也能搜知识库

**修复**：
- `query_logistics`: `"查询订单的物流配送信息（包含运单号、配送状态、预计送达时间、配送员联系方式）。**当用户询问订单到哪、什么时候送到、能不能改地址时使用此工具，而不是 search_kb**。需要订单号作为参数。"`
- `search_kb`: `"搜索通用知识库（政策、FAQ、产品介绍）。**不适用于个人订单 / 物流 / 个人账户查询**——那些请用 query_order / query_logistics / query_user。"`
- 上线注入测试集（30 个典型用户提问），离线评估准确率，调整 description 直到 ≥ 95%。

**指标**：`metric: tool_choice_accuracy{tool, intent}`

### 坑 2：并行调用副作用工具，状态错乱

**现象**："标记订单 12345 已退款并发邮件给用户"——模型并行调了 `mark_refunded` 和 `send_email`。`mark_refunded` 因数据库唯一键冲突失败，但 `send_email` 已成功发出"已退款"邮件。用户疑惑：邮件说退款了，但订单还显示"待付款"。

**根因**：写操作类工具默认开启并行，没强制串行。

**修复**：
- 系统级**对所有写工具默认 `disable_parallel_tool_use=true`**（Anthropic）/ `parallel_tool_calls=false`（OpenAI）
- 写工具 description 中明确 `"此操作有副作用。仅在前置工具确认成功后调用。"`
- 业务关键操作改成"二阶段"：先 `prepare_refund` 拿到 token → 模型确认 → `commit_refund(token)`
- 加分布式事务 / 补偿（参考 [Distributed/分布式事务](../Distributed/分布式事务.md)）

**指标**：`metric: tool_parallel_count_per_call` / `alert: 单 call 写操作并行 > 1`

### 坑 3：Tool Loop 死循环烧 200 美元

**现象**：周末告警没人看，单个会话从早 8 点跑到中午，烧了 200 美元。

**根因**：
1. 没设 max_iterations
2. 用户问题模糊，模型反复调 `search_kb` 换关键词
3. 没设 cost 上限熔断

**修复**：
- `max_iterations=15`、`max_cost_usd=1.0` 双保险
- 重复检测：最近 3 次工具调用名+参数完全一致 → 强制 `tool_choice="none"` 让模型给最终答案
- 监控告警：单次会话成本 > $0.5 立即告警值班 + 记录现场

**指标**：
```
metric: agent_iterations_per_session
metric: agent_cost_usd_per_session
alert: agent_cost_usd_per_session > 0.5（warning） / > 1.0（critical）
```

### 坑 4：流式 Tool Call 的 partial_json 拼接错位

**现象**：流式响应中收到 `partial_json: "{\"city\":"`、`partial_json: "\"上海\""`、`partial_json: "}"`，开发者用同一个 StringBuilder 拼，但因为模型并行返回两个 tool_use，**两个工具的 partial_json 互相穿插**，最终拼出来的 JSON 是 `{"city":"上海"city":"北京"}` 解析失败。

**根因**：流式 SDK 收到 partial_json 时，没有按 tool_use_id 分桶。

**修复**：
- 用 `Map<String, StringBuilder> partialJsonByToolId` 按 ID 分桶
- 每个 `content_block_start` 事件都新开 StringBuilder
- `content_block_stop` 时再 JSON 解析，**不要边拼边解析**

代码见第 6.2 节示例。

### 坑 5：模型幻觉调用未注册的工具

**现象**：模型输出 `tool_use: get_user_phone(...)`，但服务端从未注册这个工具——模型基于训练记忆"幻觉"出了一个常见函数名。

**根因**：当前注册的是 `query_user`，名字接近但不一致；模型不严格匹配。

**修复**：
- 工具调用前**严格按 name 校验白名单**
- 未知工具立即返回 `is_error=true, content="tool 'get_user_phone' not found. Available tools: [query_user, ...]"`
- 模型通常会自纠错重选 `query_user`
- 监控：`metric: tool_unknown_call_total`，> 5 / 小时 告警检查 description 是否模糊

---

## 九、面试高频追问

**Q1：Function Calling 的底层实现是什么？模型真的"调用"了函数吗？**

模型本身**没有执行能力**，只是被微调成"在合适场景输出特定格式的 Token 序列（标记 tool_use 块）"。开发者代码捕获到这个标记，**自己发起 HTTP / SQL / 命令**，把结果以特定格式回灌给模型继续推理。所以"调用"是开发者代码做的，**模型只是决策"调什么 + 用什么参数"**。这也是为什么权限控制 / 安全防御都在开发者侧。

**Q2：OpenAI 和 Anthropic 的 Tool Use 协议为什么不统一？**

历史包袱 + 设计理念差异。OpenAI 早期用 `function_call`（单数），后改 `tool_calls`（复数支持并行），向前兼容了一堆遗留字段，且 arguments 是 JSON 字符串需要客户端 parse。Anthropic 从一开始就定 `tool_use` 块作为 content 的一种类型，input 直接给对象。Google Gemini 走 protobuf 风格。**实际生产建议自己抽一层适配，或用 LangChain4j / Spring AI 的 ChatModel 抽象**。

**Q3：模型并行返回 5 个 tool_use 怎么处理？**

并行执行（`CompletableFuture.allOf` 等所有完成）→ 每个工具结果都要回传（**缺一个会报错**）→ 再次调 LLM。生产上要注意：① 工具间有依赖时关并行；② 写操作 / 副作用类工具默认串行；③ 给单个工具设 timeout（典型 10s），超时返回 error result，不要让一个慢工具拖死全局。

**Q4：Tool 失败了应该重试吗？**

分情况：① **客户端隐式重试**：瞬时网络错误（连接超时、DNS）退避重试 1-2 次，不告诉模型；② **告诉模型**：业务错误（参数错、记录不存在），返回 `is_error=true` + 简短描述 + 建议，让模型决定重试 / 换工具 / 放弃；③ **立即终止**：成本上限 / 步数上限 / 危险工具未授权。**死循环防御里"模型反复调同一失败工具"要识别并强制中断**。

**Q5：怎么防止 Tool Loop 死循环？**

四层防御：① **硬上限**：max_iterations=15、max_total_tokens、max_cost_usd、max_duration；② **重复检测**：最近 3 次工具调用名+参数完全一致就中断；③ **进展度检测**：连续 N 步未产生最终答案就强制 `tool_choice="none"` 让模型总结；④ **兜底回复**：超限被中断时给用户友好回复并告警。**生产必备**——周末没人看的话一次死循环能烧几百美元。

**Q6：Schema description 写得好和差差多少？**

实测**准确率差距能到 30%**。description 决定模型选不选这个工具的语义匹配度。好 description 的模板：① 说"是什么 + 什么时候用"；② 说"什么时候不该用"（互斥工具区分）；③ 说"返回什么"；④ 写参数边界。**工具数 > 15 后准确率显著下降**，这时候要分组 / 拆 Agent。

**Q7：流式 Tool Call 怎么处理？**

工具的 input JSON 是按 Token 流式来的（`input_json_delta`），**必须等到 `content_block_stop` 才能拼出完整 JSON 解析**——拼到一半的 JSON 不合法。多个并行工具的 partial_json 会穿插，**必须按 tool_use_id 分桶**用单独的 StringBuilder 拼。前端 UX 上，收到 `content_block_start: tool_use` 就显示"正在查询..."进度提示，不要等所有工具结束才有反馈。

**Q8：强制让模型必须调用某工具怎么做？什么场景用？**

OpenAI: `tool_choice={type: "function", function: {name: "X"}}`；Anthropic: `tool_choice={type: "tool", name: "X"}`。场景：① **结构化输出**——把 JSON Schema 包成"伪工具"强制调用拿结构化数据；② **工作流第一步**——必须先调 `validate_input` 才能进后续；③ **测试 / 调试** 模型对某工具的参数填写质量。**不要每次都强制**，这破坏了 Agent 的自主决策能力。

**Q9：30+ 个工具模型选不准怎么办？**

三种方案：① **拆 Agent**：按场景拆，每个 Agent 暴露 5-10 个工具，主 Agent 路由到子 Agent；② **二级路由**：第一次调用 `route_intent` 工具决定走哪个领域，第二次只暴露领域内工具；③ **MCP 分层**：每个领域一个 MCP Server，主 Agent 按用户意图动态挂载。**别试图一次塞 30 个工具——准确率掉到 60% 以下**。

**Q10：Anthropic 的 Tool Use 和 Structured Output 是什么关系？**

Anthropic 没有 OpenAI 的 `response_format=json_schema strict:true` 等价方案，但通过 **Tool Use 强制调用** 实现等价效果：
1. 把目标 JSON Schema 包装成一个"伪工具"`submit_data`，input_schema 就是目标结构
2. 设 `tool_choice={type: "tool", name: "submit_data"}` 强制调
3. 从 `response.content[0].input` 拿到强 schema 校验过的 JSON

这就是为什么很多 LangChain4j / Spring AI 的 "structured output" 实现底层都是 Tool Use。

---

## 十、答题模板（60 秒）

> "Function Calling 的本质是 **LLM 输出 'tool_use' 标记，开发者代码执行工具，结果回灌给模型继续推理**。三家协议字段不同（OpenAI tool_calls、Anthropic content[tool_use]、Gemini function_call），生产里建议封一层适配。"
>
> "**并行调用默认开**，但**写操作 / 副作用工具必须强制串行**（disable_parallel_tool_use），否则会出现"邮件发了但订单状态没改"的事故。"
>
> "**Tool 错误三种处理**：瞬时错误客户端隐式重试；业务错误返回 is_error=true 让模型决定；成本 / 步数上限直接中断。**Tool Loop 必须四层防御**：硬上限（max_iterations=15、max_cost=$1）+ 重复检测 + 进展度检测 + 兜底回复。"
>
> "**Schema 设计是准确率的 80%**：工具数 ≤ 15、description 写'是什么+何时用+何时不用+返回什么'、参数 enum / 边界 / 例子全写上。我们生产 description 写得好 vs 差准确率差 30%。"
>
> "**Anthropic 的 Structured Output 用 Tool Use 强制调用模拟**：把目标 Schema 包成伪工具 + tool_choice 强制 → 从 input 拿强校验过的 JSON。"

---

## 十一、相关文档

- [LLM 基础与面试视角](LLM基础与面试视角.md) — Token / 流式 / 推理参数
- [Prompt Engineering](PromptEngineering.md) — Tool Use 强约束做 Structured Output
- [Agent 架构模式](Agent架构模式.md) — ReAct / Plan-and-Execute 都基于 Tool Use 之上
- [MCP 协议](MCP协议.md) — Tool 的服务化与权限分级
- [Agent 框架对比](Agent框架对比.md) — LangChain4j / Spring AI 怎么封装 Tool Use
- [LLM 应用工程化](LLM应用工程化.md) — Tool 调用的限流 / 缓存 / 降级
- [RAG 与 Agent 生产踩坑](RAG与Agent生产踩坑.md) — Tool Loop / 副作用错乱真实事故
- [Distributed/分布式事务](../Distributed/分布式事务.md) — Tool 写操作的事务保护
