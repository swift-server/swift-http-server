import HTTPTypes
import NIOCore
import NIOHTTP3
import NIOHTTPTypes
import NIOQUIC

public struct BenchmarkHTTP3Connection {
    private let channel: any Channel

    init(channel: any Channel) {
        self.channel = channel
    }

    public func close() async throws {
        try await self.channel.close()
    }

    public func openStream() async throws -> Self.Stream {
        let channel = self.channel
        let stream = try await channel.eventLoop.flatSubmit {
            channel.pipeline.handler(type: HTTP3ConnectionHandler<NIOQUIC.QUICStreamCreator>.self)
                .flatMap { h3Handler in
                    h3Handler.createRequestStream { parameters in
                        let streamChannel = parameters.channel
                        return streamChannel.eventLoop.makeCompletedFuture {
                            try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                                wrappingChannelSynchronously: streamChannel,
                                configuration: .init(isOutboundHalfClosureEnabled: true)
                            )
                        }
                    }
                }
        }.get()

        return Self.Stream(stream: stream)
    }

    public func download() async throws {
        let stream = try await self.openStream()
        try await stream.download()
    }
}

extension BenchmarkHTTP3Connection {
    public struct Stream {
        private let stream: NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>

        fileprivate init(stream: NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>) {
            self.stream = stream
        }

        public func download() async throws {
            try await stream.executeThenClose { inbound, outbound in
                try await outbound.write(
                    .head(HTTPRequest(method: .get, scheme: "https", authority: "benchmark", path: "/"))
                )
                try await outbound.write(.end(nil))

                var iterator = inbound.makeAsyncIterator()
                while let part = try await iterator.next() {
                    if case .end = part {
                        break
                    }
                }
            }
        }

        public func close() async throws {
            try await stream.channel.close()
        }
    }
}
