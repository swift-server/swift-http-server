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

/// A configuration error arising from an invalid ``NIOHTTPServerConfiguration``.
enum NIOHTTPServerConfigurationError: Error, CustomStringConvertible {
    case noSupportedHTTPVersionsSpecified
    case incompatibleTransportSecurity
    case noBindTargetsSpecified
    case onlyPEMFileCredentialsCurrentlySupportedOverHTTP3
    // swift-nio-quic doesn't currently support mTLS. See https://github.com/apple/swift-nio-quic/issues/5.
    case mTLSNotCurrentlySupportedOverHTTP3

    var description: String {
        switch self {
        case .noSupportedHTTPVersionsSpecified:
            "Invalid configuration: at least one supported HTTP version must be specified."

        case .incompatibleTransportSecurity:
            "Invalid configuration: only HTTP/1.1 can be served over plaintext. `transportSecurity` must be set to (m)TLS for serving HTTP/2 or HTTP/3."

        case .noBindTargetsSpecified:
            "Invalid configuration: at least one bind target must be specified."

        case .onlyPEMFileCredentialsCurrentlySupportedOverHTTP3:
            "Invalid configuration: only PEM-file X.509 credentials are supported over HTTP/3. In-memory or reloading credential sources are not currently supported."

        case .mTLSNotCurrentlySupportedOverHTTP3:
            "Invalid configuration: mTLS is not currently supported over HTTP/3."
        }
    }
}
