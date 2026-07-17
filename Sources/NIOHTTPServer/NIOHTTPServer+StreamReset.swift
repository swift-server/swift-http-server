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
public import NIOHTTP2
import NIOHTTPTypes
import NIOHTTPTypesHTTP2

#if HTTP3
import NIOQUICHelpers
#endif  // HTTP3

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// The protocol-specific surface for resetting the stream carrying a request.
    ///
    /// Stream resets only exists over HTTP/2 and HTTP/3. The only abrupt tear-down mechanism available
    /// for HTTP/1.1 is closing the connection.
    @nonexhaustive
    public enum StreamReset: ~Copyable {
        /// The protocol has no per-stream coded reset (for example HTTP/1.1).
        ///
        /// There is nothing to reset with a code here. Returning from the handler without concluding the response
        /// aborts the exchange and the connection is closed.
        case unavailable

        /// The connection is HTTP/2; ``HTTP2StreamReset`` sends a `RST_STREAM`.
        case http2(HTTP2StreamReset)

        #if HTTP3
        /// The connection is HTTP/3; ``HTTP3StreamReset`` sends a QUIC `RESET_STREAM`.
        case http3(HTTP3StreamReset)
        #endif  // HTTP3
    }

    /// Resets an HTTP/2 stream by sending a `RST_STREAM` frame with a chosen error code.
    public struct HTTP2StreamReset: ~Copyable {
        private let channel: any Channel

        init(channel: any Channel) {
            self.channel = channel
        }

        /// Sends a `RST_STREAM` frame for this stream with the provided error code.
        ///
        /// - Parameter code: The `RST_STREAM` error code to send.
        public consuming func reset(code: HTTP2ErrorCode) {
            // The `HTTP2FramePayloadToHTTPServerCodec` on the stream channel translates this event into an `RST_STREAM`
            // frame.
            self.channel.triggerUserOutboundEvent(
                NIOHTTP2FramePayloadToHTTPEvent.reset(code: code),
                promise: nil
            )
        }
    }

    #if HTTP3
    /// Resets an HTTP/3 stream by sending a QUIC `RESET_STREAM` frame with a chosen error code.
    public struct HTTP3StreamReset: ~Copyable {
        private let channel: any Channel

        init(channel: any Channel) {
            self.channel = channel
        }

        /// Sends a QUIC `RESET_STREAM` frame for this stream with the provided error code.
        ///
        /// - Parameter code: The QUIC application error code to send. It must be a valid application error code that is
        ///   less than 2^62 (the maximum QUIC variable-length integer value). If the code is out of range, the stream
        ///   is not reset.
        public consuming func reset(code: UInt64) {
            guard let resetCode = QUICApplicationErrorCode(code) else { return }

            self.channel.triggerUserOutboundEvent(QUICResetStreamEvent(code: resetCode), promise: nil)
        }
    }
    #endif  // HTTP3
}

@available(*, unavailable)
extension NIOHTTPServer.StreamReset: Sendable {}

@available(*, unavailable)
extension NIOHTTPServer.HTTP2StreamReset: Sendable {}

#if HTTP3
@available(*, unavailable)
extension NIOHTTPServer.HTTP3StreamReset: Sendable {}
#endif  // HTTP3
