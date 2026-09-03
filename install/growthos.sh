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
HOSTNAME="${HOSTNAME_CT:-growthos}"
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

  if ! pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | grep -q "${TEMPLATE}"; then
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
    --hostname "${HOSTNAME}" \
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
  msg_ok "Netzwerk aktiv."
}

# ---------------------------------------------------------------------------
# App im Container installieren / aktualisieren
# ---------------------------------------------------------------------------
install_app() {
  msg_info "Installiere Systempakete im Container (das kann etwas dauern)..."
  pct exec "${CTID}" -- bash -c "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
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

  if [[ "${UPDATE_MODE}" -eq 1 ]] && pct exec "${CTID}" -- test -d "/opt/${APP}/.git" &>/dev/null; then
    msg_info "Bestehende Installation gefunden, aktualisiere per 'git pull'..."
    pct exec "${CTID}" -- su -s /bin/bash "${APP}" -c "
      cd /opt/${APP} && git fetch --quiet && git checkout ${GH_BRANCH} --quiet && git pull --quiet
    "
  else
    msg_info "Klone ${GH_REPO} (Branch ${GH_BRANCH})..."
    pct exec "${CTID}" -- su -s /bin/bash "${APP}" -c "
      git clone --quiet --branch ${GH_BRANCH} ${GH_REPO} /opt/${APP}
    "
  fi

  msg_info "Lege .env an (falls noch nicht vorhanden)..."
  pct exec "${CTID}" -- su -s /bin/bash "${APP}" -c "
    if [[ ! -f /opt/${APP}/.env ]]; then
      cp /opt/${APP}/.env.example /opt/${APP}/.env
      PW='${ADMIN_PASSWORD_INPUT}'
      if [[ -z \"\$PW\" ]]; then
        PW=\$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')
      fi
      sed -i \"s#^ADMIN_PASSWORD=.*#ADMIN_PASSWORD=\${PW}#\" /opt/${APP}/.env
      echo \"\$PW\" > /opt/${APP}/.initial_password
    fi
  "

  msg_info "Baue Python-Umgebung und installiere Abhängigkeiten..."
  pct exec "${CTID}" -- su -s /bin/bash "${APP}" -c "
    python3 -m venv /opt/${APP}/venv
    /opt/${APP}/venv/bin/pip install --upgrade pip -q
    /opt/${APP}/venv/bin/pip install -q -r /opt/${APP}/app/requirements.txt
  "

  msg_info "Setze Berechtigungen (Sicherheitsnetz, sollte bereits stimmen)..."
  pct exec "${CTID}" -- bash -c "chown -R ${APP}:${APP} /opt/${APP}"

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
