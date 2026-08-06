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

import NIOHTTPServer

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer.HTTPVersion {
    /// The ALPN protocol identifier.
    ///
    /// - SeeAlso: https://www.iana.org/assignments/tls-extensiontype-values/tls-extensiontype-values.xhtml#alpn-protocol-ids
    var alpnIdentifier: String {
        switch self {
        case .plaintextHTTP1_1:
            fatalError("Not applicable")

        case .http1_1:
            "http/1.1"

        case .http2:
            "h2"

        #if HTTP3
        case .http3:
            "h3"
        #endif
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.HTTPVersion {
    init(_ version: NIOHTTPServer.HTTPVersion) {
        switch version {
        case .plaintextHTTP1_1, .http1_1:
            self = .http1_1

        case .http2:
            self = .http2

        #if HTTP3
        case .http3:
            self = .http3
        #endif
        }
    }
}
