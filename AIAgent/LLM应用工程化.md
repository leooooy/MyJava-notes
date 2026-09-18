# LLM 应用工程化

> 引子：把 LLM 接进 demo 不难，**接进生产难**。这一篇是面试官最爱拷打 Java 后端工程师的角度——"你们怎么扛住流量、控制成本、保证稳定？"
>
> ① **流式 SSE** 后端实现（Spring MVC vs WebFlux）+ 反向代理坑 + 中断断线 Token 计费。
> ② **限流**：TPM / RPM 是什么？多租户怎么分？打穿后怎么办？
> ③ **缓存**：Anthropic Prompt Cache 之外，**语义缓存**怎么做？阈值定多少？错命中怎么防？
> ④ **降级与 Fallback**：主模型挂了 / 限流了，备模型怎么切？Cache 还命中吗？
> ⑤ **成本治理**：Token 怎么埋点？按租户 / 部门分摊？月度预算超了怎么熔断？
>
> 这一篇写完，你能撑得起"LLM 应用平台"系统设计题。

---

## 一、生产 LLM 应用的整体架构

```
┌────────────────────────────────────────────────────────────────┐
│                        前端（Web / App）                          │
└────────────────────────┬───────────────────────────────────────┘
                         │ HTTP / SSE
                         ↓
┌────────────────────────────────────────────────────────────────┐
│                   API Gateway（认证 / 限流入口）                   │
└────────────────────────┬───────────────────────────────────────┘
                         ↓
┌────────────────────────────────────────────────────────────────┐
│                LLM Gateway / Service                            │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │  请求处理 Pipeline                                         │ │
│  │  ① 多租户认证 + 配额检查                                    │ │
│  │  ② Prompt 注入检测                                         │ │
│  │  ③ 语义缓存查询                                            │ │
│  │  ④ Memory 注入                                             │ │
│  │  ⑤ RAG 检索                                                │ │
│  │  ⑥ 限流（TPM/RPM）                                         │ │
│  │  ⑦ LLM 调用（含重试 / Fallback / Cache）                  │ │
│  │  ⑧ 流式响应                                                │ │
│  │  ⑨ Token 埋点 + 成本归账                                   │ │
│  │  ⑩ Trace + 审计日志                                        │ │
│  └──────────────────────────────────────────────────────────┘ │
└────────────────────────┬───────────────────────────────────────┘
                         ↓ 多 Provider
        ┌────────────────┼────────────────┐
        ↓                ↓                ↓
   Claude API       OpenAI API       DeepSeek API
        │                │                │
        └────────────────┴────────────────┘
                Fallback 池
```

---

## 二、流式 SSE：生产实现

### 2.1 SseEmitter（Spring MVC）

```java
@RestController
@RequestMapping("/api/llm")
public class LlmController {
    
    @Autowired private LlmService llmService;
    @Autowired private ExecutorService llmExecutor;  // 隔离线程池
    
    @GetMapping(value = "/chat", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public SseEmitter chat(@RequestParam String prompt, @RequestHeader("X-User-Id") String userId) {
        SseEmitter emitter = new SseEmitter(60_000L);
        AtomicReference<StreamingCall> callRef = new AtomicReference<>();
        AtomicLong tokensUsed = new AtomicLong(0);

        emitter.onTimeout(() -> {
            log.warn("SSE timeout, userId={}, tokens={}", userId, tokensUsed.get());
            Optional.ofNullable(callRef.get()).ifPresent(StreamingCall::cancel);
            emitter.complete();
        });

        emitter.onError(t -> {
            log.error("SSE error, userId={}", userId, t);
            Optional.ofNullable(callRef.get()).ifPresent(StreamingCall::cancel);
        });

        emitter.onCompletion(() -> {
            metrics.recordTokens(userId, tokensUsed.get());
            log.info("SSE complete, userId={}, tokens={}", userId, tokensUsed.get());
        });

        llmExecutor.submit(() -> {
            try {
                StreamingCall call = llmService.streamChat(prompt, userId, chunk -> {
                    emitter.send(SseEmitter.event().data(chunk.text()));
                    tokensUsed.addAndGet(chunk.tokenCount());
                });
                callRef.set(call);
                call.await();   // 阻塞到流结束
                emitter.complete();
            } catch (Exception e) {
                emitter.completeWithError(e);
            }
        });
        return emitter;
    }
}
```

