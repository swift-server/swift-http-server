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
    let serverLogger = Logger(label: "ConnectionBackpressureE2ETests")

    @available(anyAppleOS 26.0, *)
    @Test("Requests succeed under connection limit")
    func requestsSucceedUnderConnectionLimit() async throws {
        var configuration = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext
        )
        configuration.maxConnections = 2
        configuration.connectionTimeouts = .init(idle: nil, readHeader: nil, readBody: nil)

        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: configuration
        )

        try await confirmation(expectedCount: 2) { responseReceived in
            try await NIOHTTPServerTests.withServer(
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { _, _, reader, responseSender in
                    try await NIOHTTPServerTests.echoResponse(
                        readUpTo: 1024,
                        reader: reader,
                        sender: responseSender
                    )
                },
                body: { serverAddress in
                    try await withThrowingTaskGroup { group in
                        for _ in 0..<2 {
                            group.addTask {
                                let client = try await ClientBootstrap(
                                    group: .singletonMultiThreadedEventLoopGroup
                                ).connectToTestHTTP1Server(at: serverAddress)

                                try await client.executeThenClose { inbound, outbound in
                                    try await outbound.write(
                                        .head(.init(method: .get, scheme: "http", authority: "", path: "/"))
                                    )
                                    try await outbound.write(.end(nil))

                                    try await NIOHTTPServerTests.validateResponse(
                                        inbound,
                                        expectedHead: [NIOHTTPServerTests.responseHead(status: .ok, for: .http1_1)],
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
            )
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test("More connections than maxConnections all eventually complete")
    func moreConnectionsThanLimitAllComplete() async throws {
        var configuration = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext
        )
        configuration.maxConnections = 2
        configuration.connectionTimeouts = .init(idle: nil, readHeader: nil, readBody: nil)

        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: configuration
        )

        // Open 5 connections with maxConnections: 2. All should eventually complete
        // as the connection limit handler releases slots when connections close.
        let numConnections = 5
        try await confirmation(expectedCount: numConnections) { responseReceived in
            try await NIOHTTPServerTests.withServer(
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { _, _, reader, responseSender in
                    try await NIOHTTPServerTests.echoResponse(
                        readUpTo: 1024,
                        reader: reader,
                        sender: responseSender
                    )
                },
                body: { serverAddress in
                    await withThrowingTaskGroup { group in
                        for _ in 0..<numConnections {
                            group.addTask {
                                let client = try await ClientBootstrap(
                                    group: .singletonMultiThreadedEventLoopGroup
                                ).connectToTestHTTP1Server(at: serverAddress)

                                try await client.executeThenClose { inbound, outbound in
                                    try await outbound.write(
                                        .head(.init(method: .get, scheme: "http", authority: "", path: "/"))
                                    )
                                    try await outbound.write(.end(nil))

                                    try await NIOHTTPServerTests.validateResponse(
                                        inbound,
                                        expectedHead: [NIOHTTPServerTests.responseHead(status: .ok, for: .http1_1)],
                                        expectedBody: [],
                                        expectStreamEnd: false
                                    )

                                    responseReceived()
                                }
                            }
                        }
                    }
                }
            )
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test("No connection limit by default")
    func noConnectionLimitByDefault() async throws {
        var configuration = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext
        )
        configuration.connectionTimeouts = .init(idle: nil, readHeader: nil, readBody: nil)

        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: configuration
        )

        let numConnections = 5
        try await confirmation(expectedCount: numConnections) { responseReceived in
            try await NIOHTTPServerTests.withServer(
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { _, _, reader, responseSender in
                    try await NIOHTTPServerTests.echoResponse(
                        readUpTo: 1024,
                        reader: reader,
                        sender: responseSender
                    )
                },
                body: { serverAddress in
                    await withThrowingTaskGroup { group in
                        for _ in 0..<numConnections {
                            group.addTask {
                                let client = try await ClientBootstrap(
                                    group: .singletonMultiThreadedEventLoopGroup
                                ).connectToTestHTTP1Server(at: serverAddress)

                                try await client.executeThenClose { inbound, outbound in
                                    try await outbound.write(
                                        .head(.init(method: .get, scheme: "http", authority: "", path: "/"))
                                    )
                                    try await outbound.write(.end(nil))

                                    try await NIOHTTPServerTests.validateResponse(
                                        inbound,
                                        expectedHead: [NIOHTTPServerTests.responseHead(status: .ok, for: .http1_1)],
                                        expectedBody: [],
                                        expectStreamEnd: false
                                    )

                                    responseReceived()
                                }
                            }
                        }
                    }
                }
            )
        }
    }
}
