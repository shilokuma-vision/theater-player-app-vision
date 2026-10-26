"""USD（usdc）を pxr で書き、USDZ にまとめる。

- ステージは Y が上・単位はメートル。座標は (x, y, z) → (x, z, -y)（Blender の +Y = スクリーンの向き → RealityKit の -Z）
- メッシュは三角形。角ごとの法線・UV0（st）・ライトマップの UV（st1）。マテリアルが複数なら GeomSubset で分ける
- マテリアルは照明を焼いた unlit の MaterialX（ND_realitykit_unlit_surfaceshader、トーンマップなし）

    色 = 素材の色（UV0）× (客電の光 × 客電の明るさ ＋ 常時灯の光 × 常時灯の明るさ          ← 光 = 画像² × k
                          ＋ スクリーンの光.r × 左の区画の色 ＋ .g × 中央 ＋ .b × 右)   ← 光はライトマップ（UV1）
         ＋ 発光の色 × 発光の強さ × その層の明るさ
    出力 = 色 × 全体の明るさ

  層の明るさ・区画の色は、すべてのマテリアルが共有する小さな画像（照明の状態、8 × 1 画素）から読む。
  アプリはマテリアルの入力 lightState を、GPU で毎フレーム書き換える画像（LowLevelTexture）に差し替える。
"""
import os

import numpy as np
from pxr import Gf, Sdf, Usd, UsdGeom, UsdShade, UsdUtils, Vt

# 照明の状態の画像の画素（u = (i + 0.5) / 8）
STATE_TEXELS = {"house": 0, "ambient": 1, "zoneL": 2, "zoneC": 3, "zoneR": 4, "screenAverage": 5, "houseEmission": 6,
                "exposure": 7}
STATE_WIDTH = 8

C3, C4, F, F2 = Sdf.ValueTypeNames.Color3f, Sdf.ValueTypeNames.Color4f, Sdf.ValueTypeNames.Float, Sdf.ValueTypeNames.Float2
I, S, A, B = Sdf.ValueTypeNames.Int, Sdf.ValueTypeNames.String, Sdf.ValueTypeNames.Asset, Sdf.ValueTypeNames.Bool


def to_rk(p):
    p = np.asarray(p, np.float64)
    return np.stack([p[..., 0], p[..., 2], -p[..., 1]], axis=-1)


def prim_name(s):
    import re
    s = re.sub(r"[^A-Za-z0-9_]", "_", s)
    return "_" + s if not s or s[0].isdigit() else s


