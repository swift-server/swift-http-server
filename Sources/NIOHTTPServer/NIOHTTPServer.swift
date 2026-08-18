//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@_exported public import HTTPAPIs
public import Logging
import NIOCertificateReloading
import NIOConcurrencyHelpers
import NIOCore
import NIOExtras
import NIOHPACK
import NIOHTTP1
import NIOHTTP2
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOHTTPTypesHTTP2
import NIOPosix
import NIOSSL
import ServiceLifecycle
import SwiftASN1
import Synchronization
import X509

/// A generic HTTP server that can handle incoming HTTP requests.
///
/// `NIOHTTPServer` provides a high-level interface for creating HTTP servers with support for:
/// - TLS/SSL encryption
/// - Custom request handlers
/// - Configurable binding targets
/// - Async/await request processing
/// - Bi-directional streaming support
/// - Request and response trailers
///
/// ## Usage
///
/// ```swift
/// let server = NIOHTTPServer(
///     configuration: try .init(
///         bindTarget: .hostAndPort(host: "localhost", port: 8080),
///         supportedHTTPVersions: [.http1_1],
///         transportSecurity: .plaintext
///     )
/// )
///
/// try await server.serve { request, requestContext, reader, responseSender in
///     var body = UniqueArray<UInt8>(copying: "Hello, World!".utf8)
///     try await responseSender.sendAndFinish(
///         HTTPResponse(status: .ok, headerFields: [.contentType: "text/plain"]),
///         buffer: &body
///     )
/// }
/// ```
///
/// A request handler reports failure by throwing, which aborts that request's exchange on the wire rather than
/// propagating an error to the caller. See ``serve(handler:)`` and ``HTTPServerHTTP2StreamResetErrorConvertible``.
@available(anyAppleOS 26.0, *)
public struct NIOHTTPServer: HTTPServer {
    let logger: Logger
    let configuration: NIOHTTPServerConfiguration

    /// The event loop group on which the server runs.
    ///
    /// This event loop group is used for every channel the server binds. It also provides the event loop that fulfills
    /// the listening address promise and the group from which a `ServerQuiescingHelper` is created for each bound
    /// channel.
    let eventLoopGroup: MultiThreadedEventLoopGroup

    var listeningAddressState: NIOLockedValueBox<State>

    /// Create a new ``HTTPServer`` implemented over `SwiftNIO`.
    /// - Parameters:
    ///   - logger: A logger instance for recording server events and debugging information.
    ///   - configuration: The server configuration including bind target and TLS settings.
    public init(
        logger: Logger = .current,
        configuration: NIOHTTPServerConfiguration,
    ) {
        self.logger = logger
        self.configuration = configuration

        // TODO: If we allow users to pass in an event loop, use that instead of the singleton MTELG.
        self.eventLoopGroup = .singletonMultiThreadedEventLoopGroup
        self.listeningAddressState = .init(.idle(self.eventLoopGroup.any().makePromise()))
    }

