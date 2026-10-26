"""映画館のモデルをスクリプトから作り、.blend と配置の JSON を書く。

実行: Tools/Theater/run.sh build_theater.py [--preview]
  出力は Tools/Theater/out/（theater.blend・layout_blender.json・textures/・preview_*.png）
  --preview を付けると、座席からの見た目を Cycles で描く（客電を点けた開場の状態と、上映中の状態）
"""
import json
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tp import config as C  # noqa: E402
from tp import lights, materials, room, seats, speakers  # noqa: E402

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
TEX = os.path.join(OUT, "textures")

# 確認用の視点：(名前, 座席, 見る点, 横の画角（度）)
VIEWS = [
    ("seat_G17_center", "G-17", (0.0, C.SCREEN_Y, C.SCREEN_CENTER_Z - 2.5), 84),
    ("seat_C9_front_left", "C-9", (1.5, C.SCREEN_Y, C.SCREEN_CENTER_Z), 84),
    ("seat_M30_rear_right", "M-30", (-1.0, C.SCREEN_Y, C.SCREEN_CENTER_Z - 0.5), 80),
    ("seat_G17_look_left", "G-17", (-C.ROOM_X, 10.0, 6.5), 84),
    ("seat_G17_look_up", "G-17", (0.0, 18.0, C.CEILING_Z), 84),
    ("seat_G17_look_back", "G-17", (0.0, 0.0, 9.5), 84),
    ("overview_from_stage", None, (0.0, 6.0, 4.5), 90),
]


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    world = bpy.data.worlds.new("World")
    world.color = (0, 0, 0)
    scene.world = world
    nt = world.node_tree
    bg = nt.nodes.get("Background") or nt.nodes.new("ShaderNodeBackground")
    bg.inputs["Color"].default_value = (0, 0, 0, 1)
    bg.inputs["Strength"].default_value = 0.0
    return scene


def zone_material():
    m = bpy.data.materials.new("screen_zone_emit")
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (1, 1, 1, 1)
    em.inputs["Strength"].default_value = 1.0
    nt.links.new(em.outputs[0], out.inputs["Surface"])
    return m


def seat_eye(seat):
    x, y, z = seat["position"]
    return (x, y - C.SEAT_EYE_BACK, z + C.SEAT_EYE_HEIGHT)


def add_camera(scene, name, eye, target, hfov):
    cam = bpy.data.cameras.new(name)
    cam.sensor_fit = "HORIZONTAL"
    cam.angle = math.radians(hfov)
    cam.clip_start = 0.05
    cam.clip_end = 200
    ob = bpy.data.objects.new(name, cam)
    ob.location = eye
    from mathutils import Vector
    ob.rotation_euler = (Vector(target) - Vector(eye)).to_track_quat("-Z", "Y").to_euler()
    scene.collection.objects.link(ob)
    return ob


def main():
    scene = reset()
    theater = bpy.data.collections.new("THEATER")
    scene.collection.children.link(theater)
    assets = bpy.data.collections.new("ASSETS")
    scene.collection.children.link(assets)
    bake = bpy.data.collections.new("BAKE_screen")
    scene.collection.children.link(bake)

    tex_avg = materials.make_textures(TEX, seats.labels())
    mats = materials.build_blender_materials(TEX, tex_avg)
    specs = {"house": [], "ambient": []}
    zones = {}
    room.build(theater, mats, specs["house"], specs["ambient"], zones)
    seat_info = seats.build(theater, assets, mats, specs["ambient"], scene)
    emitters = speakers.build(theater, mats)
    zmat = zone_material()
    for name, part in zones.items():
        ob = part.build(bake, {"screen": zmat}, {"tp_export": False, "tp_zone": name})
        ob.hide_render = True
    light_cols = lights.build(specs, scene.collection)
    for ob in assets.objects:
        ob.hide_render = True
        ob.hide_set(True)

    seats_by_id = {s["id"]: s for s in seat_info["seats"]}
    for name, sid, target, hfov in VIEWS:
        eye = seat_eye(seats_by_id[sid]) if sid else (0.0, C.STAGE_FRONT_Y - 0.5, 2.6)
        add_camera(scene, f"CAM_{name}", eye, target, hfov)
    scene.camera = bpy.data.objects[f"CAM_{VIEWS[0][0]}"]

    os.makedirs(OUT, exist_ok=True)
    layout = dict(
        seats=seat_info["seats"],
        groups={k: dict(row=g["row"], block=g["block"], units=g["units"]) for k, g in seat_info["groups"].items()},
        units=[dict(kind=u[0], row=u[1], number=u[2], position=u[3:]) for u in seat_info["units"]],
        templateTriangles={f"{k[0]}_LOD{k[1]}": v for k, v in seat_info["triangles"].items()},
        emitters=emitters,
        textureAverages=tex_avg,
        lights={k: len(v) for k, v in specs.items()},
    )
    with open(os.path.join(OUT, "layout_blender.json"), "w", encoding="utf-8") as f:
        json.dump(layout, f, ensure_ascii=False, indent=1)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "theater.blend"), compress=True)
    tris = sum(len(p.vertices) - 2 for o in theater.objects if o.type == "MESH" and not o.hide_render for p in o.data.polygons)
    print(f"[theater] objects={len(theater.objects)} lights={layout['lights']} triangles(LOD0)={tris:,} "
          f"seat templates={layout['templateTriangles']}")
    if "--preview" in ARGS:
        preview(scene, light_cols, bake)


def set_emission_levels(levels):
    """発光するマテリアル（灯具の光る面）の強さを、照明の層の明るさに合わせる（確認用の画像だけ。アプリでは照明の状態で変える）。"""
    for name, p in materials.LIB.items():
        if not p.get("emit") or p["emit"][2] not in levels:
            continue
        bsdf = bpy.data.materials[name].node_tree.nodes["Principled BSDF"]
        bsdf.inputs["Emission Strength"].default_value = p["emit"][1] * levels[p["emit"][2]]


def preview(scene, light_cols, bake):
    """座席からの見た目を Cycles で描く（確認用。焼き付けとは別）。"""
    scene.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.kernel_optimization_level = "OFF"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = d.type == "METAL"
    scene.cycles.device = "GPU"
    scene.cycles.samples = int(os.environ.get("TP_PREVIEW_SAMPLES", "96"))
    scene.cycles.use_denoising = True
    scene.cycles.max_bounces = 6
    scene.cycles.use_light_tree = True
    scene.render.resolution_x, scene.render.resolution_y = 1600, 900
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.look = "AgX - Base Contrast"
    scene.view_settings.exposure = float(os.environ.get("TP_PREVIEW_EXPOSURE", "0"))
    states = [("preshow", {"house": 1.0, "ambient": 1.0}, 0.35), ("feature", {"house": 0.0, "ambient": 1.0}, 0.6)]
    only = os.environ.get("TP_PREVIEW_VIEWS")
    for state, levels, screen in states:
        lights.set_levels(light_cols, levels)
        set_emission_levels(levels)
        for ob in bake.objects:
            ob.hide_render = False
            ob.active_material.node_tree.nodes["Emission"].inputs["Strength"].default_value = screen
        for name, _, _, _ in VIEWS:
            if only and name not in only.split(","):
                continue
            scene.camera = bpy.data.objects[f"CAM_{name}"]
            scene.render.filepath = os.path.join(OUT, f"preview_{state}_{name}.png")
            bpy.ops.render.render(write_still=True)
            print(f"[theater] rendered {scene.render.filepath}")


main()
