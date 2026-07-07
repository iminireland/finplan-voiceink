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

# No pipefail: this script is full of `... | grep | head -1` pipelines,
# and under pipefail an early-exiting grep/head SIGPIPEs its upstream
# and fails the whole pipeline nondeterministically (bit the first
# staff Mac on the codesign check, 2026-07-03). Failures that matter
# are checked explicitly instead.
set -eu

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
    --slack-webhook)
      [ $# -ge 2 ] || fail "--slack-webhook needs a value"
      SLACK_WEBHOOK="$2"; shift 2 ;;
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

# VoiceInk: pinned to the version the Finplan automation is tested
# against. The DMG is the developer's own notarized build, mirrored as
# a release asset on our repo (the developer's GitHub releases lag the
# direct-download channel; his download short-link blocks curl).
VOICEINK_PIN="2.0"
VOICEINK_DMG_URL="https://github.com/iminireland/finplan-voiceink/releases/download/voiceink-2.0/VoiceInk.dmg"
VOICEINK_TEAM_ID="V6J6A3VWY2" # the VoiceInk developer's Apple Developer ID

version_lt() { # true when $1 < $2 (dot-separated numerics)
  [ "$1" != "$2" ] && \
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$1" ]
}

install_voiceink() {
  local tmp mount_point
  tmp=$(mktemp -d)
  curl -fsSL "$VOICEINK_DMG_URL" -o "$tmp/VoiceInk.dmg" || { echo "diag: download failed" >&2; return 1; }
  echo "diag: dmg sha256 $(shasum -a 256 "$tmp/VoiceInk.dmg" | cut -d' ' -f1 | cut -c1-20) (expect a1c8da8ab5b3b2e6b2f5)"
  mount_point=$(hdiutil attach -nobrowse -readonly "$tmp/VoiceInk.dmg" \
    | grep -o '/Volumes/.*' | head -1 | sed 's/[[:space:]]*$//')
  [ -n "$mount_point" ] || { echo "diag: dmg would not mount" >&2; return 1; }
  # Supply-chain guardrail: only install if it carries the VoiceInk
  # developer's genuine code signature. Captured to a variable and
  # matched in-shell — no pipeline, no SIGPIPE race.
  local sig_info
  sig_info=$(codesign -dv "$mount_point/VoiceInk.app" 2>&1 || true)
  case "$sig_info" in
    *"TeamIdentifier=$VOICEINK_TEAM_ID"*) : ;; # genuine
    *)
      echo "ERROR: downloaded VoiceInk failed its signature check — not installing." >&2
      echo "diag: mount point [$mount_point]; codesign says:" >&2
      printf '%s\n' "$sig_info" | sed -n '1,8p' >&2
      hdiutil detach "$mount_point" -quiet || true
      rm -rf "$tmp"
      return 1
      ;;
  esac
  osascript -e 'tell application "VoiceInk" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do pgrep -xq VoiceInk || break; sleep 1; done
  pkill -x VoiceInk 2>/dev/null || true
  # Swap, never merge: copying over an existing bundle leaves stale
  # files from the old version inside the new one and corrupts the code
  # signature. Move the old bundle aside; roll it back if the copy fails.
  if [ -d "/Applications/VoiceInk.app" ]; then
    mv "/Applications/VoiceInk.app" "$tmp/VoiceInk.app.previous" \
      || { echo "diag: could not move the old VoiceInk aside (permissions?)" >&2
           hdiutil detach "$mount_point" -quiet || true; rm -rf "$tmp"; return 1; }
  fi
  if ! ditto "$mount_point/VoiceInk.app" "/Applications/VoiceInk.app"; then
    echo "diag: copy into /Applications failed — restoring your previous VoiceInk" >&2
    [ -d "$tmp/VoiceInk.app.previous" ] && mv "$tmp/VoiceInk.app.previous" "/Applications/VoiceInk.app"
    hdiutil detach "$mount_point" -quiet || true
    rm -rf "$tmp"
    return 1
  fi
  hdiutil detach "$mount_point" -quiet || true
  rm -rf "$tmp"
  # A successful install means the INSTALLED version is now the pin —
  # never trust "the app exists" (the old one also existed).
  local now
  now="$(installed_voiceink_version)"
  if version_lt "$now" "$VOICEINK_PIN"; then
    echo "diag: install ran but /Applications still reports VoiceInk $now" >&2
    return 1
  fi
  return 0
}

