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
        let handler = ConnectionLimitHandler(maxConnections: 3)
        try channel.pipeline.syncOperations.addHandler(handler)

        // Create and write 3 child channels
        var children: [EmbeddedChannel] = []
        for _ in 0..<3 {
            let child = EmbeddedChannel()
            children.append(child)
            try channel.writeInbound(child as Channel)
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
        let handler = ConnectionLimitHandler(maxConnections: 2)

        // Add a handler closer to the head that counts read() calls that pass through.
        let readCounter = ReadCountingHandler()
        try channel.pipeline.syncOperations.addHandler(readCounter)
        try channel.pipeline.syncOperations.addHandler(handler, position: .last)

        // Open 2 connections to fill the limit
        let child1 = EmbeddedChannel()
        let child2 = EmbeddedChannel()
        try channel.writeInbound(child1 as Channel)
        try channel.writeInbound(child2 as Channel)

        // Trigger a read while within the acceptable number of connections: it should be forwarded.
        channel.read()
        channel.embeddedEventLoop.run()

        #expect(readCounter.readCount == 1, "Read should be forwarded when under the limit")

        // Open a third connection - this will be above the limit, so stop forwarding reads.
        let child3 = EmbeddedChannel()
        try channel.writeInbound(child3 as Channel)

        // Now at capacity — a third read should be blocked
        channel.pipeline.read()
        #expect(readCounter.readCount == 1, "Third read should NOT be forwarded when at capacity")
    }

    @Test("Connections resume after close")
    func connectionsResumeAfterClose() async throws {
        let channel = EmbeddedChannel()
        let handler = ConnectionLimitHandler(maxConnections: 1)
        try channel.pipeline.syncOperations.addHandler(handler)

        // Open 1 connection (at limit)
        let child1 = EmbeddedChannel()
        try channel.writeInbound(child1 as Channel)
        _ = try channel.readInbound(as: Channel.self)

        // Close the child connection
        try await child1.close().get()

        // Run pending tasks on the event loop
        channel.embeddedEventLoop.run()

        // Now we should be able to accept a new connection
        let child2 = EmbeddedChannel()
        try channel.writeInbound(child2 as Channel)
        let forwarded = try channel.readInbound(as: Channel.self)
        #expect(forwarded != nil)
    }

    @Test("Multiple connections close and resume")
    func multipleConnectionsCloseAndResume() async throws {
        let channel = EmbeddedChannel()
        let handler = ConnectionLimitHandler(maxConnections: 3)
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
        let handler = ConnectionLimitHandler(maxConnections: 100)
        try channel.pipeline.syncOperations.addHandler(handler)

        // Open 5 connections — well under the limit
        for _ in 0..<5 {
            let child = EmbeddedChannel()
            try channel.writeInbound(child as Channel)
            let forwarded = try channel.readInbound(as: Channel.self)
            #expect(forwarded != nil)
        }
    }
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
