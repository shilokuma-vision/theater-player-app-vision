"""照明の焼き付け（Cycles）。照明の層ごとに、拡散光（直接光＋間接光。色は含まない）をライトマップに焼く。

- 焼くあいだ、すべてのマテリアルを「平均の色だけの拡散」に置き換える（照り返しの色は残る。模様・発光・艶は持たない）
- 灯具の光る面は周りを照らさない（光はライトで作ってある）。スクリーンの 3 区画だけは発光の面で照らす
- 焼いた値 L は「色 × L = 見える明るさ（リニア）」になる光。アプリのシェーダーで 色 × Σ(層の L × 層の明るさ) にする
"""
import os
import time

import bpy
import numpy as np


def setup_cycles(scene, samples):
    scene.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    # 画面なし（-b）では、裏でカーネルを最適化し直す処理がキャッシュのパスが空で落ちることがある（Blender 5.2.3）
    prefs.kernel_optimization_level = "OFF"
    prefs.get_devices()
    device = "CPU"
    for d in prefs.devices:
        d.use = d.type == "METAL"
        if d.use:
            device = d.name
    scene.cycles.device = "GPU" if device != "CPU" else "CPU"
    c = scene.cycles
    c.samples = samples
    c.max_bounces = 6
    c.diffuse_bounces = 4
    c.glossy_bounces = 0
    c.transmission_bounces = 0
    c.transparent_max_bounces = 2
    c.sample_clamp_indirect = 8.0
    c.use_light_tree = True
    scene.render.bake.margin_type = "EXTEND"
    return device


def replace_materials(zone_material):
    """マテリアルを焼き付け用（平均の色の拡散と、焼く先の画像の節）に置き換える。スクリーンの区画の発光はそのまま。"""
    out = []
    for m in bpy.data.materials:
        if m == zone_material:
            continue
        albedo = tuple(m.get("tp_albedo", (0.5, 0.5, 0.5)))
        nt = m.node_tree
        nt.nodes.clear()
        o = nt.nodes.new("ShaderNodeOutputMaterial")
        b = nt.nodes.new("ShaderNodeBsdfDiffuse")
        b.inputs["Color"].default_value = (*albedo, 1.0)
        nt.links.new(b.outputs[0], o.inputs["Surface"])
        t = nt.nodes.new("ShaderNodeTexImage")
        t.name = "tp_target"
        nt.nodes.active = t
        out.append(m)
    return out


def set_target(mats, img):
    for m in mats:
        node = m.node_tree.nodes["tp_target"]
        node.image = img
        m.node_tree.nodes.active = node


def bake(scene, ob, mats, size, samples, margin):
    """ob（UV1 を持つ焼き付け用のメッシュ）に、今の照明を焼く。戻り値は (size, size, 3) の光と、焼けた画素の印。"""
    img = bpy.data.images.new(f"tp_bake_{ob.name}", size, size, alpha=True, float_buffer=True)
    img.colorspace_settings.name = "Non-Color"
    img.pixels.foreach_set(np.zeros(size * size * 4, np.float32))
    set_target(mats, img)
    scene.cycles.samples = samples
    vl = bpy.context.view_layer
    for o in vl.objects:
        o.select_set(False)
    ob.select_set(True)
    vl.objects.active = ob
    t0 = time.time()
    with bpy.context.temp_override(scene=scene, view_layer=vl, active_object=ob, object=ob, selected_objects=[ob],
                                   selected_editable_objects=[ob]):
        bpy.ops.object.bake(type="DIFFUSE", pass_filter={"DIRECT", "INDIRECT"}, target="IMAGE_TEXTURES", uv_layer="UV1",
                            margin=margin, margin_type="EXTEND", use_clear=False)
    px = np.empty(size * size * 4, np.float32)
    img.pixels.foreach_get(px)
    bpy.data.images.remove(img)
    px = px.reshape(size, size, 4).astype(np.float64)
    print(f"[bake] {ob.name} {size}px {samples} samples: {time.time() - t0:.0f} s", flush=True)
    return px[..., :3], px[..., 3] > 0.5


def fill_holes(img, mask, passes=24):
    """焼けていない画素を、まわりの焼けた画素の平均で埋める（ミップマップと補間で島の外の黒がにじまないように）。"""
    img = img.copy()
    mask = mask.copy()
    for _ in range(passes):
        if mask.all():
            break
        acc = np.zeros_like(img)
        cnt = np.zeros(mask.shape)
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)):
            m = np.roll(np.roll(mask, dy, 0), dx, 1)
            v = np.roll(np.roll(img, dy, 0), dx, 1)
            acc += v * m[..., None]
            cnt += m
        grow = (~mask) & (cnt > 0)
        img[grow] = acc[grow] / cnt[grow][:, None]
        mask = mask | grow
    img[~mask] = img[mask].mean(axis=0) if mask.any() else 0.0
    return img


def denoise(img, work, name="tp_denoise"):
    """コンポジターの Denoise（OIDN、HDR）でざらつきを取る。img は (h, w, 3) のリニアの値（下の行から）。"""
    h, w = img.shape[:2]
    src = bpy.data.images.new(f"{name}_src", w, h, alpha=True, float_buffer=True)
    src.colorspace_settings.name = "Non-Color"
    px = np.ones((h, w, 4), np.float32)
    px[..., :3] = img
    src.pixels.foreach_set(px.ravel())
    s = bpy.data.scenes.get("TP_denoise") or bpy.data.scenes.new("TP_denoise")
    s.render.engine = "BLENDER_WORKBENCH"
    s.render.resolution_x, s.render.resolution_y, s.render.resolution_percentage = w, h, 100
    s.view_settings.view_transform = "Standard"
    tree = bpy.data.node_groups.new(f"{name}_tree", "CompositorNodeTree")
    tree.interface.new_socket(name="Image", in_out="OUTPUT", socket_type="NodeSocketColor")
    ni = tree.nodes.new("CompositorNodeImage")
    ni.image = src
    dn = tree.nodes.new("CompositorNodeDenoise")
    dn.inputs["HDR"].default_value = True
    out = tree.nodes.new("NodeGroupOutput")
    tree.links.new(ni.outputs["Image"], dn.inputs["Image"])
    tree.links.new(dn.outputs["Image"], out.inputs[0])
    s.compositing_node_group = tree
    s.render.image_settings.media_type = "IMAGE"
    s.render.image_settings.file_format = "OPEN_EXR"
    s.render.image_settings.color_depth = "32"
    path = os.path.join(work, f"{name}.exr")
    s.render.filepath = path
    with bpy.context.temp_override(scene=s):
        bpy.ops.render.render(write_still=True, scene=s.name)
    r = bpy.data.images.load(path)
    r.colorspace_settings.name = "Non-Color"
    a = np.empty(w * h * 4, np.float32)
    r.pixels.foreach_get(a)
    for im in (r, src):
        bpy.data.images.remove(im)
    bpy.data.node_groups.remove(tree)
    os.remove(path)
    return np.maximum(a.reshape(h, w, 4)[..., :3].astype(np.float64), 0.0)


def resample(img, size):
    """正方形の画像を size に縮める（面積の平均）。"""
    n = img.shape[0]
    if n == size:
        return img
    f = n // size
    return img[: size * f, : size * f].reshape(size, f, size, f, -1).mean(axis=(1, 3))
