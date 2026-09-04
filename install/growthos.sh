#!/usr/bin/env bash
#
# growthOS – Installer im Stil der Proxmox VE Community Scripts
# https://github.com/HatchetMan111/GrowthOS-Proxmox (Platzhalter, siehe README)
#
# Läuft AUF DEM PROXMOX-HOST (nicht in der LXC). Erstellt eine LXC,
# installiert growthOS darin, richtet systemd ein und prüft das Ergebnis.
#
# Einzeiler:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GrowthOS-Proxmox/main/install/growthos.sh)"
#
# Konfigurierbar über Umgebungsvariablen (siehe README für alle Optionen), z.B.:
#   CTID=150 APP_PORT=8000 RAM=2048 bash -c "$(wget -qLO - .../growthos.sh)"
#
# Ehrlicher Hinweis: Dieses Skript wurde per bash -n und shellcheck geprüft
# sowie Schritt für Schritt gegen die reale pct/pveam/pvesh-Doku durchdacht,
# aber NICHT auf einem echten Proxmox-Host ausgeführt (dafür fehlt in der
# Entwicklungsumgebung der Zugriff). Bitte den ersten Lauf aufmerksam
# beobachten und Fehlermeldungen bei Bedarf zurückmelden.

set -euo pipefail

# ---------------------------------------------------------------------------
# Konfiguration (per Umgebungsvariable überschreibbar)
# ---------------------------------------------------------------------------
APP="growthos"
GH_REPO="${GH_REPO:-https://github.com/HatchetMan111/GrowthOS-Proxmox.git}"
GH_BRANCH="${GH_BRANCH:-main}"
APP_PORT="${APP_PORT:-8000}"

CTID="${CTID:-}"                    # leer = automatisch nächste freie ID
# HOSTNAME_CT ist der dokumentierte Weg; CT_HOSTNAME als Alias.
# (Nicht einfach HOSTNAME: die Variable ist auf dem Host fast immer schon
# gesetzt und würde sonst still den Hostnamen übernehmen.)
CT_HOSTNAME="${HOSTNAME_CT:-${CT_HOSTNAME:-growthos}}"
CORES="${CORES:-2}"
RAM="${RAM:-1536}"                  # MB
DISK="${DISK:-6}"                   # GB
SWAP="${SWAP:-512}"                 # MB
BRIDGE="${BRIDGE:-vmbr0}"
# WICHTIG: Auf Standard-Proxmox-Installationen sind das zwei verschiedene
# Storages. "local" (Verzeichnis-Storage) speichert Templates/ISOs,
# "local-lvm" (LVM-Thin) speichert Container-Root-Filesystems. LVM-Thin
# kann i.d.R. KEINE Templates speichern -- daher getrennt konfigurierbar.
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
STORAGE="${STORAGE:-local-lvm}"
OS_VERSION="${OS_VERSION:-12}"      # Debian-Version
ADMIN_PASSWORD_INPUT="${ADMIN_PASSWORD:-}"

LOG_FILE="/tmp/${APP}-install-$(date +%Y%m%d-%H%M%S).log"
# Für hilfreiche Debug-Hinweise: aus GH_REPO die konkrete raw.githubusercontent-URL ableiten
SCRIPT_URL="$(echo "${GH_REPO}" | sed -E 's#github\.com#raw.githubusercontent.com#; s#\.git$##')/${GH_BRANCH}/install/${APP}.sh"

# ---------------------------------------------------------------------------
# Ausgabe-Helfer
# ---------------------------------------------------------------------------
c_reset="\033[0m"; c_green="\033[1;32m"; c_red="\033[1;31m"; c_yellow="\033[1;33m"; c_blue="\033[1;34m"

msg_info()  { echo -e "${c_blue}ℹ${c_reset}  $*"; }
msg_ok()    { echo -e "${c_green}✓${c_reset}  $*"; }
msg_warn()  { echo -e "${c_yellow}!${c_reset}  $*"; }
msg_error() { echo -e "${c_red}✗${c_reset}  $*" >&2; }

