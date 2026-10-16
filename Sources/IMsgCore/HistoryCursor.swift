import Foundation

/// Lossless database timestamp and unique row ID. Decimal strings avoid JSON and Date rounding.
public struct HistoryCursor: Sendable, Equatable, Comparable {
  public let timestamp: Int64
  public let rowID: Int64

  public init(timestamp: Int64, rowID: Int64) {
    self.timestamp = timestamp
    self.rowID = rowID
  }

  public init?(token: String) {
    let parts = token.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let timestamp = Int64(parts[0]), let rowID = Int64(parts[1]),
      rowID > 0
    else { return nil }
    self.init(timestamp: timestamp, rowID: rowID)
  }

  public var token: String { "\(timestamp):\(rowID)" }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.timestamp == rhs.timestamp ? lhs.rowID < rhs.rowID : lhs.timestamp < rhs.timestamp
  }
}
