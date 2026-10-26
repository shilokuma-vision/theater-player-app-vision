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
                quickPicks(stage)
                Text("スクリーン")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.25), in: Capsule())
                SeatMap(layout: stage.layout, current: stage.currentSeat) { seat in
                    choose(seat, on: stage)
                }
                if let seat = stage.currentSeat {
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

    private func choose(_ seat: Seat, on stage: TheaterStage) {
        appModel.preferences.seatID = seat.id
        Task {
            await stage.move(to: seat)
        }
    }
}

/// 座席の並び（ブロックの間に通路のすき間）
struct SeatMap: View {
    let layout: TheaterLayout
    let current: Seat?
    let choose: (Seat) -> Void

    var body: some View {
        let rows = Dictionary(grouping: layout.seats, by: \.rowIndex)
        VStack(spacing: 3) {
            ForEach(rows.keys.sorted(), id: \.self) { index in
                let seats = (rows[index] ?? []).sorted { $0.number < $1.number }
                HStack(spacing: 2) {
                    Text(seats.first?.row ?? "").font(.system(size: 10, weight: .semibold)).frame(width: 14)
                    ForEach(seats) { seat in
                        if seat.number > 1, let previous = seats.first(where: { $0.number == seat.number - 1 }),
                           previous.block != seat.block {
                            Color.clear.frame(width: 10, height: 1)
                        }
                        seatButton(seat)
                    }
                }
            }
        }
    }

    private func seatButton(_ seat: Seat) -> some View {
        let isCurrent = seat.id == current?.id
        return Button {
            choose(seat)
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(isCurrent ? Color.yellow : Color(red: 0.75, green: 0.18, blue: 0.22))
                .frame(width: 15, height: 15)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(seat.row) 列 \(seat.number) 番"))
    }
}