# ---------------------------------------------------------------------------
# Vollständige Fehlerkette statt nur der letzten Zeile (Anforderung 4)
# ---------------------------------------------------------------------------
on_error() {
  local exit_code=$?
  local line_no=$1
  msg_error "Installation fehlgeschlagen (Exit-Code ${exit_code}) in Zeile ${line_no}."
  msg_error "Fehlgeschlagener Befehl: ${BASH_COMMAND}"
  msg_error "Vollständiges Log: ${LOG_FILE}"
  if [[ -n "${CTID:-}" ]] && pct status "${CTID}" &>/dev/null; then
    msg_warn "Letzte Zeilen aus journalctl der ${APP}-Unit im Container ${CTID} (falls vorhanden):"
    pct exec "${CTID}" -- journalctl -u "${APP}" -n 50 --no-pager 2>&1 | tee -a "${LOG_FILE}" || true
  fi
  msg_warn "Für eine vollständig ausführliche Fehlersuche das Skript herunterladen und mit -x erneut ausführen:"
  echo "    wget -qLO growthos.sh ${SCRIPT_URL}"
  echo "    bash -x growthos.sh 2>&1 | tee ${LOG_FILE}.debug"
  exit "${exit_code}"
}
trap 'on_error ${LINENO}' ERR

exec > >(tee -a "${LOG_FILE}") 2>&1

# ---------------------------------------------------------------------------
# Preflight-Checks
# ---------------------------------------------------------------------------
preflight() {
  msg_info "Preflight-Checks..."

  if [[ "${EUID}" -ne 0 ]]; then
    msg_error "Bitte als root auf dem Proxmox-Host ausführen."
    exit 1
  fi

  for cmd in pct pveam pvesh; do
    if ! command -v "${cmd}" &>/dev/null; then
      msg_error "Befehl '${cmd}' nicht gefunden. Läuft dieses Skript wirklich auf dem Proxmox-Host?"
      exit 1
    fi
  done

  if [[ "${GH_REPO}" == *"CHANGE_ME"* ]]; then
    msg_error "GH_REPO ist noch der Platzhalter. Bitte eigenes Repo setzen, z.B.:"
    msg_error "  GH_REPO=https://github.com/DEIN-GITHUB-USER/growthos.git bash -c \"\$(wget -qLO - RAW_URL)\""
    exit 1
  fi

  if ! pvesm status 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "${STORAGE}"; then
    msg_error "Storage '${STORAGE}' existiert nicht auf diesem Host. Verfügbare Storages:"
    pvesm status | awk 'NR>1{print " - "$1" ("$2")"}'
    msg_error "Mit STORAGE=NAME ... erneut ausführen."
    exit 1
  fi
  if ! pvesm status 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "${TEMPLATE_STORAGE}"; then
    msg_error "TEMPLATE_STORAGE '${TEMPLATE_STORAGE}' existiert nicht auf diesem Host. Verfügbare Storages:"
    pvesm status | awk 'NR>1{print " - "$1" ("$2")"}'
    msg_error "Mit TEMPLATE_STORAGE=NAME ... erneut ausführen."
    exit 1
  fi

  # Proaktiv prüfen, welche Content-Types die Storages laut /etc/pve/storage.cfg
  # unterstützen -- genau das war die Ursache des vorherigen Fehlers
  # ("storage 'local-lvm' does not support templates"). Lieber hier klar
  # abbrechen als erst mitten im pveam-Download.
  if [[ -r /etc/pve/storage.cfg ]]; then
    local tmpl_content root_content
    tmpl_content="$(get_storage_content "${TEMPLATE_STORAGE}")"
    root_content="$(get_storage_content "${STORAGE}")"

    if [[ -n "${tmpl_content}" ]] && [[ ",${tmpl_content}," != *",vztmpl,"* ]]; then
      msg_error "TEMPLATE_STORAGE '${TEMPLATE_STORAGE}' unterstützt keine Templates (content: ${tmpl_content})."
      msg_error "Storages mit vztmpl-Unterstützung auf diesem Host:"
      list_storages_with_content "vztmpl"
      msg_error "Mit TEMPLATE_STORAGE=NAME aus der Liste erneut ausführen."
      exit 1
    fi
    if [[ -n "${root_content}" ]] && [[ ",${root_content}," != *",rootdir,"* ]]; then
      msg_error "STORAGE '${STORAGE}' unterstützt keine Container-Root-Filesystems (content: ${root_content})."
      msg_error "Storages mit rootdir-Unterstützung auf diesem Host:"
      list_storages_with_content "rootdir"
      msg_error "Mit STORAGE=NAME aus der Liste erneut ausführen."
      exit 1
    fi
  else
    msg_warn "/etc/pve/storage.cfg nicht lesbar, überspringe Content-Type-Prüfung der Storages."
  fi

  msg_ok "Preflight-Checks bestanden."
}

