"""映画館のモデル（out/theater.blend）の照明を焼き付け、Vision Pro（RealityKit）向けの USDZ と配置の JSON を書く。

実行: Tools/Theater/run.sh export_theater.py
  先に build_theater.py で out/theater.blend を作っておく
  出力：TheaterPlayer/Resources/Theater/Theater.usdz・TheaterLayout.json（アプリに入る）と、out/export_report.json
  TP_FAST=1 で、画像を 1/4・サンプル数 32 にして速く試す（アプリの素材は書き換えない。out/fast/ に書く）

照明の層（ライトマップ。UV1）
  house（客電）・ambient（常時灯）は色付きの光、screen はスクリーンの左・中央・右の区画の光（明るさ）を r・g・b に入れる。
  画像は 8 bit の sRGB。値は √(光 ÷ k)（k は層ごと。マテリアルに書く。シェーダーで 2 乗して k を掛ける）
"""
import json
import math
import os
import sys
import time

import bpy
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tp import bake as B  # noqa: E402
from tp import config as C  # noqa: E402
from tp import exportmesh as X  # noqa: E402
from tp import materials as M  # noqa: E402
from tp import textures as T  # noqa: E402
from tp import usdwriter as U  # noqa: E402

FAST = os.environ.get("TP_FAST") == "1"
OUT = os.path.join(HERE, "out")
REPO = os.path.dirname(os.path.dirname(HERE))
DEST = os.path.join(OUT, "fast") if FAST else os.path.join(REPO, "TheaterPlayer", "Resources", "Theater")
WORK = os.path.join(OUT, ".export_work")
TEX = os.path.join(WORK, "textures")

# 画像の大きさ（画素）とサンプル数。建築は 1 枚に、座席は単位ごとのマス（タイル）に並べる
SIZES = {"room": {"house": 2048, "ambient": 2048, "screen": 1024}, "seats": {"house": 2048, "ambient": 1024, "screen": 512}}
SAMPLES = {"house": 384, "ambient": 512, "screen": 192}
# ライトマップの細かさの重み（グループごと。目に近い所・光の模様が細かい所を細かく）
DENSITY = {"Room/Floor": 1.25, "Room/WallL": 1.0, "Room/WallR": 1.0, "Room/WallRear": 0.8, "Room/Ceiling": 0.55,
           "Screen/Drapes": 0.45, "Screen/Stage": 0.8, "Screen/Surface": 0.5}
MARGIN_PX = 2
# ライトマップに島を持たせない物（小さい・光る灯具）。UV1 は右上の予約のマスを指し、そこには決まった光を入れる
NO_LIGHTMAP = {"DownlightLenses", "Downlights", "WallLedsL", "WallLedsR", "AisleStepLights"}
RESERVED_PX = 8
RESERVED_LIGHT = {"house": 0.5, "ambient": 0.03, "screen": 0.05}


def log(msg):
    print(f"[export] {msg}", flush=True)


def scale_for_fast():
    if not FAST:
        return
    for a in SIZES.values():
        for k in a:
            a[k] //= 4
    for k in SAMPLES:
        SAMPLES[k] = 32
    global MARGIN_PX, RESERVED_PX
    MARGIN_PX, RESERVED_PX = 1, 4


