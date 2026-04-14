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

import HTTPTypes
import NIOCore
import NIOEmbedded
import NIOHTTPTypes
import Testing

@testable import NIOHTTPServer

@Suite("ConnectionIdleTimeoutHandler")
struct ConnectionIdleTimeoutHandlerTests {

    @Test("Connection closed after idle timeout")
    func closedAfterIdleTimeout() throws {
        let channel = EmbeddedChannel()
        let handler = ConnectionIdleTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        // Advance past the timeout with no activity
        channel.embeddedEventLoop.advanceTime(by: .seconds(6))

        #expect(!channel.isActive)
    }

    @Test("Read resets idle timeout")
    func readResetsTimeout() throws {
        let channel = EmbeddedChannel()
        let handler = ConnectionIdleTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        // Advance partway, then trigger a read
        channel.embeddedEventLoop.advanceTime(by: .seconds(4))
        try channel.writeInbound(ByteBuffer(bytes: [1, 2, 3]))

        // Advance past the original timeout but within the reset timeout
        channel.embeddedEventLoop.advanceTime(by: .seconds(4))
        #expect(channel.isActive)

        // Now advance past the reset timeout
        channel.embeddedEventLoop.advanceTime(by: .seconds(2))
        #expect(!channel.isActive)
    }

    @Test("Write resets idle timeout")
    func writeResetsTimeout() throws {
        let channel = EmbeddedChannel()
        let handler = ConnectionIdleTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        // Advance partway, then trigger a write
        channel.embeddedEventLoop.advanceTime(by: .seconds(4))
        try channel.writeOutbound(ByteBuffer(bytes: [1, 2, 3]))

        // Advance past the original timeout but within the reset timeout
        channel.embeddedEventLoop.advanceTime(by: .seconds(4))
        #expect(channel.isActive)

        // Now advance past the reset timeout
        channel.embeddedEventLoop.advanceTime(by: .seconds(2))
        #expect(!channel.isActive)
    }

    @Test("Cleanup on handler removal")
    func cleanupOnHandlerRemoval() throws {
        let channel = EmbeddedChannel()
        let handler = ConnectionIdleTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        _ = channel.pipeline.syncOperations.removeHandler(handler)

        channel.embeddedEventLoop.advanceTime(by: .seconds(10))

        #expect(channel.isActive)
    }
}

@Suite("RequestTimeoutHandler")
struct RequestTimeoutHandlerTests {

    // MARK: - Header timeout tests

    @Test("Headers received within timeout — connection stays open")
    func headersReceivedWithinTimeout() throws {
        let channel = EmbeddedChannel()
        let handler = RequestTimeoutHandler(readHeaderTimeout: .seconds(5), readBodyTimeout: nil)
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        let head = HTTPRequest(method: .get, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))

        channel.embeddedEventLoop.advanceTime(by: .seconds(10))

        #expect(channel.isActive)
    }

    @Test("Headers not received within timeout — connection closed")
    func headersNotReceivedWithinTimeout() throws {
        let channel = EmbeddedChannel()
        let handler = RequestTimeoutHandler(readHeaderTimeout: .seconds(5), readBodyTimeout: nil)
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        channel.embeddedEventLoop.advanceTime(by: .seconds(6))

        #expect(!channel.isActive)
    }

    // MARK: - Body timeout tests

    @Test("Body completed within timeout — connection stays open")
    func bodyCompletedWithinTimeout() throws {
        let channel = EmbeddedChannel()
        let handler = RequestTimeoutHandler(readHeaderTimeout: nil, readBodyTimeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        let head = HTTPRequest(method: .post, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))

        try channel.writeInbound(HTTPRequestPart.end(nil))

        channel.embeddedEventLoop.advanceTime(by: .seconds(10))

        #expect(channel.isActive)
    }

    @Test("Body not completed within timeout — connection closed")
    func bodyNotCompletedWithinTimeout() throws {
        let channel = EmbeddedChannel()
        let handler = RequestTimeoutHandler(readHeaderTimeout: nil, readBodyTimeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        let head = HTTPRequest(method: .post, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))

        channel.embeddedEventLoop.advanceTime(by: .seconds(6))

        #expect(!channel.isActive)
    }

    @Test("Body parts do not reset timeout")
    func bodyPartsDoNotResetTimeout() throws {
        let channel = EmbeddedChannel()
        let handler = RequestTimeoutHandler(readHeaderTimeout: nil, readBodyTimeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        let head = HTTPRequest(method: .post, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))

        channel.embeddedEventLoop.advanceTime(by: .seconds(2))
        try channel.writeInbound(HTTPRequestPart.body(ByteBuffer(bytes: [1, 2, 3])))

        channel.embeddedEventLoop.advanceTime(by: .seconds(2))
        try channel.writeInbound(HTTPRequestPart.body(ByteBuffer(bytes: [4, 5, 6])))

        // Total 6s since head — past the 5s timeout
        channel.embeddedEventLoop.advanceTime(by: .seconds(2))

        #expect(!channel.isActive)
    }

    // MARK: - Combined timeout tests

    @Test("Both timeouts configured — header then body")
    func bothTimeoutsHeaderThenBody() throws {
        let channel = EmbeddedChannel()
        let handler = RequestTimeoutHandler(readHeaderTimeout: .seconds(5), readBodyTimeout: .seconds(10))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        // Send head within header timeout
        channel.embeddedEventLoop.advanceTime(by: .seconds(3))
        let head = HTTPRequest(method: .post, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))

        // Send end within body timeout
        channel.embeddedEventLoop.advanceTime(by: .seconds(8))
        try channel.writeInbound(HTTPRequestPart.end(nil))

        channel.embeddedEventLoop.advanceTime(by: .seconds(20))

        #expect(channel.isActive)
    }

    @Test("Both timeouts configured — header timeout fires")
    func bothTimeoutsHeaderFires() throws {
        let channel = EmbeddedChannel()
        let handler = RequestTimeoutHandler(readHeaderTimeout: .seconds(5), readBodyTimeout: .seconds(10))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        channel.embeddedEventLoop.advanceTime(by: .seconds(6))

        #expect(!channel.isActive)
    }

    @Test("Both timeouts configured — body timeout fires")
    func bothTimeoutsBodyFires() throws {
        let channel = EmbeddedChannel()
        let handler = RequestTimeoutHandler(readHeaderTimeout: .seconds(5), readBodyTimeout: .seconds(10))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        let head = HTTPRequest(method: .post, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))

        channel.embeddedEventLoop.advanceTime(by: .seconds(11))

        #expect(!channel.isActive)
    }

    // MARK: - Cleanup

    @Test("Cleanup on handler removal during header phase")
    func cleanupOnHandlerRemovalDuringHeaderPhase() throws {
        let channel = EmbeddedChannel()
        let handler = RequestTimeoutHandler(readHeaderTimeout: .seconds(5), readBodyTimeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        _ = channel.pipeline.syncOperations.removeHandler(handler)

        channel.embeddedEventLoop.advanceTime(by: .seconds(10))

        #expect(channel.isActive)
    }

    @Test("Cleanup on handler removal during body phase")
    func cleanupOnHandlerRemovalDuringBodyPhase() throws {
        let channel = EmbeddedChannel()
        let handler = RequestTimeoutHandler(readHeaderTimeout: .seconds(5), readBodyTimeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        let head = HTTPRequest(method: .post, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))

        _ = channel.pipeline.syncOperations.removeHandler(handler)

        channel.embeddedEventLoop.advanceTime(by: .seconds(10))

        #expect(channel.isActive)
    }
}
