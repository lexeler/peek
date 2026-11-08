# Peek

Peek is a Liquid Glass panel for the MacBook notch. Move the pointer onto the camera and the glass flows out of it. The panel holds:

- **Music** — whatever is playing now (Yandex Music, a browser, …): artwork, play/pause, skip.
- **Headphones** — AirPods, Huawei and other Bluetooth headphones: connect or disconnect with one tap.
- **Translator** RU⇄EN — on-device, offline. How to use it:
  - hover → ⌘V or dictate → the translation appears;
  - click the translation or press ↩ to copy it;
  - the text is kept for 5 minutes after the panel closes.
- **A toggle** for the system VPN profile from System Settings → VPN, if there is one.

At rest you only see the notch with a thin status rim; its style can be changed in Settings or turned off. On Macs without a notch, a small "island" appears at the top center instead; it can be turned off or moved.

The interface is in Russian.

## Install the app

Requires an Apple Silicon Mac (M1 or newer) running macOS 26 Tahoe.

1. Download the latest `Peek-<version>.zip` from [Releases](https://github.com/lexeler/peek/releases), or build it yourself (see below).
2. Unzip it and drag Peek into Applications.
3. Peek is not notarized by Apple, so macOS blocks the first launch. Run this once in Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Peek.app
   ```
   Without Terminal: open Peek, click Done, then go to System Settings → Privacy & Security → Open Anyway.
4. Open Peek. There is no Dock icon: move the pointer onto the notch. Peek turns on start-at-login by itself (you can turn it off in Settings).
5. The first time the panel opens, macOS asks for Bluetooth access; it is needed for the headphones. Translator languages are downloaded from Settings (⚙︎).

## Controls

| Action | How |
|---|---|
| Open | hover over the notch (or click it) |
| Close | move the pointer away, press Esc or click outside |
| Settings | ⚙︎ in the panel, right-click the notch, or ⌘, |
| Quit | right-click the notch → Quit |

## Build from source

Only the Command Line Tools for macOS 26 are needed (`xcode-select --install`), no Xcode.

```sh
git clone https://github.com/lexeler/peek.git && cd peek
scripts/build.sh --install   # build, copy to /Applications, enable start-at-login
scripts/build.sh             # build only, into .build-app/Peek.app
scripts/build.sh --zip       # also pack dist/Peek-<version>.zip to share
```

`--install` registers a launchd agent: Peek starts at login and restarts by itself if it crashes. Quitting from the menu is respected, and launchd does not start it again.

To remove everything:

```sh
/Applications/Peek.app/Contents/MacOS/Peek --uninstall-agent && rm -rf /Applications/Peek.app
defaults delete com.lexeler.Peek   # optional: also erase the settings
```

## How it works, and why it costs almost nothing

- **Zero work at rest.** No timers, no polling, no animations. VPN, Bluetooth and pointer changes arrive as system events.
- **Glass only while the panel is open.** Liquid Glass and all modules exist only while the panel is open, and are released when it closes.
- **Now Playing is read only while the panel is open.** Since macOS 15.4, only Apple processes may read Now Playing. So Peek runs [`mediaremote-adapter`](Vendor/mediaremote-adapter) (BSD-3) through the system `/usr/bin/perl`, and only while the panel is open. A watchdog process guarantees the adapter never outlives Peek.
- **Translation on the Mac.** Apple Translation runs in a separate helper process. It exits 90 seconds after the panel closes, and the text is forgotten after 5 minutes.
- **Quiet restart.** If the panel stays closed for 15 minutes and Peek uses more than 20 MB, it restarts invisibly through launchd and is back at about 13 MB. This never happens while the panel or Settings is open, languages are downloading, or headphones are connecting.
- **No logs.** Peek writes nothing to disk except its settings (`defaults read com.lexeler.Peek`).
- **Local signing.** Builds are signed with a self-signed certificate in `.signing/`. It is created on the first build and never committed. This keeps the Bluetooth permission across rebuilds.

## Layout

```
Sources/Peek/
  App/       entry point, start-at-login (launchd), settings
  Window/    the window over the notch, screen geometry, hover and focus
  Services/  VPN, Bluetooth, Now Playing, translator
  UI/        SwiftUI: notch, indicators, cards, settings
Vendor/      mediaremote-adapter (BSD-3)
scripts/     build.sh
```
