import hmac
import os
import secrets
import time
from datetime import datetime, timezone
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.middleware.sessions import SessionMiddleware

import db
from ai_gateway import call_model, parse_plan_steps, AIGatewayError, tokens_used_today
from db import get_conn, get_setting, set_setting

BASE_DIR = Path(__file__).parent
load_dotenv(BASE_DIR.parent / ".env")

db.init_db()

session_secret = get_setting("session_secret")
if not session_secret:
    session_secret = secrets.token_hex(32)
    set_setting("session_secret", session_secret)

ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def safe_int(value: str | None, default: int = 0) -> int:
    """Form-/Settings-Werte robust parsen: kein 500er bei 'abc'."""
    try:
        return int((value or "").strip() or default)
    except (TypeError, ValueError, AttributeError):
        return default


# Einfacher Login-Schutz im Speicher: max. 10 Fehlversuche pro IP,
# danach exponentiell wachsende Sperre (Single-User-Tool: kein Redis nötig).
_login_attempts: dict[str, dict] = {}


def _client_ip(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for")
    if fwd:
        return fwd.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _login_blocked(ip: str) -> int:
    """Gibt Rest-Sperrzeit in Sekunden zurück (0 = nicht gesperrt)."""
    entry = _login_attempts.get(ip)
    if not entry or entry.get("fails", 0) < 5:
        return 0
    wait = min(2 ** (entry["fails"] - 5) * 30, 900)  # 30s, 60s, 120s, ... max 15min
    elapsed = time.monotonic() - entry.get("last", 0)
    return max(0, int(wait - elapsed))


def _login_failed(ip: str) -> None:
    entry = _login_attempts.setdefault(ip, {"fails": 0, "last": 0})
    entry["fails"] += 1
    entry["last"] = time.monotonic()


def _login_ok(ip: str) -> None:
    _login_attempts.pop(ip, None)


async def auth_gate(request: Request, call_next):
    open_paths = {"/login", "/health", "/favicon.ico"}
    if request.url.path in open_paths or request.url.path.startswith("/static"):
        return await call_next(request)
    if not request.session.get("authed"):
        return RedirectResponse("/login", status_code=303)
    return await call_next(request)


app = FastAPI(title="growthOS")
# Reihenfolge ist wichtig: SessionMiddleware muss VOR (also als äußere Schicht
# um) auth_gate liegen, sonst ist request.session beim Auth-Check noch nicht
# verfügbar. Starlette wrapped in umgekehrter Reihenfolge des Hinzufügens,
# daher hier zuerst auth_gate, dann SessionMiddleware registrieren.
app.add_middleware(BaseHTTPMiddleware, dispatch=auth_gate)
app.add_middleware(SessionMiddleware, secret_key=session_secret)
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=BASE_DIR / "templates")


@app.get("/health")
async def health():
    return JSONResponse({"status": "ok"})


@app.get("/favicon.ico")
async def favicon():
    # Leere Antwort statt Redirect-Loop ins Login (Browser fragt das bei
    # jedem Seitenaufruf an, sonst unnötige 303s im Log).
    return JSONResponse({}, status_code=204)


@app.get("/login", response_class=HTMLResponse)
async def login_form(request: Request):
    if not ADMIN_PASSWORD:
        return HTMLResponse(
            "<h1>Kein ADMIN_PASSWORD gesetzt</h1>"
            "<p>Bitte ADMIN_PASSWORD in der .env-Datei setzen und den "
            "Dienst neu starten: <code>systemctl restart growthos</code></p>",
            status_code=500,
        )
    return templates.TemplateResponse(request, "login.html", {"error": None})


@app.post("/login")
async def login_submit(request: Request, password: str = Form(...)):
    if not ADMIN_PASSWORD:
        return HTMLResponse(
            "<h1>Kein ADMIN_PASSWORD gesetzt</h1>"
            "<p>Bitte ADMIN_PASSWORD in der .env-Datei setzen und den "
            "Dienst neu starten: <code>systemctl restart growthos</code></p>",
            status_code=500,
        )
    ip = _client_ip(request)
    blocked = _login_blocked(ip)
    if blocked > 0:
        return templates.TemplateResponse(
            request,
            "login.html",
            {"error": f"Zu viele Fehlversuche. Bitte in {blocked}s erneut versuchen."},
            status_code=429,
        )
    if hmac.compare_digest(password, ADMIN_PASSWORD):
        _login_ok(ip)
        request.session["authed"] = True
        return RedirectResponse("/", status_code=303)
    _login_failed(ip)
    return templates.TemplateResponse(
        request, "login.html", {"error": "Falsches Passwort."}, status_code=401
    )


