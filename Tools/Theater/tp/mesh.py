"""メッシュを組み立てる道具（bmesh）。

Part に箱・円柱・押し出しなどを足していき、最後に 1 つのオブジェクトにする。
面ごとにマテリアルの名前を持たせ、オブジェクトのマテリアルの枠（slot）は使った順に作る。
明示の UV（UV0）が要る面（表示・番号の板など）は uv を渡す。渡さない面の UV0 は書き出しのときに投影で作る。
"""
import math

import bmesh
import bpy
from mathutils import Matrix, Vector


def rot_z(deg):
    return Matrix.Rotation(math.radians(deg), 4, "Z")


def rot_x(deg):
    return Matrix.Rotation(math.radians(deg), 4, "X")


def rot_y(deg):
    return Matrix.Rotation(math.radians(deg), 4, "Y")


def loc(x, y, z):
    return Matrix.Translation(Vector((x, y, z)))


class Part:
    """1 つのオブジェクトになるメッシュ。"""

    def __init__(self, name):
        self.name = name
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.new("UV0")
        self.has_uv = self.bm.faces.layers.int.new("has_uv")
        self.tag = self.bm.faces.layers.int.new("tp_tag")
        self.mats = []

    def _mat(self, name):
        if name not in self.mats:
            self.mats.append(name)
        return self.mats.index(name)

    def _take(self, bm, matrix, mat, uv_fn=None, tag=0):
        """別の bmesh の中身を matrix で動かして取り込む。uv_fn(face, loop) → (u, v) を渡すと明示の UV を付ける。
        tag は面の印（tp_tag。座席の番号の板など、書き出しで見分ける面）。"""
        bm.transform(matrix)
        mi = self._mat(mat)
        vmap = {}
        for v in bm.verts:
            vmap[v.index] = self.bm.verts.new(v.co)
        src_uv = bm.loops.layers.uv.get("UV0")
        for f in bm.faces:
            try:
                nf = self.bm.faces.new([vmap[v.index] for v in f.verts])
            except ValueError:
                continue
            nf.material_index = mi
            nf.smooth = f.smooth
            nf[self.tag] = tag
            if uv_fn is not None or src_uv is not None:
                nf[self.has_uv] = 1
                for nl, ol in zip(nf.loops, f.loops):
                    nl[self.uv].uv = uv_fn(f, ol) if uv_fn is not None else ol[src_uv].uv
        bm.free()

    # ---------------------------------------------------------------- 形
    def box(self, size, matrix=None, mat="default", bevel=0.0, segments=2, uv_fn=None, smooth=False, tag=0):
        """原点を中心とする大きさ size の箱。bevel で角を丸める。"""
        bm = bmesh.new()
        bmesh.ops.create_cube(bm, size=1.0)
        bm.transform(Matrix.Diagonal((*size, 1.0)))
        if bevel > 0:
            bmesh.ops.bevel(bm, geom=list(bm.edges), offset=min(bevel, min(size) * 0.49), segments=segments,
                            profile=0.5, affect="EDGES", clamp_overlap=True)
        for f in bm.faces:
            f.smooth = smooth
        bm.verts.index_update()
        self._take(bm, matrix or Matrix(), mat, uv_fn, tag)
        return self

    def box_between(self, lo, hi, mat="default", bevel=0.0, segments=2, uv_fn=None, smooth=False):
        """2 つの角 lo・hi の間の箱（軸にそった向き）。"""
        size = [abs(h - l) for l, h in zip(lo, hi)]
        c = [(l + h) / 2 for l, h in zip(lo, hi)]
        return self.box(size, loc(*c), mat, bevel, segments, uv_fn, smooth)

    def cylinder(self, radius, depth, matrix=None, mat="default", segments=24, cap=True, radius2=None, smooth=True,
                 inside=False, uv_fn=None):
        """Z 軸にそった円柱（radius2 で円錐台）。原点は中心。inside なら内側を表にする（筒の中を見る物）。"""
        bm = bmesh.new()
        bmesh.ops.create_cone(bm, cap_ends=cap, cap_tris=False, segments=segments, radius1=radius,
                              radius2=radius if radius2 is None else radius2, depth=depth)
        for f in bm.faces:
            f.smooth = smooth and len(f.verts) == 4
            if inside:
                f.normal_flip()
        bm.verts.index_update()
        self._take(bm, matrix or Matrix(), mat, uv_fn)
        return self

    def disk(self, radius, matrix=None, mat="default", segments=24, uv=False, uv_fn=None):
        """Z の上を向いた円盤。uv なら 0〜1 の UV を付ける。"""
        bm = bmesh.new()
        bmesh.ops.create_circle(bm, cap_ends=True, cap_tris=False, segments=segments, radius=radius)
        bm.verts.index_update()
        fn = (lambda f, l: (0.5 + l.vert.co.x / (2 * radius), 0.5 + l.vert.co.y / (2 * radius))) if uv else uv_fn
        self._take(bm, matrix or Matrix(), mat, fn)
        return self

    def ring(self, r_in, r_out, matrix=None, mat="default", segments=32, uv_fn=None):
        """Z の上を向いた平らな輪。"""
        bm = bmesh.new()
        outer, inner = [], []
        for i in range(segments):
            a = 2 * math.pi * i / segments
            outer.append(bm.verts.new((r_out * math.cos(a), r_out * math.sin(a), 0)))
            inner.append(bm.verts.new((r_in * math.cos(a), r_in * math.sin(a), 0)))
        for i in range(segments):
            j = (i + 1) % segments
            bm.faces.new([inner[i], outer[i], outer[j], inner[j]])
        bm.verts.index_update()
        self._take(bm, matrix or Matrix(), mat, uv_fn)
        return self

    def quad(self, corners, mat="default", uv=None, toward=None, tag=0):
        """4 つの頂点の面。toward（向き）を渡すと、面の表がその向きになるように頂点の順を直す。uv は 4 つの (u, v)。"""
        corners = [Vector(c) for c in corners]
        if toward is not None and (corners[1] - corners[0]).cross(corners[2] - corners[0]).dot(Vector(toward)) < 0:
            corners = list(reversed(corners))
            if uv is not None:
                uv = list(reversed(uv))
        bm = bmesh.new()
        vs = [bm.verts.new(c) for c in corners]
        f = bm.faces.new(vs)
        bm.verts.index_update()
        fn = None
        if uv is not None:
            table = {id(v): uv[i] for i, v in enumerate(f.verts)}
            fn = lambda face, l: table[id(l.vert)]  # noqa: E731
        self._take(bm, Matrix(), mat, fn, tag)
        return self

    def grid(self, fn, nu, nv, mat="default", uv=None, smooth=True, toward=None):
        """パラメータ (u, v)（0〜1）から点を返す fn の格子の面。uv(u, v) を渡すと UV を付ける。
        toward（向き）を渡すと、面の表がその向きになるように裏返す。"""
        bm = bmesh.new()
        rows = [[bm.verts.new(fn(i / nu, j / nv)) for i in range(nu + 1)] for j in range(nv + 1)]
        for j in range(nv):
            for i in range(nu):
                f = bm.faces.new([rows[j][i], rows[j][i + 1], rows[j + 1][i + 1], rows[j + 1][i]])
                f.smooth = smooth
        if toward is not None:
            bm.normal_update()
            for f in bm.faces:
                if f.normal.dot(Vector(toward)) < 0:
                    f.normal_flip()
        bm.verts.index_update()
        cuv = None
        if uv is not None:
            pos = {}
            for j in range(nv + 1):
                for i in range(nu + 1):
                    pos[rows[j][i].index] = uv(i / nu, j / nv)
            cuv = lambda f, l: pos[l.vert.index]  # noqa: E731
        self._take(bm, Matrix(), mat, cuv)
        return self

    def extrude_profile(self, profile, path, mat="default", closed=False, smooth=True):
        """断面（xy の点の列。x = 横、y = 上）を path（点の列）にそって押し出す。断面は進む向きに直交させる。"""
        bm = bmesh.new()
        up = Vector((0, 0, 1))
        rings = []
        for i, p in enumerate(path):
            p = Vector(p)
            a = Vector(path[max(i - 1, 0)])
            b = Vector(path[min(i + 1, len(path) - 1)])
            t = (b - a).normalized()
            side = t.cross(up)
            if side.length < 1e-6:
                side = Vector((1, 0, 0))
            side.normalize()
            nup = side.cross(t).normalized()
            rings.append([bm.verts.new(p + side * q[0] + nup * q[1]) for q in profile])
        n = len(profile)
        for i in range(len(rings) - 1):
            for j in range(n - (0 if closed else 1)):
                k = (j + 1) % n
                f = bm.faces.new([rings[i][j], rings[i + 1][j], rings[i + 1][k], rings[i][k]])
                f.smooth = smooth
        bm.verts.index_update()
        self._take(bm, Matrix(), mat)
        return self

    def polygon_prism(self, outline, z0, z1, matrix=None, mat="default", top=True, bottom=False):
        """xy の多角形 outline（反時計回り）を z0〜z1 に押し出した柱。"""
        bm = bmesh.new()
        lo = [bm.verts.new((x, y, z0)) for x, y in outline]
        hi = [bm.verts.new((x, y, z1)) for x, y in outline]
        n = len(outline)
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new([lo[i], lo[j], hi[j], hi[i]])
        if top:
            bm.faces.new(hi)
        if bottom:
            bm.faces.new(list(reversed(lo)))
        bm.verts.index_update()
        self._take(bm, matrix or Matrix(), mat)
        return self

    def merge(self, other, matrix=None):
        """別の Part を（matrix で動かして）取り込む。マテリアルは名前で引き継ぐ。"""
        src = other.bm.copy()
        src.transform(matrix or Matrix())
        uvl = src.loops.layers.uv.get("UV0")
        hu = src.faces.layers.int.get("has_uv")
        tg = src.faces.layers.int.get("tp_tag")
        vmap = {}
        for v in src.verts:
            vmap[v] = self.bm.verts.new(v.co)
        for f in src.faces:
            try:
                nf = self.bm.faces.new([vmap[v] for v in f.verts])
            except ValueError:
                continue
            nf.material_index = self._mat(other.mats[f.material_index])
            nf.smooth = f.smooth
            if tg is not None:
                nf[self.tag] = f[tg]
            if hu is not None and f[hu]:
                nf[self.has_uv] = 1
                for nl, ol in zip(nf.loops, f.loops):
                    nl[self.uv].uv = ol[uvl].uv
        src.free()
        return self

    # ---------------------------------------------------------------- オブジェクトにする
    def build(self, collection, materials, props=None, location=None):
        """Blender のオブジェクトにする。materials は名前 → bpy.types.Material の表。props はカスタムプロパティ（書き出しの情報）。"""
        me = bpy.data.meshes.new(self.name)
        bmesh.ops.remove_doubles(self.bm, verts=list(self.bm.verts), dist=1e-5)
        self.bm.to_mesh(me)
        self.bm.free()
        for m in self.mats:
            me.materials.append(materials[m])
        ob = bpy.data.objects.new(self.name, me)
        if location is not None:
            ob.location = location
        collection.objects.link(ob)
        for k, v in (props or {}).items():
            ob[k] = v
        return ob
