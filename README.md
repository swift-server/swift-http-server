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
To enable an additional trait on the package, update the package dependency:

```diff
.package(
    url: "https://github.com/swift-server/swift-http-server.git",
    from: "...",
+   traits: [.defaults, "ServiceLifecycle"]
)
```

Available traits:
- **`SwiftConfiguration`** (default): Enables initializing `NIOHTTPServerConfiguration` from a `swift-configuration`
  `ConfigProvider`.
- **`ServiceLifecycle`** (opt-in): Enables `HTTPService`, which allows the server to be run with `ServiceGroup` from
  `swift-service-lifecycle`, including support for graceful shutdown. 
