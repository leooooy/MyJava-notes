# LLM 基础与面试视角

> 引子：这一篇不是给你讲 Transformer 怎么做 self-attention，而是回答 **后端工程师面试时最容易被问翻车的 LLM 基础题**：
>
> ① **Token 怎么算的、API 调用一次多少钱**——你不会算，面试官会怀疑你没真的把 LLM 接进过生产。
> ② **上下文窗口越大越好吗**——回答"是"就被追问"那为什么 Claude 默认 200K 不开 1M"。
> ③ **temperature / top_p / seed 这些推理参数到底什么场景该调成什么值**——这是区分"调过 API"和"看过文档"的分水岭。
> ④ **流式输出在后端怎么实现、Token 怎么计费、断线了怎么处理**——纯后端工程问题，但跟 LLM 的请求模型紧绑。
>
> 看完这篇，前 5 个 LLM 基础高频题都能 60 秒答清楚。

---

## 一、Token：LLM 世界的"汉字"

### 1.1 为什么要分 Token，不直接喂字符

LLM 的输入不是"字符"，也不是"单词"，而是 **Token**。原因有三：

1. **算力限制**：自注意力机制的计算复杂度是 `O(n²)`，n 是序列长度。如果按字符切，"hello world" 变成 11 个单元；按 Token（BPE）切，变成 2 个。算力差 30 倍。
2. **OOV 问题（Out-of-Vocabulary）**：按完整单词切，遇到生僻词、组合词、错别字、新造词、emoji，词表立刻爆炸。BPE / WordPiece 这类子词分词器，能用有限词表（典型 5 万 ~ 20 万）覆盖任意输入。
3. **多语言统一**：同一个分词器要兼容英文 / 中文 / 代码 / 公式 / emoji。BPE 训练时只看字节频率，不需要人为分词规则。

> 主流分词器都是 **BPE 变种**：GPT 系列用 `tiktoken`（cl100k_base / o200k_base）、Claude 用自家闭源分词器（接近 cl100k）、Llama / DeepSeek / Qwen 都是开源 BPE。

### 1.2 Token 与字符的换算关系（必背）

| 内容 | 1 Token ≈ | 实际原因 |
|---|---|---|
| 英文 | **4 字符 / 0.75 单词** | 常见单词 1 Token，长 / 罕见单词被切成 2-4 个 subword |
| 中文 | **1.5 ~ 2 个汉字** | 常用汉字 1 Token，生僻字、繁体、组合词 2-3 Token |
| 代码 | **3 字符** | 关键字 / 标识符成 Token，但缩进、符号会被拆 |
| JSON | **3 ~ 4 字符** | 结构性字符（`{`, `:`, `"`）单独 Token，较费 |

**面试现场速算**：

- "你们一次调用消耗多少 Token？"
  - 5000 字中文文档 ≈ **5000 × 1.7 ≈ 8500 Token**
  - 1000 单词英文文档 ≈ **1000 / 0.75 ≈ 1333 Token**
  - 一段 100 行 Java 代码 ≈ **3000 ~ 5000 Token**

```bash
# 本地能跑的精确计算（OpenAI 系列）
pip install tiktoken
python -c "import tiktoken; enc = tiktoken.get_encoding('cl100k_base'); print(len(enc.encode('你的文本')))"
```

### 1.3 Token 不只影响成本，还影响"能不能放进去"

每个模型有 **上下文窗口（Context Window）**，单位是 Token。

| 模型 | 上下文窗口 |
|---|---|
| GPT-3.5 | 16K（早期 4K） |
| GPT-4o | 128K |
| GPT-5 | 400K |
| Claude 3.5 Sonnet | 200K |
| Claude Opus 4.7 / Sonnet 4.6 | **1M（百万级）** |
| Gemini 2.5 Pro | **2M** |
| DeepSeek V3 | 128K |
| Qwen 3 Max | 256K |

