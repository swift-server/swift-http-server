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

import Logging
import NIOCore
import NIOEmbedded
import NIOHTTPTypes
import Testing

@testable import NIOHTTPServer

@Suite("ConnectionLimitHandler")
struct ConnectionLimitHandlerTests {

    @Test("Connections under limit are accepted")
    func connectionsUnderLimitAreAccepted() async throws {
        let channel = EmbeddedChannel()
        let handler = makeConnectionLimitHandler(maxConnections: 3)
        try channel.pipeline.syncOperations.addHandler(handler)

        // Create and write 3 child channels
        var children: [EmbeddedChannel] = []
        for _ in 0..<3 {
            let child = EmbeddedChannel()
            children.append(child)
            try channel.writeInbound(child)
        }

        // All 3 should have been forwarded
        for _ in 0..<3 {
            let forwarded = try channel.readInbound(as: Channel.self)
            #expect(forwarded != nil)
        }
    }

    @Test("Connections at limit block reads")
    func connectionsAtLimitBlockReads() async throws {
        let channel = EmbeddedChannel()
        let handler = makeConnectionLimitHandler(maxConnections: 2)

        // Add a handler closer to the head that counts read() calls that pass through.
        let readCounter = ReadCountingHandler()
        try channel.pipeline.syncOperations.addHandler(readCounter)
        try channel.pipeline.syncOperations.addHandler(handler, position: .last)

        // Open a connection. We should still be under the limit.
        let child1 = try makeActiveChild(on: channel.embeddedEventLoop)
        try channel.writeInbound(child1)

        // Trigger a read while within the acceptable number of connections: it should be forwarded.
        channel.read()
        channel.embeddedEventLoop.run()

        #expect(readCounter.readCount == 1, "Read should be forwarded when under the limit")

        // Open a second connection. We will now reach the limit.
        let child2 = try makeActiveChild(on: channel.embeddedEventLoop)
        try channel.writeInbound(child2)

        // We are now at capacity. A second read should be blocked.
        channel.pipeline.read()
        #expect(readCounter.readCount == 1, "Second read should NOT be forwarded when at capacity")
    }

    @Test("Connections resume after close")
    func connectionsResumeAfterClose() async throws {
        let channel = EmbeddedChannel()
        let handler = makeConnectionLimitHandler(maxConnections: 1)
        try channel.pipeline.syncOperations.addHandler(handler)

        // Open 1 connection (at limit)
        let child1 = EmbeddedChannel()
        try channel.writeInbound(child1)
        _ = try channel.readInbound(as: Channel.self)

        // Close the child connection
        try await child1.close().get()

        // Run pending tasks on the event loop
        channel.embeddedEventLoop.run()

        // Now we should be able to accept a new connection
        let child2 = EmbeddedChannel()
        try channel.writeInbound(child2)
        let forwarded = try channel.readInbound(as: Channel.self)
        #expect(forwarded != nil)
    }

    @Test("Multiple connections close and resume")
    func multipleConnectionsCloseAndResume() async throws {
        let channel = EmbeddedChannel()
        let handler = makeConnectionLimitHandler(maxConnections: 3)
        try channel.pipeline.syncOperations.addHandler(handler)

        // Open 3 connections
        var children: [EmbeddedChannel] = []
        for _ in 0..<3 {
            let child = EmbeddedChannel()
            children.append(child)
            try channel.writeInbound(child as Channel)
            _ = try channel.readInbound(as: Channel.self)
        }

        // Close 2 of them
        try await children[0].close().get()
        try await children[1].close().get()
        channel.embeddedEventLoop.run()

        // Should be able to accept 2 more
        for _ in 0..<2 {
            let child = EmbeddedChannel()
            try channel.writeInbound(child as Channel)
            let forwarded = try channel.readInbound(as: Channel.self)
            #expect(forwarded != nil)
        }
    }

    @Test("Handler does not interfere when under limit")
    func handlerDoesNotInterfereUnderLimit() async throws {
        let channel = EmbeddedChannel()
        let handler = makeConnectionLimitHandler(maxConnections: 100)
        try channel.pipeline.syncOperations.addHandler(handler)

        // Open 5 connections — well under the limit
        for _ in 0..<5 {
            let child = EmbeddedChannel()
            try channel.writeInbound(child as Channel)
            let forwarded = try channel.readInbound(as: Channel.self)
            #expect(forwarded != nil)
        }
    }

