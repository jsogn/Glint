# Glint M11 Runtime Lifecycle Validation

- 日期：2026-10-20
- 机器：Apple M4 Pro、48GB、macOS 26.6.2（25G83）
- App：Debug arm64
- 目标：验证更新、重启和启动脚本不会继续运行旧实例，也不会在模型尚未就绪时提前返回成功

## 1. Readiness Protocol

`scripts/run.sh` 为每次启动生成一次性 UUID，通过
`--readiness-token` 传给 App。App 完成 OCR 配置和翻译运行时准备，并真正启动
监控后，将同一 UUID 写入：

```text
~/Library/Application Support/Glint/runtime-ready
```

脚本只有同时确认“仅有一个 Glint 进程”和“ready 文件中的 token 与本次启动一致”
才返回成功；否则最多等待 45 秒后失败。

## 2. Three-Cycle Restart Test

连续执行三次 `./scripts/run.sh`：

| 轮次 | 旧 PID | 新 PID | 脚本耗时 | Token 轮换 |
| --- | ---: | ---: | ---: | --- |
| 1 | 5560 | 16324 | 12s | 通过 |
| 2 | 16324 | 16553 | 7s | 通过 |
| 3 | 16553 | 16787 | 6s | 通过 |

每轮结束后均只有一个 Glint 进程，且新 PID 与旧 PID 不同。

## 3. Automated Validation

- `./scripts/test.sh`：通过，共 75 个测试，0 失败；
- Debug arm64 构建：通过；
- 稳定签名验证：通过；
- 词典查询：通过；
- 句翻译与 CTranslate2：通过；
- MLX Hy-MT2 模型加载：通过，测试时加载约 0.95s；
- Apple Vision + PP-OCRv6 配置：通过；
- OCR 内置候选样本：识别为“你好”；
- 屏幕录制和辅助功能：均为 `true`。

运行期抽样：

- 启动约 11 秒后：CPU 约 0.1%，RSS 约 1.1GB；
- 启动约 53 秒后：CPU 接近 0%，RSS 约 1.35GB。

以上只是两个资源快照，不构成长期内存泄漏结论。

## 4. Manual Acceptance

Codex 的自动输入不会经过苹果输入法的组合输入流程，因此无法可靠生成真实候选栏。

用户已在空白 TextEdit 文稿中使用“Pinyin – Simplified”完成真实输入，候选识别和
HUD 翻译显示均正常，没有复现更新后的首次失效问题。

以下场景仍属于后续兼容性覆盖：

- Safari、Chrome、微信等应用中的真实苹果拼音输入和 HUD；
- 单词、短语、短句和快速切换候选；
- 密码框、安全输入和全屏应用；
- 睡眠唤醒、多显示器及切换输入源。
