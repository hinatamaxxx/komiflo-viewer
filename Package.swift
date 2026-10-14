// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KomifloViewer",
    platforms: [.iOS(.v17)],
    products: [.library(name: "KomifloViewer", targets: ["KomifloViewer"])],
    targets: [
        .target(name: "KomifloViewer", path: "KomifloViewer",
                resources: [.process("Assets.xcassets"), .process("Resources")],
                // Linux版リンカーにも、実際に使用するSDKの版を明示する。
                linkerSettings: [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "ios",
                                                "-Xlinker", "17.0", "-Xlinker", "27.0"])])
    ],
    swiftLanguageVersions: [.v5]
)