    /// Starts an HTTP server with the specified request handler.
    ///
    /// This method binds to all addresses specified in ``NIOHTTPServerConfiguration/bindTargets`` and begins
    /// accepting connections on each one. All bind targets share the same request handler, transport security
    /// configuration, and supported HTTP versions.
    ///
    /// ## All-or-nothing listening
    ///
    /// The server treats its set of listening addresses as a single unit. If an unrecoverable error occurs on any of
    /// the listening channels, the server stops listening on **all** remaining addresses and this method returns. After
    /// that point, ``listeningAddresses`` will throw `ListeningAddressError/serverClosed`.
    ///
    /// - Parameter handler: A ``HTTPServerRequestHandler`` implementation that processes incoming HTTP
    ///   requests. The handler receives each request along with a body reader and response sender function.
    ///
    /// ## Failing a request
    ///
    /// A handler reports a failure by throwing from its `handle(request:requestContext:reader:responseSender:)` method.
    /// The thrown error is never surfaced back to the caller of this method: it aborts the exchange that carries the request:
    ///
    /// - Over HTTP/1.1 there is no stream to reset, so the connection is closed. If the handler had not yet sent a
    ///   response head, the server sends `500 Internal Server Error` carrying `Connection: close` first; if a response
    ///   was already in flight it is abandoned, and the client observes a truncated response.
    /// - Over HTTP/2, the stream is reset with a `RST_STREAM` frame.
    /// - Over HTTP/3, the stream is reset with a QUIC `RESET_STREAM` frame, and a `STOP_SENDING` frame asks the client
    ///   to stop sending the request body.
    ///
    /// Conform the thrown error to ``HTTPServerHTTP2StreamResetErrorConvertible`` or ``HTTPServerHTTP3StreamResetErrorConvertible`` to
    /// choose the protocol error codes that are sent. An error that describes neither resets the stream with the
    /// internal error code of the protocol in use.
    ///
    /// Throwing after the response has been concluded aborts nothing: a complete response is never retracted, so the
    /// only consequence is that the connection is not reused.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let server = NIOHTTPServer(
    ///     logger: logger,
    ///     configuration: try .init(
    ///         bindTargets: [
    ///             .hostAndPort(host: "0.0.0.0", port: 8080),
    ///             .hostAndPort(host: "0.0.0.0", port: 8443),
    ///         ],
    ///         supportedHTTPVersions: [.http1_1],
    ///         transportSecurity: .plaintext
    ///     )
    /// )
    ///
    /// try await server.serve(handler: MyHandler())
    /// ```
    public func serve<Handler: HTTPServerRequestHandler>(handler: Handler) async throws
    where
        Handler.RequestContext == RequestContext,
        Handler.Reader == Reader,
        Handler.ResponseSender == ResponseSender
    {
        try await self.serve(
            connectionHandler: NIOHTTPServerDefaultConnectionHandler(handler: handler)
        )
    }

    /// Starts an HTTP server with the specified connection handler.
    ///
    /// This method is the connection-aware counterpart to ``serve(handler:)``. For
    /// every accepted TCP/TLS connection (after ALPN negotiation on the secure
    /// path), the server materialises a ``Connection`` and a ``ConnectionContext``
    /// and invokes ``NIOHTTPServerConnectionHandler/handleConnection(connection:context:)``.
    ///
    /// User code that only needs request-level processing should prefer
    /// ``serve(handler:)``. Use this entry point when the user code needs to run
    /// connection-scoped setup (per-connection logger, metric dimensions,
    /// counters), share state between requests on the same connection, or
    /// observe state after the connection's request loop returns.
    ///
    /// ## All-or-nothing listening
    ///
    /// The server treats its set of listening addresses as a single unit. If an
    /// unrecoverable error occurs on any of the listening channels, the server
    /// stops listening on **all** remaining addresses and this method returns.
    ///
    /// - Parameter connectionHandler: An ``NIOHTTPServerConnectionHandler``
    ///   implementation that drives the request loop on each accepted
    ///   connection.
    public func serve<Handler: NIOHTTPServerConnectionHandler>(
        connectionHandler: Handler
    ) async throws {
        // Ensure the listening address promise is always completed on the way out, regardless of whether
        // binding succeeded, the serve loop returned normally, or an error propagated.
        defer { self.finishListeningAddressPromise() }

        let serverChannels = try await self.makeServerChannels()

        return try await withTaskCancellationHandler {
            try await withGracefulShutdownHandler {
                try await self._serve(serverChannels: serverChannels, connectionHandler: connectionHandler)
            } onGracefulShutdown: {
                self.beginGracefulShutdown(serverChannels: serverChannels)
            }
        } onCancel: {
            // Forcefully close down the server channels
            self.close(serverChannels: serverChannels)
        }
    }

