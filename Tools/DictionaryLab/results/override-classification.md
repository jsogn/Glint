# Runtime Override Audit

- Date: 2026-10-22T03:06:24.113160+00:00
- Overrides: 105
- Retire from runtime: 44
- Fallback only: 61
- Exact-phrase fallbacks: 16

## Blocklist

| Term | Action | Reason |
| --- | --- | --- |
| 你号 | keep_exact_invalid_fragment | nonstandard fragment, but this policy must remain separate from lexical ranking |

## Retire From Runtime

| Term | Current value | Reason |
| --- | --- | --- |
| 开发 | ["develop", "development", "exploit"] | develop/build versus issue a receipt or invoice |
| 功能 | ["feature"] | feature versus function depends on context |
| 业务 | ["business"] | business versus service depends on context |
| 方案 | ["solution"] | solution, plan, and approach are context-dependent |
| 问题 | ["issue"] | issue, problem, and question are different senses |
| 结果 | ["result"] | result or outcome versus the conjunction 'as a result' |
| 目标 | ["goal"] | goal or objective versus a physical target |
| 流程 | ["process"] | process, procedure, and workflow are context-dependent |
| 上线 | ["launch"] | launch, go live, and become available depend on context |
| 发布 | ["release"] | product release versus publishing a post |
| 部署 | ["deploy"] | deploy as a verb versus deployment as a noun |
| 配置 | ["configuration"] | configuration as a noun versus configure as a verb |
| 安全 | ["security"] | security or safety as a noun versus safe as an adjective |
| 输入 | ["input"] | input as a noun versus enter or type as a verb |
| 输出 | ["output"] | output as a noun versus output or export as a verb |
| 翻译 | ["translation"] | translation as a noun versus translate as a verb |
| 实现 | ["implement"] | implement versus realize or achieve |
| 优化 | ["optimize"] | optimize as a verb versus optimization as a noun |
| 重构 | ["refactor"] | refactor versus restructure depends on context |
| 处理 | ["handle", "process", "deal with"] | handle, process, deal with, and treatment are distinct |
| 运行 | ["run", "operate", "function"] | run, operate, execute, and function are context-dependent |
| 结构 | ["structure", "composition"] | structure, composition, and organization are distinct |
| 接口 | ["API"] | software API or interface versus a physical port |
| 字段 | ["field"] | field versus database column depends on the product context |
| 缓存 | ["cache"] | cache as a noun versus cache or caching as an action |
| 并发 | ["concurrency"] | concurrency as a noun versus concurrent as an adjective |
| 延迟 | ["latency"] | latency or delay as a noun versus delay as a verb |
| 依赖 | ["dependency"] | dependency as a noun versus depend or rely as a verb |
| 组件 | ["component"] | component versus widget depends on the UI context |
| 文档 | ["documentation"] | documentation versus a single document |
| 验收 | ["acceptance"] | acceptance as a noun versus inspect and accept as a verb |
| 灰度 | ["canary"] | canary release versus grayscale image processing |
| 计算 | ["calculate", "calculation"] | calculate as a verb versus calculation as a noun |
| 复盘 | ["retrospective"] | retrospective versus review or analyze footage |
| 对齐 | ["align", "alignment"] | align as a verb versus alignment as a noun |
| 迭代 | ["iterate"] | iterate as a verb versus iteration as a noun |
| 需求 | ["requirement", "demand"] | user requirements versus market demand |
| 场景 | ["scenario"] | business use case or scenario versus a film scene |
| 指标 | ["metric", "indicator"] | metric versus indicator depends on context |
| 落地 | ["implement"] | implementation versus physically landing |
| 拆分 | ["break down"] | break down a task versus split off a business |
| 收敛 | ["converge"] | converge as a verb versus convergence as a noun |
| 权衡 | ["trade-off", "balance"] | trade-off as a noun versus weigh as a verb |
| 推理 | ["reasoning"] | reasoning as a noun versus infer as a verb |

## Fallback Only

These entries may remain as exact, low-priority fallback data. They must never force a result ahead of the model or ranked dictionary output.

| Term | Scope | Current value |
| --- | --- | --- |
| 你好吗 | exact_phrase | ["How are you?"] |
| 程序 | exact_term | ["program", "procedure", "process"] |
| 设计 | exact_term | ["design", "plan"] |
| 数据 | exact_term | ["data"] |
| 计算机 | exact_term | ["computer"] |
| 项目 | exact_term | ["project"] |
| 系统 | exact_term | ["system"] |
| 用户 | exact_term | ["user"] |
| 产品 | exact_term | ["product"] |
| 团队 | exact_term | ["team"] |
| 公司 | exact_term | ["company"] |
| 客户 | exact_term | ["customer"] |
| 会议 | exact_term | ["meeting"] |
| 计划 | exact_term | ["plan"] |
| 版本 | exact_term | ["version"] |
| 代码 | exact_term | ["code"] |
| 测试 | exact_term | ["test"] |
| 性能 | exact_term | ["performance"] |
| 隐私 | exact_term | ["privacy"] |
| 模型 | exact_term | ["model"] |
| 插件 | exact_term | ["plugin"] |
| 词典 | exact_term | ["dictionary"] |
| 句子 | exact_term | ["sentence"] |
| 单词 | exact_term | ["word"] |
| 中文 | exact_term | ["Chinese"] |
| 英文 | exact_term | ["English"] |
| 苹果 | exact_term | ["apple"] |
| 复杂 | exact_term | ["complex", "complicated"] |
| 吞吐 | exact_term | ["throughput"] |
| 模块 | exact_term | ["module"] |
| 评审 | exact_term | ["review"] |
| 埋点 | exact_term | ["event tracking"] |
| 回滚 | exact_term | ["rollback"] |
| 队列 | exact_term | ["queue"] |
| 架构 | exact_term | ["architecture"] |
| 你好 | exact_term | ["hello"] |
| 谢谢 | exact_term | ["thank you", "thanks"] |
| 英语 | exact_term | ["English"] |
| 帮助 | exact_term | ["help", "assist"] |
| 算法 | exact_term | ["algorithm"] |
| 输入法 | exact_term | ["input method"] |
| 兜底 | exact_term | ["fallback"] |
| 里程碑 | exact_term | ["milestone"] |
| 语义 | exact_term | ["semantics"] |
| 上下文 | exact_term | ["context"] |
| 颗粒度 | exact_phrase | ["granularity"] |
| 先对齐一下 | exact_phrase | ["let's align first"] |
| 拉齐认知 | exact_phrase | ["align understanding"] |
| 小步快跑 | exact_phrase | ["iterate quickly in small steps"] |
| 形成闭环 | exact_phrase | ["close the loop"] |
| 拆解问题 | exact_phrase | ["break down the problem"] |
| 兜底方案 | exact_phrase | ["fallback plan"] |
| 关键路径 | exact_phrase | ["critical path"] |
| 技术债 | exact_phrase | ["technical debt"] |
| 用户画像 | exact_phrase | ["user persona"] |
| 冷启动 | exact_term | ["cold start"] |
| 灰度发布 | exact_phrase | ["canary release"] |
| 复盘总结 | exact_phrase | ["retrospective summary"] |
| 向上管理 | exact_phrase | ["managing up"] |
| 横向对比 | exact_phrase | ["side-by-side comparison"] |
| 需求评审 | exact_phrase | ["requirement review"] |
