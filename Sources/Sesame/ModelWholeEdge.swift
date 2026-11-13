/// Sees the model go from not whole to whole. `update` is fed the current answer at each look and returns true once per
/// such change. The first look never answers true: a model that is whole at launch is not a change.
struct ModelWholeEdge {
    private var last: Bool?

    init() {}

    mutating func update(isWhole: Bool) -> Bool {
        defer { last = isWhole }
        return last == false && isWhole
    }
}