    /// Convenience overload accepting a closure instead of an
    /// ``NIOHTTPServerConnectionHandler`` conformance.
    ///
    /// ```swift
    /// try await server.serve { connection, context in
    ///     var connectionLogger = rootLogger
    ///     connectionLogger[metadataKey: "peer"] =
    ///         .string(context.remoteAddress?.host ?? "unknown")
    ///     connectionLogger.info("connection accepted")
    ///     defer { connectionLogger.info("connection closed") }
    ///
    ///     try await connection.handleRequests(handler: MyHandler(logger: connectionLogger))
    /// }
    /// ```
    public func serve(
        connectionHandler:
            @Sendable @escaping (
                _ connection: consuming sending Connection,
                _ context: ConnectionContext
            ) async throws -> Void
    ) async throws {
        try await self.serve(
            connectionHandler: NIOHTTPServerClosureConnectionHandler(body: connectionHandler)
        )
    }

    /// Creates and returns server channels based on the configured transport security.
    func makeServerChannels() async throws -> [ServerChannel] {
        var serverChannels = [ServerChannel]()
        var secureUpgradeBindTargets = self.configuration.bindTargets

        #if HTTP3
        if let http3Configuration = self.configuration.supportedHTTPVersions.http3ConfigIfSupported,
            let authenticationConfiguration = self.configuration.quicAuthenticationConfiguration
        {
            let http3Channels = try await self.setupHTTP3ServerChannels(
                bindTargets: self.configuration.bindTargets,
                http3Configuration: http3Configuration,
                authenticationConfiguration: authenticationConfiguration,
                authenticator: self.configuration.quicAuthenticator
            )
            serverChannels.append(
                contentsOf: http3Channels.map { (quicChannel, mux) in
                    .http3(quicChannel: quicChannel, connectionMultiplexer: mux)
                }
            )

            if self.configuration.sslContext == nil {
                // `supportedHTTPVersions == [.http3]` here. We therefore just return HTTP/3 channel(s).
                try self.addressesBound(http3Channels.map { (channel, _) in channel.localAddress })
                return serverChannels
            }

            // We also need to set up secure upgrade channel(s) on the same port.
            secureUpgradeBindTargets = try http3Channels.map { (http3Channel, _) in
                try NIOHTTPServerConfiguration.BindTarget(http3Channel.localAddress)
            }
        }
        #endif  // HTTP3

        guard let sslContext = self.configuration.sslContext else {
            // Set up plaintext HTTP/1.1 channel(s).
            let http1Channels = try await self.setupHTTP1_1ServerChannels(bindTargets: secureUpgradeBindTargets)
            try self.addressesBound(http1Channels.map { (channel, _) in channel.channel.localAddress })
            return http1Channels.map { .plaintextHTTP1_1(channel: $0, quiescingHelper: $1) }
        }

        let secureUpgradeChannels = try await self.setupSecureUpgradeServerChannels(
            bindTargets: secureUpgradeBindTargets,
            http2Configuration: self.configuration.supportedHTTPVersions.http2ConfigIfSupported,
            sslContext: sslContext
        )
        try self.addressesBound(secureUpgradeChannels.map { (channel, _) in channel.channel.localAddress })

        serverChannels.append(
            contentsOf: secureUpgradeChannels.map { (channel, quiescingHelper) in
                .secureUpgrade(channel: channel, quiescingHelper: quiescingHelper)
            }
        )

        return serverChannels
    }

