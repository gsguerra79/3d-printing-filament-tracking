#!/usr/bin/env python3
from __future__ import annotations

import concurrent.futures
import ipaddress
import json
import sqlite3
import math
import re
import threading
import time
from datetime import datetime, timezone
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parent
STATIC_ROOT = ROOT / "static"
DB_PATH = ROOT / "filament_inventory.sqlite3"
CREALITY_RESOURCES = Path("/Applications/Creality Print.app/Contents/Resources")
USAGE_MONITOR_LOCK = threading.Lock()
USAGE_MONITOR_STARTED = False
USAGE_MONITOR_INTERVAL_SECONDS = 10

MATERIAL_DENSITY = {
    "PLA": 1.24,
    "PETG": 1.27,
    "ABS": 1.04,
    "ASA": 1.07,
    "TPU": 1.20,
    "PC": 1.20,
    "NYLON": 1.14,
    "PA": 1.14,
}

STANDARD_COLOR_OPTIONS = [
    ("Black", "#000000"),
    ("White", "#ffffff"),
    ("Gray", "#808080"),
    ("Silver", "#c0c0c0"),
    ("Red", "#ff0000"),
    ("Orange", "#ff7a00"),
    ("Yellow", "#ffd400"),
    ("Green", "#00a650"),
    ("Blue", "#006fd6"),
    ("Purple", "#7a3db8"),
    ("Pink", "#ff6bb5"),
    ("Brown", "#7a4a2a"),
    ("Beige", "#d8c3a5"),
    ("Gold", "#cf942b"),
    ("Natural", "#f2ead8"),
    ("Clear", "#f7f7f7"),
    ("Wood", "#d8b589"),
]


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def connect() -> sqlite3.Connection:
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    return con


def init_db() -> None:
    with connect() as con:
        con.executescript(
            """
            CREATE TABLE IF NOT EXISTS locations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL CHECK (kind IN ('cfs', 'dryer', 'storage', 'retired')),
                sort_order INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS spools (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                barcode TEXT,
                material TEXT NOT NULL,
                brand TEXT NOT NULL,
                color_name TEXT NOT NULL,
                color_hex TEXT NOT NULL DEFAULT '#888888',
                diameter TEXT NOT NULL DEFAULT '1.75mm',
                original_weight_g INTEGER NOT NULL DEFAULT 1000,
                remaining_weight_g INTEGER NOT NULL DEFAULT 1000,
                status TEXT NOT NULL CHECK (status IN ('sealed', 'open', 'loaded', 'retired')),
                location_id INTEGER REFERENCES locations(id) ON DELETE SET NULL,
                cfs_slot_name TEXT,
                purchased_at TEXT,
                opened_at TEXT,
                notes TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS usage_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                spool_id INTEGER NOT NULL REFERENCES spools(id) ON DELETE CASCADE,
                grams_used INTEGER NOT NULL,
                project TEXT NOT NULL DEFAULT '',
                notes TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS creality_filaments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_key TEXT NOT NULL UNIQUE,
                filament_id TEXT,
                brand TEXT NOT NULL,
                type TEXT NOT NULL,
                name TEXT NOT NULL,
                cfs_material_code TEXT,
                source_path TEXT,
                raw_json TEXT NOT NULL DEFAULT '{}',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_creality_filaments_brand
            ON creality_filaments (brand);

            CREATE INDEX IF NOT EXISTS idx_creality_filaments_type
            ON creality_filaments (type);

            CREATE INDEX IF NOT EXISTS idx_creality_filaments_name
            ON creality_filaments (name);

            """
        )

        defaults = [
            ("CFS Slot 1", "cfs", 10),
            ("CFS Slot 2", "cfs", 20),
            ("CFS Slot 3", "cfs", 30),
            ("CFS Slot 4", "cfs", 40),
            ("External Spool Holder", "cfs", 45),
            ("Dehumidifier", "dryer", 50),
            ("Open Storage", "storage", 60),
            ("Sealed Stock", "storage", 70),
            ("Retired / Empty", "retired", 80),
        ]
        con.executemany(
            "INSERT OR IGNORE INTO locations (name, kind, sort_order) VALUES (?, ?, ?)",
            defaults,
        )
        columns = {
            row["name"]
            for row in con.execute("PRAGMA table_info(spools)").fetchall()
        }
        if "cfs_slot_name" not in columns:
            con.execute("ALTER TABLE spools ADD COLUMN cfs_slot_name TEXT")
        if "barcode" not in columns:
            con.execute("ALTER TABLE spools ADD COLUMN barcode TEXT")
        if "creality_filament_id" not in columns:
            con.execute("ALTER TABLE spools ADD COLUMN creality_filament_id INTEGER REFERENCES creality_filaments(id) ON DELETE SET NULL")
        if "creality_brand" not in columns:
            con.execute("ALTER TABLE spools ADD COLUMN creality_brand TEXT")
        if "creality_type" not in columns:
            con.execute("ALTER TABLE spools ADD COLUMN creality_type TEXT")
        if "creality_name" not in columns:
            con.execute("ALTER TABLE spools ADD COLUMN creality_name TEXT")
        if "cfs_material_code" not in columns:
            con.execute("ALTER TABLE spools ADD COLUMN cfs_material_code TEXT")
        if "cfs_color_code" not in columns:
            con.execute("ALTER TABLE spools ADD COLUMN cfs_color_code TEXT")

        con.executescript(
            """
            CREATE INDEX IF NOT EXISTS idx_spools_barcode
            ON spools (barcode);

            CREATE INDEX IF NOT EXISTS idx_spools_creality_filament
            ON spools (creality_filament_id);
            """
        )
        con.execute("DROP TABLE IF EXISTS filament_catalog")
        if not con.execute("SELECT 1 FROM creality_filaments LIMIT 1").fetchone():
            import_creality_filaments(con)


def row_to_dict(row: sqlite3.Row) -> dict:
    return {key: row[key] for key in row.keys()}


def get_setting(key: str, fallback: str = "") -> str:
    with connect() as con:
        row = con.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else fallback


def set_setting(key: str, value) -> None:
    with connect() as con:
        con.execute(
            """
            INSERT OR REPLACE INTO settings (key, value)
            VALUES (?, ?)
            """,
            (key, str(value)),
        )


def set_settings(values: dict) -> None:
    with connect() as con:
        con.executemany(
            """
            INSERT OR REPLACE INTO settings (key, value)
            VALUES (?, ?)
            """,
            [(key, str(value)) for key, value in values.items()],
        )


def first_list_value(value, fallback: str = "") -> str:
    if isinstance(value, list):
        for item in value:
            text = clean_text(item)
            if text:
                return text
        return fallback
    return clean_text(value, fallback)


def profile_family(name: str) -> str:
    family = clean_text(name).split("@", 1)[0].strip()
    return re.sub(r"\s+", " ", family)


def infer_creality_type(profile: dict, family: str) -> str:
    filament_type = first_list_value(profile.get("filament_type"))
    if filament_type:
        return filament_type.upper()

    haystack = f"{family} {profile.get('inherits', '')}".upper()
    known = [
        "PLA-CF",
        "PLA-AERO",
        "PETG-CF",
        "PETG",
        "ABS-GF",
        "ABS",
        "ASA-AERO",
        "ASA",
        "TPU",
        "PA6-CF",
        "PA-CF",
        "PA-GF",
        "PA",
        "PET-CF",
        "PPS-CF",
        "PPS",
        "PPA-CF",
        "PPA-GF",
        "PC",
        "PVA",
        "BVOH",
        "PEEK",
        "PCTG",
        "HIPS",
        "PP-CF",
        "PP-GF",
        "PP",
        "PE-CF",
        "PE",
        "EVA",
        "PHA",
    ]
    for material in known:
        if re.search(rf"(^|[^A-Z0-9]){re.escape(material)}([^A-Z0-9]|$)", haystack):
            return material
    return "PLA"


def normalize_creality_brand(profile: dict, family: str, folder: str) -> str:
    vendor = first_list_value(profile.get("filament_vendor"))
    if "GENERIC" in family.upper():
        return "Generic"
    return clean_text(vendor or folder or "Generic", "Generic")


def normalize_creality_name(brand: str, family: str, material_type: str, folder: str = "") -> str:
    name = clean_text(family)
    if folder:
        name = re.sub(rf"^\s*{re.escape(folder)}\s+", "", name, flags=re.IGNORECASE).strip()
    name = re.sub(r"^\s*generic\s+", "", name, flags=re.IGNORECASE).strip()
    if brand and brand.lower() != "generic":
        name = re.sub(rf"^\s*{re.escape(brand)}\s+", "", name, flags=re.IGNORECASE).strip()
    return name or material_type


def cfs_code_from_filament_id(filament_id: str) -> str:
    text = clean_text(filament_id)
    return f"0{text}" if len(text) == 5 and text.isdigit() else ""


def creality_source_records() -> list[dict]:
    profiles_root = CREALITY_RESOURCES / "profiles"
    if not profiles_root.exists():
        return []

    records = {}
    for path in profiles_root.glob("*/filament/*.json"):
        try:
            profile = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            continue
        if not isinstance(profile, dict) or profile.get("type") != "filament":
            continue
        filament_id = clean_text(profile.get("filament_id"))
        if not filament_id:
            continue

        family = profile_family(profile.get("name") or path.stem)
        material_type = infer_creality_type(profile, family)
        folder = path.parent.parent.name
        brand = normalize_creality_brand(profile, family, folder)
        name = normalize_creality_name(brand, family, material_type, folder)
        source_key = "|".join((brand.lower(), material_type.lower(), name.lower(), filament_id))
        if source_key in records:
            continue
        records[source_key] = {
            "source_key": source_key,
            "filament_id": filament_id,
            "brand": brand,
            "type": material_type,
            "name": name,
            "cfs_material_code": cfs_code_from_filament_id(filament_id) or None,
            "source_path": str(path.relative_to(CREALITY_RESOURCES)),
            "raw_json": json.dumps(
                {
                    "name": profile.get("name"),
                    "filament_id": filament_id,
                    "filament_vendor": profile.get("filament_vendor"),
                    "filament_type": profile.get("filament_type"),
                    "inherits": profile.get("inherits"),
                    "profile_folder": path.parent.parent.name,
                    "source_path": str(path.relative_to(CREALITY_RESOURCES)),
                },
                sort_keys=True,
            ),
        }
    return sorted(records.values(), key=lambda item: (item["brand"], item["type"], item["name"], item["filament_id"]))


