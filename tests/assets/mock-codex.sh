#!/usr/bin/env bash
# Mock: Codex-CLI (offizielles Release-Binary). Wird als Inhalt des Fixture-
# Tarballs gebaut (der Installer extrahiert + installiert es) und von
# seed_full_ct direkt nach /usr/local/bin/codex gelegt.
# Verhält sich wie das echte Binary:
#   codex --version               → "codex-cli 0.170.0", Exit 0
#   codex login --with-api-key    → liest STDIN, schreibt /root/.codex/auth.json
#   codex login status            → Exit 0 wenn eingeloggt, sonst Exit 1
set -uo pipefail

STATE="${HARNESS_STATE:-/tmp/codex-mock-state}"
mkdir -p "$STATE" /root/.codex 2>/dev/null || true

case "${1:-}" in
    --version)
        echo "codex-cli 0.170.0"
        exit 0
        ;;
    login)
        case "${2:-}" in
            --with-api-key)
                # Key von STDIN lesen (wie das echte Binary)
                key=$(cat 2>/dev/null || true)
                [[ -n "$key" ]] || { echo "mock-codex: kein API-Key auf STDIN" >&2; exit 1; }
                printf '{"OPENAI_API_KEY":null,"tokens":null,"api_key":"%s"}' "$key" > /root/.codex/auth.json
                chmod 600 /root/.codex/auth.json
                echo "mock-codex: mit API-Key eingeloggt"
                exit 0
                ;;
            status)
                if [[ -f /root/.codex/auth.json || -f "$STATE/codex.logged-in" ]]; then
                    echo "Logged in using ChatGPT (mock)"
                    exit 0
                fi
                echo "Not logged in (mock)"
                exit 1
                ;;
            --device-auth)
                echo "mock-codex: Device-Code-Flow gestartet (https://chatgpt.com/codex/device, Code ABCD-1234)"
                touch "$STATE/codex.logged-in"
                exit 0
                ;;
            *)
                echo "mock-codex: login $2 nicht gemockt" >&2
                exit 64
                ;;
        esac
        ;;
    logout)
        rm -f /root/.codex/auth.json "$STATE/codex.logged-in"
        exit 0
        ;;
    *)
        echo "mock-codex: $*"
        exit 0
        ;;
esac
