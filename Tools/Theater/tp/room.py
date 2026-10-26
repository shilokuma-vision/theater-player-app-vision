"""建築：床（スタジアムの段・通路の段）、壁（腰板・吸音パネル・木のフィン・手すり）、天井（浮き天井とダウンライト）、
スクリーン（曲面・マスキング・袖幕）、舞台、前方の非常口、映写窓。

RealityKit は面の裏を描かないので、開いた面（quad・grid）には toward で表の向きを渡す（客席から見える側）。
オブジェクトには書き出し用のカスタムプロパティを付ける。
  tp_group：書き出すときのまとまり（RealityKit のエンティティの名前・カリングの単位）
  tp_role：アプリで特別に扱う物（screen_surface・masking_top など）
  tp_export = False：書き出さない（焼き付けで光を返すためだけの面）
"""
import math

from . import config as C
from .mesh import Part, loc, rot_x

UP, DOWN = (0, 0, 1), (0, 0, -1)
TO_SCREEN, TO_REAR = (0, 1, 0), (0, -1, 0)


def _floor(col, mats):
    """客席の床：前の平らな床、列の段、通路の段、最後列の後ろの通路。"""
    p = Part("Floor")
    xs = [(x0, x1) for _, _, x0, x1 in C.blocks()]
    front = C.ROW_A_Y + C.ROW_PITCH / 2
    p.quad([(-C.ROOM_X, front, 0), (C.ROOM_X, front, 0), (C.ROOM_X, C.STAGE_FRONT_Y, 0), (-C.ROOM_X, C.STAGE_FRONT_Y, 0)],
           "carpet", toward=UP)
    zr = C.ROW_Z[-1]
    p.quad([(-C.ROOM_X, C.ROOM_Y_REAR, zr), (C.ROOM_X, C.ROOM_Y_REAR, zr), (C.ROOM_X, C.REAR_AISLE_Y, zr),
            (-C.ROOM_X, C.REAR_AISLE_Y, zr)], "carpet", toward=UP)
    for i in range(len(C.ROW_LETTERS)):
        y0, y1, z = C.row_y(i) - C.ROW_PITCH / 2, C.row_y(i) + C.ROW_PITCH / 2, C.ROW_Z[i]
        zp = C.ROW_Z[i - 1] if i > 0 else 0.0
        for x0, x1 in xs:
            p.quad([(x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z)], "carpet", toward=UP)
            if z - zp > 1e-6:  # 段の前の立ち上がり（スクリーン側を向く）
                p.quad([(x0, y1, zp), (x1, y1, zp), (x1, y1, z), (x0, y1, z)], "riser", toward=TO_SCREEN)
    steps = C.aisle_steps()
    for _, ax0, ax1 in C.aisles():
        for k, (y0, y1, z) in enumerate(steps):
            p.quad([(ax0, y1, z), (ax1, y1, z), (ax1, y0, z), (ax0, y0, z)], "carpet", toward=UP)
            zp = steps[k - 1][2] if k > 0 else 0.0
            if z - zp > 1e-6:
                p.quad([(ax0, y0, zp), (ax1, y0, zp), (ax1, y0, z), (ax0, y0, z)], "riser", toward=TO_SCREEN)
    # ブロックと通路の境目の縦の面（通路の中間の段が低いところ。通路の側を向く）
    for x0, x1 in xs:
        for xb, toward in ((x0, -1), (x1, 1)):
            for y0, y1, za in steps:
                zb = C.floor_z((y0 + y1) / 2)
                if zb - za < 1e-6:
                    continue
                p.quad([(xb, y1, za), (xb, y0, za), (xb, y0, zb), (xb, y1, zb)], "riser", toward=(toward, 0, 0))
    p.build(col, mats, {"tp_group": "Room/Floor"})


