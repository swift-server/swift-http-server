import NIOSSL
import SwiftASN1
import X509

/// Some convenience helpers for converting between NIOSSL and X509 certificate and private key types.

// MARK: X509 to NIOSSL

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension NIOSSLCertificate {
    convenience init(_ certificate: Certificate) throws {
        var serializer = DER.Serializer()
        try certificate.serialize(into: &serializer)
        try self.init(bytes: serializer.serializedBytes, format: .der)
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension NIOSSLPrivateKey {
    convenience init(_ privateKey: Certificate.PrivateKey) throws {
        try self.init(bytes: try privateKey.serializeAsPEM().derBytes, format: .der)
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension NIOSSLCertificateSource {
    init(_ certificate: Certificate) throws {
        self = .certificate(try NIOSSLCertificate(certificate))
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension NIOSSLPrivateKeySource {
    init(_ privateKey: Certificate.PrivateKey) throws {
        self = .privateKey(try NIOSSLPrivateKey(privateKey))
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
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

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension Certificate {
    init(_ certificate: NIOSSLCertificate) throws {
        try self.init(derEncoded: certificate.toDERBytes())
    }
}
