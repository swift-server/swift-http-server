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
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing

@testable import NIOHTTPServer

@Suite("Connection events", .timeLimit(.minutes(1)))
struct ConnectionEventsTests {
    static let logger = Logger(label: "ConnectionEventsTests")

    /// The address the client connected from, before any migration.
    @available(anyAppleOS 27.0, *)
    static var originalAddress: NIOHTTPServer.SocketAddress { .ipv4(host: "203.0.113.7", port: 50000) }

    @available(anyAppleOS 27.0, *)
    static var migratedAddress: NIOHTTPServer.SocketAddress { .ipv4(host: "192.0.2.1", port: 4433) }

    @available(anyAppleOS 27.0, *)
    static var secondMigratedAddress: NIOHTTPServer.SocketAddress { .ipv4(host: "192.0.2.2", port: 4434) }

    /// How long to wait for something that should happen promptly before concluding it never will.
    static let deliveryWindow = Duration.seconds(5)

    // MARK: - The connection channel's handler

    @available(anyAppleOS 27.0, *)
    @Test("An event fired into the connection's pipeline updates its remote address")
    func eventUpdatesRemoteAddress() throws {
        let context = NIOHTTPServer.ConnectionContext(httpVersion: .http2, remoteAddress: Self.originalAddress)
        let channel = try Self.makeConnectionChannel(keepingCurrent: context)

        channel.pipeline.fireUserInboundEventTriggered(
            NIOHTTPServer.ConnectionEvent.remoteAddressChanged(Self.migratedAddress)
        )

        #expect(context.remoteAddress == Self.migratedAddress)
    }

    @available(anyAppleOS 27.0, *)
    @Test("Every iterator receives each event that happens after it was created")
    func everyIteratorReceivesEachEvent() async throws {
        let context = NIOHTTPServer.ConnectionContext(httpVersion: .http2, remoteAddress: Self.originalAddress)
        let channel = try Self.makeConnectionChannel(keepingCurrent: context)
        var first = context.connectionEvents.makeAsyncIterator()
        var second = context.connectionEvents.makeAsyncIterator()

        channel.pipeline.fireUserInboundEventTriggered(
            NIOHTTPServer.ConnectionEvent.remoteAddressChanged(Self.migratedAddress)
        )
        channel.pipeline.fireChannelInactive()

        #expect(await first.next() == .remoteAddressChanged(Self.migratedAddress))
        #expect(await second.next() == .remoteAddressChanged(Self.migratedAddress))
    }

    @available(anyAppleOS 27.0, *)
    @Test("An iterator does not receive events that happened before it was created")
    func iteratorSkipsEarlierEvents() async throws {
        let context = NIOHTTPServer.ConnectionContext(httpVersion: .http2, remoteAddress: Self.originalAddress)
        let channel = try Self.makeConnectionChannel(keepingCurrent: context)

        channel.pipeline.fireUserInboundEventTriggered(
            NIOHTTPServer.ConnectionEvent.remoteAddressChanged(Self.migratedAddress)
        )
        var iterator = context.connectionEvents.makeAsyncIterator()
        channel.pipeline.fireUserInboundEventTriggered(
            NIOHTTPServer.ConnectionEvent.remoteAddressChanged(Self.secondMigratedAddress)
        )
        channel.pipeline.fireChannelInactive()

        #expect(await iterator.next() == .remoteAddressChanged(Self.secondMigratedAddress))
    }

    @available(anyAppleOS 27.0, *)
    @Test("The connection going inactive ends every iterator, including ones created afterwards")
    func inactiveConnectionEndsIterators() async throws {
        let context = NIOHTTPServer.ConnectionContext(httpVersion: .http2, remoteAddress: Self.originalAddress)
        let channel = try Self.makeConnectionChannel(keepingCurrent: context)
        var before = context.connectionEvents.makeAsyncIterator()

        channel.pipeline.fireChannelInactive()
        var after = context.connectionEvents.makeAsyncIterator()

        #expect(await before.next() == nil)
        #expect(await after.next() == nil)
    }

