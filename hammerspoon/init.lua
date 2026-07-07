--[[
Finplan VoiceInk Dictionary — Hammerspoon module.

Select a word or phrase anywhere, press right-cmd + ' :
  Phase 1: the selection is captured and VoiceInk opens on Word
           Replacements with the term in both fields (Original typed
           with real keystrokes, Replacement filled silently — the
           silent fill is a deliberate guardrail: + stays disabled
           until you amend the replacement word).
  Phase 2 ("the magic"): amend the replacement, press return (or +).
           A watcher notices the entry arriving in VoiceInk's
           dictionary, closes the VoiceInk window, returns to the app
           you came from, VERIFIES your selection is still the
           original word, and pastes the replacement over it. If the
           selection changed meanwhile, it silently leaves the
           replacement on the clipboard instead (the cmd-V rule) — it
           never pastes blind.

This module replaces the Karabiner rule + Keyboard Maestro macro with
one app (Hammerspoon) and one Accessibility permission. The VoiceInk
UI driving is the proven AppleScript (fill.applescript, unchanged from
the KM era) run in-process.

The watcher READS VoiceInk's dictionary store (SQLite, read-only).
Never write to that database: it is CloudKit-synced and app-owned.

Hotkeys: right-cmd + ' (device-level right command, via event tap)
         F20 (so an existing Karabiner right-cmd+' -> F20 remap also works)

Dials are at the top. Logs: ~/.hammerspoon/finplan-voiceink.log
]]

local M = {}

-- ---------------------------------------------------------------- dials
M.VERSION = "2.4.1"
local WATCH_TIMEOUT_SECS = 300 -- give up on paste-back after this long
local WATCH_POLL_SECS = 1.0
local CLIPBOARD_WAIT_SECS = 1.0 -- max wait for cmd-C to land
local DICT_STORE = os.getenv("HOME")
    .. "/Library/Application Support/com.prakashjoshipax.VoiceInk/dictionary.store"
local LOG_FILE = os.getenv("HOME") .. "/.hammerspoon/finplan-voiceink.log"
local LOG_MAX_BYTES = 1024 * 1024
local FILL_SCRIPT = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("init%.lua$", ""))
    .. "fill.applescript"
local APPLE_EPOCH_OFFSET = 978307200 -- Core Data stores seconds since 2001-01-01
local RIGHT_CMD_MASK = 0x10 -- NX_DEVICERCMDKEYMASK
local MARKER_PREFIX = "VOICEINK_SELECTION_"

-- ---------------------------------------------------------------- state
local watcher = nil -- active phase-2 timer
local watchDeadline = nil
local watchOriginal = nil
local watchPreviousApp = nil
local watchPreviousWindow = nil -- exact source window (Stage Manager rescue)
local watchPreviousElement = nil -- remembered focused text element (rescue)
local sqlite3 = require("hs.sqlite3")

-- ---------------------------------------------------------------- utils
local function log(message)
    local size = hs.fs.attributes(LOG_FILE, "size")
    if size and size > LOG_MAX_BYTES then
        os.remove(LOG_FILE .. ".previous")
        os.rename(LOG_FILE, LOG_FILE .. ".previous")
    end
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("%Y-%m-%dT%H:%M:%S ") .. message .. "\n")
        f:close()
    end
end