# Liest den "content"-Wert eines Storage-Eintrags aus /etc/pve/storage.cfg
get_storage_content() {
  local storage="$1"
  awk -v s="${storage}" '
    /^[^[:space:]]/ { in_block = ($2 == s) }
    in_block && $1 == "content" { print $2; exit }
  ' /etc/pve/storage.cfg
}

# Listet alle Storages, die einen bestimmten Content-Type unterstützen
list_storages_with_content() {
  local wanted="$1"
  awk -v w="${wanted}" '
    /^[^[:space:]]/ { name = $2 }
    $1 == "content" && $0 ~ w { print " - " name " (content: " $2 ")" }
  ' /etc/pve/storage.cfg
}

# ---------------------------------------------------------------------------
# CT-ID bestimmen (idempotent: existierende ID -> Update-Modus statt Neuanlage)
# ---------------------------------------------------------------------------
resolve_ctid() {
  if [[ -z "${CTID}" ]]; then
    CTID="$(pvesh get /cluster/nextid)"
    msg_info "Keine CTID angegeben, verwende automatisch vergebene ID ${CTID}."
  fi

  if pct status "${CTID}" &>/dev/null; then
    UPDATE_MODE=1
    msg_warn "Container ${CTID} existiert bereits -> Update-Modus (kein Neuanlegen)."
  else
    UPDATE_MODE=0
    msg_info "Container ${CTID} existiert noch nicht -> wird neu angelegt."
  fi
}

# ---------------------------------------------------------------------------
# Debian-Template sicherstellen
# ---------------------------------------------------------------------------
ensure_template() {
  msg_info "Aktualisiere Template-Liste..."
  pveam update &>/dev/null || true

  TEMPLATE="$(pveam available --section system 2>/dev/null \
    | awk -v v="debian-${OS_VERSION}-standard" '$0 ~ v {print $2}' | sort -V | tail -n1)"

  if [[ -z "${TEMPLATE}" ]]; then
    msg_error "Kein Debian-${OS_VERSION}-Template in 'pveam available' gefunden."
    exit 1
  fi

  if ! pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | grep -qF "${TEMPLATE}"; then
    msg_info "Lade Template ${TEMPLATE} nach '${TEMPLATE_STORAGE}' herunter..."
    pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
  fi
  msg_ok "Template bereit: ${TEMPLATE_STORAGE}:${TEMPLATE}"
}

# ---------------------------------------------------------------------------
# LXC anlegen
# ---------------------------------------------------------------------------
create_container() {
  if [[ "${UPDATE_MODE}" -eq 1 ]]; then
    if [[ "$(pct status "${CTID}" | awk '{print $2}')" != "running" ]]; then
      msg_info "Starte bestehenden Container ${CTID}..."
      pct start "${CTID}"
    fi
    return
  fi

  msg_info "Lege Container ${CTID} an (${CORES} vCPU, ${RAM}MB RAM, ${DISK}GB Disk)..."
  pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "${CT_HOSTNAME}" \
    --cores "${CORES}" \
    --memory "${RAM}" \
    --swap "${SWAP}" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged 1 \
    --onboot 1 \
    --features "nesting=0" \
    --start 1

  msg_ok "Container ${CTID} angelegt und gestartet."

  msg_info "Warte auf Netzwerk im Container..."
  local tries=0
  until pct exec "${CTID}" -- sh -c "ip -4 addr show eth0 | grep -q inet" &>/dev/null; do
    tries=$((tries + 1))
    if [[ "${tries}" -gt 30 ]]; then
      msg_error "Container hat nach 60s keine IPv4-Adresse erhalten."
      exit 1
    fi
    sleep 2
  done
  msg_ok "IPv4-Adresse vorhanden."

  # Eine IP-Adresse heisst noch nicht, dass DNS schon funktioniert (DHCP-
  # Optionen fuer den Nameserver koennen minimal spaeter ankommen als die
  # Adresse selbst). Getrennt und mit eigenem Timeout pruefen, statt das
  # implizit beim ersten 'git clone' herauszufinden.
  msg_info "Warte auf funktionierende DNS-Auflösung..."
  tries=0
  until pct exec "${CTID}" -- getent hosts github.com &>/dev/null; do
    tries=$((tries + 1))
    if [[ "${tries}" -gt 20 ]]; then
      msg_warn "DNS-Auflösung antwortet nach 40s nicht. Aktuelle Netzwerk-Konfiguration im Container:"
      pct exec "${CTID}" -- cat /etc/resolv.conf 2>&1 || true
      msg_warn "Fahre trotzdem fort -- falls der spätere 'git clone' fehlschlägt, wird automatisch wiederholt."
      break
    fi
    sleep 2
  done
  if [[ "${tries}" -le 20 ]]; then
    msg_ok "DNS-Auflösung funktioniert."
  fi
}

