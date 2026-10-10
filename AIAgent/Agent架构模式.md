# Agent 架构模式

> 引子：会写 Function Calling 不等于会做 Agent。**Agent 的核心是"自主决策 + 多步执行 + 失败回滚"的工程化架构**，面试官关心的不是哪个框架名词最潮，而是：
>
> ① **ReAct vs Plan-and-Execute** 这两个最经典的模式区别在哪？什么场景该用哪个？
> ② **Multi-Agent** 的几种拓扑（Supervisor / Hierarchical / Network / Group Chat）什么场景用？多 Agent 真的比单 Agent 强吗？
> ③ **Reflection / Self-Critique** 是什么？Token × 2 的代价值得吗？
> ④ **状态机 Agent**（StateGraph）和"自由 Agent"的取舍——什么场景该上"轨道"？
> ⑤ **死循环 / 跑偏 / 步数失控** 的工程兜底机制怎么做？
>
> 这一篇是"面试官追问 Agent 架构"的标准答案集。

---

## 一、Agent 的本质定义

### 1.1 一个最小 Agent 的循环

```
┌─────────────────────────────────────────────────┐
│             Agent Loop                           │
│                                                  │
│   ┌──> 观察（Observation）                       │
│   │      ↓                                       │
│   │    思考（Thought / LLM 推理）                 │
│   │      ↓                                       │
│   │    行动（Action / Tool Call）                 │
│   │      ↓                                       │
│   │    工具执行 / 拿到结果                         │
│   │      ↓                                       │
│   └──── 直到 LLM 输出 "最终答案"                   │
└─────────────────────────────────────────────────┘
```

> **关键认知**：Agent = LLM + Loop + Tools + State。LLM 是大脑，Loop 是身体，Tools 是手脚，State 是记忆。

### 1.2 Agent vs Workflow（流程编排）

| 维度 | Workflow | Agent |
|---|---|---|
| 执行路径 | 预定义、固定 | LLM 自主决策、动态 |
| 失败处理 | 显式分支 | LLM 自主重试 / 换路径 |
| 灵活性 | 低（改流程要改代码） | 高（改 Prompt / Tools） |
| 可控性 | 高（路径确定） | 低（不确定性强） |
| 调试 | 容易 | 难（LLM 黑盒） |
| 适用 | 结构化、规则明确的任务 | 探索性、多变的任务 |

> **生产经验**：**业务核心路径用 Workflow，分支决策点用 Agent**。例如订单退款主流程是 Workflow（合规要求路径确定），但"用户问"的客服回复内的判断分支用 Agent。

---

## 二、五种主流 Agent 模式

### 2.1 ReAct（Reasoning + Acting）

**论文**：ReAct: Synergizing Reasoning and Acting in Language Models (Yao et al., 2022)

**核心思想**：让 LLM **交替输出 "思考" + "行动"**，思考引导行动，行动结果继续推动思考。

```
Thought: 用户问上海明天天气，我应该调用 get_weather
Action: get_weather(city="上海", date="2026-05-10")
Observation: 明天上海有雨 80%

Thought: 还需要确认温度
Action: get_weather(city="上海", date="2026-05-10", detail="temperature")
Observation: 18-22 度

Thought: 信息够了
Final Answer: 明天上海有雨，气温 18-22 度，建议带伞
```

**优点**：
- 实现简单——本质就是 [Function Calling](FunctionCalling与ToolUse.md) + 多轮循环
- 灵活——模型自己决定下一步
- 对简单任务足够好

**缺点**：
- **长链路易跑偏**——5 步以上经常南辕北辙
- **步数失控**——没硬上限会死循环
- **错误传播**——前一步错了后面全错，没重规划能力

**适用场景**：单 Agent + 工具数 ≤ 10 + 任务步数 ≤ 5 的简单场景。客服 Q&A、查询型应用、单领域助手。

### 2.2 Plan-and-Execute

**论文**：Plan-and-Solve Prompting (Wang et al., 2023) / LangChain 推广

**核心思想**：先让 LLM **完整规划所有步骤**，再按步骤执行；执行中如果偏离规划，可以触发重规划。

```
Plan:
1. 查询用户订单
2. 检查订单状态
3. 如果状态是"已发货"，调用物流查询
4. 否则告知用户当前状态
5. 整理回复

Execute Step 1: query_order(user_id=123)
  → result: order_id=456, status="已发货"
Execute Step 2-3: query_logistics(order_id=456)
  → result: 已到上海中转站
Execute Step 5: 整理回复

Final Answer: 您的订单已发货，目前到达上海中转站...
```

