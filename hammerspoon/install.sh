#!/bin/bash
# Finplan VoiceInk Dictionary — one-line installer for staff Macs.
#
#   curl -fsSL https://raw.githubusercontent.com/iminireland/finplan-voiceink/main/hammerspoon/install.sh | bash
#
# What it does (all user-level, nothing needs an admin password unless
# /Applications requires one):
#   1. Checks macOS version and that VoiceInk is installed.
#   2. Installs Hammerspoon (official signed release) if missing.
#   3. Installs the finplan-voiceink module into ~/.hammerspoon/.
#   4. Launches Hammerspoon and walks you through the single
#      Accessibility permission it needs.
#
# Re-running is safe: it updates the module in place.
#
# Optional: pass the Finplan Slack webhook so failures alert Ross's
# test channel (stored in your Mac's Keychain, never in this repo):
#   curl -fsSL .../install.sh | bash -s -- --slack-webhook 'https://hooks.slack.com/services/...'

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/iminireland/finplan-voiceink/main/hammerspoon"
HS_DIR="$HOME/.hammerspoon"
MODULE_DIR="$HS_DIR/finplan-voiceink"
BOLD=$(tput bold 2>/dev/null || true); PLAIN=$(tput sgr0 2>/dev/null || true)

say() { printf '%s\n' "${BOLD}==>${PLAIN} $1"; }
fail() { printf '%s\n' "ERROR: $1" >&2; exit 1; }

# When run from a local checkout (bash hammerspoon/install.sh), install
# from the local files instead of downloading — used for development.
LOCAL_SRC=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/init.lua" ]; then
  LOCAL_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

say "Finplan VoiceInk Dictionary installer"

SLACK_WEBHOOK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slack-webhook) SLACK_WEBHOOK="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$SLACK_WEBHOOK" ]; then
  security add-generic-password -U -s FINPLAN_VOICEINK_SLACK -a "$USER" -w "$SLACK_WEBHOOK"
  say "Slack failure-alert webhook stored in your Keychain."
else
  say "NOTE: no --slack-webhook given — if something breaks, it will only"
  say "log locally instead of alerting Ross. Use the full command from Slack."
fi

# 1. Requirements ------------------------------------------------------
os_version=$(sw_vers -productVersion)
os_major=${os_version%%.*}
[ "$os_major" -ge 14 ] || fail "macOS 14 or later required (you have $os_version)."

