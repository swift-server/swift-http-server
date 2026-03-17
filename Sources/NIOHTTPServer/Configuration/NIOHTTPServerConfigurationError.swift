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

    var description: String {
        switch self {
        case .noSupportedHTTPVersionsSpecified:
            "Invalid configuration: at least one supported HTTP version must be specified."

        case .incompatibleTransportSecurity:
            "Invalid configuration: only HTTP/1.1 can be served over plaintext. `transportSecurity` must be set to (m)TLS for serving HTTP/2."
        }
    }
}
