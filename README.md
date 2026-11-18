# 🧠 CodexAI-Server

**OpenAI Codex als dauerhaft laufende Session im Proxmox-LXC** – das originale
Codex-TUI, erreichbar im Netz über ein Web-Terminal (ttyd) im Browser.

Genau wie [ZCodeAI-Server](https://github.com/HatchetMan111/ZCodeAI-Server) und
[ClaudeCode-Proxmox](https://github.com/HatchetMan111/ClaudeCodeServerProxmox)
gebaute: ein Einzeiler, der einen unprivilegierten Debian-12-LXC erzeugt und
darin die **offizielle Codex-CLI** (Rust-Binary aus den
[openai/codex Releases](https://github.com/openai/codex/releases),
SHA-256-verifiziert, kein Node/npm nötig) als **systemd-Dauersession**
installiert.

---

## ⚡ Installation (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CodexAI-Server/main/install/codex-ai-server.sh)"
```

Das Script:

- wählt die nächste freie CT-ID (ab 200) und erstellt einen unprivilegierten
  LXC `codex-ai-server` (Debian 12, 2 vCPU, 4 GB RAM, 16 GB Disk, `onboot=1`,
  `nesting=1`)
- installiert die offizielle Codex-CLI als **packaged CLI** über den
  offiziellen Standalone-Installer (`chatgpt.com/codex/install.sh` – der
  verifiziert die Downloads selbst gegen `codex-package_SHA256SUMS` und
  legt das Paket-Layout unter `~/.codex/packages/standalone` an)
- installiert **ttyd 1.7.7** (statisch, SHA256SUMS-geprüft) als Web-Terminal
- richtet **systemd-Units** ein: `codex-ai-session.service` (tmux-Session
  `codex` mit Respawn-Wrapper) + `codex-ai-web.service` (ttyd auf 0.0.0.0:8091)
- verifiziert alles selbst (Services aktiv, `codex --version`, HTTP 200) und
  gibt URL + Zugangsdaten aus

### Optionen (hinter dem schließenden Anführungszeichen anhängen)

| Option | Default | Bedeutung |
|---|---|---|
| `--id N` | nächste freie ab 200 | CT-ID |
| `--hostname NAME` | `codex-ai-server` | CT-Hostname (Identität für `--update`) |
| `--storage NAME` | `local-lvm` | Storage für rootfs |
| `--rootfs GB` | 16 | Disk-Größe |
| `--cores N` | 2 | vCPUs |
| `--memory MB` | 4096 | RAM |
| `--swap MB` | 512 | Swap |
| `--bridge BR` | `vmbr0` | Netzwerk-Bridge |
| `--ip CIDR` + `--gateway GW` | DHCP | statische IP |
| `--password PW` | automatisch | Root-Passwort des CT |
| `--port PORT` | 8091 | Web-Terminal-Port im CT |
| `--codex-version VER` | `latest` | feste Version z. B. `0.170.0`; `latest` = immer neuste |
| `--api-key KEY` | – | `OPENAI_API_KEY` + non-interaktiver Login |
| `--webui` | – | zusätzlich die **CloudCLI-Web-UI** installieren (moderne Chat-Oberfläche für Codex, Port 8092, Node 22 wird mitgeliefert) |
| `--webui-port PORT` | 8092 | Port der Web-UI im CT |
| `--webui-only` | – | nur die Web-UI im bestehenden CT nachrüsten |
| `--force` | – | bestehenden CT löschen + neu anlegen (nächste freie ID) |
| `--yes / -y` | – | Rückfragen überspringen |
| `--update` / `--uninstall` / `--status` / `--debug` | – | Verwaltungsmodi |

---

## 🔑 Codex-Login (einmalig, nach der Installation)

Codex läuft direkt nach der Installation – der **Login** ist die einzige
Benutzer-Aufgabe (im Web-Terminal oder per `pct enter`):

1. **Device-Code (empfohlen – kein lokaler Browser im CT nötig):**
   ```bash
   codex login --device-auth
   ```
   Codex zeigt eine **URL + einen Code**. URL von einem beliebigen Gerät
   (Desktop/Handy) öffnen, Code eingeben, mit dem ChatGPT-Konto anmelden.
   *(Device-Auth ist ein Beta-Feature – ggf. in den ChatGPT-Sicherheitseinstellungen
   einmal freischalten.)*

2. **OAuth wie am Desktop (via SSH-Tunnel):**
   ```bash
   ssh -L 1455:localhost:1455 root@<CT-IP>
   # in der SSH-Session:
   codex login
   ```
   Die OAuth-URL im lokalen Browser öffnen – der Callback (localhost:1455)
   läuft über den Tunnel zurück in den Container.

3. **API-Key (Abrechnung über OpenAI-Platform statt ChatGPT-Plan):**
   ```bash
   printenv OPENAI_API_KEY | codex login --with-api-key
   ```
   oder direkt beim Installer: `... " --api-key sk-...`

Status/Abmelden: `codex login status` / `codex logout`. Die Hilfe liegt auch
im Container: `/opt/codex-ai/LOGIN-HINWEISE`.

---

## 🖥️ Bedienung

- **Web-Terminal:** `http://<CT-IP>:8091` (Basic-Auth `codex` / generiertes
  Passwort aus der Install-Summary) → das originale Codex-TUI; die tmux-Session
  läuft weiter, auch wenn der Browser geschlossen wird.
- **Konsole:** `pct enter <CT-ID>` → `tmux attach -t codex`
- **Workspace:** `/root/codex-workspace` (im CT) – hier arbeitet Codex.
- Reboot-sicher: CT startet mit dem Host (`onboot=1`), systemd startet beide
  Units, der Respawn-Wrapper startet Codex neu, falls die Session beendet wird.

## 🖥️ Zusätzliche Web-UI: CloudCLI (claudecodeui)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CodexAI-Server/main/install/codex-ai-server.sh)" --webui
```

Installiert zusätzlich zur ttyd-Terminal-UI die **CloudCLI-Web-UI**
([siteboon/claudecodeui](https://github.com/siteboon/claudecodeui) – React-Chat-Oberfläche,
Session-Verlauf, Datei-Explorer, mobil-tauglich) unter `http://<CT-IP>:8092`:

- läuft als eigener systemd-Service `codex-ai-ui.service` (Node 22 nach
  `/opt/node22`, SHA256-geprüft; npm-Paket `@cloudcli-ai/cloudcli`)
- nutzt **dieselbe Codex-Installation + denselben Login** wie das Terminal
  (`~/.codex/auth.json` – die UI nimmt die neuere System-Installation, nicht
  ihr gebündeltes Codex)
- **Beim ersten Öffnen ein Konto anlegen** (lokal gespeichert in
  `/opt/codex-ai/cloudcli/auth.db`), danach damit einloggen
- Im bestehenden CT nachrüsten: `... " --webui-only` · beim `--update` wird
  eine installierte Web-UI automatisch mitschaltet und aktualisiert

## 🔄 Update

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CodexAI-Server/main/install/codex-ai-server.sh)" --update
```

Installiert die (per `--codex-version` gewählte, Default `latest`) Version im
bestehenden CT neu. Login (`~/.codex`), `codex.env` und Workspace bleiben
erhalten; das Web-Terminal-Passwort wird vom CT übernommen.

## 🗑️ Deinstallation

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CodexAI-Server/main/install/codex-ai-server.sh)" --uninstall
```

Stoppt und löscht den CT inkl. Login-Daten und Workspace (`--uninstall --yes`
überspringt die Rückfrage).

## 🐞 Debugging

Bei Fehlern gibt das Script die **komplette Fehlerkette** aus (Zeile, Befehl,
Exit-Code, Log-Auszüge, Container-Logs) und behält den CT zur Inspektion.
Voller Trace:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CodexAI-Server/main/install/codex-ai-server.sh)" --debug
```

## ℹ️ Warum der Standalone-Installer?

Die nackte musl-Binary aus den GitHub-Releases
(`codex-x86_64-unknown-linux-musl.tar.gz`) ist **keine vollwertige
Installation** – die Codex-TUI startet einen Hintergrund-Daemon und braucht
das `codex-package`-Asset (mit `codex-code-mode-host`, `rg`, `bwrap` und
`codex-package.json`), sonst bricht sie mit
`Error: this CLI has no complete local package` ab (Live-Fund 2026-11-18).
Der offizielle Standalone-Installer baut exakt dieses Paket-Layout auf.

## ⚠️ Sicherheit

Das Web-Terminal ist ein **Root-Terminal im Container** und Codex ist ein
Agent mit Shell-Zugriff. Port 8091 **nicht** ohne VPN/Firewall ins Internet
exposen – die Basic-Auth ist kein Vollschutz.

## 🧪 Tests

Mock-Harness ohne Proxmox-Host (alle `pct`/`curl`/`systemctl`/…-Aufrufe
gemockt):

```bash
tests/run-tests.sh
```

## Lizenz

MIT (siehe LICENSE). Die installierten Komponenten unterliegen eigenen
Lizenzen – Codex: Apache-2.0 (openai/codex), ttyd: MIT, CloudCLI-Web-UI:
AGPL-3.0 (siteboon/claudecodeui).
