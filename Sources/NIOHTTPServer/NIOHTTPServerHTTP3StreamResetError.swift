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

#if HTTP3
public import HTTP3

/// An error that chooses the error codes sent when an HTTP/3 request is aborted.
///
/// A request handler reports a failure by throwing. The thrown error is not surfaced to any caller: it aborts the
/// exchange carrying the request, which over HTTP/3 means resetting the request's stream and asking the client to stop
/// sending the request body. Conform an error to this protocol to choose the error codes carried by those two frames.
///
/// ## Example
///
/// A proxy that fails to establish a tunnel reports it as a `CONNECT` error:
///
/// ```swift
/// struct TunnelFailure: NIOHTTPServerHTTP3StreamResetError {
///     var http3StreamResetCode: HTTP3ErrorCode { .connectError }
///     var http3StopSendingCode: HTTP3ErrorCode { .connectError }
/// }
///
/// try await server.serve { request, context, reader, responseSender in
///     guard let tunnel = try? await openTunnel(to: request.authority) else {
///         throw TunnelFailure()
///     }
///     // ...
/// }
/// ```
public protocol NIOHTTPServerHTTP3StreamResetError: Error {
    /// The application error code to send in a QUIC `RESET_STREAM` frame, abandoning the response.
    ///
    /// The available codes are defined by RFC 9114 § 8.1. This code is used only when the request is served over
    /// HTTP/3.
    var http3StreamResetCode: HTTP3ErrorCode { get }

    /// The application error code to send in a QUIC `STOP_SENDING` frame, asking the client to stop sending the request
    /// body that the server is no longer reading.
    ///
    /// The available codes are defined by RFC 9114 § 8.1. This code is used only when the request is served over
    /// HTTP/3.
    var http3StopSendingCode: HTTP3ErrorCode { get }
}
#endif
