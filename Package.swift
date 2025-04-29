// swift-tools-version:5.10

import PackageDescription

let package = Package(
    name: "swift-http-server",
    platforms: [
        .macOS("14.0")
    ],
//    products: [
//        .library(
//            name: "HTTPServer",
//            targets: ["HTTPServer"]
//        ),
//    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.58.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", revision: "0.1.1"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", revision: "2.25.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-certificates.git", branch: "main"),
        .package(url: "https://github.com/guoye-zhang/swift-nio-extras.git", branch: "http-types"),
    ],
    targets: [
        .executableTarget(
            name: "HTTPServer",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOHTTPTypesHTTP1", package: "swift-nio-extras"),
                .product(name: "NIOHTTPTypesHTTP2", package: "swift-nio-extras"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency=complete"),
            ]
        ),
        .testTarget(
            name: "HTTPServerTests",
            dependencies: []
        ),
    ]
)
