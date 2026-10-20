# DynamicNotch

A lightweight Dynamic Island for the MacBook notch. Single process, no third-party
dependencies, zero polling.

## Install

Needs an Apple Silicon Mac on macOS 26 or later. It is built for MacBooks with a
notch, and draws its own island on displays without one.

**Homebrew:**

```bash
brew tap Agent15-AI/dynamicnotch https://github.com/Agent15-AI/DynamicNotch
```

```bash
brew install --cask agent15-ai/dynamicnotch/dynamicnotch
```

The full name matters: Homebrew only loads casks from other taps when they are
named in full, which counts as trusting that tap.

**Or download** `DynamicNotch-x.y.z.zip` from
[Releases](https://github.com/Agent15-AI/DynamicNotch/releases/latest), unzip it, and
drag `DynamicIsland.app` into `/Applications`. It has to live in `/Applications` -
macOS keeps an app's menu bar icons only for the copy it registered.

The app is not notarized (that takes a paid Apple Developer account), so the first
launch of a downloaded copy is blocked. Either clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/DynamicIsland.app
```

or open it once, then go to System Settings → Privacy & Security and click
**Open Anyway**. Homebrew does this step for you.

**Or build it yourself** with Xcode 26 or later (tested with 27.1) - see [Build and run](#build-and-run).

Nothing is asked for on first launch. Each feature asks for its permission the
first time you use it, and Settings → Modules → Permissions lists them all.

To uninstall: `brew uninstall --cask dynamicnotch`, or quit it from the menu bar
capsule (right-click → Quit) and delete the app.

## Status

All modules built. Hover opens the island - no click needed. Size is adjustable
from the gear tab. One panel per connected display.

Measured idle (M4 Air, macOS 26.5, every module enabled, island closed):
**0.0% CPU, 1 idle wakeup across 40s, 17 MB.** The only child process is the Now Playing helper,
and it exists only while media is actually playing.

For reference, `boring.notch` is 19,606 Swift LOC across 12 SPM dependencies and
runs three processes (app + XPC helper + a perl MediaRemote adapter).

## Menu bar

Works like Ice. The capsule sits at the right-hand end of the menu bar - only
Control Center, Siri and the clock are right of it, because macOS pins those.
Click it to hide icons; it turns into an outlined capsule, and clicking that (or
`⌘⌃B`) brings them back. Right-click for Settings and Quit. Revealed icons hide
again by themselves after 15 seconds (Settings → Menu Bar, like Ice's
auto-rehide), but never while one of their menus is open or the pointer is in
the bar. It launches at login (Settings → General to turn that off).

Not a chevron on purpose: macOS 27 draws its own « overflow button, and that one
moves icons to the far side of the notch instead of hiding them. Hiding also folds
an open « first, so nothing is left parked left of the notch.

**Which icons hide is a switch per icon** in Settings → Menu Bar, listed in bar
order, Apple's included. Apps default to hidden and Apple's icons to shown -
Ice's out-of-the-box split.

**Reordering** is Ice's layout editor, rebuilt (`Views/MenuBarLayout.swift`):
Settings → Menu Bar → Layout shows two strips, **Shown** and **Hidden**, made of
the icons' real pixels (one ScreenCaptureKit picture of the bar, cropped per
icon and drawn at native size; app icons stand in until an icon has been seen,
for icons folded behind the «, or without Screen Recording). The bar is
transparent on 27, so each slice carries wallpaper: a second capture of just the
Wallpaper window is subtracted to lift the icon off it (`MenuBarLayout.lifted`). Drag a tile and the others slide apart under the pointer; drop it and
the real icon is ⌘-dragged next to its new neighbour. Dragging between strips
flips whether it hides. Like Ice's `LayoutBarItemView`/`LayoutBarContainer`, the
strips are AppKit views with an `NSDraggingSession`; unlike Ice, a rightward drag
anchors to the icon it passed rather than the one after it, because the strips
do not show where the other section's icons sit in between.

Moves go through `MenuBarHider.arrange`: it opens the « so folded icons have real
frames (read from each owner's own extras bar - the agent's tree keeps phantom
ones), then ⌘-drags one misplaced icon at a time, always leftwards, reading the
bar back after each drop. Control Center, Siri and the clock cannot be moved, by
macOS, so they are left out of the strips. Settings makes the app a regular app
while it is open - macOS 27 draws no menu bar at all while an accessory app is
active, which silently swallowed every drag.

**Right-click detection.** On 27 the click reaches the app second-hand from
`MenuBarAgent`, so `NSApp.currentEvent` can be a stale event - one carrying ⌃
turned every left-click into the menu. A global `rightMouseDown` monitor (the
press is delivered to the agent, so it is "global" to us) decides instead, and
the menu is popped up at the pointer - attaching it and calling `performClick`
only sometimes opened it on 27.

### How, on macOS 27

macOS 27 draws the whole bar as one window owned by `MenuBarAgent`. The per-icon
windows Ice moved are gone, which is exactly why Ice hangs on "Loading menu bar
items". `CGSGetProcessMenuBarWindowList` returns 2 windows; there is no per-icon
id left to address.

- **Hiding** uses the visibility restriction behind macOS 27's assessment (exam)
  mode, from the private `MenuBarClientCore` framework: `MenuBarShim` hands
  `MBAssessmentModeAssertion` the system items and bundle ids that may stay, and
  macOS hides the rest and reflows the bar. The same mechanism Pelmet and Hidden
  Bar ship. It is bound to this process - quit or crash and every icon returns.
- **Position** is a real ⌘-drag posted at the HID level, off the main thread
  (our own item's drag tracking runs on the main thread, and posting from there
  makes the drop revert). It runs only when the capsule is not already rightmost,
  only while nobody has touched the mouse or keyboard for 1.5s, and never while a
  fullscreen app has the bar tucked away. macOS remembers the position across
  relaunches.
- **The « overflow.** A new status item is born leftmost, and on a notched
  display with a full bar the leftmost icons fold behind macOS's own « button -
  which is why the capsule used to be invisible. Its frame is then a phantom.
  Placement opens the « first (the capsule appears left of the notch with a real
  frame), drags it to the right end, and folds the « back.

Measured on this Mac (1710pt notched display, 16 icons): capsule born at x=980
behind «; after « + ⌘-drag at x=1423, directly left of Control Center (1467),
Siri (1508) and the clock (1540). After a relaunch it came back at 1423.

### Limits macOS sets

- **By app, not by icon.** The restriction takes bundle ids, so an app with two
  icons hides both.
- **Nine Apple items only.** Battery, Bluetooth, displays, input menu, sound,
  Wi-Fi and screen mirroring can each be kept; Control Center and the clock always
  stay. Apple's other modules - Focus and the like - hide whenever anything is
  hidden and cannot be kept; the list says so beside each. **Now Playing** is
  the exception in the UI: put it in Shown and `NowPlayingStandIn` shows the
  app's own Now Playing icon in its place while icons are hidden (only while
  something plays, like Apple's; a click opens the island's media controls),
  ⌘-dragged once to where you put it. Pelmet ships the same kind of stand-in.
- **Icons with no app bundle** (a script's status item, say) always hide with the
  rest, as does an app running from a second copy outside `/Applications` - the
  restriction only matches the copy LaunchServices resolves. That is also why
  `make.sh` installs to `/Applications`.
- **Clicking the clock** opens Notification Center, which macOS refuses while a
  restriction is held. The click is caught, the restriction dropped for the click
  and put straight back: hidden icons flicker for a moment, Notification Center
  opens.
- If `MenuBarAgent` restarts it drops the restriction. A kqueue process source
  on the agent's pid fires when it exits, and the restriction goes back on as
  soon as launchd has the new agent up. It used to be a pid check every three
  seconds for as long as icons were hidden - measured as nearly every idle
  wakeup the app had (2-5 per 8s); with the exit source it is 0 per 10s.

"Remove Apple icons from the menu bar entirely" at the bottom of the tab is the
older, different switch: `SystemMenuBarItems` writes the per-icon value System
Settings → Menu Bar uses (`com.apple.controlcenter`, per-host) and restarts the
agent, taking the icon out for good rather than hiding it on click.

The toggle is also a distributed notification, for Shortcuts, Raycast or a
script:

```swift
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("dev.local.dynamicisland.toggleMenuBar"),
    object: nil, deliverImmediately: true)
