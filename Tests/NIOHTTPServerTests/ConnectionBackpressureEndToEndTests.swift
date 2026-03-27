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

    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test("Requests succeed under connection limit")
    func requestsSucceedUnderConnectionLimit() async throws {
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext,
                maxConnections: 2,
                connectionTimeouts: .init(idle: nil, readHeader: nil, readBody: nil)
            )
        )

        try await confirmation(expectedCount: 2) { responseReceived in
            try await NIOHTTPServerTests.withServer(
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { _, _, reader, responseSender in
                    _ = try await reader.consumeAndConclude { bodyReader in
                        var bodyReader = bodyReader
                        return try await bodyReader.collect(upTo: 1024) { _ in }
                    }
                    let writer = try await responseSender.send(.init(status: .ok))
                    try await writer.produceAndConclude { bodyWriter in nil }
                },
                body: { serverAddress in
                    await withThrowingTaskGroup { group in
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

                                    var iter = inbound.makeAsyncIterator()
                                    let head = try await iter.next()
                                    guard case .head(let response) = head else {
                                        Issue.record("Expected response head")
                                        return
                                    }
                                    #expect(response.status == 200)

                                    // Read remaining parts
                                    while let part = try await iter.next() {
                                        if case .end = part { break }
                                    }

                                    responseReceived()
                                }
                            }
                        }
                    }
                }
            )
        }
    }

    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test("More connections than maxConnections all eventually complete")
    func moreConnectionsThanLimitAllComplete() async throws {
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext,
                maxConnections: 2,
                connectionTimeouts: .init(idle: nil, readHeader: nil, readBody: nil)
            )
        )

        // Open 5 connections with maxConnections: 2. All should eventually complete
        // as the connection limit handler releases slots when connections close.
        let numConnections = 5
        try await confirmation(expectedCount: numConnections) { responseReceived in
            try await NIOHTTPServerTests.withServer(
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { _, _, reader, responseSender in
                    _ = try await reader.consumeAndConclude { bodyReader in
                        var bodyReader = bodyReader
                        return try await bodyReader.collect(upTo: 1024) { _ in }
                    }
                    let writer = try await responseSender.send(.init(status: .ok))
                    try await writer.produceAndConclude { bodyWriter in nil }
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

                                    var iter = inbound.makeAsyncIterator()
                                    let head = try await iter.next()
                                    guard case .head(let response) = head else {
                                        Issue.record("Expected response head")
                                        return
                                    }
                                    #expect(response.status == 200)

                                    while let part = try await iter.next() {
                                        if case .end = part { break }
                                    }

                                    responseReceived()
                                }
                            }
                        }
                    }
                }
            )
        }
    }

    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test("No connection limit by default")
    func noConnectionLimitByDefault() async throws {
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext,
                connectionTimeouts: .init(idle: nil, readHeader: nil, readBody: nil)
            )
        )

        let numConnections = 5
        try await confirmation(expectedCount: numConnections) { responseReceived in
            try await NIOHTTPServerTests.withServer(
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { _, _, reader, responseSender in
                    _ = try await reader.consumeAndConclude { bodyReader in
                        var bodyReader = bodyReader
                        return try await bodyReader.collect(upTo: 1024) { _ in }
                    }
                    let writer = try await responseSender.send(.init(status: .ok))
                    try await writer.produceAndConclude { bodyWriter in nil }
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

                                    var iter = inbound.makeAsyncIterator()
                                    let head = try await iter.next()
                                    guard case .head(let response) = head else {
                                        Issue.record("Expected response head")
                                        return
                                    }
                                    #expect(response.status == 200)

                                    while let part = try await iter.next() {
                                        if case .end = part { break }
                                    }

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