**优点**：
- **鲁棒性强**——预先规划，每步目标明确
- **可中断 / 可审计**——计划是显式的，可日志化
- **支持分支 / 失败回滚**——某步失败可重规划

**缺点**：
- **首次规划不准时全盘崩**——计划错了执行也错
- **Token 多**——计划本身要花一轮 LLM
- **不灵活**——计划做了就执行，不擅长动态调整

**适用场景**：多步骤可拆解任务 + 步数 5-15 + 业务路径相对结构化。订单处理、数据分析、报告生成。

### 2.3 Reflection / Self-Critique

**核心思想**：让 LLM **执行 → 自我评审 → 修正 → 输出**，相当于"做完作业自己再检查一遍"。

```
Step 1 (Generate):
  LLM 生成代码 / 答案 / 报告

Step 2 (Reflect):
  另一个 LLM（或同一 LLM 不同 Prompt）扮演"严格审查员"
  挑错：逻辑漏洞 / 边界 / 性能问题

Step 3 (Refine):
  原 LLM 收到批评 → 改进 → 再输出
  
（可循环 1-3 次）
```

**优点**：
- 输出质量显著提升（10-30% 错误率下降）
- 实现简单（多调用一次 LLM）

**缺点**：
- **Token 翻倍**（成本 × 2-3）
- **延迟翻倍**（对实时场景不适合）
- **过度自省**——可能把对的改错

**适用场景**：高质量要求 + 可接受延迟 + 离线 / 准实时。代码生成、长文写作、关键报告。

### 2.4 Multi-Agent（多 Agent 协作）

**核心思想**：多个 Agent 各自专精领域，协作完成复杂任务。

#### 拓扑 1：Supervisor（监督者）

```
              ┌──────────────┐
              │  Supervisor  │ ← 接收用户请求
              └──────┬───────┘
                     │ 路由
       ┌─────────────┼─────────────┐
       ↓             ↓             ↓
   ┌───────┐    ┌────────┐    ┌─────────┐
   │ Agent1│    │ Agent2 │    │ Agent3  │
   │ 销售  │    │ 售后   │    │ 技术    │
   └───────┘    └────────┘    └─────────┘
       │             │             │
       └─────────────┼─────────────┘
                     ↓
              Supervisor 整合 / 返回用户
```

适用：客服多领域分流、跨业务线统一入口。

#### 拓扑 2：Hierarchical（层级）

```
               ┌────────────┐
               │ Manager 层 │
               └─────┬──────┘
                     │
        ┌────────────┼────────────┐
        ↓            ↓            ↓
   ┌────────┐   ┌────────┐   ┌─────────┐
   │ Lead 1 │   │ Lead 2 │   │ Lead 3  │
   └────┬───┘   └────┬───┘   └────┬────┘
        │            │            │
   ┌────┴───┐   ┌────┴───┐   ┌────┴────┐
   │ Worker │   │ Worker │   │ Worker  │
   │ Worker │   │ Worker │   │ Worker  │
   └────────┘   └────────┘   └─────────┘
```

适用：复杂任务分解（写代码 = 架构师 + 后端 + 前端 + 测试）。

#### 拓扑 3：Network / Group Chat

```
   ┌─────────┐ ←→ ┌─────────┐
   │ Agent A │     │ Agent B │
   └─────────┘ ↘ ↗ └─────────┘
                 ╳
   ┌─────────┐ ↗ ↘ ┌─────────┐
   │ Agent C │ ←→ │ Agent D │
   └─────────┘     └─────────┘
```

适用：开放式协作（讨论、辩论、头脑风暴）。

#### 拓扑 4：Sequential（流水线）

```
   ┌──────┐    ┌──────┐    ┌──────┐
   │ A 提取│ →  │ B 分析│ →  │ C 总结│
   └──────┘    └──────┘    └──────┘
```

适用：固定流程的多 Agent 接力（数据 ETL 风格）。

### 2.5 状态机驱动 Agent（StateGraph）

**核心思想**：把 Agent 抽象成**有限状态机**，状态间转移由 LLM 决定但**只能走预定义边**。

```
    ┌───────────┐
    │  IDLE      │
    └─────┬──────┘
          │ user_input
          ↓
    ┌───────────┐    needs_clarify    ┌──────────────┐
    │ ANALYZING │ ────────────────→   │ ASKING_USER  │
    └─────┬──────┘                    └──────┬───────┘
          │ ready                            │ user_reply
          ↓                                  ↓
    ┌───────────┐  ←────────────────────────┘
    │ EXECUTING │
    └─────┬──────┘
          │ done / error
          ↓
    ┌───────────┐
    │ FINISH    │
    └───────────┘
```

