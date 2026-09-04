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
import Crypto
import ExampleSupport
import Foundation
import Logging
import NIOHTTP2
import NIOHTTPServer
import X509

#if HTTP3
import HTTP3
#endif

/// A failure that stands in for a proxy being unable to establish its upstream tunnel.
///
/// Conforming to the stream-reset protocols chooses the error codes the server puts on the wire when this error is
/// thrown. The protocols take the plain numeric values from the HTTP specifications so that they carry no dependency of
/// their own; a conformance is free to derive those values from whichever code types it already has, as this one does
/// from NIO's.
struct TunnelFailure: Error {
    let reason: String
}

extension TunnelFailure: HTTPServerHTTP2StreamResetErrorConvertible {
    /// `CONNECT_ERROR` (RFC 9113 § 7): the TCP connection behind a `CONNECT` request failed.
    var http2StreamResetCode: UInt32 { UInt32(HTTP2ErrorCode.connectError.networkCode) }
}

#if HTTP3
extension TunnelFailure: HTTPServerHTTP3StreamResetErrorConvertible {
    /// `H3_CONNECT_ERROR` (RFC 9114 § 8.1), the HTTP/3 counterpart of `CONNECT_ERROR`.
    var http3StreamResetCode: UInt64 { HTTPTypes.HTTP3ErrorCode.connectError.rawValue }

    /// The server is no longer reading the request body, so ask the client to stop sending it.
    var http3StopSendingCode: UInt64 { HTTPTypes.HTTP3ErrorCode.connectError.rawValue }
}
#endif

/// A failure with no stream-reset conformance, to show the fallback.
struct UnexpectedFailure: Error {}

@main
@available(anyAppleOS 26.0, *)
struct StreamResetExample {
    static func main() async throws {
        try await serve()
    }

    @concurrent
    static func serve() async throws {
        var rootLogger = Logger(label: "StreamResetExample")
        rootLogger.logLevel = .trace

        try await withLogger(rootLogger) { rootLogger in
            let server = NIOHTTPServer(
                logger: rootLogger,
                configuration: try .init(
                    bindTarget: .hostAndPort(host: "127.0.0.1", port: 12345),
                    supportedHTTPVersions: [.http1_1, .http2(config: .init())],
                    transportSecurity: .tls(credentials: try .selfSigned())
                )
            )

            try await server.serve { request, requestContext, reader, responseSender in
                switch request.path {
                case "/tunnel":
                    throw TunnelFailure(reason: "upstream refused the connection")

                case "/boom":
                    throw UnexpectedFailure()

                default:
                    var body = UniqueArray<UInt8>(copying: "Try /tunnel or /boom".utf8)
                    try await responseSender.sendAndFinish(
                        HTTPResponse(status: .ok, headerFields: [.contentType: "text/plain"]),
                        buffer: &body
                    )
                }
            }
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.TransportSecurity.TLSCredentials {
    /// A throwaway self-signed certificate, so the example needs no files on disk.
    fileprivate static func selfSigned() throws -> Self {
        let privateKey = P256.Signing.PrivateKey()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: .init(bytes: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]),
            publicKey: .init(privateKey.publicKey),
            notValidBefore: Date.now.addingTimeInterval(-60),
            notValidAfter: Date.now.addingTimeInterval(60 * 60),
            issuer: DistinguishedName(),
            subject: DistinguishedName(),
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: .init(),
            issuerPrivateKey: Certificate.PrivateKey(privateKey)
        )

        return .x509(
            .certificates(chain: [certificate], privateKey: Certificate.PrivateKey(privateKey))
        )
    }
}
