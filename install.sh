#!/bin/bash
# Toc Toc — installation sur Mac.
#   curl -fsSL https://raw.githubusercontent.com/Pablitooo5/toc-toc/main/install.sh | bash
# Construit l'app sur ton Mac, la range dans ~/.claude/toc-toc et branche les hooks de Claude Code.
set -euo pipefail

REPO="Pablitooo5/toc-toc"
DEST="$HOME/.claude/toc-toc"
APP="$DEST/TocToc.app"
SETTINGS="$HOME/.claude/settings.json"

say() { printf '%s\n' "$*"; }
fail() { printf '❌ %s\n' "$*" >&2; exit 1; }

# --- Vérifications ---
[ "$(uname)" = "Darwin" ] || fail "Toc Toc ne fonctionne que sur Mac."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || fail "Il faut macOS 14 (Sonoma) ou plus récent."
if ! xcrun --find swiftc >/dev/null 2>&1; then
  fail "Il manque les outils de développement d'Apple. Lance : xcode-select --install   puis relance l'installation."
fi
command -v python3 >/dev/null 2>&1 || fail "python3 est introuvable. Lance : xcode-select --install"

# --- Récupérer les sources (dossier local, ou téléchargement depuis GitHub) ---
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
if [ -z "$SRC" ] || [ ! -f "$SRC/main.swift" ]; then
  say "→ Téléchargement des sources"
  SRC="$(mktemp -d)"
  trap 'rm -rf "$SRC"' EXIT
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$SRC" --strip-components=1
fi

# --- Construire l'app ---
say "→ Construction de l'app (environ 30 secondes)"
pkill -x TocToc 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DEST/waiting"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/overlay.html" "$APP/Contents/Resources/overlay.html"
python3 -I "$SRC/make_sounds.py" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O "$SRC/main.swift" -o "$APP/Contents/MacOS/TocToc" \
  -framework Cocoa -framework WebKit -framework ScreenCaptureKit -framework IOKit -framework CoreAudio
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
cp "$SRC/signal.sh" "$SRC/uninstall.sh" "$DEST/"
chmod +x "$DEST/signal.sh" "$DEST/uninstall.sh"

# --- Brancher les hooks de Claude Code ---
say "→ Branchement à Claude Code ($SETTINGS)"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.avant-toc-toc.bak"
python3 -I - "$SETTINGS" "$DEST/signal.sh" <<'PY'
import json, os, sys
path, sig = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        data = json.load(f)
hooks = data.setdefault("hooks", {})

def clean(groups):
    return [g for g in groups if not any("toc-toc/signal.sh" in (h.get("command") or "") for h in g.get("hooks", []))]

def put(event, arg, matcher=None):
    group = {"hooks": [{"type": "command", "command": f'"{sig}" {arg}', "timeout": 5}]}
    if matcher:
        group = {"matcher": matcher, **group}
    hooks[event] = clean(hooks.get(event, [])) + [group]

put("Stop", "waiting")
put("Notification", "waiting keep")
put("UserPromptSubmit", "busy")
put("PreToolUse", "busy", "*")
put("PostToolUse", "busy", "*")
put("SessionEnd", "end")

tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
os.replace(tmp, path)
PY

open -g "$APP"
say ""
say "✅ Toc Toc est installé."
say "   Une icône 🔦 est apparue dans la barre des menus : clique dessus → « Lancer la démo »."
say "   Pour désinstaller : ~/.claude/toc-toc/uninstall.sh"
