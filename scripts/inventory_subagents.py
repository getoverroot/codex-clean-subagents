#!/usr/bin/env python3
"""Read-only inventory helper for the codex-clean-subagents skill."""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path
from typing import Any, Iterable, NoReturn
from urllib.parse import quote


REQUIRED_COLUMNS = {
    "threads": {"id", "rollout_path", "thread_source", "archived", "title"},
    "thread_spawn_edges": {"parent_thread_id", "child_thread_id", "status"},
}


def fail(message: str) -> NoReturn:
    raise RuntimeError(message)


def chunks(values: list[str], size: int = 400) -> Iterable[list[str]]:
    for offset in range(0, len(values), size):
        yield values[offset : offset + size]


def path_stats(raw_path: str | None, codex_home: Path) -> tuple[str | None, bool, int]:
    if not raw_path:
        return None, False, 0
    path = Path(raw_path).expanduser()
    if not path.is_absolute():
        path = codex_home / path
    try:
        resolved = path.resolve(strict=False)
        stat = resolved.stat()
        return str(resolved), resolved.is_file(), stat.st_size if resolved.is_file() else 0
    except OSError:
        return str(path), False, 0


def choose_state_db(codex_home: Path, explicit: str | None) -> Path:
    if explicit:
        candidate = Path(explicit).expanduser().resolve(strict=False)
        if not candidate.is_file():
            fail(f"State database does not exist: {candidate}")
        return candidate
    candidates = [path for path in codex_home.glob("state_*.sqlite") if path.is_file()]
    if not candidates:
        fail(f"No state_*.sqlite database found under {codex_home}")
    return max(candidates, key=lambda path: path.stat().st_mtime_ns).resolve(strict=False)


def connect_read_only(state_db: Path) -> sqlite3.Connection:
    uri = f"file:{quote(state_db.as_posix(), safe='/:')}?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=10)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only = ON")
    return connection


def validate_schema(connection: sqlite3.Connection) -> None:
    tables = {
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        )
    }
    for table, expected_columns in REQUIRED_COLUMNS.items():
        if table not in tables:
            fail(f"Unsupported Codex state schema: missing table {table}")
        actual_columns = {
            row[1] for row in connection.execute(f"PRAGMA table_info({table})")
        }
        missing = expected_columns - actual_columns
        if missing:
            fail(
                f"Unsupported Codex state schema: {table} lacks "
                + ", ".join(sorted(missing))
            )


def fetch_roots(
    connection: sqlite3.Connection, root_ids: list[str]
) -> list[sqlite3.Row]:
    if not root_ids:
        return []
    placeholders = ",".join("?" for _ in root_ids)
    rows = list(
        connection.execute(
            f"""
            SELECT id, rollout_path, thread_source, archived, title
            FROM threads
            WHERE id IN ({placeholders})
            """,
            root_ids,
        )
    )
    by_id = {row["id"]: row for row in rows}
    missing = [root_id for root_id in root_ids if root_id not in by_id]
    if missing:
        fail("Unknown main-thread UUID(s): " + ", ".join(missing))
    ordered = [by_id[root_id] for root_id in root_ids]
    subagent_roots = [row["id"] for row in ordered if row["thread_source"] == "subagent"]
    if subagent_roots:
        fail("Refusing subagent UUID(s) as main roots: " + ", ".join(subagent_roots))
    return ordered


DESCENDANT_CTE = """
WITH RECURSIVE descendants(id) AS (
    SELECT child_thread_id
    FROM thread_spawn_edges
    WHERE parent_thread_id = ?
    UNION
    SELECT edge.child_thread_id
    FROM thread_spawn_edges AS edge
    JOIN descendants ON edge.parent_thread_id = descendants.id
)
"""