def _step_details(col, mats, lights_amb):
    """通路の段の鼻先（アルミの金物）と、段の立ち上がりに埋めた足元灯（LED の帯と、下の段を照らすライト）。"""
    p = Part("AisleNosing")
    led = Part("AisleStepLights")
    steps = C.aisle_steps()
    for name, ax0, ax1 in C.aisles():
        w = ax1 - ax0
        cx = (ax0 + ax1) / 2
        for k, (y0, _, z) in enumerate(steps):
            zp = steps[k - 1][2] if k > 0 else 0.0
            if z - zp < 1e-6:
                continue
            p.box_between((ax0 + 0.02, y0 - 0.045, z - 0.012), (ax1 - 0.02, y0 + 0.004, z + 0.004), "aluminum")
            lw = w * 0.6
            led.quad([(cx - lw / 2, y0 + 0.002, z - 0.05), (cx + lw / 2, y0 + 0.002, z - 0.05),
                      (cx + lw / 2, y0 + 0.002, z - 0.03), (cx - lw / 2, y0 + 0.002, z - 0.03)], "led_step", toward=TO_SCREEN)
            lights_amb.append(dict(kind="AREA", name=f"step_{name}_{k}", size=(lw, 0.02), power=4.0,
                                   color=(1.0, 0.55, 0.22), location=(cx, y0 + 0.015, z - 0.04),
                                   aim=(cx, y0 + 0.6, zp)))
    p.build(col, mats, {"tp_group": "Room/Floor"})
    led.build(col, mats, {"tp_group": "Room/Floor"})


def _side_wall(col, mats, side, lights_house, lights_amb):
    """左右の壁（side = -1 が左、1 が右）。内側の面は x = side × 13。"""
    sx = side * C.ROOM_X
    inward = -side
    into = (inward, 0, 0)
    tag = "L" if side < 0 else "R"
    wall, panels, wood, leds = (Part(f"{n}{tag}") for n in ("Wall", "WallPanels", "WallWood", "WallLeds"))

    def wq(part, x, ya, yb, za0, zb0, za1, zb1, mat):
        part.quad([(x, ya, za0), (x, yb, zb0), (x, yb, zb1), (x, ya, za1)], mat, toward=into)

    ys = {C.ROOM_Y_REAR, C.STAGE_FRONT_Y, C.REAR_AISLE_Y, *C.DOOR_Y}
    for y0, y1, _ in C.aisle_steps():
        ys.update((y0, y1))
    ys = sorted(y for y in ys if y <= C.STAGE_FRONT_Y)
    door0, door1 = C.DOOR_Y
    x_dado = sx + inward * 0.045
    for ya, yb in zip(ys, ys[1:]):
        ym = (ya + yb) / 2
        fz = C.aisle_floor_z(ym)
        da, db = C.dado_top_z(ya), C.dado_top_z(yb)
        if door0 <= ym <= door1:
            wq(wall, sx, ya, yb, C.DOOR_H + 0.12, C.DOOR_H + 0.12, C.DOOR_H + 0.4, C.DOOR_H + 0.4, "plaster_dark")
        else:
            wq(wood, x_dado, ya, yb, fz, fz, da, db, "wood")
            wood.quad([(x_dado, ya, da), (x_dado, yb, db), (sx, yb, db), (sx, ya, da)], "wood", toward=UP)
        wq(wall, sx, ya, yb, C.WALL_PANEL_TOP, C.WALL_PANEL_TOP, C.CEILING_Z, C.CEILING_Z, "plaster_dark")
    # 吸音パネル（フィンとフィンの間。下端は腰板の線にそわせ、壁から 3 cm 出す）
    edges = [C.ROOM_Y_REAR] + C.WALL_FIN_YS + [C.STAGE_FRONT_Y]
    xp = sx + inward * 0.03
    for ya, yb in zip(edges, edges[1:]):
        segs = [(ya, yb)]
        if ya < door1 and yb > door0:
            segs = [(ya, door0), (door0, door1), (door1, yb)]
        for sa, sb in segs:
            if sb - sa < 0.05:
                continue
            over_door = door0 - 1e-6 <= sa and sb <= door1 + 1e-6
            za = C.DOOR_H + 0.4 if over_door else C.dado_top_z(sa)
            zb = C.DOOR_H + 0.4 if over_door else C.dado_top_z(sb)
            wq(panels, xp, sa, sb, za, zb, C.WALL_PANEL_TOP, C.WALL_PANEL_TOP, "wall_fabric")
    # 木のフィンと、フィンの上下から壁を洗う光
    for fy in C.WALL_FIN_YS:
        z0 = C.DOOR_H + 0.4 if door0 - 0.2 <= fy <= door1 + 0.2 else C.dado_top_z(fy)
        depth, width = 0.22, 0.10
        xa, xb = sorted((sx, sx + inward * depth))
        wood.box_between((xa, fy - width / 2, z0), (xb, fy + width / 2, C.WALL_PANEL_TOP + 0.05), "wood", bevel=0.008,
                         segments=1)
        xf = sx + inward * (depth + 0.002)
        leds.quad([(xf, fy - 0.012, z0 + 0.25), (xf, fy + 0.012, z0 + 0.25), (xf, fy + 0.012, C.WALL_PANEL_TOP - 0.25),
                   (xf, fy - 0.012, C.WALL_PANEL_TOP - 0.25)], "led_warm", toward=into)
        for zz, tilt in ((z0 + 0.15, 1), (C.WALL_PANEL_TOP - 0.15, -1)):
            for dy in (-1, 1):
                lights_house.append(dict(kind="SPOT", name=f"finwash_{tag}_{fy:.1f}_{zz:.1f}_{dy}", power=60.0,
                                         spot=math.radians(50), blend=0.9, radius=0.03, color=(1.0, 0.78, 0.55),
                                         location=(sx + inward * 0.12, fy + dy * 0.09, zz),
                                         aim=(sx + inward * 0.04, fy + dy * 1.2, zz + tilt * 3.0)))
    # 手すり（腰板の上、通路ぞい）とその受け金物
    rail = []
    y = C.ROOM_Y_REAR + 0.4
    while y < door0 - 0.4:
        rail.append((sx + inward * 0.11, y, C.dado_top_z(y) - 0.12))
        y += 0.5
    ring = [(0.022 * math.cos(2 * math.pi * k / 10), 0.022 * math.sin(2 * math.pi * k / 10)) for k in range(10)]
    wood.extrude_profile(ring, rail, "aluminum", closed=True)
    for k in range(0, len(rail), 4):
        x, yy, z = rail[k]
        xa, xb = sorted((x, sx))
        wood.box_between((xa, yy - 0.015, z - 0.015), (xb, yy + 0.015, z + 0.015), "aluminum")
    for part in (wall, panels, wood, leds):
        part.build(col, mats, {"tp_group": f"Room/Wall{tag}"})
    _exit_door(col, mats, side, lights_amb)


