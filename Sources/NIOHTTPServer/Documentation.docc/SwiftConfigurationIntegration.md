# Configuring the server with swift-configuration

Initialize ``NIOHTTPServerConfiguration`` from a configuration source using [`swift-configuration`](https://github.com/apple/swift-configuration).

## Overview

``NIOHTTPServerConfiguration`` can be initialized from a `ConfigReader` provided by
[`swift-configuration`](https://github.com/apple/swift-configuration). This lets you load server settings from
environment variables, JSON files, or other `swift-configuration` providers.

This functionality requires the `Configuration` package trait, which is enabled by default.

### Basic usage

```swift
import Configuration
import NIOHTTPServer

// Create a configuration reader from one or more providers.
let config = ConfigReader(
    providers: [
        EnvironmentVariablesProvider(),
        try FileProvider(format: .json, filePath: "config.json"),
    ]
)

let serverConfiguration = try NIOHTTPServerConfiguration(config: config)
```

### Configuration key reference

``NIOHTTPServerConfiguration`` is comprised of four components. Provide the configuration for each component under its
respective key prefix.

> Important: HTTP/2 cannot be served over plaintext. If `"http2"` is included in `http.versions`, the transport
> security must be set to `"tls"` or `"mTLS"`.

| Prefix                        | Configuration Key                 | Type           | Required/Optional                                                                                                             | Default |
|-------------------------------|-----------------------------------|----------------|-------------------------------------------------------------------------------------------------------------------------------|---------|
| `bindTarget`                  | `host`                            | `string`       | Required                                                                                                                      | -       |
|                               | `port`                            | `int`          | Required                                                                                                                      | -       |
| `http`                        | `versions`                        | `string array` | Required (permitted values: `"http1_1"`, `"http2"`)                                                                           | -       |
| `http.http2`                  | `maxFrameSize`                    | `int`          | Optional                                                                                                                      | 2^14    |
|                               | `targetWindowSize`                | `int`          | Optional                                                                                                                      | 2^16-1  |
|                               | `maxConcurrentStreams`            | `int`          | Optional                                                                                                                      | nil     |
| `http.http2.gracefulShutdown` | `maximumDuration`                 | `int`          | Optional                                                                                                                      | nil     |
| `transportSecurity`           | `mode`                            | `string`       | Required (permitted values: `"plaintext"`, `"tls"`, `"mTLS"`)                                                                 | -       |
|                               | `credentialSource`                | `string`       | Required for `"tls"` and `"mTLS"` (permitted values: `"inline"`, `"file"`)                                                    | -       |
|                               | `certificateChainPEMString`       | `string`       | Required for `credentialSource: "inline"`                                                                                     | -       |
|                               | `privateKeyPEMString`             | `string`       | Required for `credentialSource: "inline"`, secret.                                                                            | -       |
|                               | `certificateChainPEMPath`         | `string`       | Required for `credentialSource: "file"`                                                                                       | -       |
|                               | `privateKeyPEMPath`               | `string`       | Required for `credentialSource: "file"`, secret.                                                                              | -       |
|                               | `refreshInterval`                 | `int`          | Optional for `credentialSource: "file"`                                                                                       | -       |
|                               | `trustRootsSource`                | `string`       | Required for `"mTLS"` (permitted values: `"inline"`, `"file"`, `"systemDefaults"`, `"customCertificateVerificationCallback"`) | -       |
|                               | `trustRootsPEMString`             | `string`       | Required for `trustRootsSource: "inline"`                                                                                     | -       |
|                               | `trustRootsPEMPath`               | `string`       | Required for `trustRootsSource: "file"`                                                                                       | -       |
|                               | `certificateVerificationMode`     | `string`       | Required for `"mTLS"`, permitted values: `"optionalVerification"`, `"noHostnameVerification"`                                 | -       |
| `backpressureStrategy`        | `lowWatermark`                    | `int`          | Optional                                                                                                                      | 2       |
|                               | `highWatermark`                   | `int`          | Optional                                                                                                                      | 10      |


The `credentialSource` determines how server credentials are provided:
- `"inline"`: provide the PEM-encoded certificate chain and private key as string values, using
  `certificateChainPEMString` and `privateKeyPEMString`.
- `"file"`: provide file paths to PEM-encoded certificate chain and private key files on disk, using
  `certificateChainPEMPath` and `privateKeyPEMPath`.
    - When `refreshInterval` is provided, credentials are reloaded periodically at the specified interval (in seconds).
      Otherwise, credentials are loaded from disk once at startup.

The `trustRootsSource` determines how mTLS trust roots are provided:
- `"inline"`: provide the root certificates as a PEM-encoded string, using `trustRootsPEMString`.
- `"file"`: provide a file path to a PEM file containing root certificates, using `trustRootsPEMPath`.
- `"systemDefaults"`: use the operating system's default trust store.
- `"customCertificateVerificationCallback"`: use a custom verification callback provided programmatically via the
  `customCertificateVerificationCallback` parameter.

### Example JSON configuration

The following JSON file shows an example configuration. Comments indicate the default value that would be used if the
key were omitted.

```json
{
    "bindTarget": {
        "host": "0.0.0.0",
        "port": 443
    },
    "http": {
        "versions": ["http1_1", "http2"],
        "http2": {
            "maxFrameSize": 16384,          // default: 2^14 (16384)
            "targetWindowSize": 65535,      // default: 2^16 - 1 (65535)
            "maxConcurrentStreams": 100,    // default: nil (no limit)
            "gracefulShutdown": {
                "maximumDuration": 30       // default: nil (no time limit)
            }
        }
    },
    "transportSecurity": {
        "mode": "mTLS",
        "credentialSource": "inline",
        "certificateChainPEMString": "-----BEGIN CERTIFICATE-----\n...",
        "privateKeyPEMString": "-----BEGIN PRIVATE KEY-----\n...",
        "trustRootsSource": "inline",
        "trustRootsPEMString": "-----BEGIN CERTIFICATE-----\n...",
        "certificateVerificationMode": "noHostnameVerification"
    },
    "backpressureStrategy": {
        "lowWatermark": 2,                  // default: 2
        "highWatermark": 10                 // default: 10
    }
}
```

### Custom certificate verification

When using mTLS, you can provide a custom certificate verification callback instead of relying on trust roots. To do
so, set `trustRootsSource` to `"customCertificateVerificationCallback"` in the configuration:

```json
{
    "transportSecurity": {
        "mode": "mTLS",
        "credentialSource": "inline",
        "certificateChainPEMString": "...",
        "privateKeyPEMString": "...",
        "trustRootsSource": "customCertificateVerificationCallback",
        "certificateVerificationMode": "noHostnameVerification"
    }
}
```

Then pass the callback when initializing the configuration:

```swift
let serverConfiguration = try NIOHTTPServerConfiguration(
    config: config,
    customCertificateVerificationCallback: { certificates in
        // Perform custom verification logic.
        return .certificateVerified(.init(nil))
    }
)
```

Setting `trustRootsSource` to `"customCertificateVerificationCallback"` without providing a callback, or providing a
callback when `trustRootsSource` is set to something else, will result in a
`NIOHTTPServerSwiftConfigurationError/trustRootsSourceAndVerificationCallbackMismatch` error.
