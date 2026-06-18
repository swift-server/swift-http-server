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
import Logging
import NIOHTTPServer
import Testing

@Suite
struct HTTPServerTests {
    @Test
    @available(anyAppleOS 26.0, *)
    func testConsumingServe() async throws {
        let server = NIOHTTPServer(
            logger: Logger(label: "Test"),
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        try await withThrowingTaskGroup { group in
            group.addTask {
                try await server.serve { request, context, reader, responseSender in
                    _ = try await reader.collect(upTo: 100) { _ in }
                    // Uncommenting this would cause a "reader consumed more than once" error.
                    //            _ = try await reader.collect(upTo: 100) { _ in }

                    let responseWriter = try await responseSender.send(HTTPResponse(status: .ok))
                    // Uncommenting this would cause a "responseSender consumed more than once" error.
                    //            let responseWriter2 = try await responseSender.send(HTTPResponse(status: .ok))

                    var buffer = UniqueArray<UInt8>(copying: [1, 2])
                    try await responseWriter.finish(buffer: &buffer)

                    // Uncommenting this would cause a "responseWriter consumed more than once" error.
                    //            try await responseWriter.finish(
                    //                buffer: &buffer,
                    //                finalElement: [.acceptEncoding: "Encoding"]
                    //            )
                }
            }

            _ = try await server.listeningAddresses

            group.cancelAll()
        }
    }
}
