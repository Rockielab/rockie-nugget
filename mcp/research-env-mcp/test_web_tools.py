#!/usr/bin/env python3
"""Pin the web_search / fetch_url contract: real network behaviour without the
network. stdlib unittest only — no pip deps, no live HTTP (everything mocked).

Run:  python3 -m unittest test_web_tools -v   (from mcp/research-env-mcp/)

Covers: DDG result parse, BYO-key branch selection, fetch HTML→text + byte cap,
and the SSRF guard (loopback / metadata / private / non-http scheme all blocked).
"""
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import server  # noqa: E402


def _call(name, args):
    return server.call_tool(name, args)


_DDG_PAGE = """
<html><body>
<a class="result__a" href="https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa">
  First <b>Result</b></a>
<div class="result__snippet">Snippet one about the topic.</div>
<a class="result__a" href="https://example.org/b">Second Result</a>
<a class="result__snippet" href="x">Snippet two here.</a>
</body></html>
"""


class WebSearch(unittest.TestCase):
    def test_keyless_ddg_parse_and_unwrap(self):
        with mock.patch.dict(os.environ, {"SEARCH_API_KEY": ""}, clear=False), \
             mock.patch.object(server, "_http_get_post",
                               return_value=(_DDG_PAGE.encode(), "", "text/html")):
            text, is_err = _call("web_search", {"query": "topic", "k": 5})
        self.assertFalse(is_err, text)
        self.assertIn("First Result", text)
        self.assertIn("https://example.com/a", text)   # /l/?uddg= unwrapped
        self.assertIn("Snippet one", text)

    def test_ddg_rate_limit_surfaces_clean_error(self):
        with mock.patch.dict(os.environ, {"SEARCH_API_KEY": ""}, clear=False), \
             mock.patch.object(server, "_http_get_post",
                               return_value=(b"<html>If this error persists please "
                                             b"... anomaly detected</html>", "", "")):
            text, is_err = _call("web_search", {"query": "x"})
        self.assertTrue(is_err)
        self.assertIn("rate_limited", text)

    def test_byo_key_selects_provider_not_ddg(self):
        captured = {}

        def fake_byo(query, k, key, provider):
            captured.update(query=query, key=key, provider=provider)
            return [{"title": "T", "url": "https://e.com", "snippet": "S"}]

        with mock.patch.dict(os.environ,
                             {"SEARCH_API_KEY": "sk-test", "SEARCH_PROVIDER": "tavily"},
                             clear=False), \
             mock.patch.object(server, "_search_byo", side_effect=fake_byo), \
             mock.patch.object(server, "_search_duckduckgo",
                               side_effect=AssertionError("must not call DDG")):
            text, is_err = _call("web_search", {"query": "q"})
        self.assertFalse(is_err, text)
        self.assertEqual(captured["provider"], "tavily")
        self.assertEqual(captured["key"], "sk-test")
        self.assertIn("https://e.com", text)


class FetchUrl(unittest.TestCase):
    def _patch_get(self, body, ctype="text/html"):
        return mock.patch.object(
            server, "_http_get", return_value=(body, "http://pub.example/", ctype))

    def test_html_stripped_to_text(self):
        html_body = (b"<html><head><style>x{}</style></head><body>"
                     b"<h1>Title</h1><p>Hello &amp; welcome.</p>"
                     b"<script>evil()</script></body></html>")
        with mock.patch.object(server, "_assert_public_url"), self._patch_get(html_body):
            text, is_err = _call("fetch_url", {"url": "http://pub.example/"})
        self.assertFalse(is_err, text)
        self.assertIn("Title", text)
        self.assertIn("Hello & welcome.", text)
        self.assertNotIn("evil()", text)     # script body dropped
        self.assertNotIn("<", text)          # tags gone

    def test_byte_cap_reported(self):
        big = b"<p>" + b"a" * (server.FETCH_MAX_BYTES + 500)
        with mock.patch.object(server, "_assert_public_url"), self._patch_get(big):
            text, is_err = _call("fetch_url", {"url": "http://pub.example/"})
        self.assertFalse(is_err, text)
        self.assertIn("truncated at", text)
        self.assertIn("FETCH_URL_MAX_BYTES", text)


class SSRFGuard(unittest.TestCase):
    def _block(self, ip):
        # getaddrinfo returns (family, type, proto, canonname, sockaddr)
        return mock.patch.object(
            server.socket, "getaddrinfo",
            return_value=[(2, 1, 6, "", (ip, 0))])

    def test_blocks_metadata_endpoint(self):
        with self._block("169.254.169.254"):
            text, is_err = _call("fetch_url", {"url": "http://metadata.test/"})
        self.assertTrue(is_err)
        self.assertIn("non-public", text)

    def test_blocks_loopback(self):
        with self._block("127.0.0.1"):
            text, is_err = _call("fetch_url", {"url": "http://localhost.test/"})
        self.assertTrue(is_err)
        self.assertIn("non-public", text)

    def test_blocks_private_range(self):
        with self._block("10.1.2.3"):
            text, is_err = _call("fetch_url", {"url": "http://internal.test/"})
        self.assertTrue(is_err)
        self.assertIn("non-public", text)

    def test_blocks_non_http_scheme(self):
        text, is_err = _call("fetch_url", {"url": "file:///etc/passwd"})
        self.assertTrue(is_err)
        self.assertIn("non-http", text)

    def test_rechecks_each_redirect_hop(self):
        """A public first hop that redirects to a private host must still be blocked."""
        calls = {"n": 0}
        real_assert = server._assert_public_url

        def guard(url):
            calls["n"] += 1
            if "evil" in url:
                with mock.patch.object(server.socket, "getaddrinfo",
                                       return_value=[(2, 1, 6, "", ("127.0.0.1", 0))]):
                    return real_assert(url)
            return None  # first hop deemed public

        def fake_get(url, headers=None):
            return (b"", "http://evil.internal/", "302")

        with mock.patch.object(server, "_assert_public_url", side_effect=guard), \
             mock.patch.object(server, "_http_get", side_effect=fake_get):
            text, is_err = _call("fetch_url", {"url": "http://public.example/"})
        self.assertTrue(is_err)
        self.assertIn("non-public", text)
        self.assertGreaterEqual(calls["n"], 2)   # guard ran on the redirect hop too


if __name__ == "__main__":
    unittest.main()