**关键**：
- **专用线程池** `llmExecutor`——LLM 调用慢，不能用 Tomcat 默认线程池（会阻塞业务线程）
- **emitter.onTimeout / onError 回调里必须 cancel 上游调用**——否则 LLM 继续生成 + 烧 Token
- **tokensUsed 实时累加**——便于断线后还能记录已消耗的 Token

### 2.2 WebFlux（高并发推荐）

```java
@RestController
public class LlmReactiveController {
    
    @GetMapping(value = "/api/llm/chat", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public Flux<ServerSentEvent<String>> chat(
            @RequestParam String prompt,
            @RequestHeader("X-User-Id") String userId) {
        return llmService.streamChatReactive(prompt, userId)
            .timeout(Duration.ofSeconds(60))
            .doOnNext(chunk -> metrics.recordChunk(userId, chunk))
            .doOnCancel(() -> log.warn("Client cancelled, userId={}", userId))
            .doOnError(e -> log.error("Stream error", e))
            .map(chunk -> ServerSentEvent.builder(chunk.text()).build())
            .onErrorResume(e -> Flux.just(
                ServerSentEvent.builder("[error] " + e.getMessage()).event("error").build()
            ));
    }
}
```

**优势**：
- 真正异步非阻塞，单机能扛 10K+ 并发 SSE 连接
- 背压（backpressure）支持，慢客户端不拖累服务
- 与 Project Reactor 生态融合

**适用**：QPS 大、SSE 长连接多、需要高吞吐。

### 2.3 反向代理配置（必看）

```nginx
# Nginx 配置（关 buffering 是关键）
location /api/llm/ {
    proxy_pass http://llm-backend;
    proxy_http_version 1.1;
    
    # 关键：关 buffer
    proxy_buffering off;
    proxy_cache off;
    proxy_set_header Connection '';
    chunked_transfer_encoding on;
    
    # SSE 长连接
    proxy_read_timeout 120s;
    proxy_send_timeout 120s;
    
    # 不让 keepalive 把流式包合并
    keepalive_timeout 0;
}
```

> ⚠️ **生产事故**：本地测流式秒级响应，上线 Nginx 后变成"等很久突然全出来"——99% 是没关 `proxy_buffering`。

### 2.4 流式中断的 Token 计费

**关键认知**：客户端断开 ≠ 上游 LLM 停止生成。如果你不主动 cancel，LLM 继续跑到 max_tokens / stop_reason，**这部分 Token 全计费**。

```java
public class StreamingLlmCall implements StreamingCall {
    private final HttpClient httpClient;
    private final AtomicBoolean cancelled = new AtomicBoolean(false);
    private CompletableFuture<Void> activeRequest;

    @Override
    public void cancel() {
        if (cancelled.compareAndSet(false, true)) {
            // OpenAI / Anthropic SDK 都支持取消
            activeRequest.cancel(true);
            log.info("Cancelled upstream LLM call");
        }
    }
}
```

---

## 三、限流（TPM / RPM）

### 3.1 TPM 与 RPM 概念

| 概念 | 含义 | 谁限 |
|---|---|---|
| **RPM**（Requests Per Minute） | 每分钟请求数 | 防止瞬时突发压垮上游 |
| **TPM**（Tokens Per Minute） | 每分钟 Token 数（含 input + output） | 真正的成本和容量约束 |
| **CPM**（Concurrent Per Model） | 同时进行中的请求数 | 防排队溢出 |

OpenAI / Anthropic 都按 Tier 给配额（典型 Tier 1：80K TPM / 1000 RPM），打穿返回 `429 rate_limit_error`。

### 3.2 多租户限流设计