install_voiceink() {
  local tmp dmg_url mount_point
  tmp=$(mktemp -d)
  dmg_url=$(curl -fsSL "https://api.github.com/repos/Beingpax/VoiceInk/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | cut -d'"' -f4)
  [ -n "$dmg_url" ] || return 1
  curl -fsSL "$dmg_url" -o "$tmp/VoiceInk.dmg" || return 1
  mount_point=$(hdiutil attach -nobrowse -readonly "$tmp/VoiceInk.dmg" \
    | grep -o '/Volumes/.*' | head -1)
  [ -n "$mount_point" ] || return 1
  ditto "$mount_point/VoiceInk.app" "/Applications/VoiceInk.app"
  hdiutil detach "$mount_point" -quiet || true
  rm -rf "$tmp"
  [ -d "/Applications/VoiceInk.app" ]
}

if [ ! -d "/Applications/VoiceInk.app" ]; then
  say "Installing VoiceInk (the dictation app, official release)..."
  if install_voiceink; then
    say "VoiceInk installed. You'll finish its own setup on first launch:"
    say "  choose trial or enter the licence Ross gives you, allow the"
    say "  microphone, and let it download its speech model."
  else
    say "Could not auto-download VoiceInk — install it from"
    say "https://tryvoiceink.com instead. Continuing; the shortcut will"
    say "work once VoiceInk is installed."
  fi
else
  say "VoiceInk already installed."
fi

# 2. Hammerspoon -------------------------------------------------------
if [ ! -d "/Applications/Hammerspoon.app" ]; then
  say "Installing Hammerspoon (the free automation engine)..."
  tmp=$(mktemp -d)
  zip_url=$(curl -fsSL "https://api.github.com/repos/Hammerspoon/hammerspoon/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*Hammerspoon-[^"]*\.zip"' \
    | head -1 | cut -d'"' -f4)
  [ -n "$zip_url" ] || fail "could not find the latest Hammerspoon release."
  curl -fsSL "$zip_url" -o "$tmp/hammerspoon.zip"
  ditto -x -k "$tmp/hammerspoon.zip" "$tmp/unzipped"
  ditto "$tmp/unzipped/Hammerspoon.app" "/Applications/Hammerspoon.app"
  rm -rf "$tmp"
  [ -d "/Applications/Hammerspoon.app" ] || fail "Hammerspoon did not land in /Applications — try again or install from https://www.hammerspoon.org"
  # Sensible defaults: start at login, menu bar icon only.
  defaults write org.hammerspoon.Hammerspoon MJAutoLaunch -bool true
  defaults write org.hammerspoon.Hammerspoon MJShowDockIconKey -bool false
  defaults write org.hammerspoon.Hammerspoon MJShowMenuIconKey -bool true
  say "Hammerspoon installed."
else
  say "Hammerspoon already installed."
fi

# 3. Module ------------------------------------------------------------
mkdir -p "$MODULE_DIR"
if [ -n "$LOCAL_SRC" ]; then
  say "Installing module from local checkout: $LOCAL_SRC"
  cp "$LOCAL_SRC/init.lua" "$MODULE_DIR/init.lua"
  cp "$LOCAL_SRC/fill.applescript" "$MODULE_DIR/fill.applescript"
else
  say "Downloading the finplan-voiceink module..."
  curl -fsSL "$REPO_RAW/init.lua" -o "$MODULE_DIR/init.lua"
  curl -fsSL "$REPO_RAW/fill.applescript" -o "$MODULE_DIR/fill.applescript"
fi

touch "$HS_DIR/init.lua"
if ! grep -q 'finplan-voiceink' "$HS_DIR/init.lua"; then
  printf '\n-- Finplan VoiceInk Dictionary (installed %s)\nrequire("finplan-voiceink")\n' \
    "$(date +%Y-%m-%d)" >> "$HS_DIR/init.lua"
  say "Module wired into Hammerspoon config."
else
  say "Module already wired in — updated in place."
fi

# 4. Launch + permission -----------------------------------------------
say "Starting Hammerspoon..."
# Open by PATH, not by name: a freshly-copied app is not yet in the
# LaunchServices index, so `open -a Hammerspoon` fails on first install
# (seen on the first staff Mac, 2026-07-03). Never die here either —
# the permission instructions below must always be shown.
open "/Applications/Hammerspoon.app" \
  || say "Could not auto-start it — open Hammerspoon from /Applications yourself."

cat <<EOF

${BOLD}One manual step (Apple requires a human for this):${PLAIN}
  If Hammerspoon asks for Accessibility access, click through to
  System Settings and switch Hammerspoon ON. If no prompt appears:
  System Settings -> Privacy & Security -> Accessibility -> enable
  Hammerspoon. Opening that pane for you now...
EOF
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true

cat <<EOF

${BOLD}Then try it:${PLAIN}
  1. Select any word (e.g. in Notes).
  2. Press right-command + ' (apostrophe).
  3. FIRST TIME ONLY: one or two popups appear saying "Hammerspoon
     wants to control System Events / VoiceInk" — click OK/Allow on
     each (that's Apple asking, and it only asks once).
  4. VoiceInk opens with the word in both boxes. Fix the replacement
     word, press return.
  5. Like magic: you are back where you were and the word is replaced.

${BOLD}The one rule:${PLAIN} if the magic ever doesn't happen, just press cmd-V —
the corrected word is always waiting on your clipboard.

If VoiceInk was just installed: open it once first and complete its
setup (trial or licence from Ross, microphone, speech model download).
If the hotkey does nothing: Hammerspoon menu-bar icon ->
Reload Config, and check System Settings -> Privacy & Security ->
Accessibility -> Hammerspoon is ON. Re-run this installer any time to
update. Problems? Slack Ross.
EOF
say "Done."
