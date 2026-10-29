#!/usr/bin/env python3
"""Build a repeatable dictionary quality case set.

The cases are intentionally selected, not generated from model output.
Expected answers may contain several acceptable translations.
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Resources/Evaluation/dictionary-benchmark.json"

GENERAL = {
    "你好": ["hello", "hi"],
    "谢谢": ["thank", "thank you", "thanks"],
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
    "权衡": ["trade-off", "tradeoff", "balance", "weigh"],
}

DAILY = {
    "天气": ["weather"],
    "早上": ["morning"],
    "晚上": ["evening", "night"],
    "昨天": ["yesterday"],
    "明天": ["tomorrow"],
    "现在": ["now"],
    "以前": ["before", "previously", "ago"],
    "以后": ["later", "afterwards"],
    "家庭": ["family"],
    "公司": ["company"],
    "同事": ["colleague", "coworker"],
    "医院": ["hospital"],
    "医生": ["doctor"],
    "健康": ["health", "healthy"],
    "开心": ["happy", "glad", "rejoice", "feel happy"],
    "难过": ["sad", "upset", "feel sad", "feel unwell"],
    "担心": ["worry", "concerned"],
    "希望": ["hope", "wish"],
    "决定": ["decide", "decision"],
    "选择": ["choose", "choice", "select", "pick"],
    "开始": ["start", "begin"],
    "结束": ["end", "finish"],
    "完成": ["complete", "finish"],
    "准备": ["prepare", "ready"],
    "发现": ["discover", "find"],
    "认为": ["think", "believe"],
    "知道": ["know"],
    "明白": ["understand", "clear", "sensible", "obvious"],
    "记得": ["remember"],
    "忘记": ["forget"],
    "回答": ["answer", "reply"],
    "说话": ["speak", "talk"],
    "告诉": ["tell"],
    "购买": ["buy", "purchase"],
    "价格": ["price"],
    "地方": ["place"],
    "房间": ["room"],
    "电脑": ["computer"],
    "手机": ["phone", "mobile phone", "cell phone"],
    "照片": ["photo", "picture", "photograph"],
    "音乐": ["music"],
    "电影": ["movie", "film"],
    "游戏": ["game"],
    "运动": ["exercise", "sport"],
    "休息": ["rest", "break"],
}

TECHNICAL = {
    "数据": ["data"],
    "系统": ["system"],
    "用户": ["user"],
    "产品": ["product"],
    "团队": ["team"],
    "客户": ["customer", "client"],
    "服务": ["service", "serve"],
    "需求": ["requirement", "demand"],
    "版本": ["version"],
    "功能": ["function", "feature"],
    "设置": ["settings", "configuration", "set", "set up"],
    "更新": ["update", "renew", "renovate", "upgrade"],
    "安装": ["install", "installation"],
    "下载": ["download"],
    "上传": ["upload"],
    "错误": ["error", "mistake"],
    "安全": ["safe", "security", "safety"],
    "隐私": ["privacy"],
    "性能": ["performance"],
    "速度": ["speed"],
    "内存": ["memory"],
    "插件": ["plugin"],
    "模型": ["model"],
    "翻译": ["translate", "translation"],
    "词典": ["dictionary"],
    "单词": ["word"],
    "句子": ["sentence"],
    "输入": ["input", "import", "bring in"],
    "输出": ["output"],
    "候选": ["candidate"],
    "配置": ["configuration", "settings", "deploy", "allocation", "configure"],
    "默认": ["default"],
    "自动": ["automatic", "automatically"],
    "手动": ["manual", "manually"],
    "修改": ["modify", "change", "amend", "alter"],
}

AMBIGUOUS_EXTRA = {
    "安排": ["arrange", "schedule"],
    "理解": ["understand", "comprehend"],
    "支持": ["support", "back", "backing"],
    "影响": ["affect", "impact", "influence", "effect"],
    "反映": ["reflect", "reflection", "mirror"],
    "解决": ["solve", "resolve"],
    "执行": ["execute", "execution", "implement", "run", "carry out"],
    "提升": [
        "improve",
        "improvement",
        "promote",
        "lift",
        "elevate",
        "boost",
        "upgrade",
    ],
    "降低": ["reduce", "lower"],
    "满足": ["satisfy", "meet"],
    "申请": ["apply", "application"],
    "发布": ["release", "publish"],
    "审核": ["review", "audit"],
    "适配": ["adapt", "compatibility", "adaptation"],
}

PHRASES = {
    "你好吗": ["how are you"],
    "没问题": ["no problem", "certainly", "sure"],
    "不客气": ["you're welcome", "you are welcome"],
    "对不起": ["sorry", "I'm sorry"],
    "再见": ["goodbye", "bye"],
    "请稍等": ["please wait", "wait a moment"],
    "我不知道": ["I don't know"],
    "你觉得呢": ["what do you think"],
    "谢谢帮助": ["thanks for the help", "thank you for your help"],
    "今天天气不错": ["the weather is nice today"],
    "请打开文件": ["please open the file"],
    "我们需要更多时间": ["we need more time"],
}

MODEL_REQUIRED = {
    "复盘": ["retrospective", "review"],
}

BLOCKED = ["你号", "的的"]

FORBIDDEN = {
    "世界": ["extremely", "super"],
    "朋友": ["large number of retainers"],
    "城市": ["Ipswich"],
    "孩子": ["homerun"],
    "学校": ["dept", "poly"],
    "英语": ["wigg"],
    "明天": ["morn"],
    "团队": ["roadshow"],
    "电脑": ["logon", "dsp"],
    "音乐": ["tonic", "blaring"],
    "词典": ["dick"],
}


def main() -> None:
    cases = []
    for text, expected in GENERAL.items():
        cases.append(case(text, "general", expected))
    for text, expected in AMBIGUOUS.items():
        cases.append(case(text, "ambiguous", expected))
    for text, expected in DAILY.items():
        cases.append(case(text, "daily", expected))
    for text, expected in TECHNICAL.items():
        cases.append(case(text, "technical", expected))
    for text, expected in AMBIGUOUS_EXTRA.items():
        cases.append(case(text, "ambiguous", expected))
    for text, expected in PHRASES.items():
        cases.append(case(text, "phrase", expected))
    for text, expected in MODEL_REQUIRED.items():
        cases.append(case(text, "model", expected))
    for text in BLOCKED:
        cases.append(case(text, "blocked", []))

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(
        json.dumps(cases, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"wrote {len(cases)} cases to {OUTPUT}")


def case(text: str, category: str, expected: list[str]) -> dict[str, object]:
    value: dict[str, object] = {
        "text": text,
        "category": category,
        "expected": expected,
    }
    if text in FORBIDDEN:
        value["forbidden"] = FORBIDDEN[text]
    return value


if __name__ == "__main__":
    main()
