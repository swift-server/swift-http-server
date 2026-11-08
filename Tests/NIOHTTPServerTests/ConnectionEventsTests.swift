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
    @Test("A handler receives the events that happen while its operation runs")
    func handlerReceivesEventsDuringOperation() async throws {
        let context = NIOHTTPServer.ConnectionContext(httpVersion: .http2, remoteAddress: Self.originalAddress)
        let channel = try Self.makeConnectionChannel(keepingCurrent: context)
        let received = NIOLockedValueBox<[NIOHTTPServer.ConnectionEvent]>([])

        await context.withConnectionEventHandler {
            channel.pipeline.fireUserInboundEventTriggered(
                NIOHTTPServer.ConnectionEvent.remoteAddressChanged(Self.migratedAddress)
            )
            channel.pipeline.fireUserInboundEventTriggered(
                NIOHTTPServer.ConnectionEvent.remoteAddressChanged(Self.secondMigratedAddress)
            )
        } onEvent: { event in
            received.withLockedValue { $0.append(event) }
        }

        #expect(
            received.withLockedValue { $0 } == [
                .remoteAddressChanged(Self.migratedAddress),
                .remoteAddressChanged(Self.secondMigratedAddress),
            ]
        )
    }

    @available(anyAppleOS 27.0, *)
    @Test("Every registered handler receives each event")
    func everyRegisteredHandlerReceivesEachEvent() async throws {
        let context = NIOHTTPServer.ConnectionContext(httpVersion: .http2, remoteAddress: Self.originalAddress)
        let channel = try Self.makeConnectionChannel(keepingCurrent: context)
        let receivedByOuter = NIOLockedValueBox<[NIOHTTPServer.ConnectionEvent]>([])
        let receivedByInner = NIOLockedValueBox<[NIOHTTPServer.ConnectionEvent]>([])

        await context.withConnectionEventHandler {
            await context.withConnectionEventHandler {
                channel.pipeline.fireUserInboundEventTriggered(
                    NIOHTTPServer.ConnectionEvent.remoteAddressChanged(Self.migratedAddress)
                )
            } onEvent: { event in
                receivedByInner.withLockedValue { $0.append(event) }
            }
        } onEvent: { event in
            receivedByOuter.withLockedValue { $0.append(event) }
        }

        #expect(receivedByOuter.withLockedValue { $0 } == [.remoteAddressChanged(Self.migratedAddress)])
        #expect(receivedByInner.withLockedValue { $0 } == [.remoteAddressChanged(Self.migratedAddress)])
    }

    @available(anyAppleOS 27.0, *)
    @Test("A handler does not receive events from before or after its operation")
    func handlerIgnoresEventsOutsideItsOperation() async throws {
        let context = NIOHTTPServer.ConnectionContext(httpVersion: .http2, remoteAddress: Self.originalAddress)
        let channel = try Self.makeConnectionChannel(keepingCurrent: context)
        let received = NIOLockedValueBox<[NIOHTTPServer.ConnectionEvent]>([])

        channel.pipeline.fireUserInboundEventTriggered(
            NIOHTTPServer.ConnectionEvent.remoteAddressChanged(Self.originalAddress)
        )
        await context.withConnectionEventHandler {
            channel.pipeline.fireUserInboundEventTriggered(
                NIOHTTPServer.ConnectionEvent.remoteAddressChanged(Self.migratedAddress)
            )
        } onEvent: { event in
            received.withLockedValue { $0.append(event) }
        }
        channel.pipeline.fireUserInboundEventTriggered(
            NIOHTTPServer.ConnectionEvent.remoteAddressChanged(Self.secondMigratedAddress)
        )

        #expect(received.withLockedValue { $0 } == [.remoteAddressChanged(Self.migratedAddress)])
    }

    @available(anyAppleOS 27.0, *)
    @Test("A handler is removed, and the error propagates, when its operation throws")
    func handlerIsRemovedWhenOperationThrows() async throws {
        let context = NIOHTTPServer.ConnectionContext(httpVersion: .http2, remoteAddress: Self.originalAddress)
        let channel = try Self.makeConnectionChannel(keepingCurrent: context)
        let received = NIOLockedValueBox<[NIOHTTPServer.ConnectionEvent]>([])

        await #expect(throws: TestError.intentional) {
            try await context.withConnectionEventHandler {
                throw TestError.intentional
            } onEvent: { event in
                received.withLockedValue { $0.append(event) }
            }
        }
        channel.pipeline.fireUserInboundEventTriggered(
            NIOHTTPServer.ConnectionEvent.remoteAddressChanged(Self.migratedAddress)
        )

        #expect(received.withLockedValue { $0 }.isEmpty)
    }

    @available(anyAppleOS 27.0, *)
    @Test("The operation's result is returned")
    func operationResultIsReturned() async throws {
        let context = NIOHTTPServer.ConnectionContext(httpVersion: .http2, remoteAddress: Self.originalAddress)

        let result = await context.withConnectionEventHandler {
            "result"
        } onEvent: { _ in
        }

        #expect(result == "result")
    }

    @available(anyAppleOS 27.0, *)
    @Test("The remote address is already updated when a handler is called")
    func remoteAddressIsUpdatedBeforeHandlersAreCalled() async throws {
        let context = NIOHTTPServer.ConnectionContext(httpVersion: .http2, remoteAddress: Self.originalAddress)
        let channel = try Self.makeConnectionChannel(keepingCurrent: context)
        let addressSeenByHandler = NIOLockedValueBox<NIOHTTPServer.SocketAddress?>(nil)

        await context.withConnectionEventHandler {
            channel.pipeline.fireUserInboundEventTriggered(
                NIOHTTPServer.ConnectionEvent.remoteAddressChanged(Self.migratedAddress)
            )
        } onEvent: { _ in
            addressSeenByHandler.withLockedValue { $0 = context.remoteAddress }
        }

        #expect(addressSeenByHandler.withLockedValue { $0 } == Self.migratedAddress)
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

    // MARK: - End to end

    #if HTTP3
    /// Only HTTP/3 connections can migrate to a new network path, so only their pipelines report connection events.
    @available(anyAppleOS 27.0, *)
    @Test("A request handler observes its connection's remote address changing")
    func requestHandlerObservesRemoteAddressChange() async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: .http3,
            clientLogger: Self.logger,
            serverLogger: Self.logger
        )

        let observed = NIOLockedValueBox<
            (event: NIOHTTPServer.ConnectionEvent?, remoteAddress: NIOHTTPServer.SocketAddress?)
        >((nil, nil))

        try await TestHelpers.withClientServerConnection(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, requestContext, reader, responseSender in
                var reader = reader

                // Stands in for the QUIC stack reporting a migration on the connection carrying this request. The
                // request's stream channel is a child of that connection's channel.
                let connectionChannel = requestContext.channel.parent!
                let (events, eventsContinuation) = AsyncStream.makeStream(of: NIOHTTPServer.ConnectionEvent.self)

                // Only the long-running part of the handler goes inside the operation: it is a closure, so it can use
                // the noncopyable `reader` but cannot consume the `responseSender` that it captures.
                try await requestContext.withConnectionEventHandler {
                    connectionChannel.pipeline.fireUserInboundEventTriggered(
                        NIOHTTPServer.ConnectionEvent.remoteAddressChanged(Self.migratedAddress)
                    )
                    let event = await Self.firstEvent(of: events)
                    observed.withLockedValue { $0 = (event, requestContext.remoteAddress) }

                    try await reader.read { _, _ in }
                } onEvent: { event in
                    eventsContinuation.yield(event)
                }

                var body = UniqueArray<UInt8>(copying: [])
                try await responseSender.sendAndFinish(.init(status: .ok), buffer: &body)
            }
        ) { _, connection in
            try await Self.sendRequestAndAwaitResponse(on: connection, httpVersion: .http3)
        }

        let (event, remoteAddress) = observed.withLockedValue { $0 }
        #expect(event == .remoteAddressChanged(Self.migratedAddress))
        #expect(remoteAddress == Self.migratedAddress)
    }
    #endif

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

    #if HTTP3
    /// Returns the first event `events` yields, or `nil` if none arrives within ``deliveryWindow``.
    @available(anyAppleOS 27.0, *)
    private static func firstEvent(
        of events: AsyncStream<NIOHTTPServer.ConnectionEvent>
    ) async -> NIOHTTPServer.ConnectionEvent? {
        await withTaskGroup(of: NIOHTTPServer.ConnectionEvent?.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: Self.deliveryWindow)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
    #endif

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
