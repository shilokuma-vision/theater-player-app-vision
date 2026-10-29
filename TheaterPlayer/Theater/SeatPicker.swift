//
//  SeatPicker.swift
//  TheaterPlayer
//
//  座席表。スクリーンを上にして、列（A〜N）と席番号を並べる。選んだ席へ暗転して移る。
//

import SwiftUI
import TheaterScene

struct SeatPicker: View {
    let stage: TheaterStage?
    @Binding var page: ControlPanel.Page
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 12) {
            PageHeader(title: "座席", page: $page)
            if let stage {
                let current = currentSeat(on: stage)
                quickPicks(stage)
                Text("スクリーン")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.25), in: Capsule())
                SeatMap(rows: stage.seatRows, current: current?.id) { seat in
                    choose(seat, on: stage)
                }
                // 席のボタンは choose を比べずに描き直しを省くので、舞台が替わったら作り直す（古い舞台の choose を持ち続けない）
                .id(ObjectIdentifier(stage))
                if let seat = current {
                    Text("いまの席：\(seat.row) 列 \(seat.number) 番").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        }
    }

    private func quickPicks(_ stage: TheaterStage) -> some View {
        HStack {
            ForEach(Self.picks, id: \.id) { pick in
                Button {
                    if let seat = stage.layout.seat(id: pick.id) {
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
        ("C-17", "前方"), ("G-17", "中央（おすすめ）"), ("K-17", "後方"), ("N-18", "最後列")
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

/// 座席の並び（ブロックの間に通路のすき間）
struct SeatMap: View {
    let rows: [SeatRow]
    /// 選んでいる席の id
    let current: String?
    let choose: (Seat) -> Void

    var body: some View {
        VStack(spacing: 3) {
            ForEach(rows) { row in
                HStack(spacing: 2) {
                    Text(row.letter).font(.system(size: 10, weight: .semibold)).frame(width: 14)
                    ForEach(row.seats) { seat in
                        if row.aisleBefore.contains(seat.id) {
                            Color.clear.frame(width: 10, height: 1)
                        }
                        SeatButton(seat: seat, isCurrent: seat.id == current, choose: choose)
                            .equatable()
                    }
                }
            }
        }
    }
}

/// 座席表の席 1 つ。席を選び直したとき、色の変わる席だけを描き直す
/// （全席のボタンを描き直すと、選ぶたびにメインスレッドが止まる）
struct SeatButton: View, Equatable {
    let seat: Seat
    let isCurrent: Bool
    let choose: (Seat) -> Void

    var body: some View {
        Button {
            choose(seat)
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(isCurrent ? Color.yellow : Color(red: 0.75, green: 0.18, blue: 0.22))
                .frame(width: 15, height: 15)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(seat.row) 列 \(seat.number) 番"))
    }

    /// choose は比べない（同じ座席表のあいだは変わらない。舞台が替わったら座席表ごと作り直す）
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.seat.id == rhs.seat.id && lhs.isCurrent == rhs.isCurrent
    }
}
