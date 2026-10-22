#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_matches(path: Path, expected: dict[str, int | str]) -> bool:
    if not path.is_file() or path.stat().st_size != expected["sizeBytes"]:
        return False
    return sha256(path) == expected["sha256"]


def expected_files(lock: dict) -> dict:
    return lock["files"]


def model_is_ready(plugin_directory: Path, lock: dict) -> bool:
    return all(
        file_matches(plugin_directory / relative_path, expected)
        for relative_path, expected in expected_files(lock).items()
    )


def download_source(lock: dict, source_directory: Path) -> None:
    source = lock["source"]
    os.environ.setdefault("HF_ENDPOINT", source["mirrorEndpoint"])
    from huggingface_hub import snapshot_download

    arguments = {
        "repo_id": source["repository"],
        "revision": source["revision"],
        "local_dir": source_directory,
        "allow_patterns": source["downloadFiles"],
    }
    try:
        snapshot_download(**arguments, local_files_only=True)
    except Exception:
        snapshot_download(**arguments)


def convert_source(lock: dict, source_directory: Path, output: Path) -> None:
    conversion = lock["conversion"]
    converter = Path(sys.executable).with_name("ct2-transformers-converter")
    command = [
        str(converter),
        "--model",
        str(source_directory),
        "--output_dir",
        str(output),
        "--quantization",
        conversion["quantization"],
        "--copy_files",
        *conversion["copyFiles"],
        "--force",
    ]
    subprocess.run(command, check=True)


def verify_model(output: Path, lock: dict) -> None:
    for relative_path, expected in expected_files(lock).items():
        if not relative_path.startswith("model/"):
            continue
        path = output / Path(relative_path).name
        if not file_matches(path, expected):
            raise RuntimeError(
                f"Converted model does not match lock: {relative_path}"
            )


def prepare(plugin_directory: Path, lock: dict, source_directory: Path) -> None:
    source_directory.mkdir(parents=True, exist_ok=True)
    download_source(lock, source_directory)

    temp_root = Path(
        tempfile.mkdtemp(
            prefix=".opus-model-",
            dir=plugin_directory,
        )
    )
    try:
        converted = temp_root / "model"
        convert_source(lock, source_directory, converted)
        verify_model(converted, lock)

        target = plugin_directory / "model"
        if target.exists():
            shutil.rmtree(target)
        converted.rename(target)
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--plugin-directory", required=True, type=Path)
    parser.add_argument("--source-directory", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    lock = json.loads(arguments.lock.read_text(encoding="utf-8"))
    if model_is_ready(arguments.plugin_directory, lock):
        print("Bundled OPUS-MT model is ready.")
        return 0
    if arguments.check:
        return 1

    prepare(
        arguments.plugin_directory,
        lock,
        arguments.source_directory,
    )
    if not model_is_ready(arguments.plugin_directory, lock):
        raise RuntimeError("Bundled OPUS-MT model failed verification.")
    print("Bundled OPUS-MT model is ready.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
