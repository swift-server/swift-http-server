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

public import NIOHTTP2

/// An error that chooses the `RST_STREAM` error code sent when an HTTP/2 request is aborted.
///
/// A request handler reports a failure by throwing. The thrown error is not surfaced to any caller: it aborts the
/// exchange carrying the request, which over HTTP/2 means resetting the request's stream. Conform an error to this
/// protocol to choose the error code carried by that `RST_STREAM` frame.
///
/// ## Example
///
/// A proxy that fails to establish a tunnel reports it as a `CONNECT` error:
///
/// ```swift
/// struct TunnelFailure: NIOHTTPServerHTTP2StreamResetError {
///     var http2StreamResetCode: HTTP2ErrorCode { .connectError }
/// }
///
/// try await server.serve { request, context, reader, responseSender in
///     guard let tunnel = try? await openTunnel(to: request.authority) else {
///         throw TunnelFailure()
///     }
///     // ...
/// }
/// ```
public protocol NIOHTTPServerHTTP2StreamResetError: Error {
    /// The `RST_STREAM` error code to send.
    ///
    /// The available codes are defined by RFC 9113 § 7. This code is used only when the request is served over HTTP/2.
    var http2StreamResetCode: HTTP2ErrorCode { get }
}
