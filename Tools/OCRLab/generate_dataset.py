#!/usr/bin/env python3
from __future__ import annotations

import json
import random
import shutil
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "Tools/OCRLab/data"
IMAGES = DATA / "images"
MANIFEST = DATA / "manifest.json"
REAL_SAMPLE = ROOT / "Resources/Samples/sample-candidate-bar.png"

TERMS = """
你好 中国 我们 时间 工作 学习 生活 世界 朋友 今天
明天 昨天 现在 以后 问题 方法 结果 开始 结束 继续
完成 重要 简单 复杂 清楚 正确 错误 快速 稳定 翻译
词典 模型 输入 文字 语言 英语 中文 苹果 电脑 软件
系统 网络 数据 文件 项目 产品 设计 开发 测试 用户
功能 设置 显示 位置 延迟 背景 透明 候选 单词 句子
记忆 目标 计划 过程 方式 内容 信息 技术 应用 平台
本地 离线 在线 接口 下载 安装 更新 版本 权限 隐私
安全 速度 质量 自然 准确 风格 状态 能力 经验 建议
分析 选择 支持 导入 导出 成功 失败 欢迎 谢谢 再见
""".split()

FONT_PATHS = [
    Path("/System/Library/Fonts/STHeiti Medium.ttc"),
    Path("/System/Library/Fonts/Hiragino Sans GB.ttc"),
]


def blue_crop(image: np.ndarray) -> Image.Image:
    blue = (
        (image[:, :, 0] > 120)
        & ((image[:, :, 0].astype(int) - image[:, :, 2]) > 40)
        & ((image[:, :, 0].astype(int) - image[:, :, 1]) > 15)
    ).astype(np.uint8)
    count, _, stats, _ = cv2.connectedComponentsWithStats(blue, 4)
    candidates = []
    for index in range(1, count):
        x, y, width, height, area = stats[index]
        if (
            area >= 400
            and width >= 30
            and height >= 16
            and width >= height
            and width <= height * 6
        ):
            candidates.append((area, x, y, width, height))
    if not candidates:
        raise RuntimeError("blue candidate capsule not found")
    _, x, y, width, height = max(candidates)
    pad = 6
    rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
    crop = Image.fromarray(rgb).crop(
        (
            max(0, x - pad),
            max(0, y - pad),
            min(rgb.shape[1], x + width + pad),
            min(rgb.shape[0], y + height + pad),
        )
    )
    return crop


def save_variant(
    image: Image.Image,
    name: str,
    ground_truth: str,
    group: str,
    variant: str,
    records: list[dict],
) -> None:
    path = IMAGES / f"{name}.png"
    image.save(path)
    records.append(
        {
            "id": name,
            "path": str(path),
            "text": ground_truth,
            "group": group,
            "variant": variant,
        }
    )


def render_candidate(
    text: str,
    width_scale: float = 1.0,
    font_path: Path = FONT_PATHS[0],
    font_size: int = 24,
    background: tuple[int, int, int] = (245, 245, 245),
    blur_radius: float = 0.0,
) -> Image.Image:
    font = ImageFont.truetype(str(font_path), font_size, index=0)
    index_font = ImageFont.truetype(str(font_path), max(12, font_size // 2))
    text_box = font.getbbox(text)
    text_width = text_box[2] - text_box[0]
    text_height = text_box[3] - text_box[1]
    index_width = index_font.getbbox("1")[2]
    pill_height = max(font_size + 18, text_height + 16)
    pill_width = max(48, 12 + index_width + 8 + text_width + 16)
    canvas_width = pill_width + 20
    canvas_height = pill_height + 20
    image = Image.new("RGB", (canvas_width, canvas_height), background)
    draw = ImageDraw.Draw(image)
    left = (canvas_width - pill_width) // 2
    top = (canvas_height - pill_height) // 2
    right = left + pill_width
    bottom = top + pill_height
    draw.rounded_rectangle(
        (left, top, right, bottom),
        radius=pill_height // 2,
        fill=(0, 105, 245),
    )
    draw.text(
        (left + 12, top + int((pill_height - font_size) / 2)),
        "1",
        font=index_font,
        fill=(255, 255, 255),
    )
    draw.text(
        (
            left + 12 + index_width + 8,
            top + int((pill_height - font_size) / 2 - 2),
        ),
        text,
        font=font,
        fill=(255, 255, 255),
    )
    if blur_radius:
        image = image.filter(ImageFilter.GaussianBlur(blur_radius))
    if width_scale < 1:
        image = image.resize(
            (max(1, int(image.width * width_scale)), max(1, int(image.height * width_scale))),
            Image.Resampling.LANCZOS,
        )
    elif width_scale > 1:
        image = image.resize(
            (int(image.width * width_scale), int(image.height * width_scale)),
            Image.Resampling.LANCZOS,
        )
    return image


def main() -> None:
    if DATA.exists():
        shutil.rmtree(DATA)
    IMAGES.mkdir(parents=True)
    records: list[dict] = []

    sample = cv2.imread(str(REAL_SAMPLE))
    if sample is None:
        raise RuntimeError(f"cannot read {REAL_SAMPLE}")
    real = blue_crop(sample)
    save_variant(real, "real_original", "你好", "real", "original", records)
    save_variant(
        real.resize((real.width * 2, real.height * 2), Image.Resampling.LANCZOS),
        "real_upscale2x",
        "你好",
        "real_augmented",
        "upscale2x",
        records,
    )
    save_variant(
        real.resize(
            (max(1, int(real.width * 0.75)), max(1, int(real.height * 0.75))),
            Image.Resampling.LANCZOS,
        ),
        "real_downscale075",
        "你好",
        "real_augmented",
        "downscale075",
        records,
    )
    save_variant(
        real.filter(ImageFilter.GaussianBlur(0.45)),
        "real_blur",
        "你好",
        "real_augmented",
        "blur",
        records,
    )
    jpeg_path = IMAGES / "real_jpeg75.jpg"
    real.save(jpeg_path, quality=75)
    save_variant(
        Image.open(jpeg_path).convert("RGB"),
        "real_jpeg75",
        "你好",
        "real_augmented",
        "jpeg75",
        records,
    )

    rng = random.Random(20261020)
    variants = [
        (22, 1.0, FONT_PATHS[0], (245, 245, 245), 0.0),
        (28, 1.0, FONT_PATHS[1], (24, 24, 26), 0.0),
        (18, 0.85, FONT_PATHS[0], (245, 245, 245), 0.25),
        (32, 1.15, FONT_PATHS[1], (24, 24, 26), 0.35),
    ]
    for term_index, term in enumerate(TERMS):
        for variant_index, (size, scale, font, background, blur) in enumerate(variants):
            image = render_candidate(
                term,
                width_scale=scale,
                font_path=font,
                font_size=size,
                background=background,
                blur_radius=blur,
            )
            if variant_index == 2:
                image = image.rotate(
                    rng.uniform(-1.5, 1.5),
                    resample=Image.Resampling.BICUBIC,
                    expand=True,
                    fillcolor=background,
                )
            save_variant(
                image,
                f"synthetic_{term_index:03d}_{variant_index}",
                term,
                "synthetic",
                f"v{variant_index}",
                records,
            )

    MANIFEST.write_text(
        json.dumps({"records": records}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"wrote {len(records)} samples to {MANIFEST}")


if __name__ == "__main__":
    main()
