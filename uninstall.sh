#!/bin/bash
# Toc Toc — désinstallation : retire les hooks, ferme l'app, supprime ~/.claude/toc-toc.
set -euo pipefail
SETTINGS="$HOME/.claude/settings.json"
pkill -x TocToc 2>/dev/null || true
if [ -f "$SETTINGS" ]; then
  python3 -I - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
hooks = data.get("hooks")
if isinstance(hooks, dict):
    for event in list(hooks):
        kept = [g for g in hooks[event]
                if not any("toc-toc/signal.sh" in (h.get("command") or "") for h in g.get("hooks", []))]
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if not hooks:
        del data["hooks"]
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
os.replace(tmp, path)
PY
fi
rm -rf "$HOME/.claude/toc-toc"
echo "✅ Toc Toc est désinstallé."