installed_voiceink_version() {
  defaults read /Applications/VoiceInk.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo ""
}

# VoiceInk resets its recording hotkeys to app defaults on a
# reinstall/update — Primary drops to "Push to Talk" with NO key, which
# silently kills hold-to-talk (seen 2026-07-06). It keeps them in
# standard prefs, so we can put the Finplan standard back:
#   Primary   F18 (keyCode 79)      hold-to-talk / tap-toggle
#   Secondary F19 (keyCode 80)      toggle
#   Paste-enhanced  Option+V (keyCode 9, modifierFlagsRawValue 524288)
# There is no separate trigger-mode pref: both keys present as "custom"
# is exactly what the UI labels "Hybrid". modeConfigurationsV2 (the
# transcription model/language profile) is deliberately NOT touched — it
# is per-user. Repair only when the keys have actually been wiped, so a
# routine re-run never disturbs a working setup or a staff member's own
# choice. To change the standard, edit the readable JSON below.
finplan_voiceink_shortcuts() {
  local BID="com.prakashjoshipax.VoiceInk"
  [ -d "/Applications/VoiceInk.app" ] || return 0
  local mode key
  mode=$(defaults read "$BID" primaryRecordingShortcut 2>/dev/null || echo "")
  key=$(defaults read "$BID" Shortcut_primaryRecording 2>/dev/null || echo "")
  if [ "$mode" = "custom" ] && [ -n "$key" ]; then
    say "VoiceInk dictation hotkeys already set — leaving them alone."
    return 0
  fi
  say "Restoring VoiceInk dictation hotkeys (F18 / F19 / Option-V)..."
  # VoiceInk owns these prefs while running and rewrites them on quit,
  # so it must be quit before we write or our values get clobbered.
  local was_running=0
  if pgrep -xq VoiceInk; then
    was_running=1
    osascript -e 'tell application "VoiceInk" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do pgrep -xq VoiceInk || break; sleep 1; done
    pkill -x VoiceInk 2>/dev/null || true
  fi
  local pri='{"modifierFlagsRawValue":0,"keyCode":79,"kind":"key"}'
  local sec='{"keyCode":80,"kind":"key","modifierFlagsRawValue":0}'
  local pst='{"keyCode":9,"kind":"key","modifierFlagsRawValue":524288}'
  defaults write "$BID" primaryRecordingShortcut   -string custom
  defaults write "$BID" secondaryRecordingShortcut -string custom
  defaults write "$BID" Shortcut_primaryRecording     -data "$(printf %s "$pri" | xxd -p | tr -d '\n')"
  defaults write "$BID" Shortcut_secondaryRecording   -data "$(printf %s "$sec" | xxd -p | tr -d '\n')"
  defaults write "$BID" Shortcut_pasteLastEnhancement -data "$(printf %s "$pst" | xxd -p | tr -d '\n')"
  defaults write "$BID" Shortcut_LegacyCustomRecordingShortcutsMigrated -bool true
  defaults write "$BID" Shortcut_LegacyKeyboardShortcutsMigrated       -bool true
  say "  Set: Primary F18, Secondary F19, paste-enhanced Option-V (\"Hybrid\")."
  [ "$was_running" -eq 1 ] && open -g "/Applications/VoiceInk.app" >/dev/null 2>&1 || true
}

current="$(installed_voiceink_version)"
if [ -z "$current" ]; then
  say "Installing VoiceInk $VOICEINK_PIN (the dictation app, developer's official build)..."
  if install_voiceink; then
    say "VoiceInk installed. You'll finish its own setup on first launch:"
    say "  choose trial or enter the licence Ross gives you, allow the"
    say "  microphone, and let it download its speech model."
  else
    say "Could not auto-install VoiceInk — install it from"
    say "https://tryvoiceink.com instead. Continuing; the shortcut will"
    say "work once VoiceInk is installed."
  fi
