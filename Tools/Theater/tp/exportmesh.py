"""書き出すメッシュを numpy の配列で扱う。

オブジェクトごとに、三角形に分けたメッシュ（ワールド座標）を取り出す。
  verts：頂点（同じ位置の頂点はまとめてある。ライトマップの UV の島を作るのに使う）
  tris：三角形の頂点の番号
  corner_normals・uv0：三角形の角ごとの法線と UV0
  tri_mat：三角形ごとのマテリアルの名前の番号（mats）
  tri_instance：座席の単位の番号（座席のみ。ほかは -1）
  uv1：ライトマップの UV（座席はひな形の UV1、建築は焼き付けのときに作る）
"""
import bmesh
import bpy
import numpy as np

from . import materials as M


class MeshData:
    def __init__(self, ob, name, group, role=None, lod=None, atlas="room"):
        self.ob, self.name, self.group, self.role, self.lod, self.atlas = ob, name, group, role, lod, atlas
        self.verts = self.tris = self.corner_normals = self.uv0 = self.uv1 = None
        self.tri_mat = self.tri_instance = self.tri_tag = None
        self.mats = []

    @property
    def corner_pos(self):
        return self.verts[self.tris.reshape(-1)]

    @property
    def triangles(self):
        return len(self.tris)


def extract(ob, depsgraph):
    """ob を三角形に分け、ワールド座標の MeshData にする。"""
    ev = ob.evaluated_get(depsgraph)
    me = ev.to_mesh()
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.triangulate(bm, faces=list(bm.faces), quad_method="BEAUTY", ngon_method="BEAUTY")
    bm.transform(ob.matrix_world)
    bm.normal_update()
    bm.verts.ensure_lookup_table()
    bm.faces.ensure_lookup_table()
    uv0l = bm.loops.layers.uv.get("UV0")
    uv1l = bm.loops.layers.uv.get("UV1")
    hu = bm.faces.layers.int.get("has_uv")
    inst = bm.faces.layers.int.get("tp_instance")
    n = len(bm.faces)
    d = MeshData(ob, ob.name, ob.get("tp_group", "Room/Misc"), ob.get("tp_role"), ob.get("tp_lod"), ob.get("tp_atlas", "room"))
    d.verts = np.array([v.co[:] for v in bm.verts], np.float64)
    d.tris = np.array([[l.vert.index for l in f.loops] for f in bm.faces], np.int64).reshape(n, 3)
    d.corner_normals = np.array([(l.vert.normal if f.smooth else f.normal)[:] for f in bm.faces for l in f.loops],
                                np.float64).reshape(n * 3, 3)
    d.mats = [m.name for m in ob.data.materials]
    d.tri_mat = np.array([f.material_index for f in bm.faces], np.int64)
    has_uv = np.array([f[hu] if hu is not None else 0 for f in bm.faces], bool)
    uv0 = np.array([l[uv0l].uv[:] if uv0l is not None else (0.0, 0.0) for f in bm.faces for l in f.loops],
                   np.float64).reshape(n * 3, 2)
    d.uv0 = _fill_box_uv(d, uv0, has_uv)
    if uv1l is not None:
        d.uv1 = np.array([l[uv1l].uv[:] for f in bm.faces for l in f.loops], np.float64).reshape(n * 3, 2)
    d.tri_instance = np.array([f[inst] for f in bm.faces], np.int64) if inst is not None else np.full(n, -1, np.int64)
    tag = bm.faces.layers.int.get("tp_tag")
    d.tri_tag = np.array([f[tag] for f in bm.faces], np.int64) if tag is not None else np.zeros(n, np.int64)
    bm.free()
    ev.to_mesh_clear()
    return d


def subset(d, tri_mask, name):
    """d の三角形のうち tri_mask の物だけの MeshData（頂点はそのまま持つ）。"""
    s = MeshData(d.ob, name, d.group, d.role, d.lod, d.atlas)
    corner = np.repeat(tri_mask, 3)
    s.verts, s.tris = d.verts, d.tris[tri_mask]
    s.corner_normals, s.uv0 = d.corner_normals[corner], d.uv0[corner]
    s.uv1 = d.uv1[corner] if d.uv1 is not None else None
    s.tri_mat, s.tri_instance, s.tri_tag = d.tri_mat[tri_mask], d.tri_instance[tri_mask], d.tri_tag[tri_mask]
    s.mats = d.mats
    used = np.unique(s.tris)
    remap = np.full(len(d.verts), -1, np.int64)
    remap[used] = np.arange(len(used))
    s.verts, s.tris = d.verts[used], remap[s.tris]
    return s


def _fill_box_uv(d, uv0, has_uv):
    """明示の UV が無い面の UV0：面の向きで、ワールド座標を素材の繰り返しの大きさで割った値（Blender の確認用の BOX 投影と同じ）。"""
    pos = d.corner_pos
    tri_n = np.cross(pos[1::3] - pos[0::3], pos[2::3] - pos[0::3])
    ax = np.argmax(np.abs(tri_n), axis=1)
    tile = np.array([M.LIB[d.mats[m]].get("tile", 1.0) if d.mats else 1.0 for m in d.tri_mat])
    out = uv0.copy()
    for k in range(3):
        sel = ~has_uv
        c = pos[k::3]
        u = np.where(ax == 0, c[:, 1], c[:, 0])
        v = np.where(ax == 2, c[:, 1], c[:, 2])
        out[k::3][sel, 0] = (u / tile)[sel]
        out[k::3][sel, 1] = (v / tile)[sel]
    return out


def join(datas, name, materials):
    """MeshData をつないだ、焼き付け用の Blender のオブジェクト（UV1 を持つ）と、データごとの角の範囲を返す。"""
    verts, faces, mats, uv1, spans = [], [], [], [], []
    names = [m.name for m in materials]
    vo = 0
    co = 0
    for d in datas:
        verts.append(d.verts)
        faces.append(d.tris + vo)
        mats.append(np.array([names.index(d.mats[m]) for m in d.tri_mat], np.int64))
        uv1.append(d.uv1 if d.uv1 is not None else np.zeros((d.triangles * 3, 2)))
        spans.append((co, co + d.triangles * 3))
        vo += len(d.verts)
        co += d.triangles * 3
    v = np.concatenate(verts)
    f = np.concatenate(faces)
    me = bpy.data.meshes.new(name)
    me.vertices.add(len(v))
    me.vertices.foreach_set("co", v.astype(np.float32).ravel())
    me.loops.add(len(f) * 3)
    me.loops.foreach_set("vertex_index", f.astype(np.int32).ravel())
    me.polygons.add(len(f))
    me.polygons.foreach_set("loop_start", np.arange(0, len(f) * 3, 3, dtype=np.int32))
    me.polygons.foreach_set("material_index", np.concatenate(mats).astype(np.int32))
    me.update(calc_edges=True)
    for m in materials:
        me.materials.append(m)
    lay = me.uv_layers.new(name="UV1")
    lay.data.foreach_set("uv", np.concatenate(uv1).astype(np.float32).ravel())
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    # 編集モードの演算子（UV の展開・詰め込み）で選べるよう、ビューレイヤーに反映する
    bpy.context.view_layer.update()
    return ob, spans


def get_uv(ob, name="UV1"):
    a = np.empty(len(ob.data.loops) * 2, np.float32)
    ob.data.uv_layers[name].data.foreach_get("uv", a)
    return a.reshape(-1, 2).astype(np.float64)


def set_uv(ob, uv, name="UV1"):
    ob.data.uv_layers[name].data.foreach_set("uv", uv.astype(np.float32).ravel())