```
┌──────────────────────────────────────────────────┐
│  L1：全局 TPM/RPM（厂商维度，对应 Tier 上限）       │
│      Anthropic Tier 4：400K TPM / 4000 RPM        │
├──────────────────────────────────────────────────┤
│  L2：租户级 TPM/RPM（多租户分配）                   │
│      tenant_A: 50K TPM / 500 RPM                  │
│      tenant_B: 30K TPM / 300 RPM                  │
├──────────────────────────────────────────────────┤
│  L3：用户级 RPM（防滥用）                           │
│      user: 20 RPM / 100K daily Token              │
├──────────────────────────────────────────────────┤
│  L4：模型级（不同模型独立配额）                       │
│      claude-sonnet: ...     gpt-5: ...             │
└──────────────────────────────────────────────────┘
```

### 3.3 实现：Redis + 滑动窗口

```java
public class TokenRateLimiter {
    private final RedisTemplate<String, String> redis;

    /** 基于 Token 数的滑动窗口限流 */
    public boolean tryAcquire(String key, long tokens, long limit) {
        String redisKey = "tpm:" + key;
        long now = System.currentTimeMillis();
        long windowStart = now - 60_000;

        // Lua 脚本保证原子
        String lua = """
            local key = KEYS[1]
            local windowStart = tonumber(ARGV[1])
            local now = tonumber(ARGV[2])
            local tokens = tonumber(ARGV[3])
            local limit = tonumber(ARGV[4])
            
            redis.call('ZREMRANGEBYSCORE', key, 0, windowStart)
            local current = redis.call('ZRANGE', key, 0, -1, 'WITHSCORES')
            local total = 0
            for i = 2, #current, 2 do
                total = total + tonumber(current[i-1]:match("(%d+):"))
            end
            
            if total + tokens > limit then
                return 0
            else
                redis.call('ZADD', key, now, tokens .. ':' .. now)
                redis.call('EXPIRE', key, 120)
                return 1
            end
        """;
        Long result = redis.execute(new DefaultRedisScript<>(lua, Long.class),
            List.of(redisKey),
            String.valueOf(windowStart), String.valueOf(now),
            String.valueOf(tokens), String.valueOf(limit));
        return result != null && result == 1;
    }
}
```

### 3.4 限流后的处理

```java
public LlmResponse callWithRateLimit(LlmRequest req) {
    String tenantId = req.getTenantId();
    long estimatedTokens = estimateTokens(req);   // 输入 token 准估算 + 输出 max_tokens
    
    if (!tenantLimiter.tryAcquire(tenantId, estimatedTokens, getLimit(tenantId))) {
        // 优先级队列 / 降级模型 / 拒绝
        if (req.getPriority() == HIGH) {
            return enqueueAndWait(req);
        } else if (req.allowFallback()) {
            return callFallbackModel(req);  // 切便宜模型
        } else {
            throw new RateLimitException("tenant " + tenantId + " quota exceeded");
        }
    }
    return llmClient.call(req);
}
```

### 3.5 应对厂商限流（429）

```java
public LlmResponse callWithRetry(LlmRequest req) {
    int attempt = 0;
    while (attempt < 3) {
        try {
            return llmClient.call(req);
        } catch (RateLimitException e) {
            // 厂商 429
            long backoff = (long) (Math.pow(2, attempt) * 1000 + ThreadLocalRandom.current().nextInt(500));
            log.warn("Rate limited by upstream, backoff {}ms", backoff);
            Thread.sleep(backoff);
            attempt++;
            
            if (attempt == 2) {
                // 已经退避两次还失败，切 Fallback 模型
                return callFallbackModel(req);
            }
        }
    }
    return callFallbackModel(req);
}
```

---

## 四、缓存：从 Anthropic Prompt Cache 到语义缓存

### 4.1 Anthropic Prompt Cache（详见 [上下文与记忆管理](上下文与记忆管理.md)）

把 System / Tools / Few-shot 标 `cache_control: ephemeral`，5 分钟内复用 KV Cache，前缀部分计费 0.1x。生产命中率 80-95% 时省 60-80%。

### 4.2 语义缓存（Semantic Cache）

**思路**：用户两次问"包邮门槛多少"和"满多少包邮"——语义相同，但 Prompt 不字节相同（Anthropic Cache miss）。语义缓存用 Embedding 比对，相似度高就直接返回历史答案。

```
用户查询 → Embed → 在缓存向量库查 Top-1 → 相似度 > 阈值 → 返回历史答案
                                       → 否则 → 调 LLM → 写入缓存
```

