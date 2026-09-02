# growthOS

Lokales Marketing-Planungstool für ein Unternehmen: Firmenprofil hinterlegen,
KI-Rollen (Stratege, Copywriter, SEO, Ads, Social, Vertrieb) konfigurieren,
daraus konkrete Schritt-für-Schritt-Verkaufspläne und schnelle Ideen generieren.

Läuft komplett in einer eigenen Proxmox-LXC, per Ein-Zeiler installiert,
im Stil der Proxmox VE Community Scripts.

## Scope dieser Version (bewusst)

Für ein einzelnes Unternehmen gebaut, nicht als Multi-Tenant-Produkt für
mehrere Kunden. Kein RAG/Vektor-Suche, kein Connector-Framework für Social
Media/CRM/Ads – das sind bewusste spätere Phasen, keine vergessenen Features.
Ein einfacher Passwortschutz statt vollem Rollen-/Rechtesystem, weil das
Tool für dich bzw. dein Team allein gedacht ist.

## Wichtig: Datenfluss

"Lokal gehostet" bezieht sich auf die **Infrastruktur** (die LXC läuft bei
dir, niemand von außen hat automatisch Zugriff). Es bezieht sich **nicht**
auf den Inhalt der KI-Anfragen: Firmenprofil, Zielgruppen- und Strategiedaten
werden bei jeder Plan-/Ideen-Generierung an die konfigurierte API
(OpenRouter, Omniroute o.ä.) und von dort an den jeweiligen Modell-Anbieter
(z. B. Anthropic, OpenAI, Google) übertragen. Für ein vollständig
"air-gapped" System bräuchte es lokal laufende Modelle (z. B. über Ollama) –
das ist mit der aktuellen Architektur nachrüstbar, aber nicht Teil des MVP.

## Voraussetzungen

- Proxmox VE Host mit Internetzugriff für die LXC (für `apt`, `pip`, `git clone`, und die API-Aufrufe selbst)
- Ein eigenes GitHub-Repository mit diesem Code (siehe unten – ich kann nicht in deinem Namen pushen)
- Ein OpenRouter- oder Omniroute-API-Key (wird nach der Installation im Dashboard unter „Einstellungen" hinterlegt, nicht während der Installation)

## Einmalig: Code in dein eigenes Repo bringen

```bash
cd growthos               # dieser entpackte Ordner
git init -b main           # falls noch kein Git-Repo
git add -A
git commit -m "Initial commit"
git remote add origin https://github.com/<DEIN-USER>/growthos.git
git push -u origin main
```

## Installation (Einzeiler, auf dem Proxmox-Host als root ausführen)

```bash
GH_REPO=https://github.com/<DEIN-USER>/growthos.git \
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/<DEIN-USER>/growthos/main/install/growthos.sh)"
```

Am Ende gibt das Skript die URL des Dashboards, die Container-ID und ein
automatisch generiertes Admin-Passwort aus (steht auch in
`/opt/growthos/.env` auf der LXC – Datei danach am besten aufräumen/Passwort
ändern).

### Optionen (per Umgebungsvariable vor dem Einzeiler)

| Variable | Standard | Bedeutung |
|---|---|---|
| `CTID` | nächste freie ID | Container-ID |
| `APP_PORT` | `8000` | Port des Dashboards |
| `CORES` | `2` | vCPUs |
| `RAM` | `1536` | RAM in MB |
| `DISK` | `6` | Diskgröße in GB |
| `STORAGE` | `local-lvm` | Proxmox-Storage für Rootfs + Template |
| `BRIDGE` | `vmbr0` | Netzwerk-Bridge |
| `GH_BRANCH` | `main` | Git-Branch |
| `ADMIN_PASSWORD` | zufällig generiert | Admin-Passwort fest vorgeben statt generieren zu lassen |

Beispiel mit mehreren Optionen:

```bash
CTID=150 APP_PORT=8080 RAM=2048 GH_REPO=https://github.com/<DEIN-USER>/growthos.git \
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/<DEIN-USER>/growthos/main/install/growthos.sh)"
```

## Update

Skript mit derselben `CTID` erneut ausführen – es erkennt die bestehende
Installation und macht `git pull` + Dependency-Update + Neustart statt
neu anzulegen (idempotent):

```bash
CTID=150 GH_REPO=https://github.com/<DEIN-USER>/growthos.git \
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/<DEIN-USER>/growthos/main/install/growthos.sh)"
```

## Deinstallation

```bash
pct stop <CTID>
pct destroy <CTID>
```

## Passwort ändern

Auf der LXC:

```bash
pct exec <CTID> -- nano /opt/growthos/.env   # ADMIN_PASSWORD anpassen
pct exec <CTID> -- systemctl restart growthos
```

## Fehlersuche

- Log des Installer-Laufs: `/tmp/growthos-install-*.log` auf dem Proxmox-Host
- Ausführlicher Debug-Modus: `bash -x install/growthos.sh` (nachdem die Umgebungsvariablen wie oben gesetzt sind)
- Logs der App selbst: `pct exec <CTID> -- journalctl -u growthos -n 100 --no-pager`
- Health-Check von Hand: `pct exec <CTID> -- curl -sf http://localhost:8000/health`

## Bekannter Vorbehalt

Der Installer wurde `bash -n`- und `shellcheck`-geprüft und in einer
simulierten Proxmox-Umgebung (Fake-`pct`/`pveam`/`pvesh`) end-to-end
durchgetestet, aber noch nicht auf einem echten Proxmox-Host verifiziert.
Bitte den ersten Lauf aufmerksam beobachten und Fehlermeldungen bei Bedarf
melden – die vollständige Fehlerkette wird ausgegeben (siehe „Fehlersuche").

## Architektur

Python/FastAPI + SQLite (eine Datei, kein separater DB-Server) +
serverseitig gerendertes HTML/JS-Dashboard. Kein Docker, kein Node-Build,
kein Redis/Postgres – bewusst schlank für die Ein-Unternehmen-Größe. Die
KI-Anbindung ist gegen die OpenAI-kompatible Chat-Completions-API gebaut,
daher mit OpenRouter und den meisten anderen Multi-Modell-Routern kompatibel.

Für die spätere Ausbaustufe (mehrere Unternehmen, Connector-Framework für
Social/CRM/Ads, RAG über eine Wissensbasis) braucht es einen neuen
Architektur-Cut – siehe Gespräch zur ursprünglichen Gesamtplanung.
