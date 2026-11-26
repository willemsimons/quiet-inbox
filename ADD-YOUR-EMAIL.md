# Bring your email into Inbox

Inbox reads straight from Gmail. There's no import step and no copy of your mail in this repo: you point it at
your Google accounts, and Gmail stays the record of what's read, starred, archived and sent. To merge several
inboxes, add each Google account (up to 10). Mail from anywhere else (Outlook, iCloud, Yahoo, a work server) goes
into one of those Gmail accounts first, and Inbox picks it up from there.

## 1. Gmail and Google Workspace accounts

Do the Google setup in the [README](README.md) first, so you have `client_secret.json` in the folder.

1. In Google Cloud, **Google Auth Platform > Audience > Test users**: add every address you'll use. Google
   blocks sign-in for any address that isn't on this list while the app is in Testing.
2. Run `python3 inbox.py setup`. Give your first name (Claude ranks mail by how much it needs you), then each
   account's address and a short name for the sidebar, such as Work, Personal or Side project. Leave the address
   empty when you're done.
3. Run `python3 inbox.py login`. A browser opens once for each account. Pick the matching Google account and allow
   access. Google warns that the app is unverified: that's your own app, so click **Continue**.
4. Start Inbox (`mac/install.sh`, or `python3 inbox.py serve` and open http://127.0.0.1:8765).

The first start downloads the newest 250 emails in each account and has Claude rank them, which takes a few
minutes. After that, Inbox checks for new mail every minute and only ranks what's new.

**To add an account later:** add the address as a test user, run `python3 inbox.py setup` again (press Return to
keep the accounts you already have, then type the new one), then run `python3 inbox.py login you@new.example` to
sign in just that account. Restart Inbox.

**To remove one:** run `setup` and leave that address out, or delete its entry from `settings.json`.

`settings.json` looks like this, if you'd rather edit it by hand:

```json
{
  "owner": "Alex",
  "accounts": [
    {"key": "work", "name": "Work", "email": "alex@company.example"},
    {"key": "personal", "name": "Personal", "email": "alex@gmail.example"}
  ],
  "city": {"name": "London", "lat": 51.51, "lon": -0.13}
}
```

`key` is any short lowercase word, different for each account. It never leaves your Mac and is never committed.

## 2. Mail from other providers (Outlook, iCloud, Yahoo, IMAP)

Inbox doesn't connect to non-Google mail servers directly, so route that mail into a Gmail account. Pick the
Gmail account where it should live, or make a new free one just for this and add it to Inbox as above.

**New mail, from now on: forward it.** In the other provider, turn on automatic forwarding to your Gmail address:

- Outlook.com / Hotmail: **Settings > Mail > Forwarding**
- iCloud Mail: **icloud.com/mail > Settings > General > Forward my email to**
- Yahoo: **Settings > More Settings > Mailboxes > your address > Forwarding**
- A work Exchange or Microsoft 365 account: an Outlook inbox rule ("Redirect to"), if your admin allows it

Then in Gmail on the web, **Settings > Filters and Blocked Addresses > Create a new filter** with
`to:(you@other.example)`, and give it a label such as the provider's name, so you can tell that mail apart.

**Your old mail: import it once.** In Gmail on the web, **Settings > Accounts and Import > Import mail and
contacts** copies existing mail from Yahoo, Outlook, AOL and most IMAP providers. It runs in the background and can
take a day or two for a big mailbox. If your provider isn't supported, add both accounts to Apple Mail or
Thunderbird and drag folders from the old account into the Gmail one.

**Replying from the other address:** in Gmail, **Settings > Accounts and Import > Send mail as > Add another email
address**. Inbox sends through Gmail, so Gmail decides which address your mail comes from.

Inbox only shows mail in your Gmail **Inbox** (and searches everything), so make sure forwarded and imported mail
isn't skipping the inbox. Unread is Inbox's home view, so if imported history arrives unread, search for it in Gmail
(for example `label:outlook is:unread`), select all and mark it read before you open Inbox.

## 3. Your calendar

Inbox shows the primary Google Calendar of each account you add. To see an Outlook or iCloud calendar there too,
publish it as an ICS link from that calendar's sharing settings, then in Google Calendar choose
**Other calendars > + > From URL**.

## Where your data lives

Everything Inbox stores sits in this folder on your Mac, and `.gitignore` keeps all of it out of git:
`settings.json`, `client_secret.json`, `.tokens.json` (Google sign-in, readable only by you), and the caches
(`.mail-cache.json`, `.rank-cache.json`, `.today-cache.json`, `.feedback.json`, `.attachments/`). Nothing goes
anywhere except calls to Google and the ranking step, which sends each email's sender, subject and a short preview
to Claude through the Claude Code command line tool.

Before you push a fork, run `git status` and check that none of those files show up.
