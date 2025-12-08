//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import Foundation
import X509

struct ChainPrivateKeyPair {
    let leaf: Certificate
    let ca: Certificate
    let privateKey: Certificate.PrivateKey
}

struct TestCA {
    static func makeSelfSignedChain() throws -> ChainPrivateKeyPair {
        let caKey = P384.Signing.PrivateKey()
        let caName = try DistinguishedName { OrganizationName("Test CA") }
        let ca = try makeCA(name: caName, privateKey: caKey)

        let leafKey = P384.Signing.PrivateKey()
        let leafName = try DistinguishedName { OrganizationName("Test") }

        let leaf = try makeCertificate(
            issuerName: caName,
            issuerKey: .init(caKey),
            publicKey: .init(leafKey.publicKey),
            subject: leafName,
            extensions: .init()
        )

        return ChainPrivateKeyPair(leaf: leaf, ca: ca, privateKey: .init(leafKey))
    }

    static func makeCA(name: DistinguishedName, privateKey: P384.Signing.PrivateKey) throws -> Certificate {
        try makeCertificate(
            issuerName: name,
            issuerKey: .init(privateKey),
            publicKey: .init(privateKey.publicKey),
            subject: name,
            extensions: try .init {
                BasicConstraints.isCertificateAuthority(maxPathLength: nil)
            }
        )
    }

    static func makeCertificate(
        issuerName: DistinguishedName,
        issuerKey: Certificate.PrivateKey,
        publicKey: Certificate.PublicKey,
        subject: DistinguishedName,
        extensions: Certificate.Extensions
    ) throws -> Certificate {
        try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: publicKey,
            notValidBefore: .now - 60,
            notValidAfter: .now + 60,
            issuer: issuerName,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA384,
            extensions: extensions,
            issuerPrivateKey: issuerKey
        )
    }
}
