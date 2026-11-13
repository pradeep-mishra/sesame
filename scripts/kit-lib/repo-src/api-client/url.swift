import Foundation

/// Turns a dictionary of parameters into a percent encoded query string such as a=1&b=2.
func buildQueryString(_ parameters: [String: String]) -> String {
    parameters.keys.sorted().map { key in
        key + "=" + (parameters[key] ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
    }.joined(separator: "&")
}
