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

import NIOCore
import NIOHTTP2
import NIOHTTPTypes
import NIOHTTPTypesHTTP2

#if HTTP3
import HTTP3
import NIOQUICHelpers
#endif

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// Aborts the exchange carrying a request on the wire, after that request's handler threw `error`.
    ///
    /// Which mechanism applies depends on the protocol serving the request:
    /// - HTTP/1.1 has no stream to reset, so the response is abandoned and the connection is closed: a decision delegated to
    /// ``HTTPKeepAliveHandler``, which already tracks how far the response has progressed and owns the
    /// `Connection: close` handling.
    /// - HTTP/2 and HTTP/3 reset the request's own stream, with the error codes `error` describes.
    /// - HTTP/3 also asks the client to STOP_SENDING.
    static func abortRequest(requestContext: RequestContext, error: any Error) {
        let channel = requestContext.channel

        switch requestContext.connectionContext.httpVersion {
        case .plaintextHTTP1_1, .http1_1:
            var response = HTTPResponse(status: .internalServerError)
            response.headerFields[.contentLength] = "0"
            channel.triggerUserOutboundEvent(
                HTTPKeepAliveHandler.RequestAborted(responseIfNotStarted: response),
                promise: nil
            )

        case .http2:
            // An error that does not describe its own code is reset with `INTERNAL_ERROR`.
            let resetCode =
                (error as? any HTTPServerHTTP2StreamResetErrorConvertible)
                .map { HTTP2ErrorCode(networkCode: Int($0.http2StreamResetCode)) } ?? .internalError

            // `HTTP2FramePayloadToHTTPServerCodec` translates this event into a `RST_STREAM` frame.
            channel.triggerUserOutboundEvent(
                NIOHTTP2FramePayloadToHTTPEvent.reset(code: resetCode),
                promise: nil
            )

        #if HTTP3
        case .http3:
            let http3Error = error as? any HTTPServerHTTP3StreamResetErrorConvertible
            let resetCode = Self.quicErrorCode(http3Error?.http3StreamResetCode)
            let stopSendingCode = Self.quicErrorCode(http3Error?.http3StopSendingCode)

            // `RESET_STREAM` abandons the response direction and `STOP_SENDING` asks the client to
            // stop sending the request body.
            channel.triggerUserOutboundEvent(QUICResetStreamEvent(code: resetCode), promise: nil)
            channel.triggerUserOutboundEvent(QUICStopSendingEvent(code: stopSendingCode), promise: nil)
        #endif
        }
    }

    #if HTTP3
    /// Converts a raw HTTP/3 error code into a QUIC application error code.
    ///
    /// Substitutes `H3_INTERNAL_ERROR` when the error described no code, or described one that cannot be represented as
    /// a QUIC variable-length integer.
    private static func quicErrorCode(_ rawValue: UInt64?) -> QUICApplicationErrorCode {
        // The force unwrap is safe: `H3_INTERNAL_ERROR` (0x0102) is always representable as a QUIC varint.
        rawValue.flatMap(QUICApplicationErrorCode.init)
            ?? QUICApplicationErrorCode(HTTP3ErrorCode.internalError.rawValue)!
    }
    #endif
}
