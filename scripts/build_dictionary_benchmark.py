#!/usr/bin/env python3
"""Build a repeatable dictionary quality case set.

The cases are intentionally selected, not generated from model output.
Expected answers may contain several acceptable translations.
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OVERRIDES = ROOT / "Resources/Dictionary/overrides.json"
OUTPUT = ROOT / "Resources/Evaluation/dictionary-benchmark.json"

GENERAL = {
    "你好": ["hello", "hi"],
    "谢谢": ["thank you", "thanks"],
    "世界": ["world"],
    "时间": ["time"],
    "朋友": ["friend"],
    "学习": ["study", "learn"],
    "工作": ["work", "job"],
    "今天": ["today"],
    "喜欢": ["like", "enjoy"],
    "需要": ["need", "require"],
    "可以": ["can", "may"],
    "因为": ["because"],
    "但是": ["but", "however"],
    "问题": ["problem", "issue", "question"],
    "结果": ["result", "outcome"],
    "目标": ["goal", "objective", "target"],
    "方法": ["method", "way"],
    "重要": ["important"],
    "生活": ["life"],
    "城市": ["city"],
    "国家": ["country"],
    "父母": ["parents"],
    "孩子": ["child", "children"],
    "学校": ["school"],
    "老师": ["teacher"],
    "学生": ["student"],
    "语言": ["language"],
    "英语": ["English"],
    "中文": ["Chinese"],
    "帮助": ["help", "assist"],
}

AMBIGUOUS = {
    "设计": ["design", "plan"],
    "处理": ["handle", "process", "deal with"],
    "运行": ["run", "operate", "function"],
    "结构": ["structure", "composition"],
    "复杂": ["complex", "complicated"],
    "程序": ["program", "procedure", "process"],
    "开发": ["develop", "development", "exploit"],
    "对齐": ["align", "alignment"],
    "权衡": ["trade-off", "balance"],
    "复盘": ["retrospective", "review"],
}

BLOCKED = ["你号"]


def main() -> None:
    overrides_payload = json.loads(OVERRIDES.read_text(encoding="utf-8"))
    overrides = {
        **overrides_payload.get("retiredOverrides", {}),
        **overrides_payload.get("overrides", {}),
    }
    cases = []
    for text, expected in GENERAL.items():
        cases.append({"text": text, "category": "general", "expected": expected})
    for text, expected in AMBIGUOUS.items():
        cases.append({"text": text, "category": "ambiguous", "expected": expected})
    for text in BLOCKED:
        cases.append({"text": text, "category": "blocked", "expected": []})

    for text, value in overrides.items():
        if text in GENERAL or text in AMBIGUOUS:
            continue
        values = [value] if isinstance(value, str) else value
        category = "phrase" if " " in text or len(text) >= 4 else "technical"
        cases.append({"text": text, "category": category, "expected": values})

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(
        json.dumps(cases, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"wrote {len(cases)} cases to {OUTPUT}")


if __name__ == "__main__":
    main()
