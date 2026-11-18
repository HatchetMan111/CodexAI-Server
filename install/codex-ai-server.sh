#!/usr/bin/env bash
# =============================================================================
#  🧠 CodexAI-Server – One-Click-Installer (Proxmox VE)
#  https://github.com/HatchetMan111/CodexAI-Server
#
#  Erstellt einen unprivilegierten LXC-Container und installiert darin
#  OpenAI Codex (https://openai.com/codex/) als DAUERHAFT LAUFENDE Session:
#    - offizielle Codex-CLI (Rust-Binary aus den GitHub-Releases von
#      openai/codex, SHA-256-verifiziert – kein Node/npm nötig)
#    - tmux-Session „codex“ unter systemd (Respawn-Wrapper, Autostart onboot)
#    - ttyd-Webterminal (mit Basic-Auth-Passwort) als Web-UI auf die Live-
#      Session → das originale Codex-TUI im Browser
#
#  Installation (auf dem Proxmox-Host als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CodexAI-Server/main/install/codex-ai-server.sh)"
#
#  Mit Optionen (direkt hinter dem schließenden Anführungszeichen):
#    ... " --api-key sk-... --memory 4096
#
#  Update / Deinstall / Status / Debug:
#    ... " --update        |  ... " --uninstall  |  ... " --status  |  ... " --debug
#
#  Hinweis: Der Codex-Login (ChatGPT-Account ODER API-Key) passiert nach der
#  Installation in der Web-Session – die Installation richtet alles andere
#  ein. --update erneuert die Codex-Version; Login (~/.codex) und Workspace
#  bleiben erhalten.
# =============================================================================

# shellcheck disable=SC1111  # deutsche Anführungszeichen sind Absicht
set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
APP_NAME="codexai"
REPO_OWNER="HatchetMan111"
REPO_NAME="CodexAI-Server"
REPO_BRANCH="main"
CODEX_VERSION="0.170.0"     # gepinnte Version (Default); auch "latest" oder z. B. 0.171.0
CODEX_SHA256="d054916ccd28a53820376b8d2f7c875184ca8f40fcd44bbabeb8ee240ce247f5"
                            # SHA-256 von codex-x86_64-unknown-linux-musl.tar.gz @ rust-v0.170.0
                            # (gegen die GitHub-API digest-Feld verifiziert); gilt nur für die
                            # gepinnte Version – andere Versionen verifizieren via API-Digest
TTYD_VERSION="1.7.7"        # Web-Terminal-Binary (statisch, GitHub-Release)
TTYD_USER="codex"           # Basic-Auth-User für das Web-Terminal
CT_ID=""                    # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_HOSTNAME="codex-ai-server"
CT_STORAGE="local-lvm"
CT_ROOTFS=16                # GB – Codex-Binary (~290 MB entpackt) + ~/.codex + Workspace
CT_CORES=2
CT_MEMORY=4096              # MB – aktive Agent-Läufe (git, Builds im Workspace) brauchen Luft
CT_SWAP=512
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_GATEWAY=""               # nur bei statischer IP nötig, z. B. 192.168.1.1
CT_PASSWORD=""              # leer = automatisch generieren
PORT=8091                   # Web-Terminal-Port im Container
API_KEY=""                  # optional: OPENAI_API_KEY (sonst Login per Device-Code/ChatGPT im 1. Lauf)
WEB_PASSWORD=""             # Basic-Auth-Passwort für ttyd (leer = automatisch)
UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
FORCE_RECREATE=false
ASSUME_YES=false
TMP_DIR=""
LOG_FILE="/tmp/${APP_NAME}-installer-$(date +%Y%m%d-%H%M%S).log"
# Der fertige Einzeiler für Hinweise/Fehlerausgaben – exakt kopierbar (Optionen
# hinter dem schließenden Anführungszeichen; der Installer erkennt sie via $0-Fallback)
ONE_LINER='bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CodexAI-Server/main/install/codex-ai-server.sh)"'

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerem TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Gibt bei Fehlern die KOMPLETTE Fehlerkette aus: Zeile, Befehl, Exit-Code,
# letzte Logzeilen sowie Container-Logs (Setup + Services), falls schon
# ein Container existiert.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup + Services):"
        pct exec "$CT_ID" -- sh -c '
            tail -n 40 /var/log/codex-ai-setup.log 2>/dev/null
            echo "--- journalctl codex-ai-session ---"
            journalctl -u codex-ai-session --no-pager 2>/dev/null | tail -n 15
            echo "--- journalctl codex-ai-web ---"
            journalctl -u codex-ai-web --no-pager 2>/dev/null | tail -n 15
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace (exakter Befehl):"
    echo "    ${ONE_LINER} --debug"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Debug-Modus (voller bash -x-Trace) ─────────────────────────────────────
# (Vor parse_args, damit --debug selbst noch mitgetraced wird.)
if [[ "${1:-}" == "--debug" || "$0" == "--debug" ]]; then
    set -x
fi

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
find_free_id() {
    local id="$ID_SCAN_START"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

find_ct_id_by_hostname() {
    pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" '$NF==h {print $1; exit}'
}

get_ct_ip() {
    # Grube (pipefail): bei pct-exec-Fehlschlag stirbt die Substitution –
    # deshalb || true INNERHALB von $().
    local ip=""
    ip=$(pct exec "$1" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
    echo "$ip"
}

ensure_ct_running() {
    # Verwaltungs-Pfade (--update/--status) müssen einen GESTOPPTEN CT selbst
    # starten – pct exec auf gestopptem CT → Exit 255.
    local id="$1"
    if pct status "$id" 2>/dev/null | grep -q "status: running"; then
        return 0
    fi
    info "Container ist gestoppt – starte ihn ..."
    pct start "$id"
    wait_for_ct_network "$id"
}

wait_for_ct_network() {
    # Nach pct create --start nicht blind sleep 3 (DHCP/DNS-Race) – aktiv pollen.
    local id="$1" tries=0 ip=""
    info "Warte auf Netzwerk im Container (DHCP) ..."
    while true; do
        ip=$(get_ct_ip "$id")
        if [[ -n "$ip" ]]; then
            ok "Container-IP: $ip"
            return 0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 60 ]]; then
            err "Container hat nach 60 s keine IP bekommen."
            info "Prüfe: pct exec $id -- ip a   und DHCP am Bridge-Interface ($CT_BRIDGE)"
            return 1
        fi
        sleep 1
    done
}