@app.get("/logout")
async def logout(request: Request):
    request.session.clear()
    return RedirectResponse("/login", status_code=303)


def get_company() -> dict:
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM company WHERE id = 1").fetchone()
        return dict(row) if row else {}


def build_company_context() -> str:
    c = get_company()
    if not any(c.get(k) for k in ("product", "goal", "target_audience")):
        return "Kein Firmenprofil hinterlegt. Erstelle einen allgemein gehaltenen Plan " \
               "und weise darauf hin, dass ein ausgefülltes Firmenprofil bessere Ergebnisse liefert."
    return (
        f"Produkt/Dienstleistung: {c.get('product', '-')}\n"
        f"Ziel: {c.get('goal', '-')}\n"
        f"Aktueller Stand: {c.get('current_state', '-')}\n"
        f"Zielgruppe: {c.get('target_audience', '-')}\n"
        f"Wettbewerber: {c.get('competitors', '-')}\n"
        f"Tonalität/Branding: {c.get('tone', '-')}"
    )


def get_personas() -> list[dict]:
    with get_conn() as conn:
        rows = conn.execute("SELECT * FROM personas ORDER BY id").fetchall()
        return [dict(r) for r in rows]


@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request):
    with get_conn() as conn:
        plan_count = conn.execute("SELECT COUNT(*) c FROM plans").fetchone()["c"]
        persona_count = conn.execute("SELECT COUNT(*) c FROM personas").fetchone()["c"]
        recent_plans = conn.execute(
            "SELECT p.*, per.name AS persona_name FROM plans p "
            "LEFT JOIN personas per ON per.id = p.persona_id "
            "ORDER BY p.id DESC LIMIT 5"
        ).fetchall()
    cap = safe_int(get_setting("daily_token_cap", "0"), 0)
    return templates.TemplateResponse(
        request,
        "dashboard.html",
        {
            "company": get_company(),
            "plan_count": plan_count,
            "persona_count": persona_count,
            "recent_plans": [dict(p) for p in recent_plans],
            "tokens_today": tokens_used_today(),
            "cap": cap,
        },
    )


# ---------- Firmenprofil ----------

@app.get("/company", response_class=HTMLResponse)
async def company_form(request: Request):
    return templates.TemplateResponse(request, "company.html", {"company": get_company()})


@app.post("/company")
async def company_save(
    request: Request,
    product: str = Form(""),
    goal: str = Form(""),
    current_state: str = Form(""),
    target_audience: str = Form(""),
    competitors: str = Form(""),
    tone: str = Form(""),
):
    with get_conn() as conn:
        conn.execute(
            "UPDATE company SET product=?, goal=?, current_state=?, target_audience=?, "
            "competitors=?, tone=?, updated_at=? WHERE id=1",
            (product, goal, current_state, target_audience, competitors, tone, now_iso()),
        )
        conn.commit()
    return RedirectResponse("/company?saved=1", status_code=303)


# ---------- KI-Rollen (Personas) ----------

@app.get("/personas", response_class=HTMLResponse)
async def personas_list(request: Request):
    return templates.TemplateResponse(request, "personas.html", {"personas": get_personas()})


@app.post("/personas")
async def personas_create(
    request: Request,
    name: str = Form(...),
    description: str = Form(""),
    system_prompt: str = Form(...),
    model: str = Form("openrouter/auto"),
):
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO personas (name, description, system_prompt, model, created_at) "
            "VALUES (?, ?, ?, ?, ?)",
            (name, description, system_prompt, model, now_iso()),
        )
        conn.commit()
    return RedirectResponse("/personas", status_code=303)


@app.post("/personas/{persona_id}/delete")
async def personas_delete(persona_id: int):
    with get_conn() as conn:
        conn.execute("DELETE FROM personas WHERE id = ?", (persona_id,))
        conn.commit()
    return RedirectResponse("/personas", status_code=303)


@app.post("/personas/{persona_id}/update")
async def personas_update(
    request: Request,
    persona_id: int,
    name: str = Form(...),
    description: str = Form(""),
    system_prompt: str = Form(...),
    model: str = Form("openrouter/auto"),
):
    name = name.strip()
    system_prompt = system_prompt.strip()
    model = model.strip() or "openrouter/auto"
    if not name or not system_prompt:
        return templates.TemplateResponse(
            request,
            "personas.html",
            {"personas": get_personas(), "error": "Name und System-Prompt dürfen nicht leer sein."},
            status_code=422,
        )
    with get_conn() as conn:
        conn.execute(
            "UPDATE personas SET name=?, description=?, system_prompt=?, model=? WHERE id=?",
            (name, description, system_prompt, model, persona_id),
        )
        conn.commit()
    return RedirectResponse("/personas", status_code=303)


