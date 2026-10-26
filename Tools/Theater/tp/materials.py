"""マテリアルの一覧。Blender の確認用の見た目（Principled BSDF）と、書き出しの情報（色の画像・繰り返し・発光）を 1 か所で決める。

書き出し（export_theater.py）では、照明を焼いたライトマップ × 色 ＋ 発光 × 照明の状態、の unlit のマテリアルになる。
- tex：色の画像（textures/ に書く）。無ければ color（sRGB）
- tile：画像の 1 回の繰り返しの大きさ（m）。面の向きで投影した UV（UV0）に使う。uv="mesh" なら部品に付けた UV0 を使う
- emit：発光（リニアの色、強さ、どの照明の状態で明るさが変わるか）
    house = 客電（明るさの調整で変わる）、ambient = 常時点いている灯（足元灯・誘導灯）、screen = スクリーンの明るさ（映写窓のレンズ）
- bake_emit：焼くときに周りを照らすか（スクリーンの面だけ。ほかの灯はライトで照らす）
"""
import os

import bpy
import numpy as np

from . import textures as tx

LIB = {
    # 建築
    "carpet": dict(tex="carpet.png", tile=1.2, rough=0.95),
    "stage_carpet": dict(tex="stage_carpet.png", tile=1.0, rough=0.95),
    "wall_fabric": dict(tex="wall_fabric.png", tile=0.6, rough=0.9),
    "wall_fabric_rear": dict(tex="wall_fabric_rear.png", tile=0.6, rough=0.9),
    "wood": dict(tex="wood.png", tile=1.6, rough=0.45),
    "plaster_dark": dict(tex="plaster_dark.png", tile=1.5, rough=0.9),
    "ceiling": dict(tex="ceiling.png", tile=2.0, rough=0.95),
    "cloud": dict(tex="cloud.png", tile=1.5, rough=0.9),
    "velvet_black": dict(tex="velvet_black.png", tile=0.8, rough=1.0),
    "riser": dict(tex="riser.png", tile=1.0, rough=0.9),
    "aluminum": dict(tex="aluminum.png", tile=0.5, rough=0.35, metal=1.0),
    "door": dict(tex="door.png", tile=1.0, rough=0.6),
    "glass_dark": dict(color=(0.02, 0.025, 0.03), rough=0.05),
    "screen": dict(color=(0.86, 0.86, 0.85), rough=0.8, kind="screen"),
    # スピーカー・灯具
    "speaker_paint": dict(tex="speaker_paint.png", tile=0.3, rough=0.6),
    "grille": dict(tex="grille.png", tile=0.045, rough=0.5, metal=0.6),
    "bracket": dict(color=(0.05, 0.05, 0.055), rough=0.5, metal=0.8),
    "badge": dict(color=(0.55, 0.55, 0.57), rough=0.3, metal=1.0),
    "trim_white": dict(color=(0.80, 0.80, 0.79), rough=0.4),
    "trim_black": dict(color=(0.04, 0.04, 0.045), rough=0.4, metal=0.5),
    "reflector": dict(color=(0.55, 0.55, 0.56), rough=0.25, metal=1.0),
    # 発光
    "downlight_lens": dict(color=(0.9, 0.9, 0.9), emit=((1.0, 0.80, 0.58), 1.6, "house")),
    "led_warm": dict(color=(0.9, 0.9, 0.9), emit=((1.0, 0.72, 0.42), 0.85, "house")),
    "led_step": dict(color=(0.9, 0.9, 0.9), emit=((1.0, 0.55, 0.20), 1.8, "ambient")),
    "led_stage": dict(color=(0.9, 0.9, 0.9), emit=((0.35, 0.45, 1.0), 0.6, "ambient")),
    "exit_sign": dict(tex="exit_sign.png", uv="mesh", emit=("texture", 1.4, "ambient")),
    "booth_glow": dict(color=(0.03, 0.03, 0.035), emit=((0.30, 0.34, 0.45), 0.05, "ambient")),
    "projector_lens": dict(color=(0.1, 0.1, 0.1), emit=((1.0, 1.0, 1.0), 2.0, "screen")),
    # 座席
    "seat_fabric": dict(tex="seat_fabric.png", tile=0.35, rough=0.95),
    "seat_hard": dict(tex="seat_atlas.png", uv="mesh", rough=0.5),
    "seat_light": dict(color=(0.9, 0.9, 0.9), emit=((1.0, 0.58, 0.25), 1.6, "ambient")),
}


