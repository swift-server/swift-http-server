// swift-tools-version:6.4
//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import PackageDescription

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

let extraSettings: [SwiftSetting] = [
    .strictMemorySafety(),
    .enableExperimentalFeature("SuppressedAssociatedTypesWithDefaults"),
    .enableExperimentalFeature("LifetimeDependence"),
    .enableExperimentalFeature("Lifetimes"),
    .enableUpcomingFeature("LifetimeDependence"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

var traits: Set<Trait> = [
    .trait(
        name: "Configuration",
        description: "Enables initializing NIOHTTPServerConfiguration from a swift-configuration ConfigProvider"
    ),
    .trait(
        name: "HTTP3",
        description: "Enables HTTP/3 support"
    ),
]

let defaultTraits: Set<String> = ["Configuration"]

// Workaround to ensure that all traits are included in documentation. Swift Package Index adds SPI_GENERATE_DOCS
// (https://github.com/SwiftPackageIndex/SwiftPackageIndex-Server/issues/2336) when building documentation, so only
// tweak the default traits in this condition.
let spiGenerateDocs = ProcessInfo.processInfo.environment["SPI_GENERATE_DOCS"] != nil

// Conditionally add the swift-docc plugin only when previewing docs locally.
// Preview with:
// ```
// SWIFT_PREVIEW_DOCS=1 swift package --disable-sandbox preview-documentation --target NIOHTTPServer
// ```
let previewDocs = ProcessInfo.processInfo.environment["SWIFT_PREVIEW_DOCS"] != nil

// Enable all traits for other CI actions.
let enableAllTraitsExplicit = ProcessInfo.processInfo.environment["ENABLE_ALL_TRAITS"] != nil

let enableAllTraits = spiGenerateDocs || previewDocs || enableAllTraitsExplicit
let addDoccPlugin = previewDocs || spiGenerateDocs
let enableAllCIFlags = enableAllTraitsExplicit

traits.insert(
    .default(
        enabledTraits: enableAllTraits ? Set(traits.map(\.name)) : defaultTraits
    ),
)

let package = Package(
    name: "swift-http-server",
    platforms: [  // TODO: Needed until https://github.com/swiftlang/swift/issues/89028 is fixed
        .macOS(.v15),
        .iOS(.v18),
        .watchOS(.v11),
        .tvOS(.v18),
        .visionOS(.v2),
    ],
    products: [
        .library(
            name: "NIOHTTPServer",
            targets: ["NIOHTTPServer"]
        )
    ],
    traits: traits,
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-http-api-proposal.git",
            .upToNextMinor(from: "0.2.0")
        ),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.4.1"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.3"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.3"),
        .package(url: "https://github.com/apple/swift-nio-quic.git", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/apple/swift-nio-quic-helpers.git", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/apple/swift-nio-http3.git", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.34.1"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.44.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.2.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.11.0"),
    ],
    targets: [
        .target(
            name: "ExampleSupport",
            dependencies: [
                .product(name: "Tracing", package: "swift-distributed-tracing")
            ],
            swiftSettings: extraSettings
        ),
        .executableTarget(
            name: "RequestHandlerExample",
            dependencies: [
                "ExampleSupport",
                .product(name: "Instrumentation", package: "swift-distributed-tracing"),
                .product(name: "Logging", package: "swift-log"),
                "NIOHTTPServer",
            ],
            swiftSettings: extraSettings
        ),
        .executableTarget(
            name: "ConnectionHandlerExample",
            dependencies: [
                "ExampleSupport",
                .product(name: "Instrumentation", package: "swift-distributed-tracing"),
                .product(name: "Logging", package: "swift-log"),
                "NIOHTTPServer",
            ],
            swiftSettings: extraSettings
        ),
        .target(
            name: "NIOHTTPServer",
            dependencies: [
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOHTTPTypesHTTP1", package: "swift-nio-extras"),
                .product(name: "NIOHTTPTypesHTTP2", package: "swift-nio-extras"),
                .product(name: "NIOCertificateReloading", package: "swift-nio-extras"),
                .product(
                    name: "Configuration",
                    package: "swift-configuration",
                    condition: .when(traits: ["Configuration"])
                ),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "NIOQUIC", package: "swift-nio-quic", condition: .when(traits: ["HTTP3"])),
                .product(
                    name: "NIOQUICHelpers",
                    package: "swift-nio-quic-helpers",
                    condition: .when(traits: ["HTTP3"])
                ),
                .product(name: "NIOHTTP3", package: "swift-nio-http3", condition: .when(traits: ["HTTP3"])),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
            ],
            swiftSettings: extraSettings
        ),
        .testTarget(
            name: "NIOHTTPServerTests",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "ServiceLifecycleTestKit", package: "swift-service-lifecycle"),
                "NIOHTTPServer",
            ]
        ),
    ]
)
