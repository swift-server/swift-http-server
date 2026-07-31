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

    var disconnectedResponseSender = Disconnected(value: Optional(responseSender))

    try await reader.withDatagramReader { streamReader, maybeDatagramReader in
        let responseSender = disconnectedResponseSender.swap(newValue: nil)!

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

        var streamReader = streamReader
        try await streamReader.read { buffer, _ in
            for index in buffer.indices { pendingToTarget.append(buffer[index]) }
        }

        try await datagramReader.read { buffer, _ in
            for index in buffer.indices { pendingToTarget.append(buffer[index]) }
        }

        // Hold the readers until the tunnel is established.
        var disconnectedStreamReader = Disconnected(value: Optional(streamReader))
        var disconnectedDatagramReader = Disconnected(value: Optional(datagramReader))

        // Now accept the request and access the datagram writer through the response writer.
        let writer = try await responseSender.send(ConnectUDPHelper.makeSuccessResponse(version: context.httpVersion))
        try await writer.withDatagramWriter { streamWriter, datagramWriter in
            var disconnectedStreamWriter = Disconnected(value: Optional(streamWriter))
            var disconnectedDatagramWriter = Disconnected(value: datagramWriter)

            await withThrowingTaskGroup { group in
                var unwrappedStreamWriter = disconnectedStreamWriter.swap(newValue: nil)!
                var unwrappedStreamReader = disconnectedStreamReader.swap(newValue: nil)!

                // Write to the reliable stream.
                group.addTask {
                    var emptyBuffer = UniqueArray<UInt8>()
                    try await unwrappedStreamWriter.write(buffer: &emptyBuffer)
                }

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

                if var unwrappedDatagramReader = disconnectedDatagramReader.swap(newValue: nil) {
                    // Read from the unreliable stream.
                    group.addTask {
                        try await unwrappedDatagramReader.read { _, _ in
                            ()
                        }
                    }
                }
            }
        }
    }
}

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
