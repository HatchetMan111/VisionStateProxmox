# VisionState auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil)

> Upstream-App (kein Teil dieses Ordners): `https://github.com/oleost/VisionState`
> (lokale KI die Kamerabilder in Home-Assistant-Sensoren verwandelt – states/objects/readings,
> DINOv2 ONNX + D-FINE + PaddleOCR, 100% lokal, CPU-only, Apache-2.0)
> Dieser Ordner enthält **nur den Proxmox-Installer**: Install-Script + systemd-Unit.
> Die App läuft nativ (Python 3.14 via uv + venv + pip, Frontend-Build mit Node, ohne Docker) –
> vollständig lokal, keine Cloud nötig.

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VisionStateProxmox/main/install/visionstate.sh)"
```

Installer-Repo: `https://github.com/HatchetMan111/VisionStateProxmox`.
(Unit lädt das Script von dort; ohne Netz greift der Inline-Fallback.)

Anpassungen per Umgebungsvariable oder Flag (ID immer **nächste freie**, außer gesetzt):

```bash
CT_ID=150 CORES=2 RAM=3072 DISK=12 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VisionStateProxmox/main/install/visionstate.sh)"
bash visionstate.sh --ctid 150 --cores 2 --memory 3072 --disk 12 --bridge vmbr0 --storage local-lvm
bash visionstate.sh --ctid 100 --rebuild   # Update inkl. Frontend-Neubau
bash visionstate.sh --debug   # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/visionstate-install-*.log
```

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `visionstate` |
| Zweck | Lokale KI-Kamera-Sensoren: eigene States anlernen (Garagentor offen/zu), Objekte finden (Person/Auto/Tier), Zahlen ablesen (Zähler/Display) |
| Tech-Stack | Python 3.14 (uv) + venv `/opt/visionstate/.venv` + `pip install -r visionstate/backend/requirements.txt`, Frontend Svelte+Vite (`npm ci && npm run build` → `visionstate/frontend/dist`), Modelle via `python -m visionstate.backbones` |
| GitHub-Repo (Upstream) | `https://github.com/oleost/VisionState` |
| Web UI | `http://<LXC-IP>:8099` (bind `0.0.0.0:8099`), Health = `GET /api/v1/status` |
| Standard-Ressourcen | 2 vCPU / 3072 MB RAM / 12 GB Disk (Modelle + Build brauchen mehr als 4–8 GB Minimum) |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | **unprivilegiert** (`--unprivileged 1`), `nesting=1`, `onboot: 1` |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage
   (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `visionstate` (`onboot: 1`, unprivilegiert),
3. installiert im Container uv + Python 3.14 + venv, legt User `visionstate` an,
   klont Upstream nach `/opt/visionstate`, installiert Backend (`pip`),
   baut das Frontend (`npm ci && npm run build`), lädt die Modelle nach
   `/var/lib/visionstate/models`, legt `/etc/visionstate/env` (640) und
   `/var/lib/visionstate` + `/var/lib/visionstate-media` an,
   schreibt `visionstate.service`, `systemctl enable --now visionstate`,
4. verifiziert `systemctl is-active visionstate` + HTTP auf `localhost:8099/api/v1/status`
   und gibt die finale URL + Container-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active visionstate = active).
[OK]    Web UI antwortet (HTTP 200 auf localhost:8099/api/v1/status).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : VisionState – lokale KI-Kamera-Sensoren
  Container    : CT 100 (Hostname: visionstate, unprivilegiert, onboot=1)
  Ressourcen   : 2 vCPU / 3072 MB RAM / 12 GB Disk
  Web UI       : http://192.168.1.100:8099
  ...
  WARNUNG      : Ausserhalb von Home Assistant kein Login – nur im LAN oder hinter Proxy mit Auth!
  Log          : /tmp/visionstate-install-2026-....log
══════════════════════════════════════════════════════════
```

Eigene Nutzung: Kamera als `camera.*` (HA) oder RTSP/HTTP-Snapshot-URL in der Web UI anlegen.
Sensor anlegen, Labeln, Trigger, Review-Queue, History: alles in der Web UI
(`http://<LXC-IP>:8099`). Nur die HA-Anbindung selbst steht in `/etc/visionstate/env`
(siehe unten) – kein UI-Feld (Henne-Ei: ohne Broker keine Publikation, Token gehoert nicht
in ein login-loses Webformular).
Vollständige Anleitung (Sensor anlegen, Trigger, Review-Queue): Upstream `visionstate/DOCS.md`.

## Home Assistant anbinden (MQTT + Kameras)

Voraussetzungen in HA: **Mosquitto broker**-Add-on (+ dort ein Login, z. B. User
`visionstate`) und die **MQTT**-Integration (Host `core-mosquitto` bzw. HA-IP, Port 1883,
gleiche Credentials). Langlebigen Token holen: HA → Profil → Sicherheit →
**Langlebige Zugriffstoken**.

Dann im Container (`pct enter <CT>`), `/etc/visionstate/env` editieren:

```text
VISIONSTATE_MQTT_HOST=192.168.x.x      # IP des Home Assistant
VISIONSTATE_MQTT_PORT=1883
VISIONSTATE_MQTT_USERNAME=visionstate
VISIONSTATE_MQTT_PASSWORD=<mosquitto-passwort>
HA_URL=http://192.168.x.x:8123
HA_TOKEN=<langlebiger-token>
```

Danach:

```bash
systemctl restart visionstate
journalctl -u visionstate -n 30   # MQTT "connected", keine Auth-Fehler
```

Prüfen: In der Web UI stehen alle `camera.*`-Entitäten zur Wahl; in HA erscheinen
die Sensoren automatisch via MQTT-Discovery (z. B. `sensor.garage_door` + Confidence,
letztes Bild, Check-now-Button, Enable-Switch). Beispiel-Automation: siehe Upstream-README
(„Example: notify when the garage door has been open for 10 minutes").

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 60
pct exec $CT -- systemctl is-active visionstate
curl -fs http://<LXC-IP>:8099/api/v1/status >/dev/null && echo WEB_UI_OK
```

Erwartet: `active` + `WEB_UI_OK`. Beleg: `journalctl -u visionstate -n 50`
im Container zeigt Neustart nach Reboot.

## Update / Deinstall

```bash
bash visionstate.sh --ctid 100            # Update: idempotent (git pull + pip + restart; /etc/visionstate/env bleibt!)
bash visionstate.sh --ctid 100 --rebuild  # Update inkl. Frontend-Neubau (sonst nur wenn dist fehlt)
pct stop 100 && pct destroy 100          # Deinstall (vorher /var/lib/visionstate* sichern!)
```

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code aus, Voll-Log unter `/tmp/visionstate-install-*.log`.
- `bash visionstate.sh --debug` für `bash -x`-Trace.
- Im Container: `systemctl status visionstate --no-pager`, `journalctl -u visionstate -n 100`,
  Health prüfen: `curl -v http://127.0.0.1:8099/api/v1/status`,
  Env prüfen: `cat /etc/visionstate/env` (kein `HA_TOKEN` ins Log posten!).

## Dateien

- `install/visionstate.sh` – Proxmox-Einzeiler (Host, root).
- `systemd/visionstate.service` – Unit (`After=network-online.target`, `Restart=always`, User `visionstate`).