    @Test func rateLimitHoldsReadsUntilNextToken() throws {
        let channel = EmbeddedChannel()
        let readCounter = ReadCountingHandler()
        try channel.pipeline.syncOperations.addHandler(readCounter)

        // Set a rate limit of 2 new connections per second. This means the token `refreshInterval` is 500ms.
        try channel.pipeline.syncOperations.addHandler(makeConnectionLimitHandler(newConnectionRateLimit: 2))

        for expectedReadCount in 1...2 {
            channel.read()
            #expect(readCounter.readCount == expectedReadCount)

            try channel.writeInbound(EmbeddedChannel())
            let forwarded = try channel.readInbound(as: Channel.self)

            #expect(forwarded != nil)
        }

        // Now fire a `read()`; this should not be forwarded until we go below the rate limit.
        channel.read()
        #expect(readCounter.readCount == 2, "Read should be held once the rate limit is hit")

        channel.embeddedEventLoop.advanceTime(by: .milliseconds(499))
        #expect(readCounter.readCount == 2, "Read should be held until the next token is due")

        channel.embeddedEventLoop.advanceTime(by: .milliseconds(1))
        // 500ms have passed so we should have a new token. The `read()` call should now be forwarded.
        #expect(readCounter.readCount == 3, "Read should be forwarded once the next token is due")

        try channel.writeInbound(EmbeddedChannel())
        let forwarded = try channel.readInbound(as: Channel.self)
        #expect(forwarded != nil)
    }

    @Test func rateOvershootIsAdmittedAndRepaidBeforeNextRead() throws {
        let channel = EmbeddedChannel()
        let readCounter = ReadCountingHandler()
        try channel.pipeline.syncOperations.addHandler(readCounter)

        // Set a rate limit of 2 new connections per second. This means the token `refreshInterval` is 500ms.
        try channel.pipeline.syncOperations.addHandler(makeConnectionLimitHandler(newConnectionRateLimit: 2))

        // Fire a `read()` call.
        channel.read()
        #expect(readCounter.readCount == 1)

        // Now simulate a burst of 4 connections.
        var children = [EmbeddedChannel]()
        for _ in 0..<4 {
            let child = EmbeddedChannel()
            try channel.writeInbound(child)
            children.append(child)
        }

        // All 4 connections should be accepted, but our token balance should now be negative (-2).
        for _ in children {
            let forwarded = try channel.readInbound(as: Channel.self)
            #expect(forwarded != nil, "A connection beyond the rate should be forwarded")
        }

        // The next `read()` call should not be forwarded until 3 `refreshInterval`s (1500ms) have passed: two to cover
        // the debt, and one more for the next connection.
        channel.read()
        #expect(readCounter.readCount == 1, "Read should be held while the bucket refills the debt")

        channel.embeddedEventLoop.advanceTime(by: .milliseconds(1000))
        #expect(readCounter.readCount == 1, "Read should be held once the debt is refilled")

        channel.embeddedEventLoop.advanceTime(by: .milliseconds(499))
        #expect(readCounter.readCount == 1)

        // Only after 1500ms have passed should the `read()` call be forwarded.
        channel.embeddedEventLoop.advanceTime(by: .milliseconds(1))
        #expect(readCounter.readCount == 2, "Read should be forwarded once the bucket holds a token")

        // Now check that we can admit a connection.
        let child = EmbeddedChannel()
        try channel.writeInbound(child)
        #expect(try channel.readInbound(as: Channel.self) != nil)
    }

    @Test func connectionLimitAdmitsBatchOvershoot() throws {
        let channel = EmbeddedChannel()
        let readCounter = ReadCountingHandler()
        try channel.pipeline.syncOperations.addHandler(readCounter)

        // Set a limit of 2 open connections.
        try channel.pipeline.syncOperations.addHandler(makeConnectionLimitHandler(maxConnections: 2))

        channel.read()
        #expect(readCounter.readCount == 1)

        var children = [EmbeddedChannel]()
        for _ in 0..<3 {
            let child = try makeActiveChild(on: channel.embeddedEventLoop)
            try channel.writeInbound(child)
            children.append(child)
        }

        // All 3 connections should be accepted as they all arrived as a result of the same `read()` call.
        let first = try channel.readInbound(as: Channel.self)
        let second = try channel.readInbound(as: Channel.self)
        let third = try channel.readInbound(as: Channel.self)
        #expect(first != nil)
        #expect(second != nil)
        #expect(third != nil, "The connection beyond maxConnections should be forwarded")
        #expect(children.allSatisfy { $0.isActive }, "No connection beyond maxConnections should be closed")

        // `read()` calls should now be held until fewer than `maxConnections` connections are open.
        channel.read()
        #expect(readCounter.readCount == 1, "Read should be held with 3 of 2 connections open")

        children[0].close(promise: nil)
        channel.embeddedEventLoop.run()
        #expect(readCounter.readCount == 1, "Read should still be held with 2 of 2 connections open")

        children[1].close(promise: nil)
        channel.embeddedEventLoop.run()
        #expect(readCounter.readCount == 2, "Read should be forwarded with 1 of 2 connections open")
    }

