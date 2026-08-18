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

/// An error that maps to the `RST_STREAM` error code sent when an HTTP/2 request is aborted.
///
/// A request handler reports a failure by throwing. The server does not surface that error to any caller: instead it
/// aborts the exchange on the wire, which over HTTP/2 means resetting the request's stream. Conform an error to this
/// protocol to choose the error code carried by that `RST_STREAM` frame.
///
/// An error that does not conform is reset with `INTERNAL_ERROR` (`0x02`).
///
/// ## Example
///
/// A proxy that fails to establish a tunnel reports it as a `CONNECT` error:
///
/// ```swift
/// struct TunnelFailure: HTTPServerHTTP2StreamResetErrorConvertible {
///     var http2StreamResetCode: UInt32 { 0x0a }  // CONNECT_ERROR
/// }
///
/// try await server.serve { request, context, reader, responseSender in
///     guard let tunnel = try? await openTunnel(to: request.authority) else {
///         throw TunnelFailure()
///     }
///     // ...
/// }
/// ```
public protocol HTTPServerHTTP2StreamResetErrorConvertible: Error {
    /// The `RST_STREAM` error code to send, as its numeric value on the wire.
    ///
    /// The codes and their values are defined by RFC 9113 § 7 — for example `0x08` for `CANCEL`, `0x0a` for
    /// `CONNECT_ERROR`, or `0x02` for `INTERNAL_ERROR`.
    ///
    /// This code is used only when the request is served over HTTP/2.
    var http2StreamResetCode: UInt32 { get }
}