# ---------- Pläne ----------

@app.get("/plans", response_class=HTMLResponse)
async def plans_list(request: Request):
    with get_conn() as conn:
        plans = conn.execute("SELECT * FROM plans ORDER BY id DESC").fetchall()
    return templates.TemplateResponse(
        request, "plans.html", {"plans": [dict(p) for p in plans], "personas": get_personas(), "error": None}
    )


@app.post("/plans/generate")
async def plans_generate(request: Request, persona_id: int = Form(...), title: str = Form("")):
    with get_conn() as conn:
        persona = conn.execute("SELECT * FROM personas WHERE id = ?", (persona_id,)).fetchone()
    if not persona:
        return RedirectResponse("/plans", status_code=303)

    company_context = build_company_context()
    user_prompt = (
        f"Firmendaten:\n{company_context}\n\n"
        "Erstelle einen konkreten, umsetzbaren Schritt-für-Schritt-Verkaufsplan. "
        "Antworte AUSSCHLIESSLICH als JSON-Array (keine Erklärung davor/danach) im Format: "
        '[{"title": "Kurzer Schritt-Titel", "description": "konkrete Beschreibung, was genau zu tun ist"}]. '
        "6 bis 12 Schritte, in sinnvoller Reihenfolge, spezifisch für dieses Unternehmen "
        "-- keine generischen Floskeln."
    )
    try:
        content, _usage = await call_model(
            system_prompt=persona["system_prompt"],
            user_prompt=user_prompt,
            model=persona["model"],
            purpose="plan_generation",
        )
    except AIGatewayError as exc:
        with get_conn() as conn:
            plans = conn.execute("SELECT * FROM plans ORDER BY id DESC").fetchall()
        return templates.TemplateResponse(
            request,
            "plans.html",
            {"plans": [dict(p) for p in plans], "personas": get_personas(), "error": str(exc)},
            status_code=502,
        )

    steps = parse_plan_steps(content)
    plan_title = title.strip() or f"Verkaufsplan – {datetime.now().strftime('%d.%m.%Y %H:%M')}"

    with get_conn() as conn:
        cur = conn.execute(
            "INSERT INTO plans (title, persona_id, raw_response, created_at) VALUES (?, ?, ?, ?)",
            (plan_title, persona_id, content, now_iso()),
        )
        plan_id = cur.lastrowid
        for i, step in enumerate(steps):
            conn.execute(
                "INSERT INTO plan_steps (plan_id, position, title, description) VALUES (?, ?, ?, ?)",
                (plan_id, i, step["title"], step["description"]),
            )
        conn.commit()

    return RedirectResponse(f"/plans/{plan_id}", status_code=303)


@app.get("/plans/{plan_id}", response_class=HTMLResponse)
async def plan_detail(request: Request, plan_id: int):
    with get_conn() as conn:
        plan = conn.execute("SELECT * FROM plans WHERE id = ?", (plan_id,)).fetchone()
        steps = conn.execute(
            "SELECT * FROM plan_steps WHERE plan_id = ? ORDER BY position", (plan_id,)
        ).fetchall()
    if not plan:
        return RedirectResponse("/plans", status_code=303)
    return templates.TemplateResponse(
        request, "plan_detail.html", {"plan": dict(plan), "steps": [dict(s) for s in steps]}
    )


@app.post("/plans/{plan_id}/steps/{step_id}/toggle")
async def toggle_step(plan_id: int, step_id: int):
    with get_conn() as conn:
        conn.execute(
            "UPDATE plan_steps SET done = 1 - done WHERE id = ? AND plan_id = ?",
            (step_id, plan_id),
        )
        conn.commit()
    return RedirectResponse(f"/plans/{plan_id}", status_code=303)


@app.post("/plans/{plan_id}/delete")
async def plan_delete(plan_id: int):
    with get_conn() as conn:
        conn.execute("DELETE FROM plan_steps WHERE plan_id = ?", (plan_id,))
        conn.execute("DELETE FROM plans WHERE id = ?", (plan_id,))
        conn.commit()
    return RedirectResponse("/plans", status_code=303)


# ---------- Ideen ----------

