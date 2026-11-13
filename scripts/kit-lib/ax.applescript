-- The System Events side of scripts/kit-ax.sh (verify.md, Surfaces and drivers). Never run by hand.
--
--   osascript ax.applescript <process> <command> [args...]
--
--   front                                      name of the frontmost application process
--   frontinfo                                  "<name><TAB><unix id>" of the frontmost application process
--   raise <pid>                                brings that process to the front (kit-ax.sh passes only the kit's own
--                                              window or the kit's own Sesame)
--   setgoto <path>                             sets the field of the folder picker's "Go to the folder" sheet (a sheet
--                                              of one of the process's windows) to the path and reads it back
--   windows                                    one line per window: "<w> x <h> at <x>,<y> title <t>"
--   window <kind> <title>                      "<w> x <h> at <x>,<y> title <t>" of the picked window
--   dump <kind> <title>                        the picked window's header line, then its element tree: for each element its
--                                              role, label="<title, else description, ...>", desc="<the description>" when it
--                                              is not the label, help="<AXHelp>" when there is one, value="<AXValue>" when
--                                              it differs from the label, then the flags. A folder row's tick reads
--                                              label="<name>" desc="<name>, <counts>, <estimate>" help="<full path>"
--   dumpmenubar                                the tree of the process's status items
--   click <label> [<help>]                     presses the element with that visible label: a control of a window, else
--                                              an item of the status item's menu (the status item is pressed to open it).
--                                              With a help, only the element whose label is the label AND whose help
--                                              (AXHelp) is the help is pressed, and the menu is not tried: a folder row's
--                                              Re-index and Remove carry the folder's name as help, so one row's button can
--                                              be told from another's
--   dumpmenu                                  opens the status item's menu, prints its element tree (every item with
--                                              its label and [disabled]), closes the menu again
--   menuitems                                  opens the status item's menu, "<role><TAB><label>" of each enabled item;
--                                              leaves it open (menuclose puts it away)
--   menuselected                               "<role><TAB><label>" of the highlighted item of the open menu, or ""
--   menuopen                                   1 when the status item's menu is open, else 0
--   menuclose                                  AXCancel (the accessibility Esc) on the open menu
--   controls <kind> <title>                    "<role><TAB><label>" for each control of the window
--   focused                                    "<role><TAB><label>" of the focused element
--   fscapable                                  index of the first window that can go full screen, 0 if none
--   fullscreen <on|off>                        sets AXFullScreen of that window; prints the state read back
--   appearance <get|light|dark>                the system Light or Dark look
--   statusitems                                label of each status item of the process
--
-- A <kind> is panel, setup, settings or window (a title that contains <title>). The panel is the
-- largest window that is neither a settings nor a setup window.
-- Errors go to stderr with the AppleScript number; kit-ax.sh maps -1743 (Automation) and -25211
-- (Accessibility) to NEEDS A PERSON.

property elementCount : 0
property maxElements : 1200
property maxDepth : 12
property truncatedTree : false

-- A value as text; "" for a missing value or anything that will not convert.
on txt(v)
	try
		if v is missing value then return ""
		return v as text
	on error
		return ""
	end try
end txt

on attr(el, attrName)
	tell application "System Events"
		try
			return my txt(value of attribute attrName of el)
		on error
			return ""
		end try
	end tell
end attr

-- The visible label of an element: title, then description, then the placeholder; a static text or
-- a button also reads as its value.
on labelOf(el)
	set t to my attr(el, "AXTitle")
	if t is not "" then return t
	set t to my attr(el, "AXDescription")
	if t is not "" then return t
	set t to my attr(el, "AXPlaceholderValue")
	if t is not "" then return t
	set r to my attr(el, "AXRole")
	if r is "AXStaticText" or r is "AXButton" or r is "AXMenuItem" or r is "AXCheckBox" or r is "AXRadioButton" then
		set t to my attr(el, "AXValue")
		if t is not "" then return t
	end if
	return ""
end labelOf

-- The help of an element (AXHelp): the full path of a folder row's tick, the folder's name on its Re-index and Remove.
on helpOf(el)
	return my attr(el, "AXHelp")
end helpOf

on frameOf(el)
	tell application "System Events"
		try
			set p to value of attribute "AXPosition" of el
			set s to value of attribute "AXSize" of el
			return ((item 1 of p) as integer as text) & "," & ((item 2 of p) as integer as text) & "," & ((item 1 of s) as integer as text) & "," & ((item 2 of s) as integer as text)
		on error
			return ""
		end try
	end tell
