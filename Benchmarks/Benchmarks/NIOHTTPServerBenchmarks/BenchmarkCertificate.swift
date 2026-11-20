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

import Crypto
import Foundation
import NIOHTTPServer
import SwiftASN1
import X509

struct BenchmarkCertificate {
    let certificatePath: String
    let privateKeyPath: String

    var transportSecurity: NIOHTTPServerConfiguration.TransportSecurity {
        .tls(
            credentials: .x509(
                .pemFile(certificateChainPath: self.certificatePath, privateKeyPath: self.privateKeyPath)
            )
        )
    }

    static func withSelfSigned<Result>(
        _ body: (BenchmarkCertificate) async throws -> Result
    ) async throws -> Result {
        let key = P384.Signing.PrivateKey()
        let name = try DistinguishedName { OrganizationName("NIOHTTPServerBenchmarks") }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(key.publicKey),
            notValidBefore: .now - 60,
            notValidAfter: .now + 60 * 60,
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA384,
            extensions: try .init {
                BasicConstraints.isCertificateAuthority(maxPathLength: nil)
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1]))])
            },
            issuerPrivateKey: .init(key)
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("niohttpserver-benchmarks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let certificateURL = directory.appendingPathComponent("certificate.pem")
        let privateKeyURL = directory.appendingPathComponent("key.pem")
        try Data(certificate.serializeAsPEM().pemString.utf8).write(to: certificateURL)
        try Data(Certificate.PrivateKey(key).serializeAsPEM().pemString.utf8).write(to: privateKeyURL)

        return try await body(
            BenchmarkCertificate(certificatePath: certificateURL.path, privateKeyPath: privateKeyURL.path)
        )
    }
}
