#!/bin/bash
# Toc Toc — appelé par les hooks de Claude Code.
#   waiting      : Claude a fini sa réponse (Stop) → on note l'heure et le titre de la conversation
#   waiting keep : Claude attend une validation (Notification) → on note l'heure si rien n'est noté
#   busy         : tu as répondu, ou Claude retravaille → on efface
#   end          : la session se ferme → on efface
#   demo         : lance la démo
# Ne bloque jamais Claude : aucune sortie, toujours code 0. Rien n'est envoyé sur Internet.

DIR="$HOME/.claude/toc-toc"
WAIT="$DIR/waiting"
APP="$DIR/TocToc.app"
mkdir -p "$WAIT" 2>/dev/null

if [ "$1" = "demo" ]; then
  pgrep -xq TocToc || open -g "$APP"
  touch "$DIR/demo"
  exit 0
fi

INPUT=$(cat 2>/dev/null)
SID=$(printf '%s' "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
[ -z "$SID" ] && SID="default"
SID=${SID//[^A-Za-z0-9_-]/_}
F="$WAIT/$SID"

case "$1" in
  waiting)
    if [ "$2" = "keep" ] && [ -f "$F" ]; then :; else
      TITLE=$(printf '%s' "$INPUT" | /usr/bin/python3 -I -c '
import json, os, sys
d = json.load(sys.stdin)
title, path = None, d.get("transcript_path") or ""
try:
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if "\"custom-title\"" in line:
                title = json.loads(line).get("customTitle") or title
except Exception:
    pass
if not title:
    name = os.path.basename((d.get("cwd") or "").rstrip("/"))
    title = "" if not name or name.startswith("scratch-") else name
print(" ".join(str(title).split())[:60])
' 2>/dev/null)
      printf '%s\n%s\n' "$(date +%s)" "$TITLE" > "$F"
    fi
    pgrep -xq TocToc || open -g "$APP"
    ;;
  busy|end)
    rm -f "$F"
    ;;
esac
exit 0
