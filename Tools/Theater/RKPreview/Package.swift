// swift-tools-version:6.2
// 書き出した映画館（Theater.usdz）を macOS の RealityKit で描いて確かめる道具。アプリと同じ TheaterScene を使う。
// 使い方は Tools/Theater/README.md の「RealityKit で確かめる」

import PackageDescription

let package = Package(
    name: "RKPreview",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../../Packages/TheaterCore")
    ],
    targets: [
        .executableTarget(
            name: "RKPreview",
            dependencies: [.product(name: "TheaterScene", package: "TheaterCore")]
        )
    ]
)