-- Silence-first alerting (Ross's decision, 2026-07-03):
--   - NO macOS notifications, ever. Users work in silence.
--   - Interaction hiccups are silent-but-predictable: whenever the
--     paste-back cannot happen, the replacement is left on the
--     clipboard — the user rule is "if the magic didn't happen, press
--     cmd-V". Details go to the local log only.
--   - OPERATIONAL failures (VoiceInk UI broke, store unreadable) post
--     to the Finplan test Slack channel, so Ross hears about staff
--     breakage without staff having to report it.
-- The webhook lives in the macOS Keychain (service names below) — it
-- is NEVER embedded here: this file is published in a public repo, and
-- the alert text NEVER includes captured text (could be client data).
local SLACK_KEYCHAIN_SERVICES = { "FINPLAN_VOICEINK_SLACK", "FINPLAN_AUTOMATIONS_SLACK" }

local slackWebhook = nil
local function loadSlackWebhook()
    if slackWebhook then return slackWebhook end
    for _, service in ipairs(SLACK_KEYCHAIN_SERVICES) do
        local out, ok = hs.execute(
            "security find-generic-password -w -s " .. service .. " 2>/dev/null")
        if ok and out and out:match("^https://hooks%.slack%.com") then
            slackWebhook = out:gsub("%s+$", "")
            return slackWebhook
        end
    end
    return nil
end

local function slackAlert(step, detail)
    local webhook = loadSlackWebhook()
    if not webhook then
        log("slack alert skipped (no webhook in Keychain): " .. step)
        return
    end
    local text = string.format(
        "❌ VoiceInk Dictionary failed on %s (%s)\n• step: %s\n• detail: %s",
        hs.host.localizedName(), os.getenv("USER") or "?", step, detail or "?")
    hs.http.asyncPost(webhook,
        hs.json.encode({ text = text, username = "VoiceInk Dictionary" }),
        { ["Content-Type"] = "application/json" },
        function(status)
            if status ~= 200 then log("slack alert POST failed: HTTP " .. tostring(status)) end
        end)
end

-- Trim/tidy captured text: no dead space before the first word or
-- after the last, single spaces between words. Also converts the
-- invisible unicode spaces that web pages and PDFs put into selections
-- (non-breaking space U+00A0, narrow NBSP U+202F, thin space U+2009)
-- so they can't sneak into a dictionary entry.
local function normalize(text)
    if not text then return "" end
    text = text:gsub("\194\160", " "):gsub("\226\128\175", " "):gsub("\226\128\137", " ")
    text = text:gsub("[\t\r\n]", " "):gsub("%s+", " ")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Accessibility-API selection access. Preferred over synthetic
-- keystrokes: newer macOS builds (seen on 26.5.1, 2026-07-03) deliver
-- posted cmd-C/cmd-V events to event taps but apps ignore them, so the
-- clipboard method silently fails there. AX needs only the
-- already-granted Accessibility permission and touches no clipboard.
local axlib = require("hs.axuielement")

local function axFocusedElement()
    local ok, focused = pcall(function()
        return axlib.systemWideElement():attributeValue("AXFocusedUIElement")
    end)
    if ok then return focused end
    return nil
end

local function axSelectedText()
    local focused = axFocusedElement()
    if not focused then return nil end
    local ok, sel = pcall(function() return focused:attributeValue("AXSelectedText") end)
    if ok and type(sel) == "string" then
        local cleaned = normalize(sel)
        if cleaned ~= "" then return cleaned end
    end
    return nil
end

-- Replace the current selection in place via AX. Returns true when the
-- write was accepted.
local function axReplaceSelection(replacement)
    local focused = axFocusedElement()
    if not focused then return false end
    local ok, result = pcall(function()
        return focused:setAttributeValue("AXSelectedText", replacement)
    end)
    return ok and result ~= nil
end

-- Capture the current selection: AX first, then the clipboard-marker
-- cmd-C method for apps that do not expose AXSelectedText. Returns
-- normalized text or nil.
local function captureSelection()
    local viaAx = axSelectedText()
    if viaAx then
        log("capture via accessibility API")
        return viaAx
    end
    local saved = hs.pasteboard.getContents()
    local marker = MARKER_PREFIX .. hs.host.uuid()
    hs.pasteboard.setContents(marker)
    -- Menu-driven copy first: an AX menu press is allowed where newer
    -- macOS ignores synthetic keystrokes, and Electron apps (Slack)
    -- have real menus even though their content tree is empty.
    local app = hs.application.frontmostApplication()
    local menuCopied = app and app:selectMenuItem({ "Edit", "Copy" }) or false
    if not menuCopied then
        hs.eventtap.keyStroke({ "cmd" }, "c", 0)
    end
    local deadline = hs.timer.secondsSinceEpoch() + CLIPBOARD_WAIT_SECS
    local captured = nil
    while hs.timer.secondsSinceEpoch() < deadline do
        local current = hs.pasteboard.getContents()
        if current and current ~= marker then
            captured = current
            break
        end
        hs.timer.usleep(50000)
    end
    hs.pasteboard.setContents(saved or "")
    if not captured then
        log("capture failed: no AXSelectedText and clipboard never changed "
            .. "after cmd-C (no selection, or this app exposes neither path)")
        return nil
    end
    log("capture via clipboard fallback ("
        .. (menuCopied and "menu Copy" or "cmd-C") .. ")")
    local cleaned = normalize(captured)
    if cleaned == "" or cleaned:find(MARKER_PREFIX, 1, true) == 1 then
        log("capture failed: empty selection")
        return nil
    end
    return cleaned
end

-- ------------------------------------------------- phase 2: the watcher
local function stopWatcher(reason)
    if watcher then
        watcher:stop()
        watcher = nil
        if reason then log("watcher stopped: " .. reason) end
    end
end

-- Read-only lookup: replacement text for an entry with our original word
-- added after the watch started. Returns nil when not there yet.
local lastLookupError = nil
local function lookupReplacement(original, sinceUnixTime)
    local ok, result = pcall(function()
        local db, _, errmsg = sqlite3.open(DICT_STORE, sqlite3.OPEN_READONLY)
        if not db then error(errmsg or "cannot open dictionary store") end
        local replacement = nil
        local sinceApple = sinceUnixTime - APPLE_EPOCH_OFFSET
        for row in db:nrows(string.format(
            "SELECT ZREPLACEMENTTEXT FROM ZWORDREPLACEMENT "
                .. "WHERE ZORIGINALTEXT = %s AND ZDATEADDED >= %f "
                .. "ORDER BY ZDATEADDED DESC LIMIT 1",
            string.format("'%s'", original:gsub("'", "''")),
            sinceApple - 5 -- small clock-skew allowance
        )) do
            replacement = row.ZREPLACEMENTTEXT
        end
        db:close()
        return replacement
    end)
    if not ok then
        lastLookupError = tostring(result)
        return nil
    end
    lastLookupError = nil
    return result
end

-- Write the verified replacement over the still-correct selection.
-- Prefers a direct write to `element` (survives Stage Manager's focus
-- shuffling), then the system-wide AX element, then a clipboard paste.
-- `element` is nil on the normal path — identical to the pre-2.4 write.
-- An AX write can CLAIM success without applying anything (Slack's
-- Electron composer, seen 2026-07-07: setAttributeValue returns ok, the
-- text never changes). Read back the element before trusting the write.
local function axWriteLanded(el, replacement)
    if not el then return false end
    local okSel, sel = pcall(function() return el:attributeValue("AXSelectedText") end)
    if okSel and sel == replacement then return true end
    local okVal, val = pcall(function() return el:attributeValue("AXValue") end)
    if okVal and type(val) == "string" and val:find(replacement, 1, true) then
        return true
    end
    return false
end

local function writeVerified(replacement, target, element)
    -- Ross's rule (2026-07-07): however the paste-back goes, the
    -- replacement must END UP as the last clipboard item, so a manual
    -- cmd-V always produces the new word. No clipboard restore here.
    if element then
        local ok, res = pcall(function()
            return element:setAttributeValue("AXSelectedText", replacement)
        end)
        if ok and res ~= nil and axWriteLanded(element, replacement) then
            hs.pasteboard.setContents(replacement)
            log(string.format("paste-back done (via stored AX element): %q -> %q in %s",
                watchOriginal, replacement, target and target:name() or "?"))
            return
        end
    end
    if axReplaceSelection(replacement) and axWriteLanded(axFocusedElement(), replacement) then
        hs.pasteboard.setContents(replacement)
        log(string.format("paste-back done (via AX): %q -> %q in %s",
            watchOriginal, replacement, target and target:name() or "?"))
        return
    end
    hs.pasteboard.setContents(replacement)
    local pasted = target and target:selectMenuItem({ "Edit", "Paste" }) or false
    if not pasted then
        hs.eventtap.keyStroke({ "cmd" }, "v", 0)
    end
    -- replacement deliberately left on the clipboard (Ross's rule)
    log(string.format("paste-back done (via %s): %q -> %q in %s",
        pasted and "menu Paste" or "cmd-V", watchOriginal, replacement,
        target and target:name() or "?"))
end

-- Verify the original selection is still selected in the target app,
-- then paste the replacement over it. Never pastes blind.
local function pasteBack(replacement)
    local target = watchPreviousApp
    -- CLOSE the VoiceInk window rather than hiding the app: a hidden
    -- app unhides ALL its windows the next time it activates, so the
    -- dashboard popped forward on the next dictation. With the window
    -- closed, dictation's recorder appears without any window; phase 1
    -- reopens the dashboard itself when next needed (fill.applescript
    -- sends `reopen`).
    local voiceink = hs.application.get("VoiceInk")
    if voiceink then
        local win = voiceink:mainWindow()
        if win then
            win:close()
            log("VoiceInk window closed after save")
        else
            voiceink:hide()
        end
    end

    local function toClipboard(why)
        hs.pasteboard.setContents(replacement)
        log("paste-back aborted (replacement left on clipboard): " .. why)
    end

    -- RESCUE (2.4.0, for Stage Manager): app:activate() does not reliably
    -- restore the exact window + text selection once Stage Manager has
    -- re-parented windows into stages, so the normal verify below fails
    -- and the correction drops to the clipboard. The rescue runs ONLY
    -- after that failure — the working path is untouched, so it can only
    -- recover a case that would otherwise need cmd-V. It focuses the
    -- exact source window, re-verifies, and writes straight to the
    -- remembered text element (bypassing focus entirely).
    local function rescue(primaryFail)
        local win = watchPreviousWindow
        if not (win and pcall(function() win:focus() end)) then
            toClipboard(primaryFail)
            return
        end
        hs.timer.doAfter(0.35, function()
            local sel = nil
            if watchPreviousElement then
                local ok, s = pcall(function()
                    return watchPreviousElement:attributeValue("AXSelectedText")
                end)
                if ok and type(s) == "string" then sel = normalize(s) end
            end
            if sel ~= watchOriginal then sel = captureSelection() end
            if sel ~= watchOriginal then
                toClipboard(primaryFail .. "; rescue could not confirm selection")
                return
            end
            log("Stage Manager rescue: source window re-focused, selection confirmed")
            writeVerified(replacement, target, watchPreviousElement)
        end)
    end

    if not (target and target:activate()) then
        rescue("couldn't reactivate source app")
        return
    end

    hs.timer.doAfter(0.35, function()
        local stillSelected = captureSelection()
        if stillSelected ~= watchOriginal then
            -- Silent-but-predictable: never paste blind. Try the Stage
            -- Manager rescue before dropping to the clipboard (cmd-V).
            rescue(string.format("selection %q != original %q",
                stillSelected or "(none)", watchOriginal))
            return
        end
        writeVerified(replacement, target, nil)
    end)
end

local function startWatcher(original, previousApp, previousWindow, previousElement)
    stopWatcher("superseded by new capture")
    watchOriginal = original
    watchPreviousApp = previousApp
    watchPreviousWindow = previousWindow
    watchPreviousElement = previousElement
    watchDeadline = hs.timer.secondsSinceEpoch() + WATCH_TIMEOUT_SECS
    local since = os.time()
    log(string.format("watching for dictionary entry: %q (timeout %ds)",
        original, WATCH_TIMEOUT_SECS))

    watcher = hs.timer.doEvery(WATCH_POLL_SECS, function()
        if hs.timer.secondsSinceEpoch() > watchDeadline then
            stopWatcher("timeout — no word added, paste-back cancelled (silent)")
            if lastLookupError then
                -- Not a quiet no-add: the store was unreadable all along.
                log("dictionary store unreadable during watch: " .. lastLookupError)
                slackAlert("dictionary-store-read", lastLookupError)
            end
            return
        end
        local replacement = lookupReplacement(watchOriginal, since)
        if replacement and normalize(replacement) ~= "" then
            stopWatcher("entry found")
            pasteBack(normalize(replacement))
        end
    end)
end

-- ------------------------------------------------ phase 1: the capture
local fillScriptSource = nil
local function runFillScript(selectionText)
    if not fillScriptSource then
        local f = io.open(FILL_SCRIPT, "r")
        if not f then return false, "fill.applescript not found: " .. FILL_SCRIPT end
        fillScriptSource = f:read("*a")
        f:close()
    end
    -- The proven script reads the term from the clipboard (as in the KM
    -- era): stage it, run, restore.
    local saved = hs.pasteboard.getContents()
    hs.pasteboard.setContents(selectionText)
    local ok, result = hs.osascript.applescript(fillScriptSource)
    hs.pasteboard.setContents(saved or "")
    if ok and result == "OK" then return true end
    return false, tostring(result)
end

local function addSelectedWord()
    local previousApp = hs.application.frontmostApplication()
    -- Remember the exact window and focused text element too, so
    -- paste-back can rescue the Stage Manager case where re-activating
    -- the app alone does not restore the right window/selection.
    local previousWindow = hs.window.focusedWindow()
    local previousElement = axFocusedElement()
    log(string.format("hotkey fired (front app: %s, accessibility: %s)",
        previousApp and previousApp:name() or "?",
        tostring(hs.accessibilityState())))
    local selection = captureSelection()
    if not selection then
        -- Silent no-op: nothing selected -> nothing happens (logged).
        return
    end
    log(string.format("captured %q from %s", selection,
        previousApp and previousApp:name() or "?"))

    local ok, err = runFillScript(selection)
    if not ok then
        -- Operational failure (VoiceInk UI changed, permissions lost):
        -- the one category that goes to Slack. Never include the
        -- captured text — it may be client data.
        log("fill failed: " .. (err or "?"))
        slackAlert("voiceink-fill", err or "unknown")
        return
    end
    startWatcher(selection, previousApp, previousWindow, previousElement)
end

-- ---------------------------------------------------------- activation
-- Right-cmd + ' via event tap (hs.hotkey cannot tell left from right).
local hotkeyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    if event:getKeyCode() ~= hs.keycodes.map["'"] then return false end
    local flags = event:getFlags()
    if not (flags.cmd and not flags.alt and not flags.ctrl and not flags.shift) then
        return false
    end
    if event:rawFlags() & RIGHT_CMD_MASK == 0 then return false end
    hs.timer.doAfter(0, addSelectedWord)
    return true -- swallow the keystroke
end)
hotkeyTap:start()

-- F20 binding so an existing Karabiner right-cmd+' -> F20 remap keeps
-- working (Ross's Mac). Staff Macs without Karabiner use the tap above.
local f20Hotkey = hs.hotkey.bind({}, "f20", addSelectedWord)

-- Event taps die two silent deaths in production:
--   1. Lua GC collects an unanchored tap (nothing references it after
--      startup) — the hotkey stops working days later with no error.
--   2. macOS disables a tap that can't respond in time
--      (kCGEventTapDisabledByTimeout) — phase 1 blocks the main thread
--      for several seconds while driving VoiceInk, so a keypress in
--      that window can get the tap switched off.
-- Fix 1: anchor everything to the module table (which package.loaded
-- keeps alive). Fix 2: a watchdog that re-enables the tap.
M.hotkeyTap = hotkeyTap
M.f20Hotkey = f20Hotkey
M.tapWatchdog = hs.timer.doEvery(60, function()
    if not hotkeyTap:isEnabled() then
        hotkeyTap:start()
        log("watchdog: hotkey event tap was disabled — re-enabled")
    end
end)

-- The load line carries the accessibility verdict so the installer
-- (and any human reading the log) gets ground truth, not hope.
log("finplan-voiceink " .. M.VERSION .. " loaded (accessibility: "
    .. tostring(hs.accessibilityState()) .. ")")

M.addSelectedWord = addSelectedWord
M.stopWatcher = stopWatcher
return M