elif version_lt "$current" "$VOICEINK_PIN"; then
  say "Updating VoiceInk $current -> $VOICEINK_PIN (the version this tool is tested with)..."
  if install_voiceink; then
    say "VoiceInk updated — open it again after the installer finishes."
  else
    say "Could not update VoiceInk automatically — it still works, but"
    say "please update it from https://tryvoiceink.com when convenient."
  fi
else
  # Never downgrade: a newer self-updated VoiceInk stays.
  say "VoiceInk $current already installed."
fi

# Put the Finplan dictation hotkeys back if the (re)install wiped them.
finplan_voiceink_shortcuts

finplan_voiceink_paste_method() {
  local BID="com.prakashjoshipax.VoiceInk"
  [ -d "/Applications/VoiceInk.app" ] || return 0
  local method
  method=$(defaults read "$BID" pasteMethod 2>/dev/null || echo "")
  if [ "$method" = "appleScript" ]; then
    say "VoiceInk paste method already AppleScript — leaving it alone."
    return 0
  fi
  say "Setting VoiceInk paste method to AppleScript (the default synthetic"
  say "cmd-V paste is ignored by Slack's composer — found 2026-07-07)..."
  local was_running=0
  if pgrep -xq VoiceInk; then
    was_running=1
    osascript -e 'tell application "VoiceInk" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do pgrep -xq VoiceInk || break; sleep 1; done
    pkill -x VoiceInk 2>/dev/null || true
  fi
  defaults write "$BID" pasteMethod -string appleScript
  defaults write "$BID" useAppleScriptPaste -bool true
  [ "$was_running" = "1" ] && open -a VoiceInk || true
  say "  Paste method set to AppleScript."
}

finplan_voiceink_paste_method

# 2. Hammerspoon -------------------------------------------------------
if [ ! -d "/Applications/Hammerspoon.app" ]; then
  say "Installing Hammerspoon (the free automation engine)..."
  tmp=$(mktemp -d)
  zip_url=$(curl -fsSL "https://api.github.com/repos/Hammerspoon/hammerspoon/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*Hammerspoon-[^"]*\.zip"' \
    | head -1 | cut -d'"' -f4)
  [ -n "$zip_url" ] || fail "could not find the latest Hammerspoon release."
  curl -fsSL "$zip_url" -o "$tmp/hammerspoon.zip" \
    || fail "could not download Hammerspoon — check the network and try again"
  ditto -x -k "$tmp/hammerspoon.zip" "$tmp/unzipped"
  ditto "$tmp/unzipped/Hammerspoon.app" "/Applications/Hammerspoon.app"
  rm -rf "$tmp"
  [ -d "/Applications/Hammerspoon.app" ] || fail "Hammerspoon did not land in /Applications — try again or install from https://www.hammerspoon.org"
  say "Hammerspoon installed."
else
  say "Hammerspoon already installed."
fi

# Required behaviour regardless of who installed Hammerspoon or when:
# start at login (or the hotkey dies on reboot), menu icon, no dock icon.
defaults write org.hammerspoon.Hammerspoon MJAutoLaunch -bool true
defaults write org.hammerspoon.Hammerspoon MJShowDockIconKey -bool false
defaults write org.hammerspoon.Hammerspoon MJShowMenuIconKey -bool true

# 3. Module ------------------------------------------------------------
mkdir -p "$MODULE_DIR"
if [ -n "$LOCAL_SRC" ]; then
  say "Installing module from local checkout: $LOCAL_SRC"
  cp "$LOCAL_SRC/init.lua" "$MODULE_DIR/init.lua"
  cp "$LOCAL_SRC/fill.applescript" "$MODULE_DIR/fill.applescript"
