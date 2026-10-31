//
//  SeatPicker.swift
//  TheaterPlayer
//
//  座席表。スクリーンを上にして、全体の座席表から区画（ブロック × 前後の列）を選び、広げた区画の席を選ぶ。選んだ席へ暗転して移る。
//  視線で光るボタンは、全体の座席表では区画の 12 個、広げた区画ではその区画の席（24〜72 個）だけにする。
//

import SwiftUI
import TheaterScene

struct SeatPicker: View {
    let stage: TheaterStage?
    @Binding var page: ControlPanel.Page
    @Environment(AppModel.self) private var appModel
    /// 広げている区画（nil なら全体の座席表）
    @State private var sectionID: SeatSection.ID?

    var body: some View {
        VStack(spacing: 12) {
            PageHeader(title: "Seats", page: $page)
            if let stage {
                let current = currentSeat(on: stage)
                quickPicks(stage)
                Text("Screen")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.25), in: Capsule())
                seats(stage, current: current?.id)
                    // 全体の座席表と広げた区画で高さをそろえ、パネル（と下のつまみ）が伸び縮みしないようにする
                    .frame(height: stage.seatChart.size.height)
                    // 席のボタンは choose を比べずに描き直しを省くので、舞台が替わったら作り直す（古い舞台の choose を持ち続けない）
                    .id(ObjectIdentifier(stage))
                if let seat = current {
                    Text("Your seat: \(seat.title)").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder private func seats(_ stage: TheaterStage, current: String?) -> some View {
        let chart = stage.seatChart
        if let section = chart.sections.first(where: { $0.id == sectionID }) {
            SeatSectionDetail(section: section, current: current) {
                sectionID = nil
            } choose: { seat in
                choose(seat, on: stage)
            }
        } else {
            SeatOverview(chart: chart, current: current) { section in
                sectionID = section.id
            }
        }
    }

    private func quickPicks(_ stage: TheaterStage) -> some View {
        HStack {
            ForEach(Self.picks, id: \.id) { pick in
                Button {
                    if let seat = stage.layout.seat(id: pick.id) {
                        // 選んだ席が見えるよう、全体の座席表に戻す
                        sectionID = nil
                        choose(seat, on: stage)
                    }
                } label: {
                    Text(pick.title).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private static let picks: [(id: String, title: LocalizedStringKey)] = [
        ("C-17", "Front"), ("G-17", "Center (Best)"), ("K-17", "Rear"), ("N-18", "Last Row")
    ]

    /// 選んでいる席。設定（Observable）から引く：移るのは暗転のあとで、映画館の側の席は View が見ていないため
    private func currentSeat(on stage: TheaterStage) -> Seat? {
        stage.layout.seat(id: appModel.preferences.seatID) ?? stage.currentSeat
    }

    private func choose(_ seat: Seat, on stage: TheaterStage) {
        appModel.preferences.seatID = seat.id
        Task {
            await stage.move(to: seat)
        }
    }
}

/// 全体の座席表。席は絵（光らない）で、その上に区画ごとのボタンを重ねる（視線で光るのは区画の枠）
struct SeatOverview: View {
    let chart: SeatChart
    /// 選んでいる席の id
    let current: String?
    let open: (SeatSection) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            SeatChartImage(chart: chart, current: current)
            ForEach(chart.sections) { section in
                if let frame = chart.sectionFrames[section.id] {
                    Button {
                        open(section)
                    } label: {
                        Color.clear
                            .frame(width: frame.width, height: frame.height)
                            .contentShape(.rect(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .contentShape(.hoverEffect, .rect(cornerRadius: 5))
                    .hoverEffect(.highlight)
                    .offset(x: frame.minX, y: frame.minY)
                    .accessibilityLabel(Text(section.title))
                }
            }
        }
        .frame(width: chart.size.width, height: chart.size.height, alignment: .topLeading)
    }
}

/// 広げた区画。区画の席を、番号つきの大きなボタンで並べる
struct SeatSectionDetail: View {
    let section: SeatSection
    /// 選んでいる席の id
    let current: String?
    let close: () -> Void
    let choose: (Seat) -> Void

    private static let spacing: CGFloat = 4
    /// 席を並べる幅（中央のブロックの 18 席が、パネルの幅に収まる）
    private static let seatsWidth: CGFloat = 620
    private static let maxSide: CGFloat = 40

    var body: some View {
        let columns = section.rows.map(\.seats.count).max() ?? 1
        let side = min(Self.maxSide, (Self.seatsWidth / CGFloat(columns)).rounded(.down) - Self.spacing)
        VStack(spacing: 10) {
            HStack {
                Button(action: close) {
                    Label("All Seats", systemImage: "chevron.left")
                }
                Spacer()
                Text(section.title).font(.headline)
                Spacer()
                // 見出しを真ん中に置くため、左のボタンと同じくらいの幅を空ける
                Color.clear.frame(width: 150, height: 1)
            }
            VStack(spacing: Self.spacing) {
                ForEach(section.rows) { row in
                    HStack(spacing: Self.spacing) {
                        Text(row.letter).font(.system(size: 13, weight: .semibold)).frame(width: 20)
                        ForEach(row.seats) { seat in
                            SeatButton(seat: seat, isCurrent: seat.id == current, side: side, choose: choose)
                                .equatable()
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// 広げた区画の席 1 つ（番号つき）。席を選び直したとき、色の変わる席だけを描き直す
/// （区画の席を全部描き直すと、選ぶたびにメインスレッドが止まる）
struct SeatButton: View, Equatable {
    let seat: Seat
    let isCurrent: Bool
    /// 四角の一辺
    let side: CGFloat
    let choose: (Seat) -> Void

    var body: some View {
        Button {
            choose(seat)
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(SeatColor.fill(isCurrent: isCurrent))
                .overlay {
                    Text(String(seat.number))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isCurrent ? .black : .white)
                }
                .frame(width: side, height: side)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(seat.title))
    }

    /// choose は比べない（同じ座席表のあいだは変わらない。舞台が替わったら座席表ごと作り直す）
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.seat.id == rhs.seat.id && lhs.isCurrent == rhs.isCurrent && lhs.side == rhs.side
    }
}

extension SeatSection {
    /// 「Center Block, Rows G–J」（語順が言語で違うので、ブロックごとに文全体を訳す）
    var title: String {
        let first = rows.first?.letter ?? ""
        let last = rows.last?.letter ?? ""
        return switch block {
        case "L": String(localized: "Left Block, Rows \(first)–\(last)")
        case "R": String(localized: "Right Block, Rows \(first)–\(last)")
        default: String(localized: "Center Block, Rows \(first)–\(last)")
        }
    }
}

extension Seat {
    /// 「Row G, Seat 17」
    var title: String {
        String(localized: "Row \(row), Seat \(number)")
    }
}
