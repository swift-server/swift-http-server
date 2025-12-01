@testable import HTTPServer
import HTTPTypes
import Logging
import NIOCore
import NIOHTTP1
import NIOHTTPTypes
import NIOPosix
import Testing

#if canImport(Dispatch)
import Dispatch
#endif

@Suite
struct NIOHTTPServerTests {
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test("Obtain the listening address correctly")
    func testListeningAddress() async throws {
        let server = NIOHTTPServer(
            logger: Logger(label: "Test"),
            configuration: .init(bindTarget: .hostAndPort(host: "127.0.0.1", port: 1234))
        )

        try await withThrowingTaskGroup { group in
            group.addTask {
                try await server.serve { _, _, _, _ in
                    return
                }
            }

            let serverAddress = try await server.listeningAddress

            let address = try #require(serverAddress.ipv4)
            #expect(address.host == "127.0.0.1")
            #expect(address.port == 1234)

            group.cancelAll()
        }

        // Now that the server has shut down, try obtaining the listening address. This should result in an error.
        await #expect(throws: ListeningAddressError.serverClosed) {
            try await server.listeningAddress
        }
    }
}
