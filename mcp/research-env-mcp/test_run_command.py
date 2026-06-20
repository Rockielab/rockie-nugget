#!/usr/bin/env python3
"""Pin run_command's output-handling contract: it must return the FULL, faithful
result (stdout + stderr clearly separated + exit code), never silently dropping
output. stdlib unittest only — no pip deps, no network.

Run:  python3 -m unittest test_run_command -v   (from mcp/research-env-mcp/)

Regression coverage for qc-2026-06-20: a program that printed a correct answer
to stdout but emitted a non-UTF-8 byte to stderr caused text=True to raise
UnicodeDecodeError, and the generic handler then discarded ALL stdout/stderr +
the exit code — so the agent wrongly concluded every program "crashed" and
scored input_acc 0.0 across the board.
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import server  # noqa: E402


class RunCommandOutput(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._orig_ws = server.WORKSPACE
        from pathlib import Path
        server.WORKSPACE = Path(self._tmp.name).resolve()

    def tearDown(self):
        server.WORKSPACE = self._orig_ws
        self._tmp.cleanup()

    def _run(self, command, **kw):
        text, is_err = server.call_tool("run_command", {"command": command, **kw})
        return text, is_err

    def test_non_utf8_stderr_does_not_discard_correct_stdout(self):
        """The qc-2026-06-20 regression: correct stdout must survive a non-UTF-8
        stderr byte, and the exit code must be reported (no decode error envelope)."""
        text, is_err = self._run(
            'printf "42\\n"; printf "bad \\xa0 byte\\n" 1>&2; exit 134'
        )
        self.assertFalse(is_err, f"must not be an error envelope: {text!r}")
        self.assertIn("42", text)            # correct stdout preserved
        self.assertIn("[exit 134]", text)    # exit code preserved
        self.assertNotIn("codec can't decode", text)

    def test_non_utf8_stdout_replaced_not_dropped(self):
        text, is_err = self._run('printf "\\xff\\xfeokay"')
        self.assertFalse(is_err)
        self.assertIn("okay", text)
        self.assertIn("[exit 0]", text)

    def test_stdout_and_stderr_are_separated(self):
        """stdout without a trailing newline must not be jammed onto stderr."""
        text, _ = self._run('printf "OUT_NO_NL"; printf "ERR_HERE" 1>&2')
        self.assertNotIn("OUT_NO_NLERR_HERE", text)
        self.assertIn("OUT_NO_NL", text)
        self.assertIn("ERR_HERE", text)

    def test_non_zero_exit_code_reported(self):
        text, is_err = self._run("echo hi; exit 7")
        self.assertFalse(is_err)
        self.assertIn("hi", text)
        self.assertIn("[exit 7]", text)

    def test_large_output_truncated_explicitly_not_silently(self):
        cap = server.RUN_COMMAND_MAX_STREAM_BYTES
        # Emit comfortably more than the cap.
        text, is_err = self._run(
            f'python3 -c "import sys; sys.stdout.write(\\"x\\" * {cap + 10000})"'
        )
        self.assertFalse(is_err)
        self.assertIn("TRUNCATED", text)
        self.assertIn("[exit 0]", text)

    def test_structured_json_output_intact(self):
        text, is_err = self._run('printf \'{"acc": 1, "ok": true}\\n\'')
        self.assertFalse(is_err)
        self.assertIn('{"acc": 1, "ok": true}', text)
        self.assertIn("[exit 0]", text)


if __name__ == "__main__":
    unittest.main()
