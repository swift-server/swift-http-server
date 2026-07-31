# Swift HTTP Server

This repository contains the Swift HTTP Server project.
It provides a low-level yet ergonomic API for handling HTTP requests and responses with full support 
for bi-directional streaming, request and response trailers, and Structured Concurrency-based 
resource management.

## 🚧 This project is a work in progress 🚧

All feedback is welcome: please open issues!

## Getting started

To get started, please refer to the project's documentation and the Example located under `Sources`.

## Package traits

This package offers additional integrations you can enable using
[package traits](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/addingdependencies#Packages-with-Traits).

Available traits:
- **`Configuration`** (default): Enables initializing `NIOHTTPServerConfiguration` from a `swift-configuration`
  `ConfigProvider`.
- **`HTTP3`**: Enables HTTP/3 support.
- **`UnstableHTTPDatagrams`**: Enables support for reading and writing unreliable HTTP datagrams. Note that the `HTTP3`
  trait must be enabled alongside.

## HTTP/3 support

Packages in the dependency tree depend on a beta release of swift-crypto.
Set the environment variable
`SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA` to allow swift-certificates
(in the dependency tree) to adopt swift-crypto beta releases as well.

```
SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1 swift build
```

To run all unit tests, run

```
SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1 swift test
```

Use `SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1 xed Package.swift` to open
the project in Xcode with the environment variable set.
