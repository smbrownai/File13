import Foundation
import SwiftData

@Model
public final class CachedMessage {
    #Index<CachedMessage>([\.accountId, \.mailboxName])

    var messageId: String
    var accountId: UUID
    var mailboxName: String = "INBOX"
    var uid: UInt32
    var senderName: String
    var senderAddress: String
    var subject: String
    var date: Date
    var fetchedAt: Date
    var isRead: Bool = false

    // Triage-oriented metadata (no body content). Defaults make the SwiftData lightweight
    // migration safe — older rows fill in with empty/false/nil.
    var toAddresses: [String] = []
    var ccAddresses: [String] = []
    var listUnsubscribe: String? = nil
    var listUnsubscribePost: String? = nil
    var listId: String? = nil
    var isAutoSubmitted: Bool = false
    var inReplyTo: String? = nil
    var sizeBytes: UInt32 = 0     // 0 ⇒ unknown
    /// Whether the message has at least one attachment. Sourced from BODYSTRUCTURE when
    /// available; `nil` ⇒ unknown (the slim header fetch deliberately skips BODYSTRUCTURE,
    /// so rows fetched on that path leave this empty until a future enrichment pass).
    /// Only the boolean is persisted — attachment names, MIME types, and bytes are not stored.
    var hasAttachments: Bool? = nil

    public init(messageId: String,
         accountId: UUID,
         mailboxName: String,
         uid: UInt32,
         senderName: String,
         senderAddress: String,
         subject: String,
         date: Date,
         fetchedAt: Date = .now,
         isRead: Bool = false,
         toAddresses: [String] = [],
         ccAddresses: [String] = [],
         listUnsubscribe: String? = nil,
         listUnsubscribePost: String? = nil,
         listId: String? = nil,
         isAutoSubmitted: Bool = false,
         inReplyTo: String? = nil,
         sizeBytes: UInt32 = 0,
         hasAttachments: Bool? = nil) {
        self.messageId = messageId
        self.accountId = accountId
        self.mailboxName = mailboxName
        self.uid = uid
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.subject = subject
        self.date = date
        self.fetchedAt = fetchedAt
        self.isRead = isRead
        self.toAddresses = toAddresses
        self.ccAddresses = ccAddresses
        self.listUnsubscribe = listUnsubscribe
        self.listUnsubscribePost = listUnsubscribePost
        self.listId = listId
        self.isAutoSubmitted = isAutoSubmitted
        self.inReplyTo = inReplyTo
        self.sizeBytes = sizeBytes
        self.hasAttachments = hasAttachments
    }

    public convenience init(_ header: MessageHeader, mailbox: String, fetchedAt: Date = .now) {
        self.init(
            messageId: header.rawMessageId,
            accountId: header.accountId,
            mailboxName: mailbox,
            uid: header.uid ?? 0,
            senderName: header.senderName,
            senderAddress: header.senderAddress,
            subject: header.subject,
            date: header.date,
            fetchedAt: fetchedAt,
            isRead: header.isRead,
            toAddresses: header.toAddresses,
            ccAddresses: header.ccAddresses,
            listUnsubscribe: header.listUnsubscribe,
            listUnsubscribePost: header.listUnsubscribePost,
            listId: header.listId,
            isAutoSubmitted: header.isAutoSubmitted,
            inReplyTo: header.inReplyTo,
            sizeBytes: header.sizeBytes ?? 0,
            hasAttachments: header.hasAttachments
        )
    }

    public func toHeader() -> MessageHeader {
        MessageHeader(
            rawMessageId: messageId,
            uid: uid == 0 ? nil : uid,
            senderName: senderName,
            senderAddress: senderAddress,
            subject: subject,
            date: date,
            accountId: accountId,
            isRead: isRead,
            toAddresses: toAddresses,
            ccAddresses: ccAddresses,
            listUnsubscribe: listUnsubscribe,
            listUnsubscribePost: listUnsubscribePost,
            listId: listId,
            isAutoSubmitted: isAutoSubmitted,
            inReplyTo: inReplyTo,
            sizeBytes: sizeBytes == 0 ? nil : sizeBytes,
            hasAttachments: hasAttachments
        )
    }
}
