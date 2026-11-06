#!/usr/bin/env bash
# Hooks klipper-macros into Klipper and Moonraker.
# Safe to run any number of times: it only adds what's missing.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$HOME/printer_data/config}"
LINK="$CONFIG_DIR/my_macros"
PRINTER_CFG="$CONFIG_DIR/printer.cfg"
MOONRAKER_CONF="$CONFIG_DIR/moonraker.conf"
INCLUDE_LINE="[include my_macros/*.cfg]"
ORIGIN="$(git -C "$REPO_DIR" remote get-url origin)"
BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
changed=0

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
for name in $(cd "$REPO_DIR" && ls *.cfg 2>/dev/null) $RETIRED; do
  if [ -f "$CONFIG_DIR/$name" ] && [ ! -L "$CONFIG_DIR/$name" ]; then
    mkdir -p "$CONFIG_DIR/config_backups"
    mv "$CONFIG_DIR/$name" "$CONFIG_DIR/config_backups/$name.$(date +%Y%m%d_%H%M%S)"
    sed -i "/^\[include $name\]/d" "$PRINTER_CFG"
    echo "Moved old $name to config_backups and removed its include"
    changed=1
  fi
done

# 3. Include every .cfg in the repo
if ! grep -qF "$INCLUDE_LINE" "$PRINTER_CFG"; then
  sed -i "1i $INCLUDE_LINE" "$PRINTER_CFG"
  echo "Added $INCLUDE_LINE to printer.cfg"
  changed=1
fi

# 3b. Settings tables: copy each vars/*.cfg into printer.cfg once,
#     right below the include line, if its section isn't there yet.
#     After that the table belongs to the printer; updates never touch it.
for vf in "$REPO_DIR"/vars/*.cfg; do
  [ -f "$vf" ] || continue
  section="$(grep -m1 '^\[gcode_macro' "$vf")"
  if [ -n "$section" ] && ! grep -qF "$section" "$PRINTER_CFG"; then
    awk -v inc="$INCLUDE_LINE" -v f="$vf" '
      { print }
      $0 == inc && !done { print ""; while ((getline l < f) > 0) print l; print ""; done = 1 }
    ' "$PRINTER_CFG" > "$PRINTER_CFG.tmp" && mv "$PRINTER_CFG.tmp" "$PRINTER_CFG"
    echo "Added $section settings table to printer.cfg"
    changed=1
  fi
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
install_script: install.sh
EOF
  echo "Added [update_manager klipper-macros] to moonraker.conf"
  changed=1
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
    changed=1
  fi
done

# 5. Restart, only when run by hand, only if something changed, never mid-print
if [ "$changed" = 1 ] && [ -t 1 ]; then
  state="$(curl -s localhost:7125/printer/objects/query?print_stats | grep -o '"state": *"[a-z]*"' | grep -o '[a-z]*"$' | tr -d '"' || true)"
  if [ "$state" = "printing" ] || [ "$state" = "paused" ]; then
    echo "Printer is $state. Restart Klipper and Moonraker after the print."
  else
    sudo systemctl restart moonraker klipper
    echo "Restarted Moonraker and Klipper."
  fi
fi
echo "klipper-macros is set up."