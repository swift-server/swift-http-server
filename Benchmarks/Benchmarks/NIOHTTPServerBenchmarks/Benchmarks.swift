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

import Benchmark
import Benchmark
import NIOEmbedded
import NIOHTTPServerBenchmarkSupport

private func makeHTTP3BenchmarkConfiguration() -> Benchmark.Configuration {
    .init(
        metrics: [.mallocCountTotal, .instructions, .wallClock],
        scalingFactor: .one,
        maxDuration: .seconds(2),
        maxIterations: 10_000
    )
}

let eventLoop = NIOAsyncTestingEventLoop()
let certificate = try! BenchmarkCertificate.makeSelfSigned()

let benchmarks: @Sendable () -> Void = {
    var servers = [BenchmarkHTTP3Server]()
    Benchmark(
        "HTTP3_serverSetup",
        configuration: makeHTTP3BenchmarkConfiguration(),
        closure: { benchmark in
            for _ in benchmark.scaledIterations {
                servers.append(try await BenchmarkHTTP3Server.start(eventLoop: eventLoop, certificate: certificate))
            }
        },
        teardown: {
            for server in servers {
                try await server.shutdown()
            }
            servers.removeAll()
        }
    )

    var client: BenchmarkHTTP3Client!
    var prewarmedServer: BenchmarkHTTP3Server!
    var connections = [BenchmarkHTTP3Connection]()
    Benchmark(
        "HTTP3_openConnection",
        configuration: makeHTTP3BenchmarkConfiguration(),
        closure: { benchmark in
            for _ in benchmark.scaledIterations {
                connections.append(try await client.openConnection())
            }
        },
        setup: {
            client = try await BenchmarkHTTP3Client.start(eventLoop: eventLoop, certificate: certificate)
            prewarmedServer = try await BenchmarkHTTP3Server.start(eventLoop: eventLoop, certificate: certificate)
            try await client.attach(to: prewarmedServer)
        },
        teardown: {
            for connection in connections {
                try await connection.close()
            }
            connections.removeAll()
            try await client.shutdown()
            try await prewarmedServer.shutdown()
        }
    )

    var existingConnection: BenchmarkHTTP3Connection!
    Benchmark(
        "HTTP3_stream",
        configuration: makeHTTP3BenchmarkConfiguration(),
        closure: { benchmark in
            for _ in benchmark.scaledIterations {
                try await existingConnection.download()
            }
        },
        setup: {
            client = try await BenchmarkHTTP3Client.start(eventLoop: eventLoop, certificate: certificate)
            prewarmedServer = try await BenchmarkHTTP3Server.start(eventLoop: eventLoop, certificate: certificate)
            try await client.attach(to: prewarmedServer)
            existingConnection = try await client.openConnection()
        },
        teardown: {
            try await existingConnection.close()
            try await client.shutdown()
            try await prewarmedServer.shutdown()
        }
    )
}
