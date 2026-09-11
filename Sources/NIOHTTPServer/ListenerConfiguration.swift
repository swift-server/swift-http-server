//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOSSL

#if HTTP3
import NIOQUIC
#endif

/// The listeners to bind, derived from the server configuration.
@available(anyAppleOS 26.0, *)
enum ListenerConfiguration: Sendable {
    struct SecureUpgrade: Sendable {
        let sslContext: NIOSSLContext
        let http2Configuration: NIOHTTPServerConfiguration.HTTP2?
    }

    #if HTTP3
    struct HTTP3: Sendable {
        let http3Configuration: NIOHTTPServerConfiguration.HTTP3
        let authenticationConfiguration: NIOQUIC.AuthenticationConfiguration
        let quicAuthenticator: NIOQUIC.Authenticator?
    }
    #endif

    case plaintextHTTP1_1
    case secureUpgrade(SecureUpgrade)
    #if HTTP3
    case http3(HTTP3)
    case secureUpgradeAndHTTP3(SecureUpgrade, HTTP3)
    #endif
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration {
    func makeListenerConfiguration() -> ListenerConfiguration {
        let secureUpgrade = self.sslContext.map {
            ListenerConfiguration.SecureUpgrade(
                sslContext: $0,
                http2Configuration: self.supportedHTTPVersions.http2ConfigIfSupported
            )
        }

        #if HTTP3
        if let http3Configuration = self.supportedHTTPVersions.http3ConfigIfSupported,
            let authenticationConfiguration = self.quicAuthenticationConfiguration
        {
            let http3 = ListenerConfiguration.HTTP3(
                http3Configuration: http3Configuration,
                authenticationConfiguration: authenticationConfiguration,
                quicAuthenticator: self.quicAuthenticator
            )

            if let secureUpgrade {
                return .secureUpgradeAndHTTP3(secureUpgrade, http3)
            } else {
                return .http3(http3)
            }
        }
        #endif  // HTTP3

        if let secureUpgrade {
            return .secureUpgrade(secureUpgrade)
        }

        return .plaintextHTTP1_1
    }
}