@app.get("/ideas", response_class=HTMLResponse)
async def ideas_list(request: Request):
    with get_conn() as conn:
        ideas = conn.execute("SELECT * FROM ideas ORDER BY id DESC LIMIT 30").fetchall()
    return templates.TemplateResponse(
        request, "ideas.html", {"ideas": [dict(i) for i in ideas], "personas": get_personas(), "error": None}
    )


@app.post("/ideas/generate")
async def ideas_generate(request: Request, persona_id: int = Form(...), prompt: str = Form(...)):
    with get_conn() as conn:
        persona = conn.execute("SELECT * FROM personas WHERE id = ?", (persona_id,)).fetchone()
    if not persona:
        return RedirectResponse("/ideas", status_code=303)

    company_context = build_company_context()
    user_prompt = (
        f"Firmendaten:\n{company_context}\n\n"
        f"Anfrage: {prompt}\n\n"
        "Gib 3 bis 6 kurze, konkrete Ideen zurück. Kein vollständiger Plan, "
        "keine Einleitung -- direkt die Ideen als Liste."
    )
    try:
        content, _usage = await call_model(
            system_prompt=persona["system_prompt"],
            user_prompt=user_prompt,
            model=persona["model"],
            purpose="idea_generation",
            max_tokens=800,
        )
    except AIGatewayError as exc:
        with get_conn() as conn:
            ideas = conn.execute("SELECT * FROM ideas ORDER BY id DESC LIMIT 30").fetchall()
        return templates.TemplateResponse(
            request,
            "ideas.html",
            {"ideas": [dict(i) for i in ideas], "personas": get_personas(), "error": str(exc)},
            status_code=502,
        )

    with get_conn() as conn:
        conn.execute(
            "INSERT INTO ideas (prompt, content, created_at) VALUES (?, ?, ?)",
            (prompt, content, now_iso()),
        )
        conn.commit()
    return RedirectResponse("/ideas", status_code=303)


@app.post("/ideas/{idea_id}/delete")
async def idea_delete(idea_id: int):
    with get_conn() as conn:
        conn.execute("DELETE FROM ideas WHERE id = ?", (idea_id,))
        conn.commit()
    return RedirectResponse("/ideas", status_code=303)


# ---------- Einstellungen ----------

@app.get("/settings", response_class=HTMLResponse)
async def settings_form(request: Request):
    api_key = get_setting("api_key", "")
    masked = ("*" * max(len(api_key) - 4, 0)) + api_key[-4:] if api_key else ""
    return templates.TemplateResponse(
        request,
        "settings.html",
        {
            "base_url": get_setting("base_url", "https://openrouter.ai/api/v1"),
            "api_key_masked": masked,
            "has_key": bool(api_key),
            "daily_token_cap": get_setting("daily_token_cap", "0"),
            "max_tokens_per_request": get_setting("max_tokens_per_request", "2000"),
            "tokens_today": tokens_used_today(),
            "saved": request.query_params.get("saved"),
            "error": None,
        },
    )


@app.post("/settings")
async def settings_save(
    request: Request,
    base_url: str = Form(...),
    api_key: str = Form(""),
    daily_token_cap: str = Form("0"),
    max_tokens_per_request: str = Form("2000"),
):
    base_url = base_url.strip().rstrip("/")
    if not (base_url.startswith("http://") or base_url.startswith("https://")):
        return templates.TemplateResponse(
            request,
            "settings.html",
            {
                "base_url": get_setting("base_url", "https://openrouter.ai/api/v1"),
                "api_key_masked": "",
                "has_key": bool(get_setting("api_key", "")),
                "daily_token_cap": get_setting("daily_token_cap", "0"),
                "max_tokens_per_request": get_setting("max_tokens_per_request", "2000"),
                "tokens_today": tokens_used_today(),
                "saved": None,
                "error": "API-Basis-URL muss mit http:// oder https:// beginnen.",
            },
            status_code=422,
        )
    set_setting("base_url", base_url)
    if api_key.strip():
        set_setting("api_key", api_key.strip())
    # safe_int statt int(): ungültige Eingaben ("abc") führten bisher zum 500er.
    # Zusätzlich clampen: negative Limits und absurde Antwortlängen abfangen.
    set_setting("daily_token_cap", str(max(0, safe_int(daily_token_cap, 0))))
    set_setting(
        "max_tokens_per_request",
        str(max(100, min(safe_int(max_tokens_per_request, 2000), 32000))),
    )
    return RedirectResponse("/settings?saved=1", status_code=303)
