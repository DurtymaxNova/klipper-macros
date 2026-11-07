#!/usr/bin/env bash
# Hooks klipper-macros into Klipper and Moonraker.
# Safe to run any number of times: it only adds what's missing.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$HOME/printer_data/config}"
LINK="$CONFIG_DIR/my_macros"
PRINTER_CFG="$CONFIG_DIR/printer.cfg"
MOONRAKER_CONF="$CONFIG_DIR/moonraker.conf"
INCLUDE_LINE="[include my_macros/macros/*.cfg]"
OLD_INCLUDE_LINE="[include my_macros/*.cfg]"   # pre-"macros/" layout; migrated below
ORIGIN="$(git -C "$REPO_DIR" remote get-url origin)"
BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
changed=0
moon_changed=0

[ -f "$PRINTER_CFG" ] || { echo "No printer.cfg at $CONFIG_DIR"; exit 1; }

# 1. Link the repo into the config folder
if [ ! -L "$LINK" ]; then
  ln -s "$REPO_DIR" "$LINK"
  echo "Linked $LINK -> $REPO_DIR"
  changed=1
fi

# 2. Move aside old loose copies of files the repo now provides,
#    plus old names the repo used to have (RETIRED).
RETIRED="mypurge.cfg"
for name in $(cd "$REPO_DIR/macros" && ls *.cfg 2>/dev/null) $RETIRED; do
  if [ -f "$CONFIG_DIR/$name" ] && [ ! -L "$CONFIG_DIR/$name" ]; then
    mkdir -p "$CONFIG_DIR/config_backups"
    mv "$CONFIG_DIR/$name" "$CONFIG_DIR/config_backups/$name.$(date +%Y%m%d_%H%M%S)"
    sed -i "/^\[include $name\]/d" "$PRINTER_CFG"
    echo "Moved old $name to config_backups and removed its include"
    changed=1
  fi
done

# 3. Include every .cfg in the repo, plus this printer's settings file
SETTINGS_NAME="my_macros_settings.cfg"
SETTINGS_CFG="$CONFIG_DIR/$SETTINGS_NAME"
SETTINGS_INCLUDE="[include $SETTINGS_NAME]"

# Older installs included my_macros/*.cfg, which matches nothing since the
# macros moved into macros/ (Klipper silently ignores an empty wildcard).
if grep -qxF "$OLD_INCLUDE_LINE" "$PRINTER_CFG"; then
  if grep -qxF "$INCLUDE_LINE" "$PRINTER_CFG"; then
    grep -vxF "$OLD_INCLUDE_LINE" "$PRINTER_CFG" > "$PRINTER_CFG.tmp" && mv "$PRINTER_CFG.tmp" "$PRINTER_CFG"
  else
    awk -v old="$OLD_INCLUDE_LINE" -v new="$INCLUDE_LINE" '$0 == old { print new; next } { print }' \
      "$PRINTER_CFG" > "$PRINTER_CFG.tmp" && mv "$PRINTER_CFG.tmp" "$PRINTER_CFG"
  fi
  echo "Updated $OLD_INCLUDE_LINE to $INCLUDE_LINE in printer.cfg"
  changed=1
fi

if ! grep -qF "$INCLUDE_LINE" "$PRINTER_CFG"; then
  sed -i "1i $INCLUDE_LINE" "$PRINTER_CFG"
  echo "Added $INCLUDE_LINE to printer.cfg"
  changed=1
fi

if [ ! -f "$SETTINGS_CFG" ]; then
  cat > "$SETTINGS_CFG" <<'SETEOF'
#######################################################################################################
#   klipper-macros settings for this printer.                                                         #
#   Edit freely: this file is yours. klipper-macros updates only ever add                             #
#   tables for new macros here, they never change or remove what's already in it.                     #
#######################################################################################################
SETEOF
  echo "Created $SETTINGS_NAME"
  changed=1
fi

if ! grep -qF "$SETTINGS_INCLUDE" "$PRINTER_CFG"; then
  # Right below the macros include, so the two sit together at the top.
  awk -v inc="$INCLUDE_LINE" -v add="$SETTINGS_INCLUDE" '
    { print } $0 == inc && !done { print add; done = 1 }
  ' "$PRINTER_CFG" > "$PRINTER_CFG.tmp" && mv "$PRINTER_CFG.tmp" "$PRINTER_CFG"
  echo "Added $SETTINGS_INCLUDE to printer.cfg"
  changed=1
fi

