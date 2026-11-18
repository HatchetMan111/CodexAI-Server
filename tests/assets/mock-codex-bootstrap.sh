#!/bin/sh
# Mock: offizieller Codex-Standalone-Installer (chatgpt.com/codex/install.sh).
# Baut das packaged-Layout, das die echte TUI braucht (Live-Grube #19: die
# nackte musl-Binary reicht NICHT – "this CLI has no complete local package"):
#   ~/.codex/packages/standalone/releases/<v>-<target>/{bin/codex,
#     bin/codex-code-mode-host, codex -> bin/codex, codex-package.json}
#   ~/.codex/packages/standalone/current -> Release-Verzeichnis
#   ~/.local/bin/codex -> current/bin/codex   (Wrapper, wie im Original)
# Env: CODEX_RELEASE (latest|Version), CODEX_NON_INTERACTIVE,
#      HARNESS_BOOTSTRAP_FAIL=1 → bricht mit Exit 7 ab (Installer-Fehlerpfad).
set -eu

if [ "${HARNESS_BOOTSTRAP_FAIL:-0}" = "1" ]; then
    echo "mock-codex-bootstrap: Installation fehlgeschlagen (HARNESS_BOOTSTRAP_FAIL=1)" >&2
    exit 7
fi

VER="${CODEX_RELEASE:-latest}"
if [ "$VER" = "latest" ]; then
    VER="0.170.0"
fi
TARGET="x86_64-unknown-linux-musl"
echo "== mock-codex-bootstrap: CODEX_RELEASE=${CODEX_RELEASE:-latest} -> ${VER}"
echo "== mock-codex-bootstrap: NON_INTERACTIVE=${CODEX_NON_INTERACTIVE:-false}"

ASSETS="${HARNESS_ASSETS:?HARNESS_ASSETS fehlt}"
ROOT="${HOME:-/root}"
STANDALONE="$ROOT/.codex/packages/standalone"
REL="$STANDALONE/releases/$VER-$TARGET"
mkdir -p "$REL/bin" "$ROOT/.local/bin"

cp "$ASSETS/mock-codex.sh" "$REL/bin/codex"
chmod 0755 "$REL/bin/codex"
printf '#!/bin/sh\necho "mock-codex-code-mode-host: $*"\n' > "$REL/bin/codex-code-mode-host"
chmod 0755 "$REL/bin/codex-code-mode-host"
ln -sfn bin/codex "$REL/codex"
printf '{"version":"%s","target":"%s","entrypoint":"bin/codex"}\n' "$VER" "$TARGET" > "$REL/codex-package.json"

ln -sfn "$REL" "$STANDALONE/current"
ln -sfn "$STANDALONE/current/bin/codex" "$ROOT/.local/bin/codex"

echo "== mock-codex-bootstrap: installiert nach $ROOT/.local/bin/codex"
