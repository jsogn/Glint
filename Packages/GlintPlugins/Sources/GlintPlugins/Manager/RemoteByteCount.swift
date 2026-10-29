enum RemoteByteCount {
    static func checkedSum<S: Sequence>(_ values: S) -> Int64?
    where S.Element == Int64 {
        var total: Int64 = 0
        for value in values {
            guard value >= 0 else { return nil }
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }

    static func checkedProduct(_ value: Int64, _ multiplier: Int64) -> Int64? {
        guard value >= 0, multiplier >= 0 else { return nil }
        let multiplication = value.multipliedReportingOverflow(by: multiplier)
        return multiplication.overflow ? nil : multiplication.partialValue
    }
}
