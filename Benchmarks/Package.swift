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
        .package(name: "swift-http-server", path: "../"),
    ],
    targets: [
        .executableTarget(
            name: "NIOHTTPServerBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
                .product(name: "NIOHTTPServer", package: "swift-http-server"),
            ],
            path: "Benchmarks/NIOHTTPServerBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        )
    ]
)