    @available(anyAppleOS 27.0, *)
    @Test("Events carry on down the pipeline")
    func eventsAreForwarded() throws {
        let context = NIOHTTPServer.ConnectionContext(httpVersion: .http2, remoteAddress: Self.originalAddress)
        let channel = try Self.makeConnectionChannel(keepingCurrent: context)
        let recorder = UserEventRecorder()
        try channel.pipeline.syncOperations.addHandler(recorder)

        channel.pipeline.fireUserInboundEventTriggered(
            NIOHTTPServer.ConnectionEvent.remoteAddressChanged(Self.migratedAddress)
        )
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        #expect(recorder.events.count == 2)
        #expect(recorder.events.first as? NIOHTTPServer.ConnectionEvent == .remoteAddressChanged(Self.migratedAddress))
        #expect(recorder.events.last as? ChannelEvent == .inputClosed)
    }

    @available(anyAppleOS 27.0, *)
    @Test("A dropped iterator is no longer delivered to")
    func droppedIteratorIsUnregistered() throws {
        let context = NIOHTTPServer.ConnectionContext(httpVersion: .http2, remoteAddress: Self.originalAddress)

        do {
            let iterator = context.connectionEvents.makeAsyncIterator()
            #expect(context.connectionEvents.broadcaster.subscriberCount == 1)
            _ = consume iterator
        }

        #expect(context.connectionEvents.broadcaster.subscriberCount == 0)
    }

    // MARK: - End to end

    @available(anyAppleOS 27.0, *)
    @Test(
        "A request handler observes its connection's remote address changing",
        arguments: NIOHTTPServer.HTTPVersion.allCases
    )
    func requestHandlerObservesRemoteAddressChange(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: Self.logger,
            serverLogger: Self.logger
        )

        let observed = NIOLockedValueBox<
            (event: NIOHTTPServer.ConnectionEvent?, remoteAddress: NIOHTTPServer.SocketAddress?)
        >((nil, nil))

