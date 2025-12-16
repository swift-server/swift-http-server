// swift-tools-version: 6.2

import PackageDescription

let extraSettings: [SwiftSetting] = [
    .enableExperimentalFeature("SuppressedAssociatedTypes"),
    .enableExperimentalFeature("LifetimeDependence"),
    .enableUpcomingFeature("LifetimeDependence"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault")
]

let package = Package(
    name: "HTTPServer",
    products: [
        .library(
            name: "HTTPServer",
            targets: ["HTTPServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.4"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.16.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.36.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.30.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Example",
            dependencies: [
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "Instrumentation", package: "swift-distributed-tracing"),
                .product(name: "Logging", package: "swift-log"),
                "HTTPServer",
                "Middleware",
            ],
            swiftSettings: extraSettings
        ),
        .target(
            name: "HTTPServer",
            dependencies: [
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOHTTPTypesHTTP1", package: "swift-nio-extras"),
                .product(name: "NIOHTTPTypesHTTP2", package: "swift-nio-extras"),
                .product(name: "NIOCertificateReloading", package: "swift-nio-extras")
            ],
            swiftSettings: extraSettings
        ),
        .target(
            name: "Middleware",
            dependencies: [
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: extraSettings
        ),
        .testTarget(
            name: "HTTPServerTests",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "HTTPServer",
            ]
        ),
    ]
)
