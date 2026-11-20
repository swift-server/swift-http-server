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

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.mallocCountTotal, .instructions, .syscalls],
        scalingFactor: .kilo,
        maxDuration: .seconds(30),
        maxIterations: 10
    )

    Benchmark("HTTP3_stream") { benchmark in
        try await withHTTP3ClientServer { client in
            try await client.withConnection { connection in
                try await connection.get()

                benchmark.startMeasurement()
                for _ in benchmark.scaledIterations {
                    try await connection.get()
                }
                benchmark.stopMeasurement()
            }
        }
    }

    Benchmark("HTTP3_connection") { benchmark in
        try await withHTTP3ClientServer { client in
            try await client.withConnection { connection in
                try await connection.get()
            }

            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                try await client.withConnection { connection in
                    try await connection.get()
                }
            }
            benchmark.stopMeasurement()
        }
    }
}

private func withHTTP3ClientServer(_ body: (HTTP3BenchmarkClient) async throws -> Void) async throws {
    try await BenchmarkCertificate.withSelfSigned { certificate in
        try await HTTP3BenchmarkServer.withServer(certificate: certificate) { serverAddress in
            try await HTTP3BenchmarkClient.withClient(connectingTo: serverAddress, certificate: certificate, body: body)
        }
    }
}
