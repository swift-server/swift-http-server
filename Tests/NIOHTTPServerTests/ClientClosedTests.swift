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
import NIOHTTP1
import NIOHTTPTypes
import NIOPosix
import Testing

@testable import NIOHTTPServer

#if HTTP3
import NIOQUICHelpers
#endif

/// Tests for what the server observes and does when the client stops waiting for a response while its
/// handler is still working.
@Suite
struct ClientClosedTests {
    static let logger = Logger(label: "ClientClosedTests")

    /// How long a handler polls for cancellation.
    static let observationWindow = Duration.seconds(1)
    
    static let tlsShutdownWindow = Duration.seconds(8)

    /// How long we wait for the server pipeline to observe a client close before concluding it
    /// never will.
    static let detectionWindow = TimeAmount.seconds(2)

    @available(anyAppleOS 26.0, *)
    @Test(
        "Client disconnect cancels a busy handler",
        arguments: NIOHTTPServer.HTTPVersion.allCases
    )
    func clientDisconnectCancelsBusyHandler(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: Self.logger,
            serverLogger: Self.logger
        )

        // What this protocol can be expected to do here, and how long it needs to do it in.
        let expectCancellation: Bool
        let observationWindow: Duration
        switch httpVersion {
        case .plaintextHTTP1_1, .http1_1:
            #if canImport(Darwin)
            // The one case the server cannot see; see this test's note.
            expectCancellation = false
            observationWindow = Self.observationWindow
            #else
            expectCancellation = true
            observationWindow =
                httpVersion == .http1_1 ? Self.tlsShutdownWindow : Self.observationWindow
            #endif

        default:
            expectCancellation = true
            observationWindow = Self.observationWindow
        }

        let eventLoop = MultiThreadedEventLoopGroup.singleton.any()
        // Signals that the handler has begun its long-running work, so the client knows when to go.
        let handlerStarted = OnceSignal<Void>(on: eventLoop)
        // Carries whether the handler ever observed `Task.isCancelled` during its window.
        let handlerVerdict = OnceSignal<Bool>(on: eventLoop)

