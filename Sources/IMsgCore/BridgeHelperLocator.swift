import Foundation

/// Locates the injectable bridge helper dylib, `imsg-bridge-helper.dylib`.
///
/// There is deliberately **no fallback chain**. The location is a single chosen value,
/// never an ordered list of candidates walked from one to the next. The one value is:
///
///   1. `IMSG_BRIDGE_HELPER_DYLIB`, when it is set - the configured source; or
///   2. our own sibling layout, `<directory of the running binary>/imsg-bridge-helper.dylib`,
///      the single documented default for a development build.
///
/// A configured value that does not exist is a hard failure: the resolver does not
/// substitute the sibling, a bare name, a build directory, or any package manager's
/// tree. `failureMessage(_:)` names the setting, the value it held, and the one path
/// that was checked.
public enum BridgeHelperLocator {
  public static let fileName = "imsg-bridge-helper.dylib"

  /// The configuration key (environment variable) that names the helper dylib path.
  public static let configuredPathKey = "IMSG_BRIDGE_HELPER_DYLIB"

  /// The single documented default: the helper beside the running binary. One value,
  /// chosen - never a list that is walked.
  public static func siblingPath(executableURL: URL) -> String {
    executableURL.deletingLastPathComponent()
      .appendingPathComponent(fileName)
      .path
  }

  /// The outcome of locating the helper: the one path checked, the setting that carries
  /// it, the value the setting held (nil when it was not set), and whether it was there.
  public struct Lookup: Sendable, Equatable {
    public let setting: String
    public let value: String?
    public let checked: String
    public let resolved: Bool
  }

  /// Chooses the single path and checks it. No list, no order, no substitution.
  public static func lookup(
    configured: String? = ProcessInfo.processInfo.environment[configuredPathKey],
    executableURL: URL? = Bundle.main.executableURL,
    fileManager: FileManager = .default
  ) -> Lookup? {
    if let configured, !configured.isEmpty {
      return Lookup(
        setting: configuredPathKey,
        value: configured,
        checked: configured,
        resolved: fileManager.fileExists(atPath: configured)
      )
    }
    guard let executableURL else { return nil }
    let sibling = siblingPath(executableURL: executableURL)
    return Lookup(
      setting: configuredPathKey,
      value: nil,
      checked: sibling,
      resolved: fileManager.fileExists(atPath: sibling)
    )
  }

  /// The resolved helper path, or nil when the single checked path is not there.
  public static func resolve(
    customPath: String? = nil,
    executableURL: URL? = Bundle.main.executableURL,
    fileManager: FileManager = .default
  ) -> String? {
    let configured = customPath ?? ProcessInfo.processInfo.environment[configuredPathKey]
    guard let result = lookup(
      configured: configured,
      executableURL: executableURL,
      fileManager: fileManager
    ), result.resolved else {
      return nil
    }
    return result.checked
  }

  /// The hard failure: names the setting, the value it held, and the path checked.
  public static func failureMessage(_ lookup: Lookup?) -> String {
    guard let lookup else {
      return "Could not locate \(fileName): the running executable has no directory and "
        + "\(configuredPathKey) is not set."
    }
    if let value = lookup.value {
      return "\(fileName) not found. \(configuredPathKey)=\"\(value)\"; checked \(lookup.checked)."
    }
    return "\(fileName) not found. \(configuredPathKey) is not set; checked the sibling "
      + "path \(lookup.checked)."
  }
}