def eligible_rows(connection: sqlite3.Connection, root_id: str) -> list[sqlite3.Row]:
    return list(
        connection.execute(
            DESCENDANT_CTE
            + """
            SELECT DISTINCT thread.id, thread.rollout_path
            FROM descendants
            JOIN threads AS thread ON thread.id = descendants.id
            WHERE thread.thread_source = 'subagent'
              AND EXISTS (
                  SELECT 1 FROM thread_spawn_edges AS incoming
                  WHERE incoming.child_thread_id = thread.id
                    AND lower(incoming.status) = 'closed'
              )
              AND NOT EXISTS (
                  SELECT 1 FROM thread_spawn_edges AS incoming
                  WHERE incoming.child_thread_id = thread.id
                    AND lower(incoming.status) <> 'closed'
              )
              AND NOT EXISTS (
                  SELECT 1 FROM thread_spawn_edges AS outgoing
                  WHERE outgoing.parent_thread_id = thread.id
              )
            """,
            (root_id,),
        )
    )


def root_metrics(connection: sqlite3.Connection, root_id: str) -> dict[str, int]:
    row = connection.execute(
        DESCENDANT_CTE
        + """
        SELECT
            count(DISTINCT descendants.id) AS descendants,
            count(DISTINCT CASE WHEN thread.thread_source = 'subagent'
                                THEN thread.id END) AS subagents,
            count(DISTINCT CASE WHEN thread.thread_source = 'subagent'
                                      AND EXISTS (
                                          SELECT 1 FROM thread_spawn_edges AS incoming
                                          WHERE incoming.child_thread_id = thread.id
                                            AND lower(incoming.status) <> 'closed'
                                      )
                                THEN thread.id END) AS open_or_nonclosed_subagents,
            count(DISTINCT CASE WHEN thread.thread_source = 'subagent'
                                      AND EXISTS (
                                          SELECT 1 FROM thread_spawn_edges AS outgoing
                                          WHERE outgoing.parent_thread_id = thread.id
                                      )
                                THEN thread.id END) AS nonleaf_subagents
        FROM descendants
        LEFT JOIN threads AS thread ON thread.id = descendants.id
        """,
        (root_id,),
    ).fetchone()
    return {key: int(row[key] or 0) for key in row.keys()}


def inspect_ids(
    connection: sqlite3.Connection, ids: list[str], codex_home: Path
) -> list[dict[str, Any]]:
    unique_ids = list(dict.fromkeys(ids))
    thread_rows: dict[str, sqlite3.Row] = {}
    incoming: dict[str, list[str]] = {thread_id: [] for thread_id in unique_ids}
    outgoing: dict[str, int] = {thread_id: 0 for thread_id in unique_ids}

    for batch in chunks(unique_ids):
        placeholders = ",".join("?" for _ in batch)
        for row in connection.execute(
            f"SELECT id, rollout_path, thread_source FROM threads WHERE id IN ({placeholders})",
            batch,
        ):
            thread_rows[row["id"]] = row
        for row in connection.execute(
            f"""
            SELECT child_thread_id, status
            FROM thread_spawn_edges
            WHERE child_thread_id IN ({placeholders})
            """,
            batch,
        ):
            incoming[row["child_thread_id"]].append(str(row["status"]).lower())
        for row in connection.execute(
            f"""
            SELECT parent_thread_id, count(*) AS edge_count
            FROM thread_spawn_edges
            WHERE parent_thread_id IN ({placeholders})
            GROUP BY parent_thread_id
            """,
            batch,
        ):
            outgoing[row["parent_thread_id"]] = int(row["edge_count"])

    result: list[dict[str, Any]] = []
    for thread_id in unique_ids:
        row = thread_rows.get(thread_id)
        statuses = sorted(set(incoming[thread_id]))
        rollout_path, file_exists, file_bytes = path_stats(
            row["rollout_path"] if row else None, codex_home
        )
        eligible = bool(
            row
            and row["thread_source"] == "subagent"
            and statuses == ["closed"]
            and outgoing[thread_id] == 0
        )
        result.append(
            {
                "id": thread_id,
                "thread_present": row is not None,
                "thread_source": row["thread_source"] if row else None,
                "incoming_statuses": statuses,
                "incoming_edge_count": len(incoming[thread_id]),
                "outgoing_edge_count": outgoing[thread_id],
                "eligible_closed_leaf": eligible,
                "rollout_path": rollout_path,
                "file_exists": file_exists,
                "file_bytes": file_bytes,
            }
        )
    return result


