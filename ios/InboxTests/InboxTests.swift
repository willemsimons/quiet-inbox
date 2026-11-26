import XCTest
@testable import Inbox

final class InboxTests: XCTestCase {
    func testSelectionAdvancesAndHandlesEmptyOrRefreshedInbox() {
        XCTAssertEqual(InboxSelection.reconcile(selected: "b", old: ["a", "b", "c"], new: ["a", "c"]), "c")
        XCTAssertEqual(InboxSelection.reconcile(selected: "c", old: ["a", "b", "c"], new: ["a", "b"]), "b")
        XCTAssertEqual(InboxSelection.reconcile(selected: "b", old: ["a", "b"], new: ["new", "a", "b"]), "b")
        XCTAssertNil(InboxSelection.reconcile(selected: "a", old: ["a"], new: []))
        XCTAssertEqual(InboxSelection.reconcile(selected: nil, old: [], new: ["a"]), "a")
    }
    func testReadFilterAndUnreadFilterAreMutuallyExclusiveEvenWhenStarred() throws {
        let message = try JSONDecoder().decode(GmailMessage.self, from: Data(#"{"id":"1","labelIds":["STARRED"]}"#.utf8))
        let mail = message.mail(account: "a")
        XCTAssertTrue(InboxSelection.matches(mail, filter: "Read", account: "all", search: ""))
        XCTAssertFalse(InboxSelection.matches(mail, filter: "Unread", account: "all", search: ""))
        XCTAssertFalse(InboxSelection.matches(mail, filter: "Read", account: "other-account", search: ""))
    }
    func testMailboxIdentityIsScopedToAccount() throws {
        let message = try JSONDecoder().decode(GmailMessage.self, from: Data(#"{"id":"123","threadId":"thread"}"#.utf8))
        let one = message.mail(account: "first@example.com")
        let two = message.mail(account: "second@example.com")
        XCTAssertNotEqual(one.id, two.id)
        XCTAssertEqual(one.subject, "(no subject)")
    }
    func testGmailLabelsRemainAuthoritativeWithSharedRanking() throws {
        let json = #"{"id":"123","labelIds":["STARRED"],"payload":{"headers":[{"name":"Subject","value":"Hello"}]}}"#
        let mail = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8)).mail(account: "a", ranking: Ranking(score: 99, cat: "Investors", why: "Review"))
        XCTAssertFalse(mail.unread)
        XCTAssertTrue(mail.starred)
        XCTAssertEqual(mail.score, 99)
        XCTAssertEqual(mail.reason, "Review")
    }
    func testNestedMimeTextAndBase64URL() throws {
        let json = #"{"id":"1","payload":{"mimeType":"multipart/mixed","parts":[{"mimeType":"multipart/alternative","parts":[{"mimeType":"text/plain","body":{"data":"SGVsbG8g8J-MjQ"}}]}]}}"#
        let message = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.payload?.plainText, "Hello 🌍")
    }
    func testOutgoingMessagePreservesUnicodeAndReplyThreadHeaders() throws {
        let raw = MailEncoding.raw(from: "a@example.com", to: "b@example.com", subject: "Hello 🌍", body: "Café\nGood morning", replyHeaders: ["In-Reply-To": "<abc@example.com>", "References": "<older> <abc@example.com>"])
        let decoded = String(data: try XCTUnwrap(Data(base64URL: raw)), encoding: .utf8)!
        XCTAssertTrue(decoded.contains("In-Reply-To: <abc@example.com>\r\n"))
        XCTAssertTrue(decoded.contains("References: <older> <abc@example.com>\r\n"))
        let body = decoded.components(separatedBy: "\r\n\r\n").last!
        XCTAssertEqual(String(data: Data(base64Encoded: body, options: .ignoreUnknownCharacters)!, encoding: .utf8), "Café\nGood morning")
    }
    func testHeaderNewlinesCannotInjectRecipients() throws {
        let raw = MailEncoding.raw(from: "a@example.com", to: "b@example.com\r\nBcc: injected@example.com", subject: "Test", body: "test")
        let decoded = String(data: try XCTUnwrap(Data(base64URL: raw)), encoding: .utf8)!
        XCTAssertFalse(decoded.contains("\r\nBcc:"))
    }
    func testCancelledCalendarEventsAreOmitted() throws {
        let event = try JSONDecoder().decode(GoogleEvent.self, from: Data(#"{"id":"deleted","status":"cancelled"}"#.utf8))
        XCTAssertNil(event.event(account: "a"))
    }
    func testAllDayDatesUseLocalCalendarDay() throws {
        let json = #"{"id":"day","start":{"date":"2026-11-03"},"end":{"date":"2026-11-04"}}"#
        let event = try XCTUnwrap(JSONDecoder().decode(GoogleEvent.self, from: Data(json.utf8)).event(account: "a"))
        XCTAssertTrue(event.allDay)
        XCTAssertEqual(Calendar.current.component(.day, from: event.start), 3)
        XCTAssertEqual(event.timeLabel, "All day")
    }
    @MainActor func testDemoNeverRequiresGoogleAndCanBeCleared() async {
        let store = InboxStore(session: GoogleSession())
        store.showDemo()
        let item = store.mail[0]
        await store.flag(item, label: "UNREAD", value: false)
        XCTAssertFalse(store.mail[0].unread)
        let trashed = await store.trash(item)
        XCTAssertTrue(trashed)
        XCTAssertFalse(store.mail.contains { $0.id == item.id })
        store.exitDemo()
        XCTAssertTrue(store.mail.isEmpty)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertFalse(store.demo)
    }
}
