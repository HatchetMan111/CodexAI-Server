#!/usr/bin/env bash
# =============================================================================
# CodexAI-Server Mock-Harness (kein Proxmox-Host nötig)
#
# Läuft als unprivilegierter User: `unshare -rm` mappt den User auf root
# (EUID 0 → Root-Prüfung des Production-Scripts testbar) und isoliert die
# Schreibpfade per Mount-Namespace (tmpfs über /opt, /root, /usr/local/bin,
# /var/log, /etc/dhcp, /etc/systemd/system; bind-mount über /etc/resolv.conf).
# Alle pct/pveam/curl/systemctl/...-Aufrufe werden über tests/fakebin gemockt.
# Der offizielle Codex-Standalone-Installer (chatgpt.com/codex/install.sh)
# wird durch das Mock-Bootstrap ersetzt (tests/assets/mock-codex-bootstrap.sh):
# es baut dasselbe packaged-Layout wie das Original (releases/<v>-<target> +
# current-Symlink + Wrapper in ~/.local/bin) und benutzt das Mock-Codex-Binary.
#
# Aufruf:   tests/run-tests.sh            (alle Cases)
#           tests/run-tests.sh <name> ... (nur bestimmte Cases)
# =============================================================================
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HARNESS_DIR")"
FAKEBIN="$HARNESS_DIR/fakebin"
ASSETS="$HARNESS_DIR/assets"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
WORK="/tmp/codexai-harness.$$"
INSTALLER="$REPO/install/codex-ai-server.sh"

PASS=0
FAIL=0
FAILED_CASES=()

# ── Assertions (inner- und host-seitig benutzt) ────────────────────────────
ok()   { echo "OK   $*" >> "$RESULTS_FILE"; }
fail() { echo "FAIL $*" >> "$RESULTS_FILE"; }

assert_eq() {
    local got="$1" want="$2" msg="$3"
    if [[ "$got" == "$want" ]]; then ok "$msg"; else fail "$msg (got=[$got] want=[$want])"; fi
}

assert_contains() {
    local hay="$1" needle="$2" msg="$3"
    if grep -qF -- "$needle" <<< "$hay"; then ok "$msg"; else fail "$msg (fehlt: [$needle])"; fi
}

assert_file() {
    if [[ -e "$1" ]]; then ok "$2"; else fail "$2 (Datei fehlt: $1)"; fi
}

assert_no_file() {
    if [[ ! -e "$1" ]]; then ok "$2"; else fail "$2 (sollte fehlen, existiert: $1)"; fi
}

assert_mode() {
    local m
    m=$(stat -c %a "$1" 2>/dev/null || echo "?")
    assert_eq "$m" "$2" "$3"
}

# ── Installer-Lauf (innerhalb NS) ──────────────────────────────────────────
run_installer() {
    OUT=$(bash "$INSTALLER" "$@" < /dev/null 2>&1)
    RC=$?
}

# ── Presets (State-Seeding, läuft im NS) ───────────────────────────────────
seed_full_ct() {
    # Ein "fertig installierter" CT: Unit mit Passwort, codex-Mock, tmux an
    local pw="${1:-seedpw9876}"
    mkdir -p /etc/systemd/system /usr/local/bin /opt/codex-ai /root/codex-workspace
    printf 'ExecStart=/usr/local/bin/ttyd -p 8091 -c codex:%s -W /usr/bin/tmux attach -t codex\n' "$pw" \
        > /etc/systemd/system/codex-ai-web.service
    cp "$ASSETS/mock-codex.sh" /usr/local/bin/codex
    chmod +x /usr/local/bin/codex
    echo 1 > "$HARNESS_STATE/tmux.session"
}

seed_preset() {
    local preset="$1"
    mkdir -p "$HARNESS_STATE/cts" "$HARNESS_STATE/systemd"
    case "$preset" in
        fresh) ;;
        occupied200) printf 'running other-ct 10.0.0.200\n' > "$HARNESS_STATE/cts/200" ;;
        dup) printf 'running codex-ai-server 10.0.0.208\n' > "$HARNESS_STATE/cts/208" ;;
        existing-stopped)
            printf 'stopped codex-ai-server 10.0.0.205\n' > "$HARNESS_STATE/cts/205"
            seed_full_ct oldpw123
            ;;
        status-running)
            printf 'running codex-ai-server 10.0.0.42\n' > "$HARNESS_STATE/cts/206"
            seed_full_ct seedpw9876
            touch "$HARNESS_STATE/systemd/codex-ai-session.service.active"
            touch "$HARNESS_STATE/systemd/codex-ai-web.service.active"
            ;;
        status-stopped)
            printf 'stopped codex-ai-server 10.0.0.42\n' > "$HARNESS_STATE/cts/206"
            seed_full_ct seedpw9876
            ;;
        uninstall)
            printf 'running codex-ai-server 10.0.0.207\n' > "$HARNESS_STATE/cts/207"
            ;;
        *)
            echo "unbekanntes Preset: $preset" >&2
            exit 64
            ;;
    esac
}

