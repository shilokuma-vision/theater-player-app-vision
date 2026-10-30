//
//  SeatChart.swift
//  TheaterPlayer
//
//  全体の座席表の絵。442 席を 1 枚の絵（Canvas）として描き、席ごとのボタンは作らない
//  （ボタン 1 つごとにシステムが視線の効果を描くので、442 個あるとパネルを動かすだけで重くなる）。
//

import SwiftUI
import TheaterScene

/// 全体の座席表の寸法。席の四角の位置を、列・席番号・通路・区画から決める（舞台を作るときに 1 度だけ求める）
struct SeatChart {
    static let seatSize: CGFloat = 15
    static let seatSpacing: CGFloat = 2
    static let rowSpacing: CGFloat = 3
    /// 通路（ブロックの境目）で足すすき間
    static let aisle: CGFloat = 12
    /// 前後の区画の間で足すすき間
    static let sectionGap: CGFloat = 8
    /// 区画の枠と、その中の席の四角との間
    static let outlineInset: CGFloat = 3
    /// 列の文字の幅（絵の左の端）
    static let letterWidth: CGFloat = 16

    let rows: [SeatRow]
    let sections: [SeatSection]
    /// 席の四角（席の id ごと）
    let seatFrames: [String: CGRect]
    /// 区画の枠（区画の id ごと）。枠の線と、区画のボタンの範囲
    let sectionFrames: [SeatSection.ID: CGRect]
    /// 列の文字を置く高さ（列の番号ごと）
    let rowCenters: [Int: CGFloat]
    let size: CGSize

    init(rows: [SeatRow], sections: [SeatSection]) {
        self.rows = rows
        self.sections = sections
        // 2 つめ以降の前後のまとまりの先頭の列の前に、すき間を空ける
        let bandStarts = Set(sections.compactMap { $0.rows.first?.id }).subtracting(rows.first.map { [$0.id] } ?? [])
        var seatFrames: [String: CGRect] = [:]
        var rowCenters: [Int: CGFloat] = [:]
        var width: CGFloat = 0
        var y = Self.outlineInset
        for row in rows {
            if bandStarts.contains(row.id) {
                y += Self.sectionGap
            }
            var x = Self.letterWidth + Self.outlineInset
            for seat in row.seats {
                if row.aisleBefore.contains(seat.id) {
                    x += Self.aisle
                }
                seatFrames[seat.id] = CGRect(x: x, y: y, width: Self.seatSize, height: Self.seatSize)
                x += Self.seatSize + Self.seatSpacing
            }
            width = max(width, x - Self.seatSpacing)
            rowCenters[row.id] = y + Self.seatSize / 2
            y += Self.seatSize + Self.rowSpacing
        }
        self.seatFrames = seatFrames
        self.rowCenters = rowCenters
        sectionFrames = Dictionary(uniqueKeysWithValues: sections.map { section in
            let frame = section.seats.compactMap { seatFrames[$0.id] }.reduce(CGRect.null) { $0.union($1) }
            return (section.id, frame.insetBy(dx: -Self.outlineInset, dy: -Self.outlineInset))
        })
        size = CGSize(width: width + Self.outlineInset, height: y - Self.rowSpacing + Self.outlineInset)
    }
}

/// 全体の座席表の絵（光らない）。選んでいる席を黄色にし、区画の枠を描く
struct SeatChartImage: View {
    let chart: SeatChart
    /// 選んでいる席の id
    let current: String?

    var body: some View {
        Canvas { context, _ in
            for frame in chart.sectionFrames.values {
                context.stroke(Path(roundedRect: frame, cornerRadius: 5), with: .color(.white.opacity(0.3)), lineWidth: 1)
            }
            for row in chart.rows {
                if let center = chart.rowCenters[row.id] {
                    context.draw(
                        Text(row.letter).font(.system(size: 10, weight: .semibold)),
                        at: CGPoint(x: SeatChart.letterWidth / 2, y: center)
                    )
                }
                for seat in row.seats {
                    if let frame = chart.seatFrames[seat.id] {
                        context.fill(Path(roundedRect: frame, cornerRadius: 3), with: .color(SeatColor.fill(isCurrent: seat.id == current)))
                    }
                }
            }
        }
        .frame(width: chart.size.width, height: chart.size.height)
        .accessibilityHidden(true)
    }
}

/// 座席の色（選んでいる席は黄色）
enum SeatColor {
    static func fill(isCurrent: Bool) -> Color {
        isCurrent ? .yellow : Color(red: 0.75, green: 0.18, blue: 0.22)
    }
}