> ⚠️ **窗口包含 Input + Output + System Prompt + 历史消息 + Tool 定义**。如果你 System Prompt 写了 50K，加上 RAG 召回的 30K 上下文 + 历史 5 轮对话 20K，已经吃掉 100K，给模型生成留的空间只剩 28K（GPT-4o）。**这就是上下文超限的根因。**

---

## 二、上下文窗口：越大越好吗？（面试坑题）

### 2.1 大窗口的真实代价

| 维度 | 影响 |
|---|---|
| **价格** | 同一个模型，1M context 调用通常价格不变，但你**塞进去的越多 Input Token 越多，账单越爆** |
| **延迟** | 1M Token 的首 Token 延迟（TTFT）从 1-2 秒拉到 **30-60 秒**，用户体感卡死 |
| **质量** | "Lost in the Middle" 效应：放在中段的关键信息**召回率明显下降**，模型偏向开头和结尾 |
| **缓存** | 长 Prompt 不命中 Cache 时，全量重新计算 KV，单次几美元跑掉 |

### 2.2 长上下文 vs RAG 的取舍

```
┌─────────────────────────────────────────────────────────────┐
│  问题：100 万字的公司文档要查询，怎么搞？                    │
├─────────────────────────────────────────────────────────────┤
│  方案 A：1M Context 全塞进去                                 │
│    ✅ 不用搭检索系统                                          │
│    ❌ 每次调用 ≈ $20+，延迟 60 秒                            │
│    ❌ "Lost in the Middle"，关键段落召不回                   │
│    ❌ 文档更新一次，Cache 全部失效                            │
├─────────────────────────────────────────────────────────────┤
│  方案 B：RAG（向量检索 → 召回 Top-5 → 拼 Prompt）            │
│    ✅ 单次调用 ≈ $0.05，延迟 < 2 秒                          │
│    ✅ 文档更新只需 reindex 单篇                               │
│    ❌ 召回率受 Embedding 质量影响                            │
│    ❌ 跨段落语义被切断                                        │
├─────────────────────────────────────────────────────────────┤
│  方案 C：长上下文 + 检索（混合）                              │
│    召回 Top-20 段（共 ~50K Token）→ 给 1M 模型 → 模型自筛   │
│    适合"既要召回率又要全局推理"的复杂场景                     │
└─────────────────────────────────────────────────────────────┘
```

> **答题模板**：长上下文不能替代 RAG。生产场景下，**长上下文负责"理解长文档的全局语义"，RAG 负责"从海量文档中找到相关段落"**，两者互补不互替。

---

## 三、推理参数：temperature / top_p / seed

### 3.1 temperature：控制随机性的"温度"

LLM 输出每个 Token 时，对词表中所有 Token 计算一个概率分布。temperature 通过 softmax 函数调节这个分布的"平坦度"：

```
softmax(logits / T)
```

| temperature | 效果 | 场景 |
|---|---|---|
| **0.0** | 完全确定（贪心解码） | 代码生成 / 函数调用 / 结构化输出 / 数学题 |
| **0.3** | 弱随机 | RAG 问答 / 客服回复（要稳） |
| **0.7** | 中等随机（多数模型默认） | 通用对话 |
| **1.0+** | 高随机 / 创意 | 故事创作 / 头脑风暴 |
| **2.0** | 几乎采样均匀分布 | 不要这么干，输出会乱套 |

> ⚠️ **生产坑**：很多人以为 `temperature=0` 就 100% 确定输出。**错。** 模型内部的浮点计算、batch 调度、并发会让结果**不完全 deterministic**。要真正复现，必须配 `seed` 参数（OpenAI 支持）。

### 3.2 top_p（nucleus sampling）：另一种采样策略

top_p 不是改概率分布，而是**截断**。比如 top_p=0.9 意思是：从概率最高的 Token 开始累加，累加到 90% 就停，只在这个集合里随机采样。

```
[0.5, 0.3, 0.1, 0.05, 0.03, 0.02]   ← 词表概率（排序后）
   ↑    ↑    ↑
   累加 0.9，只在前 3 个里采样
```

