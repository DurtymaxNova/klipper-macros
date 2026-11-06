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

# 2. Move aside old loose copies of files the repo now provides
for f in "$REPO_DIR"/*.cfg; do
  name="$(basename "$f")"
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