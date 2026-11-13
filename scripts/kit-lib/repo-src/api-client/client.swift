import Foundation

final class ApiClient {
    var token = Token(value: "", expiresAt: .distantPast)

    func get(path: String) throws -> Data {
        if token.expiresAt < Date() { token = refreshAccessToken(using: "stored-refresh") }
        return Data(path.utf8)
    }
}
