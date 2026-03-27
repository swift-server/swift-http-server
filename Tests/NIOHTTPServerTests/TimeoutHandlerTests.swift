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

@Suite("ReadHeaderTimeoutHandler")
struct ReadHeaderTimeoutHandlerTests {

    @Test("Headers received within timeout — connection stays open")
    func headersReceivedWithinTimeout() async throws {
        let channel = EmbeddedChannel()
        let handler = ReadHeaderTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        // Activate the channel (starts the timer)
        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        // Send headers before the timeout
        let head = HTTPRequest(method: .get, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))

        // Advance past the timeout
        channel.embeddedEventLoop.advanceTime(by: .seconds(10))

        // Channel should still be active
        #expect(channel.isActive)
    }

    @Test("Headers not received within timeout — connection closed")
    func headersNotReceivedWithinTimeout() async throws {
        let channel = EmbeddedChannel()
        let handler = ReadHeaderTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        // Activate the channel (starts the timer)
        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        // Don't send any headers, advance past timeout
        channel.embeddedEventLoop.advanceTime(by: .seconds(6))

        // Channel should be closed
        #expect(!channel.isActive)
    }

    @Test("Cleanup on handler removal")
    func cleanupOnHandlerRemoval() async throws {
        let channel = EmbeddedChannel()
        let handler = ReadHeaderTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        // Activate the channel (starts the timer)
        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        // Remove the handler before the timeout fires
        try channel.pipeline.syncOperations.removeHandler(handler)

        // Advance past the timeout
        channel.embeddedEventLoop.advanceTime(by: .seconds(10))

        // Channel should still be active — the scheduled task was cancelled on removal
        #expect(channel.isActive)
    }
}

@Suite("ReadBodyTimeoutHandler")
struct ReadBodyTimeoutHandlerTests {

    @Test("Body completed within timeout — connection stays open")
    func bodyCompletedWithinTimeout() async throws {
        let channel = EmbeddedChannel()
        let handler = ReadBodyTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        // Send head (starts the timer)
        let head = HTTPRequest(method: .post, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))

        // Send end before timeout
        try channel.writeInbound(HTTPRequestPart.end(nil))

        // Advance past timeout
        channel.embeddedEventLoop.advanceTime(by: .seconds(10))

        // Channel should still be active
        #expect(channel.isActive)
    }

    @Test("Body not completed within timeout — connection closed")
    func bodyNotCompletedWithinTimeout() async throws {
        let channel = EmbeddedChannel()
        let handler = ReadBodyTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        // Send head (starts the timer) but don't send end
        let head = HTTPRequest(method: .post, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))

        // Advance past timeout without sending end
        channel.embeddedEventLoop.advanceTime(by: .seconds(6))

        // Channel should be closed
        #expect(!channel.isActive)
    }

    @Test("Body parts do not reset timeout")
    func bodyPartsDoNotResetTimeout() async throws {
        let channel = EmbeddedChannel()
        let handler = ReadBodyTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        // Send head (starts the timer)
        let head = HTTPRequest(method: .post, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))

        // Send body chunks at intervals — these should NOT reset the timer
        channel.embeddedEventLoop.advanceTime(by: .seconds(2))
        try channel.writeInbound(HTTPRequestPart.body(ByteBuffer(bytes: [1, 2, 3])))

        channel.embeddedEventLoop.advanceTime(by: .seconds(2))
        try channel.writeInbound(HTTPRequestPart.body(ByteBuffer(bytes: [4, 5, 6])))

        // Now advance past the original 5s timeout (total 6s since head)
        channel.embeddedEventLoop.advanceTime(by: .seconds(2))

        // Channel should be closed — body chunks didn't reset the timer
        #expect(!channel.isActive)
    }

    @Test("Cleanup on handler removal")
    func cleanupOnHandlerRemoval() async throws {
        let channel = EmbeddedChannel()
        let handler = ReadBodyTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        // Send head (starts the timer)
        let head = HTTPRequest(method: .post, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))

        // Remove handler before timeout
        try channel.pipeline.syncOperations.removeHandler(handler)

        // Advance past timeout
        channel.embeddedEventLoop.advanceTime(by: .seconds(10))

        // Channel should still be active
        #expect(channel.isActive)
    }
}
