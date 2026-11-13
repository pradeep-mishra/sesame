import Foundation

/// Reads dates written in many loose formats and returns the first one that parses.
func parseLooseDates(_ text: String) -> Date? {
    let formats = ["yyyy-MM-dd", "dd/MM/yyyy", "MMM d, yyyy"]
    for format in formats {
        let f = DateFormatter()
        f.dateFormat = format
        if let d = f.date(from: text) { return d }
    }
    return nil
}