| 维度 | temperature | top_p |
|---|---|---|
| 控制方式 | 缩放概率 | 截断长尾 |
| 典型值 | 0 ~ 1.5 | 0.7 ~ 1.0 |
| **是否同时调** | **不要！** OpenAI / Anthropic 官方都建议**只调一个** |

**生产推荐**：调 `temperature` 即可，`top_p` 默认 1.0 不动。除非你做创意写作要"既保多样又抑制怪 Token"。

### 3.3 seed：可复现性的救命稻草

| 参数 | OpenAI | Claude |
|---|---|---|
| `seed` | ✅ 支持（beta） | ❌ 不支持 |
| `system_fingerprint` | ✅ 返回 | — |

**用法**：调试 / 评估 / A/B 测试，传相同 `seed` + `temperature=0`，**多数情况下**输出一致。注意 OpenAI 文档自己说"best-effort determinism"——升级模型版本（`system_fingerprint` 变化）会重新洗牌。

```python
# OpenAI 复现性调用
client.chat.completions.create(
    model="gpt-5",
    messages=[...],
    temperature=0,
    seed=42,                    # 固定种子
    top_p=1.0,                  # 不动
)
# 检查 response.system_fingerprint，变了就要重跑评估
```

---

## 四、流式 vs 非流式：后端的实质差异

### 4.1 协议层差异

| 模式 | HTTP 行为 | 客户端体感 |
|---|---|---|
| **非流式** | 模型生成完才返回完整 JSON | 卡 30 秒 → 一下子全出来 |
| **流式（SSE）** | `Content-Type: text/event-stream`，每个 Token 一个 `data:` 帧 | 200ms 内开始打字 |

```
# 流式响应原始报文（OpenAI / Anthropic 都用 SSE）
data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"你"}}

data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"好"}}

data: {"type":"message_stop"}
```

### 4.2 关键指标：TTFT vs TPOT

| 指标 | 含义 | 用户体感 |
|---|---|---|
| **TTFT**（Time To First Token） | 首 Token 到达时间 | "卡不卡"的关键 |
| **TPOT**（Time Per Output Token） | 每个后续 Token 的间隔 | 打字速度 |
| **总延迟** | TTFT + TPOT × 输出长度 | 总耗时 |

**生产经验值**：
- TTFT 200ms ~ 1s 体感流畅
- TTFT > 2s 用户开始焦虑
- TTFT > 5s 用户开始重试 / 关页面

### 4.3 流式后端实现（Java 后端必考）

```java
// Spring MVC：SseEmitter 方案
@GetMapping(value = "/chat", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
public SseEmitter chat(@RequestParam String prompt) {
    SseEmitter emitter = new SseEmitter(60_000L);  // 60s 超时
    executor.submit(() -> {
        try {
            llmClient.streamChat(prompt, chunk -> {
                emitter.send(SseEmitter.event().data(chunk));
            });
            emitter.complete();
        } catch (Exception e) {
            emitter.completeWithError(e);  // 别忘了 error 也要通知前端
        }
    });
    return emitter;
}

// WebFlux 方案（更适合高并发）
@GetMapping(value = "/chat", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
public Flux<String> chat(@RequestParam String prompt) {
    return llmClient.streamChat(prompt)
                    .timeout(Duration.ofSeconds(60))
                    .onErrorResume(e -> Flux.just("[error] " + e.getMessage()));
}
```

> **方案选择**：
> - 流量小、简单接入：`SseEmitter`
> - QPS 高、需要背压：`WebFlux + Reactor`
> - 反向代理（Nginx / 网关）：**必须关 buffer**，否则前端要 30 秒才看到内容
>   ```nginx
>   proxy_buffering off;
>   proxy_cache off;
>   chunked_transfer_encoding on;
>   ```

### 4.4 流式中断的 Token 计费坑

**现象**：用户中途关页面，连接断开，但模型已经生成了一半。这一半 Token 还要扣钱吗？

