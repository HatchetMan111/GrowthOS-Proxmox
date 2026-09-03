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

Falls du dieses Repo forkst/umbenennst, ersetze `HatchetMan111/GrowthOS-Proxmox`
unten überall durch deinen eigenen Pfad. **Wichtig:** nie `<` oder `>` als
Platzhalter-Klammern in Shell-Befehlen verwenden – das sind Sonderzeichen für
Ein-/Ausgabe-Umleitung und die Kommandos brechen dann mit einem kryptischen
Fehler ab (`-bash: DEIN-USER: No such file or directory`).

```bash
cd growthos               # dieser entpackte Ordner
git init -b main           # falls noch kein Git-Repo
git add -A
git commit -m "Initial commit"
git remote add origin https://github.com/HatchetMan111/GrowthOS-Proxmox.git
git push -u origin main
```

## Installation (Einzeiler, auf dem Proxmox-Host als root ausführen)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GrowthOS-Proxmox/main/install/growthos.sh)"
```

`GH_REPO` muss dabei nicht extra gesetzt werden, wenn du dieses Repo direkt
nutzt – das Skript ist bereits darauf vorkonfiguriert. Falls du einen eigenen
Fork verwendest, zusätzlich `GH_REPO=https://github.com/DEIN-GITHUB-USER/growthos.git`
voranstellen (ohne spitze Klammern, siehe oben).

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
| `TEMPLATE_STORAGE` | `local` | Storage für das LXC-Template (muss Content-Type `vztmpl` unterstützen) |
| `STORAGE` | `local-lvm` | Storage für das Container-Root-Filesystem (muss Content-Type `rootdir` unterstützen) |
| `BRIDGE` | `vmbr0` | Netzwerk-Bridge |
| `GH_REPO` | dieses Repo | Eigenes Repo, falls geforkt |
| `GH_BRANCH` | `main` | Git-Branch |
| `ADMIN_PASSWORD` | zufällig generiert | Admin-Passwort fest vorgeben statt generieren zu lassen |

`TEMPLATE_STORAGE` und `STORAGE` sind bewusst getrennt: Auf den meisten
Proxmox-Installationen kann der Storage für Container-Disks (oft `local-lvm`,
LVM-Thin) keine Templates speichern – das kann nur ein Verzeichnis-Storage
wie `local`. Das Skript prüft das jetzt selbst vorab anhand von
`/etc/pve/storage.cfg` und bricht mit einer klaren Meldung ab, falls die
Zuordnung auf deinem Host anders ist, statt erst mitten im Template-Download
mit einem kryptischen Proxmox-Fehler zu scheitern.

Beispiel mit mehreren Optionen:

```bash
CTID=150 APP_PORT=8080 RAM=2048 \
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GrowthOS-Proxmox/main/install/growthos.sh)"
```

## Update

Skript mit derselben `CTID` erneut ausführen – es erkennt die bestehende
Installation und macht `git pull` + Dependency-Update + Neustart statt
neu anzulegen (idempotent):

```bash
CTID=150 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GrowthOS-Proxmox/main/install/growthos.sh)"
```

## Deinstallation

Ersetze `150` durch deine tatsächliche Container-ID:

```bash
pct stop 150
pct destroy 150
```

## Passwort ändern

Auf der LXC (`150` durch deine Container-ID ersetzen):

```bash
pct exec 150 -- nano /opt/growthos/.env   # ADMIN_PASSWORD anpassen
pct exec 150 -- systemctl restart growthos
```

## Fehlersuche

- Log des Installer-Laufs: `/tmp/growthos-install-*.log` auf dem Proxmox-Host
- Ausführlicher Debug-Modus: Skript herunterladen und mit `bash -x growthos.sh` starten (Umgebungsvariablen wie oben davorstellen)
- Logs der App selbst: `pct exec 150 -- journalctl -u growthos -n 100 --no-pager`
- Health-Check von Hand: `pct exec 150 -- curl -sf http://localhost:8000/health`

## Bekannter Vorbehalt

Der Installer wurde `bash -n`- und `shellcheck`-geprüft und in einer
simulierten Proxmox-Umgebung (Fake-`pct`/`pveam`/`pvesh`) end-to-end
durchgetestet, außerdem mehrfach auf einem echten Proxmox-Host verifiziert.
Bereits behoben: Verwechslung von Template-/Rootfs-Storage, ein
Git-Ownership-Konflikt im Update-Modus, ein DNS-Timing-Problem direkt nach
dem Container-Start, sowie ein systemd-Fehler beim allerersten Start
(`ProtectSystem=strict` + `ReadWritePaths` verlangen, dass `app/data`
schon existiert – wird jetzt vom Installer vorab angelegt statt erst von
der App selbst). Falls `git clone`/`git pull` mit "could not read Username"
fehlschlägt, ist das erfahrungsgemäß kein Problem dieses Skripts oder des
Repos (von mehreren Netzwerken aus erfolgreich gegengetestet), sondern
deutet auf einen Proxy, eine Firewall oder ein IPv6-Routing-Problem im
eigenen Netzwerk hin – der Installer gibt bei diesem Fehler jetzt eine
gezielte Diagnose aus (DNS, Proxy-Variablen, tatsächliche HTTP-Antwort von
github.com). Bitte trotzdem jeden Lauf aufmerksam beobachten und
Fehlermeldungen bei Bedarf melden.

## Architektur

Python/FastAPI + SQLite (eine Datei, kein separater DB-Server) +
serverseitig gerendertes HTML/JS-Dashboard. Kein Docker, kein Node-Build,
kein Redis/Postgres – bewusst schlank für die Ein-Unternehmen-Größe. Die
KI-Anbindung ist gegen die OpenAI-kompatible Chat-Completions-API gebaut,
daher mit OpenRouter und den meisten anderen Multi-Modell-Routern kompatibel.

Für die spätere Ausbaustufe (mehrere Unternehmen, Connector-Framework für
Social/CRM/Ads, RAG über eine Wissensbasis) braucht es einen neuen
Architektur-Cut – siehe Gespräch zur ursprünglichen Gesamtplanung.
