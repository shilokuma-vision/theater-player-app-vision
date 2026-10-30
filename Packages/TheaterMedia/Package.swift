// swift-tools-version:6.2
// 動画・音楽の再生（FFmpeg でファイルを開いてデコードし、映像は RealityKit のスクリーンへ、音声は映画館の音響処理へ渡す）。
// FFmpeg は scripts/build-ffmpeg.sh で Vendor/FFmpeg.xcframework に作る（リポジトリには入れない）。

import PackageDescription

let package = Package(
    name: "TheaterMedia",
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
        .binaryTarget(name: "FFmpeg", path: "Vendor/FFmpeg.xcframework"),
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