    @Test func repeatedReadsDoNotConsumeTokens() throws {
        let channel = EmbeddedChannel()
        let readCounter = ReadCountingHandler()
        try channel.pipeline.syncOperations.addHandler(readCounter)
        try channel.pipeline.syncOperations.addHandler(makeConnectionLimitHandler(newConnectionRateLimit: 1))

        // Fire three `read()` calls.
        channel.read()
        channel.read()
        channel.read()
        // All three should be forwared. Tokens should only be consumed on `channelRead()`.
        #expect(readCounter.readCount == 3, "Reads shouldn't take the only token")

        // Now simulate a connection arriving. This should exhaust the rate limit.
        try channel.writeInbound(EmbeddedChannel())
        let forwarded = try channel.readInbound(as: Channel.self)
        #expect(forwarded != nil)

        // Further `read()` calls shouldn't be forwared now.
        channel.read()
        #expect(readCounter.readCount == 3)
    }

    @Test func readHeldByConnectionLimitStillRateLimitsConnections() throws {
        let channel = EmbeddedChannel()
        let readCounter = ReadCountingHandler()
        try channel.pipeline.syncOperations.addHandler(readCounter)

        // Set a rate limit of 1 new connection per second. This means the token `refreshInterval` is also 1s.
        try channel.pipeline.syncOperations.addHandler(
            makeConnectionLimitHandler(maxConnections: 1, newConnectionRateLimit: 1)
        )

        // The first connection should take the only token and exhaust the connection rate limit.
        channel.read()
        #expect(readCounter.readCount == 1)
        let child1 = try makeActiveChild(on: channel.embeddedEventLoop)
        try channel.writeInbound(child1)

        // The connection limit should hold the next read while the bucket refills.
        channel.read()
        #expect(readCounter.readCount == 1, "Read should be held with 1 of 1 connections open")
        // Wait 2s for the bucket to refill. Since the connection hasn't closed, we still can't forward the `read()`
        // call.
        channel.embeddedEventLoop.advanceTime(by: .seconds(2))
        #expect(readCounter.readCount == 1)

        // Now close the active connection. This should trigger the held read to be forwarded.
        child1.close(promise: nil)
        channel.embeddedEventLoop.run()
        #expect(readCounter.readCount == 2, "Read should be forwarded once the connection closes")

        // Now it should be possible for another connection to be admitted.
        let child2 = try makeActiveChild(on: channel.embeddedEventLoop)
        try channel.writeInbound(child2)
        child2.close(promise: nil)
        channel.embeddedEventLoop.run()

        // There is no token left for the next read.
        channel.read()
        #expect(readCounter.readCount == 2, "Read should be held until the next token is due")
    }
}

/// Makes a handler that enforces the given limits.
private func makeConnectionLimitHandler(
    maxConnections: Int? = nil,
    newConnectionRateLimit: Int? = nil
) -> ConnectionLimitHandler {
    ConnectionLimitHandler(
        limits: ConnectionLimitHandler.LimitConfiguration(
            maxConnections: maxConnections,
            newConnectionRateLimit: newConnectionRateLimit
        ),
        logger: Logger(label: "ConnectionLimitHandlerTests")
    )
}

/// Returns an active child channel on `loop`.
private func makeActiveChild(on loop: EmbeddedEventLoop) throws -> EmbeddedChannel {
    let child = EmbeddedChannel(loop: loop)
    try child.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()
    return child
}

/// A handler that counts how many `read()` calls pass through it.
/// Placed before (closer to the head) the `ConnectionLimitHandler` in the pipeline
/// so it observes reads that the limiter forwards toward the socket.
private final class ReadCountingHandler: ChannelOutboundHandler {
    typealias OutboundIn = Any

    var readCount: Int = 0

    func read(context: ChannelHandlerContext) {
        self.readCount += 1
        context.read()
    }
}