def _exit_door(col, mats, side, lights_amb):
    """前方の非常口（両開きの扉・押し棒・枠）と、その上の避難口誘導灯。"""
    sx = side * C.ROOM_X
    inward = -side
    tag = "L" if side < 0 else "R"
    y0, y1 = C.DOOR_Y
    p = Part(f"ExitDoor{tag}")

    def xr(a, b):
        return sorted((sx + inward * a, sx + inward * b))

    fa, fb = xr(0.0, 0.06)
    for ya, yb in ((y0 - 0.08, y0), (y1, y1 + 0.08)):
        p.box_between((fa, ya, 0), (fb, yb, C.DOOR_H + 0.08), "trim_black")
    p.box_between((fa, y0 - 0.08, C.DOOR_H), (fb, y1 + 0.08, C.DOOR_H + 0.12), "trim_black")
    ym = (y0 + y1) / 2
    da, db = xr(0.01, 0.05)
    ba, bb = xr(0.05, 0.09)
    for ya, yb in ((y0, ym - 0.005), (ym + 0.005, y1)):
        p.box_between((da, ya, 0.01), (db, yb, C.DOOR_H - 0.01), "door", bevel=0.004, segments=1)
        p.box_between((ba, ya + 0.08, 0.98), (bb, yb - 0.08, 1.04), "aluminum", bevel=0.01, segments=2)
    p.build(col, mats, {"tp_group": f"Room/Wall{tag}"})
    s = Part(f"ExitSign{tag}")
    zc = C.DOOR_H + 0.5
    w, h, d = 0.62, 0.30, 0.07
    ea, eb = xr(0.0, d)
    s.box_between((ea, ym - w / 2 - 0.02, zc - h / 2 - 0.02), (eb, ym + w / 2 + 0.02, zc + h / 2 + 0.02), "trim_white",
                  bevel=0.006, segments=1)
    xf = sx + inward * (d + 0.002)
    # 部屋の内側から見て、左がスクリーンと反対の側（扉へ走る人が左を向く表示にはしない。左から右へ読む）
    left, right = (ym - w / 2, ym + w / 2) if side < 0 else (ym + w / 2, ym - w / 2)
    s.quad([(xf, left, zc - h / 2), (xf, right, zc - h / 2), (xf, right, zc + h / 2), (xf, left, zc + h / 2)], "exit_sign",
           uv=[(0, 0), (1, 0), (1, 1), (0, 1)], toward=(inward, 0, 0))
    s.build(col, mats, {"tp_group": f"Room/Wall{tag}"})
    lights_amb.append(dict(kind="AREA", name=f"exit_{tag}", size=(w, h), power=3.0, color=(0.3, 1.0, 0.55),
                           location=(sx + inward * (d + 0.03), ym, zc), aim=(0.0, ym, zc - 1.5)))


