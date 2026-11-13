import Foundation

enum ClientError: Error {
    case exhausted
    case http(Int)
}

/// Turns an http status code into a short message a person can read.
func describeHttpError(status: Int) -> String {
    switch status {
    case 404: return "The thing you asked for was not found"
    case 429: return "Too many requests, try again later"
    default: return "The server answered with status \(status)"
    }
}
