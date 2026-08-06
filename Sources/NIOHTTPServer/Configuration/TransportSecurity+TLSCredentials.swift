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

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.TransportSecurity {
    /// Represents the credentials the server uses to prove its identity during the TLS handshake.
    ///
    /// - Important: Raw public key credentials are only supported when serving over HTTP/3.
    public struct TLSCredentials: Sendable {
        enum Backing: Sendable {
            case x509(X509Credentials)
            #if HTTP3
            case rawPublicKey(RawPublicKeyCredentials)
            #endif
        }

        let backing: Backing

        /// X.509 credentials.
        ///
        /// - Parameter credentials: The X.509 certificate chain and the associated private key.
        public static func x509(_ credentials: X509Credentials) -> Self {
            Self(backing: .x509(credentials))
        }

        #if HTTP3
        /// Raw public key credentials.
        ///
        /// - Parameter credentials: The raw public key and the associated private key.
        ///
        /// - Important: Raw public key credentials are only supported when serving over HTTP/3.
        ///
        /// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc7250
        public static func rawPublicKey(_ credentials: RawPublicKeyCredentials) -> Self {
            Self(backing: .rawPublicKey(credentials))
        }
        #endif
    }

    /// The encoding format.
    enum Encoding: Sendable {
        case pem
        case der
    }

    /// The X.509 credentials the server presents during the TLS handshake.
    ///
    /// The credentials can be provided in any of the following ways:
    /// - As in-memory `X509.Certificate` and `X509.Certificate.PrivateKey` objects (``certificates(chain:privateKey:)``);
    /// - From files (``pemFile(certificateChainPath:privateKeyPath:)``, ``derFile(certificatePath:privateKeyPath:)``) or bytes
    ///   (``pemBytes(certificateChain:privateKey:)``, ``derBytes(certificate:privateKey:)``), or;
    /// - Through a `CertificateReloader` instance that periodically reloads the credentials (``reloading(_:)``).
    public struct X509Credentials: Sendable {
        enum SerializedCredentials: Sendable {
            case file(certificateChainPath: String, privateKeyPath: String, format: Encoding)
            case bytes(certificateChain: [UInt8], privateKey: [UInt8], format: Encoding)
        }

        enum Backing: Sendable {
            case certificates(chain: [Certificate], privateKey: Certificate.PrivateKey)
            case reloading(any CertificateReloader)
            case serialized(SerializedCredentials)
        }

        let backing: Backing

        /// X.509 credentials provided as in-memory `[X509.Certificate]` and `X509.Certificate.PrivateKey` objects.
        ///
        /// - Parameters:
        ///   - chain: The certificate chain to present during the TLS handshake.
        ///   - privateKey: The private key for the leaf certificate in `certificateChain`.
        public static func certificates(chain: [Certificate], privateKey: Certificate.PrivateKey) -> Self {
            Self(backing: .certificates(chain: chain, privateKey: privateKey))
        }

        /// X.509 credentials provided via a `CertificateReloader` instance.
        ///
        /// - Parameter reloader: The reloader that supplies and refreshes the credentials.
        public static func reloading(_ reloader: any CertificateReloader) -> Self {
            Self(backing: .reloading(reloader))
        }

        /// X.509 credentials provided as paths to PEM-encoded files on disk.
        ///
        /// - Parameters:
        ///   - certificateChainPath: The path to the PEM-encoded certificate chain.
        ///   - privateKeyPath: The path to the PEM-encoded private key of the leaf certificate in `certificateChain`.
        public static func pemFile(certificateChainPath: String, privateKeyPath: String) -> Self {
            Self(
                backing: .serialized(
                    .file(certificateChainPath: certificateChainPath, privateKeyPath: privateKeyPath, format: .pem)
                )
            )
        }

        /// X.509 credentials provided as PEM-encoded bytes.
        ///
        /// - Parameters:
        ///   - certificateChain: The PEM-encoded bytes representing the certificate chain.
        ///   - privateKey: The PEM-encoded bytes representing the private key of the leaf certificate in
        ///     `certificateChain`.
        public static func pemBytes(certificateChain: [UInt8], privateKey: [UInt8]) -> Self {
            Self(backing: .serialized(.bytes(certificateChain: certificateChain, privateKey: privateKey, format: .pem)))
        }

        /// X.509 credentials provided as paths to DER-encoded files on disk.
        ///
        /// - Parameters:
        ///   - certificatePath: The path to the DER-encoded certificate.
        ///   - privateKeyPath: The path to the DER-encoded private key of `certificate`.
        public static func derFile(certificatePath: String, privateKeyPath: String) -> Self {
            Self(
                backing: .serialized(
                    .file(certificateChainPath: certificatePath, privateKeyPath: privateKeyPath, format: .der)
                )
            )
        }

        /// X.509 credentials provided as DER-encoded bytes.
        ///
        /// - Parameters:
        ///   - certificate: The DER-encoded bytes representing the certificate.
        ///   - privateKey: The DER-encoded bytes representing the private key of the `certificate`.
        public static func derBytes(certificate: [UInt8], privateKey: [UInt8]) -> Self {
            Self(backing: .serialized(.bytes(certificateChain: certificate, privateKey: privateKey, format: .der)))
        }
    }

    #if HTTP3
    /// The raw public key credentials (RFC 7250) the server presents during the TLS handshake.
    ///
    /// - Important: Raw public key credentials are currently supported only when the server is configured to serve
    ///   HTTP/3 exclusively.
    ///
    /// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc7250
    public struct RawPublicKeyCredentials: Sendable {
        enum Backing: Sendable {
            case file(publicKeyPath: String, privateKeyPath: String, format: Encoding)
        }

        let backing: Backing

        /// Raw public key credentials provided as paths to DER-encoded files on disk.
        ///
        /// - Parameters:
        ///   - publicKeyPath: The path to the DER-encoded public key.
        ///   - privateKeyPath: The path to the DER-encoded private key for `publicKey`.
        public static func derFile(publicKeyPath: String, privateKeyPath: String) -> Self {
            Self(backing: .file(publicKeyPath: publicKeyPath, privateKeyPath: privateKeyPath, format: .der))
        }
    }
    #endif  // HTTP3
}