def make_textures(out_dir, seat_labels):
    """色の画像を out_dir に書き、マテリアルの平均の色（リニア）を返す。"""
    gens = {
        "carpet.png": lambda: tx.carpet(1024),
        "stage_carpet.png": lambda: tx.speckle(512, (0.05, 0.05, 0.055), 3, 0.25, 120),
        "wall_fabric.png": lambda: tx.woven(1024, (0.27, 0.245, 0.24), 7, threads=110),
        "wall_fabric_rear.png": lambda: tx.woven(1024, (0.20, 0.19, 0.19), 8, threads=110),
        "wood.png": lambda: tx.wood(1024),
        "plaster_dark.png": lambda: tx.speckle(512, (0.16, 0.16, 0.17), 12, 0.2, 90),
        "ceiling.png": lambda: tx.speckle(512, (0.12, 0.12, 0.135), 13, 0.3, 150),
        "cloud.png": lambda: tx.speckle(512, (0.19, 0.19, 0.205), 14, 0.25, 130),
        "velvet_black.png": lambda: tx.velvet(512, (0.025, 0.025, 0.028), 15, 0.4),
        "riser.png": lambda: tx.speckle(512, (0.10, 0.10, 0.11), 16, 0.2, 100),
        "aluminum.png": lambda: tx.brushed(512, (0.55, 0.56, 0.58), 17),
        "door.png": lambda: tx.wood(512, (0.16, 0.11, 0.08), 18),
        "speaker_paint.png": lambda: tx.speckle(256, (0.06, 0.06, 0.065), 19, 0.18, 120),
        "grille.png": lambda: tx.grille(256, 8),
        "seat_fabric.png": lambda: tx.velvet(1024, (0.47, 0.06, 0.085), 20, 0.3),
        "seat_atlas.png": lambda: tx.seat_atlas(1024, seat_labels),
        "exit_sign.png": lambda: tx.exit_sign(512, 256),
    }
    avg = {}
    for name, fn in gens.items():
        img = fn()
        tx.save_png(os.path.join(out_dir, name), img)
        avg[name] = tuple(float(c) for c in tx.srgb_to_lin(img.reshape(-1, 3)).mean(axis=0))
    return avg


def albedo(name, tex_avg):
    """マテリアルの平均の色（リニア）。焼くときの代わりの色に使う。"""
    p = LIB[name]
    if p.get("tex") and p["tex"] in tex_avg:
        return tex_avg[p["tex"]]
    return tuple(float(c) for c in tx.srgb_to_lin(np.array(p.get("color", (0.5, 0.5, 0.5)))))


def build_blender_materials(tex_dir, tex_avg):
    """確認用（Blender で開いて見る・EEVEE の確認画像）のマテリアルを作る。名前 → bpy.types.Material。"""
    mats = {}
    for name, p in LIB.items():
        m = bpy.data.materials.new(name)
        nt = m.node_tree
        nt.nodes.clear()
        out = nt.nodes.new("ShaderNodeOutputMaterial")
        bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
        bsdf.inputs["Roughness"].default_value = p.get("rough", 0.8)
        bsdf.inputs["Metallic"].default_value = p.get("metal", 0.0)
        nt.links.new(bsdf.outputs[0], out.inputs["Surface"])
        if p.get("tex"):
            img = bpy.data.images.load(os.path.join(tex_dir, p["tex"]), check_existing=True)
            tex = nt.nodes.new("ShaderNodeTexImage")
            tex.image = img
            if p.get("uv") == "mesh":
                uvn = nt.nodes.new("ShaderNodeUVMap")
                uvn.uv_map = "UV0"
                nt.links.new(uvn.outputs[0], tex.inputs["Vector"])
            else:
                tex.projection = "BOX"
                tex.projection_blend = 0.2
                coord = nt.nodes.new("ShaderNodeTexCoord")
                scale = nt.nodes.new("ShaderNodeVectorMath")
                scale.operation = "SCALE"
                scale.inputs["Scale"].default_value = 1.0 / p["tile"]
                nt.links.new(coord.outputs["Object"], scale.inputs[0])
                nt.links.new(scale.outputs[0], tex.inputs["Vector"])
            nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
            if p.get("emit") and p["emit"][0] == "texture":
                nt.links.new(tex.outputs["Color"], bsdf.inputs["Emission Color"])
        else:
            c = tx.srgb_to_lin(np.array(p.get("color", (0.5, 0.5, 0.5))))
            bsdf.inputs["Base Color"].default_value = (*c, 1.0)
        if p.get("emit") and p["emit"][0] != "texture":
            bsdf.inputs["Emission Color"].default_value = (*p["emit"][0], 1.0)
        if p.get("emit"):
            bsdf.inputs["Emission Strength"].default_value = p["emit"][1]
        m["tp_albedo"] = albedo(name, tex_avg)
        mats[name] = m
    return mats
