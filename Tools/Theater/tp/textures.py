"""手続き型のテクスチャ（numpy で作り、PNG に保存する）。

繰り返して貼る素材（カーペット・布・木目・グリルなど）は、継ぎ目が出ないよう周期的なノイズで作る。
値は sRGB（0〜1）。画像の行は上から（PNG と同じ）。
"""
import math
import os
import struct
import zlib

import numpy as np


# ---------------------------------------------------------------- 保存
def save_png(path, rgb, alpha=None):
    """(h, w, 3) の sRGB（0〜1）を 8 bit の PNG に保存する。"""
    h, w = rgb.shape[:2]
    px = np.clip(np.round(rgb * 255.0), 0, 255).astype(np.uint8)
    channels = 3
    if alpha is not None:
        px = np.concatenate([px, np.clip(np.round(alpha * 255.0), 0, 255).astype(np.uint8)[..., None]], axis=2)
        channels = 4
    raw = np.concatenate([np.zeros((h, 1), np.uint8), px.reshape(h, w * channels)], axis=1).tobytes()

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    color_type = 6 if channels == 4 else 2
    data = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, color_type, 0, 0, 0))
            + chunk(b"sRGB", b"\x00") + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def lin_to_srgb(c):
    c = np.clip(c, 0.0, None)
    return np.where(c <= 0.0031308, 12.92 * c, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def srgb_to_lin(c):
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.04045, c / 12.92, np.power((c + 0.055) / 1.055, 2.4))


# ---------------------------------------------------------------- ノイズ
def noise(n, freq, seed, aniso=(1.0, 1.0)):
    """周期的な（継ぎ目の無い）ノイズ。freq は 1 周期あたりの山の数のおよそ。-1〜1 に正規化する。"""
    rng = np.random.default_rng(seed)
    f = np.fft.fft2(rng.standard_normal((n, n)))
    ky = np.fft.fftfreq(n)[:, None] * n / aniso[1]
    kx = np.fft.fftfreq(n)[None, :] * n / aniso[0]
    k = np.sqrt(kx * kx + ky * ky)
    f *= np.exp(-(k / max(freq, 1e-3)) ** 2)
    out = np.real(np.fft.ifft2(f))
    out -= out.mean()
    return out / (np.abs(out).max() + 1e-9)


def fbm(n, base_freq, seed, octaves=4, aniso=(1.0, 1.0)):
    total, amp, norm = np.zeros((n, n)), 1.0, 0.0
    for o in range(octaves):
        total += amp * noise(n, base_freq * 2 ** o, seed + o, aniso)
        norm += amp
        amp *= 0.5
    return total / norm


def tint(value, color, contrast):
    """明るさの揺らぎ value（-1〜1）で色 color（sRGB）をばらつかせる。"""
    c = np.asarray(color, dtype=np.float64)[None, None, :]
    return np.clip(c * (1.0 + contrast * value[..., None]), 0.0, 1.0)


# ---------------------------------------------------------------- 素材
def carpet(n=1024):
    """映画館のカーペット：濃い紺灰の毛足に、えんじと金の小さなひし形の柄。"""
    fiber = fbm(n, 180, 11, octaves=3)
    base = tint(fiber, (0.19, 0.19, 0.235), 0.35)
    yy, xx = np.mgrid[0:n, 0:n] / n
    # ひし形の格子（1 周期に 6 つ）
    u = (xx + yy) * 6.0
    v = (xx - yy) * 6.0
    du = np.abs(u - np.round(u))
    dv = np.abs(v - np.round(v))
    line = np.exp(-((np.minimum(du, dv) / 0.018) ** 2))
    dots = np.exp(-((du ** 2 + dv ** 2) / 0.0035))
    centers = np.exp(-(((du - 0.5) ** 2 + (dv - 0.5) ** 2) / 0.002))
    out = base * (1 - 0.35 * line[..., None]) + line[..., None] * np.array([0.20, 0.07, 0.08]) * 0.35
    out = out * (1 - dots[..., None]) + dots[..., None] * np.array([0.42, 0.10, 0.12])
    out = out * (1 - 0.8 * centers[..., None]) + 0.8 * centers[..., None] * np.array([0.55, 0.44, 0.22])
    return np.clip(out * (1 + 0.15 * fiber[..., None]), 0, 1)


def woven(n, color, seed, threads=96, contrast=0.22):
    """織物（縦横の糸）の布。"""
    yy, xx = np.mgrid[0:n, 0:n] / n
    warp = 0.5 + 0.5 * np.cos(2 * math.pi * xx * threads)
    weft = 0.5 + 0.5 * np.cos(2 * math.pi * yy * threads)
    over = (np.floor(xx * threads) + np.floor(yy * threads)) % 2
    weave = np.where(over > 0, warp * 0.7 + 0.3, weft * 0.7 + 0.3)
    slub = fbm(n, 40, seed, octaves=3, aniso=(4.0, 1.0))
    value = (weave - 0.65) * 1.2 + 0.5 * slub
    return tint(value, color, contrast)


