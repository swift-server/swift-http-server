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

import Crypto
import Foundation
import SwiftASN1
import X509

@testable import NIOHTTPServer

@available(anyAppleOS 26.0, *)
struct ChainPrivateKeyPair {
    let leaf: Certificate
    let ca: Certificate
    let privateKey: Certificate.PrivateKey

    var chain: [Certificate] {
        [self.leaf, self.ca]
    }

    var chainPEMString: String {
        get throws {
            let certs = [try self.leaf.serializeAsPEM().pemString, try self.ca.serializeAsPEM().pemString]
            return certs.joined(separator: "\n")
        }
    }

    func writeToDisk(
        encoding: NIOHTTPServerConfiguration.TransportSecurity.Encoding = .pem
    ) throws -> (leafPath: String, caPath: String, keyPath: String) {
        let uuid = UUID().uuidString
        let leafPath = FileManager.default.temporaryDirectory.appendingPathComponent("leaf-\(uuid)")
        let caPath = FileManager.default.temporaryDirectory.appendingPathComponent("ca-\(uuid)")
        let keyPath = FileManager.default.temporaryDirectory.appendingPathComponent("key-\(uuid)")

        switch encoding {
        case .pem:
            try Data(self.leaf.serializeAsPEM().pemString.utf8).write(to: leafPath)
            try Data(self.ca.serializeAsPEM().pemString.utf8).write(to: caPath)
            try Data(self.privateKey.serializeAsPEM().pemString.utf8).write(to: keyPath)

        case .der:
            try Data(self.leaf.serializeAsPEM().derBytes).write(to: leafPath)
            try Data(self.ca.serializeAsPEM().derBytes).write(to: caPath)
            try Data(self.privateKey.serializeAsPEM().derBytes).write(to: keyPath)
        }

        return (leafPath.path, caPath.path, keyPath.path)
    }
}

@available(anyAppleOS 26.0, *)
struct TestCA {
    static func makeSelfSignedChain(leafExtensions: Certificate.Extensions = .init()) throws -> ChainPrivateKeyPair {
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
            extensions: leafExtensions
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

    /// Creates a self-signed certificate chain with a SAN for the leaf certificate.
    static func makeSelfSignedChainWithSAN(
        leafSAN: SubjectAlternativeNames = SubjectAlternativeNames([
            .dnsName("127.0.0.1"),
            .ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1])),
        ])
    ) throws -> ChainPrivateKeyPair {
        try TestCA.makeSelfSignedChain(
            leafExtensions: try Certificate.Extensions {
                BasicConstraints.notCertificateAuthority

                try ExtendedKeyUsage([.serverAuth])

                leafSAN
            }
        )
    }
}
