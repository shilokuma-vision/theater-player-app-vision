//
//  PanelPlacement.swift
//  TheaterPlayer
//
//  映画館の中の操作パネルの置き方。パネル（RealityView の添付）は ControlPanelRoot の中に入れ、
//  その下の「つまみ」（visionOS の窓のバーと同じ形）をつまんでドラッグすると、パネルごと動かせる。
//  どこへ動かしても、パネルは座った目の高さへ向ける。
//  つまみは、見ている間・掴んでいる間は窓のバーと同じく太く長く、明るくなる（Materials/PanelHandle.usda）。
//

import RealityKit
import RealityKitContent
import SwiftUI
import TheaterMedia

enum PanelPlacement {
    /// 既定の位置（座ったときのひざの少し上、目の前）
    static let defaultPosition = SIMD3<Float>(0, 0.78, -0.6)
    /// パネルを向ける目の高さ（座ったとき）
    static let eyeHeight: Float = 1.2
    static let rootName = "ControlPanelRoot"
    static let handleName = "ControlPanelHandle"
    /// つまみ（カプセルの中心）とパネルの下の端のすき間
    private static let handleGap: Float = 0.022
    /// つまみのカプセルの大きさ（幅・高さ）。通常と、見ている・掴んでいる間
    private static let handleIdleSize = SIMD2<Float>(0.096, 0.008)
    private static let handleActiveSize = SIMD2<Float>(0.108, 0.012)
    /// カプセルを描く板の大きさ（広げたカプセルと、縁のぼかしが入る）
    private static let handlePlaneSize = SIMD2<Float>(0.112, 0.016)
    /// つまみの白の不透明度。通常・見ている間・掴んでいる間
    private static let handleOpacity = (idle: Float(0.5), hover: Float(0.85), grab: Float(1))
    /// 掴んだ・離したときに、広がる・戻るまでの秒数
    private static let handleGrabFade: Float = 0.15
    /// つまみの当たり判定（つまみやすいよう、見た目より大きくする）
    private static let handleHitSize = SIMD3<Float>(0.22, 0.06, 0.04)

    /// root を position に置き、利用者（原点の上の目の高さ）へ向ける
    static func place(_ root: Entity, at position: SIMD3<Float>) {
        root.position = position
        root.orientation = facing(position)
    }

    /// position に置いたパネル（表は +Z）を、目の高さへ向ける回転
    static func facing(_ position: SIMD3<Float>) -> simd_quatf {
        let horizontal = max(hypot(position.x, position.z), 0.1)
        let yaw = atan2(-position.x, -position.z)
        // 目より下なら上へ、上なら下へ傾ける
        let pitch = -atan2(eyeHeight - position.y, horizontal)
        return simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
    }

    /// つまみ（パネルの下の細いカプセル）。見ると太く明るくなり、つまんでドラッグできる
    static func makeHandle() async -> ModelEntity {
        let handle = ModelEntity(mesh: .generatePlane(width: handlePlaneSize.x, height: handlePlaneSize.y))
        handle.name = handleName
        do {
            handle.model?.materials = [try await handleMaterial()]
            // 見ている間の変化は、マテリアル（Hover State）が描く
            handle.components.set(HoverEffectComponent(.shader(.default)))
        } catch {
            // 読めなければ、通常の形のカプセルにして、見ている間はシステムの光にする
            Diagnostics.log("つまみのマテリアルを読めなかった：\(error)")
            var material = UnlitMaterial(color: .white)
            material.blending = .transparent(opacity: .init(floatLiteral: handleOpacity.idle))
            handle.model = ModelComponent(
                mesh: .generatePlane(width: handleIdleSize.x, height: handleIdleSize.y, cornerRadius: handleIdleSize.y / 2),
                materials: [material]
            )
            handle.components.set(HoverEffectComponent())
        }
        // 当たり判定は、上の端をパネルの下の端にそろえる（つまみより少し下が中心になる）
        let hitShape = ShapeResource.generateBox(size: handleHitSize)
            .offsetBy(translation: SIMD3(0, handleGap - handleHitSize.y / 2, 0))
        handle.components.set(CollisionComponent(shapes: [hitShape]))
        handle.components.set(InputTargetComponent())
        return handle
    }

    private static func handleMaterial() async throws -> ShaderGraphMaterial {
        var material = try await ShaderGraphMaterial(
            named: "/Root/PanelHandle",
            from: "Materials/PanelHandle.usda",
            in: realityKitContentBundle
        )
        try material.setParameter(name: "PlaneSize", value: .simd2Float(handlePlaneSize))
        try material.setParameter(name: "IdleSize", value: .simd2Float(handleIdleSize))
        try material.setParameter(name: "ActiveSize", value: .simd2Float(handleActiveSize))
        try material.setParameter(name: "IdleOpacity", value: .float(handleOpacity.idle))
        try material.setParameter(name: "HoverOpacity", value: .float(handleOpacity.hover))
        try material.setParameter(name: "GrabOpacity", value: .float(handleOpacity.grab))
        try material.setParameter(name: "Grab", value: .float(0))
        return material
    }

    /// 掴んでいる間は、見ている間と同じ形で、いちばん明るくする（掴んだ・離したときは少しかけて変える）
    static func update(handle: ModelEntity, grabbing: Bool, deltaTime: Double) {
        guard var material = handle.model?.materials.first as? ShaderGraphMaterial else {
            return
        }
        let current: Float = if case let .float(value) = material.getParameter(name: "Grab") { value } else { 0 }
        let target: Float = grabbing ? 1 : 0
        guard current != target else {
            return
        }
        let step = Float(deltaTime) / handleGrabFade
        let next = current < target ? min(current + step, target) : max(current - step, target)
        try? material.setParameter(name: "Grab", value: .float(next))
        handle.model?.materials = [material]
    }

    /// つまみを、パネルの今の大きさ（畳んだ・ページを替えた）に合わせて、下の端のすぐ下へ置く
    static func follow(handle: Entity, panel: ViewAttachmentEntity) {
        let halfHeight = panel.attachment.bounds.extents.y / 2
        let target = SIMD3<Float>(0, -halfHeight - handleGap, 0)
        if handle.position != target {
            handle.position = target
        }
    }
}