**优点**：
- **可控**——状态有限，跑不偏
- **可审计**——每条状态转移可日志
- **可恢复**——崩了从最后状态继续

**缺点**：
- **灵活性差**——新需求要改图
- **设计成本高**——前期建模工作量大

**适用场景**：业务约束强 + 合规要求高的场景。LangGraph 是这个范式的代表实现。详见 [Agent 框架对比](Agent框架对比.md)。

### 2.6 五种模式对比

| 模式 | 实现难度 | 灵活性 | 可控性 | Token 成本 | 典型场景 |
|---|---|---|---|---|---|
| ReAct | ★ | ★★★★★ | ★★ | 低 | 客服 / 查询助手 |
| Plan-and-Execute | ★★ | ★★★ | ★★★★ | 中 | 订单 / 数据分析 |
| Reflection | ★★ | ★★★ | ★★★ | 高（×2-3） | 代码 / 写作 |
| Multi-Agent | ★★★★ | ★★★★ | ★★ | 很高 | 跨领域 / 复杂任务 |
| StateGraph | ★★★ | ★★ | ★★★★★ | 中 | 工作流 / 合规场景 |

---

## 三、Agent 的状态管理

### 3.1 单次 Agent 运行的 State

```java
public class AgentState {
    private String sessionId;
    private List<Message> messages;             // 对话历史
    private List<ToolCall> toolCallHistory;     // 工具调用记录
    private Map<String, Object> scratchpad;     // 中间变量
    private int iterations;                     // 当前步数
    private long totalTokens;
    private double totalCostUsd;
    private long startMs;
    private AgentStatus status;
}
```

### 3.2 跨会话的长期记忆

参考 [上下文与记忆管理](上下文与记忆管理.md)。短期记忆（消息历史）+ 长期记忆（向量记忆 / Summary Buffer）+ 用户偏好（KV）。

### 3.3 状态持久化场景

```
场景：Agent 跑到一半 OOM 重启 / Pod 漂移 / 用户退出再回来
解决：
  - 每个状态变更写 Redis（短期）/ DB（长期）
  - sessionId 作为恢复 key
  - 关键：tool_call 的中间结果也要存（重启后不重复调用）
```

---

## 四、防跑偏与防死循环

### 4.1 多层防御机制

```
┌──────────────────────────────────────────────────────┐
│  L1：硬上限（任何模式必有）                              │
│    max_iterations = 15                                │
│    max_total_tokens = 100,000                         │
│    max_cost_usd = 1.0                                 │
│    max_duration = 120s                                │
├──────────────────────────────────────────────────────┤
│  L2：重复检测                                           │
│    最近 N 步工具调用名+参数完全一致 → 中断              │
│    最近 N 步工具结果相似度 > 阈值 → 中断                 │
├──────────────────────────────────────────────────────┤
│  L3：进展度检测                                          │
│    距离最终答案"似乎没进展" → 强制 tool_choice="none"   │
│    State 中的 todo_list 完成度连续 N 步未变 → 重规划    │
├──────────────────────────────────────────────────────┤
│  L4：成本预算控制                                        │
│    每次工具调用前检查累计成本                            │
│    跨用户 / 租户 daily quota                           │
├──────────────────────────────────────────────────────┤
│  L5：兜底回复                                           │
│    被中断后给用户友好回复 + 后台告警                      │
│    "本次任务未完成，已为你转人工 / 记录工单"              │
└──────────────────────────────────────────────────────┘
```

### 4.2 ReAct 模式的死循环典型

```
现象：模型反复换关键词搜同一个东西
迭代 1: search_kb("退货政策")     → "未找到"
迭代 2: search_kb("退货规定")     → "未找到"
迭代 3: search_kb("退货流程")     → "未找到"
迭代 4: search_kb("退款政策")     → "未找到"  ← 偏题了
迭代 5: search_kb("售后")         → "未找到"
... 烧到 max_iterations
```

**修复**：
- 重复检测：连续 3 次 `search_kb` 都"未找到" → 强制让模型换工具或给最终答案
- 进展度检测：3 步无新工具结果 → 重规划

### 4.3 Plan-and-Execute 的失败回滚

