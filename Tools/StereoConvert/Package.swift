// swift-tools-version: 6.2
//
// 2D の動画を、深度推定（Depth Anything V2）で左右の目の絵に分けて、3D（左右に並べた動画）に変換する道具（Mac で使う）。
// 使い方は Tools/StereoConvert/README.md。
//

import PackageDescription

let package = Package(
    name: "StereoConvert",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "stereo-convert", targets: ["stereo-convert"])
    ],
    targets: [
        .target(name: "StereoKit"),
        .executableTarget(name: "stereo-convert", dependencies: ["StereoKit"]),
        .testTarget(name: "StereoKitTests", dependencies: ["StereoKit"])
    ]
)