**OpenAI / Anthropic 的实际行为**：
- 模型已经生成的 Token **照样计费**（按 SSE 已发送的内容）
- 但有个坑：**如果你不立即中断模型推理（cancel）**，模型会继续跑到 `max_tokens` 或 `stop` 才收费截止
- **Anthropic 提供 `stop_reason` 字段，断开后还能拿到完整账单元数据**

**修复方案**：
```java
// 客户端断线 → 立即调用 cancellation
emitter.onTimeout(() -> {
    streamingCall.cancel();  // 通知模型停止生成，免得继续烧 Token
    log.warn("Stream timeout, tokensUsed={}", currentTokenCount);
});
emitter.onCompletion(() -> log.info("Stream complete, tokensUsed={}", currentTokenCount));
```

---

## 五、主流模型对比与选型（2026 年初）

### 5.1 速查矩阵

| 模型 | 上下文 | 输入价 | 输出价 | 强项 | 弱项 |
|---|---|---|---|---|---|
| **Claude Opus 4.7** | 1M | $15 | $75 | 复杂推理 / Agent / 编码 | 贵 / 速度慢 |
| **Claude Sonnet 4.6** | 1M | $3 | $15 | 性价比标杆 / Tool Use 稳定 | 中文略弱于 Qwen |
| **Claude Haiku 4.5** | 200K | $1 | $5 | 高吞吐 / 简单分类 | 复杂任务掉链子 |
| **GPT-5** | 400K | $5 | $15 | Function Calling 生态 / 多模态 | 中文不如国产 |
| **GPT-4o** | 128K | $2.5 | $10 | 老牌 / 工具调用稳 | 已落后于 GPT-5 |
| **Gemini 2.5 Pro** | 2M | $1.25 | $5 | 超长文本 / 视频 / 性价比 | API 稳定性次 |
| **DeepSeek V3** | 128K | $0.27 | $1.10 | **价格屠夫** / 中文强 | 不在境外稳定 |
| **DeepSeek R1** | 128K | $0.55 | $2.19 | 推理 / CoT / 数学 | Tool Use 稳定性弱 |
| **Qwen 3 Max** | 256K | ¥0.6 | ¥2.4 | 阿里云原生 / 国内合规 | 海外延迟高 |

### 5.2 选型决策树

```
                 ┌────────────────────────────┐
                 │   是否境内合规要求强？      │
                 └────────────┬───────────────┘
                              │
                  ┌───────────┴────────────┐
                YES                       NO
                  │                        │
        ┌─────────┴─────────┐    ┌─────────┴──────────┐
        │ Qwen / DeepSeek   │    │   预算紧张吗？      │
        │  + 阿里云 / 火山   │    └─────────┬──────────┘
        └───────────────────┘              │
                              ┌───────────┴────────────┐
                            YES                       NO
                              │                        │
                  ┌───────────┴───┐    ┌──────────────┴────────┐
                  │ DeepSeek V3   │    │  任务类型？             │
                  │ Gemini 2.5    │    └──────────────┬────────┘
                  │ Claude Haiku  │                   │
                  └───────────────┘     ┌─────────────┼─────────────┐
                                       推理            Agent           通用
                                        │              │              │
                                  Claude Opus    Claude Sonnet     GPT-5
                                  / DeepSeek R1   / GPT-5          / Gemini
```

### 5.3 一次调用成本估算（必背模板）

**场景**：客服 Agent，单次对话平均 5 轮，每轮：
- System Prompt：5K Token（缓存命中）
- 用户输入：100 Token
- RAG 召回：3K Token
- 模型输出：500 Token
- Tool 调用 1 次（200 Token）

**单次对话成本（Claude Sonnet 4.6，无缓存）**：

```
Input：(5000 + 100 + 3000 + 200) × 5 轮 = 41,500 Token × $3/M = $0.125
Output：500 × 5 轮 = 2,500 Token × $15/M = $0.0375
合计 ≈ $0.16 / 对话
```

**启用 Anthropic Prompt Cache（命中 90%）**：

