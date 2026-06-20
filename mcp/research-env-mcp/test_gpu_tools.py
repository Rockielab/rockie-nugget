#!/usr/bin/env python3
"""Pin the GPU on-ramp contract translation (capability shape → CLI jobs API)
and the in-tool budget gate. stdlib unittest only — no pip deps, no network.

Run:  python3 -m unittest test_gpu_tools -v   (from mcp/research-env-mcp/)

Mocks rockie_auth.request_json + get_token so the tools' translation is asserted
without touching the backend. The bodies/shapes asserted here are the EXACT ones
the shipped @rockielab/cli sends/receives (connected-ops.ts submitExperiment /
getJobStatus), so a drift in either breaks this test.
"""
import json
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rockie_auth  # noqa: E402
import server  # noqa: E402


def _result(text):
    return json.loads(text)


class HardwareParsing(unittest.TestCase):
    def test_capability_strings(self):
        self.assertEqual(server._parse_hardware("8xH100"), ("H100", 8))
        self.assertEqual(server._parse_hardware("1xA100-80GB"), ("A100-80GB", 1))
        self.assertEqual(server._parse_hardware("cpu"), ("cpu", 0))
        self.assertEqual(server._parse_hardware("CPU"), ("cpu", 0))
        self.assertEqual(server._parse_hardware("A100"), ("A100", 1))
        self.assertEqual(server._parse_hardware(" 4xL40S "), ("L40S", 4))


class SubmitJobTranslation(unittest.TestCase):
    def setUp(self):
        self.env = mock.patch.dict(os.environ, {}, clear=False)
        self.env.start()
        os.environ.pop("NUGGET_BUDGET_CEILING_CENTS", None)
        os.environ.pop("NUGGET_SUBMIT_DRY_RUN", None)

    def tearDown(self):
        self.env.stop()

    def test_translates_to_cli_submit_body(self):
        captured = {}

        def fake_request(method, path, body=None, token=None, timeout=30.0):
            captured.update(method=method, path=path, body=body, token=token)
            return {"job_id": "job-123", "cluster_id": "c-9",
                    "state": "queued", "estimated_cost_cents": 250}

        with mock.patch.object(rockie_auth, "get_token", return_value="rl_pat_x"), \
             mock.patch.object(rockie_auth, "request_json", side_effect=fake_request):
            out = _result(server.t_submit_job(
                {"hardware": "8xH100", "image": "cuda:12", "command": "python train.py",
                 "timeout_sec": 1800}))

        # Exact CLI POST /api/jobs/submit contract (connected-ops.ts submitExperiment).
        self.assertEqual(captured["method"], "POST")
        self.assertEqual(captured["path"], "/api/jobs/submit")
        self.assertEqual(captured["token"], "rl_pat_x")
        self.assertEqual(captured["body"], {
            "spec": {"gpu_type": "H100", "gpu_count": 8, "image": "cuda:12"},
            "script": "python train.py",
            "env": {},
            "timeout_seconds": 1800,
        })
        # Contract result: handle is the canonical job_id; awareness fields ride along.
        self.assertEqual(out["handle"], "job-123")
        self.assertEqual(out["estimated_cost_cents"], 250)
        self.assertEqual(out["state"], "queued")

    def test_default_timeout_and_no_image(self):
        captured = {}

        def fake_request(method, path, body=None, token=None, timeout=30.0):
            captured.update(body=body)
            return {"job_id": "j", "estimated_cost_cents": 0}

        with mock.patch.object(rockie_auth, "get_token", return_value="t"), \
             mock.patch.object(rockie_auth, "request_json", side_effect=fake_request):
            server.t_submit_job({"hardware": "cpu", "image": "", "command": "echo hi"})

        self.assertEqual(captured["body"]["timeout_seconds"], 3600)
        self.assertNotIn("image", captured["body"]["spec"])
        self.assertEqual(captured["body"]["spec"], {"gpu_type": "cpu", "gpu_count": 0})

    def test_auth_required_when_no_token(self):
        with mock.patch.object(rockie_auth, "get_token", return_value=None):
            with self.assertRaises(server.ToolError) as cm:
                server.t_submit_job({"hardware": "cpu", "image": "i", "command": "c"})
        self.assertEqual(cm.exception.code, "auth_required")

    def test_budget_ceiling_blocks_over_estimate(self):
        os.environ["NUGGET_BUDGET_CEILING_CENTS"] = "100"

        def fake_request(method, path, body=None, token=None, timeout=30.0):
            return {"job_id": "j", "estimated_cost_cents": 500}

        with mock.patch.object(rockie_auth, "get_token", return_value="t"), \
             mock.patch.object(rockie_auth, "request_json", side_effect=fake_request):
            with self.assertRaises(server.ToolError) as cm:
                server.t_submit_job({"hardware": "8xH100", "image": "i", "command": "c"})
        self.assertEqual(cm.exception.code, "budget_exceeded")

    def test_budget_ceiling_allows_under_estimate(self):
        os.environ["NUGGET_BUDGET_CEILING_CENTS"] = "1000"

        def fake_request(method, path, body=None, token=None, timeout=30.0):
            return {"job_id": "ok", "estimated_cost_cents": 500}

        with mock.patch.object(rockie_auth, "get_token", return_value="t"), \
             mock.patch.object(rockie_auth, "request_json", side_effect=fake_request):
            out = _result(server.t_submit_job(
                {"hardware": "cpu", "image": "i", "command": "c"}))
        self.assertEqual(out["handle"], "ok")

    def test_dry_run_sets_flag_in_body(self):
        os.environ["NUGGET_SUBMIT_DRY_RUN"] = "1"
        captured = {}

        def fake_request(method, path, body=None, token=None, timeout=30.0):
            captured.update(body=body)
            return {"job_id": "j", "state": "validated", "estimated_cost_cents": 42}

        with mock.patch.object(rockie_auth, "get_token", return_value="t"), \
             mock.patch.object(rockie_auth, "request_json", side_effect=fake_request):
            out = _result(server.t_submit_job(
                {"hardware": "cpu", "image": "i", "command": "c"}))
        self.assertTrue(captured["body"]["dry_run"])
        self.assertTrue(out["dry_run"])

    def test_backend_error_code_propagates(self):
        def fake_request(method, path, body=None, token=None, timeout=30.0):
            raise rockie_auth.AuthHttpError(403, None, "forbidden")

        with mock.patch.object(rockie_auth, "get_token", return_value="t"), \
             mock.patch.object(rockie_auth, "request_json", side_effect=fake_request):
            with self.assertRaises(server.ToolError) as cm:
                server.t_submit_job({"hardware": "cpu", "image": "i", "command": "c"})
        self.assertEqual(cm.exception.code, "auth_required")