else
  say "Downloading the finplan-voiceink module..."
  curl -fsSL "$REPO_RAW/init.lua" -o "$MODULE_DIR/init.lua" \
    || fail "could not download the module (network/firewall?) — try again"
  curl -fsSL "$REPO_RAW/fill.applescript" -o "$MODULE_DIR/fill.applescript" \
    || fail "could not download fill.applescript — try again"
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
say "Restarting Hammerspoon so the newest module is loaded..."
# Always restart: `open` on a running app does nothing, so a re-run
# would leave the OLD module code executing. A full restart also makes
# a freshly-granted Accessibility permission take effect. Open by PATH,
# not by name (a freshly-copied app is not yet in the LaunchServices
# index — bit the first staff Mac). Never die here — the permission
# instructions below must always be shown.
restart_epoch=$(date +%s)
pkill -x Hammerspoon 2>/dev/null || true
sleep 1
open "/Applications/Hammerspoon.app" \
  || say "Could not auto-start it — open Hammerspoon from /Applications yourself."

# Verify the module actually loaded in the restarted Hammerspoon and
# echo its accessibility verdict — ground truth, not hope.
MOD_LOG="$HS_DIR/finplan-voiceink.log"
load_line=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if [ -f "$MOD_LOG" ] && [ "$(stat -f %m "$MOD_LOG" 2>/dev/null || echo 0)" -ge "$restart_epoch" ]; then
    load_line=$(tail -1 "$MOD_LOG")
    case "$load_line" in *"loaded"*) break ;; esac
  fi
  sleep 1
done
case "$load_line" in
  *"accessibility: true"*)
    say "VERIFIED: module loaded, Accessibility working — the hotkey is live." ;;
  *"accessibility: false"*)
    say "Module loaded, but Accessibility is NOT effective yet."
    say "  Fix: System Settings -> Privacy & Security -> Accessibility ->"
    say "  REMOVE Hammerspoon from the list (- button), reopen Hammerspoon,"
    say "  and click 'Enable Accessibility' in its Preferences window."
    say "  Then re-run this installer to verify." ;;
  *"loaded"*)
    say "VERIFIED: module loaded in Hammerspoon." ;;
  *)
    say "Could not confirm the module loaded (Hammerspoon may still be"
    say "starting) — check the menu bar for the Hammerspoon icon, then"
    say "re-run this installer to verify." ;;
esac

cat <<EOF

${BOLD}Manual steps (Apple requires a human for these):${PLAIN}
  1. System Settings -> Privacy & Security -> Accessibility -> enable
     Hammerspoon (opening that pane for you now).
  2. On macOS 26 or later ALSO: Privacy & Security -> Input Monitoring
     -> enable Hammerspoon (needed to hear the hotkey at all).
  Then run this installer once more — it restarts Hammerspoon and
  verifies the permissions actually took effect.
EOF
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
if [ "$os_major" -ge 26 ]; then
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" || true
fi

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
# Self-audit: one screenshot of this block tells Ross everything.
vi_ver="$(installed_voiceink_version)"
hs_ok="missing"; [ -d /Applications/Hammerspoon.app ] && hs_ok="installed"
hs_run="not running"; pgrep -xq Hammerspoon && hs_run="running"
wh_ok="NOT set (log-only)"; security find-generic-password -s FINPLAN_VOICEINK_SLACK >/dev/null 2>&1 && wh_ok="stored"
mod_ver="$(grep -m1 'M.VERSION' "$MODULE_DIR/init.lua" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/')"
cat <<EOF

${BOLD}Install summary:${PLAIN}
  VoiceInk:        ${vi_ver:-MISSING} (this tool is tested with $VOICEINK_PIN)
  Hammerspoon:     $hs_ok, $hs_run
  Finplan module:  v${mod_ver:-?}
  Slack alerts:    $wh_ok
  Remaining human steps: Accessibility toggle (+ Input Monitoring on
  macOS 26+) if not already ON — then run this installer once more to
  verify; the one-time "wants to control" popups; VoiceInk's own
  first-run setup. If the hotkey stays dead with everything ON: a
  keyboard remapper (e.g. Karabiner) may be intercepting right-cmd —
  Slack Ross.
EOF
say "Done."