class Writer:
    def __init__(self, path, root="Theater"):
        self.path = path
        self.stage = Usd.Stage.CreateNew(path)
        UsdGeom.SetStageUpAxis(self.stage, UsdGeom.Tokens.y)
        UsdGeom.SetStageMetersPerUnit(self.stage, 1.0)
        self.root = f"/{root}"
        r = UsdGeom.Xform.Define(self.stage, self.root)
        self.stage.SetDefaultPrim(r.GetPrim())
        Usd.ModelAPI(r.GetPrim()).SetKind("component")
        UsdGeom.Scope.Define(self.stage, f"{self.root}/Materials")
        self.materials = {}

    # ---------------------------------------------------------------- 階層
    def xform(self, rel):
        path = self.root
        for part in rel.split("/"):
            path = f"{path}/{prim_name(part)}"
            if not self.stage.GetPrimAtPath(path):
                UsdGeom.Xform.Define(self.stage, path)
        return path

    # ---------------------------------------------------------------- メッシュ
    def mesh(self, parent, name, d, material_paths):
        """MeshData d を parent の下に書く。material_paths は d.mats と同じ順のマテリアルのパス。"""
        path = f"{parent}/{prim_name(name)}"
        m = UsdGeom.Mesh.Define(self.stage, path)
        m.CreateSubdivisionSchemeAttr("none")
        # 角ごとの（頂点・法線・UV0・UV1）が同じものを 1 つの頂点にまとめ、頂点ごとの値（vertex）で書く（ファイルを小さく）
        nrm = to_rk(d.corner_normals)
        nrm /= np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-9)
        cols = [d.tris.reshape(-1, 1).astype(np.float64), np.round(nrm * 1e4), np.round(d.uv0 * 1e5)]
        if d.uv1 is not None:
            cols.append(np.round(d.uv1 * 1e6))
        _, first, inverse = np.unique(np.concatenate(cols, axis=1), axis=0, return_index=True, return_inverse=True)
        pos = to_rk(d.verts[d.tris.reshape(-1)[first]])
        m.CreatePointsAttr(Vt.Vec3fArray.FromNumpy(pos.astype(np.float32)))
        m.CreateFaceVertexCountsAttr(Vt.IntArray.FromNumpy(np.full(d.triangles, 3, np.int32)))
        m.CreateFaceVertexIndicesAttr(Vt.IntArray.FromNumpy(inverse.reshape(-1).astype(np.int32)))
        m.CreateNormalsAttr(Vt.Vec3fArray.FromNumpy(nrm[first].astype(np.float32)))
        m.SetNormalsInterpolation(UsdGeom.Tokens.vertex)
        lo, hi = pos.min(axis=0), pos.max(axis=0)
        m.CreateExtentAttr(Vt.Vec3fArray([Gf.Vec3f(*lo.tolist()), Gf.Vec3f(*hi.tolist())]))
        pv = UsdGeom.PrimvarsAPI(m)
        st = pv.CreatePrimvar("st", Sdf.ValueTypeNames.TexCoord2fArray, UsdGeom.Tokens.vertex)
        st.Set(Vt.Vec2fArray.FromNumpy(d.uv0[first].astype(np.float32)))
        if d.uv1 is not None:
            st1 = pv.CreatePrimvar("st1", Sdf.ValueTypeNames.TexCoord2fArray, UsdGeom.Tokens.vertex)
            st1.Set(Vt.Vec2fArray.FromNumpy(d.uv1[first].astype(np.float32)))
        self.vertex_count = getattr(self, "vertex_count", 0) + len(first)
        used = sorted(set(d.tri_mat.tolist()))
        if len(used) == 1:
            UsdShade.MaterialBindingAPI.Apply(m.GetPrim()).Bind(self.materials[material_paths[used[0]]])
        else:
            UsdShade.MaterialBindingAPI.Apply(m.GetPrim())
            for mi in used:
                idx = np.nonzero(d.tri_mat == mi)[0].astype(np.int32)
                sub = UsdGeom.Subset.CreateGeomSubset(m, prim_name(d.mats[mi]), UsdGeom.Tokens.face,
                                                      Vt.IntArray.FromNumpy(idx), familyName="materialBind")
                UsdShade.MaterialBindingAPI.Apply(sub.GetPrim()).Bind(self.materials[material_paths[mi]])
        return path

    # ---------------------------------------------------------------- マテリアル
    def material(self, key, spec):
        """spec：albedo（("tex", ファイル) か ("color", リニアの rgb)）・lightmaps（house・ambient・screen のファイルと倍率）・
        emit（(("tex", ファイル) か ("color", rgb)), 強さ, 層）。"""
        if key in self.materials:
            return key
        mp = f"{self.root}/Materials/{prim_name(key)}"
        mat = UsdShade.Material.Define(self.stage, mp)
        state = mat.CreateInput("lightState", A)
        state.Set(Sdf.AssetPath("textures/light_state.png"))
        g = _Graph(self.stage, mp, mat)
        uv0 = g.node("uv0", "ND_texcoord_vector2", F2, index=(I, 0))
        uv1 = g.node("uv1", "ND_texcoord_vector2", F2, index=(I, 1))

        def state_color(name):
            u = (STATE_TEXELS[name] + 0.5) / STATE_WIDTH
            return g.node(f"state_{name}", "ND_image_color3", C3, file=(A, (mat, "lightState")), texcoord=(F2, Gf.Vec2f(u, 0.5)),
                          filtertype=(S, "closest"), uaddressmode=(S, "clamp"), vaddressmode=(S, "clamp"))

        kind, val = spec["albedo"]
        if kind == "tex":
            albedo = g.node("albedo", "ND_image_color3", C3, file=(A, Sdf.AssetPath(f"textures/{val}")),
                            texcoord=(F2, (uv0, "out")), uaddressmode=(S, "periodic"), vaddressmode=(S, "periodic"))
            albedo = (albedo, "out")
        else:
            albedo = Gf.Vec3f(*[float(c) for c in val])
        lm = spec["lightmaps"]
        terms = []
        for layer in ("house", "ambient"):
            img = g.node(f"lm_{layer}", "ND_image_color3", C3, file=(A, Sdf.AssetPath(f"textures/{lm[layer][0]}")),
                         texcoord=(F2, (uv1, "out")), uaddressmode=(S, "clamp"), vaddressmode=(S, "clamp"))
            squared = g.node(f"lm_{layer}_sq", "ND_multiply_color3", C3, in1=(C3, (img, "out")), in2=(C3, (img, "out")))
            k = g.node(f"lm_{layer}_k", "ND_multiply_color3FA", C3, in1=(C3, (squared, "out")), in2=(F, float(lm[layer][1])))
            terms.append(g.node(f"lit_{layer}", "ND_multiply_color3", C3, in1=(C3, (k, "out")),
                                in2=(C3, (state_color(layer), "out"))))
        scr = g.node("lm_screen", "ND_image_color3", C3, file=(A, Sdf.AssetPath(f"textures/{lm['screen'][0]}")),
                     texcoord=(F2, (uv1, "out")), uaddressmode=(S, "clamp"), vaddressmode=(S, "clamp"))
        scr_sq = g.node("lm_screen_sq", "ND_multiply_color3", C3, in1=(C3, (scr, "out")), in2=(C3, (scr, "out")))
        scr_k = g.node("lm_screen_k", "ND_multiply_color3FA", C3, in1=(C3, (scr_sq, "out")), in2=(F, float(lm["screen"][1])))
        sep = g.separate("lm_screen_split", scr_k)
        for ch, zone in (("outr", "zoneL"), ("outg", "zoneC"), ("outb", "zoneR")):
            terms.append(g.node(f"lit_{zone}", "ND_multiply_color3FA", C3, in1=(C3, (state_color(zone), "out")),
                                in2=(F, (sep, ch))))
        light = terms[0]
        for i, t in enumerate(terms[1:]):
            light = g.node(f"light_sum{i}", "ND_add_color3", C3, in1=(C3, (light, "out")), in2=(C3, (t, "out")))
        color = g.node("lit", "ND_multiply_color3", C3, in1=(C3, albedo), in2=(C3, (light, "out")))
        if spec.get("emit"):
            (ekind, eval_), strength, level = spec["emit"]
            if ekind == "tex":
                ecol = (g.node("emit_tex", "ND_image_color3", C3, file=(A, Sdf.AssetPath(f"textures/{eval_}")),
                               texcoord=(F2, (uv0, "out")), uaddressmode=(S, "clamp"), vaddressmode=(S, "clamp")), "out")
            else:
                ecol = Gf.Vec3f(*[float(c) for c in eval_])
            lv = {"house": "houseEmission", "ambient": "ambient", "screen": "screenAverage"}[level]
            e1 = g.node("emit_level", "ND_multiply_color3", C3, in1=(C3, ecol), in2=(C3, (state_color(lv), "out")))
            e2 = g.node("emit_strength", "ND_multiply_color3FA", C3, in1=(C3, (e1, "out")), in2=(F, float(strength)))
            color = g.node("lit_emit", "ND_add_color3", C3, in1=(C3, (color, "out")), in2=(C3, (e2, "out")))
        sep7 = g.separate("exposure_split", state_color("exposure"))
        final = g.node("exposed", "ND_multiply_color3FA", C3, in1=(C3, (color, "out")), in2=(F, (sep7, "outr")))
        sh = UsdShade.Shader.Define(self.stage, f"{mp}/unlit")
        sh.CreateIdAttr("ND_realitykit_unlit_surfaceshader")
        sh.CreateInput("color", C3).ConnectToSource(final.ConnectableAPI(), "out")
        sh.CreateInput("opacity", F).Set(1.0)
        sh.CreateInput("applyPostProcessToneMap", B).Set(False)
        sh.CreateInput("hasPremultipliedAlpha", B).Set(False)
        sh.CreateOutput("out", Sdf.ValueTypeNames.Token)
        mat.CreateOutput("mtlx:surface", Sdf.ValueTypeNames.Token).ConnectToSource(sh.ConnectableAPI(), "out")
        self.materials[key] = mat
        return key

    def save_usdz(self, usdz):
        self.stage.GetRootLayer().Save()
        here = os.getcwd()
        os.chdir(os.path.dirname(self.path))
        try:
            if os.path.exists(usdz):
                os.remove(usdz)
            ok = UsdUtils.CreateNewARKitUsdzPackage(Sdf.AssetPath(os.path.basename(self.path)), usdz)
        finally:
            os.chdir(here)
        if not ok:
            raise RuntimeError("USDZ にまとめられませんでした")


class _Graph:
    def __init__(self, stage, mp, mat):
        self.stage, self.mp, self.mat = stage, mp, mat

    def node(self, name, nid, out_type, **inputs):
        sh = UsdShade.Shader.Define(self.stage, f"{self.mp}/{name}")
        sh.CreateIdAttr(nid)
        for k, (ty, v) in inputs.items():
            i = sh.CreateInput(k, ty)
            if isinstance(v, tuple) and len(v) == 2 and isinstance(v[0], UsdShade.Material):
                i.ConnectToSource(v[0].GetInput(v[1]))
            elif isinstance(v, tuple) and len(v) == 2 and isinstance(v[0], UsdShade.Shader):
                i.ConnectToSource(v[0].ConnectableAPI(), v[1])
            else:
                i.Set(v)
        sh.CreateOutput("out", out_type)
        return sh

    def separate(self, name, src):
        sh = UsdShade.Shader.Define(self.stage, f"{self.mp}/{name}")
        sh.CreateIdAttr("ND_separate3_color3")
        sh.CreateInput("in", C3).ConnectToSource(src.ConnectableAPI(), "out")
        for o in ("outr", "outg", "outb"):
            sh.CreateOutput(o, F)
        return sh