```java
public Optional<String> semanticCacheLookup(String query, String tenantId, double threshold) {
    float[] queryVec = embeddingClient.embed(query);
    
    SearchResult result = cacheVectorStore.search(SearchRequest.builder()
        .queryVec(queryVec)
        .topK(1)
        .filter("tenant_id == '" + tenantId + "'")
        .minSimilarity(threshold)   // 关键：阈值
        .build());
    
    return result.hasMatch() ? Optional.of(result.first().getCachedAnswer()) : Optional.empty();
}

public void semanticCacheWrite(String query, String answer, String tenantId) {
    float[] vec = embeddingClient.embed(query);
    cacheVectorStore.insert(CacheEntry.builder()
        .text(query)
        .vector(vec)
        .answer(answer)
        .tenantId(tenantId)
        .ts(now())
        .ttl(Duration.ofHours(24))
        .build());
}
```

### 4.3 阈值与错命中

| 阈值 | 命中率 | 错命中率 | 适用 |
|---|---|---|---|
| 0.99 | 低（< 5%） | 极低 | 金融 / 医疗（不能错） |
| **0.95** | **中（10-20%）** | 低 | 通用客服（推荐） |
| 0.90 | 高（30%+） | 中 | 闲聊 / 容忍错误 |
| 0.85 | 很高 | 高 | **不推荐** |

> ⚠️ **错命中真实场景**：用户问"信用卡能用吗"，缓存命中"信用卡能不能办"——语义相似度 0.92，但答案完全不同。设阈值 0.95 + 二次校验。

### 4.4 多级缓存

```
请求
  ↓
L1: Caffeine 本地缓存（精确匹配 / 高频常见问题）
  ↓ miss
L2: Redis 缓存（精确匹配 / 跨节点共享）
  ↓ miss
L3: 语义缓存（Embedding 比对）
  ↓ miss
L4: Anthropic Prompt Cache（前缀级别）
  ↓ miss
真正调 LLM
```

---

## 五、降级与 Fallback

### 5.1 降级层级

```
┌─────────────────────────────────────────────────┐
│  L0：主模型正常工作                               │
│      Claude Sonnet 4.6 / GPT-5                  │
├─────────────────────────────────────────────────┤
│  L1：主模型限流 / 错误率高                         │
│      → 切 Fallback 模型                          │
│      Claude Haiku 4.5 / DeepSeek V3              │
├─────────────────────────────────────────────────┤
│  L2：所有模型都不可用                             │
│      → 静态兜底                                   │
│      "暂时无法处理您的请求，请稍后再试 / 转人工"   │
├─────────────────────────────────────────────────┤
│  L3：完全不可用                                   │
│      → 返回 503，前端提示                         │
└─────────────────────────────────────────────────┘
```

### 5.2 跨厂商 Fallback

```java
public class FallbackLlmClient {
    private final List<LlmProvider> providers;  // 按优先级

    public LlmResponse call(LlmRequest req) {
        Exception lastError = null;
        for (LlmProvider provider : providers) {
            if (!provider.isHealthy()) continue;
            
            try {
                return provider.call(req);
            } catch (RateLimitException | ServerOverloadedException e) {
                log.warn("Provider {} failed, trying next", provider.getName(), e);
                lastError = e;
                provider.markUnhealthy(60);  // 60s 后再试
            } catch (InvalidRequestException e) {
                // 4xx 不重试
                throw e;
            }
        }
        throw new AllProvidersFailedException(lastError);
    }
}
```

### 5.3 Fallback 切换的注意事项

```
切 Fallback 时三件事必须考虑：
  ① Prompt 兼容性：Claude 用 XML 风格，GPT 用 Markdown 风格
  ② Tool 协议差异：自动转换字段名 / arguments 格式
  ③ Cache 失效：切了厂商 Prompt Cache 全失效，第一次重新计费
  
所以 Fallback 不是无成本的：
  - 单次调用成本 +100%（cache 重置）
  - 输出质量可能下降（fallback 是更便宜模型）
  - 必须做 A/B 评估 fallback 模型质量是否可接受
```

### 5.4 健康检查 + 熔断