    private func _serve<Handler: NIOHTTPServerConnectionHandler>(
        serverChannels: [ServerChannel],
        connectionHandler: Handler
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for serverChannel in serverChannels {
                group.addTask {
                    switch serverChannel {
                    case .plaintextHTTP1_1(let http1Channel, _):
                        try await self.serveInsecureHTTP1_1(
                            serverChannel: http1Channel,
                            connectionHandler: connectionHandler
                        )

                    case .secureUpgrade(let secureUpgradeChannel, _):
                        try await self.serveSecureUpgrade(
                            serverChannel: secureUpgradeChannel,
                            connectionHandler: connectionHandler
                        )

                    #if HTTP3
                    case .http3(_, let connectionMultiplexer):
                        await self.serveHTTP3(
                            connectionMultiplexer: connectionMultiplexer,
                            connectionHandler: connectionHandler
                        )
                    #endif
                    }
                }
            }

            // If an error occurs in any channel, bring down all other channels too and propagate the error.
            do {
                for try await _ in group {}
            } catch {
                // Propagate the error. This will cancel the entire group.
                throw error
            }
        }
    }

    /// Reads the next request head from the iterator. Returns `nil` if the connection is done or
    /// an unexpected part is received.
    ///
    /// Skips over leftover `.body` and `.end` parts from a previous request that the
    /// handler didn't fully consume. The ``HTTPKeepAliveHandler`` separately ensures that connections are closed (with
    /// `Connection: close`) when the server responds before the request `.end` arrives, preventing unbounded leftover state.
    func nextRequestHead(
        from iterator: inout NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator
    ) async throws -> HTTPRequest? {
        while true {
            switch try await iterator.next(isolation: #isolation) {
            case .head(let request):
                return request
            case .body, .end:
                // Leftover parts from a previous request. Skip and look for the next head.
                continue
            case .none:
                self.logger.trace("No more request parts on connection")
                return nil
            }
        }
    }

    /// Shared core: invokes the request handler with the appropriate reader/writer state.
    /// Returns the recovered iterator if the request was fully consumed (for HTTP/1.1 reuse),
    /// or `nil` if the request could not be fully consumed.
    func invokeHandler<Handler: HTTPServerRequestHandler>(
        request: HTTPRequest,
        iterator: consuming sending NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator,
        outbound: NIOAsyncChannelOutboundWriter<HTTPResponsePart>,
        requestContext: RequestContext,
        handler: Handler
    ) async -> NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator?
    where
        Handler.RequestContext == RequestContext,
        Handler.Reader == Reader,
        Handler.ResponseSender == ResponseSender
    {
        let readerState = Reader.ReaderState(iterator: iterator)
        let writerState = ResponseSender.WriterState()

        #if HTTP3 && UnstableHTTPDatagrams
        // TODO: `swift-nio-http3` currently does not provide APIs for reading/writing bytes on the unreliable datagram
        // stream. This is why we currently pass `nil` to the `datagramReader` and `datagramWriter` arguments.
        let requestReader = Reader(readerState: readerState, datagramReader: nil)
        let responseSender = ResponseSender(writer: outbound, writerState: writerState, datagramWriter: nil)
        #else
        let requestReader = Reader(readerState: readerState)
        let responseSender = ResponseSender(writer: outbound, writerState: writerState)
        #endif

        do {
            try await handler.handle(
                request: request,
                requestContext: requestContext,
                reader: requestReader,
                responseSender: responseSender
            )
        } catch {
            // A throwing handler signals that the exchange failed. The error is deliberately not propagated to any
            // caller: it exists to drive the wire, aborting the exchange with protocol error codes the error can
            // choose by conforming to `HTTPServerHTTP2StreamResetErrorConvertible` /
            // `HTTPServerHTTP3StreamResetErrorConvertible`.
            self.logger.debug(
                "Error thrown while handling request: aborting.",
                error: error,
                metadata: [LoggingKeys.protocol: "\(requestContext.connectionContext.httpVersion)"]
            )

            // Only abort a response that is still in flight. A response the handler already concluded has nothing left
            // to abort, and resetting the stream afterwards can make the peer discard a response it has already
            // received in full: RFC 9000 § 3.1 permits `RESET_STREAM` from the "Data Sent" state, so over HTTP/3 the
            // reset does reach the client rather than being dropped as it is over HTTP/2.
            if !writerState.wrapped.withLock({ $0.finishedWriting }) {
                Self.abortRequest(requestContext: requestContext, error: error)
            }

            // The handler failed, so this connection cannot carry another request.
            return nil
        }

        // If the handler didn't properly conclude the response, the HTTP codec
        // is in an inconsistent state and the connection cannot be reused.
        if !writerState.wrapped.withLock({ $0.finishedWriting }) {
            self.logger.debug("Handler did not conclude the response. Closing connection.")
            return nil
        }

        // Recover the iterator for potential connection reuse. If the handler started
        // reading the request body but didn't finish, the iterator was consumed by the
        // reader and not returned, so we can't reuse the connection.
        return readerState.takeIterator()
    }

    /// Fail the listening address promise if the server is shutting down before it began listening.
    private func finishListeningAddressPromise() {
        switch self.listeningAddressState.withLockedValue({ $0.close() }) {
        case .failPromise(let promise, let error):
            promise.fail(error)

        case .doNothing:
            ()
        }
    }

    /// Initiates a graceful shutdown, allowing existing connections to drain before closing. How graceful shutdown is
    /// signalled depends on the protocol:
    ///
    /// For HTTP/1.1 and HTTP/2, `ServerQuiescingHelper` is added to the server channel pipeline. For each accepted
    /// connection, `ServerQuiescingHelper` stores the associated connection child channel. When `initiateShutdown` is
    /// called, `ServerQuiescingHelper` closes the server's socket to stop accepting any new connections, then fires
    /// `ChannelShouldQuiesceEvent` on each stored child channel.
    ///
    /// For HTTP/3, `ServerQuiescingHelper` cannot be used as QUIC connections are multiplexed internally by
    /// `QUICHandler`. We instead fire `ChannelShouldQuiesceEvent` directly on the QUIC channel. `QUICHandler` reacts to
    /// it by propagating the event to each QUIC connection channel. This eventually reaches `HTTP3ConnectionHandler`,
    /// which performs the two-phase GOAWAY shutdown sequence.
    private func beginGracefulShutdown(serverChannels: [ServerChannel]) {
        self.finishListeningAddressPromise()

        for serverChannel in serverChannels {
            switch serverChannel {
            case .plaintextHTTP1_1(_, let quiescingHelper), .secureUpgrade(_, let quiescingHelper):
                quiescingHelper.initiateShutdown(promise: nil)

            #if HTTP3
            case .http3(let quicChannel, _):
                // Fire ChannelShouldQuiesceEvent directly on the QUIC channel.
                quicChannel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
            #endif
            }
        }
    }

    /// Forcefully closes the server channels without waiting for existing connections to drain.
    func close(serverChannels: [ServerChannel]) {
        self.finishListeningAddressPromise()

        for serverChannel in serverChannels {
            switch serverChannel {
            case .plaintextHTTP1_1(let http1Channel, _):
                http1Channel.channel.close(promise: nil)

            case .secureUpgrade(let secureUpgradeChannel, _):
                secureUpgradeChannel.channel.close(promise: nil)

            #if HTTP3
            case .http3(let quicChannel, _):
                quicChannel.close(promise: nil)
            #endif
            }
        }
    }
}

