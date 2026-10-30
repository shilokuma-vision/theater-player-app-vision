"""スピーカー：壁のサラウンド（側壁 7 台ずつ・後ろの壁 4 台）と天井のスピーカー（8 台）。
キャビネット（黒の塗装・角の丸み）、パンチングメタルのグリル、ロゴの板、コの字の吊り金具とつまみ、壁・天井への腕と受け板。

アプリの空間オーディオの音源の位置（スクリーンの裏の L / C / R とサブウーファーを含む）も、ここで一覧にする。
"""
import math

from mathutils import Matrix, Vector

from . import config as C
from .mesh import Part


def _aim_matrix(pos, target):
    """+Y（スピーカーの正面）を target に向け、上を +Z に近づけた姿勢。"""
    f = (Vector(target) - Vector(pos)).normalized()
    up = Vector((0, 0, 1))
    x = f.cross(up)
    if x.length < 1e-6:
        x = Vector((1, 0, 0))
    x.normalize()
    z = x.cross(f).normalized()
    m = Matrix((x, f, z)).transposed().to_4x4()
    m.translation = Vector(pos)
    return m


def _cabinet(p, m, size=(0.36, 0.30, 0.58)):
    """キャビネットの本体（正面は +Y、正面の面の中心が原点）。"""
    w, d, h = size
    p.box((w, d, h), m @ Matrix.Translation((0, -d / 2, 0)), "speaker_paint", bevel=0.018, segments=2, smooth=True)
    # グリル（正面に少し出した板。縁を丸める）
    p.box((w - 0.03, 0.012, h - 0.03), m @ Matrix.Translation((0, 0.004, 0)), "grille", bevel=0.005, segments=1)
    # ロゴの板
    p.box((0.07, 0.004, 0.016), m @ Matrix.Translation((0, 0.012, -h / 2 + 0.045)), "badge", bevel=0.001, segments=1)
    # コの字の金具（両側の板と、つまみ）
    for sx in (-1, 1):
        p.box((0.012, 0.09, 0.11), m @ Matrix.Translation((sx * (w / 2 + 0.008), -d / 2, 0)), "bracket", bevel=0.003, segments=1)
        p.cylinder(0.022, 0.016, m @ Matrix.Translation((sx * (w / 2 + 0.022), -d / 2, 0)) @ Matrix.Rotation(math.pi / 2, 4, "Y"),
                   "bracket", segments=16)
    p.box((w + 0.028, 0.03, 0.012), m @ Matrix.Translation((0, -d / 2 - 0.04, -h / 2 + 0.2)), "bracket")


def _arm(p, a, b, thick=0.04):
    """a から b への角材（金具の腕）。"""
    sq = [(-thick / 2, -thick / 2), (thick / 2, -thick / 2), (thick / 2, thick / 2), (-thick / 2, thick / 2)]
    p.extrude_profile(sq, [a, b], "bracket", closed=True, smooth=False)


def _wall_speaker(p, wall_pt, normal, target, out=0.42):
    """壁に付けたスピーカー。wall_pt は壁の取り付け位置、normal は壁から部屋への向き。"""
    pivot = Vector(wall_pt) + Vector(normal) * out
    m = _aim_matrix(pivot, target)
    back = m @ Vector((0, -0.29, 0))
    _cabinet(p, m)
    _arm(p, tuple(Vector(wall_pt) + Vector(normal) * 0.01), tuple(back))
    n = Vector(normal)
    t = Vector((0, 0, 1)).cross(n).normalized()
    c = Vector(wall_pt) + n * 0.006
    corners = [c + t * sx * 0.08 + Vector((0, 0, sz * 0.12)) for sx, sz in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    p.quad([tuple(v) for v in corners], "bracket", toward=tuple(n))
    return m


def _ceiling_speaker(p, pos, target):
    """天井から吊ったスピーカー（2 本の吊りボルトと、上の受け板）。"""
    m = _aim_matrix(pos, target)
    _cabinet(p, m)
    for sx in (-1, 1):
        top = Vector((pos[0] + sx * 0.12, pos[1], C.CEILING_Z))
        _arm(p, tuple(top), tuple(m @ Vector((sx * 0.12, -0.15, 0.27))), 0.018)
        p.box((0.06, 0.06, 0.01), Matrix.Translation(top - Vector((0, 0, 0.005))), "bracket")
    return m


def build(col, mats):
    """スピーカーを置き、音源の一覧を返す（Blender の座標。bus はアプリのスピーカーの系統）。"""
    emitters = []
    for side, tag in ((-1, "L"), (1, "R")):
        p = Part(f"Surrounds{tag}")
        sx = side * C.ROOM_X
        for k, y in enumerate(C.SURROUND_YS):
            z = C.surround_z(y)
            target = (side * 2.0, y - 1.5, C.floor_z(y) + 1.2)
            m = _wall_speaker(p, (sx, y, z), (-side, 0, 0), target)
            bus = f"{tag}ss" if y > 9.0 else f"{tag}rs"
            emitters.append(dict(id=f"{tag}wall{k + 1}", bus=bus, position=tuple(m.translation),
                                 forward=tuple(m.col[1].to_3d())))
        p.build(col, mats, {"tp_group": f"Room/Wall{tag}"})
    p = Part("SurroundsRear")
    for k, x in enumerate(C.REAR_SURROUND_XS):
        target = (x * 0.4, 9.0, C.ROW_Z[6] + 1.2)
        m = _wall_speaker(p, (x, C.ROOM_Y_REAR, 9.2), (0, 1, 0), target)
        emitters.append(dict(id=f"rear{k + 1}", bus="Lrs" if x < 0 else "Rrs", position=tuple(m.translation),
                             forward=tuple(m.col[1].to_3d())))
    p.build(col, mats, {"tp_group": "Room/WallRear"})
    p = Part("Overheads")
    for x in C.OVERHEAD_XS:
        for k, y in enumerate(C.OVERHEAD_YS):
            target = (x * 0.35, y - 0.8, C.floor_z(y) + 1.1)
            m = _ceiling_speaker(p, (x, y, C.CLOUD_Z - 0.55), target)
            tag = "L" if x < 0 else "R"
            bus = f"{tag}tf" if y > 12.0 else f"{tag}tr"
            emitters.append(dict(id=f"top{tag}{k + 1}", bus=bus, position=tuple(m.translation), forward=tuple(m.col[1].to_3d())))
    p.build(col, mats, {"tp_group": "Room/Ceiling"})
    # スクリーンの裏（見えない）
    for x, bus in zip(C.SCREEN_SPEAKER_XS, ("L", "C", "R")):
        emitters.append(dict(id=f"screen{bus}", bus=bus, position=(x, C.screen_y_at(x) + 0.6, C.SCREEN_SPEAKER_Z),
                             forward=(0.0, -1.0, 0.0)))
    for k, x in enumerate(C.SUBWOOFER_XS):
        emitters.append(dict(id=f"sub{k + 1}", bus="LFE", position=(x, C.screen_y_at(x) + 0.5, 0.6), forward=(0.0, -1.0, 0.0)))
    return emitters
