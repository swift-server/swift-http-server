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
/// An error that maps to the error codes sent when an HTTP/3 request is aborted.
///
/// A request handler reports a failure by throwing. The server does not surface that error to any caller: instead it
/// aborts the exchange on the wire, which over HTTP/3 means resetting the request's stream and asking the client to
/// stop sending the request body. Conform an error to this protocol to choose the error codes carried by those frames.
///
/// An error that does not conform is reset with `H3_INTERNAL_ERROR` (`0x0102`).
///
/// ## Example
///
/// A proxy that fails to establish a tunnel reports it as a `CONNECT` error:
///
/// ```swift
/// struct TunnelFailure: HTTPServerHTTP3StreamResetErrorConvertible {
///     var http3StreamResetCode: UInt64 { 0x010f }   // H3_CONNECT_ERROR
///     var http3StopSendingCode: UInt64 { 0x010f }   // H3_CONNECT_ERROR
/// }
///
/// try await server.serve { request, context, reader, responseSender in
///     guard let tunnel = try? await openTunnel(to: request.authority) else {
///         throw TunnelFailure()
///     }
///     // ...
/// }
/// ```
public protocol HTTPServerHTTP3StreamResetErrorConvertible: Error {
    /// The application error code to send when abandoning the response, as its numeric value on the wire.
    ///
    /// The codes and their values are defined by RFC 9114 § 8.1 — for example `0x010f` for `H3_CONNECT_ERROR`,
    /// `0x010c` for `H3_REQUEST_CANCELLED`, or `0x0102` for `H3_INTERNAL_ERROR`.
    ///
    /// The value must be less than 2^62, the largest value the transport can encode; an out-of-range value is replaced
    /// with `H3_INTERNAL_ERROR`. This code is used only when the request is served over HTTP/3.
    var http3StreamResetCode: UInt64 { get }

    /// The application error code to send when asking the client to stop sending the request body that the server is no
    /// longer reading, as its numeric value on the wire.
    ///
    /// The same code space and range restriction as ``http3StreamResetCode`` applies.
    var http3StopSendingCode: UInt64 { get }
}
#endif