# ── Cases (laufen im NS; non_root bewusst nicht) ───────────────────────────
case_fresh_install() {
    run_installer
    assert_eq "$RC" 0 "Install-Exit-Code 0"
    assert_contains "$OUT" "Codex ist bereit!" "Summary erscheint"
    assert_contains "$OUT" "http://10.0.0.42:8091" "Summary zeigt CT-IP + Port"
    assert_contains "$OUT" "codex-cli 0.170.0" "codex --version verifiziert"
    assert_contains "$OUT" "HTTP 200" "Web-Terminal HTTP-Check mit Basic-Auth"
    assert_contains "$OUT" "aabbccdd00112233aabbccdd00112233" "generiertes Web-PW in Summary"
    assert_contains "$OUT" "codex login --device-auth" "Summary zeigt Device-Auth-Login"
    assert_contains "$OUT" "1455:localhost:1455" "Summary zeigt SSH-Forward-Alternative"

    assert_file /etc/systemd/system/codex-ai-session.service "Session-Unit installiert"
    assert_file /etc/systemd/system/codex-ai-web.service "Web-Unit installiert"
    local u
    u=$(cat /etc/systemd/system/codex-ai-web.service)
    assert_contains "$u" "-p 8091" "__PORT__ wurde ersetzt (8091)"
    assert_contains "$u" "-c codex:aabbccdd00112233aabbccdd00112233" "__WEB_PASSWORD__ wurde ersetzt"
    assert_contains "$u" "-W /usr/bin/tmux attach -t codex" "ttyd hängt an tmux-Session 'codex'"
    local s
    s=$(cat /etc/systemd/system/codex-ai-session.service)
    assert_contains "$s" "new-session -d -s codex -c /root/codex-workspace /opt/codex-ai/session.sh" "Session-Unit erzeugt tmux-Session 'codex'"
    assert_contains "$s" "Restart=on-failure" "Session-Unit hat Restart-Policy"

    local w
    w=$(cat /opt/codex-ai/session.sh)
    assert_contains "$w" "while true" "Respawn-Wrapper vorhanden"
    assert_contains "$w" "/usr/local/bin" "Wrapper setzt PATH auf Codex-Binary"
    assert_contains "$w" "codex-workspace" "Wrapper wechselt in Workspace"

    assert_file /usr/local/bin/codex "codex-Symlink installiert"
    assert_file /usr/local/bin/ttyd "ttyd installiert"
    assert_contains "$OUT" "ttyd 1.7.7 einsatzbereit" "ttyd-Installations-Nachweis über ttyd -v (Prefix-Match, NICHT ttyd.*VERSION!)"
    assert_contains "$OUT" "einsatzbereit (packaged CLI)" "Codex-Installations-Nachweis über codex --version"
    assert_contains "$OUT" "offizieller Standalone-Installer" "Codex über den offiziellen Installer (Live-Grube #19: nackte musl-Binary reicht nicht)"

    # Packaged-Layout des Standalone-Installers (das braucht die TUI für den Daemon)
    assert_file /root/.codex/packages/standalone/current "current-Symlink der packaged CLI"
    assert_file /root/.codex/packages/standalone/current/codex-package.json "codex-package.json vorhanden"
    assert_file /root/.codex/packages/standalone/current/bin/codex "bin/codex vorhanden"
    assert_file /root/.codex/packages/standalone/current/bin/codex-code-mode-host "bin/codex-code-mode-host vorhanden"
    local cur_target
    cur_target=$(readlink /root/.codex/packages/standalone/current)
    assert_contains "$cur_target" "0.170.0-x86_64-unknown-linux-musl" "current zeigt auf Release-Verzeichnis (latest → 0.170.0)"
    assert_file /root/codex-workspace "Workspace angelegt"
    assert_file /opt/codex-ai/codex.env "codex.env angelegt"
    assert_mode /opt/codex-ai/codex.env 600 "codex.env ist chmod 600"
    assert_file /opt/codex-ai/LOGIN-HINWEISE "Login-Hinweise angelegt"
    if grep -q "device-auth" /opt/codex-ai/LOGIN-HINWEISE 2>/dev/null; then
        ok "LOGIN-HINWEISE nennt codex login --device-auth"
    else
        fail "LOGIN-HINWEISE nennt codex login --device-auth nicht"
    fi
    local e
    e=$(cat /opt/codex-ai/codex.env)
    if grep -q "^OPENAI_API_KEY=sk-" <<< "$e"; then
        fail "ohne --api-key darf kein Key gesetzt sein"
    else
        ok "ohne --api-key bleibt codex.env ohne Key"
    fi
    if grep -q "codex.env" /root/.bashrc 2>/dev/null; then ok ".bashrc source-Zeile vorhanden"; else fail ".bashrc source-Zeile fehlt"; fi

    # Ohne --api-key: Login ist noch offen → Warnung statt Abbruch
    assert_contains "$OUT" "noch NICHT eingeloggt" "fehlender Login → Warnung (nicht die())"

    # Codex-Download läuft über den offiziellen Standalone-Installer
    local urls
    urls=$(cat "$HARNESS_STATE/curl-calls/urls.log" 2>/dev/null || echo "")
    assert_contains "$urls" "chatgpt.com/codex/install.sh" "offizieller Standalone-Installer geladen"
    if grep -q "github.com/openai/codex/releases/download" <<< "$urls"; then
        fail "nackte musl-Binary darf NICHT mehr geladen werden (Live-Grube #19)"
    else
        ok "kein Download der nackten musl-Binary mehr (Live-Grube #19)"
    fi

    assert_file "$HARNESS_STATE/systemd/codex-ai-session.service.active" "Session-Service aktiv"
    assert_file "$HARNESS_STATE/systemd/codex-ai-web.service.active" "Web-Service aktiv"

    local r
    r=$(cat /etc/resolv.conf)
    assert_contains "$r" "nameserver 1.1.1.1" "resolv.conf mit Fallback-Nameservern"
    assert_file /etc/dhcp/dhclient-enter-hooks.d/no-dns "DHCP-DNS-Überschreib-Hook gesetzt"

    local c t
    c=$(cat "$HARNESS_STATE/pct-create-200.args" 2>/dev/null || echo "")
    assert_contains "$c" "--hostname codex-ai-server" "CT heißt 'codex-ai-server'"
    assert_contains "$c" "--onboot 1" "onboot=1 (Reboot-sicher)"
    assert_contains "$c" "--unprivileged 1" "unprivilegierter CT"
    assert_contains "$c" "nesting=1" "nesting=1"
    assert_contains "$c" "--memory 4096" "RAM 4096 MB"
    assert_contains "$c" "--cores 2" "2 vCPUs"
    assert_contains "$c" "local:vztmpl/debian-12-standard" "Debian-12-Template"

    t=$(cat "$HARNESS_STATE/tmux-calls.log" 2>/dev/null || echo "")
    assert_contains "$t" "new-session -d -s codex" "tmux-Session 'codex' erzeugt"

    if [[ -f "$HARNESS_STATE/cts/200" ]]; then ok "CT-ID 200 vergeben (erste freie ab 200)"; else fail "CT-ID 200 vergeben (erste freie ab 200)"; fi
}

