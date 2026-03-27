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

public import HTTPAPIs
import HTTPTypes
public import Logging
import NIOCertificateReloading
import NIOConcurrencyHelpers
import NIOCore
import NIOExtras
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
/// The `Server` class provides a high-level interface for creating HTTP servers with support for:
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
/// let configuration = NIOHTTPServerConfiguration(
///     bindTarget: .hostAndPort(host: "localhost", port: 8080),
///     tlsConfiguration: .insecure()
/// )
///
/// try await Server.serve(
///     logger: logger,
///     configuration: configuration
/// ) { request, bodyReader, sendResponse in
///     // Read the entire request body
///     let (bodyData, trailers) = try await bodyReader.consumeAndConclude { reader in
///         var data = [UInt8]()
///         var shouldContinue = true
///         while shouldContinue {
///             try await reader.read { span in
///                 guard let span else {
///                     shouldContinue = false
///                     return
///                 }
///                 data.append(contentsOf: span)
///             }
///         }
///         return data
///     }
///
///     // Create and send response
///     var response = HTTPResponse(status: .ok)
///     response.headerFields[.contentType] = "text/plain"
///     let responseWriter = try await sendResponse(response)
///     try await responseWriter.produceAndConclude { writer in
///         try await writer.write("Hello, World!".utf8CString.dropLast().span)
///         return ((), nil)
///     }
/// }
/// ```
@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
public struct NIOHTTPServer: HTTPServer {
    public typealias RequestConcludingReader = HTTPRequestConcludingAsyncReader
    public typealias ResponseConcludingWriter = HTTPResponseConcludingAsyncWriter

    let logger: Logger
    let configuration: NIOHTTPServerConfiguration

    let serverQuiescingHelper: ServerQuiescingHelper

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
        let eventLoopGroup: MultiThreadedEventLoopGroup = .singletonMultiThreadedEventLoopGroup
        self.listeningAddressState = .init(.idle(eventLoopGroup.any().makePromise()))

