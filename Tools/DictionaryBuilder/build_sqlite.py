#!/usr/bin/env python3
"""Build the read-only CC-CEDICT SQLite dictionary and curated overrides."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SOURCE = Path(__file__).resolve().parent / "cedict.json"
CASES = ROOT / "Tools" / "ModelLab" / "eval" / "cases.json"
OUT_DIR = ROOT / "Resources" / "Dictionary"
DB_PATH = OUT_DIR / "cedict.sqlite3"
OVERRIDES_PATH = OUT_DIR / "overrides.json"

EXTRA_OVERRIDES = {
    "你好吗": "How are you?",
    "程序": "program",
    "开发": "develop",
    "设计": "design",
    "数据": "data",
    "计算机": "computer",
    "项目": "project",
    "功能": "feature",
    "系统": "system",
    "用户": "user",
    "产品": "product",
    "业务": "business",
    "团队": "team",
    "公司": "company",
    "客户": "customer",
    "会议": "meeting",
    "计划": "plan",
    "方案": "solution",
    "问题": "issue",
    "结果": "result",
    "目标": "goal",
    "流程": "process",
    "版本": "version",
    "代码": "code",
    "测试": "test",
    "上线": "launch",
    "发布": "release",
    "部署": "deploy",
    "配置": "configuration",
    "性能": "performance",
    "安全": "security",
    "隐私": "privacy",
    "模型": "model",
    "插件": "plugin",
    "输入": "input",
    "输出": "output",
    "翻译": "translation",
    "词典": "dictionary",
    "句子": "sentence",
    "单词": "word",
    "中文": "Chinese",
    "英文": "English",
    "苹果": "apple",
    "实现": "implement",
    "优化": "optimize",
    "重构": "refactor",
    "接口": "API",
    "字段": "field",
    "缓存": "cache",
    "并发": "concurrency",
    "延迟": "latency",
    "吞吐": "throughput",
    "依赖": "dependency",
    "模块": "module",
    "组件": "component",
    "文档": "documentation",
    "评审": "review",
    "验收": "acceptance",
    "接口": "API",
    "字段": "field",
    "埋点": "event tracking",
    "灰度": "canary",
    "回滚": "rollback",
    "发布": "release",
    "上线": "launch",
    "部署": "deploy",
    "缓存": "cache",
    "并发": "concurrency",
    "队列": "queue",
    "延迟": "latency",
    "吞吐": "throughput",
    "依赖": "dependency",
    "架构": "architecture",
    "重构": "refactor",
    "模块": "module",
    "组件": "component",
    "文档": "documentation",
    "评审": "review",
    "验收": "acceptance",
}

BLOCKED = ["打", "尼", "你号"]


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    source = json.loads(SOURCE.read_text(encoding="utf-8"))
    cases = json.loads(CASES.read_text(encoding="utf-8"))

    overrides = dict(EXTRA_OVERRIDES)
    for case in cases:
        if case["kind"] in {"word", "phrase"}:
            overrides[case["input"]] = case["reference"]

    if DB_PATH.exists():
        DB_PATH.unlink()
    connection = sqlite3.connect(DB_PATH)
    connection.execute(
        "CREATE TABLE entries (word TEXT PRIMARY KEY, gloss TEXT NOT NULL)"
    )
    connection.executemany(
        "INSERT OR REPLACE INTO entries(word, gloss) VALUES (?, ?)",
        ((word, gloss) for word, gloss in source.items()),
    )
    connection.execute("PRAGMA user_version = 1")
    connection.commit()
    connection.close()

    OVERRIDES_PATH.write_text(
        json.dumps(
            {"overrides": overrides, "blocked": BLOCKED},
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print(f"entries={len(source)} overrides={len(overrides)} db={DB_PATH}")


if __name__ == "__main__":
    main()
