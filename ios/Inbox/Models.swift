import Foundation

struct MailAccount: Codable, Identifiable, Equatable {
    var id: String // Verified Google email; also namespaces Gmail IDs.
    var name: String
}

struct Ranking: Codable {
    var score: Int
    var cat: String?
    var why: String?
}

struct RankDocument: Decodable {
    var version: Int
    var account: String
    var rankings: [String: Ranking]
}

struct Mail: Identifiable, Equatable {
    var account: String
    var gmailID: String
    var threadID: String
    var sender: String
    var senderAddress: String
    var subject: String
    var body: String
    var date: Date
    var unread: Bool
    var starred: Bool
    var score: Int = 40
    var category: String = "Product"
    var reason: String = "Sorted by Gmail’s labels."
    var id: String { account + ":" + gmailID }
}

struct GmailMessage: Decodable {
    struct Header: Decodable { var name: String; var value: String }
    struct PartBody: Decodable { var data: String?; var attachmentId: String?; var size: Int? }
    struct Part: Decodable {
        var mimeType: String?
        var filename: String?
        var headers: [Header]?
        var body: PartBody?
        var parts: [Part]?
        func header(_ name: String) -> String {
            headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        var plainText: String? {
            if mimeType == "text/plain", let data = body?.data { return Data(base64URL: data).flatMap { String(data: $0, encoding: .utf8) } }
            return parts?.compactMap(\.plainText).joined(separator: "\n\n").nilIfEmpty
        }
        /// The email's own HTML, with inline images that came with the message filled in.
        var html: String? {
            guard var page = htmlPart else { return nil }
            for part in inlineImages {
                let cid = part.header("Content-ID").trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
                if let data = part.body?.data, !cid.isEmpty, let raw = Data(base64URL: data) {
                    page = page.replacingOccurrences(of: "cid:" + cid, with: "data:\(part.mimeType ?? "image/png");base64," + raw.base64EncodedString())
                }
            }
            return page
        }
        private var htmlPart: String? {
            if mimeType == "text/html", let data = body?.data { return Data(base64URL: data).flatMap { String(data: $0, encoding: .utf8) } }
            return parts?.lazy.compactMap(\.htmlPart).first
        }
        var inlineImages: [Part] {
            ((mimeType ?? "").hasPrefix("image/") && !header("Content-ID").isEmpty ? [self] : []) + (parts ?? []).flatMap(\.inlineImages)
        }
        var attachments: [Part] {
            (filename?.isEmpty == false ? [self] : []) + (parts ?? []).flatMap(\.attachments)
        }
    }
    var id: String
    var threadId: String?
    var labelIds: [String]?
    var snippet: String?
    var internalDate: String?
    var payload: Part?
    func mail(account: String, ranking: Ranking? = nil) -> Mail {
        let from = payload?.header("From") ?? ""
        let pieces = from.split(separator: "<", maxSplits: 1).map(String.init)
        let name = (pieces.first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let address = pieces.count > 1 ? pieces[1].replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces) : from
        let labels = labelIds ?? []
        let promo = labels.contains("CATEGORY_PROMOTIONS")
        return Mail(account: account, gmailID: id, threadID: threadId ?? id, sender: name.isEmpty ? address : name,
                    senderAddress: address, subject: payload?.header("Subject").nilIfEmpty ?? "(no subject)",
                    body: payload?.plainText ?? snippet ?? "No plain-text preview available.",
                    date: Date(timeIntervalSince1970: (Double(internalDate ?? "0") ?? 0) / 1000),
                    unread: labels.contains("UNREAD"), starred: labels.contains("STARRED"),
                    score: ranking?.score ?? (promo ? 15 : 45), category: ranking?.cat ?? (promo ? "Promotions" : "Product"),
                    reason: ranking?.why ?? "Sorted by Gmail’s labels. AI ranking appears after the Mac publishes it.")
    }
}

struct CalendarEvent: Identifiable {
    var account: String
    var googleID: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String
    var link: URL?
    var id: String { account + ":" + googleID }
    var timeLabel: String { allDay ? "All day" : start.formatted(date: .omitted, time: .shortened) + " – " + end.formatted(date: .omitted, time: .shortened) }
}

struct GoogleEvent: Decodable {
    struct Time: Decodable { var date: String?; var dateTime: String? }
    var id: String
    var summary: String?
    var start: Time?
    var end: Time?
    var status: String?
    var location: String?
    var hangoutLink: String?
    func event(account: String) -> CalendarEvent? {
        guard status != "cancelled", let start, let end,
              let first = Self.parse(start), let last = Self.parse(end) else { return nil }
        return CalendarEvent(account: account, googleID: id, title: summary ?? "Untitled event", start: first,
                             end: last, allDay: start.date != nil, location: location ?? "", link: hangoutLink.flatMap(URL.init(string:)))
    }
    static func parse(_ value: Time) -> Date? {
        if let raw = value.dateTime { return ISO8601DateFormatter().date(from: raw) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return value.date.flatMap(formatter.date(from:))
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var safeHeader: String { replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }
}

extension Data {
    init?(base64URL: String) {
        let value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

enum MailEncoding {
    static func raw(from: String, to: String, cc: String = "", bcc: String = "", subject: String, body: String, replyHeaders: [String: String] = [:]) -> String {
        var headers = ["From: \(from.safeHeader)", "To: \(to.safeHeader)"]
        if !cc.isEmpty { headers.append("Cc: \(cc.safeHeader)") }
        if !bcc.isEmpty { headers.append("Bcc: \(bcc.safeHeader)") }
        headers += [
                       "Subject: =?UTF-8?B?\(Data(subject.safeHeader.utf8).base64EncodedString())?=",
                       "MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64"]
        for name in ["In-Reply-To", "References"] {
            if let value = replyHeaders[name], !value.isEmpty { headers.append("\(name): \(value.safeHeader)") }
        }
        let encoded = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + encoded).utf8).base64URL
    }
}