case_id_skip() {
    run_installer
    assert_eq "$RC" 0 "Install-Exit-Code 0 (belegte ID 200)"
    assert_no_file "$HARNESS_STATE/pct-create-200.args" "belegte ID 200 nicht erneut vergeben"
    assert_file "$HARNESS_STATE/pct-create-201.args" "nächste freie ID 201 vergeben"
}

case_dns_late() {
    run_installer
    assert_eq "$RC" 0 "Install-Exit-Code 0 (DNS erst ab 11. Aufruf ok → Fallback)"
    assert_contains "$OUT" "DNS-Fallback aktiv" "DNS-Fallback-Pfad wurde durchlaufen"
    assert_file /etc/dhcp/dhclient-enter-hooks.d/no-dns "Fallback-Hook geschrieben"
}

case_dns_flaky() {
    run_installer
    assert_eq "$RC" 0 "Install-Exit-Code 0 (flaky DNS, 3-Erfolge-Fenster)"
    if grep -q "DNS-Fallback aktiv" <<< "$OUT"; then
        fail "flaky4 ohne dauerhaften Defekt löst KEINEN Fallback aus (Grube 11a)"
    else
        ok "flaky4 ohne dauerhaften Defekt löst KEINEN Fallback aus (Grube 11a)"
    fi
    assert_contains "$OUT" "DNS im Container funktioniert (3x bestätigt)" "3 konsekutive Erfolge erkannt"
}

