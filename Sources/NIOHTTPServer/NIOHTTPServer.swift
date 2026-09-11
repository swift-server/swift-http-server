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

#if HTTP3
import NIOQUIC
@_spi(HTTP3AsyncInterface) import NIOHTTP3
#endif

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
    public func serve<Handler: NIOHTTPServerConnectionHandler>(connectionHandler: Handler) async throws {
        // Ensure the listening address promise is always completed on the way out, regardless of whether
        // binding succeeded, the serve loop returned normally, or an error propagated.
        defer { self.finishListeningAddressPromise() }

        try await withThrowingDiscardingTaskGroup { group in
            let listenerConfiguration = self.configuration.makeListenerConfiguration()

            let (addressStream, addressContinuation) = AsyncThrowingStream.makeStream(of: NIOCore.SocketAddress.self)
            var addressStreamIterator = addressStream.makeAsyncIterator()

            var boundAddresses = [NIOCore.SocketAddress]()

            for bindTarget in self.configuration.bindTargets {
                let resolvedAddress: NIOCore.SocketAddress

                switch listenerConfiguration {
                case .plaintextHTTP1_1:
                    self.addPlaintextHTTP1_1Listener(
                        to: &group,
                        address: try NIOCore.SocketAddress(bindTarget: bindTarget),
                        addressContinuation: addressContinuation,
                        connectionHandler: connectionHandler
                    )

                    resolvedAddress = try await self.nextBoundAddress(from: &addressStreamIterator)

                case .secureUpgrade(let configuration):
                    self.addSecureUpgradeListener(
                        to: &group,
                        address: try NIOCore.SocketAddress(bindTarget: bindTarget),
                        configuration: configuration,
                        addressContinuation: addressContinuation,
                        connectionHandler: connectionHandler
                    )

                    resolvedAddress = try await self.nextBoundAddress(from: &addressStreamIterator)

                #if HTTP3
                case .http3(let configuration):
                    self.addHTTP3Listener(
                        to: &group,
                        address: try NIOCore.SocketAddress(bindTarget: bindTarget),
                        eventLoop: self.eventLoopGroup.next(),
                        configuration: configuration,
                        addressContinuation: addressContinuation,
                        connectionHandler: connectionHandler
                    )

                    resolvedAddress = try await self.nextBoundAddress(from: &addressStreamIterator)

                case .secureUpgradeAndHTTP3(let secureUpgradeConfiguration, let http3Configuration):
                    self.addSecureUpgradeListener(
                        to: &group,
                        address: try NIOCore.SocketAddress(bindTarget: bindTarget),
                        configuration: secureUpgradeConfiguration,
                        addressContinuation: addressContinuation,
                        connectionHandler: connectionHandler
                    )

                    // Wait for the address the TCP channel bound to, and use the same address to bind the UDP channel.
                    resolvedAddress = try await self.nextBoundAddress(from: &addressStreamIterator)

                    self.addHTTP3Listener(
                        to: &group,
                        address: resolvedAddress,
                        eventLoop: self.eventLoopGroup.next(),
                        configuration: http3Configuration,
                        addressContinuation: addressContinuation,
                        connectionHandler: connectionHandler
                    )

                    _ = try await self.nextBoundAddress(from: &addressStreamIterator)
                #endif  // HTTP3
                }

                boundAddresses.append(resolvedAddress)
            }

            self.addressesBound(boundAddresses)
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

    /// Shared core: invokes the request handler with the appropriate reader/writer state.
    /// Returns the recovered iterator if the request was fully consumed (for HTTP/1.1 reuse),
    /// or `nil` if the request could not be fully consumed.
    private func invokeHandler<Handler: HTTPServerRequestHandler>(
        request: HTTPRequest,
        requestContext: RequestContext,
        requestReader: consuming sending Reader,
        responseSender: consuming sending ResponseSender,
        handler: Handler
    ) async -> NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator?
    where
        Handler.RequestContext == RequestContext,
        Handler.Reader == Reader,
        Handler.ResponseSender == ResponseSender
    {
        let readerState = requestReader.state
        let writerState = responseSender.writerState

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

    #if HTTP3 && UnstableHTTPDatagrams
    func invokeDatagramsEnabledHandler<Handler: HTTPServerRequestHandler>(
        request: HTTPRequest,
        requestContext: RequestContext,
        inboundIterator: consuming sending NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator,
        outbound: NIOAsyncChannelOutboundWriter<HTTPResponsePart>,
        datagramStreamFuture: EventLoopFuture<HTTP3UnreliableDatagramStream>,
        handler: Handler
    ) async
    where
        Handler.RequestContext == RequestContext,
        Handler.Reader == Reader,
        Handler.ResponseSender == ResponseSender
    {
        let readerState = Reader.ReaderState(iterator: inboundIterator)
        let writerState = ResponseSender.WriterState()

        let requestReader = Reader(readerState: readerState, datagramStreamFuture: datagramStreamFuture)
        let responseSender = ResponseSender(
            writer: outbound,
            writerState: writerState,
            datagramStreamFuture: datagramStreamFuture
        )

        _ = await self.invokeHandler(
            request: request,
            requestContext: requestContext,
            requestReader: requestReader,
            responseSender: responseSender,
            handler: handler
        )
    }
    #endif  // HTTP3 && UnstableHTTPDatagrams

    func invokeHandler<Handler: HTTPServerRequestHandler>(
        request: HTTPRequest,
        requestContext: RequestContext,
        inboundIterator: consuming sending NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator,
        outbound: NIOAsyncChannelOutboundWriter<HTTPResponsePart>,
        handler: Handler
    ) async -> NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator?
    where
        Handler.RequestContext == RequestContext,
        Handler.Reader == Reader,
        Handler.ResponseSender == ResponseSender
    {
        let readerState = Reader.ReaderState(iterator: inboundIterator)
        let writerState = ResponseSender.WriterState()

        let requestReader = Reader(readerState: readerState)
        let responseSender = ResponseSender(writer: outbound, writerState: writerState)

        return await self.invokeHandler(
            request: request,
            requestContext: requestContext,
            requestReader: requestReader,
            responseSender: responseSender,
            handler: handler
        )
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

extension NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator {
    /// Reads the next request head from the iterator. Returns `nil` if the connection is done or an unexpected part is
    /// received.
    ///
    /// Skips over leftover `.body` and `.end` parts from a previous request that the handler didn't fully consume.
    mutating func nextRequestHead(logger: Logger) async throws -> HTTPRequest? {
        while true {
            switch try await self.next(isolation: #isolation) {
            case .head(let request):
                return request
            case .body, .end:
                // Leftover parts from a previous request. Skip and look for the next head.
                continue
            case .none:
                logger.trace("No more request parts on connection")
                return nil
            }
        }
    }
}

@available(anyAppleOS 26.0, *)
extension ServerBootstrap {
    /// Makes a `ServerBootstrap` alongside the `ServerQuiescingHelper` used to later shut that listener down gracefully.
    ///
    /// - Note: A `ConnectionLimitHandler` is only installed when `maxConnections` is non-`nil`.
    static func makeTCPBootstrap(
        group: any EventLoopGroup,
        maxConnections: Int?
    ) -> (ServerBootstrap, ServerQuiescingHelper) {
        let serverQuiescingHelper = ServerQuiescingHelper(group: group)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .serverChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        serverQuiescingHelper.makeServerChannelHandler(channel: channel)
                    )

                    if let maxConnections {
                        try channel.pipeline.syncOperations.addHandler(
                            ConnectionLimitHandler(maxConnections: maxConnections)
                        )
                    }
                }
            }

        return (bootstrap, serverQuiescingHelper)
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// Awaits the next address from `iterator`.
    func nextBoundAddress(
        from iterator: inout sending AsyncThrowingStream<NIOCore.SocketAddress, any Error>.AsyncIterator
    ) async throws -> NIOCore.SocketAddress {
        guard let address = try await iterator.next() else {
            throw ListeningAddressError.addressOrPortNotAvailable
        }
        return address
    }

    /// Provides a TCP listening channel bound to `address`. The underlying socket is closed when either returning or
    /// throwing from the `body` closure.
    ///
    /// - Note: The bind address is yielded to the provided `addressContinuation` immediately after the TCP socket has
    ///   been bound.
    func withTCPChannel<Child: Sendable>(
        address: NIOCore.SocketAddress,
        addressContinuation: AsyncThrowingStream<NIOCore.SocketAddress, any Error>.Continuation,
        childChannelInitializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Child>,
        _ body: (NIOAsyncChannelInboundStream<Child>) async throws -> Void
    ) async throws {
        let (bootstrap, serverQuiescingHelper) = ServerBootstrap.makeTCPBootstrap(
            group: self.eventLoopGroup,
            maxConnections: self.configuration.maxConnections
        )

        let serverChannel: NIOAsyncChannel<Child, Never>
        do {
            serverChannel = try await bootstrap.bind(to: address, childChannelInitializer: childChannelInitializer)
        } catch {
            addressContinuation.finish(throwing: error)
            throw error
        }

        try await withTaskCancellationHandler {
            try await withGracefulShutdownHandler {
                if Task.isCancelled || Task.isShuttingDownGracefully {
                    // The cancellation/shutdown handler will have closed the socket. Just await the closeFuture here.
                    try? await serverChannel.channel.closeFuture.get()
                    return
                }

                guard let localAddress = serverChannel.channel.localAddress else {
                    addressContinuation.finish(throwing: ListeningAddressError.addressOrPortNotAvailable)
                    throw ListeningAddressError.addressOrPortNotAvailable
                }

                addressContinuation.yield(localAddress)

                try await serverChannel.executeThenClose { inboundConnectionStream in
                    try await body(inboundConnectionStream)
                }
            } onGracefulShutdown: {
                addressContinuation.finish(throwing: ListeningAddressError.serverClosed)
                serverQuiescingHelper.initiateShutdown(promise: nil)
            }
        } onCancel: {
            addressContinuation.finish(throwing: ListeningAddressError.serverClosed)
            serverChannel.channel.close(promise: nil)
        }
    }
}