```

## Command bar

`⌥Space`. Apps, files, the island's own actions, clipboard history, sums, and
sentences that have an answer. Nothing runs while it is shut: the app list is
built when it opens and dropped when it closes, the Spotlight query is stopped
on the way out, and no index is kept between openings.

**Results are grouped, and a computed answer is a card.** A row is the wrong
shape for `12pm here in london` - given a row it is a sentence to read, given a
card it is two numbers to compare. Under each half is a caption saying what was
understood: `12:00 PM · Singapore · SGT` on the left is how you catch it reading
`12pm` as noon when you meant midnight, and `London · GMT+1` on the right is how
you catch it picking the wrong London. A card showing only the answer is a card
you have to trust blindly.

**`⌘K` opens what else the selected result can do** - open, reveal in Finder,
copy the path, park a file on the shelf, paste the answer into the app behind.
The footer names both keys, because second actions nobody can find are second
actions nobody has.

**Nothing matching shows what the words could still mean** rather than an empty
panel: define the word, or search Google, DuckDuckGo or GitHub. An empty result
list under a typed query reads as broken.

### Sentences with an answer

`Modules/Interpret.swift`. Two kinds, and Foundation does nearly all of both.

- **Times.** `12pm in london`, `12pm here in london`, `9am london in tokyo`,
  `now in nyc`, `next tuesday 3pm in berlin`. `NSDataDetector` parses the time
  and `TimeZone.knownTimeZoneIdentifiers` *is* the city map - `Europe/London`
  carries its own city in the last path component, so no city database is
  shipped beside the one macOS updates with the tzdata. A short alias table
  covers the cities that identifier does not name, which is mostly India:
  Mumbai, Delhi and Bengaluru all live under `Asia/Kolkata`.

  The detector hands back a `Date` built in the Mac's own zone, which is the
  wrong instant the moment the question names somewhere else - `9am london` is
  9am in London, not 9am here. So the wall-clock components are pulled out
  locally and rebuilt in the source zone. Measured: `12pm` in Singapore reads
  `5:00 AM` in London, and `9am london` reads `5:00 PM` in Tokyo. Crossing a
  date boundary is marked `(+1d)`, because that is the thing people are asking.

- **Units.** `5km in miles`, `180c in f`, `4.5gb in mb`, `3 days in hours`,
  `2*3 kg in lb`. `Measurement` converts, including the offsets that make °C to
  °F work, so nothing here does arithmetic - it is a table of names and a call.
  The number may be a sum, because `Calculator` already parses sums.

  `converted(to:)` will not refuse a nonsense conversion: hand it a mass and a
  length and it runs the arithmetic through whatever base units it was given and
  returns a confident wrong number. So the two are checked against each other
  first - by **base unit**, not by class, because a unit built here is not the
  same dynamic type as one of Foundation's own constants. `3 days in hours`
  failed a class comparison while converting perfectly well.

Currency is deliberately absent. It is the one conversion whose answer changes
by the minute and cannot be computed offline, so it needs a rate fetch and a
cache rather than a lookup table.

### Files

`Modules/FileSearch.swift`. Spotlight's index, asked after three letters and
debounced by 150ms. No crawler, no index, no folder watching - `NSMetadataQuery`
is a question asked of the index macOS already maintains. `mdfind` would be a
subprocess per keystroke and would throw the sort keys away.

Two things make the difference between this and the usual hand-rolled file
search:

- **Sorted by `kMDItemLastUsedDate`, descending.** The file you want is nearly
  always one you touched recently. Name relevance is the tiebreaker, not the
  primary key.
- **The noise is cut.** An unfiltered query for `config` is several thousand
  bundle internals and caches. `/System`, both `Library` folders,
  `node_modules`, `site-packages`, `__pycache__`, `DerivedData`, `.git` and the
  insides of `.app` and `.framework` bundles are dropped. Measured on `Interpret`:
  94 hits from Spotlight, 93 of them library noise, and the one file that was
  meant sat at index 16.

**A query is live once it has gathered** - it keeps posting updates as the disk
changes - so it is stopped and dropped when the bar closes. One left running is
a permanent wakeup source, which is the single thing this app is built not to
have.

A file result carries its folder, because two files called `index.html` are
otherwise the same result twice.

### Matching

Substring matching cannot find Visual Studio Code from `vsc`, which is how
everybody types it. Matching is a scored subsequence instead: letters that start
a word and letters found next to each other beat letters scattered through the
middle, which is the difference between `saf` putting Safari first and putting
Sound Safety Monitor first.

Command titles are sentences, and across a sentence a plain subsequence match
means almost nothing - `term` found "Toggle dark mode" and, because commands are
listed above applications, put it over Terminal. So commands additionally demand
that every letter either continues the previous one or starts a word.
Applications do not, because they are short and the strictness would stop
`tunes` finding iTunes.

That strictness has a trap worth naming: taking the first occurrence of a letter
and testing it afterwards is what a naive matcher does, and it is wrong here.
`colour` found the c in "Pi**c**k colour", failed the word-start test on it, and
gave up while the real match sat three letters later. The search itself has to
skip to a position that qualifies.

**Not every source is worth the same.** A match among installed applications is
far more likely to be the thing meant than a match among files: there are a
hundred of the former and hundreds of thousands of the latter, and a short
filename scores well on a short query purely by being short. Measured before
weighting them: `saf` answered `safe.tcl`, `safetk.tcl`, `safety.md` and
`safety.py` above Safari. Applications carry 1.3, commands 1.2, files 0.7, and
Safari leads again.

### What it learns

`Modules/Frecency.swift`. Picking a result is recorded, and results you pick
rank higher next time - decayed by half every fortnight, so a habit you drop
fades instead of being remembered for good.

**Exponential decay with a half-life, not the bucketed multipliers** that
[z](https://github.com/rupa/z), autojump and
[zoxide](https://github.com/ajeetdsouza/zoxide/wiki/Algorithm) use (×4 within
the hour, ×2 within the day, ÷2 within the week, ÷4 beyond). Buckets are a 16×
swing a single access can trigger by crossing an hour boundary, so one visit to
something long dormant re-weights its whole history at the top multiplier and
the list lurches. Firefox ran
[bucketed weights](https://firefox-source-docs.mozilla.org/browser/urlbar/ranking.html)
for years and [moved off them](https://github.com/mozilla/application-services/issues/610);
[`fre`](https://github.com/camdencheek/fre) was written specifically to fix that
artefact. Decay is smooth, so a revisit moves an item proportionally rather than
promoting it a category.

One `Double` and one timestamp per item, not a list of visits. Multiplying the
stored score by `2^(-age / halfLife)` before adding 1 is arithmetically the same
as summing `2^(-age/halfLife)` over every access ever made, because the decay
factors compose - verified against the full sum to six decimal places. The
history is already in the number.

That identity also removes the maintenance job. zoxide sweeps its database once
the total passes `_ZO_MAXAGE`, dividing every score down and evicting what falls
under 1. Here a steady habit converges by itself on
`1 / (1 - 2^(-gap/halfLife))` - measured at 3.4 for something opened weekly,
20.7 daily, 485 hourly. Nothing runs on a timer to keep it bounded, which
matters more here than in a shell tool.

**Usage multiplies the match score; it is never added to it.** A flat bonus lets
something heavily used but badly matched overtake something matched perfectly -
type `term` and get a favourite app that merely contains those letters instead
of Terminal. Scaling keeps the order match-first: usage separates results that
already match comparably well and never rescues a poor one. The boost is
logarithmic and capped at 1.9, so the hundredth launch of an app does not bury
everything else for good.

Measured, from a cleared table: picking **Lock screen** once moved it from 116
to 129, over LockDown Browser at 122. Picking **Grammarly for Safari** two
hundred times - a boost of 1.861, all but the ceiling - took it to 101, still
below a never-once-opened Safari at 115. A better match wins.

**Sections are ordered by their best member**, not by a fixed list. With
Commands permanently above Applications, the app opened twenty times a day still
loses to a command that merely matches, however much the ranking has learned -
which defeats the point of learning. The answer card stays pinned at the top and
the web fallbacks stay pinned at the bottom; everything between is sorted.

Settings ▸ Command bar has **Forget what I use most** for when the ordering has
learned something you disagree with.

### Figma

Off by default, because there is nothing to show without a token. Figma's API
has no search endpoint, so this is not a search: teams give projects, projects
give files, and the list is fetched once per opening at most every 30 minutes
and matched locally. Same ranking principle as files - most recently modified
first. The list is cached to disk, so the first opening after a launch has
something to show before the network answers.

Set it up in Settings ▸ Command bar: a personal access token with file content
read access, and the team id from a team URL (`figma.com/files/team/<id>/…`).
The team id has to be pasted because Figma offers no endpoint that lists the
teams an account belongs to.

**The token goes in the Keychain, not in `Settings`.** `Settings` is
UserDefaults, which is a plist in the user's container readable by any process
running as this user, and a Figma token reads every file in every team the
account can see. This is the app's first stored secret and it is kept where
secrets belong.

Figma is deliberately written as one integration at one call site, with no
provider protocol and no plugin host behind it. A second such integration is not
an argument for an abstraction; it is an argument for script commands, where the
user's own script carries its own credentials.

### Menu commands

`Modules/MenuSearch.swift`. Every command in the menus of the app you were just
in - "Export as PDF", "Merge Cells", "Toggle Word Wrap" - the things four levels
into a menu you otherwise go hunting for with the mouse. Paletro is an entire
app for this and Raycast folded it in as Search Menu Bar Items. It is the one
command-bar feature that works in software this app knows nothing about.

The menus are read once per bar opening, on the first query long enough to match
something, and thrown away on close. No cache between openings: half of any
menu is disabled until something is selected, so a tree kept any longer would be
wrong more often than it was fast. Bounded at five levels and two thousand
items, because Xcode's menu bar is deeper than that and a bar that stalls while
you type is worse than one that misses a command five submenus down.

Three details that are easy to get wrong:

- **Read before activating.** The bar activates to take the keyboard, and once
  it does, `frontmostApplication` is us. `prepare()` runs first for that reason.
- **`AXUIElementSetMessagingTimeout`.** The AX API blocks the calling thread
  until the target answers, and the target may be beachballing - which is
  exactly when someone reaches for a launcher. 0.4s.
- **Press the ancestors first.** Some apps populate a submenu only once its
  parent has opened, so a press on the leaf alone lands on a stale element. The
  chain is pressed root-first, the way the mouse would open it.

Measured against the front app: `new` finds "New Session ⌘N" under File, "New
Session Below ⌃⌘-" three levels down under View ▸ Split View, and `quit` finds
"Quit Claude ⌘Q". Needs Accessibility; without it the section is absent.

### Snippets

Text you retype, behind a short name, with `{clipboard}`, `{date}`, `{time}`
and `{uuid}` filled in when it is used rather than when it is listed.

Deliberately **not** an expander. Watching for a trigger as you type needs a
keyboard tap running for every keystroke in every app forever, which is the one
thing this app refuses to do - see the power rules. Vorssaint and Raycast both
expand; both pay for it. A snippet is inserted from the command bar instead,
which costs nothing when you are not using it and works in software that eats
synthetic keystrokes anyway.

### Finder keys

⌘X to cut files, ⌘V to move them, F2 to rename, and an image on the clipboard
pasted as a real PNG file.

ponytail: **nothing here moves a file.** The Finder can already move on paste -
that is ⌥⌘V, "Move Item Here", shipped but hidden behind a modifier nobody
finds. ⌘X presses ⌘C and remembers; ⌘V presses ⌥⌘V. The whole feature is a remap
of two keys onto a command Apple already wrote. Apple's objection to a real cut
is that a cut file can be lost if you never paste; this inherits copy semantics
and so inherits the answer - forget to paste and nothing happened. A pending cut
expires after 90 seconds so it cannot turn an ordinary paste into a move ten
minutes later.

**The keys are claimed only while the Finder is in front**, registered on
`didActivateApplication` and dropped when it leaves. A global ⌘X and ⌘V would
take those keys from every other app on the Mac. It is also why this needs no
event tap: the one thing that would cost a wakeup per keystroke is the one thing
it does not do.

And there is no keystroke loop, which is the trap here - a registered ⌘V that
re-posts ⌘V catches its own synthetic keystroke forever. ⌘V is claimed only when
it has something to do: a cut is pending, or the clipboard holds an image the
Finder would refuse. The cut path unregisters before it posts ⌥⌘V; the image
path writes a file and posts nothing at all.

The destination folder comes from the Finder itself, which needs the Apple
Events permission macOS asks for on first use. Refused, the PNG goes to the
Desktop and the receipt says so.

### Ports

`lsof -nP -iTCP -sTCP:LISTEN`, parsed from its `-F` field format rather than its
columns - process names contain spaces. The answer to "address already in use"
without leaving for a terminal. Stop sends SIGTERM, the signal a process can
clean up after; one that ignores it would have needed SIGKILL from a terminal
too, and killing harder from a menu bar app is not a decision worth making on
someone's behalf. Only this user's processes, which is what `lsof` without root
shows and also the only set worth offering to stop.

### Homebrew

Search, install and remove without a terminal. `brew` is the whole
implementation - parsing formulae.brew.sh would be a second source of truth
about what is installed locally and would still need `brew` to act on it. The
installed list is fetched alongside the search so a row can say whether it is
already here, which is the first thing you want to know and the thing `brew
search` does not tell you.

One bug worth recording: `brew search` writes its headings and its failures to
the same stream as its results, so "Error: No formulae or casks found" arrived
as a package named `Error:` - with an ANSI colour escape still round it, because
`HOMEBREW_COLOR=0` is not honoured on that line. Rather than blacklisting each
thing it can say, only what a package name can actually look like is accepted.

### Sources

Every app making a sound, as a line of chips under the player. Spotify paused
and a browser tab playing are both there: the dot is filled while samples are
actually flowing and hollow while the app holds the output open but is quiet.
The one with the gold ring and the waveform owns the Now Playing session, which
is to say the scrubber above belongs to it. Clicking a chip brings that app
forward.

**There is one timeline, and there can only be one.** macOS models Now Playing
as a single session - the vendored adapter exports
`MRMediaRemoteGetNowPlayingClient`, singular - and whichever app claimed it last
owns it. A video in a browser tab usually claims none at all. So a second
scrubber is not something this app declines to draw; it is something no API on
the Mac can answer. What CoreAudio *does* know is every process holding an
output stream and whether each is pushing samples, which is what the chips show,
and what `VolumeMixer` already tracked.

Levels stay in the Mixer tab. A list with a slider per row was built first and
clipped its second row in half against the divider - the panel is 196pt and the
player, lyrics and two sliders already want all of it.

Two things this got wrong on the way, both worth keeping written down:

- **The strip was inside the playing branch.** Which hid it in exactly the case
  it exists for: a browser tab playing claims no session, `hasTrack` is false,
  the idle card shows, and the one moment you most want to know what is making
  the noise was the one moment it was not there.
- **A view cannot populate the list it is deciding whether to exist from.** The
  refresh was in `onAppear`, so the body ran first against an empty list, drew
  nothing, and filled in a frame later. `NotchState.open` fills it now, beside
  the other on-open reads.

Filtered to what is playing plus the session owner, because `VolumeMixer` lists
every app *holding* a connection - measured on this Mac: Claude, Eloquent,
Gemini, Chrome, Safari and Spotify all held one while none had anything to say.

### Lyrics

From [LRCLIB](https://lrclib.net/docs), which needs no key and no account - the
same reason Open-Meteo was chosen for the weather. One request per track change,
never on a timer, and nothing leaves the Mac but the track's own metadata.
LRCLIB matches on duration within a couple of seconds, which is what stops a
cover or a live version answering for the studio cut. A track with no lyrics is
remembered as such, so opening the island again does not ask again.

The current line comes from `NowPlaying.livePosition`, which is already
`elapsedTime + timestamp` rather than a tick - so the lyric follows the song with
no clock of its own. Found by binary search, because it is read on every redraw
against a list that can run to several hundred lines. Verified against Creep:
38 timed lines, correct line and next line at 20s, 25s and 31s, and empty before
the first line and after the last.

### Brackets the keypad never closes

The keypad opens brackets and never closes them: `sin` types `sin(`, `d/dx`
types `deriv(`. So pressing `d/dx`, `sin`, `x`, `)` leaves `deriv(sin(x)` - one
short - and the line would not read at all. That is why `deriv(sinx)` failed
while `derivsinx` worked: the second needs no brackets and so could not get
them wrong.

The tokeniser now forgives both directions. A closer with nothing to close is
dropped, and any bracket still open at the end of the line is closed for you.
Typing has the same problem from the other side - `sin(x` is what a line looks
like for every keystroke until the closer arrives, and a calculator that shows
nothing until then is blank for most of the time anyone spends using it.
Measured: `deriv(sin(x)`, `deriv(sinx))`, `sqrt(2` and `2*(3+4` all read now;
`12+34` and `2+2` are unchanged.

The forgiven closers carry a zero-width range at the end of the line, so no
node ever claims characters that were never typed and the caret stops stay
inside the text. Done in the tokeniser rather than by retrying the parse with
`)` glued onto the string, because that would put every range out by however
many brackets were added - and the ranges are what the caret and the click
targets are built from.

### Where the caret can go

The hard part of drawing an expression as maths is that the caret has nowhere
to stand in most of it. `deriv(x)` draws as a `d/dx` beside an `x`; there is no
position in that picture meaning "between the r and the i".

This was got wrong twice, in opposite directions, and both are worth keeping
written down.

**First the drawing lied.** The caret was snapped to the nearest offset that
did have a home, so it sat somewhere the text was not - several different
offsets all drew a bar in the same place, and it looked frozen while you typed.

**Then the arrows were made to match, which was worse.** Stepping between the
offsets the drawing could show meant offsets 1 to 5 of `deriv(x)` could not be
reached at all: you could not get the caret into the word to fix a typo in it,
and a line you mistyped was a line you had to clear and start again. That is a
worse failure than a caret in the wrong place, and it shipped.

What is true now: **the text is the source of truth, every offset in it is
reachable, and the drawing never lies about where the caret is.** Arrows step by
character, as in any text field. When the caret lands somewhere the maths
cannot show it, the line falls back to drawing its characters, which always can.
Same face, same size, so the change is quiet - and it only happens when you
deliberately move into the letters of a name, never while typing at the end,
because the end of a line is always a place the drawing has.

Checked across the range of an expression: for `deriv(x)` the caret draws as
maths at offsets 0, 6, 7 and 8 and as characters at 1 to 5; for `12+34` and
`2+2` every offset is maths; for a line that does not parse every offset is
characters. No offset anywhere renders in something that cannot show a caret.

The genuinely correct answer to this problem is a structured cursor that lives
inside the expression tree rather than a text offset mapped onto a drawing of
one - which is what [MathQuill](https://github.com/desmosinc/mathquill-archive)
does for Desmos, where left into a fraction moves up into the numerator rather
than into a character position. That is a different editor, not a fix to this
one, and it is the shape to reach for if this ever needs to be WYSIWYG.

### The differentiation rules

Checked against numerical derivatives rather than by eye: each rule's symbolic
result is evaluated at several points and compared with a central difference of
the same expression, which catches a wrong *rule* rather than a wrong answer.
52 checks across power, product, quotient and chain rules, all six
trigonometric functions and their inverses, the hyperbolics, `exp`, `ln`,
`log`, `sqrt`, `abs`, `a^x` and `x^x`. All pass.

### The caret in the drawn maths

Four bugs lived here, and all four came from the same root: the line is drawn
twice over. An `NSTextField` one point wide and invisible holds the string and
the insertion point, because AppKit's field editor is what knows how to handle
a keyboard; `MathView` draws what it holds. Anything the field draws for itself
is a second, wrong answer.

- **Two carets on screen.** `textColor = .clear` hides the letters but not the
  field editor's own insertion point, which is laid out against the hidden 13pt
  line and so appears somewhere unrelated to the 21pt maths above it. The field
  editor's `insertionPointColor` and selection highlight are both cleared on
  every focus, because the editor is shared and handed out fresh.
- **Three carets on one offset.** Nested nodes routinely end at the same place,
  and while a line is being typed it is normal: `ddx(sin(x` parses leniently, so
  `x`, `sin(…)` and `ddx(…)` all end at offset 9 and each drew its own bar. A
  node now yields to any child of its own ending where it does, leaving exactly
  the deepest one drawing.
- **The line changed size on almost every keystroke.** Half of writing an
  expression passes through states that do not parse - `sin`, `sin(`, `sin(x` -
  and the drawing swaps to a plain-text fallback for those. The fallback was
  19pt against the maths' 21.
- **A warning that blinked as you typed.** The error mark was tied straight to
  the parse, so it appeared and vanished with every letter. It waits 550ms for
  the typing to stop, which `task(id:)` does on its own.

And the whole strip was running a spring animation keyed on the input, so every
keystroke slid the line around - and animated the swap between the two
renderings too. Typing lands instantly now; only the answer fades.

## Build and run

```bash
./make.sh && open /Applications/DynamicIsland.app
```

Launch through the bundle, not the binary. Running
`/Applications/DynamicIsland.app/Contents/MacOS/DynamicIsland` directly bypasses the
bundle's `Info.plist`, and TCC aborts the process the moment it touches
Bluetooth.

`make.sh` builds via SwiftPM, assembles the `.app`, and **signs it with a real
certificate when the keychain has one** - a Developer ID or Apple Development
identity - falling back to ad-hoc otherwise.

That choice decides whether permissions survive a rebuild. A TCC grant is
recorded against the binary's code signature, and an ad-hoc signature *is* a hash
of the binary, so every rebuild is a different app to macOS. The symptom is
specific and confusing: the row stays in System Settings switched **on**, while
the app is refused. Measured exactly that - toggle on, `CGPreflightScreenCaptureAccess`
false, `Signature=adhoc`.

A certificate-backed signature has no cdhash in its designated requirement:

```
identifier "dev.local.dynamicisland" and anchor apple generic
    and certificate leaf[subject.CN] = "Apple Development: …"
```

Verified identical across rebuilds, so one grant now holds for good. A
self-signed certificate cannot do this - codesign will not use one until it is
trusted for code signing, and that needs an admin dialog.

Quit with `killall DynamicIsland`.

`./make.sh dist` builds the release zip instead of installing: ad-hoc signed,
written to `dist/DynamicNotch-<version>.zip`, with its checksum written into
`Casks/dynamicnotch.rb`.

### Releasing

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`.
2. `./make.sh dist`
3. Commit the cask, tag `v<version>`, push both.
4. `gh release create v<version> dist/DynamicNotch-<version>.zip`

## Power rules

These are the constraints the whole design exists to satisfy. Breaking one is how
every other notch app ended up on the battery-drain lists.

1. **One global monitor, and only one.** Pointer tracking needs a mouse-moved
   monitor - see *Opening* below for why a tracking area cannot work alongside
   click pass-through. It costs nothing at rest, because a stationary mouse
   produces no events. Every *other* input path stays scoped to the window.
2. **No repeating animations at rest.** No `repeatForever`, no `TimelineView`, no
   `Timer` in the idle path. The arc reactor glow is interpolated by the same
   spring that drives the size change, so it animates only during a transition.
3. **No timers for state that can be computed.** Playback position comes from
   `elapsedTime + timestamp`, not a tick.
4. **One process at rest.** No XPC helper. The perl Now Playing helper is spawned
   when something starts outputting audio and killed after five minutes of the
   helper reporting nothing playing.
5. **Nothing may be drawn under the physical notch.** The bezel is a hole:
   pixels rendered there are in the framebuffer, so a screenshot shows them, but
   nobody can see them. That is not a theory - the header spent a release hidden
   under the notch while every screenshot of it looked correct.

   Two rules keep it out. The header reserves `notchInset` vertically and
   `notchGap` horizontally, both from `NSScreen.auxiliaryTopLeftArea` and
   `safeAreaInsets` - public API, measured, never hard-coded. And the island's
   frame pins its content with `alignment: .top`, because **a fixed SwiftUI frame
   centres a child that does not fit**: home wanted 237pt inside a 218pt island,
   the 19pt overflow split evenly, and the header rendered at y = -9.5. Pinned to
   the top, overflow can only go downward, where clipping deals with it.

   `Tools/check-notch.sh` opens every tab, captures the notch rect and fails if
   anything is lit there. Verified to fail on the original bug (1560 lit pixels)
   and pass after the fix (0).
6. **Never resize the window.** The panel is created once at max size; only the
   SwiftUI content resizes. Window resizing under the cursor costs a WindowServer
   round trip per frame.

Verify after any change:

```bash
top -l 5 -s 10 -pid $(pgrep -x DynamicIsland) -stats pid,cpu,idlew,th,mem
```

`idlew` should stay flat while the mouse is parked off the island.

And after any layout change:

```bash
./Tools/check-notch.sh
```

`check-notch.sh` photographs the real island, so it needs an unlocked screen. To look
at a layout without one - from a script, or with the Mac locked - render every tab
and live activity offscreen:

```bash
/Applications/DynamicIsland.app/Contents/MacOS/DynamicIsland --render /tmp/island
```

It runs as a separate short-lived process and starts nothing that touches the menu
bar, hotkeys or panels, so the real app can stay running. The material background
comes out flat; the layout is exact.

## Settings

Settings live in a real window, not in the island - a form crammed into a 190pt
panel is not worth opening. Reach it from the menu bar item, the gear in the
island, or:

```bash
open -a DynamicIsland --args --settings
```

Sizing follows the pattern boring.notch gets right: **presets first, custom
last**, configured separately for displays with and without a notch. A raw
multiplier makes the user do arithmetic to get back to something sensible.

By default the closed island is **hidden** - the notch and menu bar look
untouched until you push the pointer into the top edge of the screen.

The hover target is **the closed island itself** - on a notched Mac, the physical
notch. Adapted from [boring.notch](https://github.com/TheBoredTeam/boring.notch)
(MIT), which puts `.onHover` on its closed notch view.

Earlier versions here used a thin strip at the screen's top edge instead. That
was wrong twice over: at 2-6pt it is unhittable, because pointer acceleration
stops a real flick short of the edge, and deepening it to the menu bar height
made every pass across the top of the screen open the island. The notch rect is
the right target - large enough to hit, and nothing else lives under the bezel,
so the pointer only enters it deliberately.

`Behaviour ▸ Extra depth` and `Extra padding` add margin around it.

Detection is a single app-wide `NSEvent` mouse-moved monitor, **not** an
`NSTrackingArea`.

Tracking areas cannot do this job here. A tracking area only receives enter/exit
where its window is hit-testable, and this panel deliberately returns nil from
`hitTest` so clicks fall through to the menu bar underneath. The two are
mutually exclusive: with pass-through on, the enter event fires only in whatever
small sub-rect happens to be hit-testable, so a fast flick registers nothing.
Measured: 1 of 8 single-jump approaches activated. With the monitor, 8 of 8.

The monitor costs nothing at rest. A stationary mouse produces no events, so idle
wakeups are unaffected - unlike a timer, it never wakes the machine on its own.
It only runs while the pointer is actually moving, which is time the machine is
awake regardless. This is the one place where a global monitor is the right
answer, and it is deliberately the only one in the app.

The open timer is scheduled once per entry, not re-armed on every move - otherwise
each move pushed the deadline back and it never fired.

**Containment must be inclusive.** `NSRect.contains` is half-open: it excludes the
max edge. The hover band's top edge *is* the top of the screen, so shoving the
pointer into that edge reports exactly `screen.maxY` and the half-open test
rejected it - the island would only open if the pointer stopped slightly lower.
Measured over 45 flicks landing exactly on `screen.maxY`: **0 opened** with
`contains`, **45 of 45** with an inclusive test. `containsInclusive` in
`NotchContainerView.swift` exists solely for this.

The band is **as wide as the closed notch**, plus `Behaviour ▸ Target padding`
either side. It used to span `openWidth` - the shape boring.notch uses, chosen
because a 185pt target demands precision the pointer cannot deliver at speed.

That trade was wrong in practice. A 676pt band covers the whole top-centre of
the screen, so the island opened on the way to a menu, and it fired the moment
the pointer entered the area the *open* island would later occupy - which reads
as the app guessing rather than responding. Anchoring the target to the notch
costs some forgiveness and buys back the thing that matters: it opens when you
go to the notch, and only then.

Depth matters more than width here, which is why `Extra depth` is non-zero by
default. The notch is a hole with no pixels behind it, so the pointer is
invisible while over it - the depth spills the target onto screen you can see.

`Behaviour ▸ When idle` switches the closed island to show only
during playback, or always.

## UI

Motion and interaction values live in `Motion.swift`; type and colour in
`Theme.swift`. Rules the UI is built to:

- **The header runs either side of the physical cutout.** Tabs on the left,
  battery and settings on the right. That strip is dead space otherwise, and
  reclaiming it is what lets the body use its full height.
- **The player is one block, not two halves.** Title, artist, scrubber and
  transport sit tight against each other. A spacer used to push them apart,
  leaving a band of nothing between the artist and the scrubber and pinning the
  transport to the bottom of the panel - which read as a layout that had failed
  to load rather than as breathing room.
- **What that freed goes to two sliders.** Output volume with its mute toggle,
  because that is the control you reach for while a track is on; and display
  brightness, which has no home anywhere else in the app. Same grammar for both -
  glyph, system slider, trailing value - so they read as one pair rather than two
  features.
- **Brightness goes through `DisplayServices`**, resolved at runtime because
  there is no public API for it. The row hides itself if the symbols ever move,
  and the value is read when the island opens rather than on a timer. It is read
  there, not from the row's own `onAppear`: a row that renders nothing until the
  value is known never appears, so its `onAppear` never fires and it could never
  learn the value.
- **The marquee measures its own text.** The title strip was a hard-coded 17pt
  with `clipped()` on it, which is under the line height of the 14pt semibold
  title - so tall glyphs and digits were sliced off at the top. A marquee has to
  clip horizontally; it must never clip vertically.
- **`RAM`, in gigabytes.** It read `MEM 70%` - a percentage of a total the panel
  never states, which nobody can act on. `11.4 GB` is a number.
- **One panel, two columns.** Player on the left, calendar beside it, divided by
  a hairline. A week strip is small enough that hiding it behind a tab costs
  more than it saves.
- **The source app is a badge on the artwork**, not a text label.
- **Remaining time, not total** - "how long left" is the question people have.
- **Two springs, not one.** The island changing size is slightly underdamped so
  it reads as an object with mass. Content swapping inside it is critically
  damped - overshoot on text that merely faded in feels wrong.
- **Exit is faster than enter.** The user has already decided; the system gets
  out of the way.
- **The artwork travels, it does not cross-fade.** `matchedGeometryEffect` moves
  the same album art between the collapsed and expanded layouts, so the island
  reads as one thing opening rather than two views swapping.
- **Blur across the swap.** Without it the eye reads two overlapping objects
  instead of one changing.
- **Press feedback on every control**, on press rather than on release.
- **The empty state carries the primary action.** A panel whose only control was
  a small label in a top corner read as empty rather than as waiting for you -
  Cleanup and Updates both had that problem. The action now sits in the middle of
  the space it explains, as a labelled button, with the whole block as its target.
- **No dead space between hit targets.** The tab rail's targets are contiguous
  and larger than the pills they draw.
- **Nothing animates at rest.** The scrubber's clock exists only while the
  island is open *and* something is playing.
- **Reduced motion and reduced transparency are honoured**, via
  `NSWorkspace.accessibilityDisplay*`. Reduced motion keeps the cross-fades and
  drops the movement, stagger, and haptic.

## Architecture

| File | Role |
|---|---|
| `main.swift` | Accessory-policy app, screen-change observer |
| `NotchPanel.swift` | Borderless non-activating `NSPanel` pinned over the notch |
| `NotchContainerView.swift` | All input: tracking area, hit testing, click |
| `PanelManager.swift` | One panel per display, rebuilt on layout change |
| `Settings.swift` | UserDefaults-backed config |
| `Views/` | Presentation only - collapsed, expanded tabs, settings |
| `NotchState.swift` | Mode, target sizes, the one shared spring |
| `NotchShape.swift` | Notch outline |
| `NSScreen+Notch.swift` | Notch geometry from public API |
| `ArcReactor.swift`, `Theme.swift` | Styling |

Input lives in AppKit, not SwiftUI, for two reasons found by testing:

- SwiftUI `.onHover` is unreliable inside a non-activating accessory panel.
- `acceptsFirstMouse` must be overridden to `true`, or the first click on a
  never-key panel is swallowed as an activating click.

The tracking-area rect changes when the island grows, which re-fires
`mouseEntered` with the cursor inside the new area. Every mouse handler therefore
guards on an actual mode change; without that it is an infinite event loop.

Rebuilding that rect also emits an **exit** for the area being removed, even
though the cursor never left. `mouseExited` re-checks the real cursor position
before collapsing - without that, the island collapses the instant it opens.

## Prior art

Layout and settings structure were informed by looking at
[boring.notch](https://github.com/TheBoredTeam/boring.notch) (MIT) and
[Atoll](https://github.com/Ebullioscopic/Atoll). **Atoll is GPL-3.0 and none of
its code is used here** - only the visual arrangement was studied, and this
implementation is written from scratch. The ideas worth taking were: presets
before custom values in settings, a header that straddles the cutout, and
folding the calendar in beside the player instead of behind a tab.

## Attribution

The Tools tab, the disk image installer, the link cleaner and the keep-awake
panel are features borrowed from
[Vorssaint](https://github.com/vorssaint/vorssaint-utils). Only the ideas are
borrowed - every implementation here is this project's own, deliberately, because
Vorssaint is GPL-3.0 and lifting its code would put this whole app under that
licence.

`NSScreen+Notch.swift` and `NotchShape.swift` are adapted from
[DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) (MIT).
Window and hit-testing approach informed by
[NotchDrop](https://github.com/Lakr233/NotchDrop) (MIT).

The arc reactor styling is original work in a hot-rod red, black and gold palette. It deliberately
uses no Marvel logos, marks, or artwork.

## Modules

| Module | Signal | Cost at rest |
|---|---|---|
| Now Playing | perl helper streaming JSON | one process, only while playing |
| Battery | `IOPSNotificationCreateRunLoopSource` | none |
| Calendar | `EKEventStoreChanged` + on open | none |
| File shelf | AppKit drag destination | none |
| Tasks | `DispatchSource` file watch | none |
| Timer | one work item at the end date | none |
| Focus / Do Not Disturb | `DispatchSource` file watch | none |
| Bluetooth | `IOBluetooth` connect notifications | none |
| Downloads | `DispatchSource` folder watch | none |
| Audio output switcher | reuses the CoreAudio listeners | none |
| Microphone in use | default input device listener | none |
| Tools | nothing until pressed | none |
| Notes | debounced write on edit | none |
| Cleaner / uninstaller | on demand only | none |
| Updates | on demand only | none |
| Temperature | HID sensors while open, thermal state always | none |
| Camera mirror | session only while the window is open | none |
| Per-app volume | **audio render while an app is below 100%** | see below |
| Disk image installer | `NSWorkspace` mount notification | none |
| Screenshot catcher | `DispatchSource` folder watch | none |
| Colour picker | `NSColorSampler`, on demand | none |
| Monitor brightness | DDC read on open, write on drag | none |
| Several outputs | one CoreAudio device, only while on | none |
| Verification codes | rides the existing clipboard reads | none |
| Clipboard images and files | written beside the history, on copy | none |
| Plain-text paste | one Carbon hot key | none |
| Eye breaks | one work item per interval | 3 wakeups an hour |
| Convert | subprocess and encoder while a job runs | none at rest |
| Calculator | modifier-only key monitor, window only while open | none |
| Command bar | app list built on open, dropped on close | none |
| File search | Spotlight query, only while the bar is open | none |
| Figma | one fetch per opening, at most every 30 minutes | none |
| Menu search | AX read of the front app's menus, on keystroke | none |
| Sources | reuses the mixer's CoreAudio listeners | none |
| Snippets | a file, read once | none |
| Finder keys | two hot keys, only while the Finder is in front | none |
| Ports | `lsof`, on demand | none |
| Homebrew | `brew`, on demand | none |
| Lyrics | one request per track change | none |

### Skipping, going back, and the cover that lagged

Three complaints, one of them caused by a fix for another. Worth writing down
together.

**The cover ran a track behind the song.** The stream is a diff - only changed
keys arrive - and the code treated an absent key as "unchanged" for every
field. That is right for most of them and wrong for artwork, because the
adapter says plainly that `artworkData` "often takes a bit of time to load and
may not appear in the output in all cases": it arrives in a *later* message
than the title it belongs to. So the new title landed with no picture, the old
picture stayed, and the panel showed the previous song's cover until the next
track change repeated the trick. A new track now drops the old cover at once
and the panel shows the source app's badge over the reactor until the real one
lands - a moment of honesty rather than a song of being wrong. A cover that
fails to decode is treated as no cover for the same reason.

**Every other vanishing key was kept too.** The adapter documents that "when a
key is not present anymore, it's set to `null` in the payload and its previous
value should be removed", and only `title` was ever checked for that null. An
album or an artist the player had dropped stayed on screen. All of them are
read through one pair of helpers now: absent means unchanged, null means gone.

**Back restarted the song instead of going back.** That is the player's rule,
not a lost command: Spotify and Music both restart the current track once you
are a few seconds in, and only step back when you are near the beginning. So
pressing back gave the same song from the top, again and again. The restart is
unmistakable and needs no guessing at player state - same track, position
returned to zero - and when that is what comes back, the command is sent once
more, which is what "back" was meant to do. Once only; a loop would walk
backwards through the queue for as long as the player kept restarting.

**And the stall recovery is gone.** Skipping used to land on a paused track, so
a routine was added here to notice and press play. It was this project's own
invention - no other notch app does it - and it could not tell a stalled skip
from a track still loading, so it pressed play at players already on their way
up and the command landed as a pause. It broke the back button in one release
and was still pausing skips in the next. Deleted. The app now sends exactly the
transport command that was asked for and nothing else, and what remains of the
original fix is the part that was actually diagnosed: commands go out one at a
time rather than as a race of perl processes.

Checked headlessly against synthetic stream updates: a track change with no
cover yet shows none rather than the last one; a late cover fills in; a key set
to null is dropped; a cover that will not decode is not kept; back that is
answered with a restart asks again exactly once; back that works first time
asks once; and a skip that lands paused is left alone.

### Now Playing gating

macOS 15.4+ gates MediaRemote behind an entitlement, so Now Playing runs through
[mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3,
vendored in `Vendor/`), which loads the framework inside `/usr/bin/perl`.

Deciding when to run it is the hard part. Device-level
`kAudioDevicePropertyDeviceIsRunningSomewhere` is useless - it reads true
permanently on any Mac running Chrome, which holds an output stream open forever.
So the gate is the per-process `kAudioProcessPropertyIsRunningOutput` list: a
change to the set of outputting processes means something new started, which
starts the helper. The helper's own `playing` field then decides when to stop.

### Tasks

Anything that can write a file can push work into the island. A single object
still works, and a `tasks` array shows several at once:

```bash
echo '{"tasks":[{"id":"build","text":"Running tests","state":"running","startedAt":1756000000,"app":"com.apple.Terminal"}]}' > ~/.dynamicisland/status.json
```

`state` is one of `running`, `ok`, `failed`, `idle`. `startedAt` is a Unix
timestamp and drives a live elapsed counter; `app` is a bundle id, and clicking
the row brings that app forward. Wire it to a Claude Code hook or a build script.

### Interaction

- **Scroll on the notch** to open; scroll up **on the header strip** to close.
  The close gesture is confined to the header because swallowing every scroll made
  the calendar unscrollable - SwiftUI never saw the event. Costs nothing at rest: `scrollWheel`
  only arrives when the pointer is already over the view, so there is no monitor.
  Momentum frames are ignored, or one flick toggles repeatedly.
- **Swipe sideways on the closed notch** to change track. Collapsed only:
  expanded, a horizontal scroll belongs to whatever is under the pointer, and
  the open panel already has transport buttons and a draggable scrubber. One
  flick is one track however long the tail runs, and momentum frames are ignored
  for the same reason the open gesture ignores them.
- **Drag the progress bar** to seek. The hit area is 11pt tall so a 3.5pt bar is
  still grabbable.
- **Click the artwork** to bring the player app forward.
- **Peek on track change** - the closed island shows the new track for a moment
  even when the idle style is Hidden, which is the point of it.
- **Click the island** to accept what it is offering - a screenshot goes to the
  shelf, a mounted disk image installs.
- **Reopens on the last tab** used.

### Live activities

Three animated states in `Views/LiveActivities.swift`, all Iron Man themed:

- **Charging** - the arc reactor spins up. Gold ring sweeps round, red core
  ignites with an overshoot, bolt fades in.
- **Download** - the file materialises behind a descending gold scan line, then
  settles inside a completing ring.
- **Bluetooth** - repulsor link. Rings pulse *outward* on connect and *inward* on
  disconnect, so direction carries the meaning without reading the label.

Each runs once through a `KeyframeAnimator` and stops. No `repeatForever` - the
timeline ends and the view unmounts with the HUD, so nothing is left spinning.
Only `scale`, `opacity`, `rotation` and `trim` animate, so no frame triggers
layout. Under reduced motion each collapses to its settled frame: the information
still lands, the movement does not.

Activity content enters from the edge it sits on - leading content from the left,
trailing from the right - so the island reads as opening outward rather than two
things cross-fading. Exit reverses the same path; asymmetric exits look like a
glitch. Same idea as boring.notch's `LiveActivityModifier`, which lays left and
right content across the closed notch.

The closed island grows for the duration of an activity, the way the real Dynamic
Island does. Hover targeting is unaffected - that reads `collapsedSize`.

**Battery is drawn, not an SF Symbol.** `battery.75` and friends quantise to four
steps, so the header icon was identical from 97% down to 76% - it looked broken
because it never moved. `BatteryGauge` fills proportionally and colours by state:
gold charging, red low, bone otherwise. The charging bolt is white with a dark
rim, because a black bolt vanished against the empty cell at low charge and a
plain white one washed out against a full gold cell.

`Modules ▸ Preview live activities` plays all three, or launch with `--preview`.

Two bugs worth remembering, both found by capturing frames rather than by eye:

- `KeyframeAnimator` did not start on its own, so every activity sat frozen on
  its hidden first frame. They are driven by an explicit `play` state toggled in
  `onAppear`.
- The Bluetooth waves are staggered, so the timeline has to run to
  `1 + maxStagger`. Running it to 1 left the last ring frozen part-way through
  its fade, sitting on screen as a static artefact.

### Privacy

`Behaviour ▸ Hide from screen recordings` sets `NSWindow.sharingType = .none`,
which keeps the island out of recordings and screenshots. Off by default, since
it also hides the island from your own screenshots.

The island is always hidden while the screen is locked - it would otherwise sit
above the lock screen. Driven by `com.apple.screenIsLocked` distributed
notifications, so it costs nothing while unlocked.

### Never contradict System Settings

If a permission is refused while the pane says it is granted, the app says which
of those is true rather than repeating "allow it in System Settings" at someone
looking at a switch already turned on. `Permissions.signatureIsUnstable` reads
the bundle's own designated requirement and looks for a cdhash in it; when one is
there, the message becomes "granted to an older build - switch it off and on",
which is the actual fix. Every permission-gated feature uses that same line.

### Nothing is requested on launch

No permission dialog ever comes from starting the app. Calendar reads its
authorisation status instead of asking for it, Bluetooth is not touched at all
until `CBCentralManager.authorization` says it is allowed, and the Downloads and
screenshot folders are only read if a previous read already succeeded.

This is not politeness, it is the only way the app is usable while it is being
worked on. A TCC grant is keyed to the code signature, and an ad-hoc signature is
the binary's own hash - so **every rebuild is a new app to macOS** and asks for
everything again. Requesting on launch turns that into a dialog on every single
start.

Two further rules fall out of it:

- **The probe never runs on the main thread.** A TCC dialog blocks the calling
  thread until it is answered, so a folder read on the main thread freezes the
  whole island behind a dialog nobody may be there to answer.
- **A failed probe switches the feature off** rather than retrying next launch.
  The flag is cleared *before* the attempt, so an attempt that never comes back
  is remembered as a failure. One dialog, not one per launch forever.

`Settings ▸ Modules ▸ Permissions` has an Allow button for each, which is the
only place a prompt is raised.

### Permissions are actionable

Calendar and notification prompts used to be grey sentences telling you to visit
System Settings - true, but a dead end. `PermissionNotice` puts a button next to
the message: alarms request notification access directly, calendar opens the
exact privacy pane.

### First run

The idle island is invisible by default, so a fresh launch otherwise looks like
nothing happened. First launch now shows a short activity naming the hotkey.

### Clock

Timer, stopwatch, alarms and world clocks, on one tab with a segmented switch.

macOS ships Clock.app, but it declares **no URL scheme and no AppleScript
dictionary** - there is nothing to hand off to, so this is built here.

- **Timer** uses the arc reactor as its dial - gold housing, red charge arc,
  glow while it counts. Seven one-tap lengths spanning the panel, plus `+1`/`+5`
  while running, so any duration is reachable without a picker. The first pass
  used four grey chips in the left half of the panel and left the rest empty.
- **Timer** stores an end date, not a tick: one work item fires at completion and
  the UI derives the remaining time when it draws. Measured with a timer running
  and the island closed: 0 idle wakeups over 30s.
- **Timer and stopwatch survive a quit.** State is persisted, and a running timer
  also schedules a `UNTimeIntervalNotificationTrigger` - macOS owns that alert, so
  it lands even if the app is not running when the time is up. On relaunch a
  timer still in the future is re-armed; one that expired while away is cleared
  and announced once. Verified both ways: quit with 5 minutes left and it came
  back with 296s; quit past the expiry and it cleared without a false resume.
- **Stopwatch** likewise stores dates, so laps and elapsed cost nothing at rest,
  and a running stopwatch keeps counting across a quit.
- **Alarms** use `UNCalendarNotificationTrigger`, so macOS fires them whether or
  not this app is frontmost, and nothing of ours has to run in between.
- **World clocks** show local plus whatever zones are set in
  `Settings ▸ Modules`. Defaults to Asia/Kolkata.

### Focus

Shows the active Focus mode, with a glyph matched to it (sleep, work, driving and
so on). There is no public API for another process's Focus state, so this watches
`~/Library/DoNotDisturb/DB/Assertions.json` with a `DispatchSource` - event
driven, nothing runs while Focus is unchanged.

### Keyboard

**The app installs a main menu even though it shows no menu bar.** An accessory
app has no menu bar, so it is easy to assume it needs no menu - but `NSApp.mainMenu`
is what matches ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z, and with no main menu those keys match
nothing. Typing in the notes tab worked while Select All did nothing, which is
exactly that. macOS then augments the menu itself with Writing Tools, AutoFill,
Dictation and Emoji & Symbols. Verified the menu bar is byte-identical with the
app running and not running: an accessory app never displays one.

`⌃⌘N` toggles the island (not `⌘⇧I`, which is Chrome's DevTools). `⌥Space` opens
the command bar, `⌃⌘B` shows or hides menu bar icons. `Escape` closes the island, and is only registered
while the island is open so it never interferes with anything else.

Carbon hot keys rather than an event tap or a key monitor: the system delivers
only the exact combination registered, so nothing sees the rest of your typing
and there is no per-keystroke wakeup. This is why there is no Caps Lock
indicator - that would need `.flagsChanged`, which fires on every shift press.

### Reliability

- **CoreAudio notifications are debounced, not handled one by one.** Browsers
  and chat apps open and close audio constantly, and every change fired a full
  rebind: drop and re-add a listener for every audio process, twice over since
  input is watched as well as output, then re-enumerate the lot. Sampled at 0.8%
  CPU and about one wakeup a second on a *closed* island, all of it inside
  `rebindProcesses`. One cancellable work item each now - a burst settles into a
  single pass, and a quiet machine schedules nothing.
- **The island does not close on pointer-exit while text has focus.** Hover to
  open the notes tab, move your hand to the keyboard, and the pointer leaving
  the island collapsed it mid-sentence. `NSTextView` as first responder now
  outranks the pointer.
- **The notes placeholder is positioned by measurement.** `NSTextView` starts its
  first glyph one line-fragment padding in (5pt) with no top inset; the guessed
  9/8 put the hint 4pt right and 8pt below the caret it was standing in for.
- **Statics called from background queues are `nonisolated`.** A `static` on a
  `@MainActor` class inherits that isolation, so calling one from a background
  queue trips `dispatch_assert_queue` and takes the app down with SIGTRAP. Hit
  for real on the first Check: the trailing closure inside a `merging` call was
  the isolated thing. Swift 6 catches most of these at compile time; the ones it
  infers instead show up only at runtime.
- **Notes no longer crash the app.** `Notes.persist` built its debounced
  `DispatchWorkItem` inside a `@MainActor` method, so the closure inherited main
  actor isolation - and running it on a background queue trips Swift 6's runtime
  isolation check. SIGTRAP, 0.6s after any edit to a note. Work items that run off
  the main thread are now made in a `nonisolated static` function. Reproduced in
  isolation before the fix, and the clipboard store uses the same shape.
- **The media helper cannot outlive the app.** A crash or a force quit does not
  take it with it: the child is reparented to launchd and keeps streaming. Three
  orphans accumulated across restarts during development, all still parsing media
  updates for an app that no longer existed. Every launch clears any it finds
  before starting its own.
- **Downloads and screenshots announce the newest file**, not the alphabetically
  first - two files landing together used to show the wrong one.
- **A finished download reads its icon a beat later.** A file the browser has
  only just moved into place still reports the generic document icon, which made
  a completed download look like a broken one.
- **Launch at login** via `SMAppService`. The toggle reads the real registration
  rather than a stored flag, so it can never disagree with the system.
- **The shelf survives a quit.** Items are stored as security-scoped bookmarks;
  plain paths would survive the quit but not the sandbox rules macOS applies to
  files reached from another app's drag.
- **The media helper restarts itself** with exponential backoff, giving up after
  eight consecutive failures rather than spinning. Previously a crashed helper
  left Now Playing frozen until the audio device set happened to change - which
  could be never.
- **Settings shows helper health.** A macOS update breaking the MediaRemote
  adapter used to be silent; now `Modules ▸ Now Playing ▸ Helper` says so.
- **Hidden while an app is fullscreen**, detected from `visibleFrame` reaching
  the top of `frame`, checked only when the active space changes.

Now Playing survives pause, sleep and a lid close. The helper used to be killed
after five minutes of `playing == false` - but paused is not idle, and a paused
track still has to show. It now shuts down only when there is no track at all,
and reconnects on `NSWorkspace.didWakeNotification`, because waking tears down
the helper's connection to mediaremoted.

Shuffle and repeat are deliberately stateless. The adapter accepts those commands
but reports nothing back, so tracking a local flag would light the button up
wrongly the moment shuffle was changed in the player itself.

### Microphone in use

An orange microphone glyph on the closed island while anything is capturing
audio, and an activity naming the app when it starts or stops.

A glyph, and only the glyph. It was a small orange dot beside the album art,
which is two mistakes: a coloured circle in the corner says "something is on" and
leaves you to guess what, and artwork sitting next to a privacy indicator reads
as two unrelated things sharing a strip. While the microphone is live it is now
the only thing the island shows.

Detection is the input *device*, not the process list. Per-process
`IsRunningInput` misses captures - a process that appears and opens the input in
the same instant flips the flag before a listener can be bound to it, which showed
up as the indicator working on one launch and not the next. The device-level flag
never misses it, and the process list is read only to name the app. macOS shows its own dot for
this; what it does not show is *which* app, which is the only reason this exists.

It shows through `When idle ▸ Hidden` as well - an indicator you cannot see is
not an indicator, and it is the one state worth overriding that preference for.

Free to detect: the per-process audio objects are already bound for the Now
Playing gate, and `IsRunningInput` is one more property on the same objects.

### Screenshot catcher

A new screenshot appears in the closed island as a thumbnail you can **drag
straight into whatever needed it**, or release without dragging to park it on the
shelf. Watches whatever folder `com.apple.screencapture location` points at,
with the same `DispatchSource` diff the Downloads module uses.

`screencapture` creates the file before it finishes writing it, so the thumbnail
is read after a short settle - one work item, no timer. Files are checked
against Spotlight's `kMDItemIsScreenCapture` tag, falling back to accepting when
the volume is not indexed.

### Colour picker

The eyedropper in the header opens `NSColorSampler` - the system's own loupe,
with the magnifier, pixel grid and escape-to-cancel already written. The hex
goes to the clipboard and the activity names it, so the copy is not silent.

### System stats

CPU, GPU, RAM, disk, temperature and network on the home tab, as a stat-tile row
rather than a chart: six levels in a 40pt strip has no trend to read.

Disk is read once per open rather than per tick - free space does not move in
the seconds an island is up, and the capacity query is the most expensive read
in the file. The meter shows how full the volume is and the number says how much
is left, the same "how much is left" framing as the player's remaining time.

**Sampled only while the island is open.** `start()` on expand, `stop()` on
collapse. This is the feature that put Atoll's stats daemon on the drain lists,
and the cause is always the same - a timer that keeps polling when nobody is
looking.

Sources are all public: `host_statistics` for CPU ticks, `host_statistics64` for
memory footprint, `IOAccelerator`'s `PerformanceStatistics` for GPU, and
`getifaddrs` deltas for throughput. CPU and network are cumulative counters, so
the first sample after opening reads zero - only the delta means anything.

Meters are sequential (one hue, magnitude) and switch to the status colour past
80%. Identity comes from the written label, never from hue.

### Tools

Twelve one-press actions and a keep-awake card, on their own tab.

**Tabs are not all the same height, and they cannot be.** Tools needed about
280pt of content in a 196pt panel, and nothing clipped it - the overflow pushed
the tab rail and the segment row off the top of the panel, so neither could be
clicked and the only way to another tab was the hotkey. Fixed twice over: Tools
gets the height its content needs, and the content area is clipped so no tab can
ever paint over the header again.

The keep-awake card runs the full width with its lengths inline. It used to own
a third of the panel as its own column with most of that column blank, which
read as something failing to load rather than as a layout. Each is a
single call made when pressed: nothing here runs at rest, and none of it needs a
permission.

- **Mute mic** - sets mute on the default input device, falling back to dropping
  input gain to zero for the many microphones that expose no mute control. The
  pair to the microphone indicator: seeing that something is listening is half a
  feature if the answer is buried in System Settings.
- **Keep awake** - an `IOPMAssertion` held for 15m, 30m, 1h, 2h, 4h or until
  stopped. Idle *system* sleep only, not display sleep: a long export should not
  also burn the backlight. The remaining time is derived from an end date, so
  nothing counts down while it runs.
- **Lock screen**, **Sleep display**, **Eject disks**, **Restart Finder**,
  **Show hidden files**, **Hide desktop icons**, **Copy IP**, **Downloads**,
  **Clean link**, **Pick colour**, **Empty Trash**.
- **Clean link** strips 30-odd tracking parameters from a copied URL, on demand.
  Watching the clipboard instead would mean polling `changeCount` forever, which
  is the one cost this app exists to avoid.
- **Empty Trash takes two presses.** It cannot be undone, so the tile arms first
  and empties on a second press - a confirmation that cannot be clicked through,
  without a modal dialog in a 196pt panel.

### Notes

A scratchpad: list on the left, editor on the right, in one panel rather than a
list that swaps to an editor - the island is wide and short, so side by side
costs nothing and removes a navigation step.

Saves as you type, debounced: typing a sentence writes the file once, not thirty
times. Stored as JSON under Application Support rather than in `UserDefaults` -
notes are the only thing here that can grow without bound, and a preferences
plist is the wrong place for prose.

### Clipboard history

On the shelf tab, beside Files. Click a clip to paste it into the app in front - the
island never takes focus, so that is the app you were typing in - or hover for copy
and remove. `⌥Space` finds clips too.

**It does not poll**, which is why it is here at all. macOS posts nothing when the
pasteboard changes, so every clipboard manager reads `changeCount` on a timer,
several times a second, forever - the reason this used to be on the "not built"
list. But a copy almost always leaves the app it was made in, and switching apps is
an event macOS does announce. The pasteboard is read then, when the island opens,
and when the command bar opens - never otherwise. The cost of no timer is exactly
this: two copies in one app with no switch between keep only the second.

Text only, 60 entries, `~/Library/Application Support/DynamicIsland/clipboard.json`
at `0600`. Anything marked with the `org.nspasteboard` concealed or transient types -
the convention 1Password, Bitwarden and the rest follow - is never read, and nor is
anything copied from a password manager.

### Accessory batteries

Magic Keyboard, Mouse and Trackpad levels from the IORegistry
(`AppleDeviceManagementHIDEventService`, public IOKit), AirPods per bud from
`IOBluetoothDevice` properties checked with `responds(to:)` before each read. They
appear in the Bluetooth connect card ("Connected · 85%"), in the tooltip on the
header battery, in `Tools ▸ System ▸ Devices`, and as a card when one drops to 20%
or 10%. Read when the island opens, a device connects, or the Mac wakes or unlocks -
a keyboard takes days to go flat, so one of those always comes first.

### Up next

A calendar event shows in the closed island five minutes before it starts
(`Settings ▸ Modules`, 1-15 minutes or off), with **Join** when the invite carries a
Zoom, Meet, Teams, Webex or Whereby link - click the island to join, or to open
Calendar when there is no call. One work item for the next event, on a wall-clock
deadline so a sleep in between does not make it late; it schedules the one after
when it fires. Recurring events are remembered per occurrence.

### Weather

Temperature and sky under the month in the calendar strip, in place of the year;
hover for the city, conditions and today's high and low, click for Weather.app.
Fetched from Open-Meteo (no key, no account) when the island opens, at most once
per half hour - an island nobody opens sends nothing, which is why this is no longer
on the "not built" list. The place is a city name, never a location fix: it defaults
to the city in the Mac's time zone and can be changed in `Settings ▸ Modules`, so
there is no Location Services prompt and nothing more exact than a city leaves the
Mac. City coordinates are looked up once and cached.

### Screen OCR

Select an area, get its text on the clipboard. QR codes are read in the same
pass, and reported first when one is present - a code in a screenshot is almost
always the point of selecting it.

**Two processes, neither of them this one.** `screencapture` draws the selection,
because the system's crosshair is the one everybody already knows. Then `di-ocr`
reads the file and exits.

That second process is the whole design. Vision caches its recognition model in
whichever process uses it and never gives the memory back: measured, one pass
took a host from 290 MB to 389 MB, and a second pass added more. The island runs
at 18 MB, so doing this in-process would roughly quintuple its resident size
permanently for a feature used occasionally. As a child it peaks near 96 MB for a
third of a second and dies, and the island never moves. Same shape as the Now
Playing helper.

**It needs Screen Recording, and `screencapture` does not get it for free.**
Spawning the system binary was worth trying - it did not work. It inherits the
calling app's TCC identity and exits 1 with no file, which is indistinguishable
from the user pressing Escape. So the permission is checked first with
`CGPreflightScreenCaptureAccess`, which is public API and does not prompt; only
then is anything spawned.

### Cleanup

`Tools ▸ Cleanup` does two jobs that share one rule: **nothing here deletes.**
Every removal is `trashItem`, so a wrong guess is undone by dragging it back out.
An uninstaller that matches too eagerly and deletes outright is a data-loss bug;
the same feature that only moves things to the Trash is an inconvenience.

- **Uninstall** takes an app and finds what it left under `~/Library` - support
  files, caches, containers, preferences, saved state, login items. Matching is
  conservative: a bundle id matches exactly or as a dotted prefix, so
  `com.acme.app` also owns `com.acme.app.helper` but never `com.acme.apples`.
  A name has to match the whole file name.
- **Caches and logs** sizes the biggest folders under `~/Library/Caches` and
  `~/Library/Logs`. Results appear **as each folder finishes**, not in one batch
  at the end - the full sweep takes well over twenty seconds on a real library,
  and a spinner that sits there that long reads as a hang.

Chosen with the system open panel rather than a drop zone: dropping on the island
is already the shelf's gesture, and overloading it by whichever tab happens to be
showing would be a trap.

### Updates

`Tools ▸ Updates` lists outdated Homebrew formulae and casks, and App Store apps
when `mas` is installed. Parsed from `brew outdated --json=v2`, because the
human-readable output changes between releases and the schema does not.

**Only when you press Check.** This is the one module that touches the network,
and it never does so on its own - no background checking, no daily timer.

### Temperature

The `TEMP` tile reads the hottest CPU die sensor, in two layers.
`ProcessInfo.thermalState` is public, notification-driven and always right - it
is what macOS itself acts on when it decides to throttle, and it costs nothing.
The degrees come from the HID temperature sensors, resolved at runtime because
those symbols are not in the SDK, so the whole thing degrades to the thermal
state rather than failing to build if Apple moves them.

An M4 exposes 47 temperature sensors and most answer a different question -
battery, NAND, enclosure. The die sensors are named `PMU tdie<n>`; `tcal` is
excluded because it reads a steady 51.8 and is a calibration constant, not a
temperature.

Fan speeds are **not** built. This machine is fanless, so there was no way to
verify the code, and shipping an unverifiable SMC read is worse than not having
the number.

### Camera mirror

A floating preview, for checking how you look before a call. The session exists
only while the window is open - closing it removes the input and tears the
session down, so the green LED goes out. That is the only honest way to ship it.

### Command bar

`⌥Space` opens a field over whatever you are doing: launch an app, run any of the
app's own actions by name, or work out a sum. Two verbs as well: `note buy milk`
files a note, `timer 10` (or `10m`) starts a timer. Ask about your calendar or the
weather - `what's on tomorrow`, `will it rain friday` - and the answer is a card.
Clipboard history is searchable here too.

The speaker button in the header lists microphones under the outputs - connecting
headphones moves both, and the headset mic is often the one you did not want. Not `⌘Space` - Spotlight owns that
and the system takes it before this app ever sees it.

Deliberately no window switching, no file index, no clipboard paste: every one of
those needs Accessibility, and this app has none. What is left needs no
permission and covers what a command bar is actually used for.

Arithmetic is a real scientific calculator, not `NSExpression`. That was here
first and is not enough: no constants, no trigonometry worth using, no factorial,
and integer division that surprises people. Foundation offers nothing closer and
this project takes no dependencies, so `Calculator.swift` is a tokeniser and a
Pratt parser in about 200 lines.

What it does: `+ - * / ^`, parentheses, factorial, postfix `%`, scientific
notation, implicit multiplication (`2pi`, `3(4)`), constants `pi`, `tau`, `e`,
`phi`, and `ans` for the previous result. Functions cover roots, logs to any
base, all six trigonometric functions with inverses and hyperbolics, `mod`,
`gcd`, `lcm`, `ncr`, `npr`, `hypot`, and statistics over a list - `mean`,
`median`, `stdev`, `min`, `max`, `sum`. Trigonometry follows a degrees/radians
mode, switchable by typing `degrees` or `radians` into the bar.

Two details worth keeping: `-3^2` is `-9`, because the exponent binds tighter
than the unary minus the way every maths convention reads it - recursing into the
unary parser instead gave `9`. And a bare `e` or `pi` does *not* produce a
result, because that is someone typing the start of an app name; a sum needs an
operator, a call, or digits mixed with letters.

The parser is pure and `nonisolated`, so it is tested directly: 49 cases covering
precedence, associativity, every function, and the malformed input a half-typed
line always is. Applications are gathered when the bar opens and thrown away when it
closes: no index, no watcher, nothing at rest. The list includes
`/System/Cryptexes/App/System/Applications`, which is where Safari now lives -
without it the app people search for most is the one that never appears.

### Advanced system monitor

`Tools ▸ System` carries what the home tab's six tiles cannot fit: RAM, swap,
temperature, battery level, power draw in watts, health, cycle count, time
remaining, live network rates and totals since boot.

Power draw is amperage × voltage from `AppleSmartBattery` - the only honest
figure available without an admin helper. Network totals are the interface
counters themselves rather than something accumulated here, so they stay right
without anything running while the island is shut.

The speed test is the one thing in the app that reaches the network without being
asked to carry data somewhere, so it never runs on its own and keeps nothing
between runs.

### Per-app volume

The one feature here that is not free while in use, and it is deliberately the
only one.

For each app you turn down, a **muted** process tap removes that app's audio from
the normal output, and a private aggregate device re-renders the tapped stream at
the gain you chose. An app left at 100% has no tap and no engine at all - it is
untouched and costs nothing. While an app *is* below 100%, a CoreAudio render
callback runs for as long as it stays down.

Needs macOS 14.4 for process taps, and grants the media-library permission the
first time a tap is created. **The engine is built off the main thread**, because
that permission dialog blocks the thread that triggered it - building it on the
main thread froze the whole island behind a dialog. Measured, not theorised.

Quitting destroys every tap and aggregate. A leaked muted tap leaves an app
silent until the next login.

**Every app holding an audio connection gets a row**, not only the ones making a
sound right now. Presence in the CoreAudio process object list *is* the test: a
process appears there once it has opened audio and stays while it holds it, so
`IsRunningOutput` is only used to draw the playing dot. Filtering on it as well
left the list empty whenever nothing happened to be playing - which is exactly
when you want to set a level in advance. Same rule Vorssaint uses.

Helpers roll up into the app that owns them, because audio rarely comes from the
app you can see - a browser plays through a GPU process, and a row called
`com.apple.WebKit.GPU` helps nobody. The owner is found by asking macOS which
process is *responsible* for the helper, then the process itself, then a short
walk up the parent chain. Anything that never resolves to an app with a Dock
icon - daemons, agents, `afplay` - gets no row, because a slider for it would
control something the user cannot point at.

Volumes are remembered per bundle id rather than per pid, since pids recycle.

### Disk image installer

Mount a `.dmg` holding exactly one app and the island offers to install it.
Clicking copies it to `/Applications`, moves any older copy to the Trash rather
than deleting it, and ejects the image.

Exactly one app, or nothing is offered - guessing which one of several was meant
is worse than staying quiet. Driven by `NSWorkspace.didMountNotification`, so
nothing runs between mounts, and the copy happens off the main thread.

### Monitor brightness

The brightness slider on the home tab drives the built-in panel through
`DisplayServices`, which never reaches an external monitor. A desk monitor is
driven over DDC/CI instead - a small I2C message on the display cable, the same
channel the monitor's own buttons use - so it gets a slider of its own, named
after the display.

On Apple Silicon that channel is `IOAVService`: three private symbols, resolved
at runtime like the brightness and screen-lock ones, and the whole feature
disappears if they ever move. The framing is from the DDC/CI standard, with one
asymmetry worth writing down, because getting it wrong produces silence rather
than an error: a *set* is checksummed with the display's address and ours, a
*get* with the display's address alone, and the reply is read from offset zero
rather than from our own source address.

Read on open, written on drag, and nothing in between. A monitor's own buttons
move brightness without telling anyone, so the level is re-read whenever the
island opens rather than watched.

Three answers come back from a monitor and they mean different things. A value
is a value. Silence is normal - plenty of monitors take DDC writes and answer no
reads, and then the remembered level stands and the slider still works. A refused
*transfer* is the third: the cable, the adapter or the OS is not carrying I2C at
all, and then the slider is removed rather than left sitting at a level it is not
setting. This Mac's external port answers `0xE0114000` to every transfer, so the
row does not appear here - which is how that case came to be handled.

### Several outputs at once

macOS can play to two devices at once, but only if you open Audio MIDI Setup,
build a Multi-Output Device by hand, point Sound at it, and remember to point
Sound back afterwards. The speaker button's menu has the same thing as a
checklist: tick the laptop speakers and a Bluetooth speaker and both play.

ponytail: a stacked aggregate device *is* a multi-output device - the same public
CoreAudio call the per-app mixer already builds its engines with. Nothing here
renders audio; CoreAudio copies the stream to each sub-device itself. Everything
but the clock master gets drift compensation, or the second speaker walks
audibly out of step inside a minute.

Session-only, deliberately. A restored multi-output would have to recreate a
device at login and repoint the system's sound at it before anyone asked, which
is the shape of a Mac that is mysteriously silent. It is destroyed on quit for
the same reason the mixer's taps are.

AirPlay receivers are in that menu too, under their own heading. They were
always in the device list once macOS knew about them; what was missing was any
way to tell which was which, so every device now carries the glyph of how it is
attached.

### Verification codes

A code copied inside a longer message - "Your verification code is 483920,
expires in 10 minutes" - is normally copied twice: once as the message, once
again after deleting the words by hand. When the clipboard picks up text that
says it carries a code, the island offers the digits alone, and clicking puts
just those on the clipboard.

Deliberately narrow, because a 4-8 digit run matches a year, a price and a flight
number. The text has to say what it is - code, OTP, passcode, verification,
sign-in - or be nothing but the digits. Tested against a phone number in the same
sentence as the word "code", an invoice total, and prose that happens to contain
it.

No new cost: this rides on the clipboard reads that already happen on app switch,
so nothing polls for it.

### Plain-text paste

`⌃⌘V` pastes what is on the clipboard with its formatting stripped, and the
Actions grid has the same thing as a tile because a shortcut nobody has seen is
not a feature. The stripped text is put back on the clipboard rather than pasted
from a private buffer, so an app that ignores `⌘V` and wants its own menu item
still gets the plain version.

Not `⇧⌘V` - half the Mac already spells that "Paste and Match Style", and the
frontmost app wins its own shortcut. Registered only while the module is on, so
switching it off hands the combination straight back.

### Eye breaks

Every twenty minutes, look at something twenty feet away for twenty seconds. The
island runs the clock: one work item per interval, no repeating timer, three
wakeups an hour.

Off by default. Everything else here answers a question you asked; this one
interrupts, so it is opt-in.

The clock measures time at the screen rather than wall time. Locking the Mac,
closing the lid or letting it sleep drops the pending break and coming back
starts a fresh interval - a reminder that fires the moment you sit down, because
it came due while you were at lunch, is one people switch off. It also waits five
minutes while the microphone is live: the one cheap signal that an interruption
would land in front of other people.

### Calculator

**Two quick taps of the right ⌥** open a scientific calculator: the line you are
typing, the answer beside it as you type, the working still on screen, and a
keypad laid out after Desmos's scientific calculator - which is the one everybody
has already used.

Two pads rather than Desmos's three. `main` is digits, operators, `a²`, `aᵇ`,
`|a|`, `√`, `ⁿ√`, π, the three trigonometric functions, `%`, a fraction key,
`ans`, and ← → to move the caret. `func` is the named half: inverse trigonometry,
`eˣ`, `abs`, `round`, `ln`, `log`, `mean`, `stdev`, `stdevp`, `nPr`, `nCr`, `!`,
and a row Desmos does not have - `d/dx`, `median`, `Σ`, `Π`, `mod`, `hypot`.
There is no `abc` pad: the only name this calculator knows is `x`, and it has a
key of its own on both pads, next to the `=` that turns a line into an equation.

**It is drawn as maths, and the maths is what you edit.** There is no text line
on screen: the expression is typeset, and the caret is inside it. Fractions
stack, exponents raise, roots are drawn as one stroke - tick, diagonal and bar,
at any size, rather than a `√` character stretched over its contents. `deriv(…)`
reads as `d/dx` with a bar and the point on it; an integral gets its limits on
the sign and a `dx` at the end; a sum gets its range above and below the `∑`.

Clicking puts the caret at the nearest gap between characters, so a click between
the 2 and the 5 of `25` lands between them rather than at the front of the number.
The glyph widths come from the font itself: measuring the drawn view through a
`GeometryReader` is a frame late, and the click that arrives before the
measurement is exactly the first one anybody makes.

Return always starts a new line, answer or no answer. Refusing to move on from a
line that could not be worked out - `2x =`, half typed - left the calculator
looking frozen with no way to begin a second one; the unfinished line is filed
with a dash where its answer would be, and clicking it puts it back on the line to
finish. A line that cannot be read as maths at all still draws with its caret in
it and still takes a click, for the same reason.

How the caret gets in there: every node carries the character range it was parsed
from, and an atom draws the bar before itself when the insertion point is its
first character, *inside* itself when the offset falls within a number or a name,
and after itself when nothing else begins there - which is what stops `2x` drawing
two carets between the 2 and the x. An offset with no home, like the middle of the
letters of `sqrt`, snaps back to the nearest one that has one: invisible is the
one thing an insertion point may never be. Clicking an atom puts the caret in
front of it.

A one-point transparent `NSTextField` is still in the view, because AppKit's field
editor is what knows how to handle a keyboard - key repeat, dead keys, ⌘V,
selection, undo within the line. It holds the string and the insertion point; the
drawing renders them. Typing `12`, pressing ←, then `5` gives 152, which is the
test that this is editing rather than appending.

While brackets are still open the drawing closes them for you, so `1/(2√(x+1`
draws as a fraction instead of flickering back to plain text at every bracket.
Whether the line is *finished* is what the answer beside it already says, and a
line that cannot be read as maths at all gets a warning triangle.

Two layout bugs worth remembering, both found by drawing the same expression on
its own sheet rather than inside the panel:

- **A stack offers each child the width of the widest one.** `1` over `2√x`
  proposed the numerator's width to the denominator, and the root drew with
  nothing underneath it. Both halves take their ideal size now.
- **One wide row stretches the whole column.** A sum with its limits made the
  history wider than the panel, and every row's answer was clipped off the right
  edge. The expression yields and is cut off; the answer never is.

ponytail: SwiftUI stacks, a rule and one drawn shape. A `Layout` or a Core Text
run would be the general answer; a handful of shapes of expression are not a
general problem. `Tools/check-notch.sh`'s sibling - `--render` - writes
`math-sampler.png`, which is every shape on one sheet.

**What it will not do.** No complex numbers, no matrices, no symbolic algebra
beyond differentiation - it will not factor, expand or rearrange - no systems of
equations, no units, and no graphs. An Nspire does all of those; this is the
scientific half of one, and pretending otherwise would be worse than saying so.

**It works with a tree, not a number.** The parser builds an expression tree and
the evaluator walks it, which is what makes the next two things possible: you
cannot differentiate a `Double`, and you cannot look for the roots of one either.
Plain sums come out the far side as a number, so arithmetic pays nothing for the
rest.

**Integrals, sums and products.** `integral(x^2, 0, 3)` is 9, by Simpson's rule
on a thousand panels - exact for anything up to a cubic, and close enough
elsewhere that the tenth digit is the only one in doubt. `sigma(x, 1, 100)` is
5050 and `product(x, 1, 5)` is 120, both binding `x` over whole numbers the way
the derivative binds it over a point. All three are on the `func` pad as ∫, ∑ and
∏.

**Derivatives, symbolically.** `deriv(sin(x))` is `cos(x)`, printed back as
maths. The ordinary rules - product, quotient, chain, powers, logarithms, the
trigonometric family - and then a simplifier, because without one the product
rule alone turns `sin(x)` into `cos(x) * 1 + sin(x) * 0`. That simplifier is a
short list of identities, not a computer algebra system: `x/x` stays `x/x`, and
that is a deliberate place to stop.

Give it a point and it answers with a number instead: `deriv(x^2, 3)` is 6,
`deriv(sin(x), 0)` is 1. Writing the point inside the function works too -
`deriv(sin(0))` is 1, not 0. Read literally that is the slope of the number
`sin(0)`, which is zero and is never what anyone means by typing it; a function
of one argument with no `x` in it is taken as that function at that point.
`deriv(ln(2))` is 0.5, `deriv(sqrt(4))` is 0.25. `deriv(5)` is still 0, because
that one really is a constant. That goes through the symbolic derivative too, so it is
exact rather than a difference quotient. Only when the rules do not cover
something - `mod`, a statistic - does it fall back to measuring the slope from
five points around the one asked for.

Degrees are not a presentation detail here. `sin` in degree mode is
`sin(x·π/180)`, so its derivative carries that factor and the inverse functions
carry its reciprocal: `deriv(sin(x))` in DEG is `pi / 180 * cos(x)`, and
`deriv(sin(x), 0)` is 0.01745. Getting that wrong would have made every
derivative silently 57 times too big.

**Equations.** An `=` outside every bracket makes the line an equation, and the
whole thing stays on screen - both sides of the `=`, with the caret free to go
anywhere in either. The drawing used to stop at the `=` and show `2x - 5` for a
line typed as `2x - 5 = 4`, which left the right-hand side invisible and
impossible to correct. The answer sits beside it and says `x = 4.5` once, not
`= x = 4.5`.

The
answer is where it is true: `x^2 - 5x + 6 = 0` is `x = 2 or 3`, `2x + 6 = 0` is
`x = -3`, `x^2 + 1 = 0` is `no real solution`. A derivative can be one side of it
- `deriv(x^2) = 6` is `x = 3`.

Two routes into that. A polynomial of degree one or two is solved with the
formula everyone learns, which is exact and catches a repeated root that no
search would ever see: `x^2 = 0` touches zero without crossing it. Everything
else is swept for sign changes and each one bisected.

The sweep runs **outward from zero** rather than left to right across a range,
which matters more than it sounds: `sin(x) = 0` has a root every π forever, and
scanning from -100 upward answered with six roots near -100 and stopped. Outward
from the origin gives `x = -9.42, -6.28, -3.14, 0, 3.14, 6.28 …`, and a periodic
equation stops early instead of walking the whole range. Six roots at most, the
six nearest zero, negative first when a pair is the same distance out, and the
`…` says when there were more. The reach is a turn and a half in degrees or about
sixteen radians - written down rather than implied.

Worst case measured: 0.37 ms for a swept equation, on every keystroke.

The engine is the one the command bar already used, and putting a keypad in front
of it found three real bugs in it:

- **`π` never worked when typed.** It is a letter as far as Unicode is concerned,
  so the name branch of the tokeniser swallowed it and produced an unknown name.
  The symbols are matched first now - π, τ, φ, √, ∛, ×, ÷ and −.
- **`√16` wanted brackets.** A function with no brackets now takes whatever comes
  next, so `√16` is 4 and `2√9` is 6, which is what the key on a calculator does.
- **`sin90` was an unknown name**, because names absorbed any digits that followed
  them. Only `log2` and `atan2` have a digit in them; everything else that looks
  like letters-then-digits is a function applied to a number.

Three details worth keeping:

- **It does not close when you click away.** The command bar does, because a
  launcher that lingers is in the way. A calculator is the opposite - it is used
  *while* reading the thing the numbers came from. The ✕, Escape, or two more
  taps.
- **It is dragged by its top strip**, and the drag is driven by the pointer's
  position on screen rather than by the gesture's own translation. The gesture
  measures inside a coordinate space that belongs to this window, so moving the
  window moves the space, which changes the translation, which moves the window
  again: measured, a 120pt drag threw it 1,200pt across the display.
- **The history outlives the window**, and so does where you put it. Memory only -
  a calculation history should not quietly become a file on disk.

**Why a double tap rather than a chord.** Three shortcuts were tried. `⌃⌥⌘C` is
one slipped finger from `⌥⌘C`, which is "Show JavaScript Console" in Safari and
"Inspect Element" in Chrome. `⌃⌥⌘=` worked when driven but is an awkward reach,
and a shortcut you have to look at your hands for is one you stop using. Tapping
one key twice needs no chord at all and collides with nothing, because no app
binds a bare modifier.

Carbon hot keys - what the rest of this app uses - cannot express "the same
modifier twice", so this one is a `.flagsChanged` monitor: the kind the Caps Lock
indicator was turned down for. What makes it affordable here is what it does not
see. Modifier changes only, no letters and no digits; it wakes on a ⇧ or a ⌘,
does four comparisons and stops. A keyboard nobody is touching produces no
events, so at rest it costs nothing - measured at 0.0% CPU with the monitor
running.

The right ⌥ specifically. The left one is half of every shortcut on the Mac, and
the two report different key codes - 58 and 61 - so they can be told apart.
Anything held alongside cancels the sequence, so `⌥⌘` chords never count towards
a tap. It needs Accessibility, which the menu bar module already asks for; without
it macOS tells the app nothing and Settings says so rather than leaving you
tapping at a dead key.

Verified by driving it: a single tap does nothing, two taps a second apart do
nothing, two quick taps open the window and two more close it, the left ⌥ is
ignored, `12+30` typed with no click first reaches the line, the answer reads 42 before Return, Return files it in the
history, `ans+8` reads 50, `deriv(x^2,3)` reads 6, the ✕ closes it and a drag on
the strip moves it. `open -a DynamicIsland --args --calculator` opens the same
window if another app ever takes the shortcut.

### Convert

Tools ▸ Convert, and the same actions in the shelf's right-click menu.

**EPUB to MOBI** is written here rather than shelled out to Calibre. An EPUB is a
zip of XHTML plus a manifest and a MOBI is a Palm database, so neither end needs
a library: `ditto` unzips, `XMLDocument` reads the manifest and the spine, and
the writer is the byte layout. Metadata, reading order, every chapter and the
images come across, with `<img>` rewritten to the `recindex` records Kindle
resolves. No navigation table of contents: that needs `filepos` anchors, which
are byte offsets into the finished file and so need a second patching pass this
does not have. Chapters still start on their own page. Verified by parsing the
output back: header fields, EXTH metadata, text length, page breaks, and the
image records.

**Audio to MP3** needed an encoder, because macOS has none - AudioToolbox decodes
MP3 and refuses to write it, and every AVFoundation preset produces AAC. So
`Sources/Shine` is vendored: 2,800 lines of C, LGPL, no dependencies. Decoding
stays the system's job - `ExtAudioFile` reads anything macOS knows and resamples
on the way - which is why there is no format handling in `MP3.swift`.

**A link to a file** uses `yt-dlp` for the extraction and nothing else for the
rest. A native extractor was written and thrown away: the player page hands out
`signatureCipher` for every format, the decipher function lives in a 2.6 MB
`base.js` that matches none of the published patterns, and the Innertube clients
that used to return plain URLs answer `UNPLAYABLE` without a token from the page
(measured 2026-09-27). Anything written here would break the next time YouTube
shipped.

Everything after extraction is ours, so there is no ffmpeg anywhere. YouTube has
stopped serving a single combined stream for most videos, so the picture and the
sound arrive as two files and `AVAssetExportSession` joins them with passthrough
- a copy, not a transcode. MP3 goes through the vendored encoder. One caution
worth keeping: AVFoundation reads the duration of yt-dlp's fragmented MP4 as
exactly twice what it is, frames intact and only the header wrong, so the join
takes the shorter of the two tracks.

The downloader is looked for inside the app first and then where Homebrew puts
it. `Vendor/README.md` has the one command that makes an app someone else is
handed work on a Mac with nothing installed.

**Images to PDF** takes several pictures and makes one document, a page each, in
the order they were picked - from Tools ▸ Convert, or straight off the shelf,
which is where several files are already lined up in an order somebody chose.

One picker, not two. The first version had a separate "Images → PDF" button
beside a "Choose a file…" that took one file at a time and quietly turned a
picture into a PNG - so the obvious button did the wrong thing twice over. Now
the one button takes as many files as you like: pictures in the selection become
a single PDF, and anything else converts on its own. A lone picture is a
one-page PDF, because that is what the section says it does; PNG, JPEG and HEIC
conversions live in the shelf's right-click menu, where a specific format is
what you are asking for.

An accessory app's open panel does not take the keyboard by itself - it appears,
and ⇧⌘G, type-to-select and ⌘A all go to whatever was in front before. It is
claimed explicitly after `begin`, which is when the window exists.

HEIC is in the picker, because that is what a phone actually produces and a
converter that greys out every photograph is no converter. It also means EXIF
orientation has to be honoured: a phone stores the sensor's pixels and a "turn
this a quarter" tag beside them, so a page built from the raw pixels comes out
sideways for about half of all photographs. Verified with a 640×480 picture
tagged "rotate 90°" - it lands as a 480×640 page, the right way up.

A pixel becomes a point, so a phone photograph makes a big page. That is the
right call for a PDF that is going to be read rather than printed.

**Archives and images** round it out: `ditto` and `tar` unpack anything they
already know, and ImageIO converts between PNG, JPEG and HEIC. Nothing is ever
overwritten - a second conversion lands beside the first, because these are cheap
to redo and impossible to undo.

### Deliberately not built

- **Brightness above 100%.** The XDR trick: hold EDR headroom open and map
  ordinary content into it, so the screen goes brighter than macOS allows. Half
  of it works here - a Metal layer asking for extended-range content raises this
  Mac's headroom from 1.0 to 2.0 over about two seconds, measured. The other half
  has no public route. Gamma tables clamp at white and can only darken;
  `DisplayServicesSetBrightness` accepts 1.3, returns success and reads back 1.0;
  and the one remaining trick - a translucent white EDR overlay - brightens by
  adding light, so it lifts black to grey. Shipping that as "brighter" would be
  shipping a washed-out screen.
- **Camera in use.** CoreMediaIO is the obvious twin of the microphone
  indicator, and it was built and then removed: enumerating its device list
  loads every DAL plugin, and the device-list listener re-fires on the query.
  Measured 25% CPU with memory climbing 26 MB to 65 MB in 40 seconds. It would
  also be reporting what the hardware already reports - the green LED beside the
  camera is wired to the sensor's power and cannot be lied to by software. The
  microphone has no such light, which is why that half stayed.
- **A volume HUD.** Removed, not never-built. macOS already draws one on every
  volume key press, so the island was duplicating a system overlay that cannot be
  turned off - two HUDs for one action.
- **Keyboard backlight.** `CoreBrightness` exposes no keyboard symbols on
  macOS 26 - every candidate probed and missing - and the IORegistry shows only a
  `KeyboardBacklight` resource flag with nothing writable behind it. A slider
  that cannot move is worse than no slider, the same call made about fan speeds.
- **Closed-lid keep awake.** Needs an admin-authorised toggle. Keep awake holds
  on a timer, or until the power or an external display goes away - both
  event-driven, neither needing a password.
- **Lyrics.** Network polling, per track.
- **Caps Lock indicator.** Atoll has one. It needs a `.flagsChanged` monitor,
  which fires on every shift and command press - constant churn while typing, for
  a glyph you rarely need.

Refusing these is the point, not an omission.