```java
public class ProviderHealthChecker {
    @Scheduled(fixedRate = 30_000)
    public void check() {
        providers.forEach(p -> {
            try {
                LlmResponse resp = p.call(HEALTH_CHECK_REQ);  // 极简请求
                p.markHealthy();
            } catch (Exception e) {
                p.markUnhealthy(60);
            }
        });
    }
}
```

---

## 六、成本治理

### 6.1 Token 埋点（必做）

```java
@Aspect
@Component
public class LlmMetricsAspect {
    
    @Around("execution(* LlmClient.call(..))")
    public Object recordMetrics(ProceedingJoinPoint pjp) throws Throwable {
        LlmRequest req = (LlmRequest) pjp.getArgs()[0];
        long start = System.nanoTime();
        
        LlmResponse resp;
        String status = "success";
        try {
            resp = (LlmResponse) pjp.proceed();
        } catch (Exception e) {
            status = "error";
            throw e;
        } finally {
            long durationMs = (System.nanoTime() - start) / 1_000_000;
            metrics.record(LlmMetric.builder()
                .tenantId(req.getTenantId())
                .userId(req.getUserId())
                .model(req.getModel())
                .inputTokens(resp != null ? resp.getInputTokens() : 0)
                .outputTokens(resp != null ? resp.getOutputTokens() : 0)
                .cacheReadTokens(resp != null ? resp.getCacheReadTokens() : 0)
                .cacheWriteTokens(resp != null ? resp.getCacheWriteTokens() : 0)
                .costUsd(calculateCost(req.getModel(), resp))
                .durationMs(durationMs)
                .status(status)
                .build());
        }
        return resp;
    }
}
```

### 6.2 成本归账

```sql
-- 多租户成本归账查询
SELECT 
    tenant_id,
    model,
    DATE(ts) AS day,
    SUM(input_tokens) AS input_tokens,
    SUM(output_tokens) AS output_tokens,
    SUM(cache_read_tokens) AS cache_read_tokens,
    SUM(cost_usd) AS daily_cost
FROM llm_metrics
WHERE ts >= '2026-05-01'
GROUP BY tenant_id, model, DATE(ts)
ORDER BY daily_cost DESC;
```

### 6.3 配额管理

```java
public class CostQuotaService {
    /** 检查租户当日配额 */
    public boolean checkQuota(String tenantId) {
        BigDecimal todayCost = metricsService.getTodayCost(tenantId);
        BigDecimal quota = quotaService.getQuota(tenantId);
        return todayCost.compareTo(quota) < 0;
    }
    
    /** 配额预警 */
    @Scheduled(fixedRate = 300_000)
    public void checkQuotaAlerts() {
        for (String tenant : activeTenants()) {
            BigDecimal usage = metricsService.getTodayCost(tenant);
            BigDecimal quota = quotaService.getQuota(tenant);
            double pct = usage.divide(quota, 2, RoundingMode.HALF_UP).doubleValue();
            
            if (pct > 0.9) {
                alertService.sendAlert(tenant, "quota 90% used");
            }
            if (pct > 1.0) {
                quotaService.suspend(tenant);  // 超额暂停
            }
        }
    }
}
```

---

## 七、Trace 与可观测性

### 7.1 OpenTelemetry GenAI Convention

OpenTelemetry 在 2024 年定义了 LLM 应用的标准属性（Semantic Conventions for Generative AI）：

```
gen_ai.system: "anthropic" | "openai" | "google.gemini"
gen_ai.request.model: "claude-sonnet-4-6"
gen_ai.request.temperature: 0.3
gen_ai.request.max_tokens: 4096
gen_ai.usage.input_tokens: 8500
gen_ai.usage.output_tokens: 350
gen_ai.usage.cache_read_input_tokens: 7500
gen_ai.response.id: "msg_xxx"
gen_ai.response.finish_reasons: ["end_turn"]
```

### 7.2 集成示例

