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

import BasicContainers
import Crypto
import Foundation
import Instrumentation
import Logging
import NIOHTTPServer
import X509

@main
@available(anyAppleOS 26.0, *)
struct Example {
    static func main() async throws {
        try await serve()
    }

    @concurrent
    static func serve() async throws {
        InstrumentationSystem.bootstrap(LogTracer())
        var logger = Logger(label: "Logger")
        logger.logLevel = .trace

        let privateKey = P256.Signing.PrivateKey()
        let server = NIOHTTPServer(
            logger: logger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 12345),
                supportedHTTPVersions: [.http1_1, .http2(config: .init())],
                transportSecurity: .tls(
                    credentials: .inMemory(
                        certificateChain: [
                            try Certificate(
                                version: .v3,
                                serialNumber: .init(bytes: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]),
                                publicKey: .init(privateKey.publicKey),
                                notValidBefore: Date.now.addingTimeInterval(-60),
                                notValidAfter: Date.now.addingTimeInterval(60 * 60),
                                issuer: DistinguishedName(),
                                subject: DistinguishedName(),
                                signatureAlgorithm: .ecdsaWithSHA256,
                                extensions: .init(),
                                issuerPrivateKey: Certificate.PrivateKey(privateKey)
                            )
                        ],
                        privateKey: Certificate.PrivateKey(privateKey)
                    )
                )
            )
        )

        try await server.serve { request, requestContext, requestBodyAndTrailers, responseSender in
            var body = UniqueArray<UInt8>(copying: "Well, hello!".utf8)
            try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
        }
    }
}
