// swift-tools-version:6.4
//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "swift-http-server-benchmarks",
    platforms: [.macOS("27")],
    dependencies: [
        .package(name: "swift-http-server", path: "../", traits: ["HTTP3"]),
        .package(url: "https://github.com/ordo-one/benchmark.git", from: "1.38.2"),
        .package(url: "https://github.com/apple/swift-http-api-proposal.git", .upToNextMinor(from: "0.2.0")),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.3"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.103.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.35.1"),
        .package(url: "https://github.com/apple/swift-nio-quic.git", .upToNextMinor(from: "0.6.0")),
        .package(url: "https://github.com/apple/swift-nio-http3.git", .upToNextMinor(from: "0.5.0")),
    ],
    targets: [
        .executableTarget(
            name: "NIOHTTPServerBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
                .product(name: "NIOHTTPServer", package: "swift-http-server"),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
                .product(name: "BasicContainers", package: "swift-collections"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTPTypes", package: "swift-nio-extras"),
                .product(name: "NIOQUIC", package: "swift-nio-quic"),
                .product(name: "NIOHTTP3", package: "swift-nio-http3"),
            ],
            path: "Benchmarks/NIOHTTPServerBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        )
    ]
)
