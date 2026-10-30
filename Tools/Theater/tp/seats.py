"""座席：プレミアムシート（座面・リクライニングした背もたれ・背の殻と天板・肘掛けとカップホルダー・通路側の袖と足元灯・列の文字・席番号の板）。

座席は 3 種類の「単位」を並べる（スクリーンに向かって左から右へ）。
  Unit：座席 1 つ＋その右の肘掛け
  UnitEnd：ブロックの右端の座席＋右の袖（通路側。足元灯・列の文字の板）
  EndL：ブロックの左端の袖（通路側）
単位ごとにひな形（LOD0〜2）を 1 つ作り、ライトマップの UV（UV1）を 0〜1 に展開しておく。並べた物の面には、
何番目の単位か（tp_instance）を付け、書き出しで UV1 を単位ごとのマス（アトラスのタイル）に移す。LOD1・2 は LOD0 を間引いて作るので、
同じ UV1 のまま（同じマスの、同じ場所の光を読む）。

ひな形の座標：原点は座席の中心の床、+Y がスクリーンの向き。
"""
import math

import bmesh
import bpy
from mathutils import Matrix, Vector

from . import config as C
from . import textures as tx
from .mesh import Part, loc, rot_x

RECLINE = 12.0  # 背もたれの傾き（度。X 軸まわりの正の回転で、上端が後ろ（-Y）へ倒れる）
TAG_SEAT_PLATE = 1
TAG_ROW_PLATE = 2


def labels():
    """番号の板に並べる文字（席番号 1〜34、列の文字）。tx.seat_plate_cell の順。"""
    total = sum(n for _, n in C.BLOCKS)
    return [str(i + 1) for i in range(total)] + list(C.ROW_LETTERS)


def _palette_uv(name):
    u0, v0, u1, v1 = tx.SEAT_ATLAS_PALETTE[name]
    c = ((u0 + u1) / 2, (v0 + v1) / 2)
    return lambda f, l: c


def _fabric_uv(tile=0.35):
    """布の面の UV0：座席の座標で、面の向きに合わせて投影（布目の大きさ tile m）。"""
    def fn(f, l):
        n = f.normal
        co = l.vert.co
        ax = max(range(3), key=lambda i: abs(n[i]))
        if ax == 0:
            return (co.y / tile, co.z / tile)
        if ax == 1:
            return (co.x / tile, co.z / tile)
        return (co.x / tile, co.y / tile)
    return fn


def _plate_uv(cell):
    u0, v0, u1, v1 = cell
    return [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]


def _seat(p, segs):
    """座席 1 つ（肘掛けを除く）。"""
    fab = _fabric_uv()
    shell = _palette_uv("shell")
    arm = _palette_uv("arm")
    p.box((0.50, 0.48, 0.10), loc(0, 0.03, 0.42), "seat_fabric", bevel=0.032, segments=segs, uv_fn=fab, smooth=True)
    p.box((0.47, 0.44, 0.05), loc(0, 0.02, 0.345), "seat_hard", bevel=0.01, segments=1, uv_fn=shell)
    tilt = loc(0, -0.25, 0.47) @ rot_x(RECLINE)
    p.box((0.50, 0.10, 0.60), tilt @ loc(0, 0, 0.32), "seat_fabric", bevel=0.034, segments=segs, uv_fn=fab, smooth=True)
    p.box((0.47, 0.065, 0.17), tilt @ loc(0, 0.06, 0.56), "seat_fabric", bevel=0.03, segments=segs, uv_fn=fab, smooth=True)
    p.box((0.47, 0.06, 0.13), tilt @ loc(0, 0.055, 0.12), "seat_fabric", bevel=0.028, segments=segs, uv_fn=fab, smooth=True)
    # 背の後ろ（後ろの列から見える面）も布張り
    p.box((0.54, 0.05, 0.70), tilt @ loc(0, -0.075, 0.33), "seat_fabric", bevel=0.02, segments=segs, uv_fn=fab, smooth=True)
    p.box((0.55, 0.15, 0.045), tilt @ loc(0, -0.03, 0.69), "seat_hard", bevel=0.02, segments=segs, uv_fn=arm, smooth=True)
    # 背の後ろの席番号の板（後ろの列から読める）
    c = [tilt @ Vector(v) for v in ((0.055, -0.1015, 0.585), (-0.055, -0.1015, 0.585), (-0.055, -0.1015, 0.635),
                                    (0.055, -0.1015, 0.635))]
    p.quad(c, "seat_hard", uv=_plate_uv(tx.seat_plate_cell(0)), toward=(0, -1, 0), tag=TAG_SEAT_PLATE)


