#!/usr/bin/env python3
"""Classify runtime overrides without changing production routing."""

from __future__ import annotations

import argparse
import json
import sqlite3
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OVERRIDES = ROOT / "Resources/Dictionary/overrides.json"
DEFAULT_LEXICON = ROOT / "build/dictionary-core/normalized_lexicon.sqlite3"
DEFAULT_OUTPUT = (
    ROOT / "Tools/DictionaryLab/results/override-classification.json"
)

RETIRE_REASONS = {
    "开发": "develop/build versus issue a receipt or invoice",
    "功能": "feature versus function depends on context",
    "业务": "business versus service depends on context",
    "流程": "process, procedure, and workflow are context-dependent",
    "方案": "solution, plan, and approach are context-dependent",
    "问题": "issue, problem, and question are different senses",
    "结果": "result or outcome versus the conjunction 'as a result'",
    "目标": "goal or objective versus a physical target",
    "上线": "launch, go live, and become available depend on context",
    "发布": "product release versus publishing a post",
    "部署": "deploy as a verb versus deployment as a noun",
    "配置": "configuration as a noun versus configure as a verb",
    "安全": "security or safety as a noun versus safe as an adjective",
    "输入": "input as a noun versus enter or type as a verb",
    "输出": "output as a noun versus output or export as a verb",
    "翻译": "translation as a noun versus translate as a verb",
    "实现": "implement versus realize or achieve",
    "优化": "optimize as a verb versus optimization as a noun",
    "重构": "refactor versus restructure depends on context",
    "处理": "handle, process, deal with, and treatment are distinct",
    "运行": "run, operate, execute, and function are context-dependent",
    "结构": "structure, composition, and organization are distinct",
    "接口": "software API or interface versus a physical port",
    "字段": "field versus database column depends on the product context",
    "缓存": "cache as a noun versus cache or caching as an action",
    "并发": "concurrency as a noun versus concurrent as an adjective",
    "延迟": "latency or delay as a noun versus delay as a verb",
    "依赖": "dependency as a noun versus depend or rely as a verb",
    "组件": "component versus widget depends on the UI context",
    "文档": "documentation versus a single document",
    "验收": "acceptance as a noun versus inspect and accept as a verb",
    "灰度": "canary release versus grayscale image processing",
    "计算": "calculate as a verb versus calculation as a noun",
    "复盘": "retrospective versus review or analyze footage",
    "对齐": "align as a verb versus alignment as a noun",
    "迭代": "iterate as a verb versus iteration as a noun",
    "需求": "user requirements versus market demand",
    "场景": "business use case or scenario versus a film scene",
    "指标": "metric versus indicator depends on context",
    "落地": "implementation versus physically landing",
    "拆分": "break down a task versus split off a business",
    "收敛": "converge as a verb versus convergence as a noun",
    "权衡": "trade-off as a noun versus weigh as a verb",
    "推理": "reasoning as a noun versus infer as a verb",
}

BLOCKED_TERM_ACTIONS = {
    "打": {
        "action": "remove_block",
        "reason": "common legitimate character and verb with many senses",
    },
    "尼": {
        "action": "remove_block",
        "reason": "legitimate character and noun; exact fragment filtering is safer",
    },
    "你号": {
        "action": "keep_exact_invalid_fragment",
        "reason": "nonstandard fragment, but this policy must remain separate from lexical ranking",
    },
}
POLICY_BLOCKED_TERMS = ("你号",)


def load_overrides(path: Path) -> dict[str, list[str]]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    result: dict[str, list[str]] = {}
    values = {
        **raw.get("retiredOverrides", {}),
        **raw.get("overrides", {}),
    }
    for term, value in values.items():
        result[term] = [value] if isinstance(value, str) else value
    return result


