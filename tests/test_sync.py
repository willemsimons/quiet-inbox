import unittest
from unittest.mock import patch
import inbox


# Made-up accounts, so the tests don't depend on anyone's settings.json.
TEST_ACCOUNTS = [("work", "Work", "work@test.example"), ("personal", "Personal", "home@test.example")]


class RankingSyncTests(unittest.TestCase):
    def setUp(self):
        for name, value in (("ACCOUNTS", TEST_ACCOUNTS), ("ADDRESS", {k: m for k, _, m in TEST_ACCOUNTS})):
            patcher = patch.object(inbox, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.mail = [dict(a="work", gmailId="shared-id", score=90, cat="Product", why="Review"),
                     dict(a="personal", gmailId="shared-id", score=40, cat="Home", why="Personal")]

    def test_existing_credentials_do_not_attempt_drive_access(self):
        with patch.object(inbox, "read_json", return_value={}), patch.object(inbox, "call") as call:
            inbox.publish_rankings(self.mail)
            call.assert_not_called()

    def test_rankings_are_isolated_by_account_even_with_identical_message_ids(self):
        tokens = {address: {"scope": inbox.RANK_SCOPE} for _, _, address in inbox.ACCOUNTS}
        def response(address, method, url, body=None):
            return {"files": [{"id": address}]} if method == "GET" else {}
        with patch.object(inbox, "read_json", return_value=tokens), patch.object(inbox, "call", side_effect=response) as call:
            inbox.publish_rankings(self.mail)
            writes = [c for c in call.call_args_list if c.args[1] == "PATCH"]
            self.assertEqual(len(writes), 2)
            self.assertEqual(writes[0].args[3]["rankings"]["shared-id"]["score"], 90)
            self.assertEqual(writes[1].args[3]["rankings"]["shared-id"]["score"], 40)
            for write in writes:
                self.assertEqual(write.args[0], write.args[3]["account"])

    def test_empty_fetch_does_not_erase_rankings(self):
        with patch.object(inbox, "read_json", return_value={inbox.ACCOUNTS[0][2]: {"scope": inbox.RANK_SCOPE}}), patch.object(inbox, "call") as call:
            inbox.publish_rankings([])
            call.assert_not_called()

    def test_drive_failure_does_not_break_mail(self):
        with patch.object(inbox, "read_json", return_value={inbox.ACCOUNTS[0][2]: {"scope": inbox.RANK_SCOPE}}), patch.object(inbox, "call", side_effect=inbox.GoogleError("offline")):
            inbox.publish_rankings(self.mail)

    def test_connected_empty_inbox_is_valid(self):
        with patch.object(inbox, "access_token", return_value="test"), patch.object(inbox, "fetch_mail", return_value=[]), patch.object(inbox, "fetch_events", return_value=[]), patch.object(inbox, "rank"), patch.object(inbox, "publish_rankings"):
            self.assertEqual(inbox.gather()["mail"], [])

    def test_fetch_failure_does_not_publish_an_empty_snapshot(self):
        with patch.object(inbox, "access_token", return_value="test"), patch.object(inbox, "fetch_mail", side_effect=inbox.GoogleError("offline")), patch.object(inbox, "fetch_events", return_value=[]), patch.object(inbox, "rank") as rank:
            with self.assertRaises(inbox.GoogleError):
                inbox.gather()
            rank.assert_not_called()

    def test_existing_rank_cache_is_migrated_without_reranking(self):
        mail = [dict(a="work", gmailId="old", labels=[], unread=True, body="hello")]
        cache = {"old": {"score": 91, "cat": "Product", "why": "Review"}}
        with patch.object(inbox, "read_json", return_value=cache), patch.object(inbox, "private_write"), patch.object(inbox.subprocess, "run") as run:
            inbox.rank(mail)
            run.assert_not_called()
            self.assertEqual(mail[0]["score"], 91)
            self.assertIn("work:old", cache)

    def test_template_bridge_still_builds(self):
        page = inbox.build({"live": True, "mail": [], "events": []}, "test-only")
        self.assertIn("syncSnapshot", page)
        self.assertIn("pendingWrites", page)


if __name__ == "__main__":
    unittest.main()