```java
@Component
public class TracingLlmInterceptor {
    private final Tracer tracer = GlobalOpenTelemetry.getTracer("llm-service");
    
    public LlmResponse intercept(LlmRequest req, LlmCall next) {
        Span span = tracer.spanBuilder("llm.call")
            .setAttribute("gen_ai.system", req.getProvider())
            .setAttribute("gen_ai.request.model", req.getModel())
            .setAttribute("gen_ai.request.temperature", req.getTemperature())
            .startSpan();
        
        try (Scope scope = span.makeCurrent()) {
            LlmResponse resp = next.call(req);
            span.setAttribute("gen_ai.usage.input_tokens", resp.getInputTokens());
            span.setAttribute("gen_ai.usage.output_tokens", resp.getOutputTokens());
            span.setAttribute("gen_ai.response.finish_reasons", resp.getStopReason());
            return resp;
        } catch (Exception e) {
            span.recordException(e);
            span.setStatus(StatusCode.ERROR);
            throw e;
        } finally {
            span.end();
        }
    }
}
```

### 7.3 Trace 工具选型

| 工具 | 类型 | 优势 |
|---|---|---|
| **Langfuse** | 开源 / SaaS | LLM 专用、UI 友好、支持本地部署 |
| **LangSmith** | LangChain SaaS | 与 LangChain / LangGraph 深度集成 |
| **Phoenix**（Arize） | 开源 | 对 RAG 评估友好 |
| **Honeycomb** / **DataDog** | 通用 APM | 不专门 LLM 但可用 OTel 适配 |

详见 [Agent 评估与可观测性](Agent评估与可观测性.md)。

---

## 八、生产踩坑

### 坑 1：Tomcat 默认线程池被 LLM 慢调用打满

**现象**：上线 LLM 接口后，整个 Spring Boot 应用响应都变慢，连 `/health` 也卡。

**根因**：
- Tomcat 默认 `max-threads=200`，LLM 请求平均 5 秒
- 200 线程很快全占用，新请求排队
- `/health` 也走 Tomcat 线程池

**修复**：
- LLM 调用走**专用线程池**（`llmExecutor`，200-500 线程，独立 RejectedExecutionHandler）
- WebFlux 全异步化（推荐高并发场景）
- `/health` 用单独的 Actuator 端口或异步 endpoint

### 坑 2：Nginx buffering 让流式假流式

**现象**：本地测流式响应正常，上线后变成"等很久突然全出来"。

**根因**：Nginx 默认 `proxy_buffering on`，把整个响应缓存完才转发。

**修复**：参考第 2.3 节。

### 坑 3：限流计算用 Tomcat 实例本地变量，多实例不准

**现象**：3 节点集群，限流配置 100 RPM，实际线上接近 300 RPM。

**根因**：用了 Spring 单机内存（如 Resilience4j RateLimiter），多实例各自独立计数。

**修复**：
- 切到 **Redis 分布式限流**（Lua 脚本原子）
- 或者用 **API Gateway 统一限流**（Nginx limit_req / Spring Cloud Gateway）
- 单元测试 + 压测验证多实例下的 QPS 总和

### 坑 4：语义缓存阈值 0.85 错命中，用户体验崩

**现象**：上线语义缓存后，用户反馈"经常给的不是我问的答案"。

**根因**：
- 阈值设太低（0.85），相似不等于等价
- 没考虑租户隔离（不同租户的缓存串了）
- 没考虑时效（"今天的天气" 用了昨天的缓存）

**修复**：
- 阈值上调到 0.95
- 强制 tenant_id 过滤
- 时效字段：动态查询（含时间）不进缓存
- 加二次校验：相似度 0.92-0.95 区间走 LLM 二次确认（成本可接受）

### 坑 5：Fallback 切了 GPT-5 后，输出格式与 Claude 不一致