def build_inventory(
    connection: sqlite3.Connection,
    roots: list[sqlite3.Row],
    codex_home: Path,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    root_results: list[dict[str, Any]] = []
    targets: dict[str, dict[str, Any]] = {}
    for root in roots:
        root_path, root_exists, root_bytes = path_stats(root["rollout_path"], codex_home)
        candidates = eligible_rows(connection, root["id"])
        metrics = root_metrics(connection, root["id"])
        eligible_bytes = 0
        for candidate in candidates:
            rollout_path, file_exists, file_bytes = path_stats(
                candidate["rollout_path"], codex_home
            )
            eligible_bytes += file_bytes
            target = targets.setdefault(
                candidate["id"],
                {
                    "id": candidate["id"],
                    "rollout_path": rollout_path,
                    "file_exists": file_exists,
                    "bytes": file_bytes,
                    "root_ids": [],
                },
            )
            if root["id"] not in target["root_ids"]:
                target["root_ids"].append(root["id"])
        root_results.append(
            {
                "id": root["id"],
                "title": root["title"],
                "thread_source": root["thread_source"],
                "archived": bool(root["archived"]),
                "rollout_path": root_path,
                "file_exists": root_exists,
                "bytes": root_bytes,
                **metrics,
                "eligible_closed_leaf_count": len(candidates),
                "eligible_closed_leaf_bytes": eligible_bytes,
            }
        )
    sorted_targets = sorted(targets.values(), key=lambda item: (-item["bytes"], item["id"]))
    return root_results, sorted_targets


def list_root_candidates(
    connection: sqlite3.Connection, codex_home: Path
) -> list[dict[str, Any]]:
    rows = list(
        connection.execute(
            """
            SELECT id, rollout_path, thread_source, archived, title
            FROM threads
            WHERE thread_source <> 'subagent'
            """
        )
    )
    roots, _ = build_inventory(connection, rows, codex_home)
    roots = [root for root in roots if root["eligible_closed_leaf_count"] > 0]
    return sorted(
        roots,
        key=lambda item: (-item["eligible_closed_leaf_bytes"], item["id"]),
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex-home", required=True)
    parser.add_argument("--state-db")
    parser.add_argument("--root-thread-id", action="append", default=[])
    parser.add_argument("--list-roots", action="store_true")
    parser.add_argument(
        "--check-stdin",
        action="store_true",
        help="Read a JSON array of thread UUIDs from stdin and inspect them.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    codex_home = Path(args.codex_home).expanduser().resolve(strict=False)
    if not codex_home.is_dir():
        fail(f"Codex home does not exist: {codex_home}")
    if args.list_roots and args.root_thread_id:
        fail("Use either --list-roots or --root-thread-id, not both")
    if not args.list_roots and not args.root_thread_id:
        fail("Supply --list-roots or at least one --root-thread-id")

    check_ids: list[str] = []
    if args.check_stdin:
        payload = json.load(sys.stdin)
        if not isinstance(payload, list) or not all(isinstance(value, str) for value in payload):
            fail("--check-stdin expects a JSON array of string UUIDs")
        check_ids = payload

    state_db = choose_state_db(codex_home, args.state_db)
    with connect_read_only(state_db) as connection:
        validate_schema(connection)
        if args.list_roots:
            result = {
                "inventory_version": 1,
                "codex_home": str(codex_home),
                "state_db": str(state_db),
                "root_candidates": list_root_candidates(connection, codex_home),
                "roots": [],
                "targets": [],
                "checks": [],
            }
        else:
            root_ids = list(dict.fromkeys(args.root_thread_id))
            root_rows = fetch_roots(connection, root_ids)
            roots, targets = build_inventory(connection, root_rows, codex_home)
            result = {
                "inventory_version": 1,
                "codex_home": str(codex_home),
                "state_db": str(state_db),
                "root_candidates": [],
                "roots": roots,
                "targets": targets,
                "checks": inspect_ids(connection, check_ids, codex_home),
            }
    json.dump(result, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, sqlite3.Error, OSError, ValueError, json.JSONDecodeError) as error:
        print(f"inventory_subagents.py: {error}", file=sys.stderr)
        raise SystemExit(2)
