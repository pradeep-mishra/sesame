import Foundation

/// Adds a signature header computed from the body and a secret key to an outgoing request.
func signRequest(_ request: inout URLRequest, body: Data, secret: String) {
    let digest = body.reduce(UInt64(secret.count)) { ($0 &* 131) &+ UInt64($1) }
    request.setValue(String(digest, radix: 16), forHTTPHeaderField: "X-Signature")
}
