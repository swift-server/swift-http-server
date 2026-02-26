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

enum HTTPVersion {
    case http1_1
    case http2

    /// The ALPN protocol identifier.
    ///
    /// - SeeAlso: https://www.iana.org/assignments/tls-extensiontype-values/tls-extensiontype-values.xhtml#alpn-protocol-ids
    var alpnIdentifier: String {
        switch self {
        case .http1_1:
            "http/1.1"
        case .http2:
            "h2"
        }
    }
}