def _rear_wall(col, mats, lights_house, lights_amb):
    """後ろの壁：腰板・吸音パネル・木のフィン・映写窓。"""
    zf = C.ROW_Z[-1]
    y = C.ROOM_Y_REAR
    wall, wood, panels, booth = (Part(n) for n in ("WallRear", "WallRearWood", "WallRearPanels", "Booth"))
    dado = zf + 1.05

    def rq(part, x0, x1, z0, z1, yy, mat):
        part.quad([(x0, yy, z0), (x1, yy, z0), (x1, yy, z1), (x0, yy, z1)], mat, toward=TO_SCREEN)

    rq(wood, -C.ROOM_X, C.ROOM_X, zf, dado, y + 0.045, "wood")
    wood.quad([(-C.ROOM_X, y + 0.045, dado), (C.ROOM_X, y + 0.045, dado), (C.ROOM_X, y, dado), (-C.ROOM_X, y, dado)], "wood",
              toward=UP)
    rq(wall, -C.ROOM_X, C.ROOM_X, C.WALL_PANEL_TOP, C.CEILING_Z, y, "plaster_dark")
    edges = [-C.ROOM_X] + C.REAR_FIN_XS + [C.ROOM_X]
    for xa, xb in zip(edges, edges[1:]):
        if xa >= -3.6 and xb <= 3.6:
            rq(wall, xa, xb, dado, C.WALL_PANEL_TOP, y, "plaster_dark")  # 映写窓のある中央
            continue
        rq(panels, xa, xb, dado, C.WALL_PANEL_TOP, y + 0.03, "wall_fabric_rear")
    for fx in C.REAR_FIN_XS:
        wood.box_between((fx - 0.05, y, dado), (fx + 0.05, y + 0.22, C.WALL_PANEL_TOP + 0.05), "wood", bevel=0.008, segments=1)
        for zz, tilt in ((dado + 0.15, 1), (C.WALL_PANEL_TOP - 0.15, -1)):
            for dx in (-1, 1):
                lights_house.append(dict(kind="SPOT", name=f"rearwash_{fx}_{zz:.1f}_{dx}", power=60.0, spot=math.radians(50),
                                         blend=0.9, radius=0.03, color=(1.0, 0.78, 0.55), location=(fx + dx * 0.09, y + 0.12, zz),
                                         aim=(fx + dx * 1.2, y + 0.04, zz + tilt * 3.0)))
    # 映写窓：枠・ガラス（奥の映写室の薄明かり）・映写機のレンズ
    for x, w, h in C.BOOTH_PORTS:
        z0, z1 = C.BOOTH_PORT_Z - h / 2, C.BOOTH_PORT_Z + h / 2
        booth.box_between((x - w / 2 - 0.06, y, z0 - 0.06), (x + w / 2 + 0.06, y + 0.05, z0), "trim_black")
        booth.box_between((x - w / 2 - 0.06, y, z1), (x + w / 2 + 0.06, y + 0.05, z1 + 0.06), "trim_black")
        booth.box_between((x - w / 2 - 0.06, y, z0), (x - w / 2, y + 0.05, z1), "trim_black")
        booth.box_between((x + w / 2, y, z0), (x + w / 2 + 0.06, y + 0.05, z1), "trim_black")
        rq(booth, x - w / 2, x + w / 2, z0, z1, y + 0.012, "booth_glow")
        if abs(x) < 1e-6:
            booth.cylinder(0.11, 0.04, loc(x, y + 0.03, C.BOOTH_PORT_Z) @ rot_x(-90), "trim_black", segments=32)
            booth.disk(0.085, loc(x, y + 0.052, C.BOOTH_PORT_Z) @ rot_x(-90), "projector_lens", segments=32)
    lights_amb.append(dict(kind="AREA", name="booth_glow", size=(4.0, 0.8), power=4.0, color=(0.35, 0.45, 0.8),
                           location=(0, y + 0.1, C.BOOTH_PORT_Z), aim=(0, 6, C.BOOTH_PORT_Z - 2)))
    for part in (wall, wood, panels, booth):
        part.build(col, mats, {"tp_group": "Room/WallRear"})


