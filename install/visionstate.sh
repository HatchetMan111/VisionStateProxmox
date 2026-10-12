#!/usr/bin/env bash
#
# VisionState Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      VisionState – lokale KI die Kamerabilder in Home Assistant
#           Sensoren verwandelt (states/objects/readings). DINOv2 ONNX +
#           D-FINE Detector + PaddleOCR/WheelReader. 100% lokal, CPU-only.
# Upstream: https://github.com/oleost/VisionState (Apache-2.0)
# Stack:    Python 3.14 (via uv) + venv + pip, Frontend Svelte 5 + Vite
#           (npm-Build im CT), ohne Docker, ohne Cloud.
#           Web-UI auf :8099, bind 0.0.0.0 im Container.
# Laeuft:   vollstaendig lokal im LXC, keine externen Cloud-Dienste noetig
# Host:     DAS SKRIPT LAEUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VisionStateProxmox/main/install/visionstate.sh)"
#   CT_ID=150 CORES=2 RAM=3072 DISK=12 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VisionStateProxmox/main/install/visionstate.sh)"
#   bash visionstate.sh --ctid 150 --cores 2 --memory 3072 --disk 12 --bridge vmbr0 --debug
#
# Hinweis: Unit wird live aus diesem Repo geladen (SERVICE_URL unten).
# Ohne Netz zum Repo greift der Inline-Fallback im Skript.
# WARNUNG: Ausserhalb von Home Assistant hat VisionState KEIN Login –
# nur im vertrauenswuerdigen LAN betreiben oder hinter Reverse-Proxy mit Auth.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="visionstate"                             # Container-Hostname + Service-Name
APP_PORT="8099"                               # VisionState Web-UI + API
UPSTREAM_REPO="https://github.com/oleost/VisionState"
BRANCH="main"
INSTALLER_REPO="https://github.com/HatchetMan111/VisionStateProxmox"
SERVICE_URL="https://raw.githubusercontent.com/HatchetMan111/VisionStateProxmox/main/systemd/visionstate.service"

DEFAULT_CORES="2"                             # vCPU (KI-Inferenz CPU-only)
DEFAULT_RAM="3072"                            # RAM in MB (Modelle: DINOv2 + D-FINE + OCR)
DEFAULT_SWAP="512"                            # Swap in MB
DEFAULT_DISK="12"                             # Disk in GB (App + npm-Build + Modelle ~2GB + Media)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                # Storage fuer CT-Templates
DEFAULT_OS="debian-12-standard"               # Template-Familie
UNPRIVILEGED="1"                              # 1 = unprivilegiert (reicht hier)
FEATURES="nesting=1"                          # nesting fuer Robustheit

APP_USER="visionstate"
APP_DIR="/opt/visionstate"
VENV_DIR="/opt/visionstate/.venv"
ENV_DIR="/etc/visionstate"
ENV_FILE="/etc/visionstate/env"
DATA_DIR="/var/lib/visionstate"
MEDIA_DIR="/var/lib/visionstate-media"
FRONTEND_DIST="/opt/visionstate/visionstate/frontend/dist"
MODELS_DIR="/var/lib/visionstate/models"

# Umgebungs-Overrides: CT_ID=150 CORES=2 RAM=3072 DISK=12 ./visionstate.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
REBUILD="${REBUILD:-0}"
# WICHTIG: kein umask 077 – pct create wuerde /var/lib/lxc/<ID> sonst mit 700
# anlegen und der unprivilegierte Extract (UID 100000) scheitert schon an der
# Pfad-Traversierung mit Permission denied (bewiesen: 755 geht, 700 kracht).
# Stattdessen normale Rechte; nur die Logdatei wird 600 (Root-Passwort drin).
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollstaendige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Log-Verweis)
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Vollstaendiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash visionstate.sh [OPTIONEN]
  CT_ID=150 bash visionstate.sh
  bash -c "\$(wget -qLO - ${INSTALLER_REPO}/../raw/main/install/visionstate.sh)"

