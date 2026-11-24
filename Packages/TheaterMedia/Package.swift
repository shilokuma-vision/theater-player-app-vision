// swift-tools-version:6.2
// 動画・音楽の再生（FFmpeg でファイルを開いてデコードし、映像は RealityKit のスクリーンへ、音声は映画館の音響処理へ渡す）。
// FFmpeg は GitHub の Release に置いた FFmpeg.xcframework を binaryTarget で取る（作り方は scripts/build-ffmpeg.sh、置き方は scripts/publish-ffmpeg-release.sh）。

import PackageDescription

let package = Package(
    name: "TheaterMedia",
    // エラーの文言の元の言語（アプリの開発の言語と揃える）。訳は Sources/TheaterMedia/Localizable.xcstrings
    defaultLocalization: "en",
    platforms: [
        // アプリの Deployment Target（Configs/Project.xcconfig の XROS_DEPLOYMENT_TARGET）と揃える
        .visionOS(.v26)
    ],
    products: [
        .library(name: "TheaterMedia", targets: ["TheaterMedia"])
    ],
    dependencies: [
        .package(path: "../TheaterCore")
    ],
    targets: [
        // FFmpeg は scripts/build-ffmpeg.sh で作り、scripts/publish-ffmpeg-release.sh で GitHub の Release に置いたもの（LGPL のソースも同じ Release にある）。
        // 作り方を変えて作り直したら、そのスクリプトが出す url と checksum に替える
        .binaryTarget(
            name: "FFmpeg",
            url: "https://github.com/shilokuma-vision/theater-player-app-vision/releases/download/ffmpeg-9.0.2-dav1d-1.5.4-afc831a6/FFmpeg.xcframework.zip",
            checksum: "0523d786444f7a7df744859c2fb88f15147b619e8655006984aaac84afb1bbf9"
        ),
        .target(
            name: "CFFmpeg",
            dependencies: ["FFmpeg"],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("z")
            ]
        ),
        .target(
            name: "TheaterMedia",
            dependencies: [
                "CFFmpeg",
                .product(name: "CinemaAudio", package: "TheaterCore")
            ],
            resources: [
                .process("Localizable.xcstrings")
            ],
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility")
            ]
        ),
        // FFmpeg は visionOS 向けにしか作らないので、visionOS の Simulator で回す（アプリのスキームのテストに入れている）
        .testTarget(
            name: "TheaterMediaTests",
            dependencies: [
                "TheaterMedia",
                "CFFmpeg",
                .product(name: "CinemaAudio", package: "TheaterCore")
            ],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
