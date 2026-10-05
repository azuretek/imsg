import Foundation
import Testing

@testable import IMsgCore

@Suite("bridge helper locator")
struct BridgeHelperLocatorTests {
  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imsg-bridge-helper-tests")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test("an explicit configured path is honoured, and it is the one path checked")
  func configuredOverrideIsHonoured() throws {
    let directory = try temporaryDirectory()
    let helper = directory.appendingPathComponent(BridgeHelperLocator.fileName)
    try Data().write(to: helper)

    let lookup = BridgeHelperLocator.lookup(configured: helper.path, executableURL: nil)
    #expect(lookup?.setting == BridgeHelperLocator.configuredPathKey)
    #expect(lookup?.value == helper.path)
    #expect(lookup?.checked == helper.path)
    #expect(lookup?.resolved == true)
    #expect(BridgeHelperLocator.resolve(customPath: helper.path, executableURL: nil) == helper.path)
  }

  @Test("with no setting, the sibling helper is the one chosen path and it resolves")
  func siblingHelperResolves() throws {
    let directory = try temporaryDirectory()
    let executable = directory.appendingPathComponent("imsg")
    let helper = directory.appendingPathComponent(BridgeHelperLocator.fileName)
    try Data().write(to: helper)

    let lookup = BridgeHelperLocator.lookup(configured: nil, executableURL: executable)
    #expect(lookup?.value == nil)
    #expect(lookup?.checked == helper.path)
    #expect(lookup?.resolved == true)
  }

  @Test("a configured value that is missing fails hard and names setting, value and path")
  func missingConfiguredValueFailsHard() {
    let missing = "/nonexistent/imsg-bridge-helper.dylib"
    let lookup = BridgeHelperLocator.lookup(configured: missing, executableURL: nil)
    #expect(lookup?.resolved == false)

    let message = BridgeHelperLocator.failureMessage(lookup)
    #expect(message.contains(BridgeHelperLocator.configuredPathKey))
    #expect(message.contains(missing))
  }

  @Test("a missing sibling names the setting and the path it checked")
  func missingSiblingNamesSettingAndPath() throws {
    let directory = try temporaryDirectory()
    let executable = directory.appendingPathComponent("imsg")
    let lookup = BridgeHelperLocator.lookup(configured: nil, executableURL: executable)
    #expect(lookup?.resolved == false)

    let message = BridgeHelperLocator.failureMessage(lookup)
    #expect(message.contains(BridgeHelperLocator.configuredPathKey))
    #expect(message.contains(BridgeHelperLocator.siblingPath(executableURL: executable)))
  }

  @Test("a missing configured value is not substituted by an existing sibling")
  func noFallbackToSibling() throws {
    let directory = try temporaryDirectory()
    let executable = directory.appendingPathComponent("imsg")
    let sibling = directory.appendingPathComponent(BridgeHelperLocator.fileName)
    try Data().write(to: sibling)

    let missing = directory.appendingPathComponent("configured-elsewhere.dylib")
    let lookup = BridgeHelperLocator.lookup(configured: missing.path, executableURL: executable)
    #expect(lookup?.resolved == false)
    #expect(lookup?.checked == missing.path)
  }

  @Test("the resolver ships no candidate list and no package manager path")
  func resolverSourceHasNoChainAndNoHomebrew() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/IMsgCore/BridgeHelperLocator.swift"),
      encoding: .utf8
    )
    for needle in [
      "/opt/homebrew", "/usr/local", "HOMEBREW_PREFIX", ".build/release", ".build/debug",
      "searchPaths", "var paths",
    ] {
      #expect(!source.contains(needle), "the resolver must not name \(needle)")
    }
  }
}