# Führt einen Befehl im Container mehrfach aus, bevor endgültig aufgegeben
# wird -- schützt gegen kurze Netzwerk-/DNS-Aussetzer direkt nach dem
# Container-Start (in freier Wildbahn beobachtet: 'git clone' schlug einmalig
# mit "Could not resolve host" fehl, obwohl apt kurz zuvor funktioniert hatte).
retry_pct_exec() {
  local attempts="$1"; shift
  local delay="$1"; shift
  local n=0
  until pct exec "${CTID}" -- "$@"; do
    n=$((n + 1))
    if [[ "${n}" -ge "${attempts}" ]]; then
      return 1
    fi
    msg_warn "Befehl fehlgeschlagen (Versuch ${n}/${attempts}), erneuter Versuch in ${delay}s..."
    sleep "${delay}"
  done
  return 0
}

# Wird aufgerufen, wenn git clone/pull trotz Retries scheitert. Grenzt ein,
# ob es DNS, ein Proxy oder eine Firewall/ein Filter ist, der github.com
# abfängt (z.B. "could not read Username" trotz öffentlichem Repo deutet
# stark auf Letzteres hin, nicht auf ein Problem mit diesem Skript oder Repo).
diagnose_git_failure() {
  msg_warn "DNS-Auflösung im Container:"
  pct exec "${CTID}" -- cat /etc/resolv.conf 2>&1 || true
  pct exec "${CTID}" -- getent hosts github.com 2>&1 || true
  msg_warn "Proxy-Umgebungsvariablen im Container (sollten i.d.R. leer sein):"
  pct exec "${CTID}" -- bash -c 'env | grep -i _proxy || echo "(keine gesetzt)"' 2>&1 || true
  msg_warn "Tatsächliche HTTP-Antwort von github.com (zeigt, ob ein Proxy/eine Firewall dazwischenhängt):"
  pct exec "${CTID}" -- curl -sS -o /dev/null -w "HTTP-Status: %{http_code}, tatsächliche Ziel-IP: %{remote_ip}\n" https://github.com 2>&1 || true
  msg_warn "Falls der HTTP-Status nicht 200/301/302 ist oder die IP nicht zu GitHub gehört: sehr wahrscheinlich ein Proxy/eine Firewall/IPv6-Routing-Problem in deinem Netzwerk, kein Problem des Skripts oder Repos (von einem anderen Netzwerk aus erfolgreich gegengetestet)."
}

