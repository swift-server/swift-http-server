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

import BasicContainers
import HTTPAPIs
import HTTPTypes
import Logging
import NIOHTTPServer

enum HTTP3BenchmarkServer {
    static let responseBodySize = 1024

    static func withServer(
        certificate: BenchmarkCertificate,
        body: (NIOHTTPServer.SocketAddress) async throws -> Void
    ) async throws {
        let server = NIOHTTPServer(
            logger: Logger(label: "NIOHTTPServerBenchmarks.server"),
            configuration: try NIOHTTPServerConfiguration(
                bindTargets: [.hostAndPort(host: "127.0.0.1", port: 0)],
                supportedHTTPVersions: [.http3],
                transportSecurity: certificate.transportSecurity
            )
        )

        try await withThrowingTaskGroup { group in
            group.addTask { [server] in
                try await server.serve(
                    handler: HTTPServerClosureRequestHandler { _, _, reader, sender in
                        var requestBody = UniqueArray<UInt8>()
                        _ = try await reader.collect(into: &requestBody)

                        var responseBody = UniqueArray<UInt8>(repeating: 0, count: Self.responseBodySize)
                        try await sender.sendAndFinish(HTTPResponse(status: .ok), buffer: &responseBody)
                    }
                )
            }

            let address: NIOHTTPServer.SocketAddress
            do {
                guard let first = try await server.listeningAddresses.first else {
                    throw BenchmarkError.noListeningAddress
                }
                address = first
            } catch {
                group.cancelAll()
                try await group.waitForAll()
                throw error
            }

            try await body(address)
            group.cancelAll()
        }
    }
}
