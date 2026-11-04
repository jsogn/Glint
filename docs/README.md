# Glint 文档

这里只保留能指导当前代码、验证、发布或资产使用的文档：

- [架构设计](ARCHITECTURE.md)：模块职责、依赖方向、数据流和技术边界。
- [通用输入法与候选运行规则](GENERIC-INPUT-METHOD-ADAPTATION.md)：候选结构、
  Profile、探测缓存、轮询与显示规则和 AX 资源边界。
- [macOS 兼容性](MACOS-COMPATIBILITY.md)：最低系统、运行时版本和兼容性验证。
- [发布计划](RELEASE-PLAN.md)：GitHub 无签名分发、发布门禁和可选签名升级。
- [AX 候选验证](AX-CANDIDATE-VALIDATION.md)：候选读取结构、性能证据和已知边界。
- [Rime 输入法支持](SQUIRREL-CANDIDATE-BRIDGE.md)：Rime Lua 候选适配器、
  安装流程和隔离边界。
- [词典来源](DICTIONARY-SOURCES.md)：内置词典的来源、版本和许可证。
- [模型评测](MODEL-EVALUATION.md)：翻译路由、真实模型对照和质量结论。
- 文档资产：`assets/glint-logo.png` 用于 README 标识，
  `assets/glint-video-cover-clean.jpg` 用于产品介绍和演示视频封面。替换展示图时
  同步更新引用并删除旧资产；新增截图必须与引用位于同一次变更。

已完成的实施计划、设计稿、专项调研和重复记录不进入这里；需要追溯时从 Git 历史
恢复。架构决策只维护在[架构设计](ARCHITECTURE.md)的 ADR 摘要中。
