//
//  TheaterLayout.swift
//  TheaterScene
//
//  映画館の配置（Tools/Theater/export_theater.py が書く TheaterLayout.json）。座標は RealityKit（Y が上、-Z がスクリーンの向き）、単位は m。
//

import Foundation

/// 映画館の配置。座席・座席のひな形の並べ方・スピーカーの位置・スクリーンの寸法を持つ
public struct TheaterLayout: Decodable, Sendable {
    public let version: Int
    public let room: RoomBounds
    public let screen: ScreenSpec
    public let seats: [Seat]
    public let units: [SeatUnit]
    public let emitters: [Emitter]
    public let seatTemplates: SeatTemplateSpec
    public let lightState: LightStateSpec

    /// アプリに入れた配置を読む
    public static func load(from url: URL) throws -> TheaterLayout {
        try JSONDecoder().decode(TheaterLayout.self, from: Data(contentsOf: url))
    }

    /// 座席を id（例：G-17）で引く
    public func seat(id: String) -> Seat? {
        seats.first { $0.id == id }
    }

    /// 列の文字の並び（前から）
    public var rowLetters: [String] {
        var seen = Set<String>()
        return seats.sorted { $0.rowIndex < $1.rowIndex }.compactMap { seen.insert($0.row).inserted ? $0.row : nil }
    }

    /// 座席表の列（前から）。席は席番号の順に並べ、ブロックの境目（通路）を印す
    public var seatRows: [SeatRow] {
        Dictionary(grouping: seats, by: \.rowIndex).sorted { $0.key < $1.key }.map { index, seats in
            let sorted = seats.sorted { $0.number < $1.number }
            let aisles = zip(sorted, sorted.dropFirst()).filter { left, right in
                right.number == left.number + 1 && left.block != right.block
            }
            return SeatRow(id: index, letter: sorted.first?.row ?? "", seats: sorted, aisleBefore: Set(aisles.map(\.1.id)))
        }
    }
}

/// 座席表の 1 列
public struct SeatRow: Sendable, Identifiable {
    /// 列の番号（前から 0）
    public let id: Int
    /// 列の文字（A〜N）
    public let letter: String
    /// 席番号の順（スクリーンに向かって左から）
    public let seats: [Seat]
    /// 通路のすぐ右の席（左どなりとブロックが違う）。座席表では、この席の前にすき間を空ける
    public let aisleBefore: Set<String>
}

/// 部屋の範囲
public struct RoomBounds: Decodable, Sendable {
    public let min: SIMD3<Float>
    public let max: SIMD3<Float>
}

/// 座席 1 つ
public struct Seat: Decodable, Sendable, Identifiable, Hashable {
    /// 「G-17」のような座席の番号
    public let id: String
    /// 列の文字（A〜N。I は使わない）
    public let row: String
    /// 列の番号（前から 0）
    public let rowIndex: Int
    /// 席番号（スクリーンに向かって左から 1）
    public let number: Int
    /// ブロック（L・C・R）
    public let block: String
    /// 座席のまとまり（列 × ブロック。例：G_C）
    public let group: String
    /// 座席の中心の床
    public let floor: SIMD3<Float>
    /// 座ったときの目の位置
    public let eye: SIMD3<Float>
}

/// 座席のひな形を置く単位（座席＋右の肘掛け、ブロックの端の袖など）
public struct SeatUnit: Decodable, Sendable {
    /// ひな形の種類（Unit・UnitEnd・EndL）
    public let kind: String
    /// 座席のまとまり
    public let group: String
    public let rowIndex: Int
    /// 席番号（袖だけの単位は nil）
    public let number: Int?
    /// 置く位置（ひな形の原点）
    public let position: SIMD3<Float>
    /// ライトマップのマスの番号
    public let tile: Int
}

/// 空間オーディオの音源（スピーカー）
public struct Emitter: Decodable, Sendable, Identifiable {
    public let id: String
    /// 系統（L・C・R・LFE・Lss・Rss・Lrs・Rrs・Ltf・Rtf・Ltr・Rtr）
    public let bus: String
    public let position: SIMD3<Float>
    /// スピーカーの正面の向き
    public let forward: SIMD3<Float>
}

/// スクリーンの寸法（曲面）
public struct ScreenSpec: Decodable, Sendable {
    /// 映像の最大の範囲の中心（曲面の頂点）
    public let center: SIMD3<Float>
    /// 曲面の半径
    public let radius: Float
    /// 映像の最大の幅（弦の長さ）と高さ
    public let maxWidth: Float
    public let maxHeight: Float
    /// 映像の下端の高さ
    public let bottom: Float
    /// マスキングのエンティティの名前
    public let masking: MaskingNames
    /// 映像を出していないときのスクリーンの面のエンティティの名前
    public let surface: String
    /// 映写機のレンズの位置
    public let projector: SIMD3<Float>
}

/// マスキング（上下左右の黒い幕）のエンティティの名前
public struct MaskingNames: Decodable, Sendable {
    public let top: String
    public let bottom: String
    public let left: String
    public let right: String
}

/// 座席のひな形と、ライトマップのアトラス・番号の板の並び
public struct SeatTemplateSpec: Decodable, Sendable {
    /// ひな形の親のエンティティの名前
    public let entity: String
    /// ひな形ごとの三角形の数（例：Unit_LOD0）
    public let triangles: [String: Int]
    /// ライトマップのアトラスのマスの数（一辺）
    public let atlasGrid: Int
    /// マスの内側の余白（マスの大きさに対する割合）
    public let atlasPad: Float
    public let plateCells: PlateCellSpec
}

/// 番号の板（座席の画像の下半分に並んだ、席番号と列の文字）
public struct PlateCellSpec: Decodable, Sendable {
    public let columns: Int
    public let rows: Int
    /// 板の並ぶ範囲の高さ（V の 0〜vSpan）
    public let vSpan: Float
    /// 列の文字の最初のマスの番号（その前は席番号 1〜）
    public let rowLetterOffset: Int

    /// index 番目のマスの左下（u, v）と大きさ
    public func cell(_ index: Int) -> (origin: SIMD2<Float>, size: SIMD2<Float>) {
        let size = SIMD2<Float>(1 / Float(columns), vSpan / Float(rows))
        let column = index % columns
        let row = index / columns
        return (SIMD2(Float(column) * size.x, vSpan - Float(row + 1) * size.y), size)
    }
}

/// 照明の状態の画像（すべてのマテリアルが読む、横に並んだ数画素）
public struct LightStateSpec: Decodable, Sendable {
    public let width: Int
    /// 項目ごとの画素の番号（house・ambient・zoneL・zoneC・zoneR・screenAverage・houseEmission・exposure）
    public let texels: [String: Int]
}
