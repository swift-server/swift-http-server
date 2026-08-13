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

#if HTTP3 && UnstableHTTPDatagrams

import BasicContainers
import HTTPAPIs
import NIOCore
import NIOHTTPTypes
import NetworkTypes

@available(anyAppleOS 26.0, *)
func connectUDPExample(
    request: HTTPRequest,
    context: NIOHTTPServer.ConnectionContext,
    reader: consuming sending NIOHTTPServer.Reader,
    responseSender: consuming sending NIOHTTPServer.ResponseSender
) async throws {
    guard ConnectUDPHelper.isValidConnectUDPRequest(request, version: context.httpVersion) else {
        return try await responseSender.sendAndFinish(.init(status: .forbidden))
    }

    var streamReader = reader
    let maybeDatagramReader = streamReader.takeDatagramReader()

    // The unreliable datagram transport will not be available if the underlying transport does not support
    // unreliable datagrams, like in HTTP/1.1 and HTTP/2 over TCP, or also over HTTP/3 when support for datagrams is
    // not negotiated, i.e. we (the server) either sent or received the `SETTINGS_H3_DATAGRAM` setting with value 0.
    //
    // Since this example wants to showcase the unreliable datagram reader/writer APIs, we just return early if the
    // unreliable datagram transport is not available. However, note that in these cases, it is still possible to
    // perform CONNECT-UDP by exchanging data through the Capsule protocol over the request/response reader/writer.
    guard var datagramReader = maybeDatagramReader else {
        return try await responseSender.sendAndFinish(.init(status: .notImplemented))
    }

    // Store any bytes we read before sending the response so we can send them to the target.
    var pendingToTarget: [UInt8] = []

    try await streamReader.read { buffer, _ in
        for index in buffer.indices { pendingToTarget.append(buffer[index]) }
    }

    try await datagramReader.read { buffer, _ in
        for index in buffer.indices { pendingToTarget.append(buffer[index]) }
    }

    // Hold the readers until the tunnel is established.
    let streamReaderBox = RefBox(value: Disconnected(value: streamReader))
    let datagramReaderBox = RefBox(value: Disconnected(value: datagramReader))

    // Now accept the request and access the datagram writer through the response writer.
    var streamWriter = try await responseSender.send(ConnectUDPHelper.makeSuccessResponse(version: context.httpVersion))
    let datagramWriter = streamWriter.takeDatagramWriter()

    let streamWriterBox = RefBox(value: Disconnected(value: streamWriter))
    let datagramWriterBox = RefBox(value: Disconnected(value: datagramWriter))

    await withThrowingTaskGroup { group in
        var unwrappedStreamWriter = streamWriterBox.unbox().take()
        var unwrappedStreamReader = streamReaderBox.unbox().take()
        var unwrappedDatagramReader = datagramReaderBox.unbox().take()

        // Write to the reliable stream.
        group.addTask {
            var emptyBuffer = UniqueArray<UInt8>()
            try await unwrappedStreamWriter.write(buffer: &emptyBuffer)
        }

        var disconnectedDatagramWriter = datagramWriterBox.unbox()
        if var unwrappedDatagramWriter = disconnectedDatagramWriter.swap(newValue: nil) {
            // Write to the unreliable stream.
            group.addTask {
                var emptyBuffer = UniqueArray<UInt8>()
                try await unwrappedDatagramWriter.write(buffer: &emptyBuffer)
            }
        }

        // Read from the reliable stream.
        group.addTask {
            try await unwrappedStreamReader.read { _, _ in
                ()
            }
        }

        // Read from the unreliable stream.
        group.addTask {
            try await unwrappedDatagramReader.read { _, _ in
                ()
            }
        }
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

@available(anyAppleOS 26.0, *)
enum ConnectUDPHelper {
    /// Validate that `request` corresponds to a valid CONNECT-UDP request.
    static func isValidConnectUDPRequest(_ request: HTTPRequest, version: NIOHTTPServer.HTTPVersion) -> Bool {
        guard request.method == .connect else {
            return false
        }

        switch version {
        case .plaintextHTTP1_1, .http1_1:
            let hasConnectionUpgrade = request.headerFields[.connection]?.lowercased() == "upgrade"
            let hasUpgradeConnectUDP = request.headerFields[.upgrade] == "connect-udp"

            guard hasConnectionUpgrade, hasUpgradeConnectUDP else {
                return false
            }

        case .http2:
            guard request.extendedConnectProtocol == "connect-udp" else {
                return false
            }

        #if HTTP3
        case .http3:
            guard request.extendedConnectProtocol == "connect-udp" else {
                return false
            }
        #endif
        }

        return true
    }

    /// Returns a success response to accept the tunnel.
    static func makeSuccessResponse(version: NIOHTTPServer.HTTPVersion) -> HTTPResponse {
        switch version {
        case .plaintextHTTP1_1, .http1_1:
            HTTPResponse(
                status: .switchingProtocols,
                headerFields: [
                    .connection: "Upgrade",
                    .upgrade: "connect-udp",
                    .capsuleProtocol: "?1",
                ]
            )

        case .http2:
            HTTPResponse(status: .ok, headerFields: [.capsuleProtocol: "?1"])

        #if HTTP3
        case .http3:
            HTTPResponse(status: .ok, headerFields: [.capsuleProtocol: "?1"])
        #endif
        }
    }
}

extension HTTPField.Name {
    static var capsuleProtocol: Self {
        Self("Capsule-Protocol")!
    }
}

#endif  // HTTP3 && UnstableHTTPDatagrams
