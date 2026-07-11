#!/usr/bin/env python3
"""Verify an official Goose archive and write one raw executable safely."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile


class ReleaseArchiveError(ValueError):
    """The archive cannot be trusted as a single Goose executable."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalized_member_name(name: str) -> str:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        raise ReleaseArchiveError(f"unsafe archive member: {name!r}")
    return "/".join(part for part in path.parts if part not in ("", "."))


def select_goose_member(archive: tarfile.TarFile) -> tarfile.TarInfo:
    goose_members: list[tarfile.TarInfo] = []
    for member in archive.getmembers():
        name = normalized_member_name(member.name)
        if member.isdir() and not name:
            continue
        if not member.isfile():
            raise ReleaseArchiveError(
                f"archive member must be a regular file: {member.name!r}"
            )
        if name != "goose":
            raise ReleaseArchiveError(f"unexpected archive member: {member.name!r}")
        goose_members.append(member)
    if len(goose_members) != 1:
        raise ReleaseArchiveError(
            f"expected exactly one raw goose executable, found {len(goose_members)}"
        )
    return goose_members[0]


def prepare_release(
    archive_path: Path,
    output_path: Path,
    expected_archive_sha256: str,
    expected_raw_sha256: str,
) -> None:
    output_path.unlink(missing_ok=True)
    archive_digest = sha256_file(archive_path)
    if archive_digest != expected_archive_sha256:
        raise ReleaseArchiveError(
            f"archive SHA-256 mismatch: expected {expected_archive_sha256}, "
            f"got {archive_digest}"
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    temp_name: str | None = None
    try:
        with tarfile.open(archive_path, mode="r:gz") as archive:
            member = select_goose_member(archive)
            source = archive.extractfile(member)
            if source is None:
                raise ReleaseArchiveError("goose archive member has no payload")
            with source:
                with tempfile.NamedTemporaryFile(
                    dir=output_path.parent,
                    prefix=f".{output_path.name}.",
                    delete=False,
                ) as destination:
                    temp_name = destination.name
                    shutil.copyfileobj(source, destination)

        temp_path = Path(temp_name)
        raw_digest = sha256_file(temp_path)
        if raw_digest != expected_raw_sha256:
            raise ReleaseArchiveError(
                f"raw Goose SHA-256 mismatch: expected {expected_raw_sha256}, "
                f"got {raw_digest}"
            )
        temp_path.chmod(0o755)
        os.replace(temp_path, output_path)
        temp_name = None
    finally:
        if temp_name is not None:
            Path(temp_name).unlink(missing_ok=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--archive-sha256", required=True)
    parser.add_argument("--raw-sha256", required=True)
    args = parser.parse_args()
    for label in ("archive_sha256", "raw_sha256"):
        value = getattr(args, label)
        if len(value) != 64 or any(char not in "0123456789abcdef" for char in value):
            parser.error(f"--{label.replace('_', '-')} must be 64 lowercase hex characters")
    return args


def main() -> int:
    args = parse_args()
    try:
        prepare_release(
            args.archive,
            args.output,
            args.archive_sha256,
            args.raw_sha256,
        )
    except (OSError, ReleaseArchiveError, tarfile.TarError) as error:
        raise SystemExit(f"error: {error}") from error
    print(f"prepared {args.output} sha256={sha256_file(args.output)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