def _armrest(p, x, segs):
    """座席の間の肘掛け（側板・天板・カップホルダー）。"""
    end = _palette_uv("end")
    arm = _palette_uv("arm")
    metal = _palette_uv("metal")
    hole = _palette_uv("hole")
    p.box((0.05, 0.50, 0.60), loc(x, -0.02, 0.30), "seat_hard", bevel=0.012, segments=1, uv_fn=end)
    p.box((0.075, 0.56, 0.05), loc(x, -0.02, 0.645), "seat_hard", bevel=0.02, segments=segs, uv_fn=arm, smooth=True)
    seg = 20 if segs > 1 else 10
    p.cylinder(0.047, 0.014, loc(x, 0.19, 0.676), "seat_hard", segments=seg, cap=False, uv_fn=metal)
    p.ring(0.040, 0.047, loc(x, 0.19, 0.683), "seat_hard", segments=seg, uv_fn=metal)
    p.disk(0.040, loc(x, 0.19, 0.674), "seat_hard", segments=seg, uv_fn=hole)


def _end(p, x, aisle_side, segs):
    """ブロックの端の袖（通路側）。aisle_side = -1 なら左が通路。足元灯と列の文字の板を通路側の面に付ける。
    列の文字の板は、ひな形では番号の板の最初のマスを指す（並べるときに列の文字のマスへ移す）。"""
    end = _palette_uv("end")
    arm = _palette_uv("arm")
    p.box((0.07, 0.62, 0.72), loc(x, -0.03, 0.36), "seat_hard", bevel=0.015, segments=segs, uv_fn=end, smooth=False)
    p.box((0.09, 0.60, 0.055), loc(x, -0.02, 0.69), "seat_hard", bevel=0.022, segments=segs, uv_fn=arm, smooth=True)
    xf = x + aisle_side * 0.0355
    # 足元灯（通路を照らす小さな灯）
    p.box((0.008, 0.10, 0.03), loc(xf + aisle_side * 0.004, 0.12, 0.16), "seat_light")
    # 列の文字の板
    cell = tx.seat_plate_cell(0)
    ys = (0.03, -0.09) if aisle_side < 0 else (-0.09, 0.03)
    corners = [(xf + aisle_side * 0.001, ys[0], 0.45), (xf + aisle_side * 0.001, ys[1], 0.45),
               (xf + aisle_side * 0.001, ys[1], 0.55), (xf + aisle_side * 0.001, ys[0], 0.55)]
    p.quad(corners, "seat_hard", uv=_plate_uv(cell), toward=(aisle_side, 0, 0), tag=TAG_ROW_PLATE)


def _template(kind, segs, col, mats):
    p = Part(f"Template_{kind}_s{segs}")
    if kind in ("Unit", "UnitEnd"):
        _seat(p, segs)
    if kind == "Unit":
        _armrest(p, C.SEAT_PITCH / 2, segs)
    elif kind == "UnitEnd":
        _end(p, C.SEAT_PITCH / 2 + 0.01, 1, segs)
    elif kind == "EndL":
        _end(p, -0.01, -1, segs)
    return p.build(col, mats, {"tp_export": False})


def _unwrap_lightmap(ob, scene, margin=0.01):
    """ライトマップの UV（UV1）を、ひな形ごとに 0〜1 に展開して詰める。"""
    me = ob.data
    uv1 = me.uv_layers.new(name="UV1")
    me.uv_layers.active = uv1
    vl = bpy.context.view_layer
    for o in vl.objects:
        o.select_set(False)
    ob.select_set(True)
    vl.objects.active = ob
    with bpy.context.temp_override(active_object=ob, object=ob, selected_objects=[ob], selected_editable_objects=[ob]):
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.uv.smart_project(angle_limit=math.radians(55), island_margin=margin, area_weight=0.0, scale_to_bounds=False)
        bpy.ops.uv.pack_islands(rotate=True, scale=True, margin_method="FRACTION", margin=margin, shape_method="CONCAVE")
        bpy.ops.object.mode_set(mode="OBJECT")
    me.uv_layers.active = me.uv_layers["UV0"]


def _decimated(src, ratio, name, col):
    """src を間引いた複製（UV0・UV1・面の印を保つ）。"""
    ob = src.copy()
    ob.data = src.data.copy()
    ob.name = name
    col.objects.link(ob)
    mod = ob.modifiers.new("dec", "DECIMATE")
    mod.decimate_type = "COLLAPSE"
    mod.ratio = ratio
    mod.use_collapse_triangulate = True
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
    ob.modifiers.clear()
    old = ob.data
    ob.data = me
    me.name = name
    bpy.data.meshes.remove(old)
    return ob


