"""映画館の寸法と配置（Blender の座標。単位はメートル）。

座標：X = 右（スクリーンに向かって）、Y = 前（スクリーンの方向）、Z = 上。原点は後ろの壁の中央の、客席の床の高さ 0 の位置。
RealityKit へは (x, y, z) → (x, z, -y) で書き出す（Y が上、-Z が前）。

部屋は 26 m × 28 m、天井 15 m の大スクリーンの劇場（プレミアムラージフォーマット）。
スクリーンの映像の最大は 21 m × 10.5 m（2.0:1）で、半径 50 m の曲面。シネスコ（2.39:1）は上下、ビスタ・16:9 は左右をマスキングで締める。
客席はスタジアム形式の 13 列（A〜N、I は 1 と紛らわしいので使わない）× 34 席（左 8・中央 18・右 8）＝ 442 席。
"""
import math

# ---------------------------------------------------------------- 部屋
ROOM_X = 13.0          # 左右の壁（内側の面）は x = ±13
ROOM_Y_REAR = 0.0      # 後ろの壁
ROOM_Y_FRONT = 28.0    # スクリーンの後ろの壁
CEILING_Z = 15.0

# ---------------------------------------------------------------- スクリーン
SCREEN_Y = 27.0             # スクリーンの中央（曲面の頂点）の y
SCREEN_RADIUS = 50.0        # 曲面の半径（中心はスクリーンの手前 50 m）
SCREEN_IMAGE_W = 21.0       # 映像の最大の幅（弦の長さ）
SCREEN_IMAGE_H = 10.5       # 映像の最大の高さ
SCREEN_IMAGE_BOTTOM = 1.6   # 映像の下端の高さ
SCREEN_CENTER_Z = SCREEN_IMAGE_BOTTOM + SCREEN_IMAGE_H / 2
SCREEN_BORDER = 0.35        # 幕の裏に隠れるスクリーンの余白


def screen_y_at(x):
    """スクリーン面の、横位置 x での y（両端ほど客席に近い）。"""
    return SCREEN_Y - SCREEN_RADIUS + math.sqrt(SCREEN_RADIUS ** 2 - x * x)


# ---------------------------------------------------------------- 舞台（スクリーンの前の低い台）
STAGE_FRONT_Y = 24.6
STAGE_Z = 0.8
STAGE_X = 11.6

# ---------------------------------------------------------------- 客席
ROW_LETTERS = ["A", "B", "C", "D", "E", "F", "G", "H", "J", "K", "L", "M", "N"]
ROW_PITCH = 1.2
ROW_A_Y = 17.2              # A 列の座席の中心の y
# 列ごとの床の高さ（前の 3 列はゆるい段、D 列からは 0.45 m ずつのスタジアム）
ROW_Z = [0.0, 0.30, 0.60] + [0.60 + 0.45 * (i + 1) for i in range(10)]
REAR_AISLE_Y = ROW_A_Y - ROW_PITCH * (len(ROW_LETTERS) - 1) - ROW_PITCH / 2  # 最後列の後ろの通路の前端


def row_y(i):
    return ROW_A_Y - ROW_PITCH * i


SEAT_PITCH = 0.62           # 肘掛けの中心どうしの間隔
SIDE_AISLE = 1.25           # 壁ぞいの通路の幅
INNER_AISLE = 1.20          # ブロックの間の通路の幅
BLOCKS = [("L", 8), ("C", 18), ("R", 8)]  # 左から（スクリーンに向かって）
SEAT_EYE_HEIGHT = 1.15      # 座ったときの目の高さ（床から）
SEAT_EYE_BACK = 0.12        # 目の位置は座席の中心より少し後ろ


def blocks():
    """ブロックごとの (名前, 席の数, 左端の x, 右端の x)。中央のブロックを x = 0 に合わせる。"""
    center_w = BLOCKS[1][1] * SEAT_PITCH
    c0 = -center_w / 2
    left_w = BLOCKS[0][1] * SEAT_PITCH
    right_w = BLOCKS[2][1] * SEAT_PITCH
    return [
        ("L", BLOCKS[0][1], c0 - INNER_AISLE - left_w, c0 - INNER_AISLE),
        ("C", BLOCKS[1][1], c0, -c0),
        ("R", BLOCKS[2][1], -c0 + INNER_AISLE, -c0 + INNER_AISLE + right_w),
    ]


def aisles():
    """通路ごとの (名前, 左端の x, 右端の x)。壁ぞい 2 本とブロックの間 2 本。"""
    b = blocks()
    return [
        ("sideL", -ROOM_X, b[0][2]),
        ("innerL", b[0][3], b[1][2]),
        ("innerR", b[1][3], b[2][2]),
        ("sideR", b[2][3], ROOM_X),
    ]


