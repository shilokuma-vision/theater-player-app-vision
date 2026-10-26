"""照明：ライトの設定（dict）から Blender のライトを作る。照明の層ごとにコレクションを分ける。

層（アプリで明るさを別々に変える。焼き付けも層ごと）
  house：客電（ダウンライト・クラウドの間接照明・壁を洗う光）。明るさの調整と、上映の始まり・終わりで変わる
  ambient：常時点いている灯（通路の足元灯・袖の足元灯・誘導灯・舞台の縁の LED・映写室の薄明かり）
  screen：スクリーンの光（左・中央・右の 3 区画。映像の色に合わせてアプリが色を付ける）
"""
import bpy
from mathutils import Vector

LAYERS = ("house", "ambient")


def make(spec, collection):
    kind = spec["kind"]
    data = bpy.data.lights.new(spec["name"], kind)
    data.energy = spec["power"]
    data.color = spec.get("color", (1, 1, 1))
    if kind == "SPOT":
        data.spot_size = spec["spot"]
        data.spot_blend = spec.get("blend", 0.5)
        data.shadow_soft_size = spec.get("radius", 0.05)
        data.show_cone = False
    elif kind == "AREA":
        data.shape = "RECTANGLE"
        data.size, data.size_y = spec["size"]
        if "spread" in spec:
            data.spread = spec["spread"]
    elif kind == "POINT":
        data.shadow_soft_size = spec.get("radius", 0.05)
    ob = bpy.data.objects.new(spec["name"], data)
    ob.location = spec["location"]
    if "aim" in spec:
        d = Vector(spec["aim"]) - Vector(spec["location"])
        ob.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    elif "rotation" in spec:
        ob.rotation_euler = spec["rotation"]
    collection.objects.link(ob)
    return ob


def build(specs_by_layer, parent):
    cols = {}
    for layer, specs in specs_by_layer.items():
        col = bpy.data.collections.new(f"LIGHTS_{layer}")
        parent.children.link(col)
        for s in specs:
            make(s, col)
        cols[layer] = col
    return cols


def set_levels(cols, levels):
    """層ごとの明るさ（0 なら消す）。ライトの強さは作ったときの値 × 明るさ。"""
    for layer, col in cols.items():
        lv = levels.get(layer, 0.0)
        for ob in col.objects:
            if "tp_power" not in ob.data:
                ob.data["tp_power"] = ob.data.energy
            ob.data.energy = ob.data["tp_power"] * lv
            ob.hide_render = lv <= 0.0