Optionen:
  --ctid ID            Container-ID (Default: naechste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufaellig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container uebernehmen (optional)
  --rebuild            Frontend neu bauen (sonst nur wenn dist fehlt)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CT_ID="$CT_ID_ARG" HOSTNAME_ARG="$APP" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
STORAGE_ARG="" TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE" BRIDGE="$DEFAULT_BRIDGE"
PASSWORD_ARG="" SSH_KEY_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --password) PASSWORD_ARG="$2"; shift 2;;
    --rebuild) REBUILD="1"; shift;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Host-Pruefung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausfuehren."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }

# Immer naechste freie ID, ausser --ctid gesetzt
if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  msg_info "Naechste freie CT-ID: $CT_ID"
fi

# RootFS-Storage: Argument > local-lvm (wenn vorhanden) > erstes verfuegbares
if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status --storage local-lvm >/dev/null 2>&1; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content rootdir | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein RootFS-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Template-Store: $TEMPLATE_STORE | Bridge: $BRIDGE"

# ---------------------------------------------------------------------------
# 2. Template sicherstellen (neuestes debian-12-standard)
# ---------------------------------------------------------------------------
msg_info "Pruefe LXC-Template ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte – nutze vorhandene Templates."
AVAILABLE_TEMPLATES="$(pveam available --section system 2>/dev/null || true)"
# Hinweis: Proxmox liefert Templates heute als .tar.zst (nicht nur .tar.gz/.tar.xz).
TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_warn "Kein ${DEFAULT_OS}-Template – suche neuestes Debian-Standard-Template als Fallback ..."
  TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
fi
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_error "Kein Debian-Standard-Template gefunden. Verfuegbare System-Templates:"
  printf '%s\n' "$AVAILABLE_TEMPLATES" | head -n 20 >&2 || true
  msg_error "Bitte 'pveam update' manuell pruefen (Netz/DNS auf dem Host)."
  exit 1
fi
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Lade Template $TEMPLATE ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi
msg_ok "Template bereit: $TEMPLATE_STORE:vztmpl/$TEMPLATE"

# ---------------------------------------------------------------------------
# 3. Container erstellen (idempotent: existiert die ID, wird aktualisiert)
# ---------------------------------------------------------------------------
if pct status "$CT_ID" >/dev/null 2>&1; then
  msg_warn "CT $CT_ID existiert – ueberspringe Erstellung (Update-Modus)."
else
  # Stale Ueberrest frueherer Fehlversuche: Verzeichnis da, aber keine CT-Config.
  # Der unprivilegierte Extract (UID 100000) scheitert sonst mit Permission denied.
  if [[ -e "/var/lib/lxc/$CT_ID" ]]; then
    msg_warn "Stale Verzeichnis /var/lib/lxc/$CT_ID ohne CT-Config – raeume auf (Fehlversuch)."
    rm -rf "/var/lib/lxc/$CT_ID"
  fi
  [[ -z "$PASSWORD_ARG" ]] && PASSWORD_ARG="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  msg_info "Erstelle CT $CT_ID ($HOSTNAME_ARG): $CORES vCPU / $RAM MB / ${DISK}G ..."
  pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME_ARG" \
    --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot 1 --start 0 \
    --password "$PASSWORD_ARG"
  # Guertel-und-Hosentraeger: Traversierung fuer den unprivilegierten Extract
  # sicherstellen (fremde restriktive umask wuerde sonst 700 hinterlassen).
  chmod 755 "/var/lib/lxc/$CT_ID" 2>/dev/null || true
  msg_ok "CT $CT_ID erstellt (unprivilegiert, nesting, onboot=1)."
fi

pct start "$CT_ID" 2>/dev/null || true
msg_info "Warte auf Container-Netz ..."
CT_IP=""
for i in $(seq 1 24); do
  sleep 5
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${CT_IP:-}" ]] && break
done
[[ -n "${CT_IP:-}" ]] || { msg_error "Keine Container-IP (pct exec hostname -I). Netzwerk/Bridge pruefen."; exit 1; }
msg_ok "Container-IP: $CT_IP"

