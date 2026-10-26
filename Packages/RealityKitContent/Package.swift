// swift-tools-version:6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RealityKitContent",
    platforms: [
        // アプリの Deployment Target（Configs/Project.xcconfig の XROS_DEPLOYMENT_TARGET）と揃える
        .visionOS(.v26)
    ],
    products: [
        .library(
            name: "RealityKitContent",
            targets: ["RealityKitContent"]
        )
    ],
    targets: [
        .target(
            name: "RealityKitContent",
            dependencies: [],
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility")
            ]
        )
    ]
)
