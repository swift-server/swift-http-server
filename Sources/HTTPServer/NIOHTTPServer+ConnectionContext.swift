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

import NIOCore
import NIOSSL
public import X509

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension NIOHTTPServer {
    /// Connection-specific information available during request handling.
    ///
    /// Provides access to data such as the peer's validated certificate chain.
    public struct ConnectionContext: Sendable {
        var peerCertificateChainFuture: EventLoopFuture<NIOSSL.ValidatedCertificateChain?>?

        init(_ peerCertificateChainFuture: EventLoopFuture<NIOSSL.ValidatedCertificateChain?>? = nil) {
            self.peerCertificateChainFuture = peerCertificateChainFuture
        }

        /// The peer's validated certificate chain. This returns `nil` if a custom verification callback was not set
        /// when configuring mTLS in the server configuration, or if the custom verification callback did not return the
        /// derived validated chain.
        public var peerCertificateChain: X509.ValidatedCertificateChain? {
            get async throws {
                if let certs = try await self.peerCertificateChainFuture?.get() {
                    return .init(uncheckedCertificateChain: try certs.map { try Certificate($0) })
                }
                return nil
            }
        }
    }
}
