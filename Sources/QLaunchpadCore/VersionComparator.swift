import Foundation

public enum VersionComparator {
    /// Compares two version strings (e.g. "v1.1", "V1.1", "1.1.0", "1.0.24", "1.0.24-preview").
    /// Returns true if `v1` is strictly greater than `v2`.
    public static func isVersion(_ v1: String, greaterThan v2: String) -> Bool {
        func parse(_ s: String) -> [Int] {
            var clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.hasPrefix("v") || clean.hasPrefix("V") {
                clean.removeFirst()
            }
            if let hyphenIndex = clean.firstIndex(of: "-") {
                clean = String(clean[..<hyphenIndex])
            }
            return clean.split(separator: ".").compactMap { Int($0) }
        }

        let p1 = parse(v1)
        let p2 = parse(v2)
        guard !p1.isEmpty && !p2.isEmpty else { return false }

        let count = max(p1.count, p2.count)
        for i in 0..<count {
            let num1 = i < p1.count ? p1[i] : 0
            let num2 = i < p2.count ? p2[i] : 0
            if num1 != num2 {
                return num1 > num2
            }
        }
        return false
    }
}
