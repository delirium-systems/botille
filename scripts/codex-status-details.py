"""Best-effort metadata absent from Codex hooks (private, versioned SQLite schema)."""

import json
import os
from pathlib import Path
import sqlite3
import sys


def read_details(session_id):
    codex_home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    databases = [
        path for path in codex_home.glob("state_*.sqlite")
        if path.stem.removeprefix("state_").isdigit()
    ]
    if not databases:
        return {}
    # Never fall back to an obsolete database after a migration.
    database = max(databases, key=lambda path: int(path.stem.removeprefix("state_")))
    connection = sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.05)
    try:
        columns = {row[1] for row in connection.execute("PRAGMA table_info(threads)")}
        fields = [field for field in ("name", "title", "reasoning_effort") if field in columns]
        if "id" not in columns or not fields:
            return {}
        row = connection.execute(
            "SELECT " + ", ".join(fields) + " FROM threads WHERE id = ?", (session_id,)
        ).fetchone()
        if row is None:
            return {}
        values = dict(zip(fields, row))
        # Codex 0.160 stores the displayed/renamed title in name; title can
        # still contain the first prompt. Older schemas only have title.
        details = {
            "session_title": values.get("name") or values.get("title"),
            "effort": values.get("reasoning_effort"),
        }
        return {key: value for key, value in details.items() if isinstance(value, str) and value}
    finally:
        connection.close()


if __name__ == "__main__":
    try:
        result = read_details(sys.argv[1])
    except (OSError, ValueError, sqlite3.Error):
        result = {}
    print(json.dumps(result))