# SSH-Key erst nach Start (pct push/exec braucht laufenden Container)
if [[ -n "$SSH_KEY_ARG" ]]; then
  [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
  pct exec "$CT_ID" -- mkdir -p /root/.ssh
  pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys
  msg_ok "SSH-Key uebernommen."
fi

# ---------------------------------------------------------------------------
# 4. VisionState im Container (via pct exec, idempotent)
# ---------------------------------------------------------------------------
msg_info "Installiere VisionState im Container (uv Python 3.14 + venv + pip + npm-Build, ohne Docker) ..."
# Hinweis: aeussere Single-Quotes – der Block laeuft dadurch 1:1 im Container,
# ohne dass die Host-Shell $ oder $(...) anfasst (kein Escaping noetig).
pct exec "$CT_ID" -- env REBUILD="$REBUILD" bash -c '
# shellcheck disable=SC2034,SC2154
# SC2034: Pfad-Variablen unten sind Doku + Single-Source (Container-Block nutzt
# Literale, da aeussere Vars nicht per pct exec vererbt werden).
# SC2154: ec im trap-Handler ist Laufzeit, kein ungesetztes Literal.
set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates git build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libffi-dev liblzma-dev iproute2 procps
  id visionstate >/dev/null 2>&1 || useradd -m -s /bin/bash visionstate
  # ACHTUNG: In diesem Block sind KEINE einfachen Anfuehrungszeichen erlaubt,
  # weder in Befehlen noch in Kommentaren – sie wuerden den aeusseren
  # bash -c Block der Host-Shell sprengen und den Rest still abschneiden.
  if [ ! -x /root/.local/bin/uv ]; then
    curl -LsSf https://astral.sh/uv.sh | sh
  fi
  export PATH=/root/.local/bin:$PATH
  uv python install 3.14
  if [ ! -d /opt/visionstate/.git ]; then
    rm -rf /opt/visionstate
    git clone --branch main https://github.com/oleost/VisionState /opt/visionstate
  else
    git -C /opt/visionstate fetch origin
    git -C /opt/visionstate checkout main
    git -C /opt/visionstate pull --ff-only || true
  fi
  if [ ! -x /opt/visionstate/.venv/bin/python ]; then
    uv venv --python 3.14 /opt/visionstate/.venv
  fi
  /opt/visionstate/.venv/bin/pip install --upgrade pip
  /opt/visionstate/.venv/bin/pip install -r /opt/visionstate/visionstate/backend/requirements.txt
  if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
  fi
  if [ ! -d /opt/visionstate/visionstate/frontend/dist ] || [ "${REBUILD:-0}" = 1 ]; then
    cd /opt/visionstate/visionstate/frontend
    npm ci --no-audit --no-fund
    npm run build
    cd /opt/visionstate/visionstate/backend
  fi
  mkdir -p /var/lib/visionstate /var/lib/visionstate-media /etc/visionstate
  if [ -z "$(ls -A /var/lib/visionstate/models 2>/dev/null || true)" ]; then
    cd /opt/visionstate/visionstate/backend
    VISIONSTATE_BUNDLED_MODELS=/var/lib/visionstate/models /opt/visionstate/.venv/bin/python -m visionstate.backbones /var/lib/visionstate/models
  fi
  chown -R visionstate:visionstate /opt/visionstate /var/lib/visionstate /var/lib/visionstate-media
'
# Hinweis: bewusst kein "| tail" hier – mit pipefail wuerde der trap sonst
# die Pipe (tail) statt des gescheiterten pct-Befehls melden. Voll-Output steht im Log.

# Host-seitiger Guard: bricht laut ab, falls das venv unvollstaendig ist.
pct exec "$CT_ID" -- test -x /opt/visionstate/.venv/bin/python \
  || { msg_error "Installation unvollstaendig: /opt/visionstate/.venv/bin/python fehlt im Container."; exit 1; }
pct exec "$CT_ID" -- test -d /opt/visionstate/visionstate/frontend/dist \
  || { msg_error "Installation unvollstaendig: Frontend-Dist fehlt (npm-Build)."; exit 1; }
msg_ok "Checkout ok (venv + Frontend-Dist vorhanden)."

# Env-File nur beim Erst-Setup schreiben (Update behaelt HA_TOKEN/MQTT-Einstellungen)
if pct exec "$CT_ID" -- test -f /etc/visionstate/env; then
  msg_ok "Env-File existiert – behalten (/etc/visionstate/env)."
else
  pct push "$CT_ID" /dev/stdin /etc/visionstate/env <<'ENV_EOF'
VISIONSTATE_PORT=8099
VISIONSTATE_DATA=/var/lib/visionstate
VISIONSTATE_MEDIA=/var/lib/visionstate-media
VISIONSTATE_FRONTEND=/opt/visionstate/visionstate/frontend/dist
VISIONSTATE_BUNDLED_MODELS=/var/lib/visionstate/models
VISIONSTATE_MQTT_HOST=
VISIONSTATE_MQTT_PORT=1883
HA_URL=
HA_TOKEN=
ENV_EOF
  pct exec "$CT_ID" -- chown root:visionstate /etc/visionstate/env
  pct exec "$CT_ID" -- chmod 640 /etc/visionstate/env
  msg_ok "Env-File geschrieben (/etc/visionstate/env, 640)."
fi

# systemd-Unit aus diesem Repo uebernehmen (faellt auf Inline-Unit zurueck)
if pct exec "$CT_ID" -- curl -fsSL -o /etc/systemd/system/visionstate.service "$SERVICE_URL" 2>/dev/null; then
  msg_ok "visionstate.service aus Repo uebernommen."
else
  msg_warn "Service-URL nicht erreichbar – schreibe Inline-Unit."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/visionstate.service <<'UNIT'
[Unit]
Description=VisionState – lokale KI-Kamera-Sensoren fuer Home Assistant
Documentation=https://github.com/oleost/VisionState
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=visionstate
Group=visionstate
WorkingDirectory=/opt/visionstate/visionstate/backend
EnvironmentFile=/etc/visionstate/env
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/visionstate/.venv/bin/python -m visionstate
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
fi
pct exec "$CT_ID" -- systemctl daemon-reload
pct exec "$CT_ID" -- systemctl enable --now visionstate
pct exec "$CT_ID" -- systemctl restart visionstate
msg_ok "systemd-Service visionstate aktiviert (enable --now + restart)."

# ---------------------------------------------------------------------------
# 5. Verifikation: Service + Web UI
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
pct exec "$CT_ID" -- systemctl is-active visionstate || { msg_error "systemd-Service visionstate ist nicht active."; pct exec "$CT_ID" -- systemctl status visionstate --no-pager || true; exit 1; }
msg_ok "Service laeuft (systemctl is-active visionstate = active)."

msg_info "Warte auf Web UI (max. 10 Min, Modell-Ladezeit) ..."
WEB_OK=0
for _ in $(seq 1 60); do
  if pct exec "$CT_ID" -- curl -fs -m 10 "http://localhost:${APP_PORT}/api/v1/status" >/dev/null 2>&1; then WEB_OK=1; break; fi
  sleep 10
done
[[ "$WEB_OK" == "1" ]] \
  || { msg_error "Web UI antwortet nicht auf localhost:${APP_PORT}/api/v1/status."; pct exec "$CT_ID" -- systemctl status visionstate --no-pager || true; pct exec "$CT_ID" -- journalctl -u visionstate --no-pager -n 100 || true; pct exec "$CT_ID" -- curl -v "http://127.0.0.1:${APP_PORT}/api/v1/status" || true; exit 1; }
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${APP_PORT}/api/v1/status)."

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : VisionState – lokale KI-Kamera-Sensoren"
echo "  Upstream     : $UPSTREAM_REPO"
echo "  Container    : CT $CT_ID (Hostname: $HOSTNAME_ARG, unprivilegiert, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : http://${CT_IP}:${APP_PORT}"
echo "  Health       : http://${CT_IP}:${APP_PORT}/api/v1/status"
echo "  Root-Passwort: ${PASSWORD_ARG:-<bestehender CT, un Veraendert>} (nur jetzt angezeigt!)"
echo "  Service      : systemctl status visionstate  (im Container via: pct enter $CT_ID)"
echo "  Env          : /etc/visionstate/env (VISIONSTATE_MQTT_HOST/HA_URL optional setzen, dann restart)"
echo "  Daten        : /var/lib/visionstate + /var/lib/visionstate-media (Backup!)"
echo "  Update       : Skript erneut laufen lassen (idempotent, git pull + pip + rebuild + restart)"
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Reboot-Test  : pct reboot $CT_ID && sleep 60 && curl -fs http://${CT_IP}:${APP_PORT}/api/v1/status"
echo "  WARNUNG      : Ausserhalb von Home Assistant kein Login – nur im LAN oder hinter Proxy mit Auth!"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
