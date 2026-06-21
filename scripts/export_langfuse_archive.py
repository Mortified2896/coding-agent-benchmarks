#!/usr/bin/env python3
"""Read-only Langfuse local archive exporter.

Writes bounded JSONL.gz archives outside this repository. The script prints only
configuration set/missing status, object counts, page counts, and file status; it
never prints credentials or Langfuse record contents.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import shutil
import sys
import time
from datetime import date, datetime, time as dt_time, timedelta, timezone
from pathlib import Path
from typing import Any

import requests

DEFAULT_RAW_ROOT = Path("/home/hermes/archives/langfuse/raw")
ENV_FILES = [
    Path("/home/hermes/.pi/pi-langfuse.env"),
    Path("/home/hermes/.config/contained-runs/secrets.env"),
]
OBJECTS = ("traces", "observations", "scores", "sessions")
ENDPOINTS = {
    "traces": "/api/public/traces",
    "observations": "/api/public/observations",
    "scores": "/api/public/scores",
    "sessions": "/api/public/sessions",
}
TIME_PARAMS = {
    "traces": ("fromTimestamp", "toTimestamp"),
    "observations": ("fromStartTime", "toStartTime"),
    "scores": ("fromTimestamp", "toTimestamp"),
    "sessions": ("fromTimestamp", "toTimestamp"),
}
MAX_PAGE_SIZE = 100
DEFAULT_PAGE_SIZE = 50
MAX_PAGES = 10000
REQUEST_TIMEOUT = (10, 120)
MAX_RETRIES = 6
EXPORTER_VERSION = "1.0.1"


class ExportError(RuntimeError):
    pass


def eprint(*args: Any) -> None:
    print(*args, file=sys.stderr)


def iso_z(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_iso_datetime(value: str) -> datetime:
    raw = value.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(raw)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("datetime must be ISO-8601") from exc
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export bounded Langfuse records to local JSONL.gz archives")
    parser.add_argument("--date", help="UTC day to export, YYYY-MM-DD")
    parser.add_argument("--start", help="inclusive ISO datetime window start")
    parser.add_argument("--end", help="exclusive ISO datetime window end")
    parser.add_argument("--dry-run", action="store_true", help="probe endpoints and pagination shape without writing records")
    parser.add_argument("--force", action="store_true", help="replace expected files for the same target partition/window")
    parser.add_argument("--page-size", "--page-limit", dest="page_size", type=int, default=DEFAULT_PAGE_SIZE, help="records per page, capped at 100")
    parser.add_argument("--max-pages", type=int, default=MAX_PAGES, help="safety cap per object")
    return parser.parse_args(argv)


def export_window(args: argparse.Namespace) -> tuple[date, datetime, datetime]:
    if args.date and (args.start or args.end):
        raise ExportError("use either --date or --start/--end, not both")
    if args.date:
        try:
            d = date.fromisoformat(args.date)
        except ValueError as exc:
            raise ExportError("--date must use YYYY-MM-DD") from exc
        start = datetime.combine(d, dt_time.min, tzinfo=timezone.utc)
        return d, start, start + timedelta(days=1)
    if not (args.start and args.end):
        raise ExportError("provide --date or both --start and --end")
    start = parse_iso_datetime(args.start)
    end = parse_iso_datetime(args.end)
    if end <= start:
        raise ExportError("--end must be after --start")
    return start.date(), start, end


def load_env_files() -> list[str]:
    loaded: list[str] = []
    for path in ENV_FILES:
        if not path.exists():
            continue
        for raw in path.read_text(errors="ignore").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            if key.startswith("LANGFUSE_") and key not in os.environ:
                os.environ[key] = value.strip().strip('"').strip("'")
        loaded.append(path.name)
    return loaded


def config_status() -> dict[str, str]:
    return {
        "LANGFUSE_PUBLIC_KEY": "set" if os.environ.get("LANGFUSE_PUBLIC_KEY") else "missing",
        "LANGFUSE_SECRET_KEY": "set" if os.environ.get("LANGFUSE_SECRET_KEY") else "missing",
        "LANGFUSE_HOST_OR_BASEURL": "set" if (os.environ.get("LANGFUSE_HOST") or os.environ.get("LANGFUSE_BASEURL")) else "missing",
    }


def api_base() -> str:
    host = os.environ.get("LANGFUSE_HOST") or os.environ.get("LANGFUSE_BASEURL")
    if not host:
        raise ExportError("Langfuse host/base URL missing")
    return host.rstrip("/")


def successful_manifest(path: Path) -> bool:
    if not path.exists():
        return False
    try:
        manifest = json.loads(path.read_text())
    except Exception:
        return False
    return manifest.get("completed_successfully") is True or manifest.get("status") == "success"


def remove_expected(out_dir: Path) -> None:
    for name in OBJECTS:
        for suffix in (".jsonl", ".jsonl.gz"):
            (out_dir / f"{name}{suffix}").unlink(missing_ok=True)
    (out_dir / "manifest.json").unlink(missing_ok=True)
    for tmp in out_dir.glob("*.tmp"):
        tmp.unlink(missing_ok=True)


def retry_delay(attempt: int, resp: requests.Response | None = None) -> float:
    if resp is not None:
        retry_after = resp.headers.get("Retry-After")
        if retry_after:
            try:
                return min(float(retry_after), 120.0)
            except ValueError:
                pass
    return min(2.0 ** attempt, 60.0)


def get_page(session: requests.Session, base: str, obj: str, params: dict[str, Any]) -> requests.Response:
    url = base + ENDPOINTS[obj]
    last_exc: requests.RequestException | None = None
    for attempt in range(MAX_RETRIES):
        try:
            resp = session.get(url, params=params, timeout=REQUEST_TIMEOUT)
        except (requests.Timeout, requests.ConnectionError) as exc:
            last_exc = exc
            if attempt < MAX_RETRIES - 1:
                time.sleep(retry_delay(attempt))
                continue
            raise ExportError(f"request failed for {obj} page {params.get('page')}: {type(exc).__name__}") from exc
        if resp.status_code in {408, 409, 425, 429} or resp.status_code >= 500:
            if attempt < MAX_RETRIES - 1:
                time.sleep(retry_delay(attempt, resp))
                continue
        return resp
    raise ExportError(f"request failed for {obj} page {params.get('page')}: {type(last_exc).__name__ if last_exc else 'retry_exhausted'}")


def page_items(payload: Any, obj: str) -> tuple[list[Any], dict[str, Any]]:
    if isinstance(payload, list):
        return payload, {}
    if not isinstance(payload, dict) or not isinstance(payload.get("data"), list):
        raise ExportError(f"API shape mismatch for {obj}: expected JSON object with data list")
    meta = payload.get("meta") or {}
    if meta is not None and not isinstance(meta, dict):
        raise ExportError(f"API shape mismatch for {obj}: meta is not an object")
    return payload["data"], meta


def next_page(meta: dict[str, Any], current: int, got: int) -> int | None:
    total_pages = meta.get("totalPages", meta.get("total_pages"))
    if total_pages is not None:
        return current + 1 if current < int(total_pages) else None
    if got == 0:
        return None
    return current + 1


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def gzip_jsonl(path: Path) -> Path:
    gz = path.with_suffix(path.suffix + ".gz")
    tmp = gz.with_suffix(gz.suffix + ".tmp")
    with path.open("rb") as src, gzip.open(tmp, "wb") as dst:
        shutil.copyfileobj(src, dst)
    tmp.replace(gz)
    path.unlink()
    return gz


def export_object(session: requests.Session, base: str, obj: str, start: datetime, end: datetime, out_dir: Path, dry_run: bool, page_limit: int, max_pages: int) -> dict[str, Any]:
    result: dict[str, Any] = {"status": "pending", "record_count": 0, "page_count": 0, "endpoint": ENDPOINTS[obj]}
    page = 1
    jsonl_path = out_dir / f"{obj}.jsonl"
    from_key, to_key = TIME_PARAMS[obj]
    handle = None
    try:
        if not dry_run:
            handle = jsonl_path.open("w", encoding="utf-8")
        while page <= max_pages:
            params = {"page": page, "limit": page_limit, from_key: iso_z(start), to_key: iso_z(end)}
            resp = get_page(session, base, obj, params)
            if resp.status_code == 404 and obj == "sessions":
                result.update(status="skipped", reason="endpoint_not_supported")
                break
            if not (200 <= resp.status_code < 300):
                result.update(status="failed", http_status=resp.status_code)
                break
            try:
                items, meta = page_items(resp.json(), obj)
            except ValueError as exc:
                raise ExportError(f"API shape mismatch for {obj}: response was not JSON") from exc
            result["page_count"] += 1
            result["record_count"] += len(items)
            if handle is not None:
                for item in items:
                    handle.write(json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n")
            if dry_run:
                result["status"] = "dry_run_ok"
                break
            nxt = next_page(meta, page, len(items))
            if nxt is None:
                result["status"] = "success"
                break
            page = nxt
        else:
            result.update(status="failed", reason="max_pages_exceeded")
    finally:
        if handle is not None:
            handle.close()
    if not dry_run and result["status"] == "success":
        gz = gzip_jsonl(jsonl_path)
        result.update(file=gz.name, gzip_size_bytes=gz.stat().st_size, sha256=sha256_file(gz))
    elif not dry_run:
        jsonl_path.unlink(missing_ok=True)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.page_size < 1:
        raise ExportError("--page-size must be positive")
    page_size = min(args.page_size, MAX_PAGE_SIZE)
    day, start, end = export_window(args)
    loaded = load_env_files()
    status = config_status()
    for key, value in status.items():
        print("config", key, value)
    if "missing" in status.values():
        eprint("export failed: missing required Langfuse config")
        return 1
    out_dir = DEFAULT_RAW_ROOT / f"{day:%Y}" / f"{day:%m}" / f"{day:%d}"
    if not args.dry_run and successful_manifest(out_dir / "manifest.json"):
        if not args.force:
            eprint(f"refusing to overwrite successful export at {out_dir}; pass --force to replace expected files")
            return 2
        eprint(f"refusing to --force overwrite successful export at {out_dir}")
        return 2
    if not args.dry_run:
        out_dir.mkdir(parents=True, exist_ok=True)
        if args.force:
            remove_expected(out_dir)
    started = datetime.now(timezone.utc)
    session = requests.Session()
    session.auth = (os.environ["LANGFUSE_PUBLIC_KEY"], os.environ["LANGFUSE_SECRET_KEY"])
    session.headers.update({"Accept": "application/json", "User-Agent": "hermes-langfuse-archive-exporter/1.0"})
    objects: dict[str, Any] = {}
    try:
        base = api_base()
        for obj in OBJECTS:
            objects[obj] = export_object(session, base, obj, start, end, out_dir, args.dry_run, page_size, args.max_pages)
            print("object", obj, "status", objects[obj]["status"], "records", objects[obj]["record_count"], "pages", objects[obj]["page_count"])
    except Exception as exc:
        eprint("export failed:", type(exc).__name__, str(exc).splitlines()[0])
        return 1
    success = all(v["status"] in {"success", "skipped"} for v in objects.values()) if not args.dry_run else all(v["status"] in {"dry_run_ok", "skipped"} for v in objects.values())
    manifest = {
        "schema_version": 1,
        "exporter_version": EXPORTER_VERSION,
        "source": "langfuse-cloud-public-api",
        "export_date": day.isoformat(),
        "export_window_start": iso_z(start),
        "export_window_end": iso_z(end),
        "exported_at": iso_z(datetime.now(timezone.utc)),
        "export_started_at": iso_z(started),
        "object_types_attempted": list(OBJECTS),
        "objects": objects,
        "api_status_summary": {k: v["status"] for k, v in objects.items()},
        "page_size": page_size,
        "completed_successfully": bool(success and not args.dry_run),
        "dry_run": bool(args.dry_run),
        "safety": {"secrets_printed": False, "record_contents_printed": False, "env_values_printed": False},
        "config": {"credential_status": status, "env_files_loaded_count": len(loaded)},
    }
    if args.dry_run:
        print("dry_run", "success" if success else "failure")
    else:
        tmp = out_dir / "manifest.json.tmp"
        tmp.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        tmp.replace(out_dir / "manifest.json")
        print("manifest", str(out_dir / "manifest.json"))
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