case_dns_dead() {
    run_installer
    assert_eq "$RC" 1 "DNS tot → Installer bricht ab (Exit 1)"
    assert_contains "$OUT" "DNS im Container weiterhin ohne Funktion" "Diagnose-Message bei totalem DNS"
    assert_contains "$OUT" "getent hosts" "Debug-Hinweis enthält getent-Kommando"
}

case_update_stopped() {
    run_installer --update
    assert_eq "$RC" 0 "Update-Exit-Code 0 (CT war gestoppt)"
    local calls
    calls=$(cat "$HARNESS_STATE/pct-calls.log" 2>/dev/null || echo "")
    assert_contains "$calls" "pct start 205" "gestoppter CT wurde automatisch gestartet"
    assert_contains "$OUT" "Update abgeschlossen" "Update-Summary erscheint"
    assert_contains "$OUT" "offizieller Standalone-Installer" "Codex-Install über den offiziellen Installer re-lief"
    assert_contains "$OUT" "ttyd 1.7.7 einsatzbereit" "ttyd wurde (neu) installiert"
    local u
    u=$(cat /etc/systemd/system/codex-ai-web.service)
    assert_contains "$u" "codex:oldpw123" "Web-PW wurde vom bestehenden CT übernommen (nicht rotiert)"
    assert_file "$HARNESS_STATE/systemd/codex-ai-session.service.active" "Session-Service nach Update aktiv"
    assert_file "$HARNESS_STATE/systemd/codex-ai-web.service.active" "Web-Service nach Update aktiv"
}

case_status_running() {
    run_installer --status
    assert_eq "$RC" 0 "Status-Exit-Code 0"
    assert_contains "$OUT" "codex-ai-session.service läuft" "Session-Service-Status"
    assert_contains "$OUT" "codex-ai-web.service läuft" "Web-Service-Status"
    assert_contains "$OUT" "Session 'codex' vorhanden" "tmux-Session-Status"
    assert_contains "$OUT" "http://10.0.0.42:8091" "Web-Terminal-URL mit IP"
    assert_contains "$OUT" "Login: codex / seedpw9876" "Web-PW aus Unit gelesen"
    assert_contains "$OUT" "codex-cli 0.170.0" "Codex-Version im Status"
    assert_contains "$OUT" "NICHT eingeloggt" "Login-Status im Status (Warnung)"
}

case_status_stopped() {
    run_installer --status
    assert_eq "$RC" 0 "Status-Exit-Code 0 (CT gestoppt)"
    assert_contains "$OUT" "Container ist gestoppt" "Stopp-Warnung erscheint"
    assert_contains "$OUT" "pct start 206" "Start-Hinweis mit CT-ID"
}

case_uninstall_yes() {
    run_installer --uninstall --yes
    assert_eq "$RC" 0 "Deinstall-Exit-Code 0"
    assert_no_file "$HARNESS_STATE/cts/207" "CT 207 gelöscht"
    assert_contains "$OUT" "entfernt" "Deinstall-Bestätigung"
}

case_uninstall_confirm() {
    run_installer --uninstall
    assert_eq "$RC" 1 "Deinstall ohne Bestätigung bricht ab"
    assert_file "$HARNESS_STATE/cts/207" "CT 207 NICHT gelöscht (Schutz funktioniert)"
    assert_contains "$OUT" "Keine Bestätigung erhalten" "Abbruch-Message"
    assert_contains "$OUT" "--uninstall --yes" "Erzwinge-Hinweis mit exaktem Befehl"
}

case_dup_hostname() {
    run_installer
    assert_eq "$RC" 1 "Duplikat-Hostname → Abbruch"
    assert_contains "$OUT" "existiert bereits" "Duplikat-Diagnose"
    assert_contains "$OUT" "--update" "Hinweis auf --update"
    assert_contains "$OUT" "--force" "Hinweis auf --force"
}