# ================================================================ UV1
def room_uv1(datas, scene):
    """建築：オブジェクトごとに展開し、1 m あたりの細かさをそろえて（重みを掛けて）から、1 枚に詰める。"""
    fixed = [d for d in datas if d.name in NO_LIGHTMAP]
    datas = [d for d in datas if d.name not in NO_LIGHTMAP]
    for d in datas:
        tmp, _ = X.join([d], "tmp_unwrap", [bpy.data.materials[m] for m in d.mats])
        _edit(tmp, lambda: bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.0, area_weight=0.0,
                                                    scale_to_bounds=False))
        uv = X.get_uv(tmp)
        if d.name == "Floor":
            uv = _unfold_floor(d, uv)
        a3 = _tri_area3(d.corner_pos)
        auv = _tri_area2(uv)
        s = math.sqrt(a3.sum() / max(auv.sum(), 1e-12)) * DENSITY.get(d.group, DENSITY.get(d.group.split("/")[0], 1.0))
        if d.group.startswith("Screen/Masking"):
            s *= 0.5
        d.uv1 = uv * s
        if os.environ.get("TP_DEBUG"):
            log(f"  {d.name}: s={s:.4g} a3={a3.sum():.3g} auv={auv.sum():.3g} tris={d.triangles}")
        bpy.data.objects.remove(tmp)
    names = []
    for d in datas:
        for m in d.mats:
            if m not in names:
                names.append(m)
    # 詰め込みは、島がいちばん近い UDIM のマスに詰められるので、先に全体を 0〜1 に縮めておく（大きさの比は保つ）
    span = max(float(np.concatenate([d.uv1 for d in datas]).max()), 1e-6)
    for d in datas:
        d.uv1 = d.uv1 / (span * 1.01)
    ob, spans = X.join(datas, "BAKE_room", [bpy.data.materials[n] for n in names])
    size = SIZES["room"]["house"]
    if os.environ.get("TP_DEBUG"):
        u = X.get_uv(ob)
        log(f"  before pack: {u.min(0)} {u.max(0)} area={_tri_area2(u).sum():.3f}")
    _edit(ob, lambda: bpy.ops.uv.pack_islands(udim_source="ORIGINAL_AABB", rotate=True, rotate_method="ANY", scale=True,
                                              merge_overlap=False,
                                              margin_method="FRACTION", margin=MARGIN_PX * 2 / size, shape_method="CONCAVE"))
    uv = X.get_uv(ob)
    if os.environ.get("TP_DEBUG"):
        log(f"  after pack: {uv.min(0)} {uv.max(0)} area={_tri_area2(uv).sum():.3f}")
        _debug_uv_image(uv, datas, spans, os.path.join(OUT, "debug_room_uv1.png"))
    # 右上の予約のマス（RESERVED_PX）をあけるため、全体を少し縮める
    shrink = 1.0 - (RESERVED_PX + MARGIN_PX) / size
    uv *= shrink
    X.set_uv(ob, uv)
    for d, (a, b) in zip(datas, spans):
        d.uv1 = uv[a:b]
    center = 1.0 - RESERVED_PX / 2 / size
    for d in fixed:
        d.uv1 = np.full((d.triangles * 3, 2), center)
    used = _tri_area2(uv).sum()
    area = sum(_tri_area3(d.corner_pos).sum() for d in datas)
    texel = math.sqrt(area / max(used * size * size, 1)) * 100
    log(f"建築のライトマップ：三角形 {sum(d.triangles for d in datas):,}（ほかに島なし {len(fixed)}）、使用率 {used:.0%}、"
        f"1 画素 平均 {texel:.1f} cm")
    return ob, dict(uv_used=round(float(used), 3), texel_cm=round(texel, 2))


def _unfold_floor(d, uv):
    """客席の床（段の踏み面と立ち上がり）を 1 つの島に広げる。段は Y にそった階段なので、
    (x, y + (最上段の高さ - z)) にすると、面の大きさのまま途切れずに並ぶ。横を向いた面（ブロックと通路の境目）は展開のまま。"""
    pos = d.corner_pos
    n = np.cross(pos[1::3] - pos[0::3], pos[2::3] - pos[0::3])
    side = np.abs(n[:, 0]) > np.maximum(np.abs(n[:, 1]), np.abs(n[:, 2]))
    corner = ~np.repeat(side, 3)
    out = uv.copy()
    # 横を向いた面は展開の結果を、ほかの面と同じ 1 m あたりの大きさにそろえる（詰め込みで並べ直される）
    out[corner, 0] = pos[corner, 0]
    out[corner, 1] = pos[corner, 1] + (C.ROW_Z[-1] - pos[corner, 2])
    a3 = _tri_area3(pos)[side].sum()
    auv = _tri_area2(uv.reshape(-1, 3, 2)[side].reshape(-1, 2)).sum()
    if a3 > 0 and auv > 0:
        out[~corner] = uv[~corner] * math.sqrt(a3 / auv)
    return out


