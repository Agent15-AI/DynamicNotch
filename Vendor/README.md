# Vendored

`MediaRemoteAdapter.framework` and `mediaremote-adapter.pl` are from
[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter),
Copyright (c) 2025 Jonas van den Berg, BSD 3-Clause.

Needed because macOS 15.4+ gates the MediaRemote framework behind an entitlement
that third-party apps cannot get. The adapter loads the framework from inside
`/usr/bin/perl`, whose bundle id (`com.apple.perl5`) is on the allowed list.

We spawn it only while audio is actually playing - see `Modules/NowPlaying.swift`.

## shine (`../Sources/Shine`)

The MP3 encoder, from [toots/shine](https://github.com/toots/shine), LGPL v2 -
the licence sits beside the source at `Sources/Shine/COPYING`. 2,800 lines of C
with no dependencies of its own, built as an ordinary SwiftPM target.

Needed because macOS has no MP3 encoder at all: AudioToolbox decodes MP3 and
refuses to write it (`afconvert -f MPG3` answers `fmt?`), and every AVFoundation
export preset produces AAC. Vendoring it is what makes "save as MP3" work on a
Mac with nothing installed. See `Modules/MP3.swift`.

## yt-dlp (`yt-dlp`, optional, not committed)

Tools ▸ Convert turns a link into a file. The extraction is yt-dlp's job - see
the note at the top of `Modules/YouTube.swift` for why writing that here was
tried and abandoned - and everything after it is ours: no ffmpeg, no
post-processors.

`make.sh` copies `Vendor/yt-dlp` into the app when it is there, and the app
prefers its own copy over anything installed, so an app handed to someone else
works on a Mac with no Homebrew:

```
curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos -o Vendor/yt-dlp
chmod +x Vendor/yt-dlp
```

Without it the panel says what is missing and offers the Homebrew command, and
nothing else in the app is affected.
