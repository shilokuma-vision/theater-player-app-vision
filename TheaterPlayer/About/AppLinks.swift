//
//  AppLinks.swift
//  TheaterPlayer
//
//  アプリの外のページ（プライバシーポリシー・サポート）。ライセンスの画面から開く。
//  プライバシーポリシーは App Store Connect とアプリの中のどちらからも開けるようにする（ガイドライン 5.1.1(i)）。
//  App Store の掲載情報（AppStore/metadata/shared.json の privacyPolicyUrl・supportUrl）と同じ URL にする。
//

import Foundation

enum AppLinks {
    static let privacyPolicy = URL(string: "https://shilokuma.jp/privacy/theater-player/")!
    static let support = URL(string: "https://shilokuma.jp/about/")!
}
