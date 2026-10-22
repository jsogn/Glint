# M24 Translation Latency Measurement

- 日期：2026-10-22
- 目标：为真实苹果拼音输入建立可重复、默认脱敏的端到端延迟记录
- 范围：候选变化、停留确认、翻译完成和 HUD 实际显示

## 1. 时间点

一次候选 revision 按以下时间点记录：

1. `phase=dwell`
   - 候选首次被识别为发生变化的时间，代表采样起点；
   - `dwell_ms` 是采样起点到满足停留阈值的时间。
2. `phase=selected_ready` 或 `phase=row_ready`
   - 翻译结果已发给 App 层；
   - `route_ms` 是翻译路由耗时；
   - `total_to_selected_ms` / `total_to_ready_ms` 是采样起点到结果完成；
   - `attempts` 和 `cancelled` 是本次监控会话累计值。
3. `phase=selected_visible` 或 `phase=row_visible`
   - HUD 已完成内容更新并调用显示；
   - 一栏渐进批次中的完整候选槽位仍记为 `selected_visible`，只有完整行结果
     才记为 `row_visible`；
   - `event_to_visible_ms` 是 App 收到候选变化事件到 HUD 显示调用完成的耗时；
   - 与第 2 项相加可近似得到采样起点到 HUD 可见的总延迟。
4. `phase=warmup`
   - 当前 MLX 模型静默 warmup 耗时。

日志不包含候选原文、翻译结果、输入框正文、API Key 或输入历史。

## 2. 采集命令

在真实苹果拼音输入前启动：

```bash
/usr/bin/log stream \
  --info \
  --style compact \
  --predicate 'subsystem == "com.local.glint" AND eventMessage CONTAINS "perf latency"'
```

测试结束后也可以回看：

```bash
/usr/bin/log show \
  --last 30m \
  --info \
  --style compact \
  --predicate 'subsystem == "com.local.glint" AND eventMessage CONTAINS "perf latency"'
```

## 3. 验收矩阵

每个场景至少重复 20 次，并记录 p50/p95：

| 场景 | 设置 |
|---|---|
| 快速输入 | 候选间隔小于停留下限，预期不触发模型 |
| 选中 + 缓存命中 | 同一候选重复停顿 |
| 选中 + 词典命中 | 常见单词或短语 |
| 选中 + Hy-MT2 | 首次出现的短句 |
| 一栏 + 3 项 | 单行候选完整翻译 |
| 一栏 + 6 项 | 单行候选完整翻译 |
| 一栏 + 9 项 | 单行上限 |
| OPUS-MT | 与 Hy-MT2 相同输入对照 |

历史实验曾比较 `50ms` 和 `80ms`；常规下限现固定为 `80ms`。

## 4. 首次真实基线

2026-10-22 在当前 Apple Silicon 开发机上采集：

- 配置：`selected`、`modelFirst`、Hy-MT2、候选停留 `80ms`；
- 样本：9 组关联的 HUD 可见事件；
- 实际停留：p50 `84.738ms`，p95 `88.973ms`；
- 候选变化事件到 HUD 显示：p50 `162.125ms`，p95 `190.621ms`；
- 模型路径路由：7 组，p50 `84.447ms`，p95 `104.810ms`；
- 缓存命中路径：3 组，p50 `0.156ms`。

本基线样本较少，只用于确认链路与量级，不作为跨机器的固定性能承诺。

同一会话随后切换到 `row + modelFirst + 80ms`：

- 样本：13 组完整一栏可见事件；
- 选中项可见：p50 `89.956ms`，p95 `378.205ms`；
- 完整一栏可见：p50 `234.728ms`，p95 `528.814ms`；
- 模型路径整行路由：8 组，p50 `305.663ms`，p95 `437.269ms`；
- 整行缓存的选中项与完整栏都约 `85–103ms`；
- 选中项缓存、其余项走模型时，选中项约 `87–99ms` 可见，但完整行仍可能等待
  `394ms` 左右。

## 5. 判读规则

- `phase=dwell` 的 `dwell_ms` 应接近用户设置，不能在固定轮询边界上产生明显长尾。
- 一栏模式下，`selected_visible` 应先于 `row_visible` 出现。
- `selected_visible` 与 `row_visible` 的 `visible_items` 应保持相同槽位数。
- `row_visible - selected_visible` 反映整行补全时间。
- `cancelled` 持续增长但 `selected_visible` 很少出现，说明停留下限过于激进。
- 按 revision 对齐日志；不同 revision 的 ready 和 visible 事件不得拼接。