class GetJobMapping(unittest.TestCase):
    def test_maps_jobview_to_contract(self):
        jobview = {
            "id": "job-123", "state": "running",
            "cost_so_far_cents": 17, "cost_actual_cents": None,
            "last_log_line": "step 5/10", "runpod_error": None,
        }
        with mock.patch.object(rockie_auth, "get_token", return_value="t"), \
             mock.patch.object(rockie_auth, "request_json", return_value=jobview):
            out = _result(server.t_get_job({"handle": "job-123"}))
        self.assertEqual(out["state"], "running")
        self.assertEqual(out["progress"], 0.5)
        self.assertEqual(out["metrics"]["cost_so_far_cents"], 17)
        self.assertEqual(out["logs"], "step 5/10")
        self.assertEqual(out["artifacts"], [])

    def test_progress_terminal_states(self):
        for state, prog in [("succeeded", 1.0), ("queued", 0.0), ("failed", 1.0)]:
            with mock.patch.object(rockie_auth, "get_token", return_value="t"), \
                 mock.patch.object(rockie_auth, "request_json",
                                   return_value={"state": state}):
                out = _result(server.t_get_job({"handle": "h"}))
            self.assertEqual(out["progress"], prog, state)

    def test_get_job_calls_correct_endpoint(self):
        captured = {}

        def fake_request(method, path, body=None, token=None, timeout=30.0):
            captured.update(method=method, path=path)
            return {"state": "succeeded"}

        with mock.patch.object(rockie_auth, "get_token", return_value="t"), \
             mock.patch.object(rockie_auth, "request_json", side_effect=fake_request):
            server.t_get_job({"handle": "abc"})
        self.assertEqual(captured["method"], "GET")
        self.assertEqual(captured["path"], "/api/jobs/abc")


class TokenResolution(unittest.TestCase):
    def test_env_var_wins(self):
        with mock.patch.dict(os.environ, {rockie_auth.TOKEN_ENV_VAR: "  rl_env  "}):
            self.assertEqual(rockie_auth.get_token(), "rl_env")

    def test_base_url_override(self):
        with mock.patch.dict(os.environ, {"ROCKIELAB_API_URL": "https://dev.example/"}):
            self.assertEqual(rockie_auth.base_url(), "https://dev.example")

    def test_extract_detail_envelope(self):
        body = json.dumps({"detail": {"error": {"code": "authorization_pending",
                                                "message": "pending"}}})
        msg, code = rockie_auth._extract_detail(body)
        self.assertEqual(code, "authorization_pending")
        self.assertEqual(msg, "pending")


if __name__ == "__main__":
    unittest.main()
