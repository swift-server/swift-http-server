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

#if UnstableWebTransport

import Foundation
import Logging
import NIOCore
import NIOHTTP3
import NIOHTTPServer
import NIOQUIC
import NIOQUICHelpers
import X509

#endif

@main
@available(anyAppleOS 27.0, *)
struct WebTransportExample {
    static func main() async throws {
        #if UnstableWebTransport
        try await serve()
        #endif
    }

    #if UnstableWebTransport
    @concurrent
    static func serve() async throws {
        var rootLogger = Logger(label: "WebTransportExample")
        rootLogger.logLevel = .debug

        try await withLogger(rootLogger) { _ in
            let server = NIOHTTPServer(
                configuration: try .init(
                    bindTarget: .hostAndPort(host: "127.0.0.1", port: 12345),
                    supportedHTTPVersions: [.http3],
                    transportSecurity: .tls(credentials: .http3())
                )
            )

            // The example uses the `serve` method that exposes the connection, not the "default" one
            try await server.serve { connection, requestContext in
                // The QUIC stream creator can be accessed from the connection to create WebTransport streams
                guard let webTransportStreamCreator = try await connection.webTransportStreamCreator else {
                    fatalError("QUIC stream creator is not available")
                }

                // We then handle incoming requests (in this case WebTransport sessions) for this connection
                await connection.handleRequests { request, requestContext, reader, responseSender in
                    // First, we validate that the incoming request is a valid request for a WebTransport session
                    guard WebTransportHelper.isValidWebTransportRequest(request) else {
                        return try await responseSender.sendAndFinish(.init(status: .forbidden))
                    }

                    var streamReader = reader
                    // Then we take the datagram reader from the stream reader to handle incoming datagrams
                    guard let datagramReader = await streamReader.takeDatagramReader() else {
                        return try await responseSender.sendAndFinish(.init(status: .notImplemented))
                    }

                    // Next, we get the incoming streams from the stream reader
                    guard let incomingUnidirectionalStreams = streamReader.webTransportIncomingUnidirectionalStreams
                    else {
                        return try await responseSender.sendAndFinish(.init(status: .notImplemented))
                    }
                    guard let incomingBidirectionalStreams = streamReader.webTransportIncomingBidirectionalStreams
                    else {
                        return try await responseSender.sendAndFinish(.init(status: .notImplemented))
                    }

                    // let streamReaderBox = RefBox(value: Disconnected(value: streamReader))
                    let datagramReaderBox = RefBox(value: Disconnected(value: datagramReader))

                    // We send the response to the client indicating that the WebTransport session has been successfully established
                    var streamWriter = try await responseSender.send(
                        WebTransportHelper.makeSuccessResponse(headerFields: request.headerFields)
                    )
                    // We then take the datagram writer from the stream writer to handle outgoing datagrams
                    let datagramWriter = await streamWriter.takeDatagramWriter()

                    // let streamWriterBox = RefBox(value: Disconnected(value: streamWriter))
                    let datagramWriterBox = RefBox(value: Disconnected(value: datagramWriter))

                    // Give some time for the response to be fully sent
                    try await Task.sleep(for: .seconds(1))

                    await withThrowingTaskGroup { group in
                        var unwrappedDatagramReader = datagramReaderBox.unbox().take()
                        var disconnectedDatagramWriter = datagramWriterBox.unbox()
                        if var unwrappedDatagramWriter = disconnectedDatagramWriter.swap(newValue: nil) {
                            group.addTask {
                                // Echoes incoming datagrams back to the client
                                try await unwrappedDatagramReader.read { buffer, _ in
                                    try await unwrappedDatagramWriter.write(buffer: &buffer)
                                }
                            }
                        }

                        group.addTask {
                            try await withThrowingDiscardingTaskGroup { streamsGroup in
                                // Iterate over all incoming unidirectional streams from the client
                                for await stream in incomingUnidirectionalStreams {
                                    streamsGroup.addTask {
                                        // Each stream is a `NIOAsyncChannel`
                                        try await stream.executeThenClose { inbound in
                                            for try await message in inbound {
                                                // Custom logic
                                                if String(buffer: message) == "open" {
                                                    try await webTransportStreamCreator.withUnidirectionalStream(
                                                        requestContext: requestContext
                                                    ) { outbound in
                                                        try await outbound.write(ByteBuffer(string: "opened"))
                                                    }
                                                } else {
                                                    print("Received on uni stream: \(String(buffer: message))")
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        group.addTask {
                            try await withThrowingDiscardingTaskGroup { streamsGroup in
                                // Iterate over all incoming bidirectional streams from the client
                                for await stream in incomingBidirectionalStreams {
                                    streamsGroup.addTask {
                                        // Each bidirectional stream is a `NIOAsyncChannel`
                                        try await stream.executeThenClose { inbound, outbound in
                                            for try await message in inbound {
                                                // Custom logic
                                                if String(buffer: message) == "open" {
                                                    try await webTransportStreamCreator.withBidirectionalStream(
                                                        requestContext: requestContext
                                                    ) { inbound, outbound in
                                                        try await outbound.write(ByteBuffer(string: "opened"))
                                                        for try await message in inbound {
                                                            try await outbound.write(message)
                                                        }
                                                    }
                                                } else {
                                                    try await outbound.write(message)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    #endif
}

#if UnstableWebTransport

@available(anyAppleOS 27.0, *)
enum WebTransportHelper {
    /// Validate that `request` corresponds to a valid WebTransport over HTTP/3 request.
    static func isValidWebTransportRequest(_ request: HTTPRequest) -> Bool {
        guard request.method == .connect else {
            return false
        }

        // Support "webtransport" upgrade token for backward compatibility with older drafts.
        // TODO: remove support for "webtransport" upgrade token
        guard request.extendedConnectProtocol == "webtransport-h3" || request.extendedConnectProtocol == "webtransport"
        else {
            return false
        }

        return true
    }

    /// Returns a success response to accept the WebTransport session.
    static func makeSuccessResponse(headerFields: HTTPFields) -> HTTPResponse {
        let headers: HTTPFields
        if let wtAvailableProtocols = headerFields[values: .webTransportAvailableProtocols].first {
            // A real implementation should use `apple/swift-http-structured-headers` to parse the list of available protocols.
            let wtProtocol = String(wtAvailableProtocols.prefix(while: { char in char != "," }))
            if wtProtocol == "\"webtransport-test\"" || wtProtocol == "\"webtransport-test-2\"" {
                headers = [.webTransportProtocol: wtProtocol]
            } else {
                headers = [:]
            }
        } else {
            headers = [:]
        }
        return HTTPResponse(status: .ok, headerFields: headers)
    }
}

extension HTTPField.Name {
    /// WT-Protocol
    ///
    /// https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/
    static var webTransportProtocol: Self {
        Self("WT-Protocol")!
    }
    /// WT-Available-Protocols
    ///
    /// https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/
    static var webTransportAvailableProtocols: Self {
        Self("WT-Available-Protocols")!
    }
}

@available(anyAppleOS 27.0, *)
extension NIOHTTPServerConfiguration.TransportSecurity.TLSCredentials {
    /// PEM-file X.509 credentials supported by SwiftNIO HTTP/3.
    fileprivate static func http3() -> Self {
        guard
            let certificateURL = Bundle.module.url(forResource: "http3", withExtension: "crt"),
            let privateKeyURL = Bundle.module.url(forResource: "http3", withExtension: "key")
        else {
            fatalError("Failed to locate certificate or private key")
        }

        return .x509(.pemFile(certificateChainPath: certificateURL.path(), privateKeyPath: privateKeyURL.path()))
    }
}

// This is a helper type to move a non-Sendable value across isolation regions.
@usableFromInline
struct Disconnected<Value: ~Copyable>: ~Copyable, Sendable {
    // This is safe since we take the value as sending and take consumes it
    // and returns it as sending.
    private nonisolated(unsafe) var value: Value?

    @usableFromInline
    init(value: consuming sending Value) {
        unsafe self.value = .some(value)
    }

    @usableFromInline
    consuming func take() -> sending Value {
        nonisolated(unsafe) let value = unsafe self.value.take()!
        return unsafe value
    }

    @usableFromInline
    mutating func swap(newValue: consuming sending Value) -> sending Value {
        nonisolated(unsafe) let value = unsafe self.value.take()!
        unsafe self.value = consume newValue
        return unsafe value
    }
}

/// A Copyable, Sendable box for transferring a ~Copyable value across escaping
/// closure boundaries.
///
/// Store a ~Copyable value with ``init(value:)``, then retrieve it exactly once
/// with ``unbox()``.
// TODO: Remove RefBox once Swift gains "called once" closures (SE-0528 future direction).
// Until then, ~Copyable values cannot be captured by @escaping closures (like addTask),
// so this class provides a Copyable + Sendable wrapper for cross-task transfer.
final class RefBox<Value: ~Copyable> {
    private nonisolated(unsafe) var value: Value?

    public init(value: consuming Value) {
        unsafe self.value = consume value
    }

    public consuming func unbox() -> Value {
        unsafe value.take()!
    }
}
extension RefBox: Sendable where Value: Sendable & ~Copyable {}

#endif