def import_creality_filaments(con: sqlite3.Connection | None = None) -> int:
    records = creality_source_records()
    timestamp = now_iso()
    close_after = con is None
    con = con or connect()
    try:
        if records:
            placeholders = ",".join("?" for _ in records)
            con.execute(
                f"DELETE FROM creality_filaments WHERE source_key NOT IN ({placeholders})",
                [record["source_key"] for record in records],
            )
        con.executemany(
            """
            INSERT INTO creality_filaments (
                source_key, filament_id, brand, type, name, cfs_material_code,
                source_path, raw_json, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_key) DO UPDATE SET
                filament_id = excluded.filament_id,
                brand = excluded.brand,
                type = excluded.type,
                name = excluded.name,
                cfs_material_code = excluded.cfs_material_code,
                source_path = excluded.source_path,
                raw_json = excluded.raw_json,
                updated_at = excluded.updated_at
            """,
            [
                (
                    record["source_key"],
                    record["filament_id"],
                    record["brand"],
                    record["type"],
                    record["name"],
                    record["cfs_material_code"],
                    record["source_path"],
                    record["raw_json"],
                    timestamp,
                    timestamp,
                )
                for record in records
            ],
        )
        con.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES ('creality_catalog_updated_at', ?)",
            (timestamp,),
        )
        con.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES ('creality_catalog_count', ?)",
            (str(len(records)),),
        )
        con.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES ('creality_catalog_path', ?)",
            (str(CREALITY_RESOURCES),),
        )
        return len(records)
    finally:
        if close_after:
            con.close()


def catalog_result(row: sqlite3.Row) -> dict:
    item = row_to_dict(row)
    item["creality_filament_id"] = item["id"]
    item["creality_brand"] = item["brand"]
    item["creality_type"] = item["type"]
    item["creality_name"] = item["name"]
    item["material"] = item["type"]
    item["color_name"] = item["name"]
    item["color_hex"] = "#888888"
    item["display_name"] = f"{item['brand']} / {item['type']} / {item['name']}"
    return item


def catalog_options(brand: str = "", material_type: str = "") -> dict:
    brand = clean_text(brand)
    material_type = clean_text(material_type)
    with connect() as con:
        brands = [
            row["brand"]
            for row in con.execute(
                """
                SELECT DISTINCT brand
                FROM creality_filaments
                ORDER BY
                  CASE brand WHEN 'Creality' THEN 0 WHEN 'Generic' THEN 1 ELSE 2 END,
                  brand
                """
            ).fetchall()
        ]
        params = []
        brand_clause = ""
        if brand:
            brand_clause = "WHERE brand = ?"
            params.append(brand)
        types = [
            row["type"]
            for row in con.execute(
                f"""
                SELECT DISTINCT type
                FROM creality_filaments
                {brand_clause}
                ORDER BY
                  CASE type
                    WHEN 'PLA' THEN 0
                    WHEN 'PETG' THEN 1
                    WHEN 'TPU' THEN 2
                    WHEN 'ABS' THEN 3
                    ELSE 4
                  END,
                  type
                """,
                params,
            ).fetchall()
        ]

        clauses = []
        name_params = []
        if brand:
            clauses.append("brand = ?")
            name_params.append(brand)
        if material_type:
            clauses.append("type = ?")
            name_params.append(material_type)
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        name_rows = con.execute(
            f"""
            SELECT *
            FROM creality_filaments
            {where}
            ORDER BY
              CASE WHEN cfs_material_code IS NOT NULL THEN 0 ELSE 1 END,
              CASE WHEN LOWER(name) = LOWER(type) THEN 0 ELSE 1 END,
              name
            LIMIT 500
            """,
            name_params,
        ).fetchall()
        seen_names = set()
        names = []
        for row in name_rows:
            item = catalog_result(row)
            key = (item["creality_brand"], item["creality_type"], item["creality_name"])
            if key in seen_names:
                continue
            seen_names.add(key)
            names.append(item)
        colors = [{"name": name, "hex": hex_value} for name, hex_value in STANDARD_COLOR_OPTIONS]
    return {"brands": brands, "types": types, "names": names, "colors": colors}


def fetch_bootstrap() -> dict:
    with connect() as con:
        locations = [
            row_to_dict(row)
            for row in con.execute(
                "SELECT * FROM locations ORDER BY sort_order, name"
            ).fetchall()
        ]
        spools = [
            row_to_dict(row)
            for row in con.execute(
                """
                SELECT
                    s.*,
                    l.name AS location_name,
                    l.kind AS location_kind
                FROM spools s
                LEFT JOIN locations l ON l.id = s.location_id
                ORDER BY
                    CASE s.status
                        WHEN 'loaded' THEN 1
                        WHEN 'open' THEN 2
                        WHEN 'sealed' THEN 3
                        ELSE 4
                    END,
                    l.sort_order,
                    s.material,
                    s.brand,
                    s.color_name
                """
            ).fetchall()
        ]
        usage = [
            row_to_dict(row)
            for row in con.execute(
                """
                SELECT u.*, s.material, s.brand, s.color_name, s.color_hex
                FROM usage_events u
                JOIN spools s ON s.id = u.spool_id
                ORDER BY u.created_at DESC, u.id DESC
                LIMIT 50
                """
            ).fetchall()
        ]
        settings = {
            row["key"]: row["value"]
            for row in con.execute("SELECT key, value FROM settings").fetchall()
        }
        catalog_count = con.execute("SELECT COUNT(*) AS count FROM creality_filaments").fetchone()[
            "count"
        ]
    return {
        "locations": locations,
        "spools": spools,
        "usage": usage,
        "settings": settings,
        "catalog_count": catalog_count,
    }