def _debug_uv_image(uv, datas, spans, path, n=1024):
    """UV1 の配置の確認用の画像（オブジェクトごとに色を変えて三角形を塗る）。"""
    img = np.zeros((n, n, 3))
    rng = np.random.default_rng(1)
    for d, (a, b) in zip(datas, spans):
        col = rng.uniform(0.2, 1.0, 3)
        t = uv[a:b].reshape(-1, 3, 2) * n
        for tri in t:
            x0, y0 = np.floor(tri.min(0)).astype(int)
            x1, y1 = np.ceil(tri.max(0)).astype(int)
            if x1 - x0 > 400 or y1 - y0 > 400:
                xs, ys = np.meshgrid(np.arange(x0, x1) + 0.5, np.arange(y0, y1) + 0.5)
            else:
                xs, ys = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
            (ax, ay), (bx, by), (cx, cy) = tri
            den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            if abs(den) < 1e-12:
                continue
            w1 = ((by - cy) * (xs - cx) + (cx - bx) * (ys - cy)) / den
            w2 = ((cy - ay) * (xs - cx) + (ax - cx) * (ys - cy)) / den
            inside = (w1 >= 0) & (w2 >= 0) & (w1 + w2 <= 1)
            yy, xx = ys[inside].astype(int), xs[inside].astype(int)
            ok = (xx >= 0) & (xx < n) & (yy >= 0) & (yy < n)
            img[n - 1 - yy[ok], xx[ok]] = col
    T.save_png(path, img)


def seat_uv1(datas, n_units):
    """座席：単位ごとのマス（grid × grid）に、ひな形の UV1（0〜1）を縮めて入れる。"""
    grid = math.ceil(math.sqrt(n_units))
    pad = 1.5 / (SIZES["seats"]["house"] / grid)
    for d in datas:
        inst = np.repeat(d.tri_instance, 3)
        tx, ty = inst % grid, inst // grid
        d.uv1 = np.stack([(tx + pad + d.uv1[:, 0] * (1 - 2 * pad)) / grid, (ty + pad + d.uv1[:, 1] * (1 - 2 * pad)) / grid], 1)
    log(f"座席のライトマップ：単位 {n_units}、{grid} × {grid} のマス（1 マス {SIZES['seats']['house'] / grid:.0f} 画素）")
    return grid


def seat_templates(dg):
    """座席のひな形（Unit・UnitEnd・EndL × LOD0〜2）。番号の板（席番号・列の文字）は別のメッシュに分ける
    （アプリが席ごとに UV0 を番号のマスへ動かす）。UV1 はひな形の 0〜1 のまま（アプリが単位のマスへ移す）。
    マテリアルごとにも分け、1 つのメッシュは 1 つのマテリアルにする。"""
    out = []
    lods = {"s2": 0, "LOD1": 1, "LOD2": 2}
    for ob in bpy.data.collections["ASSETS"].objects:
        if not ob.name.startswith("Template_"):
            continue
        _, kind, suffix = ob.name.split("_")
        lod = lods[suffix]
        d = X.extract(ob, dg)
        # 部品（体・席番号の板・列の文字の板）× マテリアルごとに分ける。名前は「部品__マテリアル」（アプリが同じマテリアルをまとめる）
        for tag, part in ((0, "Body"), (1, "SeatPlate"), (2, "RowPlate")):
            for mi, mname in enumerate(d.mats):
                mask = (d.tri_tag == tag) & (d.tri_mat == mi)
                if not mask.any():
                    continue
                s = X.subset(d, mask, f"{part}__{mname}")
                s.group = f"SeatTemplates/{kind}_LOD{lod}"
                s.atlas, s.lod = "seats", lod
                out.append(s)
    log(f"座席のひな形：{len(out)} メッシュ（{sum(d.triangles for d in out):,} 三角形）")
    return out