end frameOf

on windowHeader(w)
	tell application "System Events"
		set p to position of w
		set s to size of w
	end tell
	set ww to (item 1 of s) as integer
	set hh to (item 2 of s) as integer
	return (ww as text) & " x " & (hh as text) & " at " & ((item 1 of p) as text) & "," & ((item 2 of p) as text) & " title " & my attr(w, "AXTitle")
end windowHeader

-- The index of the picked window of the process, 0 when there is none.
on pickWindow(procName, wkind, ttl)
	tell application "System Events"
		if not (exists process procName) then return 0
		set n to count of windows of process procName
		set bestIndex to 0
		set bestArea to -1
		repeat with i from 1 to n
			set w to window i of process procName
			set wn to my attr(w, "AXTitle")
			set isSettings to (wn contains "Settings") or (wn contains "Preferences")
			set isSetup to (wn contains "Set up") or (wn contains "Setup") or (wn contains "Welcome")
			set isMatch to false
			if wkind is "settings" then
				set isMatch to isSettings
			else if wkind is "setup" then
				set isMatch to isSetup
			else if wkind is "window" then
				set isMatch to (ttl is not "") and (wn contains ttl)
			else
				set isMatch to (not isSettings) and (not isSetup)
			end if
			if isMatch then
				set s to size of w
				set area to (item 1 of s) * (item 2 of s)
				if area > bestArea then
					set bestArea to area
					set bestIndex to i
				end if
			end if
		end repeat
		return bestIndex
	end tell
end pickWindow

-- The index of the first window that can go full screen (it has a full-screen button, or is in full
-- screen now), 0 when none.
-- A file picker or a dialog has none, so it is never taken for the app's window.
on fsWindow(procName)
	tell application "System Events"
		if not (exists process procName) then return 0
		set n to count of windows of process procName
		repeat with i from 1 to n
			-- A window already in full screen has hidden its button, so it counts by its state.
			try
				if value of attribute "AXFullScreen" of window i of process procName is true then return i
			end try
			try
				set b to value of attribute "AXFullScreenButton" of window i of process procName
				if b is not missing value then return i
			end try
		end repeat
	end tell
	return 0
end fsWindow

on pad(depth)
	set s to ""
	repeat depth times
		set s to s & "  "
	end repeat
	return s
end pad

-- A line break in a text becomes ASCII 31, so a multi-line value stays on its one dump line.
on flat(t)
	set t to my swap(t, linefeed, ASCII character 31)
	return my swap(t, return, ASCII character 31)
end flat

on swap(t, find, repl)
	set oldDelims to AppleScript's text item delimiters
	set AppleScript's text item delimiters to find
	set parts to text items of t
	set AppleScript's text item delimiters to repl
	set t to parts as text
	set AppleScript's text item delimiters to oldDelims
	return t
end swap

