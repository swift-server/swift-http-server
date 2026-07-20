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
import NIOPosix
import Testing

@testable import NIOHTTPServer

/// State observed by the connection handlers used in this test suite. The state lives
/// in a class so it survives `consuming` calls to `handleConnection` and can be
/// inspected from the test body.
@available(anyAppleOS 26.0, *)
final class ConnectionLifecycleTestState: Sendable {
    let connectionInvocations = NIOLockedValueBox(0)
    let requestInvocations = NIOLockedValueBox(0)
    let observedRemoteAddresses = NIOLockedValueBox<[NIOHTTPServer.SocketAddress?]>([])
    let observedLocalAddresses = NIOLockedValueBox<[NIOHTTPServer.SocketAddress?]>([])
    let observedFinalCounter = NIOLockedValueBox<Int?>(nil)
}

/// A connection handler that counts invocations and runs a single request handler
/// for every request on the connection.
@available(anyAppleOS 26.0, *)
struct CountingConnectionHandler<Handler: HTTPServerRequestHandler>: NIOHTTPServerConnectionHandler
where
    Handler.RequestContext == NIOHTTPServer.RequestContext,
    Handler.Reader == NIOHTTPServer.Reader,
    Handler.ResponseSender == NIOHTTPServer.ResponseSender
{
    let state: ConnectionLifecycleTestState
    let requestHandler: Handler

    func handleConnection(
        connection: consuming sending NIOHTTPServer.Connection,
        context: NIOHTTPServer.ConnectionContext
    ) async throws {
        self.state.connectionInvocations.withLockedValue { $0 += 1 }
        self.state.observedRemoteAddresses.withLockedValue { $0.append(context.remoteAddress) }
        self.state.observedLocalAddresses.withLockedValue { $0.append(context.localAddress) }

        let connectionLocalCounter = NIOLockedValueBox(0)
        let countingHandler = ConnectionScopedRequestHandler(
            wrappedHandler: self.requestHandler,
            globalCounter: self.state.requestInvocations,
            localCounter: connectionLocalCounter
        )
        await connection.handleRequests(handler: countingHandler)

        self.state.observedFinalCounter.withLockedValue { $0 = connectionLocalCounter.withLockedValue { $0 } }
    }
}

/// A request handler that increments two counters before delegating to the wrapped handler.
@available(anyAppleOS 26.0, *)
struct ConnectionScopedRequestHandler<Wrapped: HTTPServerRequestHandler>: HTTPServerRequestHandler
where
    Wrapped.RequestContext == NIOHTTPServer.RequestContext,
    Wrapped.Reader == NIOHTTPServer.Reader,
    Wrapped.ResponseSender == NIOHTTPServer.ResponseSender
{
    typealias RequestContext = NIOHTTPServer.RequestContext
    typealias Reader = NIOHTTPServer.Reader
    typealias ResponseSender = NIOHTTPServer.ResponseSender

    let wrappedHandler: Wrapped
    let globalCounter: NIOLockedValueBox<Int>
    let localCounter: NIOLockedValueBox<Int>

    func handle(
        request: HTTPRequest,
        requestContext: consuming NIOHTTPServer.RequestContext,
        reader: consuming sending NIOHTTPServer.Reader,
        responseSender: consuming sending NIOHTTPServer.ResponseSender
    ) async throws {
        self.globalCounter.withLockedValue { $0 += 1 }
        self.localCounter.withLockedValue { $0 += 1 }
        try await self.wrappedHandler.handle(
            request: request,
            requestContext: requestContext,
            reader: reader,
            responseSender: responseSender
        )
    }
}

@Suite
struct ConnectionLifecycleTests {
    @available(anyAppleOS 26.0, *)
    static var serverLogger: Logger {
        var logger = Logger(label: "ConnectionLifecycleTests")
        logger.logLevel = .info
        return logger
    }

    /// Starts `server` with `connectionHandler`, waits for it to begin listening, runs `body`
    /// with the listening address, then cancels the server task.
    @available(anyAppleOS 26.0, *)
    static func withServer<Handler: NIOHTTPServerConnectionHandler>(
        server: NIOHTTPServer,
        connectionHandler: Handler,
        body: (NIOHTTPServer.SocketAddress) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup { group in
            group.addTask {
                try await server.serve(connectionHandler: connectionHandler)
            }

            let listeningAddresses = try await server.listeningAddresses
            let address = try #require(listeningAddresses.first)

            try await body(address)

            group.cancelAll()
        }
    }

