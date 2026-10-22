# M26 OPUS-MT vs Hy-MT2 Comparison

- 日期：2026-10-22
- 机器：当前 Apple Silicon 开发机
- 范围：同一进程、同一 45 条 word/phrase/sentence 语料
- 目的：判断 OPUS-MT 是否能作为一栏和默认路径的更快替代

## 1. 方法

新增实验工具：

```bash
swift build --package-path Tools/GlintEval \
  --product TranslationCompare
```

测试流程：

1. 同时加载 Hy-MT2 与 OPUS-MT；
2. 两个模型分别 warmup；
3. 每条语料按 Hy-MT2、OPUS-MT 交错执行；
4. 丢弃首轮，使用后续 2 轮中位数；
5. 使用小写、去标点和去常见冠词/介词后的 token F1 作为初筛，
   并保留逐条译文供人工判断。

## 2. 结果

| 指标 | Hy-MT2 1.8B | OPUS-MT int8 |
|---|---:|---:|
| 加载 | 937.0ms | 70.2ms |
| warmup | 133.6ms | 16.8ms |
| p50 | 65.1ms | 17.8ms |
| p95 | 135.0ms | 40.0ms |
| 规范化精确率 | 35.6% | 15.6% |
| 平均 token F1 | 0.547 | 0.357 |

OPUS-MT 的 p50 约快 `3.7x`，p95 约快 `3.4x`。MLX 需要显式加载约
0.94 秒，但生产 App 已在启动阶段完成加载和 warmup，不把该成本计入单次候选。

## 3. 质量差异

OPUS-MT 的短句整体可用，但单词和短语存在明显误译：

| 输入 | OPUS-MT | Hy-MT2 |
|---|---|---|
| 算法 | Algebra | Algorithm |
| 复盘 | Duplicate | Review |
| 迭代 | Interrogate | Iteration |
| 拉齐认知 | Ratsy knows it. | Lazic cognition |
| 小步快跑 | Run! Run! | Take small steps forward |
| 用户画像 | User Images | User profiles |
| 复盘总结 | Remix Summary | Review and summarize |

Hy-MT2 也有错误，例如“拉齐认知”没有可靠翻译，但总体明显更稳定。

## 4. 结论

- 不把 OPUS-MT 设为默认，也不在模型优先模式下静默替换 Hy-MT2；
- OPUS-MT 可以继续作为用户显式选择的轻量模型；
- 如果后续需要“速度优先”预设，应明确标注质量取舍；
- 一栏模式使用 OPUS-MT 可以显著缩短整行耗时，但当前质量损失不适合默认开启；
- 不再继续通过批量提示优化 Hy-MT2 一栏，本次结果支持维持现有单条并发路径。
