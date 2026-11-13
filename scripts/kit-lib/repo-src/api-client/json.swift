import Foundation

/// Decodes the json body of a response into a model value and reports a clear error when it does not fit.
func decodeResponseBody<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
    try JSONDecoder().decode(type, from: body)
}
