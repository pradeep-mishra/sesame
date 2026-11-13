import Foundation

/// Follows the next-page link of a paginated response until there are no more pages and gathers every item.
func fetchAllPages(firstPage: String, fetch: (String) -> ([String], String?)) -> [String] {
    var items: [String] = []
    var next: String? = firstPage
    while let page = next {
        let (found, following) = fetch(page)
        items += found
        next = following
    }
    return items
}
