# Inbox

A mail and calendar app for your Google accounts that runs on your own Mac. Claude reads ahead and ranks your mail
by how much it needs you; Unread is the home inbox, and the goal is zero. A small Python server (standard library
only) serves the page at http://127.0.0.1:8765 and passes your clicks to Gmail and Google Calendar. The Mac app
(`mac/`) is a native window around it, and there is an iPhone app in `ios/`.

What it does: every account in one list ranked by Claude, with categories and a reason for each email; Not important
and Important buttons that teach the ranking; search across Gmail; the real HTML email with whole threads and
attachments, in Dark, Dim or Light; reply, reply all and forward with To, Cc and Bcc; archive, delete, star, report
spam and undo; back and forward through what you've read; a week calendar where you create events with Google Meet
links and invites; a background sky that follows the sun where you live; and on the Mac, a Dock badge, notifications
for important mail and Open at Login.

Nothing leaves your Mac except calls to Google and the ranking step, which sends each email's sender, subject and a
short preview to Claude through the Claude Code command line tool.

## What you need

- A Mac with Xcode (for the Mac app) and Python 3.
- [Claude Code](https://claude.com/claude-code), installed and signed in. Ranking runs `claude -p`, so it uses your plan.
- `brew install xcodegen`
- A Google account for each inbox you want to add.

## Set up Google (about 20 minutes, once)

Google needs an app of your own to let Inbox read and send your mail. It stays private to you.

1. Go to https://console.cloud.google.com and create a project (any name).
2. **APIs & Services > Library**: turn on the **Gmail API** and the **Google Calendar API**. (Turn on the
   **Google Drive API** too if you'll use the iPhone app, which reads rankings from a hidden app folder.)
3. **Google Auth Platform > Branding**: give the app a name and your email. **Audience**: choose **External**, leave
   it in **Testing**, and add every Gmail address you'll use as a **test user**.
4. **Data Access**: add the scopes `gmail.modify`, `gmail.send`, `calendar.events` and `drive.appdata`.
5. **Clients > Create client**: type **Desktop app**. Download the JSON and save it in this folder as
   `client_secret.json`.

Testing mode signs you out about once a week. Run `python3 inbox.py login` again then (the Mac app's
**File > Sign In to Google Again** does the same). Ending that needs Google to verify the app.

## Install

```
git clone https://github.com/<you>/<this-repo>.git ~/inbox-app   # the URL from GitHub's green Code button
cd ~/inbox-app
python3 inbox.py setup     # your name, your accounts, your city
python3 inbox.py login     # allow each account in the browser; Google shows an "unverified app" warning, click Continue
mac/install.sh             # builds the Mac app into /Applications and opens it
```

Prefer a browser? Run `python3 inbox.py serve` and open http://127.0.0.1:8765. `python3 inbox.py demo` builds the
page from made-up data, to look around before signing in.

## Your email

Inbox shows the Gmail and Google Workspace accounts you add with `inbox.py setup`, up to 10 of them in one list.
Mail from Outlook, iCloud, Yahoo or another server can join by forwarding it into one of those Gmail accounts. See
[ADD-YOUR-EMAIL.md](ADD-YOUR-EMAIL.md) for both, plus importing your old mail.

## Files

- `inbox.py`: sign-in, fetching, ranking, the local server and every action.
- `template.html`: the design, with sample data. `inbox.py` patches in your real data and a script that wires the
  buttons to the server.
- `mac/`: the Mac app. `ios/`: the iPhone app (see `ios/README.md`; it needs your own Apple developer account and an
  iOS client in the same Google project).
- `settings.json`, `client_secret.json`, `.tokens.json` and the caches stay on your Mac and are never committed.

## Tests

```
python3 -m unittest tests.test_sync
node tests/test_bridge.cjs
```
