import Foundation

enum TestSupport {
    static func unixSecond(from date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }
}
