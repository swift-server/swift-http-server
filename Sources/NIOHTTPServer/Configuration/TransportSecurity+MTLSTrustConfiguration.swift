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

import NIOCore
import NIOSSL
public import X509

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.TransportSecurity {
    /// Configures how the server verifies client certificates during mTLS.
    public struct MTLSTrustConfiguration: Sendable {
        enum SerializedTrustRoots: Sendable {
            case file(trustRootsPath: String, format: Encoding)
            case bytes(trustRoots: [UInt8], format: Encoding)
        }

        let source: TrustSource
        let certificateVerification: CertificateVerificationMode

        /// Creates an mTLS trust configuration from a trust source and a certificate verification behavior.
        ///
        /// - Parameters:
        ///   - source: The trust roots, or the custom verification callback, used to verify the certificates presented
        ///     by the client.
        ///   - certificateVerification: The client certificate verification behavior. Defaults to
        ///   ``CertificateVerificationMode/noHostnameVerification``.
        public init(
            _ source: TrustSource,
            certificateVerification: CertificateVerificationMode = .noHostnameVerification
        ) {
            self.source = source
            self.certificateVerification = certificateVerification
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.TransportSecurity.MTLSTrustConfiguration {
    public struct TrustSource: Sendable {
        enum Backing {
            case systemDefaults
            case certificates(trustRoots: [Certificate])
            case serialized(SerializedTrustRoots)
            case customCertificateVerificationCallback(
                @Sendable ([X509.Certificate]) async throws -> CertificateVerificationResult
            )
        }

        let backing: Backing

        /// Verifies client certificates against the operating system's default trust store.
        public static var systemDefaults: Self {
            Self(backing: .systemDefaults)
        }

        /// Verifies client certificates against the provided in-memory trust roots.
        public static func certificates(trustRoots: [Certificate]) -> Self {
            Self(backing: .certificates(trustRoots: trustRoots))
        }

        /// Verifies client certificates against trust roots loaded from a PEM-encoded file.
        ///
        /// - Parameter trustRootsPath: The file path to the PEM-encoded trust root certificates.
        public static func pemFile(trustRootsPath: String) -> Self {
            Self(backing: .serialized(.file(trustRootsPath: trustRootsPath, format: .pem)))
        }

        /// Verifies client certificates against trust roots provided as PEM-encoded bytes.
        ///
        /// - Parameter trustRoots: The PEM-encoded bytes of the trust root certificates.
        public static func pemBytes(trustRoots: [UInt8]) -> Self {
            Self(backing: .serialized(.bytes(trustRoots: trustRoots, format: .pem)))
        }

        /// Verifies client certificates against trust roots loaded from a DER-encoded file.
        ///
        /// - Note: Only a single certificate can be encoded in the DER format.
        ///
        /// - Parameter trustRootPath: The file path to the DER-encoded trust root certificate.
        public static func derFile(trustRootPath: String) -> Self {
            Self(backing: .serialized(.file(trustRootsPath: trustRootPath, format: .der)))
        }

        /// Verifies client certificates against a trust root provided as DER-encoded bytes.
        ///
        /// - Note: Only a single certificate can be encoded in the DER format.
        ///
        /// - Parameter trustRoot: The DER-encoded bytes of the trust root certificate.
        public static func derBytes(trustRoot: [UInt8]) -> Self {
            Self(backing: .serialized(.bytes(trustRoots: trustRoot, format: .der)))
        }

        /// Uses a custom callback to verify client certificates, overriding the default NIOSSL verification logic.
        ///
        /// - Parameter callback: This callback *overrides* the default NIOSSL client certificate verification logic. The
        ///   callback receives the certificates presented by the peer. Within the callback, you must validate these
        ///   certificates against your trust roots and derive a validated chain of trust per
        ///   [RFC 4158](https://datatracker.ietf.org/doc/html/rfc4158). Return
        ///   ``CertificateVerificationResult/certificateVerified(_:)`` from the callback if verification succeeds,
        ///   optionally including the validated certificate chain you derived. Returning the validated certificate
        ///   chain allows ``NIOHTTPServer`` to provide access to it in the request handler through
        ///   ``NIOHTTPServer/RequestContext/peerCertificateChain``. Otherwise, return
        ///   ``CertificateVerificationResult/failed(_:)`` if verification fails.
        ///
        /// - Warning: The provided `callback` will override NIOSSL's default certificate verification logic.
        public static func customCertificateVerificationCallback(
            _ callback: @escaping @Sendable ([X509.Certificate]) async throws -> CertificateVerificationResult
        ) -> Self {
            Self(backing: .customCertificateVerificationCallback(callback))
        }
    }
}