def _square_annulus(part, cx, cy, z, half, r, k, mat):
    """正方形（一辺 2 × half）の中に半径 r の穴をあけた、下を向いた面（ダウンライトの穴の周り）。"""
    sq, ci = [], []
    corners = [(-half, -half), (half, -half), (half, half), (-half, half)]
    for i in range(4 * k):
        s, t = divmod(i, k)
        a, b = corners[s], corners[(s + 1) % 4]
        px, py = a[0] + (b[0] - a[0]) * t / k, a[1] + (b[1] - a[1]) * t / k
        ang = math.atan2(py, px)
        sq.append((cx + px, cy + py, z))
        ci.append((cx + r * math.cos(ang), cy + r * math.sin(ang), z))
    n = len(sq)
    for i in range(n):
        j = (i + 1) % n
        part.quad([ci[i], sq[i], sq[j], ci[j]], mat, toward=DOWN)


def _ceiling(col, mats, lights_house):
    """天井：本体（黒）、浮き天井（クラウド）、埋め込みのダウンライト、クラウドの上の間接照明。"""
    ceil = Part("Ceiling")
    ceil.quad([(-C.ROOM_X, C.ROOM_Y_REAR, C.CEILING_Z), (C.ROOM_X, C.ROOM_Y_REAR, C.CEILING_Z),
               (C.ROOM_X, C.STAGE_FRONT_Y + 0.4, C.CEILING_Z), (-C.ROOM_X, C.STAGE_FRONT_Y + 0.4, C.CEILING_Z)], "ceiling",
              toward=DOWN)
    ceil.build(col, mats, {"tp_group": "Room/Ceiling"})
    clouds, cans, lenses, coves = (Part(n) for n in ("Clouds", "Downlights", "DownlightLenses", "CoveLeds"))
    tops = Part("CloudTops")
    zb, zt = C.CLOUD_Z, C.CLOUD_Z + C.CLOUD_T
    r_hole, r_trim = 0.085, 0.105
    for x0, x1 in C.CLOUD_XS:
        for y0, y1 in C.CLOUD_YS:
            sides = (((x0, y0), (x1, y0)), ((x1, y0), (x1, y1)), ((x1, y1), (x0, y1)), ((x0, y1), (x0, y0)))
            for a, b in sides:
                nx, ny = (b[1] - a[1]), -(b[0] - a[0])
                clouds.quad([(a[0], a[1], zb), (b[0], b[1], zb), (b[0], b[1], zt), (a[0], a[1], zt)], "cloud",
                            toward=(nx, ny, 0))
            tops.quad([(x0, y0, zt), (x1, y0, zt), (x1, y1, zt), (x0, y1, zt)], "cloud", toward=UP)
            xs = [x0, (x0 + x1) / 2, x1]
            ys = [y0, (y0 + y1) / 2, y1]
            for i in range(2):
                for j in range(2):
                    cx, cy = (xs[i] + xs[i + 1]) / 2, (ys[j] + ys[j + 1]) / 2
                    hx, hy = (xs[i + 1] - xs[i]) / 2, (ys[j + 1] - ys[j]) / 2
                    h = min(hx, hy)
                    _square_annulus(clouds, cx, cy, zb, h, r_trim, 6, "cloud")
                    for sgn in (-1, 1):
                        if hx > h + 1e-6:
                            xa, xb = sorted((cx + sgn * h, cx + sgn * hx))
                            clouds.quad([(xa, cy - hy, zb), (xb, cy - hy, zb), (xb, cy + hy, zb), (xa, cy + hy, zb)], "cloud",
                                        toward=DOWN)
                        if hy > h + 1e-6:
                            ya, yb = sorted((cy + sgn * h, cy + sgn * hy))
                            clouds.quad([(cx - h, ya, zb), (cx + h, ya, zb), (cx + h, yb, zb), (cx - h, yb, zb)], "cloud",
                                        toward=DOWN)
                    # 器具：化粧枠（白）、反射板（内側を見る円すい）、レンズ
                    cans.ring(r_hole, r_trim + 0.012, loc(cx, cy, zb - 0.004) @ rot_x(180), "trim_white", segments=32)
                    cans.cylinder(r_hole, 0.006, loc(cx, cy, zb - 0.001), "trim_white", segments=32, cap=False, inside=True)
                    cans.cylinder(r_hole, 0.12, loc(cx, cy, zb + 0.06), "reflector", segments=32, cap=False, radius2=0.05,
                                  inside=True)
                    lenses.disk(0.05, loc(cx, cy, zb + 0.118) @ rot_x(180), "downlight_lens", segments=24)
                    lights_house.append(dict(kind="SPOT", name=f"down_{cx:.1f}_{cy:.1f}", power=450.0, spot=math.radians(62),
                                             blend=0.55, radius=0.05, color=(1.0, 0.80, 0.58),
                                             location=(cx, cy, zb + 0.08), aim=(cx, cy, 0.0)))
            # クラウドの上の縁の LED（天井を照らす間接照明。下からは見えない）
            for a, b in sides:
                mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
                length = math.hypot(b[0] - a[0], b[1] - a[1])
                nx, ny = (b[1] - a[1]) / length, -(b[0] - a[0]) / length
                coves.box_between((min(a[0], b[0]) - nx * 0.08 - 0.01, min(a[1], b[1]) - ny * 0.08 - 0.01, zt),
                                  (max(a[0], b[0]) - nx * 0.08 + 0.01, max(a[1], b[1]) - ny * 0.08 + 0.01, zt + 0.02),
                                  "led_warm")
                lights_house.append(dict(kind="AREA", name=f"cove_{mx:.1f}_{my:.1f}", size=(length - 0.2, 0.03), power=160.0,
                                         color=(1.0, 0.74, 0.48), location=(mx - nx * 0.06, my - ny * 0.06, zt + 0.04),
                                         aim=(mx + nx * 0.9, my + ny * 0.9, C.CEILING_Z), spread=math.radians(120)))
    for part in (clouds, cans, lenses):
        part.build(col, mats, {"tp_group": "Room/Ceiling"})
    coves.build(col, mats, {"tp_group": "Room/Ceiling", "tp_export": False})
    tops.build(col, mats, {"tp_group": "Room/Ceiling", "tp_export": False})


