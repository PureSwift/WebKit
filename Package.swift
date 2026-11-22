// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebKit",
    products: [
        // WPE WebKit's pages, drawn into Cacao's external surfaces.
        .library(name: "WPEWebKit", targets: ["WPEWebKit"]),
        // The web view for Cacao's SwiftUI.
        .library(name: "CacaoWebKit", targets: ["CacaoWebKit"]),
        .executable(name: "WebDemo", targets: ["WebDemo"]),
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
        // `WebView` and `WebPage` over the engine, with the engine's loop
        // run from Cacao's host.
        .target(
            name: "CacaoWebKit",
            dependencies: [
                "WPEWebKit",
                .product(name: "Cacao", package: "Cacao"),
                .product(name: "CacaoHost", package: "Cacao"),
            ]
        ),
        // A small browser window.
        .executableTarget(
            name: "WebDemo",
            dependencies: [
                "CacaoWebKit",
                .product(name: "CacaoSDL", package: "Cacao"),
            ]
        ),
        .testTarget(name: "WPEWebKitTests", dependencies: ["WPEWebKit"]),
        .testTarget(
            name: "CacaoWebKitTests",
            dependencies: ["CacaoWebKit", .product(name: "Cacao", package: "Cacao")]
        ),
    ]
)
