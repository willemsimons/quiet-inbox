import Foundation

@MainActor final class GoogleAPI {
    let session: GoogleSession
    init(session: GoogleSession) { self.session = session }
    func url(_ base: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(string: base)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.url!
    }
    func data(_ account: String, _ path: String, method: String = "GET", body: [String: Any]? = nil, query: [String: String] = [:]) async throws -> Data {
        try await session.request(account: account, url: url(path, query: query), method: method, body: body)
    }
    private let gmail = "https://gmail.googleapis.com/gmail/v1/users/me"
    func inbox(_ account: String) async throws -> [Mail] {
        struct Listing: Decodable { struct Item: Decodable { var id: String }; var messages: [Item]? }
        let list = try JSONDecoder().decode(Listing.self, from: await data(account, gmail + "/messages", query: ["q": "in:inbox newer_than:14d", "maxResults": "60"]))
        var result: [Mail] = []
        // Bound concurrency to avoid a request burst on large inboxes.
        let ids = list.messages?.map(\.id) ?? []
        for start in stride(from: 0, to: ids.count, by: 6) {
            let batch = Array(ids[start..<min(start + 6, ids.count)])
            let messages = try await withThrowingTaskGroup(of: Mail.self) { group in
                for id in batch {
                    group.addTask { @MainActor in
                        let message = try await self.message(account, id: id)
                        return message.mail(account: account)
                    }
                }
                var fetched: [Mail] = []
                for try await message in group { fetched.append(message) }
                return fetched
            }
            result += messages
        }
        return result
    }
    func message(_ account: String, id: String) async throws -> GmailMessage {
        try JSONDecoder().decode(GmailMessage.self, from: await data(account, gmail + "/messages/" + id, query: ["format": "full"]))
    }
    func thread(_ mail: Mail) async throws -> [GmailMessage] {
        struct Thread: Decodable { var messages: [GmailMessage]? }
        return try JSONDecoder().decode(Thread.self, from: await data(mail.account, gmail + "/threads/" + mail.threadID, query: ["format": "full"])).messages ?? []
    }
    func flags(_ mail: Mail, label: String, value: Bool) async throws {
        _ = try await data(mail.account, gmail + "/messages/" + mail.gmailID + "/modify", method: "POST", body: [value ? "addLabelIds" : "removeLabelIds": [label]])
    }
    func trash(_ mail: Mail) async throws {
        _ = try await data(mail.account, gmail + "/messages/" + mail.gmailID + "/trash", method: "POST")
    }
    func send(account: String, to: String, cc: String = "", bcc: String = "", subject: String, body: String, reply: Mail?) async throws {
        var headers: [String: String] = [:], payload: [String: Any] = [:]
        if let reply {
            let part = try await message(account, id: reply.gmailID).payload
            if let messageID = part?.header("Message-ID").nilIfEmpty {
                headers["In-Reply-To"] = messageID
                headers["References"] = ((part?.header("References") ?? "") + " " + messageID).trimmingCharacters(in: .whitespaces)
            }
            payload["threadId"] = reply.threadID
        }
        payload["raw"] = MailEncoding.raw(from: account, to: to, cc: cc, bcc: bcc, subject: subject, body: body, replyHeaders: headers)
        _ = try await data(account, gmail + "/messages/send", method: "POST", body: payload)
    }
    func rankings(_ account: String) async throws -> [String: Ranking] {
        struct Files: Decodable { struct File: Decodable { var id: String }; var files: [File] }
        let list = try JSONDecoder().decode(Files.self, from: await data(account, "https://www.googleapis.com/drive/v3/files", query: [
            "spaces": "appDataFolder", "q": "name = 'inbox-rankings-v1.json' and trashed = false", "fields": "files(id)", "orderBy": "modifiedTime desc", "pageSize": "1"]))
        guard let id = list.files.first?.id else { return [:] }
        let document = try JSONDecoder().decode(RankDocument.self, from: await data(account, "https://www.googleapis.com/drive/v3/files/" + id, query: ["alt": "media"]))
        guard document.version == 1, document.account.lowercased() == account.lowercased() else { return [:] }
        return document.rankings
    }
    func events(_ account: String) async throws -> [CalendarEvent] {
        struct Events: Decodable { var items: [GoogleEvent]?; var nextPageToken: String? }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 14, to: start)!
        let formatter = ISO8601DateFormatter()
        var query = ["timeMin": formatter.string(from: start), "timeMax": formatter.string(from: end), "singleEvents": "true", "orderBy": "startTime", "maxResults": "250"]
        var result: [CalendarEvent] = []
        repeat {
            let page = try JSONDecoder().decode(Events.self, from: await data(account, "https://www.googleapis.com/calendar/v3/calendars/primary/events", query: query))
            result += (page.items ?? []).compactMap { $0.event(account: account) }
            query["pageToken"] = page.nextPageToken
        } while query["pageToken"] != nil
        return result
    }
    func createEvent(account: String, title: String, start: Date, end: Date, location: String) async throws {
        let formatter = ISO8601DateFormatter()
        _ = try await data(account, "https://www.googleapis.com/calendar/v3/calendars/primary/events", method: "POST", body: [
            "summary": title, "location": location, "start": ["dateTime": formatter.string(from: start)], "end": ["dateTime": formatter.string(from: end)]])
    }
}
