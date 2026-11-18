extension Duration {
    /// Total elapsed milliseconds represented by this duration.
    public var inMilliseconds: Double {
        let components = components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    /// Total elapsed seconds represented by this duration.
    public var inSeconds: Double {
        inMilliseconds / 1_000
    }
}
