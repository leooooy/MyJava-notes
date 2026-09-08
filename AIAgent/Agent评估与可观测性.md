# Agent 评估与可观测性

> 引子：LLM 应用最难的不是写代码，而是回答**"它好不好"**。面试官一定会追问：
>
> ① **RAG 怎么评估**——RAGAS 五大指标是什么？为什么人工标注不可少？
> ② **LLM-as-Judge 可信吗**——同一个模型既写答案又打分不就左右互搏？
> ③ **Agent 评估怎么做**——任务完成度 / 步数 / 成本怎么量化？
> ④ **Trace 工具怎么选**——LangSmith / Langfuse / Phoenix / OpenTelemetry GenAI 各自定位？
> ⑤ **告警阈值怎么定**——首 Token 延迟 / 限流率 / 成本爆增的合理阈值是多少？
>
> 这一篇是"上线后睡得着觉"的关键——没有评估和观测，LLM 应用就是黑盒。

---

## 一、为什么 LLM 评估这么难

### 1.1 传统软件 vs LLM 应用

| 维度 | 传统软件 | LLM 应用 |
|---|---|---|
| 输出确定性 | 相同输入 → 相同输出 | 相同输入 → 不同输出（temperature） |
| 正确性判定 | 规则 / 单元测试 | 语义匹配 / 主观判断 |
| 失败模式 | 异常 / 报错 | 静默错误（看似合理实则编造） |
| 性能指标 | 延迟 / QPS / 错误率 | 还要 Token / 成本 / 幻觉率 / 用户满意度 |

### 1.2 三类常见错觉

**错觉 1**："看着回答挺合理的，应该没问题"
→ 抽样测试 100 条都对不代表线上 1 万条都对，**长尾问题被掩盖**。

**错觉 2**："上线后用户没投诉就是好"
→ 用户对 LLM 容忍度高，**质量降级用户也不投诉**，只是流失。

**错觉 3**："我每天都打开看一眼"
→ 人工肉眼看几条样本，**统计上没意义**。

### 1.3 评估的两个层级

```
┌────────────────────────────────────────────────┐
│  离线评估（Offline）                              │
│  - 评测集（200-500 条人工标注）                    │
│  - 在 CI / 上线前跑                               │
│  - 衡量：准确率 / 召回率 / 幻觉率                  │
│  - 用于：模型 / Prompt / RAG 配置变更前后对比      │
└────────────────────────────────────────────────┘

┌────────────────────────────────────────────────┐
│  在线监控（Online）                               │
│  - 实时埋点（每条请求）                            │
│  - Dashboard + 告警                              │
│  - 衡量：延迟 / 成本 / Token / 用户反馈           │
│  - 用于：发现降级 / 异常 / 限流                    │
└────────────────────────────────────────────────┘
```

---

## 二、RAG 评估：RAGAS 五大指标

### 2.1 五大指标定义

| 指标 | 评估对象 | 含义 |
|---|---|---|
| **Faithfulness**（忠实度） | 生成 | 答案是否被检索内容支持，**不编造** |
| **Answer Relevancy**（答案相关性） | 生成 | 答案是否切题（答非所问就低） |
| **Context Precision**（上下文精确度） | 检索 | 召回的相关性——前面的对不对 |
| **Context Recall**（上下文召回率） | 检索 | 召回的覆盖度——相关的有没有漏 |
| **Answer Similarity**（答案相似度） | 生成 | 与人工答案的语义相似度 |

```
┌──────────────────────────────────────────────────────┐
│       检索阶段评估                       生成阶段评估   │
│  ┌──────────────────────┐         ┌────────────────┐ │
│  │ Context Precision    │         │ Faithfulness   │ │
│  │ Context Recall       │         │ Answer Rel.    │ │
│  └──────────────────────┘         │ Answer Sim.    │ │
│                                   └────────────────┘ │
└──────────────────────────────────────────────────────┘
```

### 2.2 Faithfulness（最关键）

衡量答案中的每一句话是否能从检索内容中找到依据。

