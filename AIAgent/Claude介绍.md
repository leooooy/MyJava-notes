# Claude 介绍：模型家族 / Claude Code / 设计哲学

> 引子：本模块里 Claude 是高频被引用的模型（[模型对比表](README.md#41-主流模型快速参考2026-年初) 第一行就是它），但前面各篇都把它当成一个"API 端点"在用。这篇把镜头拉回 Claude 本身——
> ① **它是什么**：Anthropic 的大模型家族（Opus / Sonnet / Haiku），以及它在 Agent / Tool Use 场景为什么稳；
> ② **Claude Code 是什么**：一个把 LLM 做成"自主编码 Agent"的真实工程范例，本身就是 Agent 架构的活教材；
> ③ **一个彩蛋**：Claude Code 终端转圈圈时蹦出来的 178 个英文词，到底是啥——附**从二进制里真抓出来的完整词表**。

---

## 一、Claude 是什么

**Claude** 是 [Anthropic](https://www.anthropic.com) 的大语言模型家族。Anthropic 由前 OpenAI 的研究骨干（Dario / Daniela Amodei 兄妹等）2021 年创立，主打 **AI 安全（AI Safety）**，代表方法是 **Constitutional AI（宪法式 AI）**——不靠人逐条标注"什么不能说"，而是给模型一部"宪法"（一组原则），让模型按原则自我批评、自我修正（RLAIF，用 AI 反馈代替部分人类反馈）。

> **为什么面试值得提一句**：Constitutional AI 是"对齐（Alignment）"领域绕不开的工程方法。被问到"你怎么防 LLM 输出有害内容"时，除了讲应用层的 Prompt 注入防御（见 [Prompt Engineering](PromptEngineering.md)），能点出"模型厂商侧还有 Constitutional AI / RLHF 这层"，深度立刻不一样。

### 1.1 命名规则：能力档 × 版本号

Claude 用**两个维度**命名，记住这个心智模型，看到任何型号都能秒定位：

```
Claude  [能力档]  [版本号]
         ├─ Opus    ── 最强档：复杂推理 / 长链路 Agent / 难题攻坚（最贵最慢）
         ├─ Sonnet  ── 均衡档：性价比之王 / 生产 Agent 主力（快 + 准 + 便宜）
         └─ Haiku   ── 轻量档：高吞吐 / 简单分类 / 实时场景（最快最便宜）

  类比餐厅：Opus = 主厨定制，Sonnet = 招牌套餐，Haiku = 快餐。
  90% 的生产流量应该跑在 Sonnet 上，只在啃硬骨头时调 Opus。
```

> 命名取自文学体裁：**Opus**（大部头作品）> **Sonnet**（十四行诗）> **Haiku**（俳句，最短），用篇幅长短暗示模型"体量"。

### 1.2 当前家族（2026 年初）

| 模型 | 上下文窗口 | 定位 | 典型用法 |
|---|---|---|---|
| **Claude Opus 4.x** | 1M | 最强推理 / 长上下文 / Tool Use 极稳 | 复杂 Agent、疑难调试、架构设计 |
| **Claude Sonnet 4.x** | 1M | 均衡主力 | 生产 Agent、RAG、日常编码 |
| **Claude Haiku 4.x** | 200K | 高吞吐轻量 | 分类、抽取、实时补全 |

> 价格与横向对比见 [README §4.1](README.md#41-主流模型快速参考2026-年初)。版本号会持续迭代（4.5 → 4.6 → 4.7 → 4.8…），但**能力档（Opus/Sonnet/Haiku）这套划分是稳定的**。

### 1.3 Claude 在 Agent 场景的工程优势

为什么很多 Agent 框架默认推荐 Claude 做"大脑"？从工程视角看三点：

1. **Tool Use 稳定性高**：长链路多轮工具调用里，幻觉出工具名、瞎编参数的概率低，`max_iterations` 不容易被打满（呼应 [Function Calling §防死循环](FunctionCalling与ToolUse.md)）。
2. **长上下文不容易"中间遗忘"**：1M 窗口配合训练优化，Lost-in-the-Middle 现象相对缓解（对比 [上下文与记忆 §长上下文衰减](上下文与记忆管理.md)）。
3. **Prompt Cache 省钱**：Anthropic 的 Prompt Cache 命中可省到 1/10 输入成本，是 Agent 场景（System Prompt 巨长且固定）成本治理的关键（见 [LLM 应用工程化 §Prompt Cache](LLM应用工程化.md)）。

---

## 二、Claude Code：一个真实的"自主编码 Agent"

**Claude Code** 是 Anthropic 官方的命令行编码 Agent——你在终端里用自然语言提需求，它自己读代码库、改文件、跑命令、看报错、再修，是 **ReAct + Tool Use 模式的工业级落地**，本身就是本模块讲的 Agent 架构的活样本。

### 2.1 它把本模块的概念全用上了

| 本模块概念 | Claude Code 里的对应 |
|---|---|
| [Tool Use / Function Calling](FunctionCalling与ToolUse.md) | 内置 Read / Edit / Bash / Grep / Glob 等工具，模型自主决定调哪个 |
| [ReAct 架构](Agent架构模式.md) | 想（reason）→ 调工具（act）→ 看结果（observe）→ 再想，循环到任务完成 |
| [防死循环](Agent架构模式.md) | 工具失败有重试上限、步数有边界、危险操作（删除 / 推送）要确认 |
| [上下文与记忆](上下文与记忆管理.md) | 长对话自动压缩（compaction）+ `CLAUDE.md` 作为项目级长期记忆 |
| [MCP 协议](MCP协议.md) | 可挂 MCP Server 扩展工具（连数据库、连 Jira、连浏览器） |
| [Prompt Cache](LLM应用工程化.md) | System Prompt + 工具定义走 Cache，多轮对话才不会成本爆炸 |

> **面试可迁移点**：如果你被问"设计一个能自主改代码的 Agent"，Claude Code 就是现成答案骨架——ReAct 主循环 + 工具集（读/写/执行）+ 权限确认 + 上下文压缩 + 项目记忆文件。把这套讲清楚，比空谈"用 LangGraph 编排"具体得多。

### 2.2 形态与版本

- **形态**：CLI（终端）、桌面 App（Mac/Windows）、Web（claude.ai/code）、IDE 插件（VS Code / JetBrains）。
- **打包**：v2.x 已经是单个原生二进制（约 200MB+，把 JS 运行时一起打包），不再依赖外部 Node。下一节的彩蛋就是从这个二进制里抓出来的。

---

## 三、彩蛋：终端转圈圈的 178 个词

Claude Code 干活（等模型出 token）时，spinner（转圈动画）旁会随机蹦一个 **-ing 结尾的英文词**，比如 `Cogitating…`、`Percolating…`、`Baking…`。

**关键认知（别误会）**：这些词是**纯装饰文案**，跟它当前在干嘛**毫无对应关系**——出现 `Baking` 不代表在编译，出现 `Scheming`（其实没这个词，见下）也不是在搞阴谋。它的唯一作用是**缓解等待焦虑 + 制造活人感**：每次刷新都不一样，潜意识让你觉得"它真在动脑子"，而不是卡死了。这是 loading 文案的经典产品设计套路（早年 Slack / GitHub 都玩过）。

### 3.1 它们藏在哪 / 怎么自己挖出来

词库是**硬编码在 Claude Code 客户端**里的字符串数组（明文），会随版本增删。在本机用一行命令就能抓出当前版本的全量：

```bash
# 1. 找到安装目录（npm 全局包）
npm root -g            # 例：D:\...\node_global\node_modules
# 二进制在：<root>\@anthropic-ai\claude-code\bin\claude.exe

# 2. 用 ripgrep 在二进制里搜"连续成串的 -ing 词数组"
rg -a -o '"[A-Z][a-z]+ing"(,"[A-Z][a-z]+ing")+' claude.exe \
  | grep -o '"[A-Z][a-z]*ing"' | tr -d '"' | sort -u
```

> ⚠️ **版本相关**：下表抓自 **claude-code v2.1.141**，共 **178 个**唯一词，**全部是现在分词（-ing）**。升级后词库可能变（增删梗词），想看你自己版本的就跑上面命令。
>
> 同时这也是个"**断言要先验证**"的小案例：先前凭印象说的 `Scheming` / `Fibbering` 两个词，真去 `grep` 二进制发现**这个版本根本没有**——所以下表是实抓的，不是手打的。

### 3.2 按画风分类（178 词全表）

#### 🍳 厨房 / 食物类（最大流派，凑"火候未到"的等待感）
`Baking` `Blanching` `Brewing` `Bunning` `Caramelizing` `Churning` `Concocting` `Cooking` `Crystallizing` `Drizzling` `Fermenting` `Frosting` `Garnishing` `Infusing` `Julienning`（切丝）`Kneading`（揉面）`Leavening`（发酵）`Marinating`（腌）`Misting` `Proofing`（醒面）`Seasoning` `Simmering`（文火炖）`Stewing` `Sublimating` `Tempering`（调温）`Whisking`（打蛋）`Zesting`（刨皮屑）

#### 🧠 思考 / 认知类（字面"在动脑"）
`Cerebrating` `Cogitating` `Computing` `Considering` `Contemplating` `Crunching` `Deciphering` `Deliberating` `Determining` `Elucidating` `Envisioning` `Ideating` `Imagining` `Improvising` `Inferring` `Mulling` `Musing` `Perusing` `Philosophising` `Pondering` `Pontificating`（高谈阔论）`Processing` `Puzzling` `Ruminating`（反刍式沉思）`Thinking`

#### 🔨 创造 / 工程类
`Accomplishing` `Actioning` `Actualizing` `Architecting` `Bootstrapping` `Calculating` `Channeling` / `Channelling` `Choreographing` `Composing` `Crafting` `Creating` `Cultivating` `Effecting` `Embellishing` `Forging` `Forming` `Generating` `Harmonizing` `Hashing` `Manifesting` `Mustering` `Orchestrating` `Reticulating` `Sketching` `Synthesizing` `Tinkering` `Working` `Wrangling` `Doing`

#### 🤪 无厘头 / 卖萌类（彩蛋核心，故意"不像 AI"）
`Befuddling` `Bloviating`（瞎吹）`Boogieing` `Boondoggling`（磨洋工）`Booping` `Canoodling`（搂抱）`Clauding`（自造词，"Claude 化"）`Combobulating` / `Discombobulating` / `Recombobulating`（生造的"理顺 / 搞乱 / 再理顺"三连）`Doodling`（涂鸦）`Enchanting` `Flibbertigibbeting`（叽叽喳喳）`Flummoxing`（搞懵）`Frolicking` `Gallivanting`（闲逛）`Gesticulating`（比划）`Gitifying`（git 化）`Grooving` `Honking` `Hullaballooing`（喧闹）`Jitterbugging`（跳吉特巴）`Lollygagging`（磨蹭）`Moonwalking` `Moseying`（溜达）`Newspapering` `Noodling`（瞎鼓捣）`Prestidigitating`（变戏法）`Puttering`（瞎忙）`Quantumizing` `Razzmatazzing`（花里胡哨）`Shenaniganing`（搞鬼）`Shimmying` `Skedaddling`（开溜）`Smooshing`（揉成团）`Spelunking`（钻洞探险）`Tomfoolering`（胡闹）`Vibing` `Waddling`（摇摇摆摆走）`Whatchamacalliting`（"那啥啥化"）`Wibbling`

#### 🌊 自然 / 物理 / 动物类
`Beaming` `Billowing`（翻涌）`Burrowing` `Cascading` `Catapulting` `Coalescing`（聚合）`Ebbing`（退潮）`Evaporating` `Flowing` `Fluttering` `Galloping` `Germinating`（发芽）`Gusting` `Hatching`（孵化）`Herding` `Hyperspacing` `Incubating` `Ionizing` `Levitating`（悬浮）`Metamorphosing`（蜕变）`Nebulizing`（雾化）`Nesting` `Nucleating`（成核）`Orbiting` `Osmosing`（渗透）`Perambulating`（漫步）`Percolating`（渗滤）`Photosynthesizing`（光合）`Pollinating`（授粉）`Pouncing`（猛扑）`Precipitating`（沉淀 / 析出）`Propagating` `Roosting`（栖息）`Scampering` `Scurrying`（疾走）`Slithering`（滑行）`Sprouting` `Swirling` `Swooping` `Symbioting`（共生）`Thundering` `Transfiguring` `Transmuting` `Twisting` `Undulating`（起伏）`Unfurling`（展开）`Unravelling`（抽丝剥茧）`Wandering` `Meandering`（蜿蜒漫游）`Warping` `Whirlpooling` `Whirring` `Zigzagging` `Spinning`

> 总计 178 词。你在终端里最常见的 `Cogitating` / `Percolating` / `Baking` / `Puzzling` / `Processing` / `Creating` / `Meandering` / `Unravelling` 都在册——其中 `Clauding`、`Gitifying`、`Whatchamacalliting` 这种生造词，是开发团队埋的私货式幽默。

### 3.3 一句话总结这个彩蛋的"为什么"

> **延迟不可消除，但焦虑可以设计。** LLM 出 token 天然有等待，干巴巴一个 `Loading…` 会放大"是不是卡了"的猜疑；178 个随机趣味词，把"无聊的等待"变成"有陪伴感、有人格的等待"——这正是把冷冰冰的工程延迟，包装成产品体验的典型手法。做 LLM 应用前端（流式 SSE、首 Token 延迟 TTFT）时，这个思路可直接抄：**首 Token 没来之前，给用户一点有生命力的反馈**（见 [LLM 应用工程化 §流式与 TTFT](LLM应用工程化.md)）。

---

## 四、相关文档

| 文档 | 关联点 |
|---|---|
| [LLM 基础与面试视角](LLM基础与面试视角.md) | Claude 在主流模型横向对比里的位置、上下文窗口、计费 |
| [Function Calling 与 Tool Use](FunctionCalling与ToolUse.md) | Claude 的 Tool Use 协议写法、并行调用、防死循环 |
| [Agent 架构模式](Agent架构模式.md) | Claude Code 是 ReAct 模式的工业级样本 |
| [上下文与记忆管理](上下文与记忆管理.md) | Claude 长上下文、对话压缩、`CLAUDE.md` 项目记忆 |
| [MCP 协议](MCP协议.md) | MCP 由 Anthropic 提出，Claude Code 原生支持挂 MCP Server |
| [LLM 应用工程化](LLM应用工程化.md) | Anthropic Prompt Cache 省钱原理、流式 TTFT 与等待体验 |