def search_catalog(
    query: str = "",
    limit: int = 40,
    brand: str = "",
    material: str = "",
    color: str = "",
    barcode: str = "",
) -> dict:
    query = clean_text(query)
    brand = clean_text(brand)
    material = clean_text(material)
    color = clean_text(color)
    limit = min(max(clean_int(limit, 40, 1), 1), 80)
    with connect() as con:
        total = con.execute("SELECT COUNT(*) AS count FROM creality_filaments").fetchone()[
            "count"
        ]
        if barcode:
            rows = []
        elif not any((query, brand, material, color)):
            rows = con.execute(
                """
                SELECT *
                FROM creality_filaments
                ORDER BY
                  CASE brand WHEN 'Generic' THEN 0 WHEN 'Creality' THEN 1 ELSE 2 END,
                  brand, type, name
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
        else:
            clauses = []
            params = []
            if query:
                for term in query.lower().split():
                    if term:
                        clauses.append(
                            "(LOWER(brand || ' ' || type || ' ' || name || ' ' || filament_id) LIKE ?)"
                        )
                        params.append(f"%{term}%")
            if brand:
                clauses.append("LOWER(brand) LIKE LOWER(?)")
                params.append(f"%{brand}%")
            if material:
                clauses.append("(LOWER(type) LIKE LOWER(?) OR LOWER(name) LIKE LOWER(?))")
                params.extend([f"%{material}%", f"%{material}%"])
            if color:
                clauses.append("LOWER(name) LIKE LOWER(?)")
                params.append(f"%{color}%")
            if not clauses:
                clauses.append("1 = 1")
            rows = con.execute(
                f"""
                SELECT *
                FROM creality_filaments
                WHERE {" AND ".join(clauses)}
                ORDER BY
                  CASE
                    WHEN LOWER(brand) = LOWER(?) THEN 0
                    WHEN brand = 'Generic' THEN 1
                    WHEN brand = 'Creality' THEN 2
                    ELSE 3
                  END,
                  CASE
                    WHEN LOWER(type) = LOWER(?) THEN 0
                    WHEN LOWER(name) = LOWER(?) THEN 1
                    WHEN LOWER(name) = LOWER(type) THEN 2
                    WHEN LOWER(type) LIKE LOWER(?) THEN 3
                    WHEN LOWER(name) LIKE LOWER(?) THEN 4
                    ELSE 5
                  END,
                  CASE WHEN cfs_material_code IS NOT NULL THEN 0 ELSE 1 END,
                  brand, type, name
                LIMIT ?
                """,
                (
                    *params,
                    brand or query,
                    material or query,
                    material or query,
                    f"{material or query}%",
                    f"{material or query}%",
                    limit,
                ),
            ).fetchall()
    return {
        "total": total,
        "results": [catalog_result(row) for row in rows],
    }


def creality_filament_by_id(con: sqlite3.Connection, value) -> dict | None:
    filament_id = clean_int(value, 0, 1)
    if not filament_id:
        return None
    row = con.execute("SELECT * FROM creality_filaments WHERE id = ?", (filament_id,)).fetchone()
    return row_to_dict(row) if row else None


def match_creality_filament(con: sqlite3.Connection, material_code: str = "", material: str = "") -> dict | None:
    material_code = clean_text(material_code)
    if material_code:
        row = con.execute(
            "SELECT * FROM creality_filaments WHERE cfs_material_code = ? LIMIT 1",
            (material_code,),
        ).fetchone()
        if row:
            return row_to_dict(row)
        if len(material_code) >= 5:
            row = con.execute(
                "SELECT * FROM creality_filaments WHERE filament_id = ? LIMIT 1",
                (material_code[-5:],),
            ).fetchone()
            if row:
                return row_to_dict(row)

    material = clean_text(material).upper()
    if material:
        row = con.execute(
            """
            SELECT * FROM creality_filaments
            WHERE brand = 'Generic'
              AND (UPPER(type) = ? OR UPPER(name) = ? OR UPPER(name) LIKE ?)
            ORDER BY
              CASE WHEN UPPER(name) = ? THEN 0 ELSE 1 END,
              name
            LIMIT 1
            """,
            (material, material, f"{material}%", material),
        ).fetchone()
        if row:
            return row_to_dict(row)
    return None


def backfill_spool_creality_mapping(con: sqlite3.Connection) -> int:
    rows = con.execute(
        """
        SELECT id, material, cfs_material_code
        FROM spools
        WHERE creality_filament_id IS NULL
          AND status != 'retired'
        """
    ).fetchall()
    touched = 0
    for spool in rows:
        match = match_creality_filament(con, spool["cfs_material_code"], spool["material"])
        if not match:
            continue
        con.execute(
            """
            UPDATE spools
            SET creality_filament_id = ?,
                creality_brand = ?,
                creality_type = ?,
                creality_name = ?,
                updated_at = ?
            WHERE id = ?
            """,
            (match["id"], match["brand"], match["type"], match["name"], now_iso(), spool["id"]),
        )
        touched += 1
    return touched


def refresh_creality_filaments() -> int:
    with connect() as con:
        return import_creality_filaments(con)


def apply_creality_mapping(data: dict, existing: dict | None = None) -> dict:
    base = existing or {}
    requested_id = data.get("creality_filament_id", base.get("creality_filament_id"))
    cfs_material_code = clean_text(data.get("cfs_material_code", base.get("cfs_material_code", "")))
    cfs_color_code = clean_text(data.get("cfs_color_code", base.get("cfs_color_code", "")))
    with connect() as con:
        selected = creality_filament_by_id(con, requested_id)
        has_explicit_profile_fields = any(
            clean_text(data.get(key, ""))
            for key in ("creality_brand", "creality_type", "creality_name")
        )
        if not selected and has_explicit_profile_fields:
            row = con.execute(
                """
                SELECT * FROM creality_filaments
                WHERE brand = ?
                  AND type = ?
                  AND name = ?
                ORDER BY CASE WHEN cfs_material_code IS NOT NULL THEN 0 ELSE 1 END, id
                LIMIT 1
                """,
                (
                    clean_text(data.get("creality_brand", base.get("creality_brand", ""))),
                    clean_text(data.get("creality_type", base.get("creality_type", ""))),
                    clean_text(data.get("creality_name", base.get("creality_name", ""))),
                ),
            ).fetchone()
            if row:
                selected = row_to_dict(row)
        if not selected and cfs_material_code:
            selected = match_creality_filament(
                con,
                cfs_material_code,
                data.get("material", base.get("material", "")),
            )
    return {
        "creality_filament_id": selected["id"] if selected else None,
        "creality_brand": selected["brand"] if selected else clean_text(data.get("creality_brand", base.get("creality_brand", ""))) or None,
        "creality_type": selected["type"] if selected else clean_text(data.get("creality_type", base.get("creality_type", ""))) or None,
        "creality_name": selected["name"] if selected else clean_text(data.get("creality_name", base.get("creality_name", ""))) or None,
        "cfs_material_code": cfs_material_code or None,
        "cfs_color_code": cfs_color_code or None,
    }


def clean_int(value, fallback: int, minimum: int = 0) -> int:
    try:
        return max(minimum, int(value))
    except (TypeError, ValueError):
        return fallback


def clean_text(value, fallback: str = "") -> str:
    if value is None:
        return fallback
    return str(value).strip()


def clean_barcode(value) -> str:
    text = clean_text(value)
    if not text:
        return ""
    return "".join(ch for ch in text if ch.isalnum() or ch in "-_.")[:128]


def location_is_kind(location_id: int | None, kind: str) -> bool:
    if not location_id:
        return False
    with connect() as con:
        row = con.execute(
            "SELECT 1 FROM locations WHERE id = ? AND kind = ?",
            (location_id, kind),
        ).fetchone()
    return row is not None


def normalize_spool_payload(data: dict, existing: dict | None = None) -> dict:
    base = existing or {}
    original = clean_int(
        data.get("original_weight_g", base.get("original_weight_g", 1000)), 1000
    )
    remaining = clean_int(
        data.get("remaining_weight_g", base.get("remaining_weight_g", original)),
        original,
    )
    location_id = data.get("location_id", base.get("location_id"))
    if location_id in ("", None):
        location_id = None
    else:
        location_id = clean_int(location_id, 0)

    status = clean_text(data.get("status", base.get("status", "sealed")), "sealed")
    if status not in {"sealed", "open", "loaded", "retired"}:
        status = "sealed"
    if location_id and location_is_kind(location_id, "cfs"):
        status = "loaded"
    elif status == "loaded":
        status = "open"

    opened_at = clean_text(data.get("opened_at", base.get("opened_at") or ""))
    if status in {"open", "loaded"} and not opened_at:
        opened_at = datetime.now().date().isoformat()
    creality_mapping = apply_creality_mapping(data, base)

    return {
        "barcode": clean_barcode(data.get("barcode", base.get("barcode", ""))) or None,
        "material": clean_text(data.get("material", base.get("material", ""))).upper(),
        "brand": clean_text(data.get("brand", base.get("brand", ""))),
        "color_name": clean_text(data.get("color_name", base.get("color_name", ""))),
        "color_hex": clean_text(data.get("color_hex", base.get("color_hex", "#888888")), "#888888"),
        "diameter": clean_text(data.get("diameter", base.get("diameter", "1.75mm")), "1.75mm"),
        "original_weight_g": original,
        "remaining_weight_g": min(remaining, original),
        "status": status,
        "location_id": location_id,
        "purchased_at": clean_text(data.get("purchased_at", base.get("purchased_at") or "")) or None,
        "opened_at": opened_at or None,
        "notes": clean_text(data.get("notes", base.get("notes", ""))),
        **creality_mapping,
    }


def dehumidifier_location_id(con: sqlite3.Connection) -> int | None:
    row = con.execute(
        "SELECT id FROM locations WHERE name = 'Dehumidifier' LIMIT 1"
    ).fetchone()
    if row:
        return row["id"]
    row = con.execute(
        "SELECT id FROM locations WHERE kind = 'dryer' ORDER BY sort_order, id LIMIT 1"
    ).fetchone()
    return row["id"] if row else None


def enforce_single_loaded_spool(
    con: sqlite3.Connection,
    location_id: int | None,
    loaded_spool_id: int,
) -> None:
    if not location_id:
        return
    location = con.execute(
        "SELECT * FROM locations WHERE id = ?",
        (location_id,),
    ).fetchone()
    if not location or location["kind"] != "cfs":
        return
    con.execute(
        """
        UPDATE spools
        SET status = 'open',
            location_id = ?,
            cfs_slot_name = NULL,
            opened_at = COALESCE(opened_at, ?),
            updated_at = ?
        WHERE status = 'loaded'
          AND location_id = ?
          AND id != ?
        """,
        (
            dehumidifier_location_id(con),
            datetime.now().date().isoformat(),
            now_iso(),
            location_id,
            loaded_spool_id,
        ),
    )


def lookup_barcode(barcode: str) -> dict:
    barcode = clean_barcode(barcode)
    if not barcode:
        raise ValueError("Barcode is required.")
    with connect() as con:
        spools = [
            row_to_dict(row)
            for row in con.execute(
                """
                SELECT
                    s.*,
                    l.name AS location_name,
                    l.kind AS location_kind
                FROM spools s
                LEFT JOIN locations l ON l.id = s.location_id
                WHERE s.barcode = ?
                ORDER BY
                    CASE s.status
                        WHEN 'loaded' THEN 1
                        WHEN 'open' THEN 2
                        WHEN 'sealed' THEN 3
                        ELSE 4
                    END,
                    s.updated_at DESC
                LIMIT 10
                """,
                (barcode,),
            ).fetchall()
        ]
    return {
        "barcode": barcode,
        "spools": spools,
        "catalog": [],
        "total_catalog": 0,
    }


def normalize_printer_base_url(value: str) -> str:
    url = clean_text(value)
    if not url:
        raise ValueError("Printer address is required.")
    if not url.startswith(("http://", "https://")):
        url = "http://" + url
    parsed = urlparse(url)
    if not parsed.netloc:
        raise ValueError("Printer address is not valid.")
    return url.rstrip("/")


def printer_get(base_url: str, path: str) -> dict:
    request = Request(
        base_url + path,
        headers={"Accept": "application/json", "User-Agent": "FilamentInventory/1.0"},
    )
    try:
        with urlopen(request, timeout=4) as response:
            return json.loads(response.read().decode("utf-8"))
    except URLError as exc:
        raise ValueError(f"Could not reach printer: {exc.reason}") from exc
    except TimeoutError as exc:
        raise ValueError("Could not reach printer before the request timed out.") from exc
    except json.JSONDecodeError as exc:
        raise ValueError("Printer answered, but not with JSON data.") from exc


def printer_api_looks_valid(payload: dict) -> bool:
    result = moonraker_result(payload)
    objects = result.get("objects", result if isinstance(result, list) else [])
    if not isinstance(objects, list):
        return False
    required = {"print_stats", "virtual_sdcard", "box"}
    return len(required.intersection(objects)) >= 2


def find_printer_replacement(base_url: str) -> str | None:
    parsed = urlparse(base_url)
    host = parsed.hostname or ""
    port = parsed.port or 4408
    try:
        network = ipaddress.ip_network(f"{host}/24", strict=False)
    except ValueError:
        return None

    candidates = [str(ip) for ip in network.hosts() if str(ip) != host]

    def probe(ip: str) -> str | None:
        candidate = f"{parsed.scheme or 'http'}://{ip}:{port}"
        request = Request(
            candidate + "/printer/objects/list",
            headers={"Accept": "application/json", "User-Agent": "FilamentInventory/1.0"},
        )
        try:
            with urlopen(request, timeout=0.45) as response:
                payload = json.loads(response.read().decode("utf-8"))
            if printer_api_looks_valid(payload):
                return candidate
        except (OSError, TimeoutError, URLError, json.JSONDecodeError):
            return None
        return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=48) as executor:
        for replacement in executor.map(probe, candidates):
            if replacement:
                return replacement
    return None


def moonraker_result(payload: dict):
    return payload.get("result", payload)


def discover_printer(base_url: str) -> dict:
    info = {}
    objects = []
    try:
        info = moonraker_result(printer_get(base_url, "/printer/info"))
    except ValueError:
        info = {}

    listed = moonraker_result(printer_get(base_url, "/printer/objects/list"))
    objects = listed.get("objects", listed if isinstance(listed, list) else [])
    cfs_candidates = [
        obj
        for obj in objects
        if any(token in obj.lower() for token in ("box", "cfs", "ams", "filament"))
    ]
    return {
        "base_url": base_url,
        "printer": info,
        "object_count": len(objects),
        "cfs_candidates": cfs_candidates,
    }


def extract_slots(value) -> list:
    if isinstance(value, list):
        return value
    if not isinstance(value, dict):
        return []
    if any(key in value for key in ("T1", "T2", "T3", "T4")):
        material_lookup = {}
        for item in value.get("same_material", []):
            if isinstance(item, list) and len(item) >= 4:
                code = str(item[0])
                color = str(item[1])
                material = str(item[3])
                for slot_name in item[2] if isinstance(item[2], list) else []:
                    material_lookup[str(slot_name)] = {
                        "material": material,
                        "color_hex": normalize_color(color),
                        "cfs_material_code": code,
                        "cfs_color_code": color,
                    }
                material_lookup[code] = {
                    "material": material,
                    "color_hex": normalize_color(color),
                    "cfs_material_code": code,
                    "cfs_color_code": color,
                }

        slots = []
        for tray_index in range(1, 5):
            tray_name = f"T{tray_index}"
            tray = value.get(tray_name)
            if not isinstance(tray, dict) or tray.get("state") != "connect":
                continue
            colors = tray.get("color_value", [])
            materials = tray.get("material_type", [])
            remaining = tray.get("remain_len", [])
            vendors = tray.get("vender", [])
            for slot_index, letter in enumerate(("A", "B", "C", "D")):
                slot_name = f"{tray_name}{letter}"
                color = colors[slot_index] if slot_index < len(colors) else "-1"
                material_code = materials[slot_index] if slot_index < len(materials) else "-1"
                remain = remaining[slot_index] if slot_index < len(remaining) else "100"
                vendor = vendors[slot_index] if slot_index < len(vendors) else ""
                if str(color) == "-1" or str(material_code) == "-1":
                    continue
                mapped = material_lookup.get(slot_name) or material_lookup.get(str(material_code)) or {}
                material = mapped.get("material") or str(material_code)
                percent = clean_int(remain, 100, 0)
                slots.append(
                    {
                        "slot_name": slot_name,
                        "slot_index": ((tray_index - 1) * 4) + slot_index,
                        "brand": "Creality RFID" if vendor and vendor != "unknown" else "CFS",
                        "material": material,
                        "color_name": f"{slot_name} {material}",
                        "color_hex": normalize_color(mapped.get("color_hex") or color),
                        "cfs_material_code": clean_text(mapped.get("cfs_material_code") or material_code),
                        "cfs_color_code": clean_text(mapped.get("cfs_color_code") or color),
                        "remaining_weight_g": min(1000, percent * 10),
                        "original_weight_g": 1000,
                        "occupied": True,
                        "temperature": tray.get("temperature"),
                        "humidity": tray.get("dry_and_humidity"),
                    }
                )
        return slots
    for key in (
        "slots",
        "slot",
        "filaments",
        "materials",
        "box_info",
        "boxInfo",
        "cfs",
        "boxes",
    ):
        nested = value.get(key)
        slots = extract_slots(nested)
        if slots:
            return slots
    numeric_items = [
        (key, item)
        for key, item in value.items()
        if str(key).isdigit() and isinstance(item, dict)
    ]
    if numeric_items:
        return [item for _, item in sorted(numeric_items, key=lambda pair: int(pair[0]))]
    return []


def first_present(data: dict, keys: tuple[str, ...], fallback=None):
    for key in keys:
        if key in data and data[key] not in (None, ""):
            return data[key]
    return fallback


def normalize_color(value) -> str:
    if isinstance(value, str):
        color = value.strip()
        if len(color) == 6 and all(ch in "0123456789abcdefABCDEF" for ch in color):
            return "#" + color
        if len(color) == 7 and all(ch in "0123456789abcdefABCDEF" for ch in color):
            return "#" + color[-6:]
        if len(color) == 7 and color.startswith("#"):
            return color
        if len(color) == 8 and color.startswith("#"):
            return "#" + color[-6:]
    if isinstance(value, (list, tuple)) and len(value) >= 3:
        return "#{:02x}{:02x}{:02x}".format(
            clean_int(value[0], 128, 0),
            clean_int(value[1], 128, 0),
            clean_int(value[2], 128, 0),
        )
    return "#888888"


def color_name_for_hex(value) -> str:
    normalized = normalize_color(value).lower()
    for name, hex_value in STANDARD_COLOR_OPTIONS:
        if hex_value.lower() == normalized:
            return name
    try:
        red = int(normalized[1:3], 16)
        green = int(normalized[3:5], 16)
        blue = int(normalized[5:7], 16)
    except (TypeError, ValueError):
        return "Gray"
    nearest = min(
        STANDARD_COLOR_OPTIONS,
        key=lambda option: (
            red - int(option[1][1:3], 16)
        ) ** 2
        + (
            green - int(option[1][3:5], 16)
        ) ** 2
        + (
            blue - int(option[1][5:7], 16)
        ) ** 2,
    )
    return nearest[0]


def same_filament(left: sqlite3.Row | dict, right: dict) -> bool:
    return (
        material_matches(left["material"], right["material"])
        and clean_text(left["color_hex"]).lower() == clean_text(right["color_hex"]).lower()
    )


def slot_profile(con: sqlite3.Connection, slot: dict) -> dict | None:
    return match_creality_filament(
        con,
        slot.get("cfs_material_code", ""),
        slot.get("material", ""),
    )


def spool_matches_profile(spool: sqlite3.Row | dict, profile: dict | None, slot: dict) -> bool:
    if not spool:
        return False
    if not profile:
        return False
    slot_color = clean_text(slot["color_hex"]).lower()
    spool_color = clean_text(spool["color_hex"]).lower()
    spool_cfs_color = clean_text(spool["cfs_color_code"])
    slot_cfs_color = clean_text(slot.get("cfs_color_code", ""))
    color_matches = spool_color == slot_color
    if not color_matches and spool_cfs_color:
        color_matches = spool_cfs_color.lower() == slot_cfs_color.lower()
    if not color_matches and not spool_cfs_color:
        profile_label = f"{profile.get('type', '')} {profile.get('name', '')}".upper()
        color_name = clean_text(spool["color_name"]).lower()
        color_matches = color_name == color_name_for_hex(slot_color).lower()
        if not color_matches and "WOOD" in profile_label:
            color_matches = color_name in {"wood", "brown", "beige", "natural"}
    if not color_matches:
        return False
    if clean_int(spool["creality_filament_id"], 0) == clean_int(profile["id"], 0):
        return True
    return (
        clean_text(spool["creality_brand"]).lower() == clean_text(profile["brand"]).lower()
        and clean_text(spool["creality_type"]).lower() == clean_text(profile["type"]).lower()
        and clean_text(spool["creality_name"]).lower() == clean_text(profile["name"]).lower()
    )


def find_spool_for_slot(
    con: sqlite3.Connection,
    slot: dict,
    profile: dict | None,
    location_id: int,
) -> sqlite3.Row | None:
    if not profile:
        return None
    candidates = con.execute(
        """
        SELECT * FROM spools
        WHERE status IN ('open', 'sealed', 'loaded')
          AND LOWER(color_hex) = LOWER(?)
          AND id NOT IN (
            SELECT id FROM spools
            WHERE status = 'loaded' AND location_id = ?
          )
        ORDER BY
          CASE status WHEN 'open' THEN 0 WHEN 'sealed' THEN 1 ELSE 2 END,
          remaining_weight_g,
          id
        """,
        (slot["color_hex"], location_id),
    ).fetchall()
    return next((spool for spool in candidates if spool_matches_profile(spool, profile, slot)), None)


def normalize_slot(slot: dict, index: int) -> dict | None:
    if not isinstance(slot, dict):
        return None
    occupied = first_present(
        slot,
        ("occupied", "has_filament", "hasFilament", "is_exist", "material_exist", "empty"),
    )
    if occupied is False or occupied == 0 or occupied == "0":
        return None
    if occupied is True:
        pass
    elif str(occupied).lower() in {"false", "empty", "none"}:
        return None

    material = clean_text(
        first_present(slot, ("material", "type", "filament_type", "filamentType", "name"), "PLA")
    ).upper()
    brand = clean_text(first_present(slot, ("brand", "vendor", "manufacturer"), "CFS"))
    color_name = clean_text(
        first_present(slot, ("color_name", "colorName", "filament_name", "filamentName"), "")
    )
    color_hex = normalize_color(first_present(slot, ("color", "color_hex", "colorHex", "rgb")))
    if not color_name:
        color_name = color_name_for_hex(color_hex)
    weight = clean_int(
        first_present(
            slot,
            ("remain", "remaining", "remaining_weight", "remainingWeight", "weight", "tray_weight"),
            1000,
        ),
        1000,
    )
    if weight <= 100:
        weight = 1000
    return {
        "material": material or "PLA",
        "brand": brand or "CFS",
        "color_name": color_name,
        "color_hex": color_hex,
        "original_weight_g": 1000,
        "remaining_weight_g": min(weight, 1000),
        "diameter": "1.75mm",
        "status": "loaded",
        "slot_index": clean_int(slot.get("slot_index"), index),
        "cfs_material_code": clean_text(first_present(slot, ("cfs_material_code", "material_code", "materialCode"), "")),
        "cfs_color_code": clean_text(first_present(slot, ("cfs_color_code", "color_code", "colorCode"), "")),
        "raw": slot,
    }


def fetch_cfs_slots(base_url: str) -> tuple[list[dict], dict]:
    candidates = ["box", "cfs", "filament_box", "filament"]
    last_payload = {}
    for candidate in candidates:
        payload = moonraker_result(
            printer_get(base_url, f"/printer/objects/query?{candidate}")
        )
        last_payload = payload
        status = payload.get("status", payload)
        data = status.get(candidate, status) if isinstance(status, dict) else status
        slots = [slot for slot in extract_slots(data)]
        normalized = []
        for index, slot in enumerate(slots):
            normalized_slot = normalize_slot(slot, index)
            if normalized_slot:
                normalized.append(normalized_slot)
        if normalized:
            return normalized, {"object": candidate, "raw": data}
    return [], {"object": None, "raw": last_payload}


def normalize_external_slot(value: dict) -> dict | None:
    if not isinstance(value, dict):
        return None
    material_code = clean_text(value.get("material_type"))
    color_code = clean_text(value.get("color_value"))
    if material_code in {"", "-1"} or color_code in {"", "-1"}:
        return None
    color_hex = normalize_color(color_code)
    return {
        "material": material_code,
        "brand": "External Spool Holder",
        "color_name": color_name_for_hex(color_hex),
        "color_hex": color_hex,
        "original_weight_g": 1000,
        "remaining_weight_g": 1000,
        "diameter": "1.75mm",
        "status": "loaded",
        "slot_index": None,
        "location_name": "External Spool Holder",
        "cfs_material_code": material_code,
        "cfs_color_code": color_code,
        "raw": {"slot_name": "External", **value},
    }


def fetch_printer_slots(base_url: str) -> tuple[list[dict], dict]:
    cfs_slots, source = fetch_cfs_slots(base_url)
    external_slot = None
    external_raw = {}
    try:
        payload = moonraker_result(
            printer_get(base_url, "/printer/objects/query?filament_rack")
        )
        status = payload.get("status", payload)
        external_raw = status.get("filament_rack", status) if isinstance(status, dict) else {}
        external_slot = normalize_external_slot(external_raw)
    except ValueError:
        external_raw = {}
    slots = list(cfs_slots)
    if external_slot:
        slots.append(external_slot)
    return slots, {"object": "box+filament_rack" if external_slot else source["object"], "raw": {"cfs": source["raw"], "external": external_raw}}


def upsert_synced_slots(slots: list[dict]) -> int:
    with connect() as con:
        cfs_locations = con.execute(
            """
            SELECT * FROM locations
            WHERE kind = 'cfs' AND name LIKE 'CFS Slot %'
            ORDER BY sort_order, name
            """
        ).fetchall()
        dehumidifier_id = dehumidifier_location_id(con)
        seen_location_ids = set()
        touched = 0
        unmatched_slots = []
        for slot in slots:
            if slot.get("location_name"):
                location = con.execute(
                    "SELECT * FROM locations WHERE name = ? LIMIT 1",
                    (slot["location_name"],),
                ).fetchone()
                if not location:
                    continue
                location_id = location["id"]
            elif slot["slot_index"] >= len(cfs_locations):
                continue
            else:
                location_id = cfs_locations[slot["slot_index"]]["id"]
            seen_location_ids.add(location_id)
            note = "Synced from printer slot."
            currently_loaded = con.execute(
                """
                SELECT * FROM spools
                WHERE location_id = ? AND status = 'loaded'
                LIMIT 1
                """,
                (location_id,),
            ).fetchone()
            profile = slot_profile(con, slot)
            if profile:
                slot = {
                    **slot,
                    "material": profile["type"],
                    "brand": profile["brand"],
                    "color_name": slot["color_name"] or color_name_for_hex(slot["color_hex"]),
                    "creality_filament_id": profile["id"],
                    "creality_brand": profile["brand"],
                    "creality_type": profile["type"],
                    "creality_name": profile["name"],
                }
            payload = normalize_spool_payload({**slot, "location_id": location_id, "notes": note})

            # A user-loaded spool is the stronger source of truth for inventory identity.
            # Printer generic/RFID data can name the slot, but it must not replace the
            # physical spool the user already put there.
            existing = currently_loaded
            if not existing:
                existing = find_spool_for_slot(con, payload, profile, location_id)

            if existing:
                remaining_weight = existing["remaining_weight_g"]
                original_weight = existing["original_weight_g"]
                material = existing["material"]
                brand = existing["brand"]
                color_name = existing["color_name"]
                color_hex = existing["color_hex"]
                con.execute(
                    """
                    UPDATE spools
                    SET material = ?, brand = ?, color_name = ?, color_hex = ?,
                        diameter = ?, original_weight_g = ?, remaining_weight_g = ?,
                        status = 'loaded', location_id = ?, cfs_slot_name = ?,
                        notes = ?, opened_at = COALESCE(opened_at, ?),
                        creality_filament_id = COALESCE(?, creality_filament_id),
                        creality_brand = COALESCE(?, creality_brand),
                        creality_type = COALESCE(?, creality_type),
                        creality_name = COALESCE(?, creality_name),
                        cfs_material_code = COALESCE(?, cfs_material_code),
                        cfs_color_code = COALESCE(?, cfs_color_code),
                        updated_at = ?
                    WHERE id = ?
                    """,
                    (
                        material,
                        brand,
                        color_name,
                        color_hex,
                        payload["diameter"],
                        original_weight,
                        remaining_weight,
                        location_id,
                        slot.get("raw", {}).get("slot_name") or (
                            f"Slot {slot['slot_index'] + 1}" if slot.get("slot_index") is not None else slot.get("location_name", "External")
                        ),
                        payload["notes"],
                        datetime.now().date().isoformat(),
                        payload["creality_filament_id"],
                        payload["creality_brand"],
                        payload["creality_type"],
                        payload["creality_name"],
                        payload["cfs_material_code"],
                        payload["cfs_color_code"],
                        now_iso(),
                        existing["id"],
                    ),
                )
                enforce_single_loaded_spool(con, location_id, existing["id"])
            else:
                unmatched_slots.append(
                    slot.get("raw", {}).get("slot_name")
                    or (
                        f"Slot {slot['slot_index'] + 1}"
                        if slot.get("slot_index") is not None
                        else slot.get("location_name", "External")
                    )
                )
            touched += 1

        if seen_location_ids:
            placeholders = ",".join("?" for _ in seen_location_ids)
            con.execute(
                f"""
                UPDATE spools
                SET status = 'open', location_id = ?, cfs_slot_name = NULL, updated_at = ?
                WHERE status = 'loaded'
                  AND location_id IN (
                    SELECT id FROM locations
                    WHERE (kind = 'cfs' AND name LIKE 'CFS Slot %')
                       OR name = 'External Spool Holder'
                  )
                  AND location_id NOT IN ({placeholders})
                """,
                (dehumidifier_id, now_iso(), *seen_location_ids),
            )
        if unmatched_slots:
            set_setting(
                "slot_sync_last_message",
                f"Printer sync found unmatched slot(s): {', '.join(unmatched_slots)}. No spools were auto-created.",
            )
    return touched


def clean_float(value, fallback: float = 0.0) -> float:
    try:
        if value in (None, ""):
            return fallback
        return float(value)
    except (TypeError, ValueError):
        return fallback


def density_for_material(material: str) -> float:
    text = clean_text(material).upper()
    for key, density in MATERIAL_DENSITY.items():
        if key in text:
            return density
    return 1.24


def diameter_to_mm(value: str) -> float:
    text = clean_text(value, "1.75").lower().replace("mm", "")
    return clean_float(text, 1.75)


def filament_mm_to_grams(length_mm: float, material: str, diameter: str = "1.75mm") -> float:
    diameter_mm = diameter_to_mm(diameter)
    area_mm2 = math.pi * (diameter_mm / 2) ** 2
    volume_cm3 = (max(0.0, length_mm) * area_mm2) / 1000
    return volume_cm3 * density_for_material(material)


def normalize_hex(value: str) -> str:
    return normalize_color(value).lower()


def color_distance(left: str, right: str) -> int:
    left = normalize_hex(left).lstrip("#")
    right = normalize_hex(right).lstrip("#")
    try:
        return sum(
            abs(int(left[index : index + 2], 16) - int(right[index : index + 2], 16))
            for index in (0, 2, 4)
        )
    except ValueError:
        return 999


def material_matches(left: str, right: str) -> bool:
    left = normalize_material_label(left)
    right = normalize_material_label(right)
    if not left or not right:
        return False
    return left in right or right in left or left.split()[0] == right.split()[0]


def normalize_material_label(value: str) -> str:
    return re.sub(r"[^A-Z0-9]+", " ", clean_text(value).upper()).strip()


def printer_usage_payload(base_url: str) -> dict:
    try:
        payload = moonraker_result(
            printer_get(base_url, "/printer/objects/query?box&print_stats&virtual_sdcard")
        )
        status = payload.get("status", payload)
        if isinstance(status, dict) and ("print_stats" in status or "virtual_sdcard" in status):
            return status
    except ValueError:
        pass

    print_stats = moonraker_result(printer_get(base_url, "/printer/objects/query?print_stats"))
    virtual_sdcard = moonraker_result(printer_get(base_url, "/printer/objects/query?virtual_sdcard"))
    box = moonraker_result(printer_get(base_url, "/printer/objects/query?box"))
    return {
        "box": box.get("status", box).get("box", {}),
        "print_stats": print_stats.get("status", print_stats).get("print_stats", {}),
        "virtual_sdcard": virtual_sdcard.get("status", virtual_sdcard).get("virtual_sdcard", {}),
    }


def list_float_values(value) -> list[float]:
    if not isinstance(value, list):
        return []
    return [max(0.0, clean_float(item, 0.0)) for item in value]


def active_cfs_slot_name_from_box(box: dict) -> str:
    if not isinstance(box, dict):
        return ""
    for tray_index in range(1, 5):
        tray_name = f"T{tray_index}"
        tray = box.get(tray_name)
        if not isinstance(tray, dict) or tray.get("state") != "connect":
            continue
        filament = clean_text(tray.get("filament")).upper()
        if filament in {"A", "B", "C", "D"}:
            return f"{tray_name}{filament}"
    filament_index = box.get("filament")
    if isinstance(filament_index, int) and 0 <= filament_index <= 3:
        return f"T1{'ABCD'[filament_index]}"
    return ""


def cfs_location_name_for_slot(slot_name: str) -> str:
    match = re.match(r"^T(\d+)([A-D])$", clean_text(slot_name).upper())
    if not match:
        return ""
    tray_index = clean_int(match.group(1), 1, 1)
    letter_index = "ABCD".index(match.group(2))
    return f"CFS Slot {((tray_index - 1) * 4) + letter_index + 1}"


def fetch_printer_usage_snapshot(base_url: str) -> dict:
    status = printer_usage_payload(base_url)
    print_stats = status.get("print_stats") or {}
    virtual_sdcard = status.get("virtual_sdcard") or {}
    box = status.get("box") or {}
    current_print = virtual_sdcard.get("cur_print_data") or {}
    metadata = current_print.get("metadata") or {}
    model_info = metadata.get("model_info") or {}

    filename = (
        clean_text(print_stats.get("filename"))
        or clean_text(current_print.get("filename"))
        or Path(clean_text(virtual_sdcard.get("file_path"))).name
    )
    current_print_status = clean_text(current_print.get("status"))
    state = current_print_status if current_print_status in {"completed", "cancelled", "error"} else clean_text(
        print_stats.get("state") or current_print_status
    )
    start_time = clean_text(current_print.get("start_time") or metadata.get("uuid"))
    material = clean_text(
        metadata.get("filament_type") or model_info.get("MaterialType") or print_stats.get("filament_type")
    ).upper()
    material_values = [item.strip().upper() for item in re.split(r"[;,]", material) if item.strip()]
    progress = clean_float(virtual_sdcard.get("progress"), 0.0)
    progress = max(0.0, min(progress, 1.0))
    planned_grams = list_float_values(metadata.get("filament_used_g"))
    planned_total_g = sum(planned_grams)
    filament_used_mm = clean_float(
        print_stats.get("filament_used") or current_print.get("filament_used"),
        0.0,
    )

    if planned_total_g > 0 and state == "completed":
        used_grams = planned_total_g
        basis = "completed slicer estimate"
    elif planned_total_g > 0 and progress > 0:
        used_grams = planned_total_g * progress
        basis = "slicer progress"
    else:
        used_grams = filament_mm_to_grams(filament_used_mm, material or "PLA")
        basis = "extrusion length"

    colors = metadata.get("default_filament_colour")
    if not isinstance(colors, list):
        colors = []
    parts = []
    for index, grams in enumerate(planned_grams):
        if grams <= 0:
            continue
        parts.append(
            {
                "index": index,
                "planned_g": grams,
                "material": material_values[index] if index < len(material_values) else material,
                "color_hex": normalize_color(colors[index]) if index < len(colors) and colors[index] else "",
            }
        )
    if not parts:
        parts = [{"index": 0, "planned_g": max(planned_total_g, 1.0), "material": material, "color_hex": ""}]

    signature = f"{filename}|{start_time}" if filename else ""
    return {
        "filename": filename,
        "signature": signature,
        "state": state,
        "progress": progress,
        "material": material,
        "planned_total_g": planned_total_g,
        "used_grams": max(0.0, used_grams),
        "filament_used_mm": filament_used_mm,
        "basis": basis,
        "parts": parts,
        "active_cfs_slot_name": active_cfs_slot_name_from_box(box),
    }


def choose_spool_for_part(part: dict, loaded_spools: list[sqlite3.Row], used_ids: set[int]) -> sqlite3.Row | None:
    candidates = []
    material_candidates = []
    part_material = normalize_material_label(part.get("material", ""))
    for spool in loaded_spools:
        score = 0
        spool_material = normalize_material_label(spool["material"])
        if material_matches(part_material, spool_material):
            score += 100
            if part_material == spool_material:
                score += 40
            material_candidates.append(spool)
        else:
            continue
        if part.get("color_hex"):
            distance = color_distance(part["color_hex"], spool["color_hex"])
            if distance <= 120:
                score += max(0, 180 - distance)
            else:
                score -= min(140, distance // 3)
        if spool["id"] in used_ids:
            score -= 50
        if score > 0:
            candidates.append((score, spool))
    if not candidates:
        available_material_candidates = [
            spool for spool in material_candidates if spool["id"] not in used_ids and spool["remaining_weight_g"] > 0
        ]
        if len(available_material_candidates) == 1:
            return available_material_candidates[0]
        return None
    candidates.sort(key=lambda item: item[0], reverse=True)
    return candidates[0][1]


def allocate_usage_to_loaded_spools(snapshot: dict, grams: int) -> list[tuple[sqlite3.Row, int]]:
    if grams <= 0:
        return []
    with connect() as con:
        loaded_spools = con.execute(
            """
            SELECT s.*, l.name AS location_name
            FROM spools s
            LEFT JOIN locations l ON l.id = s.location_id
            WHERE s.status != 'retired'
              AND l.kind = 'cfs'
            ORDER BY l.sort_order, s.id
            """
        ).fetchall()
    if not loaded_spools:
        return []

    active_slot_name = clean_text(snapshot.get("active_cfs_slot_name")).upper()
    active_location_name = cfs_location_name_for_slot(active_slot_name)
    if active_slot_name or active_location_name:
        for spool in loaded_spools:
            if (
                clean_text(spool["cfs_slot_name"]).upper() == active_slot_name
                or clean_text(spool["location_name"]) == active_location_name
            ):
                if spool["remaining_weight_g"] > 0:
                    return [(spool, min(grams, max(0, spool["remaining_weight_g"])))]

    parts = snapshot["parts"]
    total_part_grams = sum(part["planned_g"] for part in parts) or 1.0
    used_ids = set()
    allocations_by_id: dict[int, tuple[sqlite3.Row, int]] = {}
    remaining = grams
    for index, part in enumerate(parts):
        spool = choose_spool_for_part(part, loaded_spools, used_ids)
        if not spool:
            continue
        used_ids.add(spool["id"])
        part_grams = (
            remaining
            if index == len(parts) - 1
            else max(0, round(grams * (part["planned_g"] / total_part_grams)))
        )
        remaining -= part_grams
        existing_spool, existing_grams = allocations_by_id.get(spool["id"], (spool, 0))
        allocations_by_id[spool["id"]] = (existing_spool, existing_grams + part_grams)
    return [
        (spool, min(amount, max(0, spool["remaining_weight_g"])))
        for spool, amount in allocations_by_id.values()
        if amount > 0 and spool["remaining_weight_g"] > 0
    ]


def active_usage_spool_ids(snapshot: dict) -> str:
    if snapshot.get("state") in {"completed", "cancelled", "error"}:
        return ""
    allocations = allocate_usage_to_loaded_spools(snapshot, 1)
    return ",".join(str(spool["id"]) for spool, _grams in allocations)


def planned_part_gram_targets(snapshot: dict) -> list[int]:
    parts = [part for part in snapshot.get("parts", []) if clean_float(part.get("planned_g"), 0.0) > 0]
    if not parts:
        return []
    target_total = max(0, round(sum(clean_float(part.get("planned_g"), 0.0) for part in parts)))
    targets = []
    remaining = target_total
    for index, part in enumerate(parts):
        grams = remaining if index == len(parts) - 1 else max(0, round(clean_float(part.get("planned_g"), 0.0)))
        targets.append(grams)
        remaining -= grams
    return targets


def reconcile_completed_multicolor_usage(snapshot: dict) -> dict | None:
    if snapshot.get("state") != "completed" or len(snapshot.get("parts", [])) < 2:
        return None
    if not snapshot.get("signature") or not snapshot.get("filename"):
        return None
    targets = sorted(planned_part_gram_targets(snapshot), reverse=True)
    if len(targets) < 2:
        return None

    signature_pattern = f"%Print signature: {snapshot['signature']}%"
    created = now_iso()
    with connect() as con:
        rows = con.execute(
            """
            SELECT spool_id, SUM(grams_used) AS grams_used
            FROM usage_events
            WHERE project = ?
              AND notes LIKE 'Auto printer tracking%'
              AND notes LIKE ?
            GROUP BY spool_id
            ORDER BY grams_used DESC, spool_id
            """,
            (snapshot["filename"], signature_pattern),
        ).fetchall()
        if len(rows) < 2:
            return None

        observed = rows[: len(targets)]
        changes = []
        for row, target in zip(observed, targets):
            current = clean_int(row["grams_used"], 0, 0)
            spool_id = row["spool_id"]
            delta = target - current
            if delta:
                con.execute(
                    """
                    UPDATE spools
                    SET remaining_weight_g = max(0, remaining_weight_g - ?), updated_at = ?
                    WHERE id = ?
                    """,
                    (delta, created, spool_id),
                )
            event = con.execute(
                """
                SELECT id FROM usage_events
                WHERE spool_id = ?
                  AND project = ?
                  AND notes LIKE 'Auto printer tracking%'
                  AND notes LIKE ?
                ORDER BY id DESC
                LIMIT 1
                """,
                (spool_id, snapshot["filename"], signature_pattern),
            ).fetchone()
            if event:
                con.execute(
                    """
                    UPDATE usage_events
                    SET grams_used = ?,
                        notes = CASE
                            WHEN notes LIKE '%Rebalanced to completed slicer split.%' THEN notes
                            ELSE notes || ' Rebalanced to completed slicer split.'
                        END,
                        created_at = ?
                    WHERE id = ?
                    """,
                    (target, created, event["id"]),
                )
            changes.append({"spool_id": spool_id, "grams": target, "previous_grams": current})

    message = f"Rebalanced completed multicolor print to slicer split ({', '.join(str(item) + 'g' for item in targets)})."
    set_settings(
        {
            "usage_monitor_used_grams": f"{snapshot['used_grams']:.4f}",
            "usage_monitor_residual_grams": "0",
            "usage_monitor_last_message": message,
            "usage_monitor_last_checked": created,
            "usage_monitor_active_spool_ids": "",
        }
    )
    return {"tracked": True, "deducted": 0, "rebalanced": True, "allocations": changes, "message": message, "snapshot": snapshot}


def apply_printer_usage_snapshot(snapshot: dict, reset: bool = False) -> dict:
    with USAGE_MONITOR_LOCK:
        if not snapshot["signature"]:
            set_settings(
                {
                    "usage_monitor_last_message": "No active or recent print found.",
                    "usage_monitor_active_spool_ids": "",
                }
            )
            return {"tracked": False, "deducted": 0, "message": "No active or recent print found.", "snapshot": snapshot}

        last_signature = get_setting("usage_monitor_signature")
        last_used_grams = clean_float(get_setting("usage_monitor_used_grams"), 0.0)
        residual_grams = clean_float(get_setting("usage_monitor_residual_grams"), 0.0)
        active_spool_ids = active_usage_spool_ids(snapshot)

        reconciliation = reconcile_completed_multicolor_usage(snapshot)
        if reconciliation:
            return reconciliation

        if reset or snapshot["signature"] != last_signature:
            set_settings(
                {
                    "usage_monitor_signature": snapshot["signature"],
                    "usage_monitor_used_grams": f"{snapshot['used_grams']:.4f}",
                    "usage_monitor_residual_grams": "0",
                    "usage_monitor_last_message": f"Baseline set for {snapshot['filename']}.",
                    "usage_monitor_last_checked": now_iso(),
                    "usage_monitor_active_spool_ids": active_spool_ids,
                }
            )
            return {
                "tracked": True,
                "baseline": True,
                "deducted": 0,
                "message": f"Baseline set for {snapshot['filename']}.",
                "snapshot": snapshot,
            }

        delta_grams = snapshot["used_grams"] - last_used_grams
        if delta_grams <= 0:
            set_settings(
                {
                    "usage_monitor_used_grams": f"{max(snapshot['used_grams'], last_used_grams):.4f}",
                    "usage_monitor_last_message": f"No new usage for {snapshot['filename']}.",
                    "usage_monitor_last_checked": now_iso(),
                    "usage_monitor_active_spool_ids": active_spool_ids,
                }
            )
            return {
                "tracked": True,
                "deducted": 0,
                "message": f"No new usage for {snapshot['filename']}.",
                "snapshot": snapshot,
            }

        available_grams = delta_grams + residual_grams
        whole_grams = int(available_grams)
        residual_grams = available_grams - whole_grams
        if whole_grams <= 0:
            set_settings(
                {
                    "usage_monitor_used_grams": f"{snapshot['used_grams']:.4f}",
                    "usage_monitor_residual_grams": f"{residual_grams:.4f}",
                    "usage_monitor_last_message": f"Accumulating usage for {snapshot['filename']}.",
                    "usage_monitor_last_checked": now_iso(),
                    "usage_monitor_active_spool_ids": active_spool_ids,
                }
            )
            return {
                "tracked": True,
                "deducted": 0,
                "pending_grams": residual_grams,
                "message": f"Accumulating usage for {snapshot['filename']}.",
                "snapshot": snapshot,
            }

        allocations = allocate_usage_to_loaded_spools(snapshot, whole_grams)
        if not allocations:
            set_settings(
                {
                    "usage_monitor_last_message": "No loaded CFS spool found to deduct from.",
                    "usage_monitor_active_spool_ids": active_spool_ids,
                }
            )
            return {
                "tracked": False,
                "deducted": 0,
                "message": "No loaded CFS spool found to deduct from.",
                "snapshot": snapshot,
            }

        created = now_iso()
        with connect() as con:
            for spool, grams in allocations:
                signature_note = (
                    f" Print signature: {snapshot['signature']}."
                    if snapshot.get("signature")
                    else ""
                )
                remaining = max(0, spool["remaining_weight_g"] - grams)
                status = "loaded" if remaining > 0 else "retired"
                con.execute(
                    """
                    UPDATE spools
                    SET remaining_weight_g = ?, status = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    (remaining, status, created, spool["id"]),
                )
                event_update = con.execute(
                    """
                    UPDATE usage_events
                    SET grams_used = grams_used + ?, created_at = ?
                    WHERE id = (
                        SELECT id FROM usage_events
                        WHERE spool_id = ?
                          AND project = ?
                          AND notes LIKE 'Auto printer tracking%'
                          AND notes LIKE ?
                        ORDER BY id DESC
                        LIMIT 1
                    )
                    """,
                    (
                        grams,
                        created,
                        spool["id"],
                        snapshot["filename"],
                        f"%Print signature: {snapshot['signature']}%",
                    ),
                )
                if event_update.rowcount == 0:
                    active_slot_note = (
                        f" Active CFS slot: {snapshot['active_cfs_slot_name']}."
                        if snapshot.get("active_cfs_slot_name")
                        else ""
                    )
                    con.execute(
                        """
                        INSERT INTO usage_events (spool_id, grams_used, project, notes, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        (
                            spool["id"],
                            grams,
                            snapshot["filename"],
                            f"Auto printer tracking from {snapshot['basis']} while print state was {snapshot['state'] or 'unknown'}.{active_slot_note}{signature_note}",
                            created,
                        ),
                    )

        message = f"Deducted {whole_grams}g from {len(allocations)} loaded spool(s)."
        set_settings(
            {
                "usage_monitor_signature": snapshot["signature"],
                "usage_monitor_used_grams": f"{snapshot['used_grams']:.4f}",
                "usage_monitor_residual_grams": f"{residual_grams:.4f}",
                "usage_monitor_last_message": message,
                "usage_monitor_last_checked": created,
                "usage_monitor_active_spool_ids": ",".join(str(spool["id"]) for spool, _grams in allocations),
            }
        )
        return {
            "tracked": True,
            "deducted": whole_grams,
            "allocations": [
                {
                    "spool_id": spool["id"],
                    "spool": f"{spool['brand']} {spool['color_name']}",
                    "grams": grams,
                }
                for spool, grams in allocations
            ],
            "pending_grams": residual_grams,
            "message": message,
            "snapshot": snapshot,
        }


def sync_printer_usage(base_url: str, reset: bool = False) -> dict:
    base_url = normalize_printer_base_url(base_url)
    try:
        snapshot = fetch_printer_usage_snapshot(base_url)
    except ValueError as exc:
        replacement = find_printer_replacement(base_url)
        if not replacement:
            raise
        set_setting("printer_base_url", replacement)
        snapshot = fetch_printer_usage_snapshot(replacement)
        set_setting(
            "usage_monitor_last_message",
            f"Printer moved from {base_url} to {replacement}; tracking resumed.",
        )
    return apply_printer_usage_snapshot(snapshot, reset)


def sync_printer_slots(base_url: str) -> dict:
    base_url = normalize_printer_base_url(base_url)
    try:
        slots, source = fetch_printer_slots(base_url)
    except ValueError:
        replacement = find_printer_replacement(base_url)
        if not replacement:
            raise
        set_setting("printer_base_url", replacement)
        slots, source = fetch_printer_slots(replacement)
        set_setting(
            "slot_sync_last_message",
            f"Printer moved from {base_url} to {replacement}; slot sync resumed.",
        )
    if not slots:
        set_settings(
            {
                "slot_sync_last_message": "Connected to the printer, but no populated CFS/external slots were reported.",
                "slot_sync_last_checked": now_iso(),
            }
        )
        return {"synced": 0, "source": source, "slots": []}
    touched = upsert_synced_slots(slots)
    set_settings(
        {
            "slot_sync_last_message": f"Synced {touched} printer slot{'s' if touched != 1 else ''}.",
            "slot_sync_last_checked": now_iso(),
        }
    )
    return {"synced": touched, "source": source, "slots": slots}


def usage_monitor_status() -> dict:
    base_url = get_setting("printer_base_url")
    return {
        "enabled": bool(base_url),
        "last_message": get_setting("usage_monitor_last_message"),
        "last_checked": get_setting("usage_monitor_last_checked"),
        "signature": get_setting("usage_monitor_signature"),
        "slot_sync_last_message": get_setting("slot_sync_last_message"),
        "slot_sync_last_checked": get_setting("slot_sync_last_checked"),
    }


def usage_monitor_loop() -> None:
    while True:
        try:
            base_url = get_setting("printer_base_url")
            if base_url:
                sync_printer_slots(base_url)
                sync_printer_usage(base_url)
        except Exception as exc:
            set_settings(
                {
                    "usage_monitor_last_message": f"Usage tracking failed: {exc}",
                    "usage_monitor_last_checked": now_iso(),
                }
            )
        time.sleep(USAGE_MONITOR_INTERVAL_SECONDS)


def ensure_usage_monitor() -> None:
    global USAGE_MONITOR_STARTED
    if USAGE_MONITOR_STARTED:
        return
    thread = threading.Thread(target=usage_monitor_loop, daemon=True)
    thread.start()
    USAGE_MONITOR_STARTED = True


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(STATIC_ROOT), **kwargs)

    def log_message(self, format: str, *args) -> None:
        return

    def send_json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/bootstrap":
            self.send_json(fetch_bootstrap())
            return
        if parsed.path == "/api/catalog/search":
            params = parse_qs(parsed.query)
            query = params.get("q", [""])[0]
            limit = params.get("limit", ["40"])[0]
            brand = params.get("brand", [""])[0]
            material = params.get("material", [""])[0]
            color = params.get("color", [""])[0]
            barcode = params.get("barcode", [""])[0]
            self.send_json(
                search_catalog(
                    query=query,
                    limit=clean_int(limit, 40, 1),
                    brand=brand,
                    material=material,
                    color=color,
                    barcode=barcode,
                )
            )
            return
        if parsed.path == "/api/catalog/options":
            params = parse_qs(parsed.query)
            self.send_json(
                catalog_options(
                    brand=params.get("brand", [""])[0],
                    material_type=params.get("type", [""])[0],
                )
            )
            return
        if parsed.path == "/api/barcode/lookup":
            params = parse_qs(parsed.query)
            self.send_json(lookup_barcode(params.get("code", [""])[0]))
            return
        if parsed.path == "/":
            self.path = "/index.html"
        return super().do_GET()

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        try:
            if parsed.path == "/api/printer/probe":
                data = self.read_json()
                base_url = normalize_printer_base_url(data.get("base_url", ""))
                with connect() as con:
                    con.execute(
                        """
                        INSERT OR REPLACE INTO settings (key, value)
                        VALUES ('printer_base_url', ?)
                        """,
                        (base_url,),
                    )
                self.send_json(discover_printer(base_url))
                return

            if parsed.path == "/api/printer/sync":
                data = self.read_json()
                base_url = normalize_printer_base_url(data.get("base_url", ""))
                set_setting("printer_base_url", base_url)
                result = sync_printer_slots(base_url)
                if not result["slots"]:
                    self.send_json(
                        {
                            "error": "Connected to the printer, but could not find populated CFS/external slot data.",
                            "source": result["source"],
                        },
                        422,
                    )
                    return
                self.send_json(
                    {
                        "synced": result["synced"],
                        "source": result["source"]["object"],
                        "slots": result["slots"],
                        **fetch_bootstrap(),
                    }
                )
                return

            if parsed.path == "/api/printer/usage/start":
                data = self.read_json()
                base_url = normalize_printer_base_url(data.get("base_url", ""))
                set_settings(
                    {
                        "printer_base_url": base_url,
                        "usage_monitor_enabled": "0",
                    }
                )
                result = sync_printer_usage(base_url, reset=True)
                set_setting("usage_monitor_enabled", "1")
                ensure_usage_monitor()
                self.send_json({**result, "monitor": usage_monitor_status(), **fetch_bootstrap()})
                return

            if parsed.path == "/api/printer/usage/stop":
                set_settings(
                    {
                        "usage_monitor_enabled": "0",
                        "usage_monitor_last_message": "Usage tracking stopped.",
                        "usage_monitor_last_checked": now_iso(),
                    }
                )
                self.send_json({"monitor": usage_monitor_status(), **fetch_bootstrap()})
                return

            if parsed.path == "/api/printer/usage/check":
                data = self.read_json()
                base_url = normalize_printer_base_url(
                    data.get("base_url") or get_setting("printer_base_url")
                )
                result = sync_printer_usage(base_url, reset=bool(data.get("reset")))
                self.send_json({**result, "monitor": usage_monitor_status(), **fetch_bootstrap()})
                return

            if parsed.path == "/api/printer/usage/snapshot":
                data = self.read_json()
                snapshot = data.get("snapshot") or {}
                if not isinstance(snapshot, dict):
                    raise ValueError("Printer usage snapshot is not valid.")
                if data.get("base_url"):
                    set_setting("printer_base_url", normalize_printer_base_url(data.get("base_url")))
                result = apply_printer_usage_snapshot(snapshot, reset=bool(data.get("reset")))
                if data.get("enable"):
                    set_setting("usage_monitor_enabled", "1")
                self.send_json({**result, "monitor": usage_monitor_status(), **fetch_bootstrap()})
                return

            if parsed.path == "/api/catalog/refresh":
                imported = refresh_creality_filaments()
                self.send_json({"imported": imported, **fetch_bootstrap()}, 201)
                return

            if parsed.path in {"/api/catalog/import", "/api/catalog/starter"}:
                self.send_json({"error": "Community catalog imports were removed in V2. Use the Creality Print profile catalog."}, 410)
                return

            if parsed.path == "/api/spools":
                data = normalize_spool_payload(self.read_json())
                required = ["material", "brand", "color_name"]
                if any(not data[key] for key in required):
                    self.send_json({"error": "Material, brand, and color are required."}, 400)
                    return
                created = now_iso()
                with connect() as con:
                    cur = con.execute(
                        """
                        INSERT INTO spools (
                            barcode, material, brand, color_name, color_hex, diameter,
                            original_weight_g, remaining_weight_g, status, location_id,
                            purchased_at, opened_at, notes, creality_filament_id,
                            creality_brand, creality_type, creality_name, cfs_material_code,
                            cfs_color_code, created_at, updated_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            data["barcode"],
                            data["material"],
                            data["brand"],
                            data["color_name"],
                            data["color_hex"],
                            data["diameter"],
                            data["original_weight_g"],
                            data["remaining_weight_g"],
                            data["status"],
                            data["location_id"],
                            data["purchased_at"],
                            data["opened_at"],
                            data["notes"],
                            data["creality_filament_id"],
                            data["creality_brand"],
                            data["creality_type"],
                            data["creality_name"],
                            data["cfs_material_code"],
                            data["cfs_color_code"],
                            created,
                            created,
                        ),
                    )
                    enforce_single_loaded_spool(con, data["location_id"], cur.lastrowid)
                self.send_json({"id": cur.lastrowid, **fetch_bootstrap()}, 201)
                return

            if parsed.path.startswith("/api/spools/") and parsed.path.endswith("/usage"):
                spool_id = int(parsed.path.split("/")[3])
                data = self.read_json()
                grams = clean_int(data.get("grams_used"), 0, 1)
                project = clean_text(data.get("project"))
                notes = clean_text(data.get("notes"))
                with connect() as con:
                    spool = con.execute(
                        "SELECT * FROM spools WHERE id = ?", (spool_id,)
                    ).fetchone()
                    if not spool:
                        self.send_json({"error": "Spool not found."}, 404)
                        return
                    remaining = max(0, spool["remaining_weight_g"] - grams)
                    status = "retired" if remaining == 0 else spool["status"]
                    con.execute(
                        """
                        UPDATE spools
                        SET remaining_weight_g = ?, status = ?, updated_at = ?
                        WHERE id = ?
                        """,
                        (remaining, status, now_iso(), spool_id),
                    )
                    con.execute(
                        """
                        INSERT INTO usage_events (spool_id, grams_used, project, notes, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        (spool_id, grams, project, notes, now_iso()),
                    )
                self.send_json(fetch_bootstrap(), 201)
                return
        except (json.JSONDecodeError, ValueError, sqlite3.Error) as exc:
            self.send_json({"error": str(exc)}, 400)
            return
        self.send_json({"error": "Not found."}, 404)

    def do_PUT(self) -> None:
        parsed = urlparse(self.path)
        try:
            if parsed.path.startswith("/api/spools/"):
                spool_id = int(parsed.path.split("/")[3])
                with connect() as con:
                    existing_row = con.execute(
                        "SELECT * FROM spools WHERE id = ?", (spool_id,)
                    ).fetchone()
                    if not existing_row:
                        self.send_json({"error": "Spool not found."}, 404)
                        return
                    data = normalize_spool_payload(
                        self.read_json(), row_to_dict(existing_row)
                    )
                    if not data["material"] or not data["brand"] or not data["color_name"]:
                        self.send_json({"error": "Material, brand, and color are required."}, 400)
                        return
                    con.execute(
                        """
                        UPDATE spools
                        SET barcode = ?, material = ?, brand = ?, color_name = ?, color_hex = ?,
                            diameter = ?, original_weight_g = ?, remaining_weight_g = ?,
                            status = ?, location_id = ?, purchased_at = ?, opened_at = ?,
                            notes = ?, creality_filament_id = ?, creality_brand = ?,
                            creality_type = ?, creality_name = ?, cfs_material_code = ?,
                            cfs_color_code = ?, updated_at = ?
                        WHERE id = ?
                        """,
                        (
                            data["barcode"],
                            data["material"],
                            data["brand"],
                            data["color_name"],
                            data["color_hex"],
                            data["diameter"],
                            data["original_weight_g"],
                            data["remaining_weight_g"],
                            data["status"],
                            data["location_id"],
                            data["purchased_at"],
                            data["opened_at"],
                            data["notes"],
                            data["creality_filament_id"],
                            data["creality_brand"],
                            data["creality_type"],
                            data["creality_name"],
                            data["cfs_material_code"],
                            data["cfs_color_code"],
                            now_iso(),
                            spool_id,
                        ),
                    )
                    enforce_single_loaded_spool(con, data["location_id"], spool_id)
                self.send_json(fetch_bootstrap())
                return
        except (json.JSONDecodeError, ValueError, sqlite3.Error) as exc:
            self.send_json({"error": str(exc)}, 400)
            return
        self.send_json({"error": "Not found."}, 404)

    def do_DELETE(self) -> None:
        parsed = urlparse(self.path)
        try:
            if parsed.path.startswith("/api/spools/"):
                spool_id = int(parsed.path.split("/")[3])
                with connect() as con:
                    existing_row = con.execute(
                        "SELECT * FROM spools WHERE id = ?", (spool_id,)
                    ).fetchone()
                    if not existing_row:
                        self.send_json({"error": "Spool not found."}, 404)
                        return
                    con.execute("DELETE FROM spools WHERE id = ?", (spool_id,))
                self.send_json(fetch_bootstrap())
                return
        except (ValueError, sqlite3.Error) as exc:
            self.send_json({"error": str(exc)}, 400)
            return
        self.send_json({"error": "Not found."}, 404)


def main() -> None:
    init_db()
    ensure_usage_monitor()
    server = None
    port = 8765
    for candidate in range(8765, 8776):
        try:
            server = ThreadingHTTPServer(("127.0.0.1", candidate), Handler)
            port = candidate
            break
        except OSError:
            continue
    if server is None:
        raise OSError("No available local preview port between 8765 and 8775.")
    print(f"Filament tracker running at http://127.0.0.1:{port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