```
答案：苹果公司由乔布斯、沃兹尼亚克和韦恩在 1976 年创立，总部在库比蒂诺。

拆成原子事实：
- 苹果公司由乔布斯、沃兹尼亚克和韦恩创立    ← 在 retrieved 中 ✅
- 创立于 1976 年                          ← 在 retrieved 中 ✅
- 总部在库比蒂诺                           ← 在 retrieved 中 ✅
- ...

Faithfulness = 被支持的事实数 / 总事实数
```

> ⚠️ **生产意义**：低 Faithfulness 直接对应"幻觉"。Faithfulness < 0.85 通常已经有显著用户感知。

### 2.3 用 RAGAS 跑评估

```python
from ragas import evaluate
from ragas.metrics import (
    faithfulness, answer_relevancy,
    context_precision, context_recall, answer_similarity
)
from datasets import Dataset

# 评测集结构
data = {
    "question": ["...", "..."],
    "answer": ["...", "..."],          # RAG 生成的答案
    "contexts": [["...", "..."], [...]],  # RAG 召回的段落
    "ground_truth": ["...", "..."]     # 人工标注的标准答案
}
dataset = Dataset.from_dict(data)

result = evaluate(
    dataset,
    metrics=[faithfulness, answer_relevancy, context_precision, context_recall, answer_similarity]
)
print(result)
# {'faithfulness': 0.91, 'answer_relevancy': 0.89, 'context_precision': 0.83, ...}
```

### 2.4 跑评估的成本

每次跑 200 条评测 × 5 指标 ≈ 1000 次 LLM 调用（评判模型）≈ $5-10。**生产做法**：
- 上线前必跑（PR check）
- 模型 / Prompt 变更必跑
- 周报告（监控漂移）

---

## 三、LLM-as-Judge：能信吗？

### 3.1 原理

让 LLM 扮演"评委"，给生成结果打分。

```python
judge_prompt = """
你是评委。判断以下答案是否准确回答了问题。

问题: {question}
检索内容: {contexts}
答案: {answer}
人工标准: {ground_truth}

打分：
- 5: 完全正确，覆盖标准
- 4: 基本正确，少量偏差
- 3: 部分正确，关键信息有遗漏
- 2: 大部分错误
- 1: 完全错误

输出 JSON: {{"score": 1-5, "reason": "..."}}
"""
```

### 3.2 准确性与陷阱

**LLM-as-Judge 已被多个论文验证可达 80-90% 与人工评分一致率**，但有四个坑：

| 坑 | 现象 | 修复 |
|---|---|---|
| **位置偏置** | 把好答案放第二个，评分偏向第一个 | 随机交换位置或用单条评分而非对比 |
| **冗长偏置** | 长答案被评高分（看起来"努力"） | 评分前先按长度归一化 / Prompt 强调内容质量 |
| **同源偏置** | 用 GPT 评 GPT 自己的答案，给分偏高 | 用不同厂商模型评分（Claude 评 GPT、GPT 评 Claude） |
| **难度无视** | 简单题打 5 分难题打 5 分一样标 | 评测集按难度分层，分别统计 |

### 3.3 校准

**核心原则**：LLM-as-Judge 必须用人工评测校准。

```
1. 人工标注 50 条评测（5 分制）
2. LLM-as-Judge 跑同样 50 条
3. 算一致率（绝对差 ≤ 1 分算一致）
4. 一致率 < 80% → Judge Prompt 不行，重写
   一致率 ≥ 85% → 上线，定期复查
```

### 3.4 LLM-as-Judge vs 人工

| 维度 | LLM-as-Judge | 人工标注 |
|---|---|---|
| 速度 | 200 条 / 10 分钟 | 200 条 / 1-2 天 |
| 成本 | $5-10 | $200-500（外包） |
| 一致性 | 高（同一 Prompt） | 标注员间一致率 70-85% |
| 准确性 | 80-90%（已校准） | 95%+（专家） |
| 覆盖密集 | 高（可天天跑） | 低（季度跑） |

**生产做法**：
- 日常评估用 LLM-as-Judge（成本低 / 频率高）
- 季度全量人工标注（校准 + 兜底）
- 关键变更（模型 / Prompt 升级）人工抽样复核

---