verify_ct_dns() {
    # IP allein reicht nicht – der Codex-Download (github.com +
    # objects.githubusercontent.com), die Release-API (api.github.com), das
    # Repo-Tarball (codeload.github.com) und apt brauchen Namensauflösung.
    # DNS kann FLAKY sein: 3 Erfolge in Folge verlangen; eine Störung →
    # Fallback + Freeze.
    local id="$1" ok_count=0 tries=0
    info "Prüfe DNS im Container (3x hintereinander) ..."
    while true; do
        if pct exec "$id" -- getent hosts github.com api.github.com objects.githubusercontent.com >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            if [[ $ok_count -ge 3 ]]; then
                ok "DNS im Container funktioniert (3x bestätigt)"
                return 0
            fi
        else
            ok_count=0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 10 ]]; then
            break
        fi
        sleep 2
    done
    # Fallback: DNS des Hosts (falls nicht loopback) + öffentliche Resolver eintragen
    local host_ns ns_list
    host_ns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    ns_list="1.1.1.1 8.8.8.8"
    if [[ -n "$host_ns" ]]; then
        ns_list="$host_ns $ns_list"
    fi
    warn "DNS im Container defekt – schreibe Fallback-Nameserver ($ns_list) nach /etc/resolv.conf"
    pct exec "$id" -- sh -c "printf 'nameserver %s\n' $ns_list > /etc/resolv.conf"
    # Dauerhaft: dhclient-Hook (verhindert das Überschreiben durch Lease-Renewals —
    # chattr +i funktioniert in unprivilegierten LXCs nicht) + nochmal prüfen.
    pct exec "$id" -- bash -c 'mkdir -p /etc/dhcp/dhclient-enter-hooks.d && printf "make_resolv_conf() { :; }\n" > /etc/dhcp/dhclient-enter-hooks.d/no-dns'
    if pct exec "$id" -- getent hosts github.com api.github.com objects.githubusercontent.com >/dev/null 2>&1; then
        ok "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt – Auflösung funktioniert"
        return 0
    fi
    die "DNS im Container weiterhin ohne Funktion (auch mit Fallback).\n  Prüfe: pct exec $id -- getent hosts github.com api.github.com objects.githubusercontent.com\n  Firewall/Router: ausgehende DNS-Anfragen (Port 53) am Bridge-Netz erlauben."
}

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    # Grube (bash -c): `bash -c "$(wget -qLO - URL)" --id 5` belegt das ERSTE
    # Argument nach dem Script-String mit $0, nicht $1 – die Option würde
    # still geschluckt. Fallback: startet $0 mit "-", ist es eine Option.
    local args=("$@")
    if [[ "$0" == -* ]]; then
        args=("$0" "$@")
    fi
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --id)            CT_ID="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --hostname)      CT_HOSTNAME="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --storage)       CT_STORAGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --rootfs)        CT_ROOTFS="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --cores)         CT_CORES="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --memory)        CT_MEMORY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --swap)          CT_SWAP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --bridge)        CT_BRIDGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --ip)            CT_IP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --gateway)       CT_GATEWAY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --password)      CT_PASSWORD="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --port)          PORT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --codex-version) CODEX_VERSION="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --api-key)       API_KEY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --force)         FORCE_RECREATE=true; i=$((i+1)) ;;
            --yes|-y)        ASSUME_YES=true; i=$((i+1)) ;;
            --update)        UPDATE=true; i=$((i+1)) ;;
            --uninstall)     UNINSTALL=true; i=$((i+1)) ;;
            --status)        STATUS_CHECK=true; i=$((i+1)) ;;
            --debug)         set -x; i=$((i+1)) ;;
            --help|-h)       print_help; exit 0 ;;
            *) die "Unbekannte Option: ${args[$i]}  (--help zeigt alle Optionen)" ;;
        esac
    done
}

