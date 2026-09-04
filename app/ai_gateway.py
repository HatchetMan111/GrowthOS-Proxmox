"""
KI-Gateway. Bewusst gegen die OpenAI-kompatible Chat-Completions-API gebaut,
weil OpenRouter dieses Format spricht und die meisten Multi-Modell-Router
(u.a. Omniroute) ebenfalls OpenAI-kompatibel sind. Die Basis-URL ist frei
konfigurierbar (siehe /settings), damit der Anbieter austauschbar bleibt.

WICHTIG (siehe README "Datenfluss"): Diese Funktion verlässt die LXC in
Richtung Internet. "Lokal gehostet" bezieht sich auf die Infrastruktur,
NICHT auf die Inhalte der Prompts.
"""

from datetime import datetime, timezone
import json
import re

import httpx

from db import get_conn, get_setting

DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"
REQUEST_TIMEOUT = httpx.Timeout(90.0, connect=10.0)


class AIGatewayError(Exception):
    """Trägt eine vollständige, für den Nutzer verständliche Fehlerkette."""


class TokenCapExceeded(AIGatewayError):
    pass


def _today() -> str:
    return datetime.now(timezone.utc).date().isoformat()


def tokens_used_today() -> int:
    with get_conn() as conn:
        row = conn.execute(
            "SELECT COALESCE(SUM(tokens_used), 0) AS total FROM usage_log WHERE day = ?",
            (_today(),),
        ).fetchone()
        return int(row["total"])


def _log_usage(tokens: int, model: str, purpose: str) -> None:
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO usage_log (day, tokens_used, model, purpose) VALUES (?, ?, ?, ?)",
            (_today(), tokens, model, purpose),
        )
        conn.commit()


def _check_cap() -> None:
    try:
        cap = int(get_setting("daily_token_cap", "0") or "0")
    except (TypeError, ValueError):
        cap = 0  # korrupter Wert -> kein Limit statt 500er
    if cap <= 0:
        return  # 0 == kein Limit gesetzt
    used = tokens_used_today()
    if used >= cap:
        raise TokenCapExceeded(
            f"Tages-Token-Limit erreicht ({used}/{cap} Tokens). "
            "Limit unter Einstellungen anpassen oder morgen weitermachen."
        )


def _extract_tokens(usage: dict) -> int:
    """Manche Router liefern kein total_tokens, sondern nur
    prompt_tokens + completion_tokens. Fallback summieren, sonst
    würde die Nutzung als 0 geloggt und das Tages-Limit umgangen."""
    if not isinstance(usage, dict):
        return 0
    total = usage.get("total_tokens")
    try:
        if total is not None:
            return int(total)
    except (TypeError, ValueError):
        pass
    try:
        return int(usage.get("prompt_tokens") or 0) + int(
            usage.get("completion_tokens") or 0
        )
    except (TypeError, ValueError):
        return 0