# ---------------------------------------------------------------------------
# App im Container installieren / aktualisieren
# ---------------------------------------------------------------------------
install_app() {
  msg_info "Installiere Systempakete im Container (das kann etwas dauern)..."
  pct exec "${CTID}" -- bash -c "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    export LC_ALL=C LANGUAGE=C
    apt-get update -qq
    apt-get install -y -qq python3 python3-venv python3-pip git curl ca-certificates >/dev/null
  "

  msg_info "Richte Systemnutzer '${APP}' ein..."
  # -M (kein Home-Verzeichnis automatisch anlegen): verhindert, dass useradd
  # per /etc/skel Dateien in /opt/${APP} legt, bevor wir per 'git clone' ein
  # LEERES Zielverzeichnis brauchen.
  pct exec "${CTID}" -- bash -c "
    id -u ${APP} &>/dev/null || useradd -r -M -d /opt/${APP} -s /usr/sbin/nologin ${APP}
    mkdir -p /opt/${APP}
    chown ${APP}:${APP} /opt/${APP}
  "

  # Ab hier bewusst ALLES als '${APP}'-Nutzer statt root ausführen (nicht
  # nur der finale chown am Ende): sonst gehört das Verzeichnis nach dem
  # ersten Lauf '${APP}', aber ein späterer 'git pull' liefe als root darauf
  # -- Git verweigert das dann als "dubious ownership" (getestet, echter Bug
  # in einer früheren Version dieses Skripts).
  # --system (nicht --global!): landet in /etc/gitconfig statt in
  # $HOME/.gitconfig -- sonst existiert vor dem 'git clone' bereits eine
  # Datei im Zielverzeichnis und der Klon schlägt mit "not an empty
  # directory" fehl (getestet, echter Bug in einer früheren Version).
  pct exec "${CTID}" -- bash -c "
    git config --system --add safe.directory /opt/${APP}
  "

  # retry_pct_exec statt direktem pct exec: direkt nach dem Container-Start
  # kann DNS noch kurz hinterherhinken, selbst wenn apt kurz zuvor schon
  # funktioniert hat (in freier Wildbahn beobachtet: "Could not resolve
  # host: github.com"). 3 Versuche mit 8s Abstand fangen das ab.
  #
  # GIT_TERMINAL_PROMPT=0 + credential.helper=: verhindert, dass git bei
  # einer unerwarteten Server-Antwort (z.B. durch einen Proxy/eine Firewall,
  # die github.com abfängt) nach Zugangsdaten fragt und dabei ohne Terminal
  # hängt/kryptisch fehlschlägt -- schlägt stattdessen sofort klar fehl.
  if [[ "${UPDATE_MODE}" -eq 1 ]] && pct exec "${CTID}" -- test -d "/opt/${APP}/.git" &>/dev/null; then
    msg_info "Bestehende Installation gefunden, aktualisiere per 'git pull'..."
    if ! retry_pct_exec 3 8 su -s /bin/bash "${APP}" -c "
      export GIT_TERMINAL_PROMPT=0
      cd /opt/${APP} && git -c credential.helper= fetch --quiet && git checkout \"${GH_BRANCH}\" --quiet && git -c credential.helper= pull --ff-only --quiet
    "; then
      msg_error "git pull ist nach 3 Versuchen fehlgeschlagen."
      diagnose_git_failure
      exit 1
    fi
  else
    msg_info "Klone ${GH_REPO} (Branch ${GH_BRANCH})..."
    if ! retry_pct_exec 3 8 su -s /bin/bash "${APP}" -c "
      export GIT_TERMINAL_PROMPT=0
      git -c credential.helper= clone --quiet --branch \"${GH_BRANCH}\" ${GH_REPO} /opt/${APP}
    "; then
      msg_error "git clone ist nach 3 Versuchen fehlgeschlagen."
      diagnose_git_failure
      exit 1
    fi
  fi

  msg_info "Lege .env an (falls noch nicht vorhanden)..."
  # BUGFIX: Die alte Variante baute das Passwort per
  #   PW='${ADMIN_PASSWORD_INPUT}' + sed
  # in einen Container-Shell-String ein. Jedes Sonderzeichen im Passwort
  # (', $, !, #, &, Backslash, ...) zerbrach das Quoting bzw. das sed-
  # Ersetzungsmuster. Stattdessen: Passwort auf dem HOST erzeugen, .env auf
  # dem HOST per Python bauen und per 'pct push' in den Container schieben --
  # so erreicht kein einziges Passwort-Zeichen je eine Shell.
  if pct exec "${CTID}" -- test -f "/opt/${APP}/.env" &>/dev/null; then
    msg_info ".env existiert bereits, lasse sie unverändert."
  else
    local pw="${ADMIN_PASSWORD_INPUT}"
    if [[ -z "${pw}" ]]; then
      pw="$(python3 -c 'import secrets; print(secrets.token_urlsafe(16))')"
    fi
    local tmp_env tmp_pw
    tmp_env="$(mktemp)"
    tmp_pw="$(mktemp)"
    pct exec "${CTID}" -- cat "/opt/${APP}/.env.example" > "${tmp_env}"
    PW_VALUE="${pw}" ENV_FILE="${tmp_env}" python3 - <<'PYEOF'
import os
env_file = os.environ["ENV_FILE"]
pw = os.environ["PW_VALUE"]
with open(env_file) as f:
    content = f.read()
lines, replaced = [], False
for line in content.splitlines():
    if line.startswith("ADMIN_PASSWORD="):
        lines.append(f"ADMIN_PASSWORD={pw}")
        replaced = True
    else:
        lines.append(line)
if not replaced:
    lines.append(f"ADMIN_PASSWORD={pw}")
with open(env_file, "w") as f:
    f.write("\n".join(lines) + "\n")
PYEOF
    printf '%s' "${pw}" > "${tmp_pw}"
    pct push "${CTID}" "${tmp_env}" "/opt/${APP}/.env" --perms 600
    pct push "${CTID}" "${tmp_pw}" "/opt/${APP}/.initial_password" --perms 600
    rm -f "${tmp_env}" "${tmp_pw}"
    unset pw tmp_env tmp_pw
    pct exec "${CTID}" -- bash -c "chown ${APP}:${APP} /opt/${APP}/.env /opt/${APP}/.initial_password"
  fi

  msg_info "Baue Python-Umgebung und installiere Abhängigkeiten..."
  pct exec "${CTID}" -- su -s /bin/bash "${APP}" -c "
    python3 -m venv /opt/${APP}/venv
    /opt/${APP}/venv/bin/pip install --upgrade pip -q
    /opt/${APP}/venv/bin/pip install -q -r /opt/${APP}/app/requirements.txt
  "

  msg_info "Setze Berechtigungen (Sicherheitsnetz, sollte bereits stimmen)..."
  pct exec "${CTID}" -- bash -c "chown -R ${APP}:${APP} /opt/${APP}"

  msg_info "Lege Datenverzeichnis an (muss vor dem Service-Start existieren)..."
  # ProtectSystem=strict + ReadWritePaths in der systemd-Unit setzen bei
  # Start einen Mount-Namespace auf -- dafür MUSS der Pfad schon existieren,
  # sonst schlägt der Service mit "Failed at step NAMESPACE" fehl (getestet,
  # echter Bug: die App selbst legt data/ erst beim ersten Start an, aber da
  # kommt sie dann gar nicht mehr hin).
  pct exec "${CTID}" -- su -s /bin/bash "${APP}" -c "mkdir -p /opt/${APP}/app/data"

  msg_info "Richte systemd-Service ein..."
  pct exec "${CTID}" -- bash -c "
    sed \"s#__PORT__#${APP_PORT}#\" /opt/${APP}/install/${APP}.service > /etc/systemd/system/${APP}.service
    systemctl daemon-reload
    systemctl enable --now ${APP}
    systemctl restart ${APP}
  "

  if pct exec "${CTID}" -- command -v ufw &>/dev/null; then
    if pct exec "${CTID}" -- bash -c "ufw status | grep -q 'Status: active'" &>/dev/null; then
      msg_info "ufw aktiv, öffne Port ${APP_PORT}..."
      pct exec "${CTID}" -- ufw allow "${APP_PORT}/tcp" &>/dev/null || true
    fi
  fi

  msg_ok "App installiert."
}

