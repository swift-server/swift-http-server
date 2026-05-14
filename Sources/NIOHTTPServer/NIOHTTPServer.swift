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
    /// This method binds to all addresses specified in ``NIOHTTPServerConfiguration/bindTargets`` and begins
    /// accepting connections on each one. All bind targets share the same request handler, transport security
    /// configuration, and supported HTTP versions.
    ///
    /// ## All-or-nothing listening
    ///
    /// The server treats its set of listening addresses as a single unit. If any one of the bound addresses
    /// stops listening — whether due to its underlying socket closing, an unrecoverable error on the
    /// listening channel, or any other reason — the server stops listening on **all** remaining addresses
    /// and this method returns. After that point, ``listeningAddresses`` will throw
    /// ``ListeningAddressError/serverClosed``.
    ///
    /// This also applies during graceful shutdown and task cancellation: all channels are shut down together.
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
    public func serve(
        handler: some HTTPServerRequestHandler<RequestConcludingReader, ResponseConcludingWriter>
    ) async throws {
        // Ensure the listening address promise is always completed on the way out, regardless of whether
        // binding succeeded, the serve loop returned normally, or an error propagated.
        defer { self.finishListeningAddressPromise() }

        let serverChannels = try await self.makeServerChannels()

        return try await withTaskCancellationHandler {
            try await withGracefulShutdownHandler {
                try await self._serve(serverChannels: serverChannels, handler: handler)
            } onGracefulShutdown: {
                self.beginGracefulShutdown()
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
                .map { .plaintextHTTP1_1($0) }

        case .tls(let credentials):
            return try await self.setupSecureUpgradeServerChannels(
                bindTargets: self.configuration.bindTargets,
                supportedHTTPVersions: self.configuration.supportedHTTPVersions,
                tlsConfiguration: try .makeServerConfiguration(tlsCredentials: credentials, mTLSConfiguration: nil)
            ).map { .secureUpgrade($0) }

        case .mTLS(let credentials, let mTLSConfiguration):
            return try await self.setupSecureUpgradeServerChannels(
                bindTargets: self.configuration.bindTargets,
                supportedHTTPVersions: self.configuration.supportedHTTPVersions,
                tlsConfiguration: try .makeServerConfiguration(
                    tlsCredentials: credentials,
                    mTLSConfiguration: mTLSConfiguration
                )
            ).map { .secureUpgrade($0) }
        }
    }

    private func _serve(
        serverChannels: [ServerChannel],
        handler: some HTTPServerRequestHandler<RequestConcludingReader, ResponseConcludingWriter>
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for serverChannel in serverChannels {
                group.addTask {
                    switch serverChannel {
                    case .plaintextHTTP1_1(let http1Channel):
                        try await self.serveInsecureHTTP1_1(serverChannel: http1Channel, handler: handler)

                    case .secureUpgrade(let secureUpgradeChannel):
                        try await self.serveSecureUpgrade(serverChannel: secureUpgradeChannel, handler: handler)
                    }
                }
            }

            // Wait for the first channel to complete (either normally or by throwing).
            // If any channel stops serving, bring down all remaining channels.
            try await group.next()
            group.cancelAll()
        }
    }

    /// Handles a single HTTP request.
    ///
    /// - Note: Errors do not propagate to the caller. When an error occurs, it is logged and the channel is closed.
    ///
    /// - Parameters:
    ///   - channel: The async channel to read the request from and write the response to.
    ///   - handler: The request handler.
    func handleRequestChannel(
        channel: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
        handler: some HTTPServerRequestHandler<RequestConcludingReader, ResponseConcludingWriter>
    ) async {
        do {
            try await channel.executeThenClose { inbound, outbound in
                var iterator = inbound.makeAsyncIterator()

                let nextPart: HTTPRequestPart?
                do {
                    nextPart = try await iterator.next()
                } catch {
                    self.logger.error(
                        "Error thrown while advancing the request iterator",
                        metadata: ["error": "\(error)"]
                    )
                    throw error
                }

                let httpRequest: HTTPRequest
                switch nextPart {
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
                    if !readerState.wrapped.withLock({ $0.finishedReading }) {
                        self.logger.error("Did not finish reading but error thrown.")
                        // TODO: if h2 reset stream; if h1 try draining request?
                    }

                    if !writerState.wrapped.withLock({ $0.finishedWriting }) {
                        self.logger.error("Did not write response but error thrown.")
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
            // TODO: We need to send a response head here potentially
            self.logger.error("Error thrown while handling connection", metadata: ["error": "\(error)"])

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

    /// Forcefully closes the server channels without waiting for existing connections to drain.
    private func close(serverChannels: [ServerChannel]) {
        self.finishListeningAddressPromise()

        for serverChannel in serverChannels {
            switch serverChannel {
            case .plaintextHTTP1_1(let http1Channel):
                http1Channel.channel.close(promise: nil)

            case .secureUpgrade(let secureUpgradeChannel):
                secureUpgradeChannel.channel.close(promise: nil)
            }
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