def _edit(ob, fn):
    vl = bpy.context.view_layer
    for o in vl.objects:
        o.select_set(False)
    ob.select_set(True)
    vl.objects.active = ob
    ob.data.uv_layers.active = ob.data.uv_layers["UV1"]
    with bpy.context.temp_override(active_object=ob, object=ob, selected_objects=[ob], selected_editable_objects=[ob]):
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.uv.select_all(action="SELECT")
        fn()
        bpy.ops.object.mode_set(mode="OBJECT")


def _tri_area3(p):
    return 0.5 * np.linalg.norm(np.cross(p[1::3] - p[0::3], p[2::3] - p[0::3]), axis=1)


def _tri_area2(uv):
    a, b, c = uv[0::3], uv[1::3], uv[2::3]
    return 0.5 * np.abs((b[:, 0] - a[:, 0]) * (c[:, 1] - a[:, 1]) - (c[:, 0] - a[:, 0]) * (b[:, 1] - a[:, 1]))


# ================================================================ 焼き付け
def show_layer(layer, zones):
    for col in bpy.data.collections:
        if col.name.startswith("LIGHTS_"):
            for o in col.objects:
                o.hide_render = col.name != f"LIGHTS_{layer}"
    for z in zones:
        z.hide_render = layer != f"zone{z['tp_zone']}"


def one_sided_zone_material():
    """スクリーンの区画の発光を表の面（客席の側）だけにする（裏のスクリーンの面を照らさない）。"""
    m = bpy.data.materials["screen_zone_emit"]
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    inv = nt.nodes.new("ShaderNodeMath")
    inv.operation = "SUBTRACT"
    inv.inputs[0].default_value = 1.0
    nt.links.new(geo.outputs["Backfacing"], inv.inputs[1])
    nt.links.new(inv.outputs[0], em.inputs["Strength"])
    nt.links.new(em.outputs[0], out.inputs["Surface"])
    return m


def bake_atlas(scene, ob, atlas, mats, zones):
    """1 つのアトラスの全部の層を焼く。戻り値は層 → (光, 焼けた画素)。"""
    res = {}
    sizes = SIZES[atlas]
    for layer in ("house", "ambient"):
        show_layer(layer, zones)
        light, cov = B.bake(scene, ob, mats, sizes[layer], SAMPLES[layer], MARGIN_PX)
        res[layer] = _clean(light, cov)
    zl = []
    for z in ("L", "C", "R"):
        show_layer(f"zone{z}", zones)
        light, cov = B.bake(scene, ob, mats, sizes["screen"], SAMPLES["screen"], max(1, MARGIN_PX - 1))
        zl.append(_clean(light, cov) @ np.array([0.2126, 0.7152, 0.0722]))
    res["screen"] = np.stack(zl, axis=-1)
    return res


def _clean(light, cov):
    light = B.fill_holes(np.nan_to_num(light, nan=0.0, posinf=0.0), cov)
    if not FAST:
        light = B.denoise(light, WORK)
    return light


