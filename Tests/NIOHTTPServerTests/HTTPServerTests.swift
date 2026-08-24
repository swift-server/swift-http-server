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
import Foundation
import Logging
import NIOHTTPServer
import Testing
import System

@Suite
struct HTTPServerTests {
    @Test
    @available(anyAppleOS 26.0, *)
    func testConsumingServe() async throws {
        let server = NIOHTTPServer(
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        try await withThrowingTaskGroup { group in
            group.addTask {
                try await server.serve { request, context, reader, responseSender in
                    var requestBody = UniqueArray<UInt8>()
                    requestBody.reserveCapacity(100)
                    _ = try await reader.collect(into: &requestBody)
                    // Uncommenting this would cause a "reader consumed more than once" error.
                    //            _ = try await reader.collect(into: &requestBody)

                    let responseWriter = try await responseSender.send(HTTPResponse(status: .ok))
                    // Uncommenting this would cause a "responseSender consumed more than once" error.
                    //            let responseWriter2 = try await responseSender.send(HTTPResponse(status: .ok))

                    var buffer = UniqueArray<UInt8>(copying: [1, 2])
                    try await responseWriter.finish(buffer: &buffer, finalElement: nil)

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

    @Test("Unix domain socket file is removed on shutdown")
    @available(anyAppleOS 26.0, *)
    func testUnixDomainSocketFileRemovedOnShutdown() async throws {
        // Keep the path short so it stays under the platform's `sun_path` limit (104 on Darwin, 108 on Linux),
        // even on CI where the system temporary directory can be deep.
        let socketPath = "/tmp/nio-http-server-uds-\(UUID().uuidString).sock"
        // Guard against a leftover file from a previously crashed run, and clean up if this test fails early.
        try? FileManager.default.removeItem(atPath: socketPath)
        defer { try? FileManager.default.removeItem(atPath: socketPath) }
        let filePath = FilePath(socketPath)

        let server = NIOHTTPServer(
            logger: Logger(label: "Test"),
            configuration: try .init(
                bindTarget: .unixDomainSocket(path: filePath),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        try await withThrowingTaskGroup { group in
            group.addTask {
                try await server.serve { request, context, reader, responseSender in
                    let responseWriter = try await responseSender.send(HTTPResponse(status: .ok))
                    var buffer = UniqueArray<UInt8>()
                    try await responseWriter.finish(buffer: &buffer, finalElement: nil)
                }
            }

            // Wait until the server is bound; the socket file must exist while it is listening.
            _ = try await server.listeningAddresses
            #expect(FileManager.default.fileExists(atPath: socketPath))

            // Shutting the server down should release the socket by removing its file.
            group.cancelAll()
        }

        // The task group only returns once `serve` has fully unwound, including its cleanup `defer`.
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test("Bind fails when the unix domain socket path is already occupied")
    @available(anyAppleOS 26.0, *)
    func testUnixDomainSocketBindFailsWhenPathExists() async throws {
        let socketPath = "/tmp/nio-http-server-uds-\(UUID().uuidString).sock"
        // Simulate a leftover/occupied socket by pre-creating a file at the path.
        #expect(FileManager.default.createFile(atPath: socketPath, contents: nil))
        defer { try? FileManager.default.removeItem(atPath: socketPath) }
        let filePath = FilePath(socketPath)

        let server = NIOHTTPServer(
            logger: Logger(label: "Test"),
            configuration: try .init(
                bindTarget: .unixDomainSocket(path: filePath),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        // Binding to an occupied path must fail rather than silently reusing or removing the file.
        await #expect(throws: Error.self) {
            try await server.serve { _, _, _, _ in }
        }

        // The pre-existing file must be left untouched: cleanup only runs for sockets we bound ourselves.
        #expect(FileManager.default.fileExists(atPath: socketPath))
    }
}
