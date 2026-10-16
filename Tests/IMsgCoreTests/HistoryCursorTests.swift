import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func historyCursorKeepsNanosecondsAndRejectsMalformedTokens() {
  let cursor = HistoryCursor(timestamp: Int64.max, rowID: Int64.max)
  #expect(HistoryCursor(token: cursor.token) == cursor)
  for token in ["", "1", "1:0", "1:-1", "1:2:3", "x:2", "9223372036854775808:1"] {
    #expect(HistoryCursor(token: token) == nil)
  }
}

@Test
func historyCursorPagesTiesBothWaysWithoutGapsOrDuplicates() throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(db)
  try db.execute(
    "INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name) VALUES (1, 'fixture', 'fixture', '', 'iMessage')"
  )
  // Reverse row-ID/time order and keep nanosecond differences Date cannot represent.
  let epoch: Int64 = 800_000_000_000_000_000
  let times: [Int64] = [epoch + 2, epoch, epoch + 1, epoch, epoch + 1, epoch, epoch]
  for (index, timestamp) in times.enumerated() {
    try db.run(
      "INSERT INTO message(ROWID, text, date, is_from_me) VALUES (?, 'fixture', ?, 0)",
      index + 1, timestamp)
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)", index + 1)
  }
  let store = try MessageStore(connection: db, path: ":memory:")
  let expected: [Int64] = [1, 5, 3, 7, 6, 4, 2]
  var descending: [Int64] = []
  var before: HistoryCursor?
  while descending.count <= times.count {
    let page = try store.messages(chatID: 1, limit: 2, filter: MessageFilter(before: before))
    guard let last = page.last else { break }
    descending.append(contentsOf: page.map { $0.rowID })
    before = try store.historyCursor(for: last)
  }
  #expect(descending == expected)
  #expect(Set(descending).count == times.count)
  var ascending: [Int64] = []
  var after = HistoryCursor(timestamp: epoch - 1, rowID: 1)
  while ascending.count <= times.count {
    let page = try store.messages(chatID: 1, limit: 2, filter: MessageFilter(after: after))
    guard let last = page.last else { break }
    ascending.append(contentsOf: page.map { $0.rowID })
    after = try store.historyCursor(for: last)
  }
  #expect(ascending == expected.reversed())
  #expect(Set(ascending).count == times.count)
  // A cursor survives deletion of its anchor.
  let anchor = HistoryCursor(timestamp: epoch + 1, rowID: 5)
  try db.run("DELETE FROM message WHERE ROWID = 5")
  let next = try store.messages(chatID: 1, limit: 2, filter: MessageFilter(before: anchor))
  #expect(next.map { $0.rowID } == [3, 7])
}