print_help() {
    cat <<EOF
🧠 CodexAI-Server – Proxmox-Installer (OpenAI Codex als dauerhafte Session im LXC)

Installation:   bash -c "\$(wget -qLO - https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/install/codex-ai-server.sh)"

Optionen (hinter dem schließenden Anführungszeichen anhängen, z. B. ... " --id 210):
  --id ID               Container-ID (Default: nächste freie ab 200)
  --hostname NAME       Container-Hostname (Default: codex-ai-server)
  --storage NAME        Storage für rootfs (Default: local-lvm)
  --rootfs GB           Disk-Größe (Default: 16)
  --cores N             vCPUs (Default: 2)
  --memory MB           RAM (Default: 4096)
  --swap MB             Swap (Default: 512)
  --bridge BR           Netzwerk-Bridge (Default: vmbr0)
  --ip CIDR             Statt DHCP, z. B. 192.168.1.50/24 (+ --gateway 192.168.1.1)
  --gateway GW          Gateway für statische IP
  --password PW         Root-Passwort des CT (Default: automatisch generiert)
  --port PORT           Web-Terminal-Port im Container (Default: 8091)
  --codex-version VER   Codex-Version (Default: ${CODEX_VERSION}; auch "latest" oder z. B. 0.171.0)
  --api-key KEY         OPENAI_API_KEY setzen + direkten Login (sonst Login per
                        Device-Code im Web-Terminal – ChatGPT-Plan ODER API-Key)
  --force               Vorhandenen Container mit gleichem Hostname löschen und neu anlegen
  --yes / -y            Rückfragen überspringen
  --update              Codex-Version im bestehenden Container erneuern (Login bleibt)
  --uninstall           Container stoppen und löschen (inkl. Session-Daten!)
  --status              Status anzeigen
  --debug               Vollständiges bash -x-Trace

  Modus:  Install (Default) / --update / --uninstall / --status / --debug
EOF
}

# ── In-Container-Setup-Script (idempotent) ─────────────────────────────────
write_inner_script() {
    cat > "$TMP_DIR/setup-inner.sh" <<INNEREOF
#!/usr/bin/env bash
# =============================================================================
# CodexAI-Server In-Container-Setup (idempotent – safe für Update & Re-Run)
# Installiert die offizielle Codex-CLI (Rust-Binary aus den GitHub-Releases)
# + ttyd-Webterminal und richtet die dauerhafte tmux-Session unter systemd ein.
# =============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C   # verhindert perl/locale-Warnungen im frischen Debian-CT

echo ">>> Basis-Pakete (tmux, curl, git) ..."
apt-get update -qq
# curl braucht das nackte Debian-Template vorher NICHT – deshalb apt zuerst.
# git: Codex arbeitet direkt im Workspace (Diffs, Commits). procps liefert pgrep/pkill.
apt-get install -y -qq tmux curl ca-certificates git procps >/dev/null

echo ">>> Installer-Tarball laden (systemd-Units aus diesem Repo) ..."
curl -fsSL --retry 3 "https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${REPO_BRANCH}" -o /tmp/codexai-installer.tar.gz
rm -rf /tmp/codexai-src && mkdir -p /tmp/codexai-src
tar -xzf /tmp/codexai-installer.tar.gz -C /tmp/codexai-src --strip-components=1

echo ">>> Nameserver festschreiben (DHCP-DNS des Netzes kann flaky sein) ..."
mkdir -p /etc/dhcp/dhclient-enter-hooks.d
printf '# CodexAI-Server: resolv.conf nicht von DHCP überschreiben lassen\nmake_resolv_conf() { :; }\n' > /etc/dhcp/dhclient-enter-hooks.d/no-dns
printf 'domain home.arpa\nsearch home.arpa\nnameserver %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n' "\${HOST_DNS:-1.1.1.1}" > /etc/resolv.conf

echo ">>> Codex (\${CODEX_VERSION}) installieren – offizielles Release-Binary (SHA-256-verifiziert) ..."
# Die Codex-CLI ist eine statische Rust-Binary (musl): kein Node/npm nötig.
# Quelle: openai/codex GitHub-Releases, Tag rust-v<version>.
# Verifikation: 1) gegen den gepinnten SHA-256 im Installer, 2) fallback gegen
# das "digest"-Feld der GitHub-Release-API (für Versionen ohne Pin).
CODEX_TARBALL="codex-x86_64-unknown-linux-musl.tar.gz"
DL_URL_BASE="https://github.com/openai/codex/releases/download"
REL_JSON="/tmp/codex-release.json"
VER="\${CODEX_VERSION}"
SUM="\${CODEX_SHA256}"
if [[ "\${VER}" != "\${CODEX_PINNED_VERSION}" ]]; then
    SUM=""   # der Pin gilt nur für die gepinnte Version
fi

fetch_digest() {
    # Liest das sha256-Digest des Codex-Tarballs aus der GitHub-Release-API.
    # Das digest-Feld liegt im selben Asset-Objekt wie der Name – Fenster von
    # 4000 Zeichen nach dem Namen per awk (kein jq nötig). Bewusst OHNE
    # Interval-Regex ({64}): mawk (Debian-Default) unterstützt die nicht.
    local tag="\$1"
    curl -fsSL --retry 3 "https://api.github.com/repos/openai/codex/releases/tags/rust-v\${tag}" -o "\$REL_JSON" || return 1
    awk -v needle='"name":"codex-x86_64-unknown-linux-musl.tar.gz"' '
        index(\$0, needle) {
            rest = substr(\$0, index(\$0, needle) + length(needle), 4000)
            p = index(rest, "\"digest\":\"sha256:")
            if (p > 0) {
                print substr(rest, p + 17, 64)
                exit
            }
        }' "\$REL_JSON"
}

if [[ "\${VER}" == "latest" ]]; then
    curl -fsSL --retry 3 "https://api.github.com/repos/openai/codex/releases/latest" -o "\$REL_JSON"
    TAG=\$(awk -F'"' '{ for (i = 1; i < NF; i++) if (\$i == "tag_name" && \$(i+2) ~ /^rust-v/) { v = \$(i+2); sub(/^rust-v/, "", v); print v; exit } }' "\$REL_JSON")
    if [[ -z "\$TAG" ]]; then
        echo "FEHLER: Konne den neuesten Release-Tag nicht aus der GitHub-API lesen."
        echo "  Rate-Limit? Manuell prüfen: https://github.com/openai/codex/releases/latest"
        echo "  Oder feste Version setzen: ${ONE_LINER} --codex-version 0.170.0"
        exit 12
    fi
    VER="\$TAG"
    SUM=""
    echo ">>> Neueste Codex-Version laut GitHub-API: \${VER}"
fi

# Bereits installierte Version überspringen (Update ohne Re-Download)
if [[ -x /usr/local/bin/codex ]]; then
    CUR_VER=\$(/usr/local/bin/codex --version 2>/dev/null || true)
    if grep -q "codex-cli \${VER}" <<< "\$CUR_VER"; then
        echo ">>> Codex \${VER} ist bereits installiert – Download übersprungen."
    else
        CUR_VER=""
    fi
fi

if [[ -z "\${CUR_VER:-}" ]]; then
    curl -fsSL --retry 3 "\${DL_URL_BASE}/rust-v\${VER}/\${CODEX_TARBALL}" -o /tmp/codex.tar.gz
    ACTUAL_SUM=\$(sha256sum /tmp/codex.tar.gz | awk '{print \$1}')
    if [[ "\${SUM}" != "\${ACTUAL_SUM}" ]]; then
        echo ">>> Pin trifft nicht (oder fehlt) – verifiziere gegen das digest-Feld der GitHub-Release-API ..."
        SUM=\$(fetch_digest "\${VER}" || true)
        if [[ -z "\$SUM" ]]; then
            echo "FEHLER: SHA-256 nicht ermittelbar (Pin + GitHub-API beide ohne Treffer)."
            echo "  Rate-Limit? Später erneut oder feste Version setzen."
            exit 12
        fi
    fi
    if [[ "\${SUM}" != "\${ACTUAL_SUM}" ]]; then
        echo "FEHLER: SHA-256-MISMATCH beim Codex-Tarball – Download verworfen."
        echo "  Erwartet: \${SUM}"
        echo "  Erhalten: \${ACTUAL_SUM}"
        echo "  Download: \${DL_URL_BASE}/rust-v\${VER}/\${CODEX_TARBALL}"
        exit 13
    fi
    echo ">>> SHA-256 verifiziert: \${ACTUAL_SUM}"
    rm -rf /tmp/codex-extract && mkdir -p /tmp/codex-extract
    tar -xzf /tmp/codex.tar.gz -C /tmp/codex-extract
    # Layout der Releases: 0.170.0 = EINE Datei 'codex-x86_64-unknown-linux-musl'
    # (das Binary selbst). Zukünftige Releases könnten ein Verzeichnis mit
    # 'codex' darin bringen – beide Fälle abdecken.
    CODEX_SRC=""
    if [[ -f /tmp/codex-extract/codex-x86_64-unknown-linux-musl ]]; then
        CODEX_SRC=/tmp/codex-extract/codex-x86_64-unknown-linux-musl
    elif [[ -f /tmp/codex-extract/codex-x86_64-unknown-linux-musl/codex ]]; then
        CODEX_SRC=/tmp/codex-extract/codex-x86_64-unknown-linux-musl/codex
    elif [[ -f /tmp/codex-extract/codex ]]; then
        CODEX_SRC=/tmp/codex-extract/codex
    fi
    if [[ -z "\$CODEX_SRC" ]]; then
        echo "FEHLER: Kein codex-Binary im Tarball gefunden (Layout geändert?)."
        echo "  Inhalt: \$(tar -tzf /tmp/codex.tar.gz | head -5)"
        exit 14
    fi
    install -m 755 "\$CODEX_SRC" /usr/local/bin/codex
    rm -rf /tmp/codex-extract /tmp/codex.tar.gz "\$REL_JSON"
    CODEX_VER_OUT=\$(/usr/local/bin/codex --version 2>/dev/null || true)
    if grep -q "codex-cli \${VER}" <<< "\$CODEX_VER_OUT"; then
        echo "Codex \${CODEX_VER_OUT} einsatzbereit"
    else
        echo "FEHLER: codex --version meldet nicht die erwartete Version \${VER}."
        echo "  Ausgabe war: \${CODEX_VER_OUT:-<leer>}"
        exit 15
    fi
fi

echo ">>> ttyd ${TTYD_VERSION} installieren (statisches Web-Terminal-Binary) ..."
# ttyd NICHT per bare-Name aufrufen: /usr/local/bin liegt nicht im PATH des
# pct-exec → Exit 127 killt unter set -euo pipefail den ganzen Lauf
# (Live-Grube #1). Versions-Nachweis über ttyd -v: das Binary meldet
# "1.7.7-40e79c7" (Release + Commit-Hash) – der Versions-Block steht in der
# Usage-Ausgabe NICHT in der Zeile mit "ttyd", deshalb NIE zeilenbasiert
# mit "ttyd.*VERSION" matchen (Live-Grube #2). Prefix-Match auf 1.7.7.
if [[ ! -x /usr/local/bin/ttyd ]]; then
    curl -fsSL --retry 3 "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" -o /tmp/ttyd.x86_64
    curl -fsSL --retry 3 "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/SHA256SUMS" -o /tmp/ttyd-SHA256SUMS
    TTYD_SUM=\$(awk '\$2=="ttyd.x86_64" {print \$1}' /tmp/ttyd-SHA256SUMS)
    if [[ -z "\$TTYD_SUM" ]]; then
        echo "FEHLER: ttyd.x86_64 fehlt in SHA256SUMS"; exit 9
    fi
    echo "\${TTYD_SUM}  /tmp/ttyd.x86_64" | sha256sum -c -
    install -m 755 /tmp/ttyd.x86_64 /usr/local/bin/ttyd
    rm -f /tmp/ttyd.x86_64 /tmp/ttyd-SHA256SUMS
fi
TTYD_VER_OUT=\$(/usr/local/bin/ttyd -v 2>/dev/null || true)
# ttyd 1.7.7 server.c: ttyd -v gibt "ttyd version 1.7.7-40e79c7" aus.
# Gegen die echte Quelle verifiziert (src/server.c, Tag 1.7.7) – NICHT raten!
if grep -q "ttyd version ${TTYD_VERSION}" <<< "\$TTYD_VER_OUT"; then
    echo "ttyd ${TTYD_VERSION} einsatzbereit"
else
    echo "FEHLER: /usr/local/bin/ttyd meldet nicht die erwartete Version ${TTYD_VERSION}"
    echo "  Ausgabe war: \$TTYD_VER_OUT"
    exit 10
fi

echo ">>> Workspace + Datenpfad anlegen (/root/codex-workspace) ..."
mkdir -p /root/codex-workspace
mkdir -p /opt/codex-ai

echo ">>> API-Key-Env anlegen (optional; leer = Login per Device-Code im ersten Lauf) ..."
if [[ -n "\${API_KEY:-}" ]]; then
    printf 'OPENAI_API_KEY=%s\n' "\$API_KEY" > /opt/codex-ai/codex.env
elif [[ ! -f /opt/codex-ai/codex.env ]]; then
    printf '# Codex: hier optional OPENAI_API_KEY=sk-... eintragen.\n# Leer lassen = Login per Device-Code/ChatGPT im ersten Lauf (Empfehlung).\n' > /opt/codex-ai/codex.env
fi
chmod 600 /opt/codex-ai/codex.env
# Interaktive Logins (ssh / pct enter) bekommen den Key ebenfalls:
if ! grep -q 'codex.env' /root/.bashrc 2>/dev/null; then
    printf '\n# CodexAI-Server: API-Key-Env laden (falls gesetzt)\nif [[ -f /opt/codex-ai/codex.env ]]; then . /opt/codex-ai/codex.env; fi\n' >> /root/.bashrc
fi

if [[ -n "\${API_KEY:-}" ]]; then
    echo ">>> Codex-Login mit API-Key (non-interaktiv) ..."
    # Offizieller Weg (Doku developers.openai.com/codex/auth):
    #   printenv OPENAI_API_KEY | codex login --with-api-key
    if ! printf '%s' "\${API_KEY}" | /usr/local/bin/codex login --with-api-key; then
        echo "FEHLER: codex login --with-api-key fehlgeschlagen (Key ungültig? org verbietet Keys?)."
        echo "  Key prüfen: https://platform.openai.com/api-keys"
        exit 16
    fi
    chmod 700 /root/.codex 2>/dev/null || true
    chmod 600 /root/.codex/auth.json 2>/dev/null || true
    if ! /usr/local/bin/codex login status >/dev/null 2>&1; then
        echo "FEHLER: codex login status schlägt nach dem API-Key-Login fehl."
        echo "  Key prüfen (gültig? org erlaubt API-Keys?): https://platform.openai.com/api-keys"
        exit 16
    fi
    echo ">>> Codex ist mit dem API-Key eingeloggt (auth.json: /root/.codex/auth.json)."
fi

cat > /opt/codex-ai/session.sh <<'WRAPEOF'
#!/usr/bin/env bash
# Codex Dauersession-Wrapper: startet codex immer wieder neu (Respawn).
export PATH="/usr/local/bin:\${PATH}"
if [[ -f /opt/codex-ai/codex.env ]]; then
    . /opt/codex-ai/codex.env
fi
cd /root/codex-workspace || cd /root
while true; do
    codex
    echo ">>> codex beendet – Neustart in 2 s ..."
    sleep 2
done
WRAPEOF
chmod +x /opt/codex-ai/session.sh

cat > /opt/codex-ai/LOGIN-HINWEISE <<'HINTSEOF'
Codex-Login (im Web-Terminal ODER per ssh/pct enter) – so geht's:
  1. Device-Code (empfohlen, auch ohne lokalen Browser):
       codex login --device-auth
     → Codex zeigt eine URL + einen Code: URL von JEDEM Rechner/Handy aus
       öffnen, Code eingeben, mit dem ChatGPT-Konto anmelden. Fertig.
     (Device-Auth ist ein Beta-Feature – ggf. in den ChatGPT-Sicherheitseinstellungen
      bzw. Workspace-Berechtigungen einmal freischalten.)
  2. SSH-Forward (OAuth wie am Desktop):
       ssh -L 1455:localhost:1455 root@<CT-IP>
     dann in DIESER SSH-Session: codex login → URL im lokalen Browser öffnen
     (der Callback läuft über den Tunnel zurück in den Container).
  3. API-Key (Abrechnung über OpenAI-Platform, NICHT ChatGPT-Plan):
       printenv OPENAI_API_KEY | codex login --with-api-key
     oder dem Installer direkt mitgeben:  <Einzeiler> --api-key sk-...
  Status:  codex login status     Abmelden:  codex logout
HINTSEOF

echo ">>> systemd-Units installieren (aus dem Installer-Tarball) ..."
install -m 644 /tmp/codexai-src/app/codex-ai-session.service /etc/systemd/system/codex-ai-session.service
install -m 644 /tmp/codexai-src/app/codex-ai-web.service /etc/systemd/system/codex-ai-web.service
sed -i "s/__PORT__/${PORT}/g; s/__WEB_PASSWORD__/\${WEB_PASSWORD}/g" \
    /etc/systemd/system/codex-ai-session.service \
    /etc/systemd/system/codex-ai-web.service

# Aufräumen erst NACH allen installs
rm -rf /tmp/codexai-src /tmp/codexai-installer.tar.gz

echo ">>> Service aktivieren (Session + Web-Terminal) ..."
systemctl daemon-reload
systemctl enable --now codex-ai-session.service codex-ai-web.service
systemctl restart codex-ai-session.service codex-ai-web.service

echo ">>> Setup abgeschlossen. Log: /var/log/codex-ai-setup.log"
INNEREOF
}

run_inner_setup() {
    local ct_id="$1"
    header "⚙️  Installation im Container $ct_id (Codex + ttyd + systemd)"
    # DNS des Hosts in den Container bringen (dort resolvert das Setup garantiert –
    # der DHCP-DNS des Zielnetzes kann flaky sein, siehe verify_ct_dns)
    HOST_DNS=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null \
               | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    write_inner_script
    pct push "$ct_id" "$TMP_DIR/setup-inner.sh" /root/setup-inner.sh
    # ALLES läuft im inner-Script (inkl. curl-Downloads) – das nackte Debian-
    # Template hat kein curl, pct exec curl → Exit 127!
    # Grube (tee-Pipe): ohne exit ${PIPESTATUS[0]} frisst die Pipe den inner-
    # Exit-Code (Fehler im inner liefen als "erfolgreich" durch!).
    pct exec "$ct_id" -- env CODEX_VERSION="$CODEX_VERSION" CODEX_SHA256="$CODEX_SHA256" \
        CODEX_PINNED_VERSION="${CODEX_VERSION}" PORT="$PORT" \
        WEB_PASSWORD="$WEB_PASSWORD" API_KEY="$API_KEY" HOST_DNS="$HOST_DNS" \
        bash -c "bash /root/setup-inner.sh 2>&1 | tee /var/log/codex-ai-setup.log; exit \${PIPESTATUS[0]}"
}

# ── Verifikation ───────────────────────────────────────────────────────────
verify_installation() {
    local ct_id="$1" tries=0 code="" codex_ver=""

    header "✅ Verifikation"

    # Session-Service aktiv?
    while true; do
        if pct exec "$ct_id" -- systemctl is-active --quiet codex-ai-session.service 2>/dev/null; then
            ok "Service codex-ai-session.service läuft (tmux-Dauersession)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Service codex-ai-session.service läuft nicht.\n  Debug: pct exec $ct_id -- journalctl -u codex-ai-session -e"
        fi
        sleep 1
    done

    # Web-Terminal-Service aktiv?
    tries=0
    while true; do
        if pct exec "$ct_id" -- systemctl is-active --quiet codex-ai-web.service 2>/dev/null; then
            ok "Service codex-ai-web.service läuft (ttyd-Webterminal)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Service codex-ai-web.service läuft nicht.\n  Debug: pct exec $ct_id -- journalctl -u codex-ai-web -e"
        fi
        sleep 1
    done

    # Codex-Binary benutzbar?
    codex_ver=$(pct exec "$ct_id" -- sh -c 'export PATH=/usr/local/bin:$PATH; codex --version 2>/dev/null' 2>/dev/null || true)
    if [[ -z "$codex_ver" ]]; then
        die "codex --version liefert keine Ausgabe.\n  Debug: pct enter $ct_id   (dann: codex --version)"
    fi
    ok "Codex: $codex_ver"

    # Web-Terminal antwortet? (Grube: curl -w gibt bei Verbindungsfehler
    # bereits 000 aus – NIE zusätzlich || echo 000 anhängen.)
    tries=0
    while true; do
        code=$(pct exec "$ct_id" -- curl -s -o /dev/null -w '%{http_code}' \
               -u "${TTYD_USER}:${WEB_PASSWORD}" "http://127.0.0.1:${PORT}/" || true)
        if [[ "$code" == "200" ]]; then
            ok "Web-Terminal antwortet (HTTP 200 mit Basic-Auth auf Port $PORT)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Web-Terminal antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).\n  401 = Passwort passt nicht (Unit prüfen), 000 = ttyd tot.\n  Debug: pct exec $ct_id -- journalctl -u codex-ai-web -e"
        fi
        sleep 1
    done

    # Login-Status: mit --api-key MUSS Codex eingeloggt sein; ohne Key ist der
    # Login eine Benutzer-Aufgabe (Warnung statt Abbruch).
    if ! pct exec "$ct_id" -- sh -c 'export PATH=/usr/local/bin:$PATH; codex login status >/dev/null 2>&1'; then
        if [[ -n "$API_KEY" ]]; then
            die "Codex ist trotz --api-key NICHT eingeloggt (codex login status fehlgeschlagen).\n  Debug: pct exec $ct_id -- codex login status"
        fi
        warn "Codex ist noch NICHT eingeloggt – Login im Web-Terminal machen:"
        warn "  codex login --device-auth   (URL + Code von einem beliebigen Gerät öffnen)"
        warn "  oder:  ${ONE_LINER} --api-key sk-...   (non-interaktiv)"
    else
        ok "Codex-Login: aktiv (codex login status grün)"
    fi
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    header "🧠  Codex ist bereit!"

    local ct_ip
    ct_ip=$(get_ct_ip "$CT_ID")
    if [[ -z "$ct_ip" ]]; then
        ct_ip="<IP-ADRESSE>"
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  🌐 Web-Terminal:  http://${ct_ip}:${PORT}${NC}"
    echo -e "  ${GREEN}  🔑 Login:         ${TTYD_USER} / ${WEB_PASSWORD}${NC}"
    echo -e "  ${GREEN}  🐚 Session:       pct enter ${CT_ID}   →   tmux attach -t codex${NC}"
    if [[ -n "$CT_PASSWORD" ]]; then
        echo -e "  ${GREEN}  🔒 Root-PW:       ${CT_PASSWORD}${NC}"
    fi
    if [[ -n "$API_KEY" ]]; then
        echo -e "  ${GREEN}  🔏 API-Key:       gesetzt (${API_KEY:0:8}…, in /opt/codex-ai/codex.env)${NC}"
    fi
    echo -e "  ${GREEN}  📁 Workspace:     /root/codex-workspace  (im Container)${NC}"
    echo -e "  ${GREEN}  🧠 Codex:         ${CODEX_VERSION} (offizielles Release-Binary)${NC}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}So läuft die Session (dauerhaft – Reboot-sicher, Respawn bei Beenden):${NC}"
    echo "  1. Web-Terminal-URL im Browser öffnen (Basic-Auth: ${TTYD_USER} / ${WEB_PASSWORD})"
    if [[ -z "$API_KEY" ]]; then
        echo "  2. Einmalig einloggen – im Web-Terminal (exakte Befehle):"
        echo "       codex login --device-auth"
        echo "     → URL + Code erscheinen; URL von JEDEM Gerät aus im Browser öffnen,"
        echo "       Code eingeben, mit dem ChatGPT-Konto (Plus/Pro/Business) anmelden."
        echo "     Alternative mit OAuth wie am Desktop: ssh -L 1455:localhost:1455 root@${ct_ip}"
        echo "       → dann in der SSH-Session: codex login"
        echo "     Alternative ohne ChatGPT-Plan (Platform-Abrechnung):"
        echo "       ${ONE_LINER} --api-key sk-..."
    else
        echo "  2. Codex startet direkt (API-Key ist gesetzt und eingeloggt)."
    fi
    echo "  3. Fertig – die Session läuft weiter, auch wenn du den Browser schließt."
    echo "     Zurückkehren: URL wieder öffnen (oder ssh/pct enter → tmux attach -t codex)."
    echo ""
    echo -e "  ${CYAN}Login-Hilfe liegt auch im Container: /opt/codex-ai/LOGIN-HINWEISE${NC}"
    echo ""
    echo -e "  ${CYAN}Nützliche Befehle (exakt kopierbar):${NC}"
    echo "  Status:    ${ONE_LINER} --status"
    echo "  Update:    ${ONE_LINER} --update"
    echo "  Deinstall: ${ONE_LINER} --uninstall"
    echo "  Logs:      pct exec ${CT_ID} -- journalctl -u codex-ai-session -f"
    echo ""
    warn "Hinweis: das Web-Terminal ist ein ROOT-Terminal im Container (LXC-Isolation)"
    warn "und Codex ist ein Agent mit Shell-Zugriff – Port ${PORT} NICHT ohne VPN/Firewall"
    warn "ins Internet exposen. Basic-Auth ist kein Vollschutz."
}

# ── Install ────────────────────────────────────────────────────────────────
do_install() {
    header "🧠 Installiere CodexAI-Server (LXC, Codex @ ${CODEX_VERSION})"

    if [[ $EUID -ne 0 ]]; then
        die "Bitte als root ausführen (auf dem Proxmox-Host)."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        die "pct nicht gefunden – das Script muss auf einem Proxmox-VE-Host laufen."
    fi

    # Bereits vorhanden? ALLE Treffer listen (doppelte Hostnamen = Warnfall)
    local all_ids existing
    all_ids=$(pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" '$NF==h {print $1}' | tr '\n' ' ' | sed 's/ $//')
    if [[ -n "$all_ids" ]]; then
        existing=${all_ids%% *}
        if [[ "$all_ids" == *" "* ]]; then
            warn "MEHRERE Container mit Hostname '$CT_HOSTNAME': $all_ids"
            warn "--force löscht nur $existing – überzählige vorher manuell räumen:"
            warn "  pct stop <ID> && pct destroy <ID> --purge   (für jede doppelte ID)"
        fi
        if $FORCE_RECREATE; then
            warn "Container $existing ($CT_HOSTNAME) existiert – --force: lösche und lege neu an (nächste freie ID)."
            warn "Session-Daten (~/.codex, Workspace) in diesem Container gehen verloren!"
            pct stop "$existing" || true
            pct destroy "$existing" --purge
        else
            die "Container $all_ids mit Hostname '$CT_HOSTNAME' existiert bereits.\n  Update (dasselbe CT, Login bleibt):  ${ONE_LINER} --update\n  Neu aufsetzen (löscht CT, wählt nächste freie ID):  ${ONE_LINER} --force\n  Doppelte manuell räumen:  pct stop <ID> && pct destroy <ID> --purge"
        fi
    fi

    # Debian-Template sicherstellen
    header "🧱 Container-Template"
    local template=""
    template=$(pveam list local 2>/dev/null | awk '{print $1}' | grep -o 'debian-12-standard[^ ]*' | sort -rV | head -1 || true)
    if [[ -z "$template" ]]; then
        info "Kein Debian-12-Template vorhanden – lade es herunter ..."
        pveam update
        template=$(pveam available --section system 2>/dev/null | grep -o 'debian-12-standard[^ ]*' | sort -rV | head -1 || true)
        if [[ -z "$template" ]]; then
            die "Kein debian-12-standard-Template gefunden (pveam available leer?)."
        fi
        pveam download local "$template"
    fi
    ok "Template: $template"

    # ID, Root-Passwort, Web-Terminal-Passwort
    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_free_id)
        info "Nächste freie CT-ID: $CT_ID"
    fi
    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(openssl rand -base64 12 2>/dev/null || true)
        if [[ -z "$CT_PASSWORD" ]]; then
            CT_PASSWORD="cx-$(date +%s)"
        fi
    fi
    if [[ -z "$WEB_PASSWORD" ]]; then
        # hex → sed-sicher und URL-tauglich (kein / oder + wie bei base64)
        WEB_PASSWORD=$(openssl rand -hex 16 2>/dev/null || true)
        if [[ -z "$WEB_PASSWORD" ]]; then
            die "Konnte kein Web-Terminal-Passwort generieren (openssl fehlt?)."
        fi
    fi

    # Container anlegen
    header "🚀 Erzeuge Container $CT_ID ($CT_HOSTNAME)"
    local net0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},firewall=0"
    if [[ -n "$CT_GATEWAY" ]]; then
        net0+=",gateway=${CT_GATEWAY}"
    fi
    pct create "$CT_ID" "local:vztmpl/${template}" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --net0 "$net0" \
        --unprivileged 1 \
        --features nesting=1 \
        --onboot 1 \
        --start 1 \
        --password "$CT_PASSWORD"
    ok "Container $CT_ID erstellt und gestartet"

    wait_for_ct_network "$CT_ID"
    verify_ct_dns "$CT_ID"

    run_inner_setup "$CT_ID"
    verify_installation "$CT_ID"
    print_summary
}