# 3b. Settings tables (vars/*.cfg) live in the settings file.
#     - Already in the settings file: left alone, so your values stick.
#     - Inline in printer.cfg (older installs put them there): moved over
#       as-is, values and comments included.
#     - Missing: the repo's default table is added.
for vf in "$REPO_DIR"/vars/*.cfg; do
  [ -f "$vf" ] || continue
  section="$(grep -m1 '^\[gcode_macro' "$vf")"
  [ -n "$section" ] || continue
  grep -qF "$section" "$SETTINGS_CFG" && continue

  if grep -qxF "$section" "$PRINTER_CFG"; then
    python3 - "$PRINTER_CFG" "$SETTINGS_CFG" "$section" <<'PYEOF'
import sys
cfg, dest, section = sys.argv[1:4]
lines = open(cfg).read().split("\n")
i = lines.index(section)
start = i
# Take the comment banner sitting directly above the section with it.
while start > 0 and lines[start - 1].startswith("#") and not lines[start - 1].startswith("#*#"):
    start -= 1
# The section runs until the next [section] header or the SAVE_CONFIG block.
end = i + 1
while end < len(lines) and not lines[end].startswith("[") and not lines[end].startswith("#*#"):
    end += 1
block = lines[start:end]
while block and not block[-1].strip():
    block.pop()
rest = lines[:start] + lines[end:]
# Don't leave a double blank line where the block was.
if start < len(rest) and start > 0 and not rest[start].strip() and not rest[start - 1].strip():
    del rest[start]
open(cfg, "w").write("\n".join(rest))
with open(dest, "a") as f:
    f.write("\n" + "\n".join(block) + "\n")
PYEOF
    echo "Moved $section from printer.cfg to $SETTINGS_NAME (values kept)"
  else
    { echo; cat "$vf"; } >> "$SETTINGS_CFG"
    echo "Added $section settings table to $SETTINGS_NAME"
  fi
  changed=1
done

# 4. Moonraker update entry
if [ -f "$MOONRAKER_CONF" ] && ! grep -q "^\[update_manager klipper-macros\]" "$MOONRAKER_CONF"; then
  cat >> "$MOONRAKER_CONF" <<EOF

[update_manager klipper-macros]
type: git_repo
path: $REPO_DIR
origin: $ORIGIN
primary_branch: $BRANCH
managed_services: klipper
EOF
  echo "Added [update_manager klipper-macros] to moonraker.conf"
  changed=1; moon_changed=1
fi

# 4b. Plugins listed in plugins/*.conf
for pf in "$REPO_DIR"/plugins/*.conf; do
  [ -f "$pf" ] || continue
  url="$(sed -n 's/^# *repo: *//p' "$pf")"
  inst="$(sed -n 's/^# *install: *//p' "$pf")"
  dir="$(sed -n 's/^path: *//p' "$pf" | head -1)"
  dir="${dir/#\~/$HOME}"
  section="$(grep -m1 '^\[update_manager' "$pf")"
  [ -n "$url" ] && [ -n "$dir" ] || { echo "Skipping $(basename "$pf"): needs '# repo:' and 'path:'"; continue; }

  # Clone and run its installer only if it isn't already here,
  # so Moonraker re-running this script on updates is cheap.
  if [ ! -d "$dir/.git" ]; then
    echo "Installing $(basename "$pf" .conf)..."
    git clone "$url" "$dir"
    if [ -n "$inst" ]; then
      inst="${inst/#\~/$HOME}"
      chmod +x "$inst" 2>/dev/null || true
      bash "$inst" || echo "WARNING: $inst failed. Check its output above."
    fi
    changed=1
  fi

  # Add its Moonraker entry unless that section, or any entry for
  # the same folder, is already there (some installers add their own).
  if [ -f "$MOONRAKER_CONF" ] && ! grep -qF "$section" "$MOONRAKER_CONF" \
     && ! grep -qE "^path: *(~|$HOME)${dir#$HOME}/?$" "$MOONRAKER_CONF"; then
    { echo; grep -v '^#' "$pf"; } >> "$MOONRAKER_CONF"
    echo "Added $section to moonraker.conf"
    changed=1; moon_changed=1
  fi
done

# 5. Re-run this script automatically after every Mainsail update.
#    Moonraker updates with `git pull`, which fires git's post-merge hook.
#    (Moonraker's own install_script option never runs the script.)
HOOK="$REPO_DIR/.git/hooks/post-merge"
if ! grep -q "klipper-macros auto-setup" "$HOOK" 2>/dev/null; then
  mkdir -p "$(dirname "$HOOK")"
  cat > "$HOOK" <<'HOOKEOF'
#!/bin/sh
# klipper-macros auto-setup: re-run install.sh after each pull.
# Output goes to klipper-macros.log (Mainsail: Machine > Logs).
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$HOME/printer_data/logs/klipper-macros.log"
mkdir -p "$(dirname "$LOG")"
{ echo "== $(date '+%F %T') update pulled, running install.sh"; bash "$REPO/install.sh"; } >> "$LOG" 2>&1 || true
HOOKEOF
  chmod +x "$HOOK"
  echo "Installed auto-setup hook: install.sh now runs after every update"
fi

# 6. Restarts
printer_state() {
  curl -s localhost:7125/printer/objects/query?print_stats \
    | grep -o '"state": *"[a-z]*"' | grep -o '[a-z]*"$' | tr -d '"' || true
}

if [ -t 1 ]; then
  # Run by hand: restart now if anything changed, but never mid-print.
  if [ "$changed" = 1 ]; then
    state="$(printer_state)"
    if [ "$state" = "printing" ] || [ "$state" = "paused" ]; then
      echo "Printer is $state. Restart Klipper and Moonraker after the print."
    else
      sudo systemctl restart moonraker klipper
      echo "Restarted Moonraker and Klipper."
    fi
  fi
elif [ "$moon_changed" = 1 ]; then
  # Run from the update hook: Moonraker restarts Klipper itself after the
  # update, but must restart itself to pick up new update_manager entries.
  # Do that in the background, after the update has finished.
  setsid nohup sh -c '
    sleep 30
    s=$(curl -s localhost:7125/printer/objects/query?print_stats)
    case "$s" in *\"printing\"*|*\"paused\"*) exit 0 ;; esac
    curl -s -X POST localhost:7125/server/restart >/dev/null
  ' >/dev/null 2>&1 &
  echo "moonraker.conf changed: Moonraker will restart in 30 seconds"
fi
echo "klipper-macros is set up."
