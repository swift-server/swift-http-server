import Benchmark
import NIOEmbedded
import NIOHTTPServerBenchmarkSupport

private func makeHTTP3BenchmarkConfiguration() -> Benchmark.Configuration {
    .init(
        metrics: [.mallocCountTotal, .instructions, .wallClock],
        scalingFactor: .one,
        maxDuration: .seconds(2),
        maxIterations: 10_000
    )
}

let eventLoop = NIOAsyncTestingEventLoop()
let certificate = try! BenchmarkCertificate.makeSelfSigned()

let benchmarks: @Sendable () -> Void = {
    var client: BenchmarkHTTP3Client!
    var prewarmedServer: BenchmarkHTTP3Server!
    Benchmark(
        "HTTP3_openConnection_stream",
        configuration: makeHTTP3BenchmarkConfiguration(),
        closure: { benchmark in
            for _ in benchmark.scaledIterations {
                let connection = try await client.openConnection()
                try await connection.download()
                try await connection.close()
            }
        },
        setup: {
            client = try await BenchmarkHTTP3Client.start(eventLoop: eventLoop, certificate: certificate)
            prewarmedServer = try await BenchmarkHTTP3Server.start(eventLoop: eventLoop, certificate: certificate)
            try await client.attach(to: prewarmedServer)
        },
        teardown: {
            try await client.shutdown()
            try await prewarmedServer.shutdown()
        }
    )

    Benchmark(
        "HTTP3_serverSetup_openConnection_stream",
        configuration: makeHTTP3BenchmarkConfiguration(),
        closure: { benchmark in
            for _ in benchmark.scaledIterations {
                let server = try await BenchmarkHTTP3Server.start(eventLoop: eventLoop, certificate: certificate)
                try await client.attach(to: server)
                let connection = try await client.openConnection()
                try await connection.download()
                try await connection.close()
                try await server.shutdown()
            }
        },
        setup: {
            client = try await BenchmarkHTTP3Client.start(eventLoop: eventLoop, certificate: certificate)
        },
        teardown: {
            try await client.shutdown()
        }
    )
}
