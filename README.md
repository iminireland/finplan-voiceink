# Finplan VoiceInk Dictionary

Fix a misheard dictation word once, and VoiceInk gets it right forever —
with one keyboard shortcut.

## What it does

You dictate with VoiceInk and it types "Vimplan" instead of
"Finplan". Instead of fixing it by hand every time:

1. **Select the wrong word** (anywhere — email, Word, browser).
2. **Press `right command + '`** (the apostrophe key).
3. VoiceInk opens with the word ready in both boxes — **type the
   correct word** over the suggestion, **press return**.
4. ✨ You're instantly back where you were, the wrong word has been
   replaced with the right one, and VoiceInk will spell it correctly
   in every future dictation.

**The one rule to remember:** if the magic ever doesn't happen, just
press **cmd-V** — the corrected word is always waiting on your
clipboard. (That happens if you clicked somewhere else mid-edit; the
tool never pastes into the wrong place.)

## Install

Paste the one-line command Ross sends you into Terminal
(cmd+space → type "Terminal" → return) and press return. Then:

1. When Hammerspoon asks for **Accessibility** access, switch it ON in
   System Settings (the installer opens the right page for you).
2. First time you use the shortcut, click **OK/Allow** on the one or
   two "Hammerspoon wants to control…" popups — Apple asks once, then
   never again.
3. The installer downloads **VoiceInk** itself too if you don't have
   it. Open VoiceInk once and complete its own setup: choose the trial
   (or enter the licence Ross gives you), allow the microphone, and
   let it download its speech model.

Re-run the same command any time to update to the latest version.

## Privacy

Everything runs on your Mac. The words you add never leave it (they go
only into your own VoiceInk dictionary). If the tool itself breaks, a
technical alert goes to Finplan's internal Slack so Ross can fix it —
it says which Mac and which step failed, never any of your text.

## If something's not working

- Hammerspoon menu-bar icon → **Reload Config**.
- System Settings → Privacy & Security → **Accessibility** →
  Hammerspoon must be ON.
- Still stuck? Slack Ross — the log on your Mac
  (`~/.hammerspoon/finplan-voiceink.log`) will tell him exactly what
  happened.

---
Built and maintained by Ross Harrison / Finplan. Internal tool.