# ---------------------------------------------------------------------------
# Verifikation (Anforderung 7)
# ---------------------------------------------------------------------------
verify() {
  msg_info "Prüfe Service-Status..."
  local tries=0
  until [[ "$(pct exec "${CTID}" -- systemctl is-active "${APP}" 2>/dev/null || true)" == "active" ]]; do
    tries=$((tries + 1))
    if [[ "${tries}" -gt 15 ]]; then
      msg_error "Service ist nach 30s nicht aktiv. journalctl-Auszug:"
      pct exec "${CTID}" -- journalctl -u "${APP}" -n 50 --no-pager || true
      exit 1
    fi
    sleep 2
  done
  msg_ok "Service ist aktiv."

  msg_info "Prüfe Web-UI-Erreichbarkeit..."
  tries=0
  until pct exec "${CTID}" -- curl -sf "http://localhost:${APP_PORT}/health" &>/dev/null; do
    tries=$((tries + 1))
    if [[ "${tries}" -gt 15 ]]; then
      msg_error "Web-UI antwortet nach 30s nicht auf /health. journalctl-Auszug:"
      pct exec "${CTID}" -- journalctl -u "${APP}" -n 50 --no-pager || true
      exit 1
    fi
    sleep 2
  done
  msg_ok "Web-UI antwortet."

  CT_IP="$(pct exec "${CTID}" -- hostname -I | awk '{print $1}')"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  msg_info "growthOS-Installer gestartet. Log: ${LOG_FILE}"
  preflight
  resolve_ctid
  ensure_template
  create_container
  install_app
  verify

  echo
  msg_ok "Fertig."
  echo -e "  ${c_green}URL:${c_reset}        http://${CT_IP}:${APP_PORT}"
  echo -e "  ${c_green}Container:${c_reset}  CTID ${CTID}"
  if pct exec "${CTID}" -- test -f "/opt/${APP}/.initial_password" &>/dev/null; then
    INITIAL_PW="$(pct exec "${CTID}" -- cat "/opt/${APP}/.initial_password")"
    echo -e "  ${c_green}Passwort:${c_reset}   ${INITIAL_PW}  (aus /opt/${APP}/.env, bitte ändern und Datei löschen)"
  fi
  echo -e "  ${c_yellow}Update:${c_reset}     Skript erneut mit derselben CTID=${CTID} ausführen."
  echo
}

main "$@"
