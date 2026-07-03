use framework "Foundation"
use framework "AppKit"
use scripting additions

set wrongText to ""
try
	set wrongText to my normalizeText(my readClipboardText())
on error
	return "NO_SELECTION"
end try

if wrongText is "" or wrongText starts with "VOICEINK_SELECTION_" then
	my notifyUser("No selected text", "Select a word or phrase first.")
	return "NO_SELECTION"
end if

if my ensureVoiceInkFrontmost() is false then
	my notifyUser("VoiceInk Dictionary", "VoiceInk could not be brought to the front.")
	return "VOICEINK_FRONT_FAILED"
end if

tell application "System Events"
	if not (exists process "VoiceInk") then
		my notifyUser("VoiceInk Dictionary", "VoiceInk is not running.")
		return "VOICEINK_NOT_RUNNING"
	end if
	
	tell process "VoiceInk"
		set voiceWindow to my waitForWindow()
		if voiceWindow is missing value then
			my notifyUser("VoiceInk Dictionary", "VoiceInk did not open a window in time.")
			return "VOICEINK_NO_WINDOW"
		end if
		
		try
			perform action "AXRaise" of voiceWindow
		end try
		
		if my showDictionaryEditor(voiceWindow) is false then
			return "VOICEINK_NO_DICTIONARY"
		end if

		-- If the list was scrolled down from earlier browsing, the add
		-- fields sit off-screen even though AX can reach them. Bring the
		-- page back to the top so the user sees what the automation did.
		my scrollDictionaryToTop(voiceWindow)

		-- The fields exist in the AX tree before the page transition has
		-- settled; writes made mid-transition land on stale nodes and are
		-- lost. Give the transition a moment, then fill each field with
		-- fresh resolution + verification on every attempt.
		delay 0.35
		
		-- Original: typed with real keystrokes so VoiceInk registers it.
		if my fillFieldRobust(voiceWindow, "Original text", 1, wrongText, true) is false then
			my notifyUser("VoiceInk Dictionary", "VoiceInk could not fill the original text field.")
			return "VOICEINK_FILL_ORIGINAL_FAILED"
		end if
		
		-- Replacement: DELIBERATELY a silent accessibility write. The text
		-- appears as a starting point, but VoiceInk does not register it,
		-- so the Add (+) button stays disabled until Ross manually amends
		-- the replacement word — a guardrail against adding an unedited
		-- wrong->wrong pair.
		if my fillFieldRobust(voiceWindow, "Replacement text", 2, wrongText, false) is false then
			my notifyUser("VoiceInk Dictionary", "VoiceInk could not fill the replacement text field.")
			return "VOICEINK_FILL_REPLACEMENT_FAILED"
		end if

		-- Leave the cursor in the REPLACEMENT field — that is where the
		-- user edits next. AX focus does not register text with the app,
		-- so the +-stays-disabled guardrail is unaffected.
		try
			set repField to my resolveDictionaryField(voiceWindow, "Replacement text", 2)
			if repField is not missing value then
				set focused of repField to true
			end if
		end try
	end tell
end tell

return "OK"

on scrollDictionaryToTop(voiceWindow)
	tell application "System Events"
		tell process "VoiceInk"
			try
				set value of scroll bar 1 of scroll area 1 of group 1 of voiceWindow to 0.0
				return true
			end try
			try
				set value of scroll bar 1 of (first scroll area of voiceWindow) to 0.0
				return true
			end try
		end tell
	end tell
	return false
end scrollDictionaryToTop

on readClipboardText()
	try
		set pasteboardText to current application's NSPasteboard's generalPasteboard()'s stringForType:(current application's NSPasteboardTypeString)
		if pasteboardText is missing value then return ""
		return pasteboardText as text
	on error
		return ""
	end try
end readClipboardText

on notifyUser(titleText, bodyText)
	-- NSUserNotification is deprecated and silently dropped on modern
	-- macOS; display notification is what the user actually sees.
	try
		display notification bodyText with title titleText
	end try
end notifyUser