## 四、Agent 评估：比 RAG 难一个量级

### 4.1 评估维度

| 维度 | 含义 | 权重 |
|---|---|---|
| **任务完成度** | 用户原始任务是否完成 | 高 |
| **工具调用正确率** | 每步工具选用是否正确 | 中 |
| **步数效率** | 多少步完成（少 = 好） | 中 |
| **成本** | 单次任务 Token / 美元 | 中 |
| **幻觉率** | 模型编造工具结果或事实 | 高 |
| **死循环率** | 触发 max_iterations 的比例 | 高 |
| **延迟** | 端到端总耗时 | 中 |

### 4.2 评估方法

```python
# 1. 构建评测集（每条含完整任务定义）
test_cases = [
    {
        "input": "把订单 12345 标记为已退款并通知用户",
        "expected_tools": ["query_order", "mark_refunded", "send_email"],
        "success_criteria": {
            "order_status": "refunded",
            "email_sent": True
        }
    },
    ...
]

# 2. 跑 Agent + 收集 trace
for case in test_cases:
    result, trace = agent.run(case["input"])
    
    # 3. 评估各维度
    case["actual_tools"] = trace.tool_calls
    case["task_success"] = check_criteria(result, case["success_criteria"])
    case["iterations"] = trace.iterations
    case["cost"] = trace.total_cost
    case["duration_ms"] = trace.duration_ms
    case["hallucinated"] = check_hallucination(trace)

# 4. 汇总指标
print(f"任务完成率: {sum(c['task_success'] for c in test_cases) / len(test_cases):.1%}")
print(f"平均步数: {mean(c['iterations'] for c in test_cases):.1f}")
print(f"平均成本: ${mean(c['cost'] for c in test_cases):.3f}")
```

### 4.3 工具调用评估的关键

**Tool Choice Accuracy**：模型在每步是否调用了"正确"的工具。

```python
def evaluate_tool_choice(trace, expected_tools):
    actual = [tc.tool_name for tc in trace.tool_calls]
    
    # 严格序列匹配
    exact_match = actual == expected_tools
    
    # 集合匹配（允许顺序不同）
    set_match = set(actual) == set(expected_tools)
    
    # 子集（必须全包含 + 允许多余）
    superset = set(expected_tools) <= set(actual)
    
    return {
        "exact": exact_match,
        "set": set_match,
        "superset": superset,
        "missing": set(expected_tools) - set(actual),
        "extra": set(actual) - set(expected_tools)
    }
```

> ⚠️ **生产经验**：序列严格匹配往往太严格（不同顺序也能完成任务）。集合匹配 + missing 检查是平衡点。

---

## 五、在线监控指标体系

### 5.1 核心指标四象限

```
              业务侧                     技术侧
          ┌──────────┐              ┌──────────┐
   质量   │  幻觉率   │              │  Trace   │
          │ 用户点踩  │              │  错误率  │
          │ 答案长度  │              │ Tool 失败│
          └──────────┘              └──────────┘
          ┌──────────┐              ┌──────────┐
   成本   │  Token   │              │  延迟   │
          │  美元/天  │              │  TTFT   │
   性能   │ Cache 命中│              │  P95 P99│
          └──────────┘              └──────────┘
```

### 5.2 必埋点指标清单

```
gen_ai.system                    -- claude / openai / deepseek
gen_ai.request.model             -- claude-sonnet-4-6
gen_ai.request.temperature       
gen_ai.request.max_tokens        
gen_ai.response.finish_reasons   -- end_turn / tool_use / max_tokens
gen_ai.usage.input_tokens        
gen_ai.usage.output_tokens       
gen_ai.usage.cache_read_input_tokens   -- 缓存命中度量
gen_ai.usage.cache_creation_input_tokens
gen_ai.cost.usd                  -- 计算后的成本
llm.tenant_id                    -- 租户归账
llm.user_id                      -- 用户级监控
llm.session_id                   -- 串联多轮
llm.first_token_ms               -- TTFT
llm.duration_ms                  -- 总耗时
llm.fallback_triggered           -- 是否走了备用模型
llm.cache_layer_hit              -- L1/L2/L3/L4 命中层
llm.tool_calls_count             -- 工具调用步数
llm.error_class                  -- rate_limit / overload / parse_error
```

