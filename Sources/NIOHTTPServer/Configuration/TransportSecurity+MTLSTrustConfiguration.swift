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

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension NIOHTTPServerConfiguration.TransportSecurity {
    /// Configures how the server verifies client certificates during mTLS.
    public struct MTLSTrustConfiguration: Sendable {
        enum Backing {
            case systemDefaults
            case inMemory(trustRoots: [Certificate])
            case pemFile(path: String)
            case customCertificateVerificationCallback(
                @Sendable ([X509.Certificate]) async throws -> CertificateVerificationResult
            )
        }

        let backing: Backing
        let certificateVerification: CertificateVerificationMode

        /// Verifies client certificates against the operating system's default trust store.
        ///
        /// - Parameter certificateVerification: The client certificate verification behavior. Defaults to
        ///   ``CertificateVerificationMode/noHostnameVerification``.
        public static func systemDefaults(
            certificateVerification: CertificateVerificationMode = .noHostnameVerification
        ) -> Self {
            Self(backing: .systemDefaults, certificateVerification: certificateVerification)
        }

        /// Verifies client certificates against the provided in-memory trust roots.
        ///
        /// - Parameters:
        ///   - trustRoots: The root certificates to trust when verifying client certificates.
        ///   - certificateVerification: The client certificate verification behavior. Defaults to
        ///     ``CertificateVerificationMode/noHostnameVerification``.
        public static func inMemory(
            trustRoots: [Certificate],
            certificateVerification: CertificateVerificationMode = .noHostnameVerification
        ) -> Self {
            Self(
                backing: .inMemory(trustRoots: trustRoots),
                certificateVerification: certificateVerification
            )
        }

        /// Verifies client certificates against trust roots loaded from a PEM-encoded file.
        ///
        /// - Parameters:
        ///   - path: The file path to the PEM-encoded trust root certificates.
        ///   - certificateVerification: The client certificate verification behavior. Defaults to
        ///     ``CertificateVerificationMode/noHostnameVerification``.
        public static func pemFile(
            path: String,
            certificateVerification: CertificateVerificationMode = .noHostnameVerification
        ) -> Self {
            Self(
                backing: .pemFile(path: path),
                certificateVerification: certificateVerification
            )
        }

        /// Uses a custom callback to verify client certificates, overriding the default NIOSSL verification logic.
        ///
        /// - Parameters:
        ///   - callback: This callback *overrides* the default NIOSSL client certificate verification logic. The
        ///     callback receives the certificates presented by the peer. Within the callback, you must validate these
        ///     certificates against your trust roots and derive a validated chain of trust per
        ///     [RFC 4158](https://datatracker.ietf.org/doc/html/rfc4158). Return
        ///     ``CertificateVerificationResult/certificateVerified(_:)`` from the callback if verification succeeds,
        ///     optionally including the validated certificate chain you derived. Returning the validated certificate
        ///     chain allows ``NIOHTTPServer`` to provide access to it in the request handler through
        ///     ``NIOHTTPServer/ConnectionContext/peerCertificateChain``, accessed via the task-local
        ///     ``NIOHTTPServer/connectionContext`` property. Otherwise, return
        ///     ``CertificateVerificationResult/failed(_:)`` if verification fails.
        ///   - certificateVerification: The client certificate verification behavior. Defaults to
        ///     ``CertificateVerificationMode/noHostnameVerification``.
        ///
        /// - Warning: The provided `callback` will override NIOSSL's default certificate verification logic.
        public static func customCertificateVerificationCallback(
            _ callback: @escaping @Sendable ([X509.Certificate]) async throws -> CertificateVerificationResult,
            certificateVerification: CertificateVerificationMode = .noHostnameVerification
        ) -> Self {
            Self(
                backing: .customCertificateVerificationCallback(callback),
                certificateVerification: certificateVerification
            )
        }
    }
}