```
首轮 Input：8300 × $3/M = $0.025
后续 Input：(100 + 3000 + 200 + 8300_cached × 0.1) × 4 = 16,520 × $3/M ≈ $0.05
Output 不变：$0.0375
合计 ≈ $0.11 / 对话（省 30%）
```

**月度估算**：日均 10 万次对话 × $0.11 × 30 天 ≈ **$33,000 / 月**。

> **生产建议**：所有 LLM 调用都要带 `userId / tenantId` 埋点，**每条请求**记录 `input_tokens / output_tokens / cache_hit_tokens / cost`。**没埋点的项目=没法治理成本的项目**。

---

## 六、配置与最佳实践

### 6.1 三档配置模板

```yaml
# 开发环境：能跑就行
llm:
  model: claude-haiku-4-5      # 便宜
  temperature: 0.7
  max_tokens: 2048
  timeout: 60s
  retry: 1

# 生产环境（互联网通用）
llm:
  model: claude-sonnet-4-6
  temperature: 0.3              # 降低随机性
  max_tokens: 4096
  timeout: 30s                  # 非流式 30s，流式 60s
  retry: 2
  retry_backoff: exponential
  fallback_model: deepseek-v3   # 主备切换
  enable_prompt_cache: true     # Anthropic Prompt Cache
  enable_streaming: true        # 用户场景默认开

# 金融 / 高一致性场景
llm:
  model: claude-opus-4-7
  temperature: 0                # 确定性
  seed: 42                      # 复现（OpenAI 才支持）
  max_tokens: 2048
  timeout: 30s
  retry: 0                      # 不重试，避免幻觉漂移
  audit_log: full               # 全量请求审计
  output_validator: json_schema # 强结构校验
```

### 6.2 错误码处理矩阵

| 错误码 | 含义 | 处理 |
|---|---|---|
| `429 rate_limit_error` | TPM/RPM 超限 | 指数退避重试 + 切 Fallback Key |
| `529 overloaded_error` | 厂商过载 | 立即切 Fallback 模型 |
| `400 invalid_request` | Prompt 格式 / 长度问题 | **不重试**，返回用户错误 |
| `401 unauthorized` | API Key 失效 | 告警 + 切备用 Key |
| `500 server_error` | 厂商内部错 | 退避重试 1 次 |
| `连接超时` | 网络问题 | 退避重试 2 次 + 切 Fallback |

---

## 七、生产踩坑

### 坑 1：Token 估算错了，月底账单爆 10 倍

**现象**：原计划月预算 $5,000，结果烧到 $50,000。

**根因**：
1. RAG 召回 Top-K=10，每段 1000 Token，**单次输入直接干到 10K**，没有截断。
2. 调试日志把每次完整 Prompt 打印到 ELK，还**额外发了一份给 LLM-as-Judge 评估**——等于每条 Prompt 算了两次钱。
3. 没启 Prompt Cache，每次都全量发。

**修复**：
- Top-K 降到 5，加 Rerank 取 Top-3
- 评估改成抽样 1%，不是 100%
- System Prompt + 文档检索结果 全部 `cache_control` 标 `ephemeral`
- 加每用户 / 每租户 daily Token 上限（超限直接返回限额提示）

**监控指标**：
```
metric: llm_tokens_total{tenant, model, type=input|output|cache}
metric: llm_cost_usd{tenant, model}
alert: 单租户 1 小时 Token 使用 > 上日峰值 3x
```

### 坑 2：seed=42 + temperature=0 仍然不可复现

**现象**：评估集每次跑出来准确率波动 5%。

**根因**：
- OpenAI seed 是 best-effort，**模型版本（system_fingerprint）变化**会洗牌
- 后台 batch 调度对相同请求并发处理，浮点累加顺序不同会导致末尾 Token 不一样
- Claude **根本不支持 seed**，他们文档明说"内部不保证"

**修复**：
- 评估时**每次只用一个固定 system_fingerprint**，发现变化就重跑全集
- 报告"准确率 ± 标准差"，不是单点值
- Claude 评估改成跑 3 次取多数（majority voting）