        try await TestHelpers.withClientServerConnection(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, _, _ in
                handlerStarted.fire(())

                // Stand in for a long upstream call, polling for cancellation throughout.
                var sawCancellation = false
                let deadline = ContinuousClock.now + observationWindow
                while ContinuousClock.now < deadline {
                    if Task.isCancelled {
                        sawCancellation = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                }

                handlerVerdict.fire(sawCancellation)
                // Deliberately no response: the client is already gone.
            }
        ) { _, connection in
            let requestChannel = try await connection.makeRequestChannel(expectedHTTPVersion: httpVersion)

            // Teardown races are expected here — we are deliberately killing the connection from
            // under the request stream — so tolerate errors from the stream's own close.
            try? await requestChannel.executeThenClose { _, outbound in
                // Send a *complete* request so the handler is not blocked reading a body.
                try await outbound.write(.testHead(method: .get, for: httpVersion))
                try await outbound.write(.end(nil))

                try await handlerStarted.future.get()

                // The client goes away, with the request still in flight.
                #if HTTP3
                if httpVersion == .http3 {
                    try await connection.closeAnnouncingDeparture()
                } else {
                    try await connection.close()
                }
                #else
                try await connection.close()
                #endif
            }

            let sawCancellation = try await handlerVerdict.future.get()

            #expect(
                sawCancellation == expectCancellation,
                """
                Expected the handler \(expectCancellation ? "to be" : "not to be") cancelled when the \
                client went away (\(httpVersion)), but it was \(sawCancellation ? "" : "not ")cancelled.
                """
            )
        }
    }

    /// HTTP/2: a client cancelling a single stream must cancel that request's handler, while leaving
    /// the connection and any other requests on it alive.
    @available(anyAppleOS 26.0, *)
    @Test("HTTP/2 stream reset by the client cancels that request's handler")
    func http2StreamResetCancelsBusyHandler() async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: .http2,
            clientLogger: Self.logger,
            serverLogger: Self.logger
        )

        let eventLoop = MultiThreadedEventLoopGroup.singleton.any()
        let handlerStarted = OnceSignal<Void>(on: eventLoop)
        let handlerVerdict = OnceSignal<Bool>(on: eventLoop)

        try await TestHelpers.withClientServerConnection(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, _, _ in
                handlerStarted.fire(())
                handlerVerdict.fire(await Self.awaitCancellation())
            }
        ) { _, connection in
            let requestChannel = try await connection.makeRequestChannel(expectedHTTPVersion: .http2)

            try? await requestChannel.executeThenClose { _, outbound in
                try await outbound.write(.testHead(method: .get, for: .http2))
                try await outbound.write(.end(nil))

                try await handlerStarted.future.get()

                // Abandon just this stream. The server has not responded, so the stream is still
                // open and NIO sends a RST_STREAM rather than treating this as a no-op.
                try await requestChannel.channel.close()
            }

            #expect(
                try await handlerVerdict.future.get(),
                "An HTTP/2 RST_STREAM from the client should have cancelled the handler."
            )
        }
    }

    #if HTTP3
    @available(anyAppleOS 26.0, *)
    @Test("HTTP/3 STOP_SENDING alone does not cancel the handler")
    func http3StopSendingAloneDoesNotCancel() async throws {
        let sawCancellation = try await Self.runHTTP3Handler(clientSends: [.stopSending], completeRequest: false)
        #expect(
            sawCancellation == false,
            "STOP_SENDING is non-terminal and repeatable, so on its own it must not cancel the handler."
        )
    }

    /// `STOP_SENDING` *after* the request end does cancel: with the client's FIN already received, the
    /// exchange is finished in both directions, so the QUIC layer closes the stream — the `hasReceivedFin`
    /// branch of `QUICChannelStreamHandler.receiveStopSending`, the one case where opting into half-closure
    /// still closes.
    @available(anyAppleOS 26.0, *)
    @Test("HTTP/3 STOP_SENDING after the request end cancels the handler")
    func http3StopSendingAfterRequestEndCancels() async throws {
        let sawCancellation = try await Self.runHTTP3Handler(clientSends: [.stopSending], completeRequest: true)
        #expect(
            sawCancellation,
            """
            With the request already complete, STOP_SENDING leaves nothing open in either direction, so \
            the stream closes and the handler must be cancelled.
            """
        )
    }

    @available(anyAppleOS 26.0, *)
    @Test("HTTP/3 RESET_STREAM alone does not cancel the handler")
    func http3ResetStreamAloneDoesNotCancel() async throws {
        let sawCancellation = try await Self.runHTTP3Handler(clientSends: [.resetStream], completeRequest: false)
        #expect(
            sawCancellation == false,
            "RESET_STREAM only abandons the client's send direction, so on its own it must not cancel."
        )
    }

    @available(anyAppleOS 26.0, *)
    @Test("HTTP/3 RESET_STREAM followed by STOP_SENDING cancels the handler")
    func http3BothFramesCancel() async throws {
        let sawCancellation = try await Self.runHTTP3Handler(
            clientSends: [.resetStream, .stopSending],
            completeRequest: false
        )
        #expect(
            sawCancellation,
            """
            Having received both RESET_STREAM and STOP_SENDING, the client has abandoned the exchange \
            in both directions and the handler should have been cancelled.
            """
        )
    }

    /// A client-side cancel frame, sent as an outbound user event on the client's QUIC stream channel.
    enum H3CancelFrame: Sendable, CustomStringConvertible {
        case stopSending
        case resetStream

        var description: String {
            switch self {
            case .stopSending: "STOP_SENDING"
            case .resetStream: "RESET_STREAM"
            }
        }
    }

    /// Runs an HTTP/3 request whose handler is busy, has the client send `clientSends` mid-flight, and
    /// reports whether the handler observed cancellation.
    ///
    /// - Parameter completeRequest: whether the client finishes its request body. This matters: once the
    ///   request is fully received QUIC may ignore a `RESET_STREAM` (RFC 9000 § 3.2), so leaving it
    ///   incomplete is the only way the server can observe that frame.
    @available(anyAppleOS 26.0, *)
    private static func runHTTP3Handler(
        clientSends frames: [H3CancelFrame],
        completeRequest: Bool
    ) async throws -> Bool {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: .http3,
            clientLogger: Self.logger,
            serverLogger: Self.logger
        )

        let eventLoop = MultiThreadedEventLoopGroup.singleton.any()
        let handlerStarted = OnceSignal<Void>(on: eventLoop)
        let handlerVerdict = OnceSignal<Bool>(on: eventLoop)

        // H3_REQUEST_CANCELLED (RFC 9114 § 8.1).
        let requestCancelled = try #require(QUICApplicationErrorCode(0x010c))

        // Read the verdict while the server is still running: `withClientServerConnection` cancels the
        // server task when its body returns, and that cancellation would reach the handler and be
        // indistinguishable from a client-driven one.
        let verdict = NIOLockedValueBox(false)

        try await TestHelpers.withClientServerConnection(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, _, _ in
                handlerStarted.fire(())
                handlerVerdict.fire(await Self.awaitCancellation())
            }
        ) { _, connection in
            let requestChannel = try await connection.makeRequestChannel(expectedHTTPVersion: .http3)

            try? await requestChannel.executeThenClose { _, outbound in
                try await outbound.write(.testHead(method: .get, for: .http3))
                if completeRequest {
                    try await outbound.write(.end(nil))
                }

                try await handlerStarted.future.get()

                let streamChannel = requestChannel.channel
                for frame in frames {
                    switch frame {
                    case .stopSending:
                        try await Self.send(QUICStopSendingEvent(code: requestCancelled), on: streamChannel)
                    case .resetStream:
                        try await Self.send(QUICResetStreamEvent(code: requestCancelled), on: streamChannel)
                    }
                }

                // Read the verdict before this closure returns. Closing the client's stream channel can
                // itself emit further QUIC frames — notably a STOP_SENDING for a response it never
                // finished reading — which would contaminate the observation.
                let sawCancellation = try await handlerVerdict.future.get()
                verdict.withLockedValue { $0 = sawCancellation }
            }
        }

        return verdict.withLockedValue { $0 }
    }

    private static func send<Event: Sendable>(_ event: Event, on channel: any Channel) async throws {
        try await channel.eventLoop.submit {
            channel.pipeline.syncOperations.triggerUserOutboundEvent(event, promise: nil)
        }.get()
    }
    #endif

    /// Waits for the current task to be cancelled, up to ``observationWindow``.
    ///
    /// - Returns: `true` if cancellation was observed, `false` if the window elapsed first.
    private static func awaitCancellation() async -> Bool {
        let deadline = ContinuousClock.now + Self.observationWindow
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Cancellation is not scoped to the client going away: a close the *server* decided on cancels the
    /// handler too. For example, a timeout closing the connection has already concluded that nobody is getting a
    /// response.
    @available(anyAppleOS 26.0, *)
    @Test("A timeout closing the connection cancels the handler")
    func serverInitiatedCloseCancelsBusyHandler() async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: .plaintextHTTP1_1,
            clientLogger: Self.logger,
            serverLogger: Self.logger,
            serverConfigurationOverride: { configuration in
                configuration.connectionTimeouts = .init(idle: nil, readHeader: nil, readBody: .milliseconds(100))
            }
        )

        let eventLoop = MultiThreadedEventLoopGroup.singleton.any()
        let handlerVerdict = OnceSignal<Bool>(on: eventLoop)

        try await TestHelpers.withClientServerConnection(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, _, _ in
                // Busy without reading, so the request body timeout is free to fire underneath.
                handlerVerdict.fire(await Self.awaitCancellation())
            }
        ) { _, connection in
            let requestChannel = try await connection.makeRequestChannel(expectedHTTPVersion: .plaintextHTTP1_1)

            // The server closes this connection from under us, so its own teardown may error.
            try? await requestChannel.executeThenClose { _, outbound in
                // A head with no body and no end: the request body the server is waiting for never comes.
                try await outbound.write(.testHead(method: .post, for: .plaintextHTTP1_1))

                #expect(
                    try await handlerVerdict.future.get(),
                    "The request body timeout closing the connection should have cancelled the handler."
                )
            }
        }
    }
}

/// A promise that can be completed at most once, from any thread.
///
/// `EventLoopPromise` traps on double completion, and these tests race several producers (a
/// pipeline event, a timeout, a handler) to report first.
private final class OnceSignal<Value: Sendable>: Sendable {
    private let promise: EventLoopPromise<Value>
    private let hasFired = NIOLockedValueBox(false)

    init(on eventLoop: any EventLoop) {
        self.promise = eventLoop.makePromise(of: Value.self)
    }

    var future: EventLoopFuture<Value> {
        self.promise.futureResult
    }

    deinit {
        // NIO traps on a promise that is never completed. A signal can legitimately go unfired if the
        // scenario it describes did not happen, so fail it rather than crash the run.
        if !self.hasFired.withLockedValue({ $0 }) {
            self.promise.fail(NeverFired())
        }
    }

    struct NeverFired: Error {}

    /// Completes the signal if it has not already been completed. Later calls are ignored.
    func fire(_ value: Value) {
        let shouldFire = self.hasFired.withLockedValue { hasFired in
            if hasFired { return false }
            hasFired = true
            return true
        }

        if shouldFire {
            self.promise.succeed(value)
        }
    }
}