### 5.3 告警阈值（生产经验）

| 指标 | Warning | Critical |
|---|---|---|
| 接口成功率 | < 99.5% | < 98% |
| TTFT P95 | > 2s | > 5s |
| 总延迟 P95（非流式） | > 10s | > 30s |
| 限流错误（429）持续 | > 5 分钟 | > 15 分钟 |
| Fallback 触发率 | > 5% | > 20% |
| 单租户日成本 | > 上日峰值 1.5x | > 3x |
| Cache 命中率（Anthropic） | < 70% | < 40% |
| Tool Loop 中断率 | > 1% | > 5% |
| 用户点踩率 | > 5% | > 15% |
| 幻觉率（抽样） | > 5% | > 10% |

---

## 六、Trace 工具选型

### 6.1 主流工具对比

| 工具 | 类型 | 优势 | 劣势 |
|---|---|---|---|
| **Langfuse** | 开源 / SaaS | LLM 专用 / UI 优 / 自部署友好 | 比 LangSmith 年轻 |
| **LangSmith** | LangChain SaaS | 与 LangChain / LangGraph 深度 | 收费 / 数据出境 |
| **Phoenix**（Arize） | 开源 | RAG 评估友好 / 嵌入向量可视化 | 综合性弱 |
| **Helicone** | SaaS / 开源 | 网关式（无侵入）/ 简单 | 评估能力弱 |
| **OpenLLMetry** | 库 | OpenTelemetry 标准 | 只是埋点不是平台 |
| **DataDog / Honeycomb** | 通用 APM | 与现有监控融合 | 不专门 LLM |

### 6.2 选型建议

```
┌─────────────────────────────────────────────────┐
│  Q: 数据敏感 / 必须自部署？                       │
│     YES → Langfuse 自部署 / Phoenix              │
│     NO ↓                                         │
│                                                  │
│  Q: 主用 LangChain / LangGraph？                 │
│     YES → LangSmith                              │
│     NO ↓                                         │
│                                                  │
│  Q: 已有 DataDog / Jaeger 等 APM？               │
│     YES → OpenLLMetry + 现有 APM                 │
│     NO  → Langfuse SaaS（最简单）                │
└─────────────────────────────────────────────────┘
```

### 6.3 OpenTelemetry GenAI Convention

OTel 在 2024 年推出了 LLM 应用的语义约定（Semantic Conventions for Generative AI），统一了字段名：

```yaml
# 标准属性
gen_ai.system: anthropic | openai | google.gemini | deepseek
gen_ai.operation.name: chat | embeddings | completion
gen_ai.request.model: claude-sonnet-4-6
gen_ai.request.temperature: 0.3
gen_ai.request.max_tokens: 4096
gen_ai.usage.input_tokens: 8500
gen_ai.usage.output_tokens: 350
gen_ai.response.id: msg_xxx
gen_ai.response.finish_reasons: ["end_turn"]
```

**好处**：用统一规范埋点，可以**自由切换**后端（Langfuse / LangSmith / DataDog 都能解析）。

### 6.4 Java 集成示例

```java
// 用 OpenTelemetry SDK + GenAI 约定
@Component
public class TracingLlmInterceptor {
    private final Tracer tracer = GlobalOpenTelemetry.getTracer("llm-service");
    
    public LlmResponse intercept(LlmRequest req, LlmCall next) {
        Span span = tracer.spanBuilder("gen_ai.chat")
            .setAttribute("gen_ai.system", req.getProvider())
            .setAttribute("gen_ai.request.model", req.getModel())
            .setAttribute("gen_ai.request.temperature", req.getTemperature())
            .setAttribute("gen_ai.request.max_tokens", req.getMaxTokens())
            .setAttribute("llm.tenant_id", req.getTenantId())
            .setAttribute("llm.session_id", req.getSessionId())
            .startSpan();
        
        try (Scope ignore = span.makeCurrent()) {
            LlmResponse resp = next.call(req);
            span.setAttribute("gen_ai.usage.input_tokens", resp.getInputTokens());
            span.setAttribute("gen_ai.usage.output_tokens", resp.getOutputTokens());
            span.setAttribute("gen_ai.usage.cache_read_input_tokens", resp.getCacheReadTokens());
            span.setAttribute("gen_ai.response.finish_reasons", resp.getStopReason());
            span.setAttribute("llm.cost.usd", resp.getCostUsd());
            return resp;
        } catch (Exception e) {
            span.recordException(e);
            span.setAttribute("llm.error_class", classify(e));
            span.setStatus(StatusCode.ERROR);
            throw e;
        } finally {
            span.end();
        }
    }
}
```

