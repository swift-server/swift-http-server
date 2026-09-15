import Crypto
import Foundation
import NIOHTTPServer
import SwiftASN1
import X509

public struct BenchmarkCertificate: Sendable {
    let certificatePath: String
    let privateKeyPath: String

    public static func makeSelfSigned() throws -> BenchmarkCertificate {
        let key = P384.Signing.PrivateKey()
        let name = try DistinguishedName { OrganizationName("Benchmark") }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(key.publicKey),
            notValidBefore: .now - 60,
            notValidAfter: .now + 60,
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA384,
            extensions: try .init {
                BasicConstraints.isCertificateAuthority(maxPathLength: nil)
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([
                    .dnsName("127.0.0.1"),
                    .ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1])),
                ])
            },
            issuerPrivateKey: .init(key)
        )

        let uuid = UUID().uuidString
        let certificatePath = FileManager.default.temporaryDirectory.appendingPathComponent("benchmark-cert-\(uuid)")
        let privateKeyPath = FileManager.default.temporaryDirectory.appendingPathComponent("benchmark-key-\(uuid)")

        try Data(certificate.serializeAsPEM().pemString.utf8).write(to: certificatePath)
        try Data(Certificate.PrivateKey(key).serializeAsPEM().pemString.utf8).write(to: privateKeyPath)

        return BenchmarkCertificate(certificatePath: certificatePath.path, privateKeyPath: privateKeyPath.path)
    }

    var transportSecurity: NIOHTTPServerConfiguration.TransportSecurity {
        .tls(
            credentials: .x509(.pemFile(certificateChainPath: certificatePath, privateKeyPath: privateKeyPath))
        )
    }
}
