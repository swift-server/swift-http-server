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

public import NIOCertificateReloading
public import X509

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension NIOHTTPServerConfiguration.TransportSecurity {
    /// Represents the server's TLS credentials: a certificate chain and its corresponding private key.
    ///
    /// Credentials can be provided as in-memory objects, loaded from PEM files on disk, or automatically reloaded at
    /// runtime using a `CertificateReloader`.
    public struct TLSCredentials: Sendable {
        enum Backing {
            case inMemory(certificateChain: [Certificate], privateKey: Certificate.PrivateKey)
            case reloading(certificateReloader: any CertificateReloader)
            case pemFile(certificateChainPath: String, privateKeyPath: String)
        }

        let backing: Backing

        /// Credentials from in-memory certificate objects.
        ///
        /// - Parameters:
        ///   - certificateChain: The certificate chain to present during the TLS handshake.
        ///   - privateKey: The private key corresponding to the leaf certificate in `certificateChain`.
        public static func inMemory(certificateChain: [Certificate], privateKey: Certificate.PrivateKey) -> Self {
            Self(backing: .inMemory(certificateChain: certificateChain, privateKey: privateKey))
        }

        /// Credentials backed by a `CertificateReloader` that periodically refreshes the certificate chain and
        /// private key.
        ///
        /// - Parameter certificateReloader: The reloader responsible for refreshing the credentials.
        public static func reloading(certificateReloader: any CertificateReloader) -> Self {
            Self(backing: .reloading(certificateReloader: certificateReloader))
        }

        /// Credentials loaded from PEM-encoded files on disk.
        ///
        /// - Parameters:
        ///   - certificateChainPath: The file path to the PEM-encoded certificate chain.
        ///   - privateKeyPath: The file path to the PEM-encoded private key, corresponding to the leaf certificate in
        ///     `certificateChainPath`.
        public static func pemFile(certificateChainPath: String, privateKeyPath: String) -> Self {
            Self(backing: .pemFile(certificateChainPath: certificateChainPath, privateKeyPath: privateKeyPath))
        }
    }
}
