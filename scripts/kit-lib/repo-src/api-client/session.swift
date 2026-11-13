import Foundation

struct Session {
    var token: Token

    mutating func renewIfNeeded() {
        if token.expiresAt.timeIntervalSinceNow < 60 { token = refreshAccessToken(using: "session-refresh") }
    }
}