case_api_key() {
    run_installer --api-key "sk-openai-test1234"
    assert_eq "$RC" 0 "Install-Exit-Code 0 (--api-key)"
    local e
    e=$(cat /opt/codex-ai/codex.env)
    assert_contains "$e" "OPENAI_API_KEY=sk-openai-test1234" "API-Key in codex.env"
    assert_mode /opt/codex-ai/codex.env 600 "codex.env ist chmod 600"
    assert_file /root/.codex/auth.json "auth.json nach non-interaktivem Login vorhanden"
    assert_contains "$OUT" "Codex-Login: aktiv" "Verifikation meldet aktiven Login"
    assert_contains "$OUT" "API-Key:       gesetzt" "Summary meldet API-Key (maskiert)"
    if grep -q "sk-openai-test1234" <<< "$OUT"; then
        fail "API-Key darf NICHT im Klartext in der Summary stehen"
    else
        ok "API-Key nur maskiert in der Summary"
    fi
}

case_version_pin() {
    run_installer --codex-version "0.170.0"
    assert_eq "$RC" 0 "Install-Exit-Code 0 (Versions-Pin)"
    assert_contains "$OUT" "codex-cli 0.170.0" "verifizierte Version"
    assert_contains "$OUT" "CODEX_RELEASE=0.170.0 -> 0.170.0" "Installer lief mit CODEX_RELEASE=0.170.0"
}

case_version_latest() {
    run_installer --codex-version "latest"
    assert_eq "$RC" 0 "Install-Exit-Code 0 (latest-Auflösung)"
    assert_contains "$OUT" "CODEX_RELEASE=latest -> 0.170.0" "Installer löst latest selbst auf"
    assert_contains "$OUT" "codex-cli 0.170.0" "aufgelöste Version installiert + verifiziert"
    local urls
    urls=$(cat "$HARNESS_STATE/curl-calls/urls.log" 2>/dev/null || echo "")
    assert_contains "$urls" "chatgpt.com/codex/install.sh" "Installer-URL geladen"
}

case_bootstrap_fail() {
    run_installer
    assert_eq "$RC" 8 "Standalone-Installer-Fehler → Exit 8"
    assert_contains "$OUT" "Standalone-Installer ist fehlgeschlagen" "Diagnose-Message bei Installer-Crash"
    assert_contains "$OUT" "Installationsfehler – Exit-Code 8" "on_error-Fehlerkette"
    assert_contains "$OUT" "--debug" "on_error: bash -x-Hinweis mit exaktem Befehl"
}

case_help() {
    run_installer --help
    assert_eq "$RC" 0 "Help-Exit-Code 0"
    assert_contains "$OUT" "--codex-version" "Help listet --codex-version"
    assert_contains "$OUT" "--api-key" "Help listet --api-key"
    assert_contains "$OUT" "--port" "Help listet --port"
}

case_zero_fallback() {
    # bash -c "$(wget ...)" --status: $0 ist "--status", kein $1 – der
    # Installer muss die Option trotzdem erkennen ($0-Fallback).
    OUT=$(bash -c "$(cat "$INSTALLER")" --status < /dev/null 2>&1)
    RC=$?
    assert_eq "$RC" 0 "Exit-Code 0 ($0-Fallback)"
    assert_contains "$OUT" "Status CodexAI-Server" "Option wurde als --status erkannt"
    assert_contains "$OUT" "codex-ai-session.service läuft" "Status-Output vollständig"
}

case_error_chain() {
    run_installer
    assert_eq "$RC" 9 "pct create-Fehler → Exit-Code 9 durchgereicht"
    assert_contains "$OUT" "Installationsfehler – Exit-Code 9" "on_error: Exit-Code genannt"
    assert_contains "$OUT" "Fehlgeschlagener Befehl: pct create" "on_error: fehlgeschlagener Befehl genannt"
    assert_contains "$OUT" "Letzte Logzeilen" "on_error: Log-Auszug"
    assert_contains "$OUT" "--debug" "on_error: bash -x-Hinweis mit exaktem Befehl"
}

case_non_root() {
    # Läuft bewusst AUSSERHALB des unshare-NS (dort wäre man root):
    OUT=$(bash "$INSTALLER" < /dev/null 2>&1)
    RC=$?
    assert_eq "$RC" 1 "nicht-root → Exit 1"
    assert_contains "$OUT" "Bitte als root ausführen" "Root-Prüfung greift"
}