def build(col, assets, mats, lights_amb, scene):
    """座席を並べる。戻り値は書き出し用の情報（座席の一覧・単位の一覧・グループ）。"""
    lods = {0: 2, 1: 1, 2: 0}  # LOD → ひな形の角の丸めの段数
    temps = {}
    for kind in ("Unit", "UnitEnd", "EndL"):
        t0 = _template(kind, lods[0], assets, mats)
        _unwrap_lightmap(t0, scene)
        temps[(kind, 0)] = t0
        temps[(kind, 1)] = _decimated(t0, 0.32, f"Template_{kind}_LOD1", assets)
        temps[(kind, 2)] = _decimated(t0, 0.09, f"Template_{kind}_LOD2", assets)
    tri = {k: sum(len(p.vertices) - 2 for p in o.data.polygons) for k, o in temps.items()}
    units = []      # (種類, 列, 席番号 or None, x, y, z)
    seats = []
    groups = {}
    for i, letter in enumerate(C.ROW_LETTERS):
        number = 1
        for bname, count, x0, _ in C.blocks():
            key = f"{letter}_{bname}"
            groups[key] = dict(row=letter, block=bname, units=[])
            y, z = C.row_y(i), C.ROW_Z[i]
            groups[key]["units"].append(len(units))
            units.append(("EndL", i, None, x0, y, z))
            lights_amb.append(_aisle_light(x0 - 0.07, y, z, -1, f"seatlight_{key}_L"))
            for j in range(count):
                x = x0 + C.SEAT_PITCH * (j + 0.5)
                kind = "UnitEnd" if j == count - 1 else "Unit"
                groups[key]["units"].append(len(units))
                units.append((kind, i, number, x, y, z))
                seats.append(dict(id=f"{letter}-{number}", row=letter, rowIndex=i, number=number, block=bname, group=key,
                                  position=(x, y, z)))
                number += 1
            lights_amb.append(_aisle_light(x0 + count * C.SEAT_PITCH + 0.07, y, z, 1, f"seatlight_{key}_R"))
    # グループ（列 × ブロック）× LOD ごとに 1 つのオブジェクトにまとめる。マテリアルは名前でそろえる
    mat_names = []
    for t in temps.values():
        for mt in t.data.materials:
            if mt.name not in mat_names:
                mat_names.append(mt.name)
    remap = {k: [mat_names.index(mt.name) for mt in t.data.materials] for k, t in temps.items()}
    objs = []
    for key, g in groups.items():
        for lod in (0, 1, 2):
            bm = bmesh.new()
            inst = bm.faces.layers.int.new("tp_instance")
            for ui in g["units"]:
                kind, ri, number, x, y, z = units[ui]
                t = temps[(kind, lod)]
                nv, nf = len(bm.verts), len(bm.faces)
                bm.from_mesh(t.data)
                bm.verts.ensure_lookup_table()
                bm.faces.ensure_lookup_table()
                m = Matrix.Translation((x, y, z))
                for v in bm.verts[nv:]:
                    v.co = m @ v.co
                inst = bm.faces.layers.int.get("tp_instance") or bm.faces.layers.int.new("tp_instance")
                tag = bm.faces.layers.int.get("tp_tag")
                uv0 = bm.loops.layers.uv.get("UV0")
                for f in bm.faces[nf:]:
                    f[inst] = ui
                    f.material_index = remap[(kind, lod)][f.material_index]
                    if tag is None or uv0 is None:
                        continue
                    shift = None
                    if f[tag] == TAG_SEAT_PLATE and number is not None:
                        shift = _cell_shift(number - 1)
                    elif f[tag] == TAG_ROW_PLATE:
                        shift = _cell_shift(sum(n for _, n in C.BLOCKS) + ri)
                    if shift is not None:
                        for lp in f.loops:
                            lp[uv0].uv = (lp[uv0].uv[0] + shift[0], lp[uv0].uv[1] + shift[1])
            me = bpy.data.meshes.new(f"Seats_{key}_LOD{lod}")
            bm.to_mesh(me)
            bm.free()
            for name in mat_names:
                me.materials.append(mats[name])
            ob = bpy.data.objects.new(f"Seats_{key}_LOD{lod}", me)
            col.objects.link(ob)
            ob["tp_group"] = f"Seats/{key}"
            ob["tp_lod"] = lod
            ob["tp_atlas"] = "seats"
            if lod > 0:
                ob.hide_render = True
                ob.hide_set(True)
            objs.append(ob)
    return dict(seats=seats, units=units, groups=groups, templates=temps, triangles=tri, objects=objs)


def _cell_shift(index):
    a = tx.seat_plate_cell(0)
    b = tx.seat_plate_cell(index)
    return (b[0] - a[0], b[1] - a[1])


def _aisle_light(x, y, z, side, name):
    """袖の足元灯の光（通路の床を照らす）。"""
    return dict(kind="SPOT", name=name, power=2.5, spot=math.radians(80), blend=0.8, radius=0.01, color=(1.0, 0.6, 0.3),
                location=(x, y + 0.12, z + 0.16), aim=(x + side * 0.3, y + 0.2, z))