# ── Update ─────────────────────────────────────────────────────────────────
do_update() {
    header "🔄 Update CodexAI-Server (Codex @ ${CODEX_VERSION})"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden.\n  Erst installieren:  ${ONE_LINER}"
    fi
    CT_ID="$ct_id"

    ensure_ct_running "$ct_id"
    verify_ct_dns "$ct_id"

    if [[ -z "$WEB_PASSWORD" ]]; then
        # Bestehendes Web-Terminal-Passwort aus der Unit übernehmen (Session bleibt
        # mit demselben Login erreichbar – kein neuer Wert, keine Überraschung).
        WEB_PASSWORD=$(pct exec "$ct_id" -- sh -c "sed -n 's/.*-c ${TTYD_USER}:\([^ ]*\) .*/\1/p' /etc/systemd/system/codex-ai-web.service" 2>/dev/null || true)
        if [[ -z "$WEB_PASSWORD" ]]; then
            WEB_PASSWORD=$(openssl rand -hex 16 2>/dev/null || true)
        fi
    fi

    run_inner_setup "$ct_id"
    verify_installation "$ct_id"

    ok "Update abgeschlossen – Login (~/.codex), codex.env und Workspace blieben erhalten."
    print_summary
}

# ── Uninstall ──────────────────────────────────────────────────────────────
do_uninstall() {
    header "🗑️  Deinstalliere CodexAI-Server"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden – nichts zu tun."
        return 0
    fi
    CT_ID="$ct_id"

    warn "Container $ct_id ($CT_HOSTNAME) wird GESTOPPT und GELÖSCHT."
    warn "Darin: die Codex-Session, Login-Daten (~/.codex), codex.env und der Workspace!"
    if ! $ASSUME_YES; then
        local answer=""
        if ! read -r -t 60 -p "Wirklich löschen? (ja/NEIN): " answer; then
            die "Keine Bestätigung erhalten (nicht-interaktiv?) – nichts gelöscht.\n  Erzwingen:  ${ONE_LINER} --uninstall --yes"
        fi
        if [[ "$answer" != "ja" ]]; then
            info "Abgebrochen – nichts gelöscht."
            return 0
        fi
    fi
    pct stop "$ct_id" || true
    pct destroy "$ct_id" --purge
    ok "Container $ct_id entfernt."
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    header "📊 Status CodexAI-Server"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden."
        info "Installieren:  ${ONE_LINER}"
        return 0
    fi
    CT_ID="$ct_id"

    pct list 2>/dev/null | awk -v id="$ct_id" '$1==id {print "Container:  " $1 " (" $2 ") – " $3 " – " $4 " – " $5}'
    # --status startet einen gestoppten Container NICHT – nur melden.
    if ! pct status "$ct_id" 2>/dev/null | grep -q "status: running"; then
        warn "Container ist gestoppt – Session/Web-Terminal nicht erreichbar."
        info "Starten:  pct start $ct_id   |   Update inkl. Start:  ${ONE_LINER} --update"
        return 0
    fi

    if pct exec "$ct_id" -- systemctl is-active --quiet codex-ai-session.service 2>/dev/null; then
        ok "Session:   codex-ai-session.service läuft"
    else
        err "Session:   codex-ai-session.service läuft NICHT"
        info "Logs:      pct exec $ct_id -- journalctl -u codex-ai-session -e"
    fi
    if pct exec "$ct_id" -- systemctl is-active --quiet codex-ai-web.service 2>/dev/null; then
        ok "Web-Term:  codex-ai-web.service läuft"
    else
        err "Web-Term:  codex-ai-web.service läuft NICHT"
        info "Logs:      pct exec $ct_id -- journalctl -u codex-ai-web -e"
    fi
    if pct exec "$ct_id" -- tmux has-session -t codex 2>/dev/null; then
        ok "tmux:      Session 'codex' vorhanden"
    else
        warn "tmux:      Session 'codex' fehlt (Service neu starten: pct exec $ct_id -- systemctl restart codex-ai-session)"
    fi

    local ip code codex_ver web_pw login_out
    ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ip" ]]; then
        web_pw=$(pct exec "$ct_id" -- sh -c "sed -n 's/.*-c ${TTYD_USER}:\([^ ]*\) .*/\1/p' /etc/systemd/system/codex-ai-web.service" 2>/dev/null || true)
        code=$(pct exec "$ct_id" -- curl -s -o /dev/null -w '%{http_code}' -u "${TTYD_USER}:${web_pw}" --max-time 5 "http://127.0.0.1:${PORT}/" || true)
        if [[ "$code" == "200" ]]; then
            ok "Web-Term:  http://${ip}:${PORT}  (Login: ${TTYD_USER} / ${web_pw})"
        else
            warn "Web-Term:  HTTP-Code ${code:-unbekannt} von http://${ip}:${PORT}"
        fi
    else
        warn "Container hat keine IP (läuft er?)."
    fi

    codex_ver=$(pct exec "$ct_id" -- sh -c 'export PATH=/usr/local/bin:$PATH; codex --version 2>/dev/null' 2>/dev/null || true)
    info "Codex:     ${codex_ver:-unbekannt} (OpenAI Codex CLI)"

    login_out=$(pct exec "$ct_id" -- sh -c 'export PATH=/usr/local/bin:$PATH; codex login status 2>&1' 2>/dev/null || true)
    if pct exec "$ct_id" -- sh -c 'export PATH=/usr/local/bin:$PATH; codex login status >/dev/null 2>&1'; then
        ok "Login:     eingeloggt (${login_out})"
    else
        warn "Login:     NICHT eingeloggt – im Web-Terminal: codex login --device-auth"
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────
parse_args "$@"

TMP_DIR=$(mktemp -d)

if $UNINSTALL; then
    do_uninstall
elif $UPDATE; then
    do_update
elif $STATUS_CHECK; then
    do_status
else
    do_install
fi
