public enum MetricOrdering {
    /// Move to the target's position, shifting intervening items rather than swapping them.
    public static func moving(_ metric: Metric, to target: Metric, in order: [Metric]) -> [Metric] {
        guard metric != target, let source = order.firstIndex(of: metric),
              let destination = order.firstIndex(of: target) else { return order }
        var result = order
        result.remove(at: source)
        result.insert(metric, at: destination)
        return result
    }
}