def _screen(col, mats, zones):
    """スクリーン（曲面）、動くマスキング（上下左右）、袖幕、上の幕。zones に焼き付け用の 3 区画の光を入れる。"""
    bw = C.SCREEN_IMAGE_W / 2 + C.SCREEN_BORDER
    zb = C.SCREEN_IMAGE_BOTTOM - C.SCREEN_BORDER
    zt = C.SCREEN_IMAGE_BOTTOM + C.SCREEN_IMAGE_H + C.SCREEN_BORDER

    def pt(x, z, dy=0.0):
        return (x, C.screen_y_at(x) - dy, z)

    s = Part("ScreenSurface")
    s.grid(lambda u, v: pt(-bw + 2 * bw * u, zb + (zt - zb) * v), 48, 6, "screen", uv=lambda u, v: (u, v), toward=TO_REAR)
    s.build(col, mats, {"tp_group": "Screen/Surface", "tp_role": "screen_surface"})
    for k, name in enumerate(("L", "C", "R")):
        x0 = -C.SCREEN_IMAGE_W / 2 + C.SCREEN_IMAGE_W * k / 3
        x1 = x0 + C.SCREEN_IMAGE_W / 3
        z0, z1 = C.SCREEN_IMAGE_BOTTOM, C.SCREEN_IMAGE_BOTTOM + C.SCREEN_IMAGE_H
        zp = Part(f"ScreenZone{name}")
        zp.grid(lambda u, v, x0=x0, x1=x1: pt(x0 + (x1 - x0) * u, z0 + (z1 - z0) * v, 0.01), 16, 4, "screen", toward=TO_REAR)
        zones[name] = zp
    iw, ih, ib = C.SCREEN_IMAGE_W / 2, C.SCREEN_IMAGE_H, C.SCREEN_IMAGE_BOTTOM
    masks = {
        "Top": (-bw - 1.5, bw + 1.5, ib + ih, ib + ih + 2.8, 0.12),
        "Bottom": (-bw - 1.5, bw + 1.5, ib - 1.4, ib, 0.12),
        "Left": (-bw - 2.6, -iw, ib - 1.0, ib + ih + 1.0, 0.16),
        "Right": (iw, bw + 2.6, ib - 1.0, ib + ih + 1.0, 0.16),
    }
    for name, (x0, x1, z0, z1, dy) in masks.items():
        m = Part(f"Masking{name}")
        nu = max(2, int((x1 - x0) / 0.5))
        m.grid(lambda u, v, x0=x0, x1=x1, z0=z0, z1=z1, dy=dy: pt(x0 + (x1 - x0) * u, z0 + (z1 - z0) * v, dy), nu, 2,
               "velvet_black", toward=TO_REAR)
        m.build(col, mats, {"tp_group": f"Screen/Masking{name}", "tp_role": f"masking_{name.lower()}"})
    for side in (-1, 1):
        d = Part(f"Leg{'L' if side < 0 else 'R'}")
        x_in = side * (bw + 1.6)

        def leg(u, v, side=side, x_in=x_in):
            x = x_in + side * (C.ROOM_X - abs(x_in)) * u
            return (x, C.STAGE_FRONT_Y - 0.15 + 0.12 * math.sin(u * math.pi * 14), C.STAGE_Z + (C.CEILING_Z - C.STAGE_Z) * v)
        d.grid(leg, 84, 2, "velvet_black", toward=TO_REAR)
        d.build(col, mats, {"tp_group": "Screen/Drapes"})
    top = Part("Border")

    def border(u, v):
        x = -C.ROOM_X + 2 * C.ROOM_X * u
        return (x, C.STAGE_FRONT_Y + 0.4 + 0.1 * math.sin(u * math.pi * 60), zt + 2.2 + (C.CEILING_Z - zt - 2.2) * v)
    top.grid(border, 240, 2, "velvet_black", toward=TO_REAR)
    top.quad([(-C.ROOM_X, C.ROOM_Y_FRONT, 0), (C.ROOM_X, C.ROOM_Y_FRONT, 0), (C.ROOM_X, C.ROOM_Y_FRONT, C.CEILING_Z),
              (-C.ROOM_X, C.ROOM_Y_FRONT, C.CEILING_Z)], "velvet_black", toward=TO_REAR)
    top.build(col, mats, {"tp_group": "Screen/Drapes"})


