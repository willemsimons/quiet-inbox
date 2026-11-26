import AppAuth
import Foundation
import Security
import UIKit

struct InboxError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

@MainActor final class GoogleSession: ObservableObject {
    @Published private(set) var accounts: [MailAccount] = []
    private var states: [String: OIDAuthState] = [:]
    private var flow: OIDExternalUserAgentSession?
    private let service = "com.example.inbox.oauth"
    static let scopes = ["openid", "email", "https://www.googleapis.com/auth/gmail.modify",
                         "https://www.googleapis.com/auth/gmail.send", "https://www.googleapis.com/auth/calendar.events",
                         "https://www.googleapis.com/auth/drive.appdata"]
    var configured: Bool {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String else { return false }
        return id.hasSuffix(".apps.googleusercontent.com") && !id.contains("configure-me") && !id.contains("YOUR_")
    }
    init() {
        if let data = UserDefaults.standard.data(forKey: "InboxAccounts"), let saved = try? JSONDecoder().decode([MailAccount].self, from: data) {
            for account in saved {
                var query = keyQuery(account.id); query[kSecReturnData as String] = true
                var item: CFTypeRef?
                if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                   let data = item as? Data,
                   let state = try? NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data) {
                    states[account.id] = state; accounts.append(account)
                }
            }
        }
    }
    private func keyQuery(_ email: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: email]
    }
    private func persist(_ state: OIDAuthState, email: String) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
        let query = keyQuery(email)
        let changes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(changes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw InboxError(message: "Could not save Google sign-in to Keychain (\(status)).") }
    }
    private func saveAccounts() { UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: "InboxAccounts") }
    func remove(_ account: MailAccount) {
        SecItemDelete(keyQuery(account.id) as CFDictionary)
        states.removeValue(forKey: account.id); accounts.removeAll { $0.id == account.id }; saveAccounts()
    }
    func handle(_ url: URL) {
        if flow?.resumeExternalUserAgentFlow(with: url) == true { flow = nil }
    }
    func signIn() async throws {
        guard configured,
              let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String,
              let scheme = Bundle.main.object(forInfoDictionaryKey: "GoogleRedirectScheme") as? String,
              let redirect = URL(string: scheme + ":/oauthredirect") else {
            throw InboxError(message: "Add the iOS Google OAuth client ID in ios/Local.xcconfig, then rebuild. Setup steps are in ios/README.md.")
        }
        guard flow == nil else { return }
        guard var presenter = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
            throw InboxError(message: "Could not open Google sign-in.")
        }
        while let next = presenter.presentedViewController { presenter = next }
        let configuration = OIDServiceConfiguration(authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                                                    tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!)
        let request = OIDAuthorizationRequest(configuration: configuration, clientId: clientID, scopes: Self.scopes,
                                              redirectURL: redirect, responseType: OIDResponseTypeCode,
                                              additionalParameters: ["access_type": "offline", "prompt": "select_account consent"])
        let state: OIDAuthState = try await withCheckedThrowingContinuation { continuation in
            flow = OIDAuthState.authState(byPresenting: request, presenting: presenter) { state, error in
                self.flow = nil
                if let state { continuation.resume(returning: state) }
                else { continuation.resume(throwing: error ?? InboxError(message: "Google sign-in was cancelled.")) }
            }
        }
        let token = try await freshToken(state)
        var req = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let data = try await Self.send(req)
        struct Profile: Decodable { var email: String; var email_verified: Bool; var name: String? }
        let profile = try JSONDecoder().decode(Profile.self, from: data)
        guard profile.email_verified else { throw InboxError(message: "Google could not verify this email address.") }
        let email = profile.email.lowercased()
        try persist(state, email: email)
        states[email] = state
        if !accounts.contains(where: { $0.id == email }) {
            accounts.append(MailAccount(id: email, name: email.hasSuffix("@work.example") ? "Work" : "Personal"))
        }
        saveAccounts()
    }
    private func freshToken(_ state: OIDAuthState) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            state.performAction { token, _, error in
                if let token { continuation.resume(returning: token) }
                else { continuation.resume(throwing: error ?? InboxError(message: "Sign in to Google again.")) }
            }
        }
    }
    func request(account: String, url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let state = states[account] else { throw InboxError(message: "Sign in to \(account) again.") }
        let token = try await freshToken(state)
        try persist(state, email: account)
        var req = URLRequest(url: url); req.httpMethod = method; req.timeoutInterval = 45
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return try await Self.send(req)
    }
    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            throw InboxError(message: error?["message"] as? String ?? "Google could not complete this request. Check your connection and sign-in.")
        }
        return data
    }
}
