#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 ADBManager 应用图标（v2 精致版）。
设计原则：
  - 元素居中缩小，四周留足内边距（视觉不溢出，与其他 app 图标大小协调）
  - 深蓝渐变底 + 圆角矩形（标准 macOS 连续圆角，~22.36% 黄金比例）
  - 简洁的终端 >_ 符号 + 绿色光标块（无多余装饰点）
  - 光标带微发光效果，提升质感
仅依赖 Pillow + macOS iconutil。
"""
import os
import subprocess
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ICONSET = os.path.join(HERE, "ADBManager.iconset")
ICNS = os.path.join(HERE, "ADBManager.icns")
SIZES = [16, 32, 64, 128, 256, 512, 1024]


def make_icon(s: int) -> Image.Image:
    """绘制单尺寸图标。核心区域占图幅 ~50%，四周留白充裕。"""
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # ── 背景：深蓝渐变 + 圆角遮罩（macOS 标准连续圆角） ──
    # 关键：圆角矩形【不铺满整个画布】，四周留透明边距，
    # 这样图标（dock 与菜单栏）视觉上不溢出、与其他 app 协调。
    top = (29, 78, 216)    # #1d4ed8 鲜蓝（比 v1 更亮更现代）
    bot = (15, 23, 42)     # #0f172a 近墨蓝
    pad = int(s * 0.10)               # 四周各留 10% 透明边距
    t0, t1 = pad, s - pad
    tile_w = s - 2 * pad
    bg = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bg)
    for y in range(t0, t1):
        t = (y - t0) / max(1, tile_w - 1)
        col = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
        bd.line([(t0, y), (t1, y)], fill=col + (255,))

    # macOS 标准圆角（squircle 近似）：radius ≈ 22.36% × 瓦片宽
    r = int(tile_w * 0.2236)
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle([t0, t0, t1, t1], radius=r, fill=255)
    bg.putalpha(mask)
    img = Image.alpha_composite(img, bg)

    # ── 内边距：核心绘图区只占中间 ~52% ──
    margin = s * 0.24          # 四周各留 24% 空间
    inner_cx = s * 0.5         # 内容区中心 X
    inner_cy = s * 0.5         # 内容区中心 Y
    scale = s * 0.18           # 基准缩放（> 笔画宽度以此为参考）

    d = ImageDraw.Draw(img)
    lw = max(2, int(scale * 0.40))   # 主线条宽

    # 终端 ">_" 折线（白色，简洁）
    p1 = (inner_cx - scale * 0.85, inner_cy - scale * 0.65)
    p2 = (inner_cx + scale * 0.70, inner_cy)
    p3 = (inner_cx - scale * 0.85, inner_cy + scale * 0.65)
    for seg, end in ((p1, p2), (p2, p3)):
        d.line([seg, end], fill=(255, 255, 255, 245), width=lw, joint="curve")
        # 端点圆润
        d.ellipse([seg[0] - lw/2, seg[1] - lw/2, seg[0] + lw/2, seg[1] + lw/2],
                  fill=(255, 255, 255, 245))
    d.ellipse([p3[0] - lw/2, p3[1] - lw/2, p3[0] + lw/2, p3[1] + lw/2],
              fill=(255, 255, 255, 245))

    # 绿色光标块（终端闪烁光标感，比 v1 小且位置精确）
    cw = scale * 0.55
    ch = scale * 0.75
    cx0 = inner_cx + scale * 0.85
    cy0 = inner_cy - ch * 0.15
    d.rectangle([cx0, cy0, cx0 + cw, cy0 + ch],
                fill=(74, 222, 128, 255))   # tailwind green-400

    # 微弱外发光（光标周围淡淡绿晕，提升精致感）
    if s >= 64:  # 小尺寸跳过，无意义
        glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        gd = ImageDraw.Draw(glow)
        glow_r = cw * 0.8
        gd.ellipse([cx0 + cw/2 - glow_r, cy0 + ch/2 - glow_r,
                    cx0 + cw/2 + glow_r, cy0 + ch/2 + glow_r],
                   fill=(74, 222, 128, 35))
        img = Image.alpha_composite(img, glow)

    return img


def main() -> None:
    os.makedirs(ICONSET, exist_ok=True)
    cache = {}
    for s in SIZES:
        cache[s] = make_icon(s)

    # 标准 iconset 命名（含 @2x 高倍图）
    cache[16].save(os.path.join(ICONSET, "icon_16x16.png"))
    cache[32].save(os.path.join(ICONSET, "icon_16x16@2x.png"))
    cache[32].save(os.path.join(ICONSET, "icon_32x32.png"))
    cache[64].save(os.path.join(ICONSET, "icon_32x32@2x.png"))
    cache[128].save(os.path.join(ICONSET, "icon_128x128.png"))
    cache[256].save(os.path.join(ICONSET, "icon_128x128@2x.png"))
    cache[256].save(os.path.join(ICONSET, "icon_256x256.png"))
    cache[512].save(os.path.join(ICONSET, "icon_256x256@2x.png"))
    cache[512].save(os.path.join(ICONSET, "icon_512x512.png"))
    cache[1024].save(os.path.join(ICONSET, "icon_512x512@2x.png"))

    print("iconset generated (v2精致版)")
    subprocess.run(["iconutil", "--convert", "icns", "--output", ICNS, ICONSET], check=True)
    print("icns generated:", ICNS)


if __name__ == "__main__":
    main()