def _stage(col, mats, lights_amb):
    """スクリーンの前の舞台：黒いカーペットの天板、吸音布の前面（奥にサブウーファー）、鼻先のアルミと LED。"""
    p = Part("Stage")
    y0, y1, z, x = C.STAGE_FRONT_Y, C.ROOM_Y_FRONT, C.STAGE_Z, C.ROOM_X
    p.quad([(-x, y0, z), (x, y0, z), (x, y1, z), (-x, y1, z)], "stage_carpet", toward=UP)
    p.quad([(-x, y0, 0), (x, y0, 0), (x, y0, z - 0.05), (-x, y0, z - 0.05)], "velvet_black", toward=TO_REAR)
    p.box_between((-x, y0 - 0.04, z - 0.05), (x, y0 + 0.02, z + 0.004), "aluminum")
    p.build(col, mats, {"tp_group": "Screen/Stage"})
    led = Part("StageLed")
    led.quad([(-x + 0.3, y0 - 0.041, z - 0.075), (x - 0.3, y0 - 0.041, z - 0.075), (x - 0.3, y0 - 0.041, z - 0.06),
              (-x + 0.3, y0 - 0.041, z - 0.06)], "led_stage", toward=TO_REAR)
    led.build(col, mats, {"tp_group": "Screen/Stage"})
    lights_amb.append(dict(kind="AREA", name="stage_led", size=(2 * x - 0.6, 0.02), power=15.0, color=(0.35, 0.45, 1.0),
                           location=(0, y0 - 0.06, z - 0.08), aim=(0, y0 - 1.5, 0)))


def build(col, mats, lights_house, lights_amb, zones):
    _floor(col, mats)
    _step_details(col, mats, lights_amb)
    for side in (-1, 1):
        _side_wall(col, mats, side, lights_house, lights_amb)
    _rear_wall(col, mats, lights_house, lights_amb)
    _ceiling(col, mats, lights_house)
    _screen(col, mats, zones)
    _stage(col, mats, lights_amb)