@available(anyAppleOS 26.0, *)
extension ChannelPipeline.SynchronousOperations {
    /// Adds timeout handlers (idle, read header, read body) to the channel pipeline.
    ///
    /// Only handlers for non-nil timeouts are installed.
    ///
    /// - Parameters:
    ///   - timeouts: The configured connection timeouts. Only handlers for non-nil timeouts are installed.
    ///   - expectMultipleRequests: Whether the channel can receive more than one request. Pass `true` for an HTTP/1.1
    ///     connection channel (for keep-alive), and `false` for an HTTP/2 or HTTP/3 stream channel.
    func addTimeoutHandlers(
        _ timeouts: NIOHTTPServerConfiguration.ConnectionTimeouts,
        expectMultipleRequests: Bool
    ) throws {
        try self.addIdleTimeoutHandlers(timeouts)
        try self.addReadTimeoutHandlers(timeouts, expectMultipleRequests: expectMultipleRequests)
    }

    /// Adds the connection idle timeout handler to the channel. Used by HTTP/1.1 connection channels. HTTP/2 delegates
    /// idle handling to `NIOHTTP2ServerConnectionManagementHandler`'s `maxIdleTime`. Idle timeout is not currently
    /// supported over HTTP/3.
    func addIdleTimeoutHandlers(_ timeouts: NIOHTTPServerConfiguration.ConnectionTimeouts) throws {
        if let idle = timeouts.idle {
            try self.addHandler(
                ConnectionIdleTimeoutHandler(timeout: TimeAmount(idle))
            )
        }
    }