```python
def execute_with_replan(plan, max_replans=2):
    for replan_count in range(max_replans + 1):
        for step in plan.steps:
            try:
                result = execute_step(step)
                if not result.is_satisfactory():
                    # 步骤完成但质量不好
                    plan = replan(plan, current_step=step, feedback=result)
                    break
            except StepFailedException as e:
                # 步骤完全失败
                plan = replan(plan, failed_step=step, error=e)
                break
        else:
            return final_answer(plan)
    return fallback_answer()
```

### 4.4 Multi-Agent 的协调成本

**反模式**：5 个 Agent 互相 chat，每条消息所有人都看，**Token 消耗 N²**。

**最佳实践**：
- 用 **Supervisor 路由**而不是 Group Chat（除非真的需要协作讨论）
- 设 Supervisor 的 max_handoffs（最多转交 5 次）
- Agent 间传**简短摘要**而不是完整对话历史
- 关键状态写入共享 Memory，不在消息流里反复传

---

## 五、Agentic RAG：自主决策何时检索

### 5.1 普通 RAG vs Agentic RAG

```
普通 RAG：
  user query → 必检索 → 拼 Prompt → 生成答案
  缺点：闲聊也检索 / 检索不到也强答 / 不能多轮检索

Agentic RAG：
  user query → LLM 判断"要不要检索 / 检索什么 / 检索几次" → 多次决策 → 综合
  优点：
   - 不必要时跳过检索（"你好" 不查 KB）
   - 不够时多次检索（先查产品再查政策）
   - 找不到时承认（不强答）
```

### 5.2 实现：把检索做成 Tool

```python
tools = [
    {
        "name": "search_kb",
        "description": "搜索内部知识库。当需要查询产品 / 政策 / FAQ 信息时调用。",
        "input_schema": {...}
    },
    {
        "name": "search_web",
        "description": "搜索外部互联网。当 search_kb 找不到 / 需要实时信息时调用。",
        "input_schema": {...}
    }
]

# Agent Loop（ReAct）让 LLM 自己决定调几次检索
```

### 5.3 适用场景

- 闲聊 + 知识问答混合的客服
- 多领域知识库（先 query_router 决定查哪个 KB）
- 需要多步推理的 QA（先查 A 再基于结果查 B）

---

## 六、生产踩坑

### 坑 1：纯 ReAct 应付不了 5 步以上任务，跑偏率 30%

**现象**：用 ReAct 做"分析用户最近 3 个月订单 + 生成报告"任务，5 个步骤以上跑偏率 30%——模型经常忘记前面拿到的数据，重新调工具拿一遍。

**根因**：
- ReAct 没有显式 plan，模型"边想边做"，在长任务上失去全局视野
- 上下文中工具结果太多，模型注意力被稀释
- 没有 todo_list / scratchpad 保留全局进度

**修复**：
- 切换到 Plan-and-Execute：先让模型生成 plan（5 步明确）→ 按 plan 执行
- Plan 在 State 里固化，每步执行完更新进度
- Execute 阶段限制 LLM"只关注当前步骤"
- 步数超限触发重规划

**指标**：
```
metric: agent_completion_rate{mode=react|plan_execute}
metric: agent_avg_iterations{mode}
```

### 坑 2：Multi-Agent 5 个 Agent 互相聊，烧了 4 倍 Token

**现象**：上线"研究助手" Multi-Agent（PM / 研究员 / 编辑 / 校对 / Lead），每个任务 Token 消耗是单 Agent 的 4 倍，但质量提升只有 5%。

**根因**：
- 用了 Group Chat 拓扑，每条消息全员可见，N² 增长
- Agent 间传完整对话历史而不是摘要
- 没有 Supervisor 控制转交次数

**修复**：
- 改用 Supervisor + 4 个 Worker 拓扑
- Supervisor 决定转交给哪个 Worker，**只传任务摘要 + 上下文重点**
- 每个 Agent 完成后写入共享 Memory（关键结果 KV），其他 Agent 按需读取
- 设 max_handoffs=5，超限走兜底

**对比**：
| 拓扑 | Token | 质量 |
|---|---|---|
| Group Chat 5-Agent | ×4 | +5% |
| Supervisor + 4 Worker | ×1.5 | +12% |

### 坑 3：Reflection 反思把对的改成了错的

**现象**：代码 Agent 用 Reflection（生成 → 自评 → 修改），发现修改后的代码反而引入新 bug。

