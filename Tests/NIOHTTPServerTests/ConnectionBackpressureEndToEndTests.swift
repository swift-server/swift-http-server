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

import HTTPAPIs
import Logging
import NIOCore
import NIOPosix
import Synchronization
import Testing

@testable import NIOHTTPServer

@Suite("Connection Backpressure End-to-End")
struct ConnectionBackpressureEndToEndTests {
    let serverLogger = Logger(label: "ConnectionBackpressureE2ETests.server")
    let clientLogger = Logger(label: "ConnectionBackpressureE2ETests.client")

    @available(anyAppleOS 26.0, *)
    @Test(
        "Requests succeed under connection limit",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1, .http2]
    )
    func requestsSucceedUnderConnectionLimit(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        ) { configuration in
            configuration.maxConnections = 2
            configuration.connectionTimeouts = .init(idle: nil, readHeader: nil, readBody: nil)
        }

        try await confirmation(expectedCount: 2) { responseReceived in
            try await TestHelpers.withServer(
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { _, _, reader, responseSender in
                    try await TestHelpers.echoResponse(
                        readUpTo: 1024,
                        reader: reader,
                        sender: responseSender
                    )
                }
            ) { serverAddress in
                try await withThrowingTaskGroup { group in
                    for _ in 0..<2 {
                        group.addTask {
                            try await TestClientConnection.withConnectedRequestChannel(
                                configuration: clientConfiguration,
                                serverAddress: serverAddress
                            ) { inbound, outbound in
                                try await outbound.write(.testHead(method: .get, for: httpVersion))
                                try await outbound.write(.end(nil))

                                try await TestHelpers.validateResponse(
                                    inbound,
                                    expectedHead: [.makeResponse(status: .ok, for: httpVersion)],
                                    expectedBody: [],
                                    expectStreamEnd: false
                                )

                                responseReceived()
                            }
                        }
                    }

                    try await group.waitForAll()
                }
            }
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test(
        "More connections than maxConnections all eventually complete",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1, .http2]
    )
    func moreConnectionsThanLimitAllComplete(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        ) { configuration in
            configuration.maxConnections = 2
            configuration.connectionTimeouts = .init(idle: nil, readHeader: nil, readBody: nil)
        }

        // Open 5 connections with maxConnections: 2. All should eventually complete
        // as the connection limit handler releases slots when connections close.
        let numConnections = 5
        try await confirmation(expectedCount: numConnections) { responseReceived in
            try await TestHelpers.withServer(
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { _, _, reader, responseSender in
                    try await TestHelpers.echoResponse(
                        readUpTo: 1024,
                        reader: reader,
                        sender: responseSender
                    )
                },
            ) { serverAddress in
                await withThrowingTaskGroup { group in
                    for _ in 0..<numConnections {
                        group.addTask {
                            try await TestClientConnection.withConnectedRequestChannel(
                                configuration: clientConfiguration,
                                serverAddress: serverAddress
                            ) { inbound, outbound in
                                try await outbound.write(.testHead(method: .get, for: httpVersion))
                                try await outbound.write(.end(nil))

                                try await TestHelpers.validateResponse(
                                    inbound,
                                    expectedHead: [.makeResponse(status: .ok, for: httpVersion)],
                                    expectedBody: [],
                                    expectStreamEnd: false
                                )

                                responseReceived()
                            }
                        }
                    }
                }
            }
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test(
        "No connection limit by default",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1, .http2]
    )
    func noConnectionLimitByDefault(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        ) { configuration in
            configuration.connectionTimeouts = .init(idle: nil, readHeader: nil, readBody: nil)
        }

        let numConnections = 5
        try await confirmation(expectedCount: numConnections) { responseReceived in
            try await TestHelpers.withServer(
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { _, _, reader, responseSender in
                    try await TestHelpers.echoResponse(
                        readUpTo: 1024,
                        reader: reader,
                        sender: responseSender
                    )
                }
            ) { serverAddress in
                await withThrowingTaskGroup { group in
                    for _ in 0..<numConnections {
                        group.addTask {
                            try await TestClientConnection.withConnectedRequestChannel(
                                configuration: clientConfiguration,
                                serverAddress: serverAddress
                            ) { inbound, outbound in
                                try await outbound.write(.testHead(method: .get, for: httpVersion))
                                try await outbound.write(.end(nil))

                                try await TestHelpers.validateResponse(
                                    inbound,
                                    expectedHead: [.makeResponse(status: .ok, for: httpVersion)],
                                    expectedBody: [],
                                    expectStreamEnd: false
                                )

                                responseReceived()
                            }
                        }
                    }
                }
            }
        }
    }
}