def seats():
    """すべての座席。(列の番号, 列の文字, 席番号, ブロック, x, y, z)。席番号はスクリーンに向かって左から 1。"""
    out = []
    for i, letter in enumerate(ROW_LETTERS):
        number = 1
        for name, count, x0, _ in blocks():
            for j in range(count):
                out.append((i, letter, number, name, x0 + SEAT_PITCH * (j + 0.5), row_y(i), ROW_Z[i]))
                number += 1
    return out


def floor_z(y):
    """通路ではない客席の床の高さ（y の位置の列の床）。前の平らな床は 0。"""
    for i in range(len(ROW_LETTERS)):
        if abs(y - row_y(i)) <= ROW_PITCH / 2 + 1e-6:
            return ROW_Z[i]
    return ROW_Z[-1] if y < row_y(len(ROW_LETTERS) - 1) else 0.0


def aisle_steps():
    """通路の段（前から後ろへ）。(y の前端, y の後端, 高さ)。列の床の前半に中間の段を入れる。"""
    steps = []
    for i in range(len(ROW_LETTERS)):
        y_front, y_mid, y_back = row_y(i) + ROW_PITCH / 2, row_y(i), row_y(i) - ROW_PITCH / 2
        rise = ROW_Z[i] - (ROW_Z[i - 1] if i > 0 else 0.0)
        if rise > 1e-6:
            steps.append((y_front, y_mid, ROW_Z[i] - rise / 2))
            steps.append((y_mid, y_back, ROW_Z[i]))
        else:
            steps.append((y_front, y_back, ROW_Z[i]))
    return steps


def aisle_floor_z(y):
    """通路の床の高さ（段）。"""
    for y0, y1, z in aisle_steps():
        if y1 - 1e-6 <= y <= y0 + 1e-6:
            return z
    if y < REAR_AISLE_Y:
        return ROW_Z[-1]
    return 0.0


def dado_top_z(y):
    """壁の腰板の上端（通路の床に沿ってなだらかに上がる線）。"""
    pts = [(ROOM_Y_FRONT, 0.0), (ROW_A_Y + ROW_PITCH / 2, 0.0)]
    pts += [(row_y(i), ROW_Z[i]) for i in range(len(ROW_LETTERS))]
    pts += [(ROOM_Y_REAR, ROW_Z[-1])]
    for (ya, za), (yb, zb) in zip(pts, pts[1:]):
        if yb <= y <= ya:
            t = (ya - y) / (ya - yb) if ya != yb else 0.0
            return za + (zb - za) * t + 1.05
    return 1.05


# ---------------------------------------------------------------- 壁の作り
WALL_FIN_YS = [1.6, 4.4, 7.2, 10.0, 12.8, 15.6, 18.4, 21.2]  # 側壁の木のフィン（縦の桟）
WALL_PANEL_TOP = 12.0       # 吸音パネルの上端
DOOR_Y = (21.6, 23.4)       # 前方の非常口（左右の壁）
DOOR_H = 2.4
REAR_FIN_XS = [-10.5, -7.0, -3.5, 3.5, 7.0, 10.5]

# ---------------------------------------------------------------- 天井
CLOUD_Z = 13.6              # 天井から吊った浮き天井（クラウド）の下面
CLOUD_T = 0.22
CLOUD_XS = [(-12.2, -4.5), (-3.9, 3.9), (4.5, 12.2)]
CLOUD_YS = [(1.0, 5.4), (5.9, 10.3), (10.8, 15.2), (15.7, 20.1), (20.6, 25.0)]

# ---------------------------------------------------------------- スピーカー（音源の位置もここから書き出す）
SURROUND_YS = [3.0, 5.8, 8.6, 11.4, 14.2, 17.0, 19.8]   # 側壁のサラウンド（片側 7 台）
REAR_SURROUND_XS = [-9.5, -4.5, 4.5, 9.5]
OVERHEAD_XS = [-4.2, 4.2]                               # 天井のスピーカー（クラウドのすきま）
OVERHEAD_YS = [5.65, 10.55, 15.45, 20.35]
SCREEN_SPEAKER_XS = [-7.0, 0.0, 7.0]                    # スクリーンの裏（L / C / R）
SCREEN_SPEAKER_Z = SCREEN_IMAGE_BOTTOM + SCREEN_IMAGE_H * 0.42
SUBWOOFER_XS = [-3.0, 3.0]


def surround_z(y):
    """側壁のサラウンドの高さ（通路の床から 4.6 m、最低 5.6 m）。"""
    return max(5.6, aisle_floor_z(y) + 4.6)


# ---------------------------------------------------------------- 映写室
BOOTH_PORT_Z = 10.4
BOOTH_PORTS = [(-1.6, 0.5, 0.4), (0.0, 1.3, 0.8), (1.6, 0.5, 0.4)]  # (x, 幅, 高さ)。中央が映写機
