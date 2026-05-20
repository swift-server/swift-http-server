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
import SwiftASN1
import X509

/// Some convenience helpers for converting between NIOSSL and X509 certificate and private key types.

// MARK: X509 to NIOSSL

@available(anyAppleOS 26.0, *)
extension NIOSSLCertificate {
    convenience init(_ certificate: Certificate) throws {
        var serializer = DER.Serializer()
        try certificate.serialize(into: &serializer)
        try self.init(bytes: serializer.serializedBytes, format: .der)
    }
}

@available(anyAppleOS 26.0, *)
extension NIOSSLPrivateKey {
    convenience init(_ privateKey: Certificate.PrivateKey) throws {
        try self.init(bytes: try privateKey.serializeAsPEM().derBytes, format: .der)
    }
}

@available(anyAppleOS 26.0, *)
extension NIOSSLCertificateSource {
    init(_ certificate: Certificate) throws {
        self = .certificate(try NIOSSLCertificate(certificate))
    }
}

@available(anyAppleOS 26.0, *)
extension NIOSSLPrivateKeySource {
    init(_ privateKey: Certificate.PrivateKey) throws {
        self = .privateKey(try NIOSSLPrivateKey(privateKey))
    }
}

@available(anyAppleOS 26.0, *)
extension NIOSSLTrustRoots {
    init(treatingNilAsSystemTrustRoots certificates: [Certificate]?) throws {
        if let certificates {
            self = .certificates(try certificates.map { try NIOSSLCertificate($0) })
        } else {
            self = .default
        }
    }
}

// MARK: NIOSSL to X509

@available(anyAppleOS 26.0, *)
extension Certificate {
    init(_ certificate: NIOSSLCertificate) throws {
        try self.init(derEncoded: certificate.toDERBytes())
    }
}