async def call_model(
    system_prompt: str,
    user_prompt: str,
    model: str,
    purpose: str = "generic",
    max_tokens: int | None = None,
) -> tuple[str, dict]:
    """Ruft das konfigurierte Modell auf. Wirft AIGatewayError mit vollständiger
    Fehlermeldungskette (Status, Body) statt nur der letzten Fehlerzeile."""

    _check_cap()

    api_key = get_setting("api_key", "")
    if not api_key:
        raise AIGatewayError(
            "Kein API-Key hinterlegt. Unter /settings einen OpenRouter- oder "
            "Omniroute-Key eintragen."
        )
    base_url = get_setting("base_url", DEFAULT_BASE_URL).rstrip("/")
    try:
        request_max_tokens = max_tokens or int(
            get_setting("max_tokens_per_request", "2000")
        )
    except (TypeError, ValueError):
        request_max_tokens = 2000
    request_max_tokens = max(100, min(request_max_tokens, 32000))

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        # max_tokens (klassisch) + max_completion_tokens (neue Reasoning-Modelle):
        # Unbekannte Felder ignorieren OpenAI-kompatible Router, fehlende
        # Felder führen bei manchen Modellen zu unbegrenzt langen Antworten.
        "max_tokens": request_max_tokens,
        "max_completion_tokens": request_max_tokens,
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        # OpenRouter-Empfehlung: ohne Referer/Titel wird stärker rate-limitiert.
        "HTTP-Referer": "https://localhost/",
        "X-Title": "growthOS",
    }

    try:
        async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as client:
            resp = await client.post(
                f"{base_url}/chat/completions", json=payload, headers=headers
            )
    except httpx.RequestError as exc:
        raise AIGatewayError(
            f"Netzwerkfehler beim Aufruf von {base_url}: {exc!r}. "
            "Prüfe, ob die LXC Internetzugriff hat (DNS/Firewall)."
        ) from exc

    if resp.status_code >= 400:
        raise AIGatewayError(
            f"API-Fehler {resp.status_code} von {base_url}: {resp.text[:1000]}"
        )

    try:
        data = resp.json()
        content = data["choices"][0]["message"]["content"]
        usage = data.get("usage", {})
    except (KeyError, IndexError, json.JSONDecodeError, TypeError) as exc:
        raise AIGatewayError(
            f"Unerwartetes Antwortformat vom Modell-Anbieter: {resp.text[:1000]}"
        ) from exc

    if not content or not isinstance(content, str):
        raise AIGatewayError(
            "Leere Antwort vom Modell-Anbieter erhalten. "
            "Ggf. anderes Modell wählen oder erneut versuchen."
        )

    tokens = _extract_tokens(usage)
    _log_usage(tokens, model, purpose)
    return content, usage


def _normalize_steps(parsed, fallback_title_prefix="Schritt") -> list[dict] | None:
    """Akzeptiert Liste ODER Dict-Wrapper ({"steps": [...]}, {"plan": [...]},
    {"items": [...]}), wie ihn manche Modelle trotz Array-Anweisung liefern.
    Gibt None zurück, wenn nichts Brauchbares dabei ist."""
    if isinstance(parsed, dict):
        for key in ("steps", "plan", "items", "schritte"):
            if isinstance(parsed.get(key), list):
                parsed = parsed[key]
                break
        else:
            return None
    if not isinstance(parsed, list):
        return None
    steps = []
    for i, s in enumerate(parsed):
        if isinstance(s, str):
            steps.append({"title": s[:120], "description": ""})
        elif isinstance(s, dict):
            steps.append(
                {
                    "title": str(
                        s.get("title") or s.get("titel") or s.get("name")
                        or f"{fallback_title_prefix} {i + 1}"
                    ),
                    "description": str(
                        s.get("description") or s.get("beschreibung")
                        or s.get("text") or s.get("content") or ""
                    ),
                }
            )
    return steps or None


def _strip_code_fences(text: str) -> str:
    """Entfernt ```json ... ```-Zäune, die Modelle gern um JSON legen."""
    m = re.search(r"```(?:json)?\s*(.*?)```", text, re.DOTALL | re.IGNORECASE)
    return m.group(1).strip() if m else text


def parse_plan_steps(raw_text: str) -> list[dict]:
    """Erwartet eine JSON-Liste von {"title": ..., "description": ...}.
    Fällt robust auf Rohtext zurück, falls das Modell kein sauberes JSON liefert
    -- nichts geht verloren, es wird nur nicht in Einzelschritte zerlegt."""

    text = _strip_code_fences(raw_text.strip())
    try:
        steps = _normalize_steps(json.loads(text))
        if steps:
            return steps
    except json.JSONDecodeError:
        pass

    match = re.search(r"\[.*\]|\{.*\}", text, re.DOTALL)
    if match:
        try:
            steps = _normalize_steps(json.loads(match.group(0)))
            if steps:
                return steps
        except json.JSONDecodeError:
            pass

    return [{"title": "Antwort (nicht als Liste erkannt)", "description": raw_text.strip()}]