**根因**：
- 评审 LLM 太"挑剔"，鸡蛋里挑骨头，把对的也质疑
- 修改 LLM 看到批评就照单全收，过度修改
- 没有"评审通过"的退出机制——总会被改

**修复**：
- Reflection 加 **score 字段**（评审打分 0-10），>= 8 直接接受不改
- 评审 Prompt 强调"只挑会导致 bug 的问题，风格 / 命名等不算"
- 限制 reflection 轮次（最多 2 次）
- 加单元测试驱动：reflection 后跑测试，测试不过才改

### 坑 4：状态机改业务路径要改代码，灵活性死了

**现象**：用 LangGraph 做客服 Agent，每次新增一个业务场景（如"会员升级"）都要画图 + 改代码 + 上线。

**根因**：StateGraph 把所有路径硬编码进图，改一个场景就要改图。

**修复**：
- 主干用 StateGraph（合规 / 关键路径）
- 在 StateGraph 中嵌入 ReAct 子节点（处理灵活分支）
- 状态机控制"业务流"，ReAct 控制"对话流"
- 新场景在 ReAct 范围内通过加 Tool / 改 Prompt 上线，不动 StateGraph

### 坑 5：Agent 跑到 14 步突然把对话记录全清了

**现象**：长任务跑到 14 步时，模型"忘记"了开头的用户问题，回复"我可以帮你做什么"。

**根因**：
- 前面工具结果累积太多，**自动滑动窗口把头部消息（含用户原始 query）剔除**
- ReAct 模式下没有"任务总目标"的固化机制

**修复**：
- 用户原始 query 写入 State.original_query，每轮注入到 System Prompt
- 滑动窗口策略改成"保留最近 K 轮 + 始终保留 System + 用户首条"
- 长任务用 Summary Buffer 压缩中间步骤而不是丢弃
- 监控 messages.length，超过阈值告警查 prompt 大小

详见 [上下文与记忆管理](上下文与记忆管理.md)。

---

## 七、面试高频追问

**Q1：ReAct 和 Plan-and-Execute 区别？什么时候用哪个？**

ReAct 是"边想边做"——每步 LLM 输出 Thought + Action，看到 Observation 再决定下一步。优点是简单、灵活；缺点是长任务（5+ 步）容易跑偏。Plan-and-Execute 是"先想全再做"——LLM 第一轮先输出完整 plan（5-10 步），后续按 plan 执行，失败可重规划。优点是鲁棒、可审计；缺点是首次规划错就全错。**经验**：步数 ≤ 5 用 ReAct，步数 5-15 用 Plan-and-Execute，> 15 用 StateGraph 拆分。

**Q2：Multi-Agent 真的比单 Agent 强吗？**

不一定。Multi-Agent 在以下场景显著好：① **跨领域任务**——不同 Agent 专精不同领域；② **角色对抗**——评审 / 编辑等需要"换视角"；③ **并行任务**——多个独立子任务可同时跑。但代价是 **Token 消耗 2-5x、协调成本高、调试难**。生产经验：能用单 Agent + 工具丰富解决的，不要上 Multi-Agent；上 Multi-Agent 优先 Supervisor 拓扑，避免 Group Chat 的 N² 通信。

**Q3：Reflection 值得吗？**

视场景而定。**值得**：代码生成 / 长文写作 / 关键报告——质量提升 10-30%、可接受延迟翻倍。**不值得**：实时聊天 / 简单 QA——延迟 / 成本翻倍但质量提升 < 5%。生产实践：加 score 字段，评审打分 ≥ 8 直接通过不修改；最多 reflection 2 次防过度修改。

**Q4：StateGraph（LangGraph）相比 ReAct 优势在哪？**

可控性 + 可审计性 + 可恢复性。StateGraph 把所有可能的状态转移**显式定义**，模型只能在预定义边上走，不会跑偏；状态变化可日志化便于审计；崩了从最后状态继续。**代价**：灵活性差、设计成本高。**生产做法**：合规要求高 / 业务路径关键的部分用 StateGraph，灵活分支处嵌入 ReAct 子节点。

**Q5：Agent 怎么防死循环？**

**五层防御**：① 硬上限（max_iterations=15、max_cost=$1、max_duration=120s）；② 重复检测（最近 3 步工具调用名+参数完全一致就中断）；③ 进展度检测（连续 N 步无新工具结果就强制总结）；④ 成本预算（跨用户 daily quota）；⑤ 兜底回复（被中断时友好回复 + 告警）。生产里**周末没人看，一次死循环烧几百美元的故事是常态**。

