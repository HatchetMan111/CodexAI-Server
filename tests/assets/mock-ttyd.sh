#!/usr/bin/env bash
# Mock: ttyd 1.7.7 – verhält sich wie das echte Binary:
#   ttyd -v   → Versionsblock (Release + Commit-Hash) auf stdout, Exit 0
#   ohne Arg  → Usage auf stderr + Exit 1
case "${1:-}" in
    -v | --version)
        # Exakt wie ttyd 1.7.7 server.c: printf("ttyd version %s\n", TTYD_VERSION)
        printf 'ttyd version 1.7.7-40e79c7\n'
        exit 0
        ;;
    *)
        cat >&2 <<'USAGE'
ttyd is a tool for sharing terminal over the web

USAGE:
    ttyd [options] <command> [<arguments...>]

VERSION:
    1.7.7-40e79c7

Visit https://github.com/tsl0922/ttyd to get more information and report bugs.
USAGE
        exit 1
        ;;
esac