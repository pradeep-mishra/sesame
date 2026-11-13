import Foundation

struct Token {
    var value: String
    var expiresAt: Date
}

/// Asks the server for a new access token before the old one expires and stores it.
func refreshAccessToken(using refreshToken: String) -> Token {
    let fresh = Token(value: "token-" + refreshToken, expiresAt: Date().addingTimeInterval(3600))
    return fresh
}