### 坑 3：流式 Nginx 反代缓冲，前端 60 秒后才看到响应

**现象**：本地测试流式秒级响应，上线 Nginx 后变成"等很久突然全出来"。

**根因**：Nginx 默认 `proxy_buffering on`，把整个响应缓存完才转发给客户端。

**修复**：
```nginx
location /api/chat {
    proxy_pass http://llm-service;
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_cache off;
    proxy_set_header Connection '';
    chunked_transfer_encoding on;
    proxy_read_timeout 120s;     # SSE 长连接
}
```

**监控**：在网关层埋 `first_byte_latency`，> 2s 即告警。

### 坑 4：上下文塞太满，模型"中间遗忘"

**现象**：把 200K 文档全塞进 Claude 1M 模型，问"第 80 页讲了什么"，模型胡说八道。

**根因**：Lost in the Middle。模型对 prompt 中段的注意力**显著低于**首尾。NIAH（Needle in a Haystack）评测的"曲线低谷"区。

**修复**：
- 关键信息**放首尾**（System Prompt 开头 + User 最后强调）
- 长文档先 RAG 切到 Top-5，再交模型综合
- 在 Prompt 末尾加 `请基于上面的全部文档回答，不要遗漏中段内容`（口令式提醒能回收 5-10% 准确率）

---

## 八、面试高频追问

**Q1：1M 上下文窗口意味着什么？为什么不直接全文喂？**

意味着模型一次最多能"看到" 100 万 Token（≈ 70 万汉字 / 3000 页文档）。但实际不全文喂，因为 ① 价格——1M 输入 Token 一次 $3-15；② 延迟——TTFT 30-60 秒；③ Lost in the Middle 导致中段召回率下降；④ Cache 不命中时全量重算。生产做法是 **RAG 召回 Top-K → 拼到 50K-100K 给模型综合**，不是上来就 1M。

**Q2：Token 怎么算？一条中文消息有多少？**

中文 1 字 ≈ 1.5-2 Token，英文 1 单词 ≈ 1.3 Token，代码 3 字符 ≈ 1 Token。10 个汉字 ≈ 17 Token。可以用 OpenAI 的 `tiktoken` 库本地精确算（cl100k_base / o200k_base 编码），Claude 因为分词器闭源只能调 API 拿 `usage` 反推。**生产建议每个请求都记录 `input_tokens / output_tokens` 埋点**，自己估算的偏差可能 20%+。

**Q3：temperature=0 一定能复现吗？**

不一定。即使 temperature=0、seed 固定，后台 batch 调度和浮点并发会让结果**最后几个 Token** 略有差异。OpenAI 提供 `system_fingerprint` 用来检测模型权重变化，变了就要重跑评估。**Claude 不支持 seed**，要复现只能跑多次取多数。

**Q4：temperature 和 top_p 区别？同时调会怎样？**

temperature 是缩放整个概率分布（softmax），top_p 是截断尾部低概率 Token。**官方建议只调一个**。同时调会让"哪些 Token 候选"和"候选间概率"双重变化，调试困难。生产推荐：temperature 控制随机度，top_p 默认 1.0 不动。

**Q5：流式输出的 SSE 和 WebSocket 怎么选？**

SSE 是单向（服务端 → 客户端），HTTP 协议，浏览器原生 EventSource 支持，断线自动重连。LLM 流式天然单向（模型只往外吐字），所以**SSE 是首选**。WebSocket 双向但更复杂，反代要专门配置（Nginx 的 `Upgrade` 头），用在需要客户端中途打断或追问的场景（很少）。

**Q6：流式中断断线怎么办？Token 怎么扣？**

客户端断开后，**模型已生成的 Token 照算钱**（按 SSE 已发送的截断点）。后端务必：① 监听 SseEmitter / Flux 的 onTimeout / cancel 事件，立即调用底层 LLM 客户端的 `cancel()`（OpenAI 是 `AbortController.abort()`，Anthropic 是关闭 stream），免得模型继续往 `max_tokens` 跑；② 持久化 stream-id + 已生成内容，前端恢复连接时可以接着拿，不要重新调用 LLM。