case_ttyd_version_format() {
    # Regressionsschutz gegen Live-Gruben #1/#2: ttyd -v liefert
    # "ttyd version 1.7.7-40e79c7" (server.c-Zeile printf("ttyd version %s")).
    # Der Installer MUSS diesen String erkennen – ein Prefix-Match auf "1.7.7"
    # scheitert, weil die Zeile mit "ttyd version " beginnt (Live-Lauf #3).
    local want="${TTYD_VERSION:-$(sed -n 's/^TTYD_VERSION="\([^"]*\)".*/\1/p' "$INSTALLER")}"
    local fakebin="$HARNESS_STATE/version-bin"
    mkdir -p "$fakebin"
    cp "$ASSETS/mock-ttyd.sh" "$fakebin/ttyd"
    chmod +x "$fakebin/ttyd"
    local v_out v_rc
    v_out=$("$fakebin/ttyd" -v 2>/dev/null) && v_rc=0 || v_rc=$?
    assert_eq "$v_rc" 0 "ttyd -v endet mit Exit 0"
    if grep -q "ttyd version ${want}" <<< "$v_out"; then
        ok "Installer-Muster 'ttyd version ${want}' matcht den echten ttyd -v-String"
    else
        fail "Installer-Muster würde den echten ttyd -v-String NICHT matchen"
    fi
    # Gegenprobe: der alte Prefix-Match ^1.7.7 darf NICHT akzeptieren
    if grep -q "^${want}" <<< "$v_out"; then
        fail "falsch: Prefix ^${want} würde den echten ttyd -v-String akzeptieren (Live-Grube #2)"
    else
        ok "Prefix ^${want} matcht den echten String NICHT (war der Live-Bug #2)"
    fi
    # Gegenprobe: Usage-Ausgabe (ohne Argument) enthält zwar die Version,
    # aber NIE in einer Zeile "ttyd version ..." → darf nicht akzeptieren
    local usage_out
    usage_out=$("$fakebin/ttyd" 2>&1 || true)
    if grep -q "ttyd version ${want}" <<< "$usage_out"; then
        fail "falsch: Usage-Output würde als ttyd -v-Erfolg akzeptiert"
    else
        ok "Usage-Output wird NICHT als Versions-Erfolg akzeptiert (Live-Grube #1/#3)"
    fi
}

# ── NS-Runner (host-seitig) ────────────────────────────────────────────────
declare -A PRESETS=(
    [fresh_install]=fresh [id_skip]=occupied200 [dns_late]=fresh [dns_flaky]=fresh
    [dns_dead]=fresh [update_stopped]=existing-stopped [status_running]=status-running
    [status_stopped]=status-stopped [uninstall_yes]=uninstall [uninstall_confirm]=uninstall
    [dup_hostname]=dup [api_key]=fresh [version_pin]=fresh [version_latest]=fresh
    [bootstrap_fail]=fresh [help]=fresh [zero_fallback]=status-running
    [error_chain]=fresh [ttyd_version_format]=fresh
)
declare -A DNS_MODES=(
    [dns_late]=late [dns_flaky]=flaky4 [dns_dead]=dead
)
declare -A FAIL_CREATE=(
    [error_chain]=1
)
declare -A BOOTSTRAP_FAIL=(
    [bootstrap_fail]=1
)

run_case() {
    local name="$1"
    local preset="${PRESETS[$name]:-fresh}"
    local state="$WORK/state-$name"
    rm -rf "$state"
    mkdir -p "$state"
    RESULTS_FILE="$WORK/results-$name.log"
    : > "$RESULTS_FILE"
    export HARNESS_STATE="$state" HARNESS_SRC_TARBALL="$WORK/src.tar.gz" \
        HARNESS_ASSETS="$ASSETS" RESULTS_FILE FAKEBIN_PATH="$FAKEBIN" \
        HARNESS_DNS_MODE="${DNS_MODES[$name]:-ok}" \
        HARNESS_FAIL_CREATE="${FAIL_CREATE[$name]:-0}" \
        HARNESS_BOOTSTRAP_FAIL="${BOOTSTRAP_FAIL[$name]:-0}"

    if [[ "$name" == "non_root" || "$name" == "ttyd_version_format" ]]; then

        # Läuft bewusst ohne unshare (EUID bleibt unprivilegiert / braucht echte ttyd-Ausgabe)
        "case_$name"
    else
        unshare -rm bash "$SELF" --ns-setup --inner "$name" "$preset" < /dev/null
    fi

    # Ergebnis auswerten
    local o x
    o=$(grep -c '^OK' "$RESULTS_FILE" || true)
    x=$(grep -c '^FAIL' "$RESULTS_FILE" || true)
    if [[ "$x" -eq 0 ]]; then
        PASS=$((PASS + 1))
        echo "  ✔ $name  ($o Assertions)"
    else
        FAIL=$((FAIL + 1))
        FAILED_CASES+=("$name")
        echo "  ✘ $name  ($x von $((o + x)) Assertions fehlgeschlagen)"
        grep '^FAIL' "$RESULTS_FILE" | sed 's/^/      /'
    fi
}

CASES=(
    fresh_install
    id_skip
    dns_late
    dns_flaky
    dns_dead
    update_stopped
    status_running
    status_stopped
    uninstall_yes
    uninstall_confirm
    dup_hostname
    api_key
    version_pin
    version_latest
    bootstrap_fail
    help
    zero_fallback
    error_chain
    ttyd_version_format
    non_root
)

cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

# ── Inner-Dispatch: läuft INNERHALB des unshare-Mount-Namespace ────────────
# (Nach allen Funktionsdefinitionen, damit seed/case verfügbar sind.)
MODE="${1:-host}"
if [[ "$MODE" == "--ns-setup" || "$MODE" == "--inner" ]]; then
    if [[ "$MODE" == "--ns-setup" ]]; then
        shift
        mount --make-rprivate /
        mkdir -p /opt /root /usr/local/bin /usr/share/keyrings /var/log /etc/dhcp /etc/systemd/system /etc/apt/sources.list.d
        mount -t tmpfs tmpfs /opt
        mount -t tmpfs tmpfs /root
        mount -t tmpfs tmpfs /usr/local/bin
        mount -t tmpfs tmpfs /usr/share/keyrings
        mount -t tmpfs tmpfs /var/log
        mount -t tmpfs tmpfs /etc/dhcp
        mount -t tmpfs tmpfs /etc/systemd/system
        mount -t tmpfs tmpfs /etc/apt/sources.list.d
        RESOLV_SCRATCH="/tmp/codexai-harness-resolv.$$"
        : > "$RESOLV_SCRATCH"
        mount --bind "$RESOLV_SCRATCH" /etc/resolv.conf
    fi
    shift  # --inner Flag ablegen
    CASE_NAME="${1:?Case-Name fehlt}"
    PRESET="${2:?Preset fehlt}"
    shift 2
    export PATH="$FAKEBIN:$PATH"
    seed_preset "$PRESET"
    "case_$CASE_NAME"
    exit 0
fi

# ── Main (host-seitig) ─────────────────────────────────────────────────────
mkdir -p "$WORK"

echo "🧪 CodexAI-Server Mock-Harness"
echo "   Installer: $INSTALLER"

# Tarball-Fixtures bauen (simuliert den codeload-Download des Repos).
# --owner=0/--group=0: GitHub-Tarballs gehören uid 0 – im User-Namespace
# wäre ein chown auf phil-uid (1000) unmöglich ("Invalid argument").
mkdir -p "$WORK/pkgroot/CodexAI-Server-main"
cp -r "$REPO/app" "$WORK/pkgroot/CodexAI-Server-main/app"
tar --owner=0 --group=0 -czf "$WORK/src.tar.gz" -C "$WORK/pkgroot" CodexAI-Server-main

echo ""
SELECTED=("${CASES[@]}")
if [[ $# -gt 0 ]]; then
    SELECTED=("$@")
fi
for name in "${SELECTED[@]}"; do
    run_case "$name"
done

echo ""
echo "════════════════════════════════════════"
if [[ $FAIL -eq 0 ]]; then
    echo "✅ ALLE ${PASS} TESTS BESTANDEN"
    echo "════════════════════════════════════════"
    exit 0
else
    echo "❌ ${FAIL} von $((PASS + FAIL)) Tests fehlgeschlagen:"
    for c in "${FAILED_CASES[@]}"; do
        echo "   ✘ $c"
    done
    echo "════════════════════════════════════════"
    exit 1
fi
