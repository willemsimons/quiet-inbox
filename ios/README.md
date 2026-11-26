# Inbox for iOS

Native SwiftUI companion for the Mac app, targeting iOS 17 and later. Open `Inbox.xcodeproj`, select the **Inbox** scheme, and run on an iPhone simulator. Choose **Explore with sample mail** to try the app without credentials. The launch argument `--demo` goes straight to the sample inbox.

## Install from your laptop

Clone the repo and open the committed Xcode project (XcodeGen is not required):

```sh
git clone https://github.com/<you>/<this-repo>.git
cd inbox
open ios/Inbox.xcodeproj
```

Use Xcode 26 or later. Sign in to your Apple account in Xcode Settings → Accounts and select **your Apple developer team** for the Inbox target under Signing & Capabilities. Connect your iPhone, trust the laptop, enable Developer Mode on the phone if prompted, and choose the phone as Xcode's run destination. Select the **Inbox** scheme and press Run. Automatic signing needs access to that team's development certificates and device registration.

You can use **Explore with sample mail** immediately. To use your inbox, configure Google sign-in below. Secrets and local build files are intentionally excluded from Git. TestFlight distribution still requires App Store Connect access and provisioning; this branch can be installed directly through Xcode first.

## Connect your real accounts

1. In the **same Google Cloud project** as the desktop app, enable Gmail, Google Calendar, and Google Drive APIs. Keep both email addresses in the consent screen's test users if the app is in Testing.
2. Create an **iOS** OAuth client with bundle ID `com.example.inbox`. The desktop client's credentials cannot be used as an iOS client.
3. Copy `Local.example.xcconfig` to `Local.xcconfig` and replace the Google client ID and reversed client ID. For `123-abc.apps.googleusercontent.com`, the reversed ID is `com.googleusercontent.apps.123-abc`. Do not include a client secret. `Local.xcconfig` is ignored by Git.
4. Set your Apple development team in that file or Xcode's Signing & Capabilities panel for installation on a physical phone. If using a different bundle ID, change it in `project.yml`, regenerate the project, and register that exact ID with Google.
5. Build and run, then use **Connect Google account** for each account. AppAuth performs browser-based authorization with PKCE; each account's refresh credentials live in this device's Keychain.
6. On the Mac, run `python3 inbox.py login` again to grant the new `drive.appdata` permission, then `python3 inbox.py serve`. The Mac publishes per-account ranking metadata after fetching/ranking mail. Previously granted tokens still work for mail/calendar without Drive permission.

The iOS OAuth client must belong to the same Google Cloud project as the desktop client for the two clients to access the same hidden app-data folder. No mail bodies, desktop client secrets, or desktop refresh tokens are copied to the phone or to this metadata file.

## Split inbox interaction

The inbox occupies the upper half of the display. Rows snap into a top selection slot as you scroll; that selected message is always shown in the lower reader. Tapping a row moves it into that slot. Long-press a row to open a separate preview without changing selection or read state.

Swipe left on an unread row or tap **Read** in the reader's horizontally scrolling Liquid Glass action bar to mark it read. It leaves **Unread**, remains in **Read**, and selection advances to the next available message. Viewing a message alone never marks it read. The top-left hamburger menu contains Unread, Read, Starred, All mail, account/category filters, search, calendar, and settings.

Swipe upward on the collapsed reader (or its handle) to expand it to the full available screen. The inbox is inaccessible while expanded. Use the collapse button or pull the handle downward to return to split view. In the expanded state, the message scrolls independently. The action bar stays at the bottom. iOS 26 uses native Liquid Glass; iOS 17–25 use translucent material.

Simulator UI tests exercise these gestures using sample mail and retain screenshots as test-result attachments. No live Gmail mutations are involved in those tests.

## What stays in sync

Google is the source of truth for read/unread, stars, Trash, sent replies/messages, and primary calendar events. The phone connects directly to Google and does not depend on the Mac being awake for these actions. Each client refreshes when brought to the foreground and every 60 seconds while active. Pull to refresh on iOS; the desktop also has **Check for new mail**. Desktop refresh waits while a draft, selection, drag, or pending write is active.

The Mac is the sole writer of AI ranking metadata (`inbox-rankings-v1.json` in each account's hidden Drive app-data folder). The phone reads scores, categories, and explanations. New messages use Gmail labels until the Mac ranks and publishes them. Drive failures do not prevent mail or calendar access. Rank caches and UI identities are scoped to account plus message ID.

Mutations in iOS are reflected locally only after Google succeeds. Refreshes that overlap a mutation are discarded. Failed refreshes preserve the account's previous content and display an error. Sending failures keep the compose sheet and draft open; writes are not automatically retried because a timed-out send may have reached Google.

## Current scope

- Both accounts, importance ordering, unread/star/category filters, search within loaded mail.
- Most recent 60 inbox messages per account within 14 days, matching the Mac's fetch window.
- Plain-text conversation reader, reply, compose, read/unread, star/unstar, and move to Trash.
- Calendar agenda for the next 14 days, Google Meet links, and creating timed events.
- Foreground polling; no push notifications, background fetch, persistent offline mail cache, or cross-device draft sync yet.
- HTML-only messages currently use Gmail's text snippet. Attachment names are shown; use **Open in Gmail** to download attachments or view original formatting.
- Calendar editing/deletion, invitations, sending attachments, and CC/BCC are not yet exposed in the mobile UI.

Live Google authorization and cross-device round trips require your OAuth configuration and consent; simulator/demo tests do not verify those account-dependent steps.

## Development

The Xcode project is generated with XcodeGen; commit both `project.yml` and `Inbox.xcodeproj`. AppAuth is the only package dependency. The package resolution is committed for reproducibility.

```sh
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/Inbox.xcodeproj -scheme Inbox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
python3 -m unittest discover -s tests -v
node tests/test_bridge.cjs
```

Tests cover account isolation, shared rank publication, empty inboxes, Drive failure handling, MIME decoding, Unicode outgoing mail, reply headers, header injection, all-day dates, and demo isolation.

Protocol references: [AppAuth for iOS](https://github.com/openid/AppAuth-iOS), [Gmail synchronization](https://developers.google.com/workspace/gmail/api/guides/sync), and [Drive app-data storage](https://developers.google.com/workspace/drive/api/guides/appdata).