---

## 七、生产踩坑

### 坑 1：评测集不变，模型升级看不出退化

**现象**：升级到新版 Claude，离线评估通过，上线后用户反馈"有些场景明显变差"。

**根因**：
- 评测集是 6 个月前建的，**没覆盖新业务场景**
- 用户实际问题分布与评测集分布不一致
- 新模型在评测集场景上略好，但在长尾场景上变差

**修复**：
- **评测集动态扩充**：每月从生产采样 50 条新 case 加入（脱敏后）
- **按场景分层评估**：不只看总体准确率，还看每个细分类目
- **用户点踩反馈直接喂回**：被点踩的 case 加入评测
- **影子流量**：上线前用 5% 流量影子跑新模型，对比生成结果差异

### 坑 2：LLM-as-Judge 给自己打高分

**现象**：用 GPT-5 评 GPT-5 自己的答案，普遍 4.5+，但人工抽样发现实际 3.5-4.0。

**根因**：同源偏置——评判模型对自己生成的内容评分偏高。

**修复**：
- 评判模型用**不同厂商**（Claude 评 GPT、GPT 评 Claude）
- 关键评估用**两个评判模型 + 取平均**
- 季度人工抽样校准（采样 50 条对比 LLM-as-Judge 与人工评分一致率）

### 坑 3：Token 埋点漏了 cache 字段，成本归账偏 60%

**现象**：财务报表显示某租户成本 $5K/月，实际账单 $12K/月。

**根因**：埋点只记 `input_tokens` 和 `output_tokens`，没记 `cache_creation_input_tokens` 和 `cache_read_input_tokens`，Anthropic 的 cache write 是 1.25x 输入价、cache read 是 0.1x，**没体现在内部归账里**。

**修复**：
- 全量补埋点：`cache_read_input_tokens` / `cache_creation_input_tokens` / `cost.usd`（按各 token 类别计算）
- 历史数据从厂商账单拉回回填
- 定期对账：内部成本 vs 厂商账单偏差 < 2%

### 坑 4：告警阈值定太松，事故 30 分钟没人发

**现象**：周末 LLM 调用错误率从 0.5% 飙到 8%，告警 30 分钟才触发，影响 200 用户。

**根因**：
- 告警阈值"错误率 > 10% 持续 5 分钟"——对单点突发不敏感
- 没有"突变检测"（与昨日同时段对比）

**修复**：
- 加多级告警：
  - Warning：错误率 > 1% 持续 3 分钟
  - Critical：错误率 > 5% 持续 1 分钟 / 单点 > 20%
  - 突变检测：当前值 > 7 日同时段 P95 × 2
- 周末 / 节假日加 PagerDuty 升级
- 关键告警必须 5 分钟内响应（值班 SLA）

### 坑 5：评估只看 Faithfulness，忽略了 Answer Relevancy

**现象**：Faithfulness 92%（不编造），但用户体验差。

**根因**：
- 模型很"严谨"——只说检索内容里有的话
- 但答案没切题——用户问 A 它答了 B（B 也在检索内容里）
- Faithfulness 高不等于回答好

**修复**：
- 评估必须**多指标综合**：Faithfulness + Answer Relevancy + Context Precision
- 设阈值：任一 < 0.85 都触发回归 / 调优
- 真实业务指标（用户满意度 / 复购率）作为最终金标

### 坑 6：Trace 数据量爆炸，存储一个月烧 5 万

**现象**：上线 Langfuse 后，存储数据三个月就 10TB+。

