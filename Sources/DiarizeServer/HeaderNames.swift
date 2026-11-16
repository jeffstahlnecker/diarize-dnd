import HTTPTypes

/// Header names used by the server (namespaced to avoid clashing with names HTTPTypes already defines).
enum Hdr {
    static let requestID = HTTPField.Name("X-Request-Id")!
    static let origin = HTTPField.Name("Origin")!
    static let host = HTTPField.Name("Host")!
    static let vary = HTTPField.Name("Vary")!
    static let authorization = HTTPField.Name("Authorization")!
    static let contentLength = HTTPField.Name("Content-Length")!
    static let allowOrigin = HTTPField.Name("Access-Control-Allow-Origin")!
    static let allowMethods = HTTPField.Name("Access-Control-Allow-Methods")!
    static let allowHeaders = HTTPField.Name("Access-Control-Allow-Headers")!
    static let maxAge = HTTPField.Name("Access-Control-Max-Age")!
    static let exposeHeaders = HTTPField.Name("Access-Control-Expose-Headers")!
    static let allowPrivateNetwork = HTTPField.Name("Access-Control-Allow-Private-Network")!
    static let requestMethod = HTTPField.Name("Access-Control-Request-Method")!
    static let requestPrivateNetwork = HTTPField.Name("Access-Control-Request-Private-Network")!
}
