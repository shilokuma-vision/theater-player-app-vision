//
//  PanelPlacement.swift
//  TheaterPlayer
//
//  映画館の中の操作パネルの置き方。パネル（RealityView の添付）は ControlPanelRoot の中に入れ、
//  その下の「つまみ」（visionOS の窓のバーと同じ形）をつまんでドラッグすると、パネルごと動かせる。
//  どこへ動かしても、パネルは座った目の高さへ向ける。
//

import RealityKit
import SwiftUI

enum PanelPlacement {
    /// 既定の位置（座ったときのひざの少し上、目の前）
    static let defaultPosition = SIMD3<Float>(0, 0.78, -0.6)
    /// パネルを向ける目の高さ（座ったとき）
    static let eyeHeight: Float = 1.2
    static let rootName = "ControlPanelRoot"
    static let handleName = "ControlPanelHandle"
    /// つまみとパネルの下の端のすき間
    private static let handleGap: Float = 0.03

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

    /// つまみ（パネルの下の小さなバー）。視線を向けると光り、つまんでドラッグできる
    static func makeHandle() -> ModelEntity {
        var material = UnlitMaterial(color: .white)
        material.blending = .transparent(opacity: 0.55)
        let handle = ModelEntity(mesh: .generateBox(width: 0.12, height: 0.012, depth: 0.004, cornerRadius: 0.006), materials: [material])
        handle.name = handleName
        // つまみやすいよう、当たり判定は見た目より大きくする
        handle.components.set(CollisionComponent(shapes: [.generateBox(width: 0.22, height: 0.06, depth: 0.04)]))
        handle.components.set(InputTargetComponent())
        handle.components.set(HoverEffectComponent())
        return handle
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
