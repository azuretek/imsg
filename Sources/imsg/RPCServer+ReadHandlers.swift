import Foundation
import IMsgCore

extension RPCServer {
  func handleChatsList(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params,
      method: "chats.list",
      supportedKeys: ["limit", "unread_only", "unreadOnly"]
    )
    let limit = try params.integer("limit") ?? 20
    guard limit > 0 else {
      throw RPCError.invalidParams("limit must be a positive integer")
    }
    let unreadOnly = try params.boolean("unread_only", aliases: ["unreadOnly"]) ?? false
    let database = try await databaseResources.require()
    let store = database.store
    guard !unreadOnly || store.supportsUnreadState else {
      throw RPCError.invalidParams(
        "unread_only is unavailable because this Messages database has no read-state column")
    }
    let chats = try store.listChats(limit: limit, unreadOnly: unreadOnly)
    var payloads: [[String: Any]] = []
    payloads.reserveCapacity(chats.count)

    for chat in chats {
      let info = try store.chatInfo(chatID: chat.id)
      let participants = try store.participants(chatID: chat.id)
      let contactName = contactNameForChat(
        chat: chat,
        chatInfo: info,
        participants: participants,
        contacts: contactResolver
      )
      payloads.append(
        try ChatPayload(
          chat: chat,
          chatInfo: info,
          participants: participants,
          contactName: contactName
        ).asDictionary())
    }

    respond(id: id, result: ["chats": payloads])
  }

  func handleMessagesHistory(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params,
      method: "messages.history",
      supportedKeys: [
        "chat_id", "limit", "participants", "start", "end", "attachments",
        "convert_attachments", "before_cursor", "after_cursor",
      ]
    )
    guard let chatID = try params.int64("chat_id") else {
      throw RPCError.invalidParams("chat_id is required")
    }
    guard chatID > 0 else {
      throw RPCError.invalidParams("chat_id must be a positive integer")
    }
    let limit = try params.integer("limit") ?? 50
    guard limit > 0 else {
      throw RPCError.invalidParams("limit must be a positive integer")
    }
    let beforeToken = try params.string("before_cursor")
    let afterToken = try params.string("after_cursor")
    let before = beforeToken.flatMap { HistoryCursor(token: $0) }
    let after = afterToken.flatMap { HistoryCursor(token: $0) }
    guard beforeToken == nil || before != nil, afterToken == nil || after != nil,
      beforeToken == nil || afterToken == nil
    else { throw RPCError.invalidParams("provide one valid before_cursor or after_cursor") }
    guard limit < Int.max else { throw RPCError.invalidParams("limit is too large") }
    let participants = try params.stringArray("participants") ?? []
    let startISO = try params.string("start")
    let endISO = try params.string("end")
    let includeAttachments = try params.boolean("attachments") ?? false
    let attachmentOptions = AttachmentQueryOptions(
      convertUnsupported: try params.boolean("convert_attachments") ?? false)
    let database = try await databaseResources.require()
    let store = database.store
    let dates = try MessageFilter.fromISO(
      participants: participants,
      startISO: startISO,
      endISO: endISO
    )
    let filter = MessageFilter(
      participants: dates.participants, startDate: dates.startDate, endDate: dates.endDate,
      before: before, after: after)
    let page = try store.messages(chatID: chatID, limit: limit + 1, filter: filter)
    let filtered = Array(page.prefix(limit))
    let reactionsByMessageID = try store.reactions(for: filtered)

    var payloads: [[String: Any]] = []
    payloads.reserveCapacity(filtered.count)
    for message in filtered {
      var payload = try buildMessagePayload(
        store: store,
        message: message,
        includeAttachments: includeAttachments,
        includeReactions: true,
        prefetchedReactions: reactionsByMessageID[message.rowID] ?? [],
        attachmentOptions: attachmentOptions,
        contactResolver: contactResolver
      )
      payload["history_cursor"] = try store.historyCursor(for: message).token
      payloads.append(payload)
    }

    var result: [String: Any] = ["messages": payloads, "has_more": page.count > limit]
    if let last = filtered.last {
      result["next_cursor"] = try store.historyCursor(for: last).token
    }
    respond(id: id, result: result)
  }

}
