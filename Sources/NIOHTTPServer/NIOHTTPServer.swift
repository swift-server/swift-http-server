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
///     logger: logger,
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
@available(anyAppleOS 26.0, *)
public struct NIOHTTPServer: HTTPServer {
    public struct RequestContext: HTTPServerCapability.RequestContext, Sendable {}

    let logger: Logger
    let configuration: NIOHTTPServerConfiguration

    /// The event loop group on which the server runs.
    ///
    /// This event loop group is used for every channel the server binds. It also provides the event loop that fulfills
    /// the listening address promise and the group from which a `ServerQuiescingHelper` is created for each bound
    /// channel.
    let eventLoopGroup: MultiThreadedEventLoopGroup

    var listeningAddressState: NIOLockedValueBox<State>

    /// Task-local storage for connection-specific information accessible from request handlers.
    ///
    /// - SeeAlso: ``ConnectionContext``.
    @TaskLocal public static var connectionContext = ConnectionContext()

    /// Create a new ``HTTPServer`` implemented over `SwiftNIO`.
    /// - Parameters:
    ///   - logger: A logger instance for recording server events and debugging information.
    ///   - configuration: The server configuration including bind target and TLS settings.
    public init(
        logger: Logger,
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
    /// that point, ``listeningAddresses`` will throw ``ListeningAddressError/serverClosed``.
    ///
    /// - Parameter handler: A ``HTTPServerRequestHandler`` implementation that processes incoming HTTP
    ///   requests. The handler receives each request along with a body reader and response sender function.
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
        Handler.RequestContext: ~Copyable,
        Handler.RequestContext == RequestContext,
        Handler.Reader == Reader,
        Handler.Reader: ~Copyable,
        Handler.ResponseSender == ResponseSender,
        Handler.ResponseSender: ~Copyable
    {
        // Ensure the listening address promise is always completed on the way out, regardless of whether
        // binding succeeded, the serve loop returned normally, or an error propagated.
        defer { self.finishListeningAddressPromise() }

        let serverChannels = try await self.makeServerChannels()

        return try await withTaskCancellationHandler {
            try await withGracefulShutdownHandler {
                try await self._serve(serverChannels: serverChannels, handler: handler)
            } onGracefulShutdown: {
                self.beginGracefulShutdown(serverChannels: serverChannels)
            }
        } onCancel: {
            // Forcefully close down the server channels
            self.close(serverChannels: serverChannels)
        }
    }

    /// Creates and returns server channels based on the configured transport security.
    private func makeServerChannels() async throws -> [ServerChannel] {
        switch self.configuration.transportSecurity.backing {
        case .plaintext:
            return try await self.setupHTTP1_1ServerChannels(bindTargets: self.configuration.bindTargets)
                .map { channel, quiescingHelper in
                    .plaintextHTTP1_1(channel: channel, quiescingHelper: quiescingHelper)
                }

        case .tls, .mTLS:
            return try await self.setupSecureUpgradeServerChannels(
                bindTargets: self.configuration.bindTargets,
                supportedHTTPVersions: self.configuration.supportedHTTPVersions,
                sslContext: .makeServerContext(
                    transportSecurity: self.configuration.transportSecurity,
                    alpnIdentifiers: self.configuration.supportedHTTPVersions.alpnIdentifiers
                ),
            ).map { channel, quiescingHelper in
                .secureUpgrade(channel: channel, quiescingHelper: quiescingHelper)
            }
        }
    }

    private func _serve<Handler: HTTPServerRequestHandler>(
        serverChannels: [ServerChannel],
        handler: Handler
    ) async throws
    where
        Handler.RequestContext: ~Copyable,
        Handler.RequestContext == RequestContext,
        Handler.Reader == Reader,
        Handler.Reader: ~Copyable,
        Handler.ResponseSender == ResponseSender,
        Handler.ResponseSender: ~Copyable
    {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for serverChannel in serverChannels {
                group.addTask {
                    switch serverChannel {
                    case .plaintextHTTP1_1(let http1Channel, _):
                        try await self.serveInsecureHTTP1_1(serverChannel: http1Channel, handler: handler)

                    case .secureUpgrade(let secureUpgradeChannel, _):
                        try await self.serveSecureUpgrade(serverChannel: secureUpgradeChannel, handler: handler)
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
        handler: Handler
    ) async throws -> NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator?
    where
        Handler.RequestContext: ~Copyable,
        Handler.RequestContext == RequestContext,
        Handler.Reader == Reader,
        Handler.Reader: ~Copyable,
        Handler.ResponseSender == ResponseSender,
        Handler.ResponseSender: ~Copyable
    {
        let readerState = Reader.ReaderState(iterator: iterator)
        let writerState = ResponseSender.WriterState()

        do {
            try await handler.handle(
                request: request,
                requestContext: RequestContext(),
                reader: Reader(
                    readerState: readerState
                ),
                responseSender: ResponseSender(writer: outbound, writerState: writerState)
            )
        } catch {
            logger.error("Error thrown while handling request: \(error)")
            if !readerState.wrapped.withLock({ $0.finishedReading }) {
                logger.error("Did not finish reading but error thrown.")
            }
            if !writerState.wrapped.withLock({ $0.finishedWriting }) {
                logger.error("Did not write response but error thrown.")
            }
            throw error
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

    /// Initiates a graceful shutdown, allowing existing connections to drain before closing.
    private func beginGracefulShutdown(serverChannels: [ServerChannel]) {
        self.finishListeningAddressPromise()

        for serverChannel in serverChannels {
            switch serverChannel {
            case .plaintextHTTP1_1(_, let quiescingHelper),
                .secureUpgrade(_, let quiescingHelper):
                quiescingHelper.initiateShutdown(promise: nil)
            }
        }
    }

    /// Forcefully closes the server channels without waiting for existing connections to drain.
    private func close(serverChannels: [ServerChannel]) {
        self.finishListeningAddressPromise()

        for serverChannel in serverChannels {
            switch serverChannel {
            case .plaintextHTTP1_1(let http1Channel, _):
                http1Channel.channel.close(promise: nil)

            case .secureUpgrade(let secureUpgradeChannel, _):
                secureUpgradeChannel.channel.close(promise: nil)
            }
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
