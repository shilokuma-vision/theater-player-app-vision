// swift-tools-version:6.2
// 映画館の空間（RealityKit）と、映画館の音響（音声処理）。visionOS のアプリと、macOS の確認用の道具（Tools/Theater/RKPreview）から使う。

import PackageDescription

let package = Package(
    name: "TheaterCore",
    platforms: [
        // アプリの Deployment Target（Configs/Project.xcconfig の XROS_DEPLOYMENT_TARGET）と揃える
        .visionOS(.v26),
        // 確認用の道具（RealityKit で描いて確かめる）と、音声処理の手元のテスト
        .macOS(.v26)
    ],
    products: [
        .library(name: "TheaterScene", targets: ["TheaterScene"]),
        .library(name: "CinemaAudio", targets: ["CinemaAudio"])
    ],
    targets: [
        .target(
            name: "TheaterScene",
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility")
            ]
        ),
        .target(
            name: "CinemaAudio",
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility")
            ]
        ),
        .testTarget(
            name: "CinemaAudioTests",
            dependencies: ["CinemaAudio"]
        ),
        .testTarget(
            name: "TheaterSceneTests",
            dependencies: ["TheaterScene"]
        )
    ]
)