def velvet(n, color, seed, contrast=0.35):
    """ビロード（座席・幕）：毛足のむらと、押しつぶれた跡の濃淡。"""
    pile = fbm(n, 260, seed, octaves=2)
    crush = fbm(n, 6, seed + 7, octaves=3)
    return tint(0.35 * pile + 0.65 * crush, color, contrast)


def wood(n=1024, color=(0.36, 0.23, 0.15), seed=5):
    """ウォールナットの突き板（木目は縦＝ V の向き）。"""
    yy, xx = np.mgrid[0:n, 0:n] / n
    warp = fbm(n, 6, seed, octaves=3, aniso=(1.0, 6.0))
    rings = np.sin(2 * math.pi * (xx * 14 + 0.9 * warp))
    streak = fbm(n, 90, seed + 3, octaves=2, aniso=(1.0, 30.0))
    pores = fbm(n, 300, seed + 9, octaves=1, aniso=(1.0, 12.0))
    value = 0.45 * rings + 0.35 * streak + 0.2 * pores
    return tint(value, color, 0.28)


def speckle(n, color, seed, contrast=0.15, freq=200):
    return tint(fbm(n, freq, seed, octaves=3), color, contrast)


def grille(n=256, holes=8):
    """パンチングメタルのグリル（六角の配置の丸穴）。1 周期に holes × holes 個。"""
    yy, xx = np.mgrid[0:n, 0:n] / n
    gx = xx * holes
    gy = yy * holes * 2 / math.sqrt(3)
    row = np.floor(gy)
    cx = gx - np.floor(gx + 0.5 * (row % 2)) - 0.5 * (row % 2)
    cy = (gy - row - 0.5) * math.sqrt(3) / 2
    r = np.sqrt(cx * cx + cy * cy)
    hole = np.clip((0.33 - r) / 0.05, 0, 1)
    metal = speckle(n, (0.13, 0.13, 0.14), 21, 0.1, 80)
    return metal * (1 - hole[..., None]) + hole[..., None] * np.array([0.015, 0.015, 0.017])


def brushed(n, color, seed):
    return tint(fbm(n, 220, seed, octaves=2, aniso=(30.0, 1.0)), color, 0.12)