on ensureVoiceInkFrontmost()
	repeat 8 times
		try
			current application's NSWorkspace's sharedWorkspace()'s launchAppWithBundleIdentifier:"com.prakashjoshipax.VoiceInk" options:0 additionalEventParamDescriptor:(missing value) launchIdentifier:(missing value)
		end try
		try
			tell application "VoiceInk" to activate
		end try
		-- The paste-back closes the dashboard window (so the next
		-- dictation doesn't pop it forward); reopen recreates it.
		try
			tell application "System Events"
				if exists process "VoiceInk" then
					if not (exists window 1 of process "VoiceInk") then
						tell application "VoiceInk" to reopen
					end if
				end if
			end tell
		end try
		delay 0.15
		
		tell application "System Events"
			if exists process "VoiceInk" then
				tell process "VoiceInk"
					try
						set frontmost to true
					end try
					try
						if exists window 1 then
							perform action "AXRaise" of window 1
						end if
					end try
					if frontmost is true then return true
				end tell
			end if
		end tell
	end repeat
	return false
end ensureVoiceInkFrontmost

on waitForWindow()
	tell application "System Events"
		tell process "VoiceInk"
			repeat 50 times
				if exists window 1 then return window 1
				delay 0.05
			end repeat
		end tell
	end tell
	return missing value
end waitForWindow

on showDictionaryEditor(voiceWindow)
	repeat 10 times
		if my dictionaryEditorIsReady(voiceWindow) then
			my ensureWordReplacementsSelected(voiceWindow)
			delay 0.05
			if my dictionaryEditorIsReady(voiceWindow) then return true
		end if
		my tryPressDictionarySidebar(voiceWindow)
		delay 0.14
		if my dictionaryEditorIsReady(voiceWindow) then
			my ensureWordReplacementsSelected(voiceWindow)
			if my dictionaryEditorIsReady(voiceWindow) then return true
		end if
		my ensureWordReplacementsSelected(voiceWindow)
		delay 0.14
		if my dictionaryEditorIsReady(voiceWindow) then return true
	end repeat
	my notifyUser("VoiceInk Dictionary", "VoiceInk opened, but Dictionary did not appear.")
	return false
end showDictionaryEditor

on tryPressDictionarySidebar(voiceWindow)
	if my tryPressButtonByLabel("Dictionary") then return true
	tell application "System Events"
		tell process "VoiceInk"
			try
				click button 5 of group 1 of voiceWindow
				return true
			end try
		end tell
	end tell
	return false
end tryPressDictionarySidebar

on ensureWordReplacementsSelected(voiceWindow)
	if my tryPressButtonByLabel("Word Replacements") then return true
	tell application "System Events"
		tell process "VoiceInk"
			try
				click button 1 of scroll area 1 of group 1 of voiceWindow
				return true
			end try
		end tell
	end tell
	return false
end ensureWordReplacementsSelected

on dictionaryEditorIsReady(voiceWindow)
	set dictionaryFields to my findDictionaryFields(voiceWindow)
	return ((count of dictionaryFields) >= 2)
end dictionaryEditorIsReady

on waitForDictionaryFields(voiceWindow)
	repeat 50 times
		set dictionaryFields to my findDictionaryFields(voiceWindow)
		if (count of dictionaryFields) >= 2 then return dictionaryFields
		delay 0.05
	end repeat
	return {}
end waitForDictionaryFields

on findDictionaryFields(voiceWindow)
	set editorArea to my findEditorArea(voiceWindow)
	set visibleFields to {}
	if editorArea is not missing value then set visibleFields to my visibleTextFields(editorArea)
	set directFields to my directDictionaryFields(voiceWindow)
	set candidateFields to visibleFields
	if (count of candidateFields) < 2 then set candidateFields to directFields
	if (count of candidateFields) < 2 then return {}
	set originalField to my firstMatchingField(candidateFields, {"Original text (use commas for multiple)", "Original text"})
	set replacementField to my firstMatchingField(candidateFields, {"Replacement text"})
	if originalField is not missing value and replacementField is not missing value then
		return {originalField, replacementField}
	end if
	if (count of directFields) >= 2 then return {item 1 of directFields, item 2 of directFields}
	return {item 1 of candidateFields, item 2 of candidateFields}
end findDictionaryFields

on directDictionaryFields(voiceWindow)
	tell application "System Events"
		tell process "VoiceInk"
			try
				return {text field 1 of scroll area 1 of group 1 of voiceWindow, text field 2 of scroll area 1 of group 1 of voiceWindow}
			on error
				return {}
			end try
		end tell
	end tell
end directDictionaryFields

on fillDictionaryFieldsDirectly(voiceWindow, targetText)
	set dictionaryFields to my findDictionaryFields(voiceWindow)
	if (count of dictionaryFields) < 2 then return false
	set originalField to item 1 of dictionaryFields
	set replacementField to item 2 of dictionaryFields
	if my fillTextField(originalField, targetText) is false then return false
	if my fillTextField(replacementField, targetText) is false then return false
	return true
end fillDictionaryFieldsDirectly

on findEditorArea(voiceWindow)
	tell application "System Events"
		tell process "VoiceInk"
			try
				return first scroll area of voiceWindow
			on error
				return missing value
			end try
		end tell
	end tell
end findEditorArea

on visibleTextFields(editorArea)
	set visibleFields to {}
	tell application "System Events"
		tell process "VoiceInk"
			try
				repeat with oneField in (text fields of editorArea)
					set currentField to contents of oneField
					if my isVisibleElement(currentField) then set end of visibleFields to currentField
				end repeat
			on error
				return visibleFields
			end try
		end tell
	end tell
	return visibleFields
end visibleTextFields

on firstMatchingField(fieldList, targetTexts)
	repeat with oneField in fieldList
		set currentField to contents of oneField
		if my fieldMatchesAnyLabel(currentField, targetTexts) then return currentField
	end repeat
	return missing value
end firstMatchingField

on fieldMatchesAnyLabel(oneField, targetTexts)
	set candidateTexts to {}
	try
		set end of candidateTexts to (name of oneField as text)
	end try
	try
		set end of candidateTexts to (description of oneField as text)
	end try
	set placeholderText to my fieldPlaceholderValue(oneField)
	if placeholderText is not "" then set end of candidateTexts to placeholderText
	try
		set end of candidateTexts to (value of oneField as text)
	end try
	repeat with candidateText in candidateTexts
		try
			set candidateValue to my normalizeText(candidateText as text)
			repeat with oneTarget in targetTexts
				set targetValue to my normalizeText(oneTarget as text)
				if candidateValue is targetValue or candidateValue contains targetValue then return true
			end repeat
		end try
	end repeat
	return false
end fieldMatchesAnyLabel

on fieldPlaceholderValue(oneField)
	tell application "System Events"
		try
			return (value of attribute "AXPlaceholderValue" of oneField) as text
		on error
			return ""
		end try
	end tell
end fieldPlaceholderValue

on fillTextField(targetField, targetText)
	tell application "System Events"
		tell process "VoiceInk"
			try
				set value of targetField to targetText
			end try
			delay 0.06
			if my fieldValueMatches(targetField, targetText) then return true
		end tell
	end tell
	return false
end fillTextField

on fieldValueMatches(targetField, targetText)
	try
		return (my normalizeText(value of targetField as text) is targetText)
	on error
		return false
	end try
end fieldValueMatches

on tryPressButtonByLabel(targetText)
	tell application "System Events"
		tell process "VoiceInk"
			try
				perform action "AXPress" of (first button whose name is targetText)
				return true
			end try
			try
				click (first button whose name is targetText)
				return true
			end try
			try
				perform action "AXPress" of (first button whose description is targetText)
				return true
			end try
			try
				click (first button whose description is targetText)
				return true
			end try
		end tell
	end tell
	return false
end tryPressButtonByLabel

on normalizeText(sourceText)
	set cleanedText to sourceText as text
	set cleanedText to my replaceText(tab, " ", cleanedText)
	set cleanedText to my replaceText(return, " ", cleanedText)
	set cleanedText to my replaceText(linefeed, " ", cleanedText)
	set cleanedText to my collapseSpaces(cleanedText)
	repeat while cleanedText begins with space
		set cleanedText to text 2 thru -1 of cleanedText
	end repeat
	repeat while cleanedText ends with space
		set cleanedText to text 1 thru -2 of cleanedText
	end repeat
	return cleanedText
end normalizeText

on collapseSpaces(sourceText)
	set collapsedText to sourceText
	repeat while collapsedText contains "  "
		set collapsedText to my replaceText("  ", " ", collapsedText)
	end repeat
	return collapsedText
end collapseSpaces

on replaceText(findText, replaceWith, sourceText)
	set previousTID to AppleScript's text item delimiters
	set AppleScript's text item delimiters to findText
	set textItems to every text item of sourceText
	set AppleScript's text item delimiters to replaceWith
	set newText to textItems as text
	set AppleScript's text item delimiters to previousTID
	return newText
end replaceText

on isVisibleElement(oneItem)
	try
		if visible of oneItem is false then return false
	end try
	return true
end isVisibleElement

on resolveDictionaryField(voiceWindow, placeholderNeedle, fallbackIndex)
	-- Always resolve fresh: SwiftUI recreates these fields on page
	-- transitions, so a reference captured earlier can be a stale node
	-- that accepts writes which never reach the real UI.
	tell application "System Events"
		tell process "VoiceInk"
			try
				repeat with oneField in (text fields of scroll area 1 of group 1 of voiceWindow)
					try
						set placeholderValue to (value of attribute "AXPlaceholderValue" of oneField) as text
						if placeholderValue contains placeholderNeedle then return contents of oneField
					end try
				end repeat
			end try
			try
				return text field fallbackIndex of scroll area 1 of group 1 of voiceWindow
			on error
				return missing value
			end try
		end tell
	end tell
end resolveDictionaryField

on readFieldValue(voiceWindow, placeholderNeedle, fallbackIndex)
	-- Reads must run inside a System Events tell context; outside one the
	-- read throws and verification false-negatives (the original bug).
	set theField to my resolveDictionaryField(voiceWindow, placeholderNeedle, fallbackIndex)
	if theField is missing value then return missing value
	tell application "System Events"
		try
			return (value of theField) as text
		on error
			return missing value
		end try
	end tell
end readFieldValue

on fillFieldRobust(voiceWindow, placeholderNeedle, fallbackIndex, targetText, useKeystrokes)
	-- useKeystrokes true: focus + type real key events so the app's input
	-- system registers the text (enables the + button).
	-- useKeystrokes false: silent AX value write — the text appears but
	-- the app does not register it. Used on purpose for the Replacement
	-- field as a guardrail (see call site).
	repeat with attemptNumber from 1 to 6
		set targetField to my resolveDictionaryField(voiceWindow, placeholderNeedle, fallbackIndex)
		if targetField is not missing value then
			if useKeystrokes then
				set fieldIsFocused to false
				tell application "System Events"
					tell process "VoiceInk"
						try
							set focused of targetField to true
						end try
						delay 0.12
						try
							set fieldIsFocused to ((value of attribute "AXFocused" of targetField) as boolean)
						end try
					end tell
				end tell
				if fieldIsFocused then
					tell application "System Events"
						tell process "VoiceInk"
							try
								keystroke "a" using command down
								delay 0.05
								key code 51
								delay 0.05
								keystroke targetText
							end try
						end tell
					end tell
					delay 0.15
					set readBack to my readFieldValue(voiceWindow, placeholderNeedle, fallbackIndex)
					if readBack is not missing value then
						if my normalizeText(readBack) is targetText then return true
					end if
				end if
				-- fallback: AX write late in the attempts (text appears,
				-- app may not register it)
				if attemptNumber is greater than or equal to 4 then
					tell application "System Events"
						tell process "VoiceInk"
							try
								set value of targetField to targetText
							end try
						end tell
					end tell
					delay 0.15
					set readBack to my readFieldValue(voiceWindow, placeholderNeedle, fallbackIndex)
					if readBack is not missing value then
						if my normalizeText(readBack) is targetText then return true
					end if
				end if
			else
				-- quiet mode: AX write only, never keystrokes
				tell application "System Events"
					tell process "VoiceInk"
						try
							set value of targetField to targetText
						end try
					end tell
				end tell
				delay 0.15
				set readBack to my readFieldValue(voiceWindow, placeholderNeedle, fallbackIndex)
				if readBack is not missing value then
					if my normalizeText(readBack) is targetText then return true
				end if
			end if
		end if
		delay 0.25
	end repeat
	return false
end fillFieldRobust
