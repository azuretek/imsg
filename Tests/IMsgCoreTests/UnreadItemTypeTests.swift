import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test(arguments: [false, true])
func unreadCountsExcludeEventItemsWithoutScanningHistory(hasItemType: Bool) throws {
  let db = try Connection(.inMemory)
  try MessageDatabaseFixture.createSchema(
    db, options: MessageDatabaseFixture.SchemaOptions(includeReadState: true)
  )
  if hasItemType {
    try db.execute("ALTER TABLE message ADD COLUMN item_type INTEGER DEFAULT 0")
  }
  try db.execute(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, 'events', 'iMessage;+;events', 'Events', 'iMessage'),
           (2, 'ordinary', 'iMessage;+;ordinary', 'Ordinary', 'iMessage');
    INSERT INTO handle(ROWID, id) VALUES (1, 'sender@example.invalid');
    """)
  for itemType in 1...5 {
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, is_read)
      VALUES (?, 1, ?, ?, 0, 'iMessage', 0)
      """, itemType, itemType == 2 ? "event with visible text" : "", itemType + 10000)
    if hasItemType {
      try db.run("UPDATE message SET item_type = ? WHERE ROWID = ?", itemType, itemType)
    }
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)", itemType)
  }
  // A genuinely unread row can predate thousands of read messages. Counts must not page history.
  try db.execute(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, is_read)
    VALUES (10, 1, 'old unread text', 1, 0, 'iMessage', 0),
           (11, 1, '', 2, 0, 'iMessage', 0),
           (12, 1, 'outgoing', 3, 1, 'iMessage', 0);
    INSERT INTO chat_message_join(chat_id, message_id) VALUES (2, 10), (2, 11), (2, 12);
    INSERT INTO attachment(ROWID, filename, transfer_name, mime_type, total_bytes, is_sticker)
    VALUES (1, '', 'GroupPhotoImage', 'image/png', 10, 0),
           (2, '', 'BrandLogoImage', 'image/png', 10, 0),
           (3, '', 'ordinary.png', 'image/png', 10, 0);
    INSERT INTO message_attachment_join(message_id, attachment_id)
    VALUES (3, 1), (4, 2), (11, 3);
    WITH RECURSIVE n(x) AS (SELECT 100 UNION ALL SELECT x + 1 FROM n WHERE x < 10100)
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, is_read)
    SELECT x, 1, 'already read', x, 0, 'iMessage', 1 FROM n;
    INSERT INTO chat_message_join(chat_id, message_id)
    SELECT 2, ROWID FROM message WHERE ROWID >= 100;
    """)
  let store = try MessageStore(connection: db, path: ":memory:")
  let chats = try store.listChats(limit: 10)
  #expect(chats.first { $0.identifier == "events" }?.unreadCount == (hasItemType ? 0 : 5))
  #expect(chats.first { $0.identifier == "ordinary" }?.unreadCount == 2)
  let unread = try store.listChats(limit: 10, unreadOnly: true)
  #expect(unread.contains { $0.identifier == "events" } == !hasItemType)
  #expect(unread.contains { $0.identifier == "ordinary" })
}