on dumpTree(el, depth)
	if elementCount is greater than or equal to maxElements then
		set truncatedTree to true
		return ""
	end if
	set elementCount to elementCount + 1
	set r to my attr(el, "AXRole")
	set sr to my attr(el, "AXSubrole")
	set lb to my flat(my labelOf(el))
	set v to my flat(my attr(el, "AXValue"))
	set ln to my pad(depth) & r
	if sr is not "" then set ln to ln & "/" & sr
	if lb is not "" then set ln to ln & " label=\"" & lb & "\""
	-- The description is the accessibility label of a control whose title is its name ("Desktop" and "Desktop, 5 photos,
	-- about 1 min"); the help is its full path. Both are printed so a reader can tell a folder row from its neighbours.
	-- Only a control carries either (two more Apple Events for each element would slow a 600-element dump for nothing).
	if my isControlRole(r, sr) then
		set dsc to my attr(el, "AXDescription")
		if dsc is not "" and dsc is not lb then set ln to ln & " desc=\"" & dsc & "\""
		set hp to my helpOf(el)
		if hp is not "" then set ln to ln & " help=\"" & hp & "\""
	end if
	if v is not "" and v is not lb then set ln to ln & " value=\"" & v & "\""
	if my attr(el, "AXFocused") is "true" then set ln to ln & " [focused]"
	if my attr(el, "AXSelected") is "true" then set ln to ln & " [selected]"
	if my attr(el, "AXEnabled") is "false" then set ln to ln & " [disabled]"
	set fr to my frameOf(el)
	if fr is not "" then set ln to ln & " frame=" & fr
	set out to ln & linefeed
	if depth < maxDepth then
		repeat with i from 1 to my kidCount(el)
			set out to out & my dumpTree(my kidRef(el, i), depth + 1)
		end repeat
	end if
	return out
end dumpTree

-- Children are reached by position, never by the list `UI elements of el` returns: System Events holds each of those
-- by its name, so two rows named alike ("photos" under golden and under overlap, "outer" twice) both resolve to the
-- first one and a read or a press lands on the wrong row.
on kidCount(el)
	tell application "System Events"
		try
			return count of UI elements of el
		on error
			return 0
		end try
	end tell
end kidCount

on kidRef(el, i)
	tell application "System Events"
		return a reference to UI element i of el
	end tell
end kidRef

-- Presses the first element at or under el (a depth first walk by position) with that label and, when given, that help.
-- "" when none matches, else the "clicked ..." line.
on findAndPress(el, depth, wanted, wantedHelp)
	set lb to my labelOf(el)
	considering case
		set same to (lb is wanted)
	end considering
	if same and wantedHelp is not "" then
		considering case
			set same to (my helpOf(el) is wantedHelp)
		end considering
	end if
	if same then
		set r to my attr(el, "AXRole")
		tell application "System Events"
			-- No coordinate click: the window may be under another app's window, and a click
			-- at its position would reach that app. Press, else focus, else fail.
			try
				perform action "AXPress" of el
			on error
				set value of attribute "AXFocused" of el to true
			end try
		end tell
		return "clicked " & r & " \"" & lb & "\""
	end if
	if depth >= 20 then return ""
	repeat with i from 1 to my kidCount(el)
		set res to my findAndPress(my kidRef(el, i), depth + 1, wanted, wantedHelp)
		if res is not "" then return res
	end repeat
	return ""
end findAndPress

on statusBarIndex(n)
	if n >= 2 then return 2
	return n
end statusBarIndex

on statusItemIndexes(bar, labels, procName)
	set keep_ to {}
	repeat with i from 1 to count of labels
		if bar is 2 or (item i of labels) starts with (procName & ": ") then set end of keep_ to i
	end repeat
	return keep_
end statusItemIndexes

on statusItems(procName)
	tell application "System Events"
		if not (exists process procName) then error "no status item" number 1
		tell process procName
			set bar_ to my statusBarIndex(count of menu bars)
			if bar_ is 0 then error "no status item" number 1
			if bar_ is 2 then
				set items_ to menu bar items of menu bar 2
			else
				set items_ to menu bar items of menu bar 1
			end if
		end tell
	end tell
	set labels_ to {}
	repeat with it_ in items_
		set end of labels_ to my labelOf(contents of it_)
	end repeat
	set kept_ to {}
	set indexes_ to my statusItemIndexes(bar_, labels_, procName)
	repeat with k from 1 to count of indexes_
		set end of kept_ to item (item k of indexes_) of items_
	end repeat
	if (count of kept_) is 0 then error "no status item" number 1
	return kept_
end statusItems

-- The status item of the process (the first status item); an error "no status item" when there is none.
on statusItem(procName)
	return item 1 of my statusItems(procName)
end statusItem

-- True when the status item's menu is open (a closed menu has no items to read).
on menuIsOpen(it_)
	tell application "System Events"
		try
			return (count of menu items of menu 1 of it_) > 0
		on error
			return false
		end try
	end tell
end menuIsOpen

-- Opens the status item's menu by pressing the status item (AXPress, never a screen position) and returns the
-- menu. Waits up to 2 s for its items to appear.
on openStatusMenu(procName)
	set it_ to my statusItem(procName)
	if not my menuIsOpen(it_) then
		tell application "System Events"
			perform action "AXPress" of it_
		end tell
		repeat 20 times
			if my menuIsOpen(it_) then exit repeat
			delay 0.1
		end repeat
	end if
	if not my menuIsOpen(it_) then error "the status item's menu did not open" number 1
	tell application "System Events"
		return menu 1 of it_
	end tell
end openStatusMenu

-- Puts an open status item menu away with AXCancel, the accessibility Esc. Never an error.
on closeStatusMenu(procName)
	try
		set it_ to my statusItem(procName)
		if my menuIsOpen(it_) then
			tell application "System Events"
				try
					perform action "AXCancel" of menu 1 of it_
				end try
			end tell
			repeat 10 times
				if not my menuIsOpen(it_) then exit repeat
				delay 0.1
			end repeat
		end if
	end try
	return ""
end closeStatusMenu

-- Presses the item of the status item's menu with exactly that label. "" when the menu has no such item (the menu
-- is put away again), else the "clicked ..." line.
on pressMenuItem(procName, wanted)
	try
		set m to my openStatusMenu(procName)
	on error
		return ""
	end try
	tell application "System Events"
		set els to UI elements of m
	end tell
	repeat with e in els
		set el to contents of e
		set lb to my labelOf(el)
		considering case
			set same to (lb is wanted)
		end considering
		if same then
			set r to my attr(el, "AXRole")
			try
				tell application "System Events"
					perform action "AXPress" of el
				end tell
			on error msg number n
				my closeStatusMenu(procName)
				error msg number n
			end try
			return "clicked " & r & " \"" & lb & "\""
		end if
	end repeat
	my closeStatusMenu(procName)
	return ""
