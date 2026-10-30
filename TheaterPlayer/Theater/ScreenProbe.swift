//
//  ScreenProbe.swift
//  TheaterPlayer
//
//  映像のスクリーンの診断ログ（-tp-diagnostics のときだけ）。途中から再生すると、音だけ鳴って映像が映らないことがあり、
//  スクリーンのエンティティの様子・VideoMaterial が映す renderer・外したスクリーンと前の舞台が解放されたかを追う。
//

@preconcurrency import AVFoundation
import Foundation
import RealityKit
import TheaterMedia

@MainActor
enum ScreenProbe {
    /// 片付けた物（外したスクリーン・閉じた舞台）。弱く持って、解放されたかを見る
    private final class Released {
        let label: String
        let time: TimeInterval
        weak var object: AnyObject?

        init(label: String, time: TimeInterval, object: AnyObject) {
            self.label = label
            self.time = time
            self.object = object
        }
    }

    private static var released: [Released] = []
    private static var lastReport: TimeInterval = 0

    private static var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// 片付けた物を覚える（解放されたら、次の報告で書く）
    static func track(_ object: AnyObject?, _ label: String) {
        guard Diagnostics.enabled, let object else {
            return
        }
        released.append(Released(label: label, time: now, object: object))
    }

    /// スクリーンのエンティティの様子
    static func describe(_ screen: ModelEntity?) -> String {
        guard let screen else {
            return "screen=なし"
        }
        let material = screen.model?.materials.first as? VideoMaterial
        let opacity = screen.components[OpacityComponent.self].map { String($0.opacity) } ?? "なし"
        return "screen=\(Diagnostics.id(screen)) scene=\(screen.scene != nil) active=\(screen.isActive) " +
            "enabled=\(screen.isEnabledInHierarchy) opacity=\(opacity) parent=\(screen.parent?.name ?? "なし") " +
            "material.renderer=\(Diagnostics.id(material?.videoRenderer)) material=\(Diagnostics.id(material?.__videoResource))"
    }

    /// 片付けた物のうち、まだ解放されていない物
    static func remaining() -> String {
        let alive = released.filter { $0.object != nil }
        guard !alive.isEmpty else {
            return "残っている物=なし"
        }
        let time = now
        return "残っている物=" + alive.map { "\($0.label)（\(String(format: "%.1f", time - $0.time)) 秒）" }.joined(separator: "、")
    }

    /// 1 秒ごとに、スクリーンの様子と、片付けた物が解放されたかを書く
    static func report(stage: Int, screen: ModelEntity?, room: Entity, engine: MediaPlayer?) {
        guard Diagnostics.enabled, now - lastReport >= 1 else {
            return
        }
        lastReport = now
        for item in released where item.object == nil {
            Diagnostics.log("解放された：\(item.label)（片付けてから \(String(format: "%.1f", now - item.time)) 秒以内）")
        }
        released.removeAll { $0.object == nil }
        let screens = room.children.filter { $0.name == "VideoScreen" }.count
        Diagnostics.log(
            "screen 舞台#\(stage) \(describe(screen)) engine.renderer=\(Diagnostics.id(engine?.videoRenderer)) " +
                "部屋の VideoScreen=\(screens) \(remaining())"
        )
    }
}
