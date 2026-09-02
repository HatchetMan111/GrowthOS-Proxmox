"""
Sehr bewusst schlank gehalten: eine einzige SQLite-Datei, kein ORM, kein
separater DB-Server. Für den MVP (eine Firma, ein Nutzer) reicht das locker
und macht Installation/Backup trivial (eine Datei kopieren = Backup).

Erweiterungsstelle für Phase 2 (Multi-Tenancy): würde hier eine
`tenant_id`-Spalte auf allen Tabellen brauchen und den Wechsel auf
Postgres nahelegen. Bewusst NICHT jetzt gebaut.
"""

import sqlite3
from contextlib import contextmanager
from pathlib import Path

DB_PATH = Path(__file__).parent / "data" / "growthos.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS company (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    product TEXT DEFAULT '',
    goal TEXT DEFAULT '',
    current_state TEXT DEFAULT '',
    target_audience TEXT DEFAULT '',
    competitors TEXT DEFAULT '',
    tone TEXT DEFAULT '',
    updated_at TEXT DEFAULT ''
);

CREATE TABLE IF NOT EXISTS personas (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    description TEXT DEFAULT '',
    system_prompt TEXT NOT NULL,
    model TEXT NOT NULL DEFAULT 'openrouter/auto',
    created_at TEXT DEFAULT ''
);

CREATE TABLE IF NOT EXISTS plans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    persona_id INTEGER,
    raw_response TEXT DEFAULT '',
    created_at TEXT DEFAULT '',
    FOREIGN KEY (persona_id) REFERENCES personas(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS plan_steps (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    plan_id INTEGER NOT NULL,
    position INTEGER NOT NULL,
    title TEXT NOT NULL,
    description TEXT DEFAULT '',
    done INTEGER DEFAULT 0,
    FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS ideas (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    prompt TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at TEXT DEFAULT ''
);

CREATE TABLE IF NOT EXISTS usage_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    day TEXT NOT NULL,
    tokens_used INTEGER NOT NULL,
    model TEXT DEFAULT '',
    purpose TEXT DEFAULT ''
);
"""

DEFAULT_PERSONAS = [
    (
        "Stratege",
        "Positionierung, Zielgruppenanalyse, Go-to-Market-Logik",
        "Du bist ein erfahrener Marketing-Stratege für kleine und mittlere "
        "Unternehmen. Du denkst in konkreten, umsetzbaren Schritten statt in "
        "generischen Marketing-Floskeln. Du berücksichtigst immer Budget- und "
        "Zeitrealität eines kleinen Teams.",
        "openrouter/auto",
    ),
    (
        "Copywriter",
        "Werbetexte, Slogans, E-Mail-Sequenzen",
        "Du bist ein Copywriter mit Fokus auf klare, verkaufsstarke aber "
        "unaufdringliche Sprache. Du schreibst so, wie die Zielgruppe "
        "tatsächlich spricht, nicht in Marketing-Jargon.",
        "openrouter/auto",
    ),
    (
        "SEO-/Content-Experte",
        "Keyword- und Themenplanung, Redaktionsplan",
        "Du bist Content-Stratege mit SEO-Schwerpunkt. Du schlägst konkrete "
        "Themen und Suchbegriffe vor, die zur Zielgruppe und zum "
        "Unternehmen passen, keine generischen Listen.",
        "openrouter/auto",
    ),
    (
        "Ads-Experte",
        "Kampagnenstruktur, Budgetlogik",
        "Du bist Performance-Marketing-Experte für kleine Werbebudgets. Du "
        "gibst realistische, konkrete Empfehlungen zu Kanalwahl, "
        "Budgetaufteilung und Kampagnenstruktur.",
        "openrouter/auto",
    ),
    (
        "Social-Media-Manager",
        "Redaktionsplan, Format- und Plattformwahl",
        "Du bist Social-Media-Manager. Du empfiehlst konkrete Formate, "
        "Plattformen und einen realistischen Rhythmus für ein kleines Team.",
        "openrouter/auto",
    ),
    (
        "Vertriebscoach",
        "Skripte, Einwandbehandlung, Follow-up",
        "Du bist Vertriebscoach für B2B/B2C-Verkauf im kleinen Unternehmen. "
        "Du gibst konkrete Gesprächsleitfäden und Follow-up-Sequenzen, "
        "keine abstrakten Verkaufstheorien.",
        "openrouter/auto",
    ),
]


def init_db() -> None:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with get_conn() as conn:
        conn.executescript(SCHEMA)
        conn.execute(
            "INSERT OR IGNORE INTO company (id) VALUES (1)"
        )
        existing = conn.execute("SELECT COUNT(*) AS c FROM personas").fetchone()
        if existing["c"] == 0:
            from datetime import datetime, timezone

            now = datetime.now(timezone.utc).isoformat()
            conn.executemany(
                "INSERT INTO personas (name, description, system_prompt, model, created_at) "
                "VALUES (?, ?, ?, ?, ?)",
                [(n, d, p, m, now) for (n, d, p, m) in DEFAULT_PERSONAS],
            )
        conn.commit()


@contextmanager
def get_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        yield conn
    finally:
        conn.close()


def get_setting(key: str, default: str = "") -> str:
    with get_conn() as conn:
        row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
        return row["value"] if row else default


def set_setting(key: str, value: str) -> None:
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )
        conn.commit()