end pressMenuItem

on isControlRole(r, sr)
	if sr is "AXCloseButton" or sr is "AXMinimizeButton" or sr is "AXZoomButton" or sr is "AXFullScreenButton" then return false
	set roles to {"AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider", "AXMenuButton", "AXTable", "AXList", "AXOutline"}
	return roles contains r
end isControlRole

on run argv
	set procName to item 1 of argv
	set cmd to item 2 of argv
	set elementCount to 0
	set truncatedTree to false

	if cmd is "front" then
		tell application "System Events"
			return name of first application process whose frontmost is true
		end tell

	else if cmd is "frontinfo" then
		tell application "System Events"
			set p to first application process whose frontmost is true
			return (name of p) & tab & ((unix id of p) as text)
		end tell

	else if cmd is "raise" then
		-- Brings the process with that unix id to the front. Only ever called for the kit's own window.
		set wantedPid to (item 3 of argv) as integer
		tell application "System Events"
			set frontmost of (first application process whose unix id is wantedPid) to true
		end tell
		return "raised"

	else if cmd is "setgoto" then
		-- The picker's Go to the folder sheet takes no typed keys (its field keeps the old text), so its field
		-- is set through the accessibility value, then read back. Only a text field or combo box inside a
		-- sheet is touched, never the panel's own search box.
		set wanted to item 3 of argv
		tell application "System Events"
			if not (exists process procName) then error "no window" number 1
			set n to count of windows of process procName
		end tell
		repeat with i from 1 to n
			set shs to {}
			tell application "System Events"
				set w to window i of process procName
				try
					set shs to sheets of w
				end try
				if (count of shs) is 0 then
					try
						set shs to (UI elements of w whose role is "AXSheet")
					end try
				end if
			end tell
			repeat with sh in shs
				tell application "System Events"
					set els to entire contents of (contents of sh)
				end tell
				repeat with e in els
					set el to contents of e
					set r to my attr(el, "AXRole")
					if r is "AXComboBox" or r is "AXTextField" then
						tell application "System Events"
							try
								set value of attribute "AXFocused" of el to true
							end try
							set value of attribute "AXValue" of el to wanted
						end tell
						set got to my attr(el, "AXValue")
						if got is not wanted then error "the Go to field reads \"" & got & "\" after it was set to the path" number 1
						return "set " & wanted
					end if
				end repeat
			end repeat
		end repeat
		error "no Go to the folder sheet with a text field" number 1

	else if cmd is "appearance" then
		set what to item 3 of argv
		tell application "System Events"
			tell appearance preferences
				if what is "light" then set dark mode to false
				if what is "dark" then set dark mode to true
				if dark mode then
					return "dark"
				else
					return "light"
				end if
			end tell
		end tell

	else if cmd is "windows" then
		set out to ""
		tell application "System Events"
			if not (exists process procName) then return ""
			set n to count of windows of process procName
			repeat with i from 1 to n
				set out to out & my windowHeader(window i of process procName) & linefeed
			end repeat
		end tell
		return out

	else if cmd is "window" or cmd is "dump" or cmd is "controls" then
		set wkind to item 3 of argv
		set ttl to ""
		if (count of argv) is greater than or equal to 4 then set ttl to item 4 of argv
		set idx to my pickWindow(procName, wkind, ttl)
		if idx is 0 then error "no " & wkind & " window" number 1
		tell application "System Events"
			set w to window idx of process procName
		end tell
		if cmd is "window" then
			return my windowHeader(w)
		else if cmd is "dump" then
			set out to "window " & my windowHeader(w) & linefeed
			set out to out & my dumpTree(w, 0)
			if truncatedTree then set out to out & "(tree cut at " & maxElements & " elements)" & linefeed
			return out
		else
			set out to ""
			tell application "System Events"
				set els to entire contents of w
			end tell
			repeat with e in els
				set el to contents of e
				set r to my attr(el, "AXRole")
				set sr to my attr(el, "AXSubrole")
				if my isControlRole(r, sr) and my attr(el, "AXEnabled") is not "false" then
					set out to out & r & tab & my labelOf(el) & linefeed
				end if
			end repeat
			return out
		end if

	else if cmd is "click" then
		set wanted to item 3 of argv
		set wantedHelp to ""
		if (count of argv) is greater than or equal to 4 then set wantedHelp to item 4 of argv
		tell application "System Events"
			if not (exists process procName) then error "no window" number 1
			set n to count of windows of process procName
		end tell
		repeat with i from 1 to n
			tell application "System Events"
				set w to a reference to window i of process procName
			end tell
			repeat with j from 1 to my kidCount(w)
				set res to my findAndPress(my kidRef(w, j), 1, wanted, wantedHelp)
				if res is not "" then return res
			end repeat
		end repeat
		-- Not in a window: the status item's menu (Pause indexing, Resume indexing, Open Sesame, Settings…,
		-- Quit Sesame, ...). The status item is pressed to open it; the item is pressed by its label. A menu item has no
		-- help, so with a help selector the menu is not tried (the wrong row is never pressed).
		if wantedHelp is not "" then error "no element labelled \"" & wanted & "\" with help \"" & wantedHelp & "\"" number 1
		set pressed to my pressMenuItem(procName, wanted)
		if pressed is not "" then return pressed
		error "no element labelled \"" & wanted & "\"" number 1

	else if cmd is "dumpmenu" then
		try
			set m to my openStatusMenu(procName)
			set out to my dumpTree(m, 0)
		on error msg number n
			my closeStatusMenu(procName)
			error msg number n
		end try
		my closeStatusMenu(procName)
		if truncatedTree then set out to out & "(tree cut at " & maxElements & " elements)" & linefeed
		return out

	else if cmd is "menuitems" then
		set m to my openStatusMenu(procName)
		set out to ""
		tell application "System Events"
			set els to UI elements of m
		end tell
		repeat with e in els
			set el to contents of e
			set lb to my labelOf(el)
			if lb is not "" and my attr(el, "AXEnabled") is not "false" then
				set out to out & my attr(el, "AXRole") & tab & lb & linefeed
			end if
		end repeat
		return out

	else if cmd is "menuselected" then
		set it_ to my statusItem(procName)
		if not my menuIsOpen(it_) then return ""
		tell application "System Events"
			set els to UI elements of (menu 1 of it_)
		end tell
		repeat with e in els
			set el to contents of e
			if my attr(el, "AXSelected") is "true" then return my attr(el, "AXRole") & tab & my labelOf(el)
		end repeat
		return ""

	else if cmd is "menuopen" then
		try
			if my menuIsOpen(my statusItem(procName)) then return "1"
		end try
		return "0"

	else if cmd is "menuclose" then
		return my closeStatusMenu(procName)

	else if cmd is "focused" then
		tell application "System Events"
			tell process procName
				try
					set f to value of attribute "AXFocusedUIElement"
				on error
					return ""
				end try
			end tell
		end tell
		if f is missing value then return ""
		return my attr(f, "AXRole") & tab & my labelOf(f)

	else if cmd is "fscapable" then
		return (my fsWindow(procName)) as text

	else if cmd is "fullscreen" then
		set want to (item 3 of argv) is "on"
		set idx to my fsWindow(procName)
		if idx is 0 then error "no window" number 1
		tell application "System Events"
			tell process procName
				set value of attribute "AXFullScreen" of window idx to want
			end tell
		end tell
		delay 1.5
		tell application "System Events"
			tell process procName
				if value of attribute "AXFullScreen" of window idx then
					return "on"
				else
					return "off"
				end if
			end tell
		end tell

	else if cmd is "statusitems" or cmd is "dumpmenubar" then
		set items_ to my statusItems(procName)
		set out to ""
		repeat with it_ in items_
			if cmd is "statusitems" then
				set out to out & my labelOf(contents of it_) & linefeed
			else
				set out to out & my dumpTree(contents of it_, 0)
			end if
		end repeat
		return out

	else
		error "unknown command " & cmd number 2
	end if
end run