    /// Helper that echoes the request body back as a 200 OK response. Fully
    /// drains the request body, which is required for the per-channel loop
    /// to recover the iterator and keep the HTTP/1.1 connection alive across
    /// requests.
    @available(anyAppleOS 26.0, *)
    static func echoHandler() -> HTTPServerClosureRequestHandler<
        NIOHTTPServer.RequestContext,
        NIOHTTPServer.Reader,
        NIOHTTPServer.ResponseSender
    > {
        HTTPServerClosureRequestHandler { request, requestContext, reader, responseSender in
            try await NIOHTTPServerTests.echoResponse(readUpTo: 1024, reader: reader, sender: responseSender)
        }
    }

    /// HTTP/1.1: connecting twice results in two `handleConnection` invocations,
    /// each with non-nil `remoteAddress` and `localAddress`.
    @available(anyAppleOS 26.0, *)
    @Test("serve(connectionHandler:) — per-connection invocation count (HTTP/1.1)", .timeLimit(.minutes(1)))
    func testPerConnectionInvocationHTTP1_1() async throws {
        let server = try NIOHTTPServerTests.makePlaintextHTTP1Server(logger: Self.serverLogger)
        let state = ConnectionLifecycleTestState()
        let connectionHandler = CountingConnectionHandler(state: state, requestHandler: Self.echoHandler())

        try await Self.withServer(server: server, connectionHandler: connectionHandler) { serverAddress in
            for _ in 1...2 {
                let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                    .connectToTestHTTP1Server(at: serverAddress)
                try await client.executeThenClose { inbound, outbound in
                    try await outbound.write(.head(.init(method: .get, scheme: "http", authority: "", path: "/")))
                    try await outbound.write(.end(nil))
                    var iterator = inbound.makeAsyncIterator()
                    while let part = try await iterator.next() {
                        if case .end = part { break }
                    }
                }
            }
        }

        #expect(state.connectionInvocations.withLockedValue { $0 } == 2)
        let remotes = state.observedRemoteAddresses.withLockedValue { $0 }
        let locals = state.observedLocalAddresses.withLockedValue { $0 }
        #expect(remotes.count == 2)
        #expect(locals.count == 2)
        for remote in remotes { #expect(remote != nil) }
        for local in locals { #expect(local != nil) }
    }

    /// HTTP/1.1 keep-alive: two requests on the same connection result in a
    /// single `handleConnection` invocation that runs the request handler twice.
    @available(anyAppleOS 26.0, *)
    @Test("HTTP/1.1 keep-alive — single connection-handler invocation, multiple requests", .timeLimit(.minutes(1)))
    func testKeepAliveSingleInvocationMultipleRequests() async throws {
        let server = try NIOHTTPServerTests.makePlaintextHTTP1Server(logger: Self.serverLogger)
        let state = ConnectionLifecycleTestState()
        let connectionHandler = CountingConnectionHandler(state: state, requestHandler: Self.echoHandler())

        try await Self.withServer(server: server, connectionHandler: connectionHandler) { serverAddress in
            let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .connectToTestHTTP1Server(at: serverAddress)
            try await client.executeThenClose { inbound, outbound in
                // Pipeline both requests up-front, then read both responses.
                for path in ["/a", "/b"] {
                    try await outbound.write(.head(.init(method: .post, scheme: "http", authority: "", path: path)))
                    try await outbound.write(.body(ByteBuffer(string: "x")))
                    try await outbound.write(.end(nil))
                }

                var iterator = inbound.makeAsyncIterator()
                for _ in 0..<2 {
                    while let part = try await iterator.next() {
                        if case .end = part { break }
                    }
                }
            }
        }

        #expect(state.connectionInvocations.withLockedValue { $0 } == 1)
        #expect(state.requestInvocations.withLockedValue { $0 } == 2)
    }

    /// HTTP/2: three concurrent streams on one connection result in one
    /// `handleConnection` call and three request-handler calls. A user counter
    /// held by the connection handler observes three after `handleRequests`
    /// returns.
    @available(anyAppleOS 26.0, *)
    @Test("HTTP/2 — single connection-handler invocation, concurrent streams", .timeLimit(.minutes(1)))
    func testHTTP2SingleInvocationConcurrentStreams() async throws {
        let (server, serverChain) = try NIOHTTPServerTests.makeSecureUpgradeServer(logger: Self.serverLogger)
        let elg: EventLoopGroup = .singletonMultiThreadedEventLoopGroup
        let numStreams = 3
        let allRequestsReceived = elg.any().makePromise(of: Void.self)
        let arrivedCounter = NIOLockedValueBox(0)

        let state = ConnectionLifecycleTestState()

        // Inner request handler that synchronises three concurrent streams via the
        // promise so they all execute before any responds.
        let synchronizingRequestHandler:
            HTTPServerClosureRequestHandler<
                NIOHTTPServer.RequestContext,
                NIOHTTPServer.Reader,
                NIOHTTPServer.ResponseSender
            > = HTTPServerClosureRequestHandler {
                request,
                requestContext,
                reader,
                responseSender in
                let arrived = arrivedCounter.withLockedValue { value -> Int in
                    value += 1
                    return value
                }
                if arrived == numStreams {
                    allRequestsReceived.succeed()
                } else {
                    try await allRequestsReceived.futureResult.get()
                }
                var buffer = UniqueArray<UInt8>(copying: [])
                try await responseSender.sendAndFinish(.init(status: .ok), buffer: &buffer)
            }
        let connectionHandler = CountingConnectionHandler(state: state, requestHandler: synchronizingRequestHandler)

        try await Self.withServer(server: server, connectionHandler: connectionHandler) { serverAddress in
            let clientChannel = try await ClientBootstrap(group: elg)
                .connectToTestSecureUpgradeHTTPServer(
                    at: serverAddress,
                    trustRoots: serverChain.chain,
                    applicationProtocol: HTTPVersion.http2.alpnIdentifier
                )
            guard case .http2(let streamManager) = clientChannel else {
                Issue.record("Expected HTTP/2 channel, got \(clientChannel).")
                return
            }

            try await withThrowingTaskGroup { group in
                for _ in 1...numStreams {
                    group.addTask {
                        let stream = try await streamManager.openStream()
                        try await stream.executeThenClose { inbound, outbound in
                            try await outbound.write(
                                .head(.init(method: .get, scheme: "https", authority: "", path: "/"))
                            )
                            try await outbound.write(.end(nil))
                            var iterator = inbound.makeAsyncIterator()
                            while let part = try await iterator.next() {
                                if case .end = part { break }
                            }
                        }
                    }
                }
                try await group.waitForAll()
            }
        }

        #expect(state.connectionInvocations.withLockedValue { $0 } == 1)
        // handleConnection returns after the multiplexer's inbound iteration ends,
        // which happens after the server task is cancelled at the end of `withServer`.
        for _ in 0..<50 {
            if state.observedFinalCounter.withLockedValue({ $0 }) != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(state.observedFinalCounter.withLockedValue { $0 } == numStreams)
    }

    /// A throwing connection handler is logged at debug level by the server but
    /// doesn't bring it down: a subsequent connection on the same server is
    /// served normally.
    @available(anyAppleOS 26.0, *)
    @Test("Throwing connection handler doesn't bring down the server", .timeLimit(.minutes(1)))
    func testThrowingConnectionHandlerDoesNotKillServer() async throws {
        let server = try NIOHTTPServerTests.makePlaintextHTTP1Server(logger: Self.serverLogger)
        let connectionInvocations = NIOLockedValueBox(0)

        let connectionHandler = ThrowingFirstConnectionHandler(
            connectionInvocations: connectionInvocations
        )

        try await Self.withServer(server: server, connectionHandler: connectionHandler) { serverAddress in
            // First connection: the handler throws after consuming the connection;
            // we expect the channel to close without a response.
            let firstClient = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .connectToTestHTTP1Server(at: serverAddress)
            try await firstClient.executeThenClose { inbound, _ in
                var iterator = inbound.makeAsyncIterator()
                let part = try await iterator.next()
                #expect(part == nil)
            }

            // Second connection: the handler runs the request loop normally.
            let secondClient = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .connectToTestHTTP1Server(at: serverAddress)
            try await secondClient.executeThenClose { inbound, outbound in
                try await outbound.write(.head(.init(method: .post, scheme: "http", authority: "", path: "/")))
                try await outbound.write(.body(ByteBuffer(string: "x")))
                try await outbound.write(.end(nil))
                var iterator = inbound.makeAsyncIterator()
                var sawOK = false
                while let part = try await iterator.next() {
                    if case .head(let response) = part {
                        #expect(response.status == .ok)
                        sawOK = true
                    }
                    if case .end = part { break }
                }
                #expect(sawOK, "Second connection should have been served normally.")
            }
        }

        #expect(connectionInvocations.withLockedValue { $0 } == 2)
    }

    /// A connection handler that returns without calling `handleRequests`
    /// effectively drops the connection: the channel closes immediately and
    /// the client sees EOF without any response.
    @available(anyAppleOS 26.0, *)
    @Test("Connection handler returning without handleRequests drops the connection", .timeLimit(.minutes(1)))
    func testConnectionHandlerEarlyReturn() async throws {
        let server = try NIOHTTPServerTests.makePlaintextHTTP1Server(logger: Self.serverLogger)
        let connectionInvocations = NIOLockedValueBox(0)

        let connectionHandler = NoOpConnectionHandler(connectionInvocations: connectionInvocations)

        try await Self.withServer(server: server, connectionHandler: connectionHandler) { serverAddress in
            let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .connectToTestHTTP1Server(at: serverAddress)
            try await client.executeThenClose { inbound, outbound in
                // The server side dropped the connection immediately; trying to
                // read either returns nil (clean EOF) or throws (peer reset).
                // Either is valid evidence that the connection was dropped.
                try? await outbound.write(.head(.init(method: .get, scheme: "http", authority: "", path: "/")))
                try? await outbound.write(.end(nil))
                var iterator = inbound.makeAsyncIterator()
                var receivedAnyResponsePart = false
                do {
                    while let part = try await iterator.next() {
                        if case .head = part { receivedAnyResponsePart = true }
                    }
                } catch {
                    // Connection-reset / read errors are also valid evidence that
                    // the connection was dropped.
                }
                #expect(!receivedAnyResponsePart, "Expected no response head from a dropped connection.")
            }
        }

        #expect(connectionInvocations.withLockedValue { $0 } == 1)
    }

    /// HTTP/2 counterpart: a connection handler that returns without calling
    /// `handleRequests` still causes the underlying connection channel to be
    /// closed by the dispatcher. Without the dispatcher's explicit close, the
    /// multiplexer's underlying `NIOAsyncChannel` would deinit with an
    /// unfinalized writer and trip the `NIOAsyncWriter` precondition — since
    /// nothing else on our side references the channel in the early-return
    /// path.
    @available(anyAppleOS 26.0, *)
    @Test("Connection handler returning without handleRequests drops the HTTP/2 connection", .timeLimit(.minutes(1)))
    func testConnectionHandlerEarlyReturnHTTP2() async throws {
        let (server, serverChain) = try NIOHTTPServerTests.makeSecureUpgradeServer(logger: Self.serverLogger)
        let elg: EventLoopGroup = .singletonMultiThreadedEventLoopGroup
        let connectionInvocations = NIOLockedValueBox(0)

        let connectionHandler = NoOpConnectionHandler(connectionInvocations: connectionInvocations)

        try await Self.withServer(server: server, connectionHandler: connectionHandler) { serverAddress in
            let clientChannel = try await ClientBootstrap(group: elg)
                .connectToTestSecureUpgradeHTTPServer(
                    at: serverAddress,
                    trustRoots: serverChain.chain,
                    applicationProtocol: HTTPVersion.http2.alpnIdentifier
                )
            guard case .http2(let streamManager) = clientChannel else {
                Issue.record("Expected HTTP/2 channel, got \(clientChannel).")
                return
            }

            // The server side drops the connection right after `handleConnection`
            // returns. Any stream we try to open should either fail outright, or
            // succeed transiently and then error/EOF once the server's close
            // reaches the client. Both outcomes are valid evidence that the
            // connection was closed.
            var sawResponseHead = false
            do {
                let stream = try await streamManager.openStream()
                try await stream.executeThenClose { inbound, outbound in
                    try? await outbound.write(.head(.init(method: .get, scheme: "https", authority: "", path: "/")))
                    try? await outbound.write(.end(nil))
                    var iterator = inbound.makeAsyncIterator()
                    while let part = try? await iterator.next() {
                        if case .head = part { sawResponseHead = true }
                    }
                }
            } catch {
                // Stream open / write / read may throw — all valid outcomes.
            }
            #expect(!sawResponseHead, "Expected no response head from a dropped connection.")
        }

        #expect(connectionInvocations.withLockedValue { $0 } == 1)
    }

    /// `ConnectionContext.httpVersion` reflects the protocol negotiated for the
    /// connection. Verified for plaintext HTTP/1.1, secure-upgrade-negotiated
    /// HTTP/1.1, and secure-upgrade-negotiated HTTP/2.
    @available(anyAppleOS 26.0, *)
    @Test("ConnectionContext.httpVersion for plaintext HTTP/1.1", .timeLimit(.minutes(1)))
    func testHTTPVersionPlaintextHTTP1_1() async throws {
        let server = try NIOHTTPServerTests.makePlaintextHTTP1Server(logger: Self.serverLogger)
        let observed = NIOLockedValueBox<NIOHTTPServer.HTTPVersion?>(nil)

        let connectionHandler = HTTPVersionRecordingConnectionHandler(
            observed: observed,
            wrappedHandler: Self.echoHandler()
        )

        try await Self.withServer(server: server, connectionHandler: connectionHandler) { serverAddress in
            let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .connectToTestHTTP1Server(at: serverAddress)
            try await client.executeThenClose { inbound, outbound in
                try await outbound.write(.head(.init(method: .post, scheme: "http", authority: "", path: "/")))
                try await outbound.write(.body(ByteBuffer(string: "x")))
                try await outbound.write(.end(nil))
                var iterator = inbound.makeAsyncIterator()
                while let part = try await iterator.next() {
                    if case .end = part { break }
                }
            }
        }

        #expect(observed.withLockedValue { $0 } == .plaintextHTTP1_1)
    }

    @available(anyAppleOS 26.0, *)
    @Test("ConnectionContext.httpVersion for secure-upgrade HTTP/1.1", .timeLimit(.minutes(1)))
    func testHTTPVersionSecureUpgradeHTTP1_1() async throws {
        let (server, serverChain) = try NIOHTTPServerTests.makeSecureUpgradeServer(logger: Self.serverLogger)
        let observed = NIOLockedValueBox<NIOHTTPServer.HTTPVersion?>(nil)

        let connectionHandler = HTTPVersionRecordingConnectionHandler(
            observed: observed,
            wrappedHandler: Self.echoHandler()
        )

        try await Self.withServer(server: server, connectionHandler: connectionHandler) { serverAddress in
            let clientChannel = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .connectToTestSecureUpgradeHTTPServer(
                    at: serverAddress,
                    trustRoots: serverChain.chain,
                    applicationProtocol: HTTPVersion.http1_1.alpnIdentifier
                )
            guard case .http1(let http1Channel) = clientChannel else {
                Issue.record("Expected HTTP/1.1 negotiation, got \(clientChannel).")
                return
            }
            try await http1Channel.executeThenClose { inbound, outbound in
                try await outbound.write(.head(.init(method: .post, scheme: "https", authority: "", path: "/")))
                try await outbound.write(.body(ByteBuffer(string: "x")))
                try await outbound.write(.end(nil))
                var iterator = inbound.makeAsyncIterator()
                while let part = try await iterator.next() {
                    if case .end = part { break }
                }
            }
        }

        #expect(observed.withLockedValue { $0 } == .http1_1)
    }

    @available(anyAppleOS 26.0, *)
    @Test("ConnectionContext.httpVersion for secure-upgrade HTTP/2", .timeLimit(.minutes(1)))
    func testHTTPVersionSecureUpgradeHTTP2() async throws {
        let (server, serverChain) = try NIOHTTPServerTests.makeSecureUpgradeServer(logger: Self.serverLogger)
        let observed = NIOLockedValueBox<NIOHTTPServer.HTTPVersion?>(nil)

        let connectionHandler = HTTPVersionRecordingConnectionHandler(
            observed: observed,
            wrappedHandler: Self.echoHandler()
        )

        try await Self.withServer(server: server, connectionHandler: connectionHandler) { serverAddress in
            let clientChannel = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .connectToTestSecureUpgradeHTTPServer(
                    at: serverAddress,
                    trustRoots: serverChain.chain,
                    applicationProtocol: HTTPVersion.http2.alpnIdentifier
                )
            guard case .http2(let streamManager) = clientChannel else {
                Issue.record("Expected HTTP/2 negotiation, got \(clientChannel).")
                return
            }
            let stream = try await streamManager.openStream()
            try await stream.executeThenClose { inbound, outbound in
                try await outbound.write(.head(.init(method: .post, scheme: "https", authority: "", path: "/")))
                try await outbound.write(.body(ByteBuffer(string: "x")))
                try await outbound.write(.end(nil))
                var iterator = inbound.makeAsyncIterator()
                while let part = try await iterator.next() {
                    if case .end = part { break }
                }
            }
        }

        #expect(observed.withLockedValue { $0 } == .http2)
    }

    /// Multiple HTTP/1.1 keep-alive connections in parallel each receive their
    /// own `handleConnection` invocation and connection-scoped state isn't
    /// shared between them — each connection's per-request counter only
    /// reflects its own requests.
    @available(anyAppleOS 26.0, *)
    @Test("State isolation across keep-alive HTTP/1.1 connections", .timeLimit(.minutes(1)))
    func testKeepAliveStateIsolationAcrossConnections() async throws {
        let server = try NIOHTTPServerTests.makePlaintextHTTP1Server(logger: Self.serverLogger)
        let perConnectionCounters = NIOLockedValueBox<[Int]>([])

        let connectionHandler = PerConnectionCounterHandler(
            perConnectionCounters: perConnectionCounters,
            wrappedHandler: Self.echoHandler()
        )

        try await Self.withServer(server: server, connectionHandler: connectionHandler) { serverAddress in
            await withThrowingTaskGroup(of: Void.self) { group in
                // Connection A makes 3 requests; connection B makes 1.
                for requestCount in [3, 1] {
                    group.addTask {
                        let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                            .connectToTestHTTP1Server(at: serverAddress)
                        try await client.executeThenClose { inbound, outbound in
                            for i in 0..<requestCount {
                                try await outbound.write(
                                    .head(.init(method: .post, scheme: "http", authority: "", path: "/\(i)"))
                                )
                                try await outbound.write(.body(ByteBuffer(string: "x")))
                                try await outbound.write(.end(nil))
                            }
                            var iterator = inbound.makeAsyncIterator()
                            for _ in 0..<requestCount {
                                while let part = try await iterator.next() {
                                    if case .end = part { break }
                                }
                            }
                        }
                    }
                }
                try? await group.waitForAll()
            }
        }

        let counters = perConnectionCounters.withLockedValue { $0 }.sorted()
        #expect(counters == [1, 3], "Each connection should see only its own request count.")
    }

    /// Smoke test for the closure-overload of
    /// ``NIOHTTPServer/Connection/handleRequests(handler:)-((@Sendable)``: a
    /// single request is served end-to-end without constructing an explicit
    /// ``HTTPServerClosureRequestHandler``.
    @available(anyAppleOS 26.0, *)
    @Test("connection.handleRequests closure overload", .timeLimit(.minutes(1)))
    func testHandleRequestsClosureOverload() async throws {
        let server = try NIOHTTPServerTests.makePlaintextHTTP1Server(logger: Self.serverLogger)

        try await Self.withServer(
            server: server,
            connectionHandler: ClosureRequestHandlerConnectionHandler()
        ) { serverAddress in
            let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .connectToTestHTTP1Server(at: serverAddress)
            try await client.executeThenClose { inbound, outbound in
                try await outbound.write(.head(.init(method: .post, scheme: "http", authority: "", path: "/")))
                try await outbound.write(.body(ByteBuffer(string: "x")))
                try await outbound.write(.end(nil))
                var iterator = inbound.makeAsyncIterator()
                var sawOK = false
                while let part = try await iterator.next() {
                    if case .head(let response) = part {
                        #expect(response.status == .ok)
                        sawOK = true
                    }
                    if case .end = part { break }
                }
                #expect(sawOK, "Closure-overloaded handleRequests should serve the request.")
            }
        }
    }
}

/// Connection handler that throws on the first invocation and runs normally
/// thereafter, so the test can verify a thrown error doesn't bring down the
/// server.
/// Connection handler that throws on its very first invocation and runs
/// normally thereafter — used to verify a thrown error doesn't bring down
/// the server.
@available(anyAppleOS 26.0, *)
struct ThrowingFirstConnectionHandler: NIOHTTPServerConnectionHandler {
    let connectionInvocations: NIOLockedValueBox<Int>

    func handleConnection(
        connection: consuming sending NIOHTTPServer.Connection,
        context: NIOHTTPServer.ConnectionContext
    ) async throws {
        let invocation = self.connectionInvocations.withLockedValue { value -> Int in
            value += 1
            return value
        }
        if invocation == 1 {
            throw TestError.intentional
        }
        await connection.handleRequests { request, _, reader, sender in
            try await NIOHTTPServerTests.echoResponse(readUpTo: 1024, reader: reader, sender: sender)
        }
    }
}

/// Connection handler that records the invocation count and returns without
/// calling `handleRequests`, dropping the connection.
@available(anyAppleOS 26.0, *)
struct NoOpConnectionHandler: NIOHTTPServerConnectionHandler {
    let connectionInvocations: NIOLockedValueBox<Int>

    func handleConnection(
        connection: consuming sending NIOHTTPServer.Connection,
        context: NIOHTTPServer.ConnectionContext
    ) async throws {
        self.connectionInvocations.withLockedValue { $0 += 1 }
        // Intentionally do not call `handleRequests` — the connection is
        // dropped and the channel is closed on scope exit.
    }
}

/// Connection handler that records the negotiated HTTP version on its first
/// invocation and forwards every request to a wrapped handler.
@available(anyAppleOS 26.0, *)
struct HTTPVersionRecordingConnectionHandler<Wrapped: HTTPServerRequestHandler>:
    NIOHTTPServerConnectionHandler
where
    Wrapped.RequestContext == NIOHTTPServer.RequestContext,
    Wrapped.Reader == NIOHTTPServer.Reader,
    Wrapped.ResponseSender == NIOHTTPServer.ResponseSender
{
    let observed: NIOLockedValueBox<NIOHTTPServer.HTTPVersion?>
    let wrappedHandler: Wrapped

    func handleConnection(
        connection: consuming sending NIOHTTPServer.Connection,
        context: NIOHTTPServer.ConnectionContext
    ) async throws {
        self.observed.withLockedValue { value in
            if value == nil { value = context.httpVersion }
        }
        await connection.handleRequests(handler: self.wrappedHandler)
    }
}

/// Connection handler that counts requests on its own connection and appends
/// the final count to a shared array when the connection ends.
@available(anyAppleOS 26.0, *)
struct PerConnectionCounterHandler<Wrapped: HTTPServerRequestHandler>: NIOHTTPServerConnectionHandler
where
    Wrapped.RequestContext == NIOHTTPServer.RequestContext,
    Wrapped.Reader == NIOHTTPServer.Reader,
    Wrapped.ResponseSender == NIOHTTPServer.ResponseSender
{
    let perConnectionCounters: NIOLockedValueBox<[Int]>
    let wrappedHandler: Wrapped

    func handleConnection(
        connection: consuming sending NIOHTTPServer.Connection,
        context: NIOHTTPServer.ConnectionContext
    ) async throws {
        let counter = NIOLockedValueBox(0)
        let countingHandler = ConnectionScopedRequestHandler(
            wrappedHandler: self.wrappedHandler,
            globalCounter: NIOLockedValueBox(0),
            localCounter: counter
        )
        await connection.handleRequests(handler: countingHandler)
        let finalCount = counter.withLockedValue { $0 }
        self.perConnectionCounters.withLockedValue { $0.append(finalCount) }
    }
}

/// Connection handler that uses the closure-overload of
/// ``NIOHTTPServer/Connection/handleRequests(handler:)-((@Sendable)``.
@available(anyAppleOS 26.0, *)
struct ClosureRequestHandlerConnectionHandler: NIOHTTPServerConnectionHandler {
    func handleConnection(
        connection: consuming sending NIOHTTPServer.Connection,
        context: NIOHTTPServer.ConnectionContext
    ) async throws {
        await connection.handleRequests { request, _, reader, sender in
            try await NIOHTTPServerTests.echoResponse(readUpTo: 1024, reader: reader, sender: sender)
        }
    }
}
