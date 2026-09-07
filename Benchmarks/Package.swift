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
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.36.2"),
        .package(name: "swift-http-server", path: "../", traits: ["HTTP3"]),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.3"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.0-beta.2"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.3"),
        .package(url: "https://github.com/apple/swift-nio-quic.git", .upToNextMinor(from: "0.2.2")),
        .package(url: "https://github.com/apple/swift-nio-quic-helpers.git", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/apple/swift-nio-http3.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "NIOHTTPServerBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                "NIOHTTPServerBenchmarkSupport",
            ],
            path: "Benchmarks/NIOHTTPServerBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
        .target(
            name: "NIOHTTPServerBenchmarkSupport",
            dependencies: [
                .product(name: "NIOHTTPServer", package: "swift-http-server"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOQUIC", package: "swift-nio-quic"),
                .product(name: "NIOQUICHelpers", package: "swift-nio-quic-helpers"),
                .product(name: "NIOHTTP3", package: "swift-nio-http3"),
            ],
            path: "Benchmarks/NIOHTTPServerBenchmarkSupport",
        ),
    ]
)
