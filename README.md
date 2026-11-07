<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Player app icon">
</p>

<h1 align="center">Player</h1>

<p align="center">A small Now Playing widget for the macOS menu bar, made of Liquid Glass and coloured by your album artwork.</p>

---

Player puts the current song and artist in your menu bar, next to a tiny equalizer drawn in the artwork's colours. Click it for a glass panel with the artwork, a progress bar, playback controls and volume. It works with any app that reports Now Playing: Music, Spotify, Podcasts, and videos in Safari or Chrome.

## Features

- **Menu bar:** a four-bar equalizer in the artwork's colours, then "Title — Artist". Long titles scroll when you hover.
- **Panel:** artwork, title, artist and album, a scrubber you can drag to seek, and previous, play/pause and next. The background takes a soft colour flood from the artwork, which cross-fades when the track changes.
- **Sources:** each app with something playing or paused gets an icon at the bottom of the panel, ordered music apps, podcasts, browsers, then everything else. Click one to show and control that app.
- **Per-app volume:** with an app selected, the volume slider sets that app's own volume and leaves the rest of your Mac alone. With no app selected, it sets the Mac's volume.
- **Shortcuts:**

  | Action | What it does |
  | --- | --- |
  | Click | Open or close the panel |
  | ⌥-click | Play or pause |
  | Right-click or ⌃-click | Menu with playback controls, sources, Open app, Launch at Login and Quit |
  | Scroll over the menu bar item | Volume up or down |
  | Space (panel open) | Play or pause |
  | Esc | Close the panel |

## Download

Get **Player.zip** from the [latest release](https://github.com/workbyoliver/Player/releases/latest). It needs macOS 26 Tahoe or later and a Mac with Apple silicon.

1. Unzip it, move **Player.app** to your Applications folder and open it.
2. The build isn't notarised, so macOS blocks the first launch. Go to System Settings › Privacy & Security, scroll down and click **Open Anyway**. Or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Player.app
   ```

Player appears in the menu bar, not the Dock. Right-click it for Launch at Login and Quit.

## Build from source

You'll need:

- macOS 26 Tahoe or later
- Xcode 26 or later (Swift 6.2 and `actool`, which compiles the icon)

Then:

```bash
git clone https://github.com/workbyoliver/Player.git
cd Player
make install
```

`make install` builds `build/Player.app`, copies it to /Applications and opens it. Other targets:

| Command | What it does |
| --- | --- |
| `make run` | Build and run from `build/` |
| `make debug` | Debug build |
| `make zip` | Build `dist/Player.zip` to send to someone |
| `make clean` | Remove build output |

The build signs the app with your Apple Development certificate if you have one, so macOS keeps Player's permissions between builds. Without one it signs ad hoc, and macOS asks for permissions again after each rebuild. To pick an identity, set `CODESIGN_IDENTITY`.

## Permissions

Player asks for these only when you first use the feature that needs them:

- **Audio recording:** asked the first time you change an app's volume. Player sets an app's volume by playing that app's audio back at the level you choose. Nothing is recorded or saved.
- **Automation (Music, Spotify):** asked the first time you control Music or Spotify while a different app is the active player.

## How it works

- **Reading Now Playing:** since macOS 15.4, the system-wide Now Playing info (Apple's private MediaRemote framework) only answers Apple-signed processes. Player loads a small Objective-C helper (`Helper/`) into `/usr/bin/perl`, which is Apple-signed. The helper sends track, artwork and source updates to the app as JSON lines and takes commands on stdin. It exits when the app quits.
- **Controlling playback:** macOS only sends playback commands to the active player. To control Music or Spotify when they aren't the active player, Player uses AppleScript. Other inactive apps, such as a paused browser tab, can't be controlled, so the controls dim.
- **Per-app volume:** a Core Audio process tap mutes the app and plays its audio back at your chosen level through a private aggregate device. At 100% the tap is removed, so the app plays untouched.
- **Menu bar and panel:** the menu bar item is drawn with AppKit layers to keep CPU low. The panel is an `NSGlassEffectView` window, so it blurs what's behind it, with SwiftUI content on top.

## Caveats

- Player relies on a private macOS framework, so a macOS update could break it.
- Builds aren't notarised, so the first launch needs Open Anyway (see [Download](#download)).

## Project layout

```
Sources/Player/
  PlayerApp.swift        app entry point
  NowPlaying/            helper process, track model, AppleScript fallback
  Audio/                 Mac volume, per-app volume taps, permission check
  StatusBar/             menu bar item, equalizer, glass panel window
  Panel/                 panel UI and the artwork colour flood
Helper/                  MediaRemote helper (Objective-C, loaded by perl)
Resources/               Info.plist and the Icon Composer app icon
scripts/                 build script and icon generator
```