**现象**：主模型 Claude 流量被限，自动切 GPT-5。原本要求"输出 JSON"，Claude 稳定，GPT 偶尔输出带 ```` ```json ```` 围栏。

**根因**：
- Prompt 是为 Claude 优化的（XML 标签风格）
- GPT 对 XML 解析不一致
- JSON Mode 没启用（仍靠 Prompt 约束）

**修复**：
- Prompt 写跨厂商通用版本（避免 XML / Markdown 风格依赖）
- 启用 GPT 的 Structured Output / JSON Mode（参考 [Prompt Engineering](PromptEngineering.md)）
- Fallback 之后加"Output Validator"：解析失败再 retry 一次或转兜底
- 对 Fallback 链路做单独的 A/B 评估，确保质量可接受

### 坑 6：流式响应 4 分钟后断开，用户体验崩

**现象**：长流式响应（生成大段报告）4 分钟后客户端连接断开。

**根因**：
- AWS ALB 默认 idle_timeout 60s，4 分钟超时
- Nginx `proxy_read_timeout` 默认 60s
- 客户端浏览器对 SSE 长连接通常 15 分钟超时

**修复**：
- ALB / Nginx `idle_timeout` / `read_timeout` 调到 120-300s
- 服务端**主动发心跳事件**保持连接活跃（每 30s 一个 `:keepalive`）
- 长任务改成异步：返回 task_id，前端轮询 / WebSocket 拿进度

```java
// 心跳保活
@Scheduled(fixedRate = 30_000)
public void sendHeartbeat() {
    activeEmitters.forEach(emitter -> {
        try {
            emitter.send(SseEmitter.event().comment("keepalive"));
        } catch (Exception ignore) {}
    });
}
```

---

## 九、面试高频追问

**Q1：流式 SSE 在 Spring 怎么实现？SseEmitter 和 WebFlux 怎么选？**

低 / 中并发用 **SseEmitter**（Spring MVC，简单），高并发（QPS > 1K + 长连接）用 **WebFlux**（异步非阻塞 + 背压）。两者都要：① 专用线程池隔离 LLM 慢调用；② onTimeout/onError 回调里 cancel 上游 LLM；③ tokensUsed 实时埋点；④ Nginx 配 `proxy_buffering off`；⑤ 长流式加心跳保活。

**Q2：流式中断断线，Token 怎么算？**

客户端断开 ≠ 上游 LLM 停止。如果不主动 cancel，**模型继续跑到 max_tokens / stop_reason，全 Token 计费**。后端必须：监听 SseEmitter / Flux 的 onTimeout / cancel 事件 → 立即调用底层 LLM SDK 的 cancel（OpenAI 是 AbortController.abort()）→ 持久化已生成内容（前端恢复时不重新调 LLM）。

**Q3：TPM 和 RPM 区别？多租户怎么分配？**

RPM 限请求数（防瞬时突发），TPM 限 Token 数（真正的成本约束）。OpenAI / Anthropic 按 Tier 给配额（Tier 1 ≈ 80K TPM）。多租户**四层限流**：① 全局（厂商 Tier 上限）；② 租户级（按合同 / 重要度分配）；③ 用户级（防滥用）；④ 模型级（不同模型独立）。**实现**：Redis + Lua 滑动窗口，避免 Tomcat 单机本地变量在多实例失效。

**Q4：限流被打穿（429）怎么处理？**

四档应对：① **指数退避重试**（2 次）；② **降级到 Fallback 模型**（Claude → DeepSeek）；③ **优先级队列**（VIP 用户先放行，普通用户等）；④ **拒绝**（普通流量直接返回 503）。**别一直死等**——超过 3 秒用户体验已崩，宁愿降级。

**Q5：语义缓存怎么做？阈值定多少？**

Embedding 用户 query → 在缓存向量库找 Top-1 → 相似度 > 阈值 → 返回历史答案。**阈值 0.95 是甜区**——太低（0.85）错命中率高（"信用卡能用吗" 命中"信用卡能不能办"），太高（0.99）命中率低收益小。**关键约束**：① 强 tenant_id 过滤；② 含时间 / 状态的 query 不进缓存；③ 相似度 0.92-0.95 区间走 LLM 二次确认。

**Q6：Fallback 模型切换有什么坑？**

三个：① **Cache 失效**——切厂商 Prompt Cache 全部重置，第一次成本翻倍；② **Prompt 兼容性**——Claude 优化的 XML 风格在 GPT 上不一定稳定；③ **输出质量下降**——Fallback 通常是更便宜模型。**修复**：Prompt 写跨厂商通用版、启用结构化输出、对 Fallback 链路单独 A/B 评估。

**Q7：你们生产 LLM 一个月烧多少钱？怎么砍？**

典型 ToB 客服场景：日均 10 万次对话 × $0.11 ≈ $33K/月。**砍成本五招**：① **Anthropic Prompt Cache**（命中 90% 省 60-80%）；② **语义缓存**（高频问题命中 30%+ 直接返回）；③ **模型分级**（简单分类用 Haiku，复杂推理用 Opus）；④ **Token 埋点 + 部门配额**（超预算自动暂停）；⑤ **Top-K 降低 + Rerank**（RAG 召回 5 段够了不要 20）。**通常能砍 50-70%**。

**Q8：怎么对 LLM 应用做监控？告警阈值多少？**

核心指标：① **可用性**——P99 < 5s、成功率 > 99.5%；② **成本**——日预算消耗、Cache 命中率；③ **质量**——用户点踩率、重新提问率、Fallback 触发率；④ **限流**——TPM 使用率、429 错误率；⑤ **业务**——RAG 召回 Hit@K、Tool 调用成功率。**告警阈值**：单租户 1 小时成本 > 上日峰值 3x、Fallback 触发率 > 10%、429 持续 > 5 分钟、首 Token 延迟 P95 > 2s。

**Q9：OpenTelemetry GenAI Convention 是什么？**

OTel 2024 年定义的 LLM 应用标准属性集，约定 `gen_ai.system / gen_ai.request.model / gen_ai.usage.input_tokens` 等字段。**好处**：用统一规范埋点，可以跨工具切换（Langfuse / LangSmith / Phoenix / Jaeger / DataDog）。Java 推荐通过 OpenTelemetry SDK 自动埋点 + 自定义 Span Processor 适配 LLM 字段。

**Q10：LLM Gateway 自研还是用现成的？**

业界主流自研——OpenAI / Anthropic SDK + 自实现限流 / 缓存 / Fallback / 路由。**原因**：① 业务定制（成本归账 / SLA / 合规）；② 多模型路由是核心价值；③ 现成方案（如 LiteLLM、Portkey、Helicone）有锁定风险。**典型架构**：Spring Boot + Resilience4j + Redis + 自研 Provider 抽象，5-10 人团队 3 个月能做到生产级。

---

## 十、答题模板（60 秒）

> "生产 LLM 应用 = **Gateway 层（多租户 / 限流 / 缓存 / Fallback / Trace）+ 多 Provider 池**。"
>
> "**流式 SSE**：低中并发 SseEmitter + 专用线程池，高并发 WebFlux。**断线必须 cancel 上游**，**Nginx 必须关 buffering**，长流式加心跳保活。"
>
> "**限流四层**：全局（Tier）/ 租户 / 用户 / 模型，用 Redis + Lua 滑动窗口（多实例一致）。打穿后退避重试 2 次 → 切 Fallback 模型 → 优先级队列 → 拒绝。"
>
> "**缓存多级**：L1 Caffeine 本地 → L2 Redis 精确匹配 → L3 语义缓存（**阈值 0.95**，强 tenant 过滤）→ L4 Anthropic Prompt Cache → 真调 LLM。"
>
> "**Fallback** 不是无成本——Cache 失效、Prompt 兼容、输出质量都要 A/B 验证。**成本治理**：Token 埋点 + 部门配额 + 90% 预警 + 100% 暂停。**Trace 走 OpenTelemetry GenAI Convention**，落地到 Langfuse / LangSmith。"

---

## 十一、相关文档

- [LLM 基础与面试视角](LLM基础与面试视角.md) — Token / 流式 / 推理参数基础
- [上下文与记忆管理](上下文与记忆管理.md) — Anthropic Prompt Cache 原理
- [Agent 架构模式](Agent架构模式.md) — Agent 步数 / 成本上限
- [Function Calling 与 Tool Use](FunctionCalling与ToolUse.md) — 流式 Tool Call 处理
- [Agent 评估与可观测性](Agent评估与可观测性.md) — Trace 工具与告警阈值
- [Microservice/限流算法](../Microservice/限流算法.md) — 滑动窗口 / 令牌桶基础
- [Microservice/Sentinel](../Microservice/Sentinel.md) — Sentinel 限流方案
- [Redis](../Redis/README.md) — Redis Lua 限流脚本
- [Network/HTTP 协议](../Network/HTTP协议.md) — SSE 协议细节
- [RAG 与 Agent 生产踩坑](RAG与Agent生产踩坑.md) — 工程化真实事故