# ---------------------------------------------------------------- 文字（5 × 7 のドット）
FONT = {
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
    "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
    "D": ["11100", "10010", "10001", "10001", "10001", "10010", "11100"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
    "G": ["01110", "10001", "10000", "10111", "10001", "10001", "01111"],
    "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    "J": ["00111", "00010", "00010", "00010", "00010", "10010", "01100"],
    "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    "N": ["10001", "10001", "11001", "10101", "10011", "10001", "10001"],
}


def text_mask(text, w, h, stroke=0.62):
    """文字列を w × h の範囲に入れた、なめらかな文字の形（0〜1）。ドットを丸い線でつないで描く。"""
    out = np.zeros((h, w))
    cols = 6 * len(text) - 1
    cell = min(w / cols, h / 7.0)
    x0 = (w - cell * cols) / 2
    y0 = (h - cell * 7) / 2
    yy, xx = np.mgrid[0:h, 0:w] + 0.5
    for ci, ch in enumerate(text):
        rows = FONT[ch]
        for ry in range(7):
            for rx in range(5):
                if rows[ry][rx] != "1":
                    continue
                cx = x0 + (ci * 6 + rx + 0.5) * cell
                cy = y0 + (ry + 0.5) * cell
                d = np.maximum(np.abs(xx - cx), np.abs(yy - cy)) / (cell * 0.5 * stroke + 1e-6)
                out = np.maximum(out, np.clip((1.25 - d) * 3.0, 0, 1))
    return out


# ---------------------------------------------------------------- 座席の硬い部品のアトラス（色の帯 + 番号の板）
SEAT_ATLAS_PALETTE = {
    # 名前: (u0, v0, u1, v1)（V は上が 1）
    "shell": (0.0, 0.75, 0.25, 1.0),
    "arm": (0.25, 0.75, 0.5, 1.0),
    "metal": (0.5, 0.75, 0.75, 1.0),
    "hole": (0.75, 0.75, 1.0, 1.0),
    "rubber": (0.0, 0.5, 0.25, 0.75),
    "end": (0.25, 0.5, 0.5, 0.75),
}
SEAT_PLATE_COLS, SEAT_PLATE_ROWS = 8, 8   # 下半分の番号の板（1〜34 の席番号、A〜N の列の文字）


def seat_plate_cell(label_index):
    """番号の板の label_index 番目のマス（u0, v0, u1, v1）。0〜33 が席番号 1〜34、34〜46 が列の文字。"""
    cx = label_index % SEAT_PLATE_COLS
    cy = label_index // SEAT_PLATE_COLS
    du = 1.0 / SEAT_PLATE_COLS
    dv = 0.5 / SEAT_PLATE_ROWS
    return (cx * du, 0.5 - (cy + 1) * dv, (cx + 1) * du, 0.5 - cy * dv)


def seat_atlas(n=1024, labels=()):
    img = np.zeros((n, n, 3))

    def fill(name, rgb, seed):
        u0, v0, u1, v1 = SEAT_ATLAS_PALETTE[name]
        x0, x1 = int(u0 * n), int(u1 * n)
        y0, y1 = int((1 - v1) * n), int((1 - v0) * n)
        img[y0:y1, x0:x1] = speckle(n, rgb, seed, 0.12, 60)[y0:y1, x0:x1]

    fill("shell", (0.075, 0.075, 0.08), 31)
    fill("arm", (0.11, 0.075, 0.06), 32)
    fill("metal", (0.30, 0.30, 0.32), 33)
    fill("hole", (0.02, 0.02, 0.02), 34)
    fill("rubber", (0.04, 0.04, 0.045), 35)
    fill("end", (0.09, 0.07, 0.065), 36)
    # 番号の板：真鍮の地に、濃い色の文字
    for i, text in enumerate(labels):
        u0, v0, u1, v1 = seat_plate_cell(i)
        x0, x1 = int(u0 * n), int(u1 * n)
        y0, y1 = int((1 - v1) * n), int((1 - v0) * n)
        w, h = x1 - x0, y1 - y0
        plate = speckle(max(w, h), (0.62, 0.50, 0.28), 40 + i, 0.08, 20)[:h, :w]
        yy, xx = np.mgrid[0:h, 0:w]
        edge = np.minimum.reduce([xx, yy, w - 1 - xx, h - 1 - yy]) / max(w, h)
        plate *= np.clip(0.75 + edge * 6, 0.75, 1.0)[..., None]
        m = text_mask(text, int(w * 0.8), int(h * 0.7))
        pad = np.zeros((h, w))
        oy, ox = (h - m.shape[0]) // 2, (w - m.shape[1]) // 2
        pad[oy:oy + m.shape[0], ox:ox + m.shape[1]] = m
        img[y0:y1, x0:x1] = plate * (1 - pad[..., None]) + pad[..., None] * np.array([0.08, 0.06, 0.04])
    return img


# ---------------------------------------------------------------- 誘導灯（避難口：緑の地に白の人と扉）
def _capsule(img, mask_val, p0, p1, r):
    h, w = img.shape
    yy, xx = np.mgrid[0:h, 0:w] + 0.5
    ax, ay = p0
    bx, by = p1
    dx, dy = bx - ax, by - ay
    t = np.clip(((xx - ax) * dx + (yy - ay) * dy) / (dx * dx + dy * dy + 1e-9), 0, 1)
    d = np.hypot(xx - (ax + t * dx), yy - (ay + t * dy))
    np.maximum(img, np.clip((r - d) + 0.5, 0, 1) * mask_val, out=img)


def exit_sign(w=512, h=256):
    """避難口誘導灯の表示（緑の地に、扉へ走る白い人）。値は表示の色（発光の色に使う）。"""
    white = np.zeros((h, w))
    s = h / 256.0
    # 扉（白い枠の中に緑の開口。右側）
    x0, x1, y0, y1 = int(300 * s), int(450 * s), int(40 * s), int(220 * s)
    white[y0:y1, x0:x1] = 1.0
    white[int(60 * s):y1, int(320 * s):int(430 * s)] = 0.0
    # 走る人（頭・胴・腕・脚）
    _capsule(white, 1.0, (170 * s, 62 * s), (170 * s, 62 * s), 20 * s)
    _capsule(white, 1.0, (160 * s, 95 * s), (130 * s, 150 * s), 15 * s)
    _capsule(white, 1.0, (155 * s, 100 * s), (205 * s, 120 * s), 9 * s)
    _capsule(white, 1.0, (205 * s, 120 * s), (240 * s, 100 * s), 8 * s)
    _capsule(white, 1.0, (150 * s, 105 * s), (105 * s, 125 * s), 9 * s)
    _capsule(white, 1.0, (105 * s, 125 * s), (85 * s, 105 * s), 8 * s)
    _capsule(white, 1.0, (130 * s, 150 * s), (185 * s, 175 * s), 11 * s)
    _capsule(white, 1.0, (185 * s, 175 * s), (175 * s, 222 * s), 10 * s)
    _capsule(white, 1.0, (130 * s, 150 * s), (95 * s, 190 * s), 11 * s)
    _capsule(white, 1.0, (95 * s, 190 * s), (55 * s, 200 * s), 10 * s)
    green = np.array([0.0, 0.62, 0.30])
    img = green[None, None, :] * (1 - white[..., None]) + white[..., None] * np.array([0.95, 1.0, 0.95])
    # 縁（白っぽい枠）
    yy, xx = np.mgrid[0:h, 0:w]
    edge = (np.minimum.reduce([xx, yy, w - 1 - xx, h - 1 - yy]) < 6 * s)
    img[edge] = np.array([0.85, 0.9, 0.86])
    return img
