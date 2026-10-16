import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcHistoryCursorContinuesWithoutRepeatingBoundary() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":1,"method":"messages.history","params":{"chat_id":1,"limit":1}}"#)
  let result = try #require(output.responses.last?["result"] as? [String: Any])
  let messages = try #require(result["messages"] as? [[String: Any]])
  let cursor = try #require(result["next_cursor"] as? String)
  #expect(messages.count == 1)
  #expect(messages.first?["history_cursor"] as? String == cursor)
  #expect(result["has_more"] as? Bool == false)
  let request: [String: Any] = [
    "jsonrpc": "2.0", "id": 2, "method": "messages.history",
    "params": ["chat_id": 1, "limit": 1, "before_cursor": cursor],
  ]
  let data = try JSONSerialization.data(withJSONObject: request)
  await server.handleLineForTesting(String(decoding: data, as: UTF8.self))
  let next = try #require(output.responses.last?["result"] as? [String: Any])
  #expect((next["messages"] as? [[String: Any]])?.isEmpty == true)
  #expect(next["has_more"] as? Bool == false)
  #expect(next["next_cursor"] == nil)
}

@Test(arguments: [
  #"{"before_cursor":"bad"}"#,
  #"{"after_cursor":"1:0"}"#,
  #"{"before_cursor":"1:1","after_cursor":"1:2"}"#,
])
func rpcHistoryRejectsInvalidCursorParameters(parameters: String) async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)
  var params = try #require(
    JSONSerialization.jsonObject(with: Data(parameters.utf8)) as? [String: Any])
  params["chat_id"] = 1
  let request: [String: Any] = [
    "jsonrpc": "2.0", "id": 1, "method": "messages.history", "params": params,
  ]
  let data = try JSONSerialization.data(withJSONObject: request)
  await server.handleLineForTesting(String(decoding: data, as: UTF8.self))
  let error = output.errors.last?["error"] as? [String: Any]
  #expect(rpcTestInt64Value(error?["code"]) == -32602)
  #expect(output.responses.isEmpty)
}