    /// Adds header and body read timeout handlers to the channel.
    ///
    /// - Parameters:
    ///   - timeouts: The configured connection timeouts. No handler is installed if both read timeouts are `nil`.
    ///   - expectMultipleRequests: Whether the channel can receive more than one request. Pass `true` for an HTTP/1.1
    ///     connection channel (for keep-alive), and `false` for an HTTP/2 or HTTP/3 stream channel.
    func addReadTimeoutHandlers(
        _ timeouts: NIOHTTPServerConfiguration.ConnectionTimeouts,
        expectMultipleRequests: Bool
    ) throws {
        let readHeader = timeouts.readHeader.map { TimeAmount($0) }
        let readBody = timeouts.readBody.map { TimeAmount($0) }
        if readHeader != nil || readBody != nil {
            try self.addHandler(
                RequestTimeoutHandler(
                    readHeaderTimeout: readHeader,
                    readBodyTimeout: readBody,
                    expectMultipleRequests: expectMultipleRequests
                )
            )
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTP2Handler.Configuration {
    init(httpServerHTTP2Configuration http2Config: NIOHTTPServerConfiguration.HTTP2) {
        let clampedTargetWindowSize = Self.clampTargetWindowSize(http2Config.targetWindowSize)
        let clampedMaxFrameSize = Self.clampMaxFrameSize(http2Config.maxFrameSize)

        var http2HandlerConnectionConfiguration = NIOHTTP2Handler.ConnectionConfiguration()
        let http2HandlerHTTP2Settings = HTTP2Settings([
            HTTP2Setting(parameter: .initialWindowSize, value: clampedTargetWindowSize),
            HTTP2Setting(parameter: .maxFrameSize, value: clampedMaxFrameSize),
            HTTP2Setting(parameter: .maxConcurrentStreams, value: http2Config.maxConcurrentStreams),
            HTTP2Setting(parameter: .maxHeaderListSize, value: HPACKDecoder.defaultMaxHeaderListSize),
        ])

        http2HandlerConnectionConfiguration.initialSettings = http2HandlerHTTP2Settings

        var http2HandlerStreamConfiguration = NIOHTTP2Handler.StreamConfiguration()
        http2HandlerStreamConfiguration.targetWindowSize = clampedTargetWindowSize

        self = NIOHTTP2Handler.Configuration(
            connection: http2HandlerConnectionConfiguration,
            stream: http2HandlerStreamConfiguration
        )
    }

    /// Window size which mustn't exceed `2^31 - 1` (RFC 9113 § 6.5.2).
    private static func clampTargetWindowSize(_ targetWindowSize: Int) -> Int {
        min(targetWindowSize, Int(Int32.max))
    }

    /// Max frame size must be in the range `2^14 ..< 2^24` (RFC 9113 § 4.2).
    private static func clampMaxFrameSize(_ maxFrameSize: Int) -> Int {
        let clampedMaxFrameSize: Int
        if maxFrameSize >= (1 << 24) {
            clampedMaxFrameSize = (1 << 24) - 1
        } else if maxFrameSize < (1 << 14) {
            clampedMaxFrameSize = (1 << 14)
        } else {
            clampedMaxFrameSize = maxFrameSize
        }
        return clampedMaxFrameSize
    }
}
