// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebKit",
    products: [
        // WPE WebKit's pages, drawn into Cacao's external surfaces.
        .library(name: "WPEWebKit", targets: ["WPEWebKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/PureSwift/Cacao.git", branch: "develop"),
    ],
    targets: [
        // The engine: WPE WebKit, opened at run time, so nothing links it
        // and a machine without it still runs.
        .target(
            name: "WPEWebKit",
            dependencies: [.product(name: "CacaoRender", package: "Cacao")]
        ),
        .testTarget(name: "WPEWebKitTests", dependencies: ["WPEWebKit"]),
    ]
)