**根因**：
- 把每次 LLM 调用的完整 Prompt + Output 全存（多者几十 KB）
- 没采样 / 没 TTL
- 评估场景的 trace 也全量存

**修复**：
- **采样**：成功请求 1% 抽样存全量 Prompt，失败请求 100% 存
- **TTL**：详细 trace 30 天，聚合指标 90 天
- **分层存储**：热数据 ES（30 天），冷数据 S3（1 年）
- **压缩**：长 Prompt 走 gzip
- 评估专用 environment 与生产分库

---

## 八、面试高频追问

**Q1：RAG 怎么评估？为什么人工标注不可少？**

RAGAS 五大指标：① Faithfulness（不编造）② Answer Relevancy（切题）③ Context Precision（召回相关性）④ Context Recall（召回覆盖度）⑤ Answer Similarity（与人工答案相似度）。前两个评生成、后两个评检索、最后一个综合。**人工标注不可少的原因**：① LLM-as-Judge 与人工一致率 80-90%，剩下 10-20% 偏差需要校准；② 业务边界 case / 长尾场景 LLM 评判不准；③ 季度全量人工标注作为最终金标。生产做法：日常 LLM-as-Judge 高频跑，季度人工抽样校准。

**Q2：LLM-as-Judge 可信吗？怎么校准？**

可信但要校准。论文表明 LLM-as-Judge 与人工评分一致率达 80-90%。**四个坑**：① 位置偏置（对比时偏向第一个）；② 冗长偏置（长答案偏高）；③ 同源偏置（GPT 评 GPT 偏高）；④ 难度无视。**校准流程**：人工标 50 条 → LLM-as-Judge 跑同样 50 条 → 算一致率（绝对差 ≤ 1 分算一致）→ < 80% 重写 Judge Prompt，≥ 85% 上线。**关键技巧**：评判模型用不同厂商（Claude 评 GPT、GPT 评 Claude）。

**Q3：Faithfulness 是什么？怎么算？**

衡量答案中每一句话是否能从检索内容中找到依据。**算法**：① LLM 把答案拆成 N 个原子事实（"X 是 Y"、"A 在 B 时间发生"）；② 对每个事实，让 LLM 判断 retrieved contexts 是否支持；③ Faithfulness = 被支持的事实数 / 总事实数。**生产意义**：低 Faithfulness 直接对应"幻觉"——< 0.85 已有显著用户感知。

**Q4：Agent 评估比 RAG 难在哪？**

Agent 多了"过程评估"。**多维度**：① 任务完成度（最终结果对不对）；② 工具调用正确率（每步选对工具吗）；③ 步数效率（5 步完成的别花 15 步）；④ 成本（Token / $）；⑤ 幻觉率；⑥ 死循环率；⑦ 延迟。**实现**：用结构化评测集（每条含 `expected_tools` + `success_criteria`），跑 Agent 收集 trace，分别评估各维度。**Tool Choice 评估推荐集合匹配 + missing 检查**，序列严格匹配往往太严格。

**Q5：在线监控应该埋哪些点？**

按 OpenTelemetry GenAI Convention 标准化埋点。必埋：`gen_ai.system / gen_ai.request.model / gen_ai.usage.input_tokens / gen_ai.usage.output_tokens / gen_ai.usage.cache_read_input_tokens / gen_ai.usage.cache_creation_input_tokens / gen_ai.response.finish_reasons / cost.usd / tenant_id / session_id / first_token_ms / duration_ms / fallback_triggered / tool_calls_count / error_class`。**分四象限**：业务质量 + 业务成本 + 技术延迟 + 技术错误。

**Q6：Trace 工具怎么选？Langfuse / LangSmith / DataDog？**

数据敏感 / 自部署用 **Langfuse 自部署 / Phoenix**；主用 LangChain 生态用 **LangSmith**（深度集成）；已有 DataDog / Jaeger 用 **OpenLLMetry + 现有 APM**；最简单上手用 **Langfuse SaaS**。**关键**：用 OpenTelemetry GenAI Convention 标准化埋点，可以自由切换后端，避免锁定。

