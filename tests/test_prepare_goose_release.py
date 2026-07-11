import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
PREPARE = REPO_ROOT / "scripts" / "prepare-goose-release.py"


class PrepareGooseReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.archive = self.root / "goose.tar.gz"
        self.output = self.root / "release" / "goose"

    def tearDown(self):
        self.temp_dir.cleanup()

    def write_archive(self, members):
        with tarfile.open(self.archive, mode="w:gz") as archive:
            for name, data, member_type in members:
                member = tarfile.TarInfo(name)
                member.type = member_type
                if member_type == tarfile.REGTYPE:
                    member.size = len(data)
                    archive.addfile(member, fileobj=io.BytesIO(data))
                else:
                    member.linkname = "target"
                    archive.addfile(member)

    def run_prepare(self, raw_sha256):
        archive_sha256 = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        return subprocess.run(
            [
                sys.executable,
                str(PREPARE),
                "--archive",
                str(self.archive),
                "--output",
                str(self.output),
                "--archive-sha256",
                archive_sha256,
                "--raw-sha256",
                raw_sha256,
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_extracts_exactly_one_regular_goose_file(self):
        payload = b"#!/bin/sh\necho goose 1.41.0\n"
        self.write_archive([("./goose", payload, tarfile.REGTYPE)])

        result = self.run_prepare(hashlib.sha256(payload).hexdigest())

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_bytes(), payload)
        self.assertTrue(self.output.stat().st_mode & 0o111)

    def test_rejects_path_traversal(self):
        payload = b"goose"
        self.write_archive([("../../goose", payload, tarfile.REGTYPE)])

        result = self.run_prepare(hashlib.sha256(payload).hexdigest())

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe archive member", result.stderr)
        self.assertFalse(self.output.exists())

    def test_rejects_symlink_named_goose(self):
        self.write_archive([("goose", b"", tarfile.SYMTYPE)])

        result = self.run_prepare(hashlib.sha256(b"").hexdigest())

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be a regular file", result.stderr)
        self.assertFalse(self.output.exists())

    def test_rejects_any_extra_file(self):
        payload = b"goose"
        self.write_archive(
            [
                ("goose", payload, tarfile.REGTYPE),
                ("README", b"extra", tarfile.REGTYPE),
            ]
        )

        result = self.run_prepare(hashlib.sha256(payload).hexdigest())

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected archive member", result.stderr)
        self.assertFalse(self.output.exists())

    def test_rejects_raw_digest_mismatch_without_publishing_output(self):
        self.write_archive([("goose", b"actual", tarfile.REGTYPE)])

        result = self.run_prepare("0" * 64)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("raw Goose SHA-256 mismatch", result.stderr)
        self.assertFalse(self.output.exists())
