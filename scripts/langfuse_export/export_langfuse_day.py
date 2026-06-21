#!/usr/bin/env python3
"""Export one UTC day of Langfuse Cloud data to local JSONL.gz archives.

Read-only: uses Langfuse SDK public API list/get_many methods only.
Never prints secrets or raw Langfuse records.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import date, datetime, time as dt_time, timezone, timedelta
from pathlib import Path
from typing import Any, Callable, Iterable

EXPORTER_VERSION = "0.1.0"
DEFAULT_OUT = Path("/home/hermes/archives/langfuse/raw")
ENV_FILES = [
    Path("/home/hermes/.pi/pi-langfuse.env"),
    Path("/home/hermes/.config/contained-runs/secrets.env"),
]
OBJECTS = ("traces", "observations", "scores", "sessions")
PAGE_LIMIT = 100
MAX_RETRIES = 4


class ExportError(RuntimeError):
    pass


@dataclass
class ObjectResult:
    name: str
    count: int = 0
    pages: int = 0
    file: str | None = None
    sha256: str | None = None
    status: str = "pending"
    error: str | None = None


def eprint(*args: Any) -> None:
    print(*args, file=sys.stderr)


def load_env_files() -> list[str]:
    loaded: list[str] = []
    for path in ENV_FILES:
        if not path.exists():
            continue
        try:
            for raw in path.read_text(errors="ignore").splitlines():
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                if key.startswith("LANGFUSE_") and key not in os.environ:
                    os.environ[key] = value
            loaded.append(path.name)
        except OSError:
            continue
    return loaded


def credential_status() -> dict[str, str]:
    return {
        "LANGFUSE_PUBLIC_KEY": "set" if os.environ.get("LANGFUSE_PUBLIC_KEY") else "missing",
        "LANGFUSE_SECRET_KEY": "set" if os.environ.get("LANGFUSE_SECRET_KEY") else "missing",
        "LANGFUSE_HOST_OR_BASEURL": "set" if (os.environ.get("LANGFUSE_HOST") or os.environ.get("LANGFUSE_BASEURL")) else "missing",
    }


def parse_day(value: str) -> tuple[date, datetime, datetime]:
    try:
        d = date.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("--date must use YYYY-MM-DD") from exc
    start = datetime.combine(d, dt_time.min, tzinfo=timezone.utc)
    end = start + timedelta(days=1)
    return d, start, end


def model_to_dict(obj: Any) -> dict[str, Any]:
    if hasattr(obj, "model_dump"):
        return obj.model_dump(mode="json", by_alias=True)
    if hasattr(obj, "dict"):
        return obj.dict()
    if isinstance(obj, dict):
        return obj
    raise TypeError(f"Cannot serialize SDK object of type {type(obj).__name__}")


def response_data(resp: Any) -> list[Any]:
    data = getattr(resp, "data", None)
    if data is None and isinstance(resp, dict):
        data = resp.get("data")
    return list(data or [])


def response_meta(resp: Any) -> Any:
    if hasattr(resp, "meta"):
        return resp.meta
    if isinstance(resp, dict):
        return resp.get("meta")
    return None


def meta_value(meta: Any, key: str) -> Any:
    if meta is None:
        return None
    if isinstance(meta, dict):
        return meta.get(key)
    return getattr(meta, key, None)


def write_record(handle: gzip.GzipFile, record: Any) -> None:
    payload = model_to_dict(record)
    handle.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
    handle.write(b"\n")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def with_retries(fn: Callable[[], Any]) -> Any:
    delay = 1.0
    for attempt in range(MAX_RETRIES + 1):
        try:
            return fn()
        except Exception as exc:  # SDK wraps HTTP errors with generated exception types.
            if attempt >= MAX_RETRIES:
                raise
            name = type(exc).__name__.lower()
            retryable = any(token in name for token in ("timeout", "rate", "too", "server", "service"))
            if not retryable:
                raise
            time.sleep(delay)
            delay = min(delay * 2, 30)


def iter_page_based(fetch: Callable[[int], Any]) -> Iterable[tuple[int, list[Any]]]:
    page = 1
    while True:
        resp = with_retries(lambda p=page: fetch(p))
        data = response_data(resp)
        yield page, data
        meta = response_meta(resp)
        total_pages = meta_value(meta, "total_pages") or meta_value(meta, "totalPages")
        if total_pages is not None:
            if page >= int(total_pages):
                break
        elif not data:
            break
        page += 1


def iter_cursor_based(fetch: Callable[[str | None], Any]) -> Iterable[tuple[int, list[Any]]]:
    cursor: str | None = None
    page = 1
    while True:
        resp = with_retries(lambda c=cursor: fetch(c))
        data = response_data(resp)
        yield page, data
        meta = response_meta(resp)
        next_cursor = meta_value(meta, "cursor")
        if not next_cursor or not data:
            break
        cursor = str(next_cursor)
        page += 1


def export_object(name: str, client: Any, start: datetime, end: datetime, out_dir: Path, dry_run: bool) -> ObjectResult:
    result = ObjectResult(name=name, file=f"{name}.jsonl.gz")
    tmp_path = out_dir / f".{name}.jsonl.gz.tmp"
    final_path = out_dir / f"{name}.jsonl.gz"

    def pages() -> Iterable[tuple[int, list[Any]]]:
        if name == "traces":
            return iter_page_based(lambda page: client.api.trace.list(page=page, limit=PAGE_LIMIT, from_timestamp=start, to_timestamp=end))
        if name == "observations":
            return iter_cursor_based(lambda cursor: client.api.observations.get_many(limit=PAGE_LIMIT, cursor=cursor, from_start_time=start, to_start_time=end))
        if name == "scores":
            return iter_page_based(lambda page: client.api.scores.get_many(page=page, limit=PAGE_LIMIT, from_timestamp=start, to_timestamp=end))
        if name == "sessions":
            return iter_page_based(lambda page: client.api.sessions.list(page=page, limit=PAGE_LIMIT, from_timestamp=start, to_timestamp=end))
        raise ExportError(f"Unsupported object: {name}")

    try:
        if dry_run:
            # Probe only the first page for availability and count that page; no records are written.
            first_page, data = next(iter(pages()))
            result.pages = first_page
            result.count = len(data)
            result.status = "dry-run-ok"
            result.file = None
            return result

        with gzip.open(tmp_path, "wb") as handle:
            for _page, data in pages():
                result.pages += 1
                for item in data:
                    write_record(handle, item)
                    result.count += 1
        tmp_path.replace(final_path)
        result.sha256 = sha256_file(final_path)
        result.status = "success"
        return result
    except Exception as exc:
        result.status = "failure"
        result.error = type(exc).__name__
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass
        return result


def write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def build_client() -> tuple[Any, str]:
    try:
        import langfuse
        from langfuse import Langfuse
    except Exception as exc:
        raise ExportError("Langfuse SDK import failed. Install requirements-langfuse-export.txt in the repo-local venv.") from exc

    public_key = os.environ.get("LANGFUSE_PUBLIC_KEY")
    secret_key = os.environ.get("LANGFUSE_SECRET_KEY")
    host = os.environ.get("LANGFUSE_HOST") or os.environ.get("LANGFUSE_BASEURL")
    if not public_key or not secret_key:
        raise ExportError("Langfuse credentials missing: LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY must be set.")
    # Do not print host; pass it only to SDK.
    client = Langfuse(public_key=public_key, secret_key=secret_key, host=host, timeout=60)
    return client, getattr(langfuse, "__version__", "unknown")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Export one UTC day of Langfuse data to local JSONL.gz archives.")
    parser.add_argument("--date", required=True, help="UTC day to export, format YYYY-MM-DD")
    parser.add_argument("--dry-run", action="store_true", help="Probe SDK endpoints without writing archive files")
    parser.add_argument("--out", default=str(DEFAULT_OUT), help="Archive raw root; default is /home/hermes/archives/langfuse/raw")
    args = parser.parse_args(argv)

    day, start, end = parse_day(args.date)
    env_loaded = load_env_files()
    status = credential_status()
    print("config LANGFUSE_PUBLIC_KEY", status["LANGFUSE_PUBLIC_KEY"])
    print("config LANGFUSE_SECRET_KEY", status["LANGFUSE_SECRET_KEY"])
    print("config LANGFUSE_HOST_OR_BASEURL", status["LANGFUSE_HOST_OR_BASEURL"])

    started = datetime.now(timezone.utc)
    out_dir = Path(args.out) / f"{day:%Y}" / f"{day:%m}" / f"{day:%d}"
    if not args.dry_run:
        out_dir.mkdir(parents=True, exist_ok=True)

    try:
        client, sdk_version = build_client()
        results: dict[str, ObjectResult] = {}
        for name in OBJECTS:
            results[name] = export_object(name, client, start, end, out_dir, args.dry_run)
        overall = "success" if all(r.status in ("success", "dry-run-ok") for r in results.values()) else "failure"
    except Exception as exc:
        sdk_version = "unknown"
        results = {}
        overall = "failure"
        eprint("export failed:", type(exc).__name__, str(exc).splitlines()[0])

    finished = datetime.now(timezone.utc)
    manifest = {
        "exporter_version": EXPORTER_VERSION,
        "sdk_version": sdk_version,
        "status": overall,
        "dry_run": bool(args.dry_run),
        "export_started_at": started.isoformat(),
        "export_finished_at": finished.isoformat(),
        "export_date_range": {"start": start.isoformat(), "end": end.isoformat()},
        "objects": {name: vars(result) for name, result in results.items()},
        "config": {
            "credential_status": status,
            "env_files_loaded_count": len(env_loaded),
        },
    }

    if args.dry_run:
        print(json.dumps({
            "status": overall,
            "dry_run": True,
            "sdk_version": sdk_version,
            "counts_first_page_only": {name: r.count for name, r in results.items()},
        }, indent=2, sort_keys=True))
    else:
        write_manifest(out_dir / "manifest.json", manifest)
        print(json.dumps({
            "status": overall,
            "dry_run": False,
            "archive_dir_created": "set" if out_dir.exists() else "missing",
            "sdk_version": sdk_version,
            "counts": {name: r.count for name, r in results.items()},
        }, indent=2, sort_keys=True))

    return 0 if overall == "success" else 1


if __name__ == "__main__":
    raise SystemExit(main())