**Q7：长上下文模型为什么会 Lost in the Middle？**

不是 bug，是 Transformer 自注意力在长序列下**位置编码权重失衡**导致的——首尾位置由于训练数据分布天然被强化，中段相对弱。Anthropic / Google / Meta 都有论文证实。修复：关键信息前置/后置 + 分段查询 + RAG 选 Top-K 而不是塞全文。

**Q8：Anthropic Prompt Cache 是怎么工作的？什么时候不命中？**

把 Prompt 中**前缀完全相同**的部分（System Prompt + 工具定义 + 示例）标记 `cache_control: ephemeral`。下次请求**前缀未变**就直接复用 KV Cache，不重算。命中条件：① 前缀字节级别完全一致（多空格 / 时间戳都会破坏）；② 模型版本不变；③ 5 分钟内（默认 TTL）。**不命中场景**：多租户拼了用户名进 System、Prompt 注入了当前时间、A/B 测试切换 Prompt 版本。

**Q9：DeepSeek 比 Claude 便宜 50 倍，为什么大厂还用 Claude？**

价格不是唯一维度。Claude 在以下场景仍领先：① **复杂推理 / 长链 Agent** 不掉链子；② **Tool Use 稳定性**（连续 10+ 步工具调用错误率低）；③ **长上下文质量**（200K-1M 实际可用，不是参数虚标）；④ **企业合规 / SOC2 / HIPAA**。DeepSeek 适合中文场景 / 高吞吐 / 成本敏感，但 Agent 场景的稳定性还需要测——很多生产团队是**主力用 DeepSeek，复杂任务降级到 Claude**。

**Q10：模型输出为什么有时是英文有时是中文？**

System Prompt 没明确语言要求 + 用户输入英文 + 检索文档英文，模型默认跟着环境走。修复：① System Prompt 加 `Always respond in Chinese (Simplified)`；② 用户输入做语言检测，不一致时改写；③ 输出层加语言校验，识别到非中文 retry 一次。

---

## 九、答题模板（60 秒）

> "LLM 基础在面试里就三件事：**Token、上下文、推理参数**。"
>
> "Token 是 BPE 分词的最小单元，**英文 1 Token ≈ 4 字符，中文 ≈ 1.5-2 字**。所有 API 计费按 Input / Output Token 算，生产**必须埋点 token + cost**，否则成本失控。"
>
> "上下文窗口现在主流 128K-1M，**但不是越大越好**——价格、延迟、Lost in the Middle 都是代价。生产选型一般是 **Claude / GPT 系负责复杂推理，DeepSeek / Qwen 负责高吞吐**，加 Prompt Cache 把成本砍 30-70%。"
>
> "推理参数生产用 **temperature=0.3 或 0**（确定性场景）+ **top_p=1.0 不动**，要复现得用 seed（仅 OpenAI），但是 best-effort，模型版本变就要重跑评估。"
>
> "流式后端用 **SSE** 实现，Spring 里 SseEmitter 或 WebFlux，**断线必须 cancel 上游**，否则继续烧 Token。**Nginx 反代必须关 buffering**，不然流式假流式。"

---

## 十、相关文档

- [Prompt Engineering](PromptEngineering.md) — System / User Prompt 与防注入
- [Function Calling 与 Tool Use](FunctionCalling与ToolUse.md) — 工具调用底层协议
- [LLM 应用工程化](LLM应用工程化.md) — Prompt Cache / 限流 / Fallback
- [上下文与记忆管理](上下文与记忆管理.md) — 滑动窗口与 Summary Buffer
- [RAG 检索增强生成](RAG检索增强生成.md) — 长上下文的替代方案
- [Network/HTTP 协议](../Network/HTTP协议.md) — SSE 协议细节
- [Network/WebSocket](../Network/WebSocket.md) — 双向流式补充阅读