**Q7：告警阈值怎么定？**

接口成功率 < 99.5% Warning / < 98% Critical；TTFT P95 > 2s W / > 5s C；限流持续 > 5 分钟 W / > 15 分钟 C；Fallback 触发率 > 5% / > 20%；**单租户日成本 > 上日峰值 1.5x / 3x**（突变检测）；Cache 命中率 < 70% / < 40%；Tool Loop 中断率 > 1% / > 5%；**用户点踩率 > 5% / > 15%**（业务质量金标）。生产经验：单点突变（vs 7 日同时段 P95 × 2）比"持续 X 分钟阈值"更早发现事故。

**Q8：评测集应该多大？多久更新一次？**

**最少 100 条，推荐 200-500 条**。少于 100 条统计上不显著；超过 500 条收益递减且 LLM-as-Judge 成本飙升。**结构**：按场景分层（每场景 30-50 条）+ 涵盖典型 case + 边界 case + 历史 bug case。**更新**：每月从生产采样 50 条新 case 加入（脱敏）；用户点踩 case 直接加入；模型版本变更时全量回归 + 评测集快照保留。

**Q9：影子流量是什么？怎么做？**

新模型 / Prompt 上线前，**用一小部分生产流量（如 5%）镜像跑新版本，但不返回给用户**——只对比新旧两版的输出差异。优点：① 在真实流量下评估而不是固定测集；② 不影响用户体验（不返回新版本）；③ 能发现长尾问题。**实现**：在 LLM Gateway 加镜像逻辑——主请求走旧版本返回用户，5% 同步异步触发新版本，结果落库对比。

**Q10：你们 LLM 应用上线后最严重的事故是什么？怎么发现的？**

经典回答："**Embedding 模型升级后召回率从 80% 跌到 40%**——用户大量点踩反馈触发监控，Faithfulness 没跌（模型仍诚实），但 Answer Relevancy 大跌（召回都不相关，模型只能答"不知道"）。修复路径：① 立即回滚 Embedding 版本；② 离线评测对比新旧 Embedding；③ 全量 reindex 后再切；④ 上线向量空间漂移监控。**教训**：Embedding 变更必须做双写双查灰度，不能直接切。"

---

## 九、答题模板（60 秒）

> "LLM 评估分**离线 + 在线**两层。"
>
> "**离线评估**：RAGAS 五指标（Faithfulness 不编造 / Answer Relevancy 切题 / Context Precision&Recall 召回质量 / Answer Similarity 综合）+ Agent 加任务完成度 / 工具调用准确率 / 步数效率 / 成本。**LLM-as-Judge 与人工 80-90% 一致**，必须用不同厂商模型 + 季度人工校准。"
>
> "**在线监控**：按 OpenTelemetry GenAI Convention 埋 input_tokens / output_tokens / cache_read / cost / TTFT / fallback / tool_calls。**告警阈值**：成功率 99.5%、TTFT P95 < 2s、单租户成本突变 > 1.5x、用户点踩率 < 5%。"
>
> "**Trace 工具**：自部署 Langfuse / LangChain 系 LangSmith / 已有 APM 用 OpenLLMetry + DataDog。"
>
> "**生产经验**：评测集动态更新（每月加新 case）、Embedding 升级必须双写双查、cost 埋点必须含 cache 字段否则归账偏 60%、突变检测比固定阈值更早发现事故。"

---

## 十、相关文档

- [RAG 检索增强生成](RAG检索增强生成.md) — RAGAS 在 RAG 场景的应用
- [Agent 架构模式](Agent架构模式.md) — Agent 评估的指标定义
- [LLM 应用工程化](LLM应用工程化.md) — Trace 与监控埋点
- [Prompt Engineering](PromptEngineering.md) — Prompt 注入测试集
- [Function Calling 与 Tool Use](FunctionCalling与ToolUse.md) — Tool Choice Accuracy 评估
- [Microservice/链路追踪](../Microservice/链路追踪.md) — 通用 APM 与 Trace 基础
- [RAG 与 Agent 生产踩坑](RAG与Agent生产踩坑.md) — 真实事故的监控发现路径