def classify(
    overrides_path: Path,
    lexicon_path: Path,
) -> dict:
    raw = json.loads(overrides_path.read_text(encoding="utf-8"))
    overrides = load_overrides(overrides_path)
    retired_terms = set(raw.get("retiredOverrides", {}))
    connection = sqlite3.connect(lexicon_path)
    try:
        entries = []
        for term, values in overrides.items():
            sense_count, reading_count = connection.execute(
                """
                SELECT COUNT(*), COUNT(DISTINCT pinyin)
                FROM lexicon_entries
                WHERE headword = ? OR traditional = ?
                """,
                (term, term),
            ).fetchone()
            if term in retired_terms or term in RETIRE_REASONS:
                action = "retire_runtime"
                scope = "none"
                reason = RETIRE_REASONS[term]
            elif sense_count == 0:
                action = "fallback_only"
                scope = "exact_phrase"
                reason = (
                    "not present as a normalized dictionary headword; "
                    "allow only as an exact low-priority fallback"
                )
            else:
                action = "fallback_only"
                scope = "exact_term"
                reason = (
                    "stable domain or general mapping; never outrank the "
                    "model or a ranked dictionary result"
                )
            entries.append(
                {
                    "term": term,
                    "current_override": values,
                    "action": action,
                    "scope": scope,
                    "reason": reason,
                    "dictionary_senses": sense_count,
                    "dictionary_readings": reading_count,
                    "test_role": "fixture_only",
                }
            )
    finally:
        connection.close()

    actions = Counter(entry["action"] for entry in entries)
    missing_retire = sorted(set(RETIRE_REASONS) - set(overrides))
    return {
        "schema_version": 1,
        "reviewed_at": datetime.now(timezone.utc).isoformat(),
        "source": str(overrides_path),
        "rules": {
            "retire_runtime": (
                "remove precedence from runtime; model and preserved senses "
                "must decide"
            ),
            "fallback_only": (
                "allowed only after model and ranked dictionary paths fail; "
                "never receives a forcing score"
            ),
            "fixture_only": (
                "historical expected values remain tests, not runtime truth"
            ),
        },
        "summary": {
            "override_count": len(entries),
            "retire_runtime": actions["retire_runtime"],
            "fallback_only": actions["fallback_only"],
            "exact_phrase_fallbacks": sum(
                entry["scope"] == "exact_phrase" for entry in entries
            ),
            "blocked_term_count": len(POLICY_BLOCKED_TERMS),
        },
        "missing_retire_terms": missing_retire,
        "blocked_terms": [
            {
                "term": term,
                **BLOCKED_TERM_ACTIONS.get(
                    term,
                    {
                        "action": "review",
                        "reason": "no classification decision",
                    },
                ),
            }
            for term in POLICY_BLOCKED_TERMS
        ],
        "entries": entries,
    }


def render_markdown(result: dict) -> str:
    summary = result["summary"]
    lines = [
        "# Runtime Override Audit",
        "",
        f"- Date: {result['reviewed_at']}",
        f"- Overrides: {summary['override_count']}",
        f"- Retire from runtime: {summary['retire_runtime']}",
        f"- Fallback only: {summary['fallback_only']}",
        f"- Exact-phrase fallbacks: {summary['exact_phrase_fallbacks']}",
        "",
        "## Blocklist",
        "",
        "| Term | Action | Reason |",
        "| --- | --- | --- |",
    ]
    for entry in result["blocked_terms"]:
        lines.append(
            f"| {entry['term']} | {entry['action']} | {entry['reason']} |"
        )
    lines.extend(
        [
            "",
            "## Retire From Runtime",
            "",
            "| Term | Current value | Reason |",
            "| --- | --- | --- |",
        ]
    )
    for entry in result["entries"]:
        if entry["action"] != "retire_runtime":
            continue
        value = json.dumps(
            entry["current_override"],
            ensure_ascii=False,
        )
        lines.append(f"| {entry['term']} | {value} | {entry['reason']} |")
    lines.extend(
        [
            "",
            "## Fallback Only",
            "",
            "These entries may remain as exact, low-priority fallback data. "
            "They must never force a result ahead of the model or ranked "
            "dictionary output.",
            "",
            "| Term | Scope | Current value |",
            "| --- | --- | --- |",
        ]
    )
    for entry in result["entries"]:
        if entry["action"] != "fallback_only":
            continue
        value = json.dumps(
            entry["current_override"],
            ensure_ascii=False,
        )
        lines.append(
            f"| {entry['term']} | {entry['scope']} | {value} |"
        )
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--overrides", default=str(DEFAULT_OVERRIDES))
    parser.add_argument("--lexicon", default=str(DEFAULT_LEXICON))
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    result = classify(
        Path(args.overrides),
        Path(args.lexicon),
    )
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    output.with_suffix(".md").write_text(
        render_markdown(result) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(result["summary"], ensure_ascii=False, indent=2))
    print(f"saved {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