        self.serverQuiescingHelper = .init(group: eventLoopGroup)
    }

    /// Starts an HTTP server with the specified request handler.
    ///
    /// This method creates and runs an HTTP server that processes incoming requests using the provided
    /// ``HTTPServerRequestHandler`` implementation. The server binds to the specified configuration and
    /// handles each connection concurrently using Swift's structured concurrency.
    ///
    /// - Parameters:
    ///   - logger: A logger instance for recording server events and debugging information.
    ///   - configuration: The server configuration including bind target and TLS settings.
    ///   - handler: A ``HTTPServerRequestHandler`` implementation that processes incoming HTTP requests. The handler
    ///     receives each request along with a body reader and response sender function.
    ///
    /// ## Example
    ///
    /// ```swift
    /// struct EchoHandler: HTTPServerRequestHandler {
    ///     func handle(
    ///         request: HTTPRequest,
    ///         requestBodyAndTrailers: HTTPRequestConcludingAsyncReader,
    ///         responseSender: @escaping (HTTPResponse) async throws -> HTTPResponseConcludingAsyncWriter
    ///     ) async throws {
    ///         let response = HTTPResponse(status: .ok)
    ///         let writer = try await sendResponse(response)
    ///         // Handle request and write response...
    ///     }
    /// }
    ///
    /// let configuration = HTTPServerConfiguration(
    ///     bindTarget: .hostAndPort(host: "localhost", port: 8080),
    ///     tlsConfiguration: .insecure()
    /// )
    ///
    /// try await Server.serve(
    ///     logger: logger,
    ///     configuration: configuration,
    ///     handler: EchoHandler()
    /// )
    /// ```
    public func serve(
        handler: some HTTPServerRequestHandler<RequestConcludingReader, ResponseConcludingWriter>
    ) async throws {
        let serverChannel = try await self.makeServerChannel()

        return try await withTaskCancellationHandler {
            try await withGracefulShutdownHandler {
                try await self._serve(serverChannel: serverChannel, handler: handler)
            } onGracefulShutdown: {
                self.beginGracefulShutdown()
            }
        } onCancel: {
            // Forcefully close down the server channel
            self.close(serverChannel: serverChannel)
        }
    }

    /// Creates and returns a server channel based on the configured transport security.
    private func makeServerChannel() async throws -> ServerChannel {
        switch self.configuration.transportSecurity.backing {
        case .plaintext:
            return .plaintextHTTP1_1(
                try await self.setupHTTP1_1ServerChannel(bindTarget: self.configuration.bindTarget)
            )

        case .tls(let credentials):
            return .secureUpgrade(
                try await self.setupSecureUpgradeServerChannel(
                    bindTarget: self.configuration.bindTarget,
                    supportedHTTPVersions: self.configuration.supportedHTTPVersions,
                    tlsConfiguration: try .makeServerConfiguration(tlsCredentials: credentials, mTLSConfiguration: nil)
                )
            )

        case .mTLS(let credentials, let mTLSConfiguration):
            return .secureUpgrade(
                try await self.setupSecureUpgradeServerChannel(
                    bindTarget: self.configuration.bindTarget,
                    supportedHTTPVersions: self.configuration.supportedHTTPVersions,
                    tlsConfiguration: try .makeServerConfiguration(
                        tlsCredentials: credentials,
                        mTLSConfiguration: mTLSConfiguration
                    )
                )
            )
        }
    }

    private func _serve(
        serverChannel: ServerChannel,
        handler: some HTTPServerRequestHandler<RequestConcludingReader, ResponseConcludingWriter>
    ) async throws {
        switch serverChannel {
        case .plaintextHTTP1_1(let http1Channel):
            try await self.serveInsecureHTTP1_1(serverChannel: http1Channel, handler: handler)

        case .secureUpgrade(let secureUpgradeChannel):
            try await self.serveSecureUpgrade(serverChannel: secureUpgradeChannel, handler: handler)
        }
    }

    func handleRequestChannel(
        channel: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
        handler: some HTTPServerRequestHandler<RequestConcludingReader, ResponseConcludingWriter>
    ) async throws {
        do {
            try await channel
                .executeThenClose { inbound, outbound in
                    var iterator = inbound.makeAsyncIterator()

                    let httpRequest: HTTPRequest
                    switch try await iterator.next() {
                    case .head(let request):
                        httpRequest = request
                    case .body:
                        self.logger.debug("Unexpectedly received body on connection. Closing now")
                        outbound.finish()
                        return
                    case .end:
                        self.logger.debug("Unexpectedly received end on connection. Closing now")
                        outbound.finish()
                        return
                    case .none:
                        self.logger.trace("No more requests parts on connection")
                        return
                    }

                    let readerState = HTTPRequestConcludingAsyncReader.ReaderState()
                    let writerState = HTTPResponseConcludingAsyncWriter.WriterState()

                    do {
                        try await handler.handle(
                            request: httpRequest,
                            requestContext: HTTPRequestContext(),
                            requestBodyAndTrailers: HTTPRequestConcludingAsyncReader(
                                iterator: iterator,
                                readerState: readerState
                            ),
                            responseSender: HTTPResponseSender { response in
                                try await outbound.write(.head(response))
                                return HTTPResponseConcludingAsyncWriter(
                                    writer: outbound,
                                    writerState: writerState
                                )
                            } sendInformational: { response in
                                try await outbound.write(.head(response))
                            }
                        )
                    } catch {
                        logger.error("Error thrown while handling connection: \(error)")
                        if !readerState.wrapped.withLock({ $0.finishedReading }) {
                            logger.error("Did not finish reading but error thrown.")
                            // TODO: if h2 reset stream; if h1 try draining request?
                        }
                        if !writerState.wrapped.withLock({ $0.finishedWriting }) {
                            logger.error("Did not write response but error thrown.")
                            // TODO: we need to do something, possibly just close the connection or
                            // reset the stream with the appropriate error.
                        }
                        throw error
                    }

                    // TODO: handle other state scenarios.
                    // For example, if we're using h2 and we didn't finish reading but we wrote back
                    // a response, we should send a RST_STREAM with NO_ERROR set.
                    // If we finished reading but we didn't write back a response, then RST_STREAM
                    // is also likely appropriate but unclear about the error.
                    // For h1, we should close the connection.

                    // Finish the outbound and wait on the close future to make sure all pending
                    // writes are actually written.
                    outbound.finish()
                    try await channel.channel.closeFuture.get()
                }
        } catch {
            self.logger.debug("Error thrown while handling connection: \(error)")
            // TODO: We need to send a response head here potentially
            try? await channel.channel.close()
        }
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
    private func beginGracefulShutdown() {
        self.finishListeningAddressPromise()
        self.serverQuiescingHelper.initiateShutdown(promise: nil)
    }

    /// Forcefully closes the server channel without waiting for existing connections to drain.
    private func close(serverChannel: ServerChannel) {
        self.finishListeningAddressPromise()

        switch serverChannel {
        case .plaintextHTTP1_1(let http1Channel):
            http1Channel.channel.close(promise: nil)

        case .secureUpgrade(let secureUpgradeChannel):
            secureUpgradeChannel.channel.close(promise: nil)
        }
    }
}

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension NIOHTTP2Handler.Configuration {
    init(httpServerHTTP2Configuration http2Config: NIOHTTPServerConfiguration.HTTP2) {
        let clampedTargetWindowSize = Self.clampTargetWindowSize(http2Config.targetWindowSize)
        let clampedMaxFrameSize = Self.clampMaxFrameSize(http2Config.maxFrameSize)

        var http2HandlerConnectionConfiguration = NIOHTTP2Handler.ConnectionConfiguration()
        var http2HandlerHTTP2Settings = HTTP2Settings([
            HTTP2Setting(parameter: .initialWindowSize, value: clampedTargetWindowSize),
            HTTP2Setting(parameter: .maxFrameSize, value: clampedMaxFrameSize),
        ])
        if let maxConcurrentStreams = http2Config.maxConcurrentStreams {
            http2HandlerHTTP2Settings.append(
                HTTP2Setting(parameter: .maxConcurrentStreams, value: maxConcurrentStreams)
            )
        }
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