        try await TestHelpers.withClientServerConnection(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, requestContext, _, responseSender in
                // Stands in for the QUIC stack reporting a migration on the connection carrying this request.
                let connectionChannel = Self.connectionChannel(carrying: requestContext)
                let event = try await Self.firstEvent(of: requestContext.connectionEvents) {
                    connectionChannel.pipeline.fireUserInboundEventTriggered(
                        NIOHTTPServer.ConnectionEvent.remoteAddressChanged(Self.migratedAddress)
                    )
                }
                observed.withLockedValue { $0 = (event, requestContext.remoteAddress) }

                var body = UniqueArray<UInt8>(copying: [])
                try await responseSender.sendAndFinish(.init(status: .ok), buffer: &body)
            }
        ) { _, connection in
            try await Self.sendRequestAndAwaitResponse(on: connection, httpVersion: httpVersion)
        }

        let (event, remoteAddress) = observed.withLockedValue { $0 }
        #expect(event == .remoteAddressChanged(Self.migratedAddress))
        #expect(remoteAddress == Self.migratedAddress)
    }

    @available(anyAppleOS 27.0, *)
    @Test(
        "A connection's events finish when the client closes the connection",
        arguments: NIOHTTPServer.HTTPVersion.allCases
    )
    func connectionEventsFinishWhenClientCloses(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: Self.logger,
            serverLogger: Self.logger
        )

        let (subscribed, subscribedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (finished, finishedContinuation) = AsyncStream.makeStream(of: Void.self)

        try await TestHelpers.withClientServerConnection(
            clientConfiguration: clientConfiguration,
            server: server,
            connectionHandler: NIOHTTPServerClosureConnectionHandler { connection, context in
                // Unstructured, so that observing the events cannot hold the connection open.
                Task {
                    var iterator = context.connectionEvents.makeAsyncIterator()
                    subscribedContinuation.finish()
                    while await iterator.next() != nil {}
                    finishedContinuation.finish()
                }

                await connection.handleRequests { _, _, _, _ in }
            }
        ) { _, connection in
            for await _ in subscribed {}

            #if HTTP3
            if httpVersion == .http3 {
                try await connection.closeAnnouncingDeparture()
            } else {
                try await connection.close()
            }
            #else
            try await connection.close()
            #endif

            #expect(
                await Self.finishes(finished, within: Self.deliveryWindow),
                "The connection's events should have finished once the client closed the connection (\(httpVersion))."
            )
        }
    }

    @available(anyAppleOS 27.0, *)
    @Test(
        "The request context reports the connection's local and remote addresses",
        arguments: NIOHTTPServer.HTTPVersion.allCases
    )
    func requestContextReportsAddresses(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: Self.logger,
            serverLogger: Self.logger
        )

        let observed = NIOLockedValueBox<
            (localAddress: NIOHTTPServer.SocketAddress?, remoteAddress: NIOHTTPServer.SocketAddress?)
        >((nil, nil))

        try await TestHelpers.withClientServerConnection(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, requestContext, _, responseSender in
                observed.withLockedValue { $0 = (requestContext.localAddress, requestContext.remoteAddress) }

                var body = UniqueArray<UInt8>(copying: [])
                try await responseSender.sendAndFinish(.init(status: .ok), buffer: &body)
            }
        ) { serverAddress, connection in
            // Read before the request: over HTTP/1.1 the request channel is the connection, which the request closes.
            let clientPort = try #require(connection.localPort)
            try await Self.sendRequestAndAwaitResponse(on: connection, httpVersion: httpVersion)

            let (localAddress, remoteAddress) = observed.withLockedValue { $0 }
            #expect(localAddress?.port == serverAddress.port)
            #expect(remoteAddress?.port == clientPort)
        }
    }

    // MARK: - Helpers

    /// An `EmbeddedChannel` standing in for a connection channel, whose pipeline keeps `context` current.
    @available(anyAppleOS 27.0, *)
    private static func makeConnectionChannel(
        keepingCurrent context: NIOHTTPServer.ConnectionContext
    ) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(ConnectionEventsHandler(connectionContext: context))
        return channel
    }

    /// The channel of the connection carrying a request.
    ///
    /// Over HTTP/1.1 the request's channel is the connection channel itself, while over HTTP/2 and HTTP/3 it is a
    /// stream channel whose parent is the connection channel.
    @available(anyAppleOS 27.0, *)
    private static func connectionChannel(carrying requestContext: NIOHTTPServer.RequestContext) -> any Channel {
        switch requestContext.connectionContext.httpVersion {
        case .plaintextHTTP1_1, .http1_1:
            requestContext.channel
        default:
            requestContext.channel.parent!
        }
    }

    /// Starts iterating `events`, runs `trigger`, and returns the first event that follows, or `nil` if none arrives
    /// within ``deliveryWindow``.
    @available(anyAppleOS 27.0, *)
    private static func firstEvent(
        of events: NIOHTTPServer.ConnectionEvents,
        after trigger: () async throws -> Void
    ) async throws -> NIOHTTPServer.ConnectionEvent? {
        let (subscribed, subscribedContinuation) = AsyncStream.makeStream(of: Void.self)

        return try await withThrowingTaskGroup(of: NIOHTTPServer.ConnectionEvent?.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                subscribedContinuation.finish()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: Self.deliveryWindow)
                return nil
            }

            for await _ in subscribed {}
            try await trigger()

            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Returns whether `stream` finishes within `window`.
    private static func finishes(_ stream: AsyncStream<Void>, within window: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream {}
                return true
            }
            group.addTask {
                try? await Task.sleep(for: window)
                return false
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Sends a bodiless `GET` on a new request channel and reads the response through to its end.
    @available(anyAppleOS 27.0, *)
    private static func sendRequestAndAwaitResponse(
        on connection: TestClientConnection,
        httpVersion: NIOHTTPServer.HTTPVersion
    ) async throws {
        let requestChannel = try await connection.makeRequestChannel(expectedHTTPVersion: httpVersion)
        try await requestChannel.executeThenClose { inbound, outbound in
            try await outbound.write(.testHead(method: .get, for: httpVersion))
            try await outbound.write(.end(nil))

            for try await part in inbound {
                if case .end = part { break }
            }
        }
    }
}

/// Records the user inbound events that reach it.
private final class UserEventRecorder: ChannelInboundHandler {
    typealias InboundIn = NIOAny

    private(set) var events: [Any] = []

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        self.events.append(event)
    }
}

@available(anyAppleOS 27.0, *)
extension TestClientConnection {
    /// The port this client connection is bound to locally.
    var localPort: Int? {
        switch self.connectionProtocol {
        case .http1(let connectionChannel):
            connectionChannel.channel.localAddress?.port
        case .http2(let connectionChannel, _):
            connectionChannel.localAddress?.port
        #if HTTP3
        case .http3(_, let connectionChannel, _):
            connectionChannel.localAddress?.port
        #endif
        }
    }
}