def encode(name, light, report, reserved=None):
    """光を ÷ k して 8 bit の sRGB の PNG にする。k は焼けた値の 99.9 パーセンタイル（明るい点は丸める）。
    reserved を渡すと、右上の予約のマスにその光を入れる（島を持たない灯具の光）。"""
    if reserved is not None:
        n = light.shape[0]
        r = max(1, RESERVED_PX * n // SIZES["room"]["house"])
        light = light.copy()
        light[n - r:, n - r:] = reserved
    k = float(max(np.percentile(light.max(axis=2), 99.9), 1e-4))
    # 暗い所の階調を残すため、光の平方根を入れる（シェーダーで 2 乗して戻す。8 bit でも暗部の段がつきにくい）
    img = np.sqrt(np.clip(light / k, 0.0, 1.0))
    T.save_png(os.path.join(TEX, name), T.lin_to_srgb(img[::-1]))
    report[name] = dict(k=round(k, 5), size=light.shape[0], mean=[round(float(v), 5) for v in light.reshape(-1, 3).mean(0)])
    return k


# ================================================================ 書き出し
def material_spec(name, atlas, lm):
    p = M.LIB[name]
    if p.get("tex"):
        albedo = ("tex", p["tex"])
    else:
        albedo = ("color", tuple(float(c) for c in T.srgb_to_lin(np.array(p.get("color", (0.5, 0.5, 0.5))))))
    spec = dict(albedo=albedo, lightmaps=lm[atlas])
    if p.get("emit"):
        col, strength, level = p["emit"]
        spec["emit"] = (("tex", p["tex"]) if col == "texture" else ("color", col), strength, level)
        if col != "texture":
            spec["albedo"] = ("color", tuple(float(c) for c in T.srgb_to_lin(np.array(p.get("color", (0.9, 0.9, 0.9))))))
    return spec


def write_state_texture():
    """照明の状態の既定（開場：客電・常時灯 1、スクリーンは消えている、全体の明るさ 1）。アプリは実行時に差し替える。"""
    px = np.zeros((1, U.STATE_WIDTH, 3))
    px[0, U.STATE_TEXELS["house"]] = 1.0
    px[0, U.STATE_TEXELS["ambient"]] = 1.0
    px[0, U.STATE_TEXELS["houseEmission"]] = 1.0
    px[0, U.STATE_TEXELS["exposure"]] = 1.0
    T.save_png(os.path.join(TEX, "light_state.png"), T.lin_to_srgb(px))


def copy_albedo_textures():
    src = os.path.join(OUT, "textures")
    for f in os.listdir(src):
        if f.endswith(".png"):
            with open(os.path.join(src, f), "rb") as a, open(os.path.join(TEX, f), "wb") as b:
                b.write(a.read())


def write_usd(datas, lm, layout_b, report):
    path = os.path.join(WORK, "Theater.usdc")
    if os.path.exists(path):
        os.remove(path)
    w = U.Writer(path)
    tris = 0
    for d in datas:
        keys = [w.material(f"{d.atlas}_{m}", material_spec(m, d.atlas, lm)) for m in d.mats]
        w.mesh(w.xform(d.group), d.name, d, keys)
        tris += d.triangles
    usdz = os.path.join(DEST, "Theater.usdz")
    os.makedirs(DEST, exist_ok=True)
    w.save_usdz(usdz)
    report["usd"] = dict(meshes=len(datas), materials=len(w.materials), triangles_all_lods=tris,
                         usdz_mb=round(os.path.getsize(usdz) / 1e6, 2))
    log(f"USDZ：{usdz}（{report['usd']['usdz_mb']} MB、マテリアル {len(w.materials)}）")


def write_layout(templates, layout_b, grid):
    """アプリが使う配置（RealityKit の座標）。座席はひな形と、単位（ひな形を置く位置・ライトマップのマス）の一覧。"""
    def rk(p):
        return [round(float(v), 4) for v in U.to_rk(np.array(p))]

    seats = []
    for s in layout_b["seats"]:
        x, y, z = s["position"]
        seats.append(dict(id=s["id"], row=s["row"], rowIndex=s["rowIndex"], number=s["number"], block=s["block"],
                          group=s["group"], floor=rk((x, y, z)), eye=rk((x, y - C.SEAT_EYE_BACK, z + C.SEAT_EYE_HEIGHT))))
    units = []
    for i, u in enumerate(layout_b["units"]):
        group = f"{C.ROW_LETTERS[u['row']]}_{_block_of(u['position'][0])}"
        units.append(dict(kind=u["kind"], group=group, rowIndex=u["row"], number=u["number"], position=rk(u["position"]), tile=i))
    tris = {}
    for d in templates:
        key = d.group.split("/")[1]
        tris[key] = tris.get(key, 0) + d.triangles
    emitters = [dict(id=e["id"], bus=e["bus"], position=rk(e["position"]),
                     forward=[round(float(v), 4) for v in U.to_rk(np.array(e["forward"]))]) for e in layout_b["emitters"]]
    screen = dict(
        center=rk((0.0, C.SCREEN_Y, C.SCREEN_CENTER_Z)), radius=C.SCREEN_RADIUS, maxWidth=C.SCREEN_IMAGE_W,
        maxHeight=C.SCREEN_IMAGE_H, bottom=C.SCREEN_IMAGE_BOTTOM,
        masking=dict(top="MaskingTop", bottom="MaskingBottom", left="MaskingLeft", right="MaskingRight"),
        surface="ScreenSurface", projector=rk((0.0, C.ROOM_Y_REAR + 0.05, C.BOOTH_PORT_Z)))
    pad = 1.5 / (SIZES["seats"]["house"] / grid)
    layout = dict(version=1, unitOfLength="meters", coordinateSystem="RealityKit (Y up, -Z toward the screen)",
                  room=dict(min=rk((-C.ROOM_X, C.ROOM_Y_FRONT, 0.0)), max=rk((C.ROOM_X, C.ROOM_Y_REAR, C.CEILING_Z))),
                  screen=screen, seats=seats, units=units, emitters=emitters,
                  seatTemplates=dict(entity="SeatTemplates", triangles=tris, atlasGrid=grid, atlasPad=pad,
                                     plateCells=dict(columns=T.SEAT_PLATE_COLS, rows=T.SEAT_PLATE_ROWS, vSpan=0.5,
                                                     rowLetterOffset=sum(n for _, n in C.BLOCKS))),
                  lightState=dict(width=U.STATE_WIDTH, texels=U.STATE_TEXELS))
    with open(os.path.join(DEST, "TheaterLayout.json"), "w", encoding="utf-8") as f:
        json.dump(layout, f, ensure_ascii=False, indent=1)


def _block_of(x):
    for name, _, x0, x1 in C.blocks():
        if x0 - 0.2 <= x <= x1 + 0.2:
            return name
    return "C"


def main():
    t0 = time.time()
    scale_for_fast()
    bpy.ops.wm.open_mainfile(filepath=os.path.join(OUT, "theater.blend"))
    with open(os.path.join(OUT, "layout_blender.json"), encoding="utf-8") as f:
        layout_b = json.load(f)
    os.makedirs(TEX, exist_ok=True)
    scene = bpy.context.scene
    dg = bpy.context.evaluated_depsgraph_get()
    theater = bpy.data.collections["THEATER"]
    exported = [o for o in theater.all_objects if o.type == "MESH" and o.get("tp_export", True)]
    datas = [X.extract(o, dg) for o in exported]
    room = [d for d in datas if d.atlas == "room"]
    seats = [d for d in datas if d.atlas == "seats"]
    log(f"書き出す物：建築 {len(room)}・座席 {len(seats)}（{time.time() - t0:.0f} 秒）")
    for o in exported:
        o.hide_render = True
    room_ob, room_rep = room_uv1(room, scene)
    grid = seat_uv1(seats, len(layout_b["units"]))
    seat_mats = []
    for d in seats:
        for m in d.mats:
            if m not in seat_mats:
                seat_mats.append(m)
    seat_ob, _ = X.join([d for d in seats if d.lod == 0], "BAKE_seats", [bpy.data.materials[n] for n in seat_mats])
    templates = seat_templates(dg)
    zones = list(bpy.data.collections["BAKE_screen"].objects)
    zone_mat = one_sided_zone_material()
    device = B.setup_cycles(scene, 64)
    mats = B.replace_materials(zone_mat)
    log(f"焼き付け（{device}）")
    report = dict(device=device, fast=FAST, room=room_rep, textures={})
    lm = {}
    for atlas, ob in (("room", room_ob), ("seats", seat_ob)):
        res = bake_atlas(scene, ob, atlas, mats, zones)
        lm[atlas] = {}
        for layer, light in res.items():
            name = f"lm_{atlas}_{layer}.png"
            reserved = RESERVED_LIGHT[layer] if atlas == "room" else None
            lm[atlas][layer] = (name, encode(name, light, report["textures"], reserved))
    write_state_texture()
    copy_albedo_textures()
    write_usd(room + templates, lm, layout_b, report)
    write_layout(templates, layout_b, grid)
    report["seconds"] = round(time.time() - t0)
    with open(os.path.join(OUT, "export_report.json" if not FAST else "export_report_fast.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=1)
    log(f"完了（{report['seconds']} 秒）")


main()
