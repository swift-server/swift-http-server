# Swift HTTP Server

* Proposal: [SE-NNNN](NNNN-HTTPServer.md)
* Authors: [Franz Busch](https://github.com/FranzBusch)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Not yet implemented
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

This proposal introduces a Swift-native HTTP server designed with Swift
Concurrency at its core. It provides a low-level yet ergonomic API for handling
HTTP requests and responses with full support for bi-directional streaming,
request and response trailers, and Structured Concurrency based resource management.
The server is built on top of the types provided by
[HTTPTypes](https://github.com/apple/swift-http-types) and `Span` from standard library,
making it a perfect foundation for both direct use and as a basis for higher-level web frameworks.

The proposal also includes a hypothetical middleware API showcasing that
bi-directional streaming with request and response trailers also works there.

## Motivation

Swift has become an increasingly popular language for developing cloud services,
with frameworks like [Vapor](https://github.com/vapor/vapor),
[Hummingbird](https://github.com/hummingbird-project/hummingbird),
and others providing robust solutions for building web applications.
However, each framework is currently building its own internal low-level HTTP
server. This creates several challenges:

1. **Inconsistent abstractions**: Different frameworks use different models for
handling HTTP, making it difficult to share code or patterns across frameworks.

2. **Concurrency model mismatch**: Some of the existing solutions were built
before Swift Concurrency was available, leading to difficult retrofitting of
async/await patterns onto callback-based or future-based designs.

3. **Manual resource management**: Developers often need to manually track and
close resources like connections and request bodies, leading to potential leaks.

4. **Limited streaming support**: Full bidirectional streaming with proper
support for HTTP trailers is inconsistently implemented across different solutions.

A Swift-native HTTP server would solve these problems by providing:

- A common foundation that any Swift web framework can build upon
- First-class Swift Concurrency support
- Structured resource management tied to the lifetime of async tasks and methods
- Full support for bi-directional streaming requests and responses with trailers
- Enforcing the right order of HTTP request parts (head, body, end) through
its APIs
- A clear and type-safe configuration API

### Streaming, trailers and structured concurrency

Before diving into the proposed solution it is important to understand the
fundamental problems that streaming and trailers introduce when trying to keep the
implementation adhering to Structured Concurrency. First, let's talk about
why we want to leverage structured concurency in the first place. Structured
Concurrency allows us to use the linear code flow to enforce invariants.
Furthermore, that linear flows allows us to reason better about the lifetime and
behaviour of our code. An important part of this is leveraging closure-based
scoping for composition and resource management. The standard library and libraries across the
ecosystem offer APIs based on this such as:

- [Swift Standard library `measure`]
(https://developer.apple.com/documentation/swift/clock/measure(_:))
- [Swift Standard library `withTaskCancellationHandler`]
(https://developer.apple.com/documentation/swift/withtaskcancellationhandler(handler:operation:)))
- [Swift Metrics `measure`]
(https://swiftpackageindex.com/apple/swift-metrics/2.7.0/documentation/metrics/coremetrics/timer/measure(clock:body:)))
- [Swift Tracing `withSpan`]
(https://swiftpackageindex.com/apple/swift-distributed-tracing/1.2.0/documentation/tracing/withspan(_:at:context:ofkind:function:file:line:_:)-7pdo8))


Those scope-based methods also commonly referred to as `with-style` methods allow
great composition of functionality. Below is an example composing some of those
methods:

```swift
// Opening a span for tracing
try await withSpan { span in
    // Recording a timer to understand how long the code runs
    try await Timer.measure {
        // Enforcing an upper limit how long the code can run
        try await withTimeout {
            // Executing the actual work
            try await doSomeActualWork()
        }
    }
}
```

This example shows how powerful `with-style` methods are in both allowing
great composition but also clear understanding. From just looking at the code
we can see when the span is closed or when the timer stops measuring. However,
the correctness of this fully relies on `doSomeActualWork` to finish all of its
work within the duration of the method and clean-up any used resources before
returning.

In the context of an HTTP server with bi-directional streaming and trailer
support, we want to be able to use the same `with-style` primitives when handling
a request. Concretely this means:
- Being able enforce a timeout for handling a request until the final response
trailer is written
- Being able to add observability around handling a request such as traces, logs
or metrics

In practice, this means that the request handling API of the HTTP server needs
to be scoped to a single method where at the end of the method the request is
completely handled and the response including trailers is fully written out.

To motivate this even further, the following is showing a pseudo-code pattern
which allow bi-directional streaming but fails to allow composition using
`with-style` methods.

#### Returning AsyncSequence-based streaming approach

```swift
// A hypothethical HTTP server serve method using async sequences for bodies
func serve(
    requestHandler: (
        HTTPRequest,
        some AsyncSequence<[UInt8], any Error>
    ) async throws -> (HTTPResponse, some AsyncSequence<[UInt8], any Error>)
) async throws

// We are just streaming back the request body
try await serve { request, requestBodyAsyncSequence in
    return try await withSpan {
        return (HTTPResponse(status: .ok), requestBodyAsyncSequence)
    }
}
```

The above example is returning an async sequence for the response body. The
problem with this is that the underlying implementation then has to consume
the async sequence to write back the response data. Our `withSpan` method here
is only capturing the span until we return the HTTP response. If we wanted to
have a span that lasts until the last response body chunk has been written we
would need to fall back to manually managing the spans lifetime.

**Result** The entire request until writing the response trailers must be handled
in the scope of the request handler closure.

#### Writer-based streaming approach

The above shows that returning async sequences are not the right tool for modeling
responses since they require a consumer to pull the data. Hence, instead of
using of returning an async sequence we need a type that allows developers to write response
body chunks in their scope. Applying this to the async sequence based example:

```swift
// A hypothethical HTTP server listen method using a writer for response bodies
func listen(
    requestHandler: (
        HTTPRequest,
        some AsyncSequence<[UInt8], any Error>,
        _ sendResponse: (HTTPResponse, some AsyncWriter<[UInt8], any Error>)
    ) async throws -> Void
) async throws

// We are just streaming back the request body
try await listen { request, requestBodyAsyncSequence, sendResponse in
    return try await withSpan {
        try await sendResponse(HTTPResponse(status: .ok)) { responseBodyWriter in
            for try await requestChunk in requestBodyAsyncSequence {
                try await responseBodyWriter.write(requestChunk)
            }
        }
    }
}
```

The above example now correctly works and the span is covering the response
header and every response body chunk being written out. The only problem left to
solve is how to correctly model the optional request and response trailers while
upholding the scope based guarantees of the writer-based streaming apporach. This
is explored in the below proposed and detailed design section.

## Proposed solution

We propose a Swift HTTP server that builds on the
[HTTPTypes](https://github.com/apple/swift-http-types) library and `Span<UInt8>`,
and leverages Swift's Structured Concurrency to provide a safe, efficient, and
easy-to-use API for handling HTTP requests.

The core of the API centers around handling individual requests within an
async context, ensuring that resources are automatically managed when the
request handler completes. The server supports HTTP/1.1 and HTTP/2 with TLS encryption
options.

### Basic Usage

Here's a simple example of using the HTTP server:

```swift
import HTTPServer
import HTTPTypes
import Logging

let logger = Logger(label: "HTTPServer")
let configuration = HTTPServerConfiguration(
    bindTarget: .hostAndPort(host: "127.0.0.1", port: 8080),
    tlsConfiguration: .insecure()
)

try await Server.serve(
    logger: logger,
    configuration: configuration
) { request, bodyReader, sendResponse in
    print("Handling request", request.path ?? "unknown")

    // Read the request body and trailers
    let (body, trailers) = try await requestConcludingReader.collect(upTo: 100) { Array($0) }
    
    // Create and send response
    let responseWriter = try await sendResponse(HTTPResponse(status: .ok))
    try await responseWriter.writeAndConclude(
        element: body.span,
        finalElement: HTTPFields(dictionaryLiteral: (.acceptEncoding, "Encoding"))
    )
}
```

### Using Request Handlers

For more structured applications, you can implement the `HTTPServerRequestHandler` protocol:

```swift
struct EchoHandler: HTTPServerRequestHandler {
    func handle(
        request: HTTPRequest,
        requestConcludingAsyncReader: HTTPRequestConcludingAsyncReader,
        sendResponse: @escaping (HTTPResponse) async throws -> HTTPResponseConcludingAsyncWriter
    ) async throws {
        // Read the entire request body
        let (bodyData, trailers) = try await bodyAndTrailerAsyncSequence.consumeAndConclude { reader in
            var data = [UInt8]()
            var shouldContinue = true
            while shouldContinue {
                try await reader.read { span in
                    guard let span else {
                        shouldContinue = false
                        return
                    }
                    data.append(contentsOf: span)
                }
            }
            return data
        }

        // Create and send response
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/octet-stream"
        let responseWriter = try await sendResponse(response)
        
        // Echo the request body back
        try await responseWriter.produceAndConclude { writer in
            try await writer.write(bodyData.span)
            return ((), trailers) // Echo trailers back too
        }
    }
}

// Use the handler
try await Server.serve(
    logger: logger,
    configuration: configuration,
    handler: EchoHandler()
)
```

## Detailed design

### Core Server Architecture

The HTTP server is built around several key components:

#### Server Class

The `Server` class provides the main entry point for creating and configuring an HTTP server:

```swift
public final class Server<RequestHandler: HTTPServerRequestHandler> {
    /// Starts an HTTP server with a closure-based request handler.
    public static func serve(
        logger: Logger,
        configuration: HTTPServerConfiguration,
        handler: @escaping @Sendable (
            HTTPRequest,
            HTTPRequestConcludingAsyncReader,
            @escaping (HTTPResponse) async throws -> HTTPResponseConcludingAsyncWriter
        ) async throws -> Void
    ) async throws where RequestHandler == HTTPServerClosureRequestHandler
    
    /// Starts an HTTP server with the specified request handler.
    public static func serve(
        logger: Logger,
        configuration: HTTPServerConfiguration,
        handler: RequestHandler
    ) async throws
}
```

#### Configuration

The server can be configured with various options:

```swift
public struct HTTPServerConfiguration: Sendable {
    /// Specifies where the server should bind and listen for incoming connections.
    public struct BindTarget: Sendable {
        /// Creates a bind target for a specific host and port.
        public static func hostAndPort(host: String, port: Int) -> Self
    }
    
    /// Configuration for TLS/SSL encryption settings.
    public struct TLSConfiguration: Sendable {
        /// Run the server without TLS encryption
        public static func insecure() -> Self
        
        /// Configure TLS with certificate chain and private key
        public static func certificateChainAndPrivateKey(
            certificateChain: [Certificate],
            privateKey: Certificate.PrivateKey
        ) -> Self
    }
    
    /// Network binding configuration
    public var bindTarget: BindTarget
    
    /// TLS configuration (defaults to insecure)
    public var tlsConfiguration: TLSConfiguration
    
    public init(
        bindTarget: BindTarget,
        tlsConfiguration: TLSConfiguration = .insecure()
    )
}
```

### Async Primitives

The HTTP server introduces several key async primitives for streaming:

#### AsyncReader Protocol

```swift
public protocol AsyncReader<ReadElement, ReadFailure> {
    associatedtype ReadElement: ~Copyable, ~Escapable
    associatedtype ReadFailure: Error
    
    /// Reads an element from the underlying source and processes it with the provided body function.
    mutating func read<Return>(
        body: (consuming ReadElement?) async throws -> Return
    ) async throws(ReadFailure) -> Return
}
```

#### AsyncWriter Protocol

```swift
public protocol AsyncWriter<WriteElement, WriteFailure>: ~Copyable {
    associatedtype WriteElement: ~Copyable, ~Escapable
    associatedtype WriteFailure: Error
    
    /// Writes the provided element to the underlying destination.
    mutating func write(_ element: consuming WriteElement) async throws(WriteFailure)
}
```

#### Concluding Async Primitives

For handling resources with final elements (like HTTP trailers):

```swift
public protocol ConcludingAsyncReader<Underlying, FinalElement> {
    associatedtype Underlying: AsyncReader, ~Copyable, ~Escapable
    associatedtype FinalElement
    
    /// Processes the underlying async reader until completion and returns both the result and final element.
    consuming func consumeAndConclude<Return>(
        body: (inout Underlying) async throws -> Return
    ) async throws -> (Return, FinalElement)
}

public protocol ConcludingAsyncWriter<Underlying, FinalElement>: ~Copyable {
    associatedtype Underlying: AsyncWriter, ~Copyable
    associatedtype FinalElement
    
    /// Allows writing to the underlying async writer and produces a final element upon completion.
    consuming func produceAndConclude<Return>(
        body: (consuming Underlying) async throws -> (Return, FinalElement)
    ) async throws -> Return
}
```

### HTTP-Specific Types

#### HTTP Request Processing

```swift
/// A specialized reader for HTTP request bodies and trailers
public struct HTTPRequestConcludingAsyncReader: ConcludingAsyncReader {
    public typealias Underlying = RequestBodyAsyncReader
    public typealias FinalElement = HTTPFields?
    
    /// Processes the request body reading operation and captures the final trailer fields.
    public consuming func consumeAndConclude<Return>(
        body: (inout RequestBodyAsyncReader) async throws -> Return
    ) async throws -> (Return, HTTPFields?)
}
```

#### HTTP Response Writing

```swift
/// A specialized writer for HTTP response bodies and trailers
public struct HTTPResponseConcludingAsyncWriter: ConcludingAsyncWriter, ~Copyable {
    public typealias Underlying = ResponseBodyAsyncWriter
    public typealias FinalElement = HTTPFields?
    
    /// Processes the body writing operation and concludes with optional trailer fields.
    public consuming func produceAndConclude<Return>(
        body: (consuming ResponseBodyAsyncWriter) async throws -> (Return, FinalElement)
    ) async throws -> Return
}
```

#### Request Handler Protocol

```swift
public protocol HTTPServerRequestHandler: Sendable {
    /// Handles an incoming HTTP request and generates a response.
    func handle(
        request: HTTPRequest,
        bodyAndTrailerAsyncSequence: HTTPRequestConcludingAsyncReader,
        sendResponse: @escaping (HTTPResponse) async throws -> HTTPResponseConcludingAsyncWriter
    ) async throws
}
```

### Middleware System

The hypothetical middleware system for composable request processing:

#### Middleware Protocol

```swift
public protocol Middleware<Input, NextInput> {
    associatedtype Input
    associatedtype NextInput = Input
    
    /// Intercepts and processes the input, then calls the next middleware or handler.
    func intercept(
        input: Input,
        next: (NextInput) async throws -> Void
    ) async throws
}
```

#### Middleware Chain Builder

Using Swift's result builder feature:

```swift
@resultBuilder
public struct MiddlewareChainBuilder {
    public static func buildPartialBlock<I: Middleware>(
        first middleware: I
    ) -> MiddlewareChain<I.Input, I.NextInput>
    
    public static func buildPartialBlock<Input, MiddleInput, NextInput>(
        accumulated: MiddlewareChain<Input, MiddleInput>,
        next: MiddlewareChain<MiddleInput, NextInput>
    ) -> MiddlewareChain<Input, NextInput>
    
    // Additional builder methods for optionals, conditionals, etc.
}
```

## Future directions

### WebSocket Support

The HTTP server could be extended to support WebSocket protocol upgrades:

### HTTP/3 Support

Future support for HTTP/3 (based on QUIC) could be integrated once the ecosystem
gains an implementation.

## Alternatives considered

### Different models for bi-directional streaming and trailers 

We considered several approaches for handling streaming and trailers:

#### Returning `AsyncSequence` for Response Bodies

```swift
func handle(
    request: HTTPRequest
) async throws -> (HTTPResponse, some AsyncSequence<UInt8, Error>)
```

This approach was rejected because:
- The response body sequence would be consumed outside the request handler scope
- Structured concurrency guarantees would be lost
- Trailer support would be difficult to implement
- Resource management becomes manual and error-prone
