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

    @Test("Connection closed after idle timeout with no request")
    func closedAfterIdleTimeout() throws {
        let channel = EmbeddedChannel()
        let handler = ConnectionIdleTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        // Advance past the timeout with no request in flight
        channel.embeddedEventLoop.advanceTime(by: .seconds(6))

        #expect(!channel.isActive)
    }

    @Test("Idle timer is cancelled while a request is in flight")
    func idleCancelledWhileRequestInFlight() throws {
        let channel = EmbeddedChannel()
        let handler = ConnectionIdleTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        // Send a request head before the idle timeout would fire.
        let head = HTTPRequest(method: .post, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))

        // Advance well past the original idle window. Idle should not fire because a request is
        // in flight (response not yet written).
        channel.embeddedEventLoop.advanceTime(by: .seconds(60))

        #expect(channel.isActive)
    }

    @Test("Body parts do not reset idle (because idle is paused)")
    func bodyPartsDoNotMatter() throws {
        let channel = EmbeddedChannel()
        let handler = ConnectionIdleTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        let head = HTTPRequest(method: .post, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))
        try channel.writeInbound(HTTPRequestPart.body(ByteBuffer(bytes: [1, 2, 3])))

        // Idle is paused while a request is in flight; it doesn't matter that we got body bytes.
        channel.embeddedEventLoop.advanceTime(by: .seconds(10))
        #expect(channel.isActive)
    }

    @Test("Idle timer is rearmed after response end (between requests)")
    func idleRearmedAfterResponseEnd() throws {
        let channel = EmbeddedChannel()
        let handler = ConnectionIdleTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        // Process a request fully.
        let head = HTTPRequest(method: .get, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))
        try channel.writeInbound(HTTPRequestPart.end(nil))
        try channel.writeOutbound(HTTPResponsePart.head(HTTPResponse(status: .ok)))
        try channel.writeOutbound(HTTPResponsePart.end(nil))

        // No new request — advance past the idle window. Connection should close.
        channel.embeddedEventLoop.advanceTime(by: .seconds(6))
        #expect(!channel.isActive)
    }

    @Test("Idle timer is cancelled when next request begins on a keep-alive connection")
    func idleCancelledOnNextRequest() throws {
        let channel = EmbeddedChannel()
        let handler = ConnectionIdleTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        // First request/response cycle.
        let head = HTTPRequest(method: .get, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))
        try channel.writeInbound(HTTPRequestPart.end(nil))
        try channel.writeOutbound(HTTPResponsePart.head(HTTPResponse(status: .ok)))
        try channel.writeOutbound(HTTPResponsePart.end(nil))

        // Wait partway, then start a second request before idle fires.
        channel.embeddedEventLoop.advanceTime(by: .seconds(4))
        try channel.writeInbound(HTTPRequestPart.head(head))

        // Advance well past — idle should be paused again.
        channel.embeddedEventLoop.advanceTime(by: .seconds(60))
        #expect(channel.isActive)
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

    @Test("Idle timer starts when handler is added to an already-active channel")
    func idleTimerStartsWhenAddedToActiveChannel() throws {
        let channel = EmbeddedChannel()

        // Activate the channel *before* adding the handler. This mirrors the secure HTTP/1.1 path,
        // where the timeout handlers are installed after ALPN negotiation completes — by which point
        // the channel is already active and `channelActive` will never fire for them again.
        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()
        #expect(channel.isActive)

        let handler = ConnectionIdleTimeoutHandler(timeout: .seconds(5))
        try channel.pipeline.syncOperations.addHandler(handler)

        // The idle timer must have been armed in `handlerAdded`, so the connection closes once the
        // timeout elapses with no request in flight.
        channel.embeddedEventLoop.advanceTime(by: .seconds(6))

        #expect(!channel.isActive)
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

        // Right after `.end`, the header timeout is re-armed for the next request. Send a fresh
        // head before that timer fires so the connection stays open.
        channel.embeddedEventLoop.advanceTime(by: .seconds(3))
        try channel.writeInbound(HTTPRequestPart.head(head))

        // Body timer is now ticking on the second request — finish within the body timeout.
        channel.embeddedEventLoop.advanceTime(by: .seconds(5))
        try channel.writeInbound(HTTPRequestPart.end(nil))

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

    @Test("Header timeout is re-armed after end so subsequent requests are protected")
    func headerTimeoutRearmedAfterEnd() throws {
        let channel = EmbeddedChannel()
        let handler = RequestTimeoutHandler(readHeaderTimeout: .seconds(5), readBodyTimeout: nil)
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()

        // First request completes successfully within the header timeout window.
        let head = HTTPRequest(method: .get, scheme: "http", authority: "", path: "/")
        try channel.writeInbound(HTTPRequestPart.head(head))
        try channel.writeInbound(HTTPRequestPart.end(nil))

        // Now no second request arrives within the header timeout — connection should be closed.
        channel.embeddedEventLoop.advanceTime(by: .seconds(6))

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

    // MARK: - Added to an already-active channel

    @Test("Header timeout starts when handler is added to an already-active channel")
    func headerTimeoutStartsWhenAddedToActiveChannel() throws {
        let channel = EmbeddedChannel()

        // Activate the channel *before* adding the handler. This mirrors the secure HTTP/1.1 path,
        // where the timeout handlers are installed after ALPN negotiation completes — by which point
        // the channel is already active and `channelActive` will never fire for them again.
        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()
        #expect(channel.isActive)

        let handler = RequestTimeoutHandler(readHeaderTimeout: .seconds(5), readBodyTimeout: nil)
        try channel.pipeline.syncOperations.addHandler(handler)

        // The header timer must have been armed in `handlerAdded`, so the connection closes once the
        // timeout elapses with no request headers received.
        channel.embeddedEventLoop.advanceTime(by: .seconds(6))

        #expect(!channel.isActive)
    }
}