**Q6：Agent 状态崩了 / 重启怎么恢复？**

**关键**：状态外置 + 幂等。① sessionId 作为恢复 key，每次状态变更写 Redis / DB；② 工具调用结果也要存（重启后不能重复调用——尤其副作用工具）；③ 工具调用前先查"是否已执行"，幂等保证；④ 关键操作走两阶段（prepare → commit）便于回滚。复杂场景考虑用 Temporal / Cadence 这类工作流引擎。

**Q7：Agentic RAG 是什么？比普通 RAG 好在哪？**

普通 RAG 是"必检索 → 生成"，闲聊也检索、检索不到也强答。Agentic RAG 把检索做成 Tool，LLM 自主决定**要不要检索 / 检索什么 / 检索几次**。优势：① 闲聊跳过检索；② 多领域时先 router 再查；③ 找不到时承认而不强答；④ 复杂问题多次检索综合。代价是延迟 / Token 略增（多了决策环节），但准确率和用户体验都更好。

**Q8：Agent 长任务上下文超限怎么办？**

四种策略：① **滑动窗口**——保留最近 K 轮 + 系统 + 用户首条；② **Summary Buffer**——把超出的旧消息压缩成摘要；③ **向量记忆**——历史消息存向量库，按需召回；④ **任务状态固化**——把 Plan / todo_list / 关键中间结果存 State，每轮 inject 到 Prompt。**生产推荐**：滑动窗口 + Summary Buffer + State 固化三管齐下。详见 [上下文与记忆管理](上下文与记忆管理.md)。

**Q9：Agent 测试 / 评估怎么做？**

很难。三个层次：① **单元测试**——对每个 Tool 单独测；② **集成测试**——给定 user input，跑全流程，断言最终输出包含关键内容；③ **离线评估集**——50-200 条标注数据，用 LLM-as-Judge 打分（任务完成度 / 工具选用正确率 / 回答质量）。生产监控：在线 A/B + 用户反馈率 + 步数分布 + 成本分布。详见 [Agent 评估与可观测性](Agent评估与可观测性.md)。

**Q10：Agent 在 Java 后端怎么落地？**

三种方式：① **Spring AI** + ChatClient + Function Callback——简洁、与 Spring Boot 生态融合；② **LangChain4j**——更接近 Python LangChain 风格、AI Service 抽象；③ **OpenAI/Anthropic 官方 SDK 直连 + 自实现 Loop**——控制力最强、依赖最少。生产建议 Spring AI 或 LangChain4j 起步，复杂 Agent 自实现 Loop。详见 [Agent 框架对比](Agent框架对比.md)。

---

## 八、答题模板（60 秒）

> "Agent 的本质是 **LLM + Loop + Tools + State**。"
>
> "**五种主流模式**：ReAct（边想边做，简单任务）、Plan-and-Execute（先规划再执行，多步任务）、Reflection（自评修正，高质量场景）、Multi-Agent（跨领域协作，Supervisor 拓扑优先）、StateGraph（状态机驱动，合规场景）。"
>
> "**生产选型**：步数 ≤ 5 用 ReAct，5-15 用 Plan-and-Execute，业务关键路径用 StateGraph，跨领域上 Multi-Agent。"
>
> "**防死循环必备五层**：硬上限（iterations=15 / cost=$1）+ 重复检测 + 进展度检测 + 成本预算 + 兜底回复。"
>
> "**状态管理**：sessionId 持久化，工具调用幂等，关键操作两阶段。**长任务上下文**：滑动窗口 + Summary Buffer + State 固化（用户原始 query 始终保留）。"
>
> "**Java 落地**：Spring AI / LangChain4j 起步，复杂 Agent 自实现 Loop。"

---

## 九、相关文档

- [Function Calling 与 Tool Use](FunctionCalling与ToolUse.md) — Agent 的工具调用基础
- [Prompt Engineering](PromptEngineering.md) — Agent System Prompt 设计
- [上下文与记忆管理](上下文与记忆管理.md) — Agent State + 长期记忆
- [Agent 框架对比](Agent框架对比.md) — LangGraph / Spring AI / LangChain4j 选型
- [LLM 应用工程化](LLM应用工程化.md) — Agent 限流 / 成本治理
- [Agent 评估与可观测性](Agent评估与可观测性.md) — Agent 评估指标
- [RAG 与 Agent 生产踩坑](RAG与Agent生产踩坑.md) — Agent 真实事故
- [MCP 协议](MCP协议.md) — 工具的服务化 / Agent 工具市场
