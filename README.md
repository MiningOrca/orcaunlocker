# Orca Unlocker

Native Steam DLC unlocker for macOS.

Orca Unlocker is a native macOS alternative for people looking for CreamAPI, CreamInstaller or similar Steam DLC unlockers on Mac, without requiring Windows, Wine or a compatibility layer.

The project is built specifically for macOS and supports Apple Silicon and Intel runtime targets. Probably. I haven't tested Intel.

![Orca Unlocker](docs/screens/game_overview.png)

## Features

* Native macOS application
* Automatic runtime installation and management
* Check whether DLC files are present on disk or need to be downloaded separately (no auto-download yet)
* Restore/uninstall support
* No Windows installation or Wine environment required

## Requirements

* macOS 13 or later
* Steam for macOS
* A supported Steam game

## Installation and permission

Download the latest [Orca-Unlocker-macOS.zip](https://github.com/MiningOrca/orcaUnlocker/releases/latest/download/Orca-Unlocker-macOS.zip) from the [Releases](https://github.com/MiningOrca/orcaUnlocker/releases/) page. One day, I'll add proper release policy.

Extract the archive and open:

```text
Orca Unlocker.app
```

You may move the application to `/Applications` if desired or use directly from `~/Downloads`, honestly I do not care.

### Gatekeeper 

Current releases are ad-hoc signed but are not notarized by Apple.
Apple notarization requires using an Apple Developer identity tied to my real identity, which I do not want to expose for this project.
Because of this, macOS may block Orca Unlocker when it is opened for the first time.

The easiest way to remove the quarantine flag from the downloaded application is couple of terminal commands:
```bash
cd ~/Downloads
unzip Orca-Unlocker-macOS.zip
xattr -dr com.apple.quarantine "Orca Unlocker.app"
open "Orca Unlocker.app"
```


Alternatively you can use apple certified proper and very simple UI way:
1. Try to open the application once.
2. Go to **System Settings → Privacy & Security → Security → Open Anyway**.
3. Confirm that you want to run Orca Unlocker.

### Proxy method permissions

The Proxy method modifies files inside the target game's application bundle.
macOS therefore requires Orca Unlocker to have permission to modify other applications.
Unfortunatelly, you need to enable it manually:

**System Settings → Privacy & Security → App Management → Orca Unlocker**

Bad news - this permission is required when using the Proxy method. Good news - from my tests proxy method needs only for Stellaris.

## Usage

#### TL;DR:
1. Select a game.
2. Wait for it to load.
3. Click **Apply Changes**.

Select a game from your detected Steam library to open its configuration.

For transport selection, DLC configuration, advanced options and diagnostics, see the [Usage Guide](docs/usage.md).

## How it works

Orca Unlocker consists of several separate components:

```text
Orca Unlocker.app
├── Native macOS launcher
├── Steam helper
└── Runtime
    ├── manifest.json
    ├── proxy runtime
    └── injection runtime
```

The launcher is responsible for Steam discovery, configuration, installation and lifecycle management.

Low-level Steam integration is handled by bundled runtime components. Release runtime binaries are built separately and copied into the application bundle without modification.

Each runtime release includes a manifest containing metadata and SHA-256 hashes for the packaged artifacts.
This should work pretty much like CreamAPI from a user's point of view, but it is not CreamAPI. The runtime, including its proxy component, is my own implementation.
I build the runtime for both Apple Silicon (`arm64`) and Intel (`x86_64`) Macs. But I never had a chance to test it with intel mac.

## Project status

Orca Unlocker is under active development and will be updated. At least unless I die in the near future.

Compatibility may vary between games and game updates. Steam games can change their binaries, loading behavior or Steam API integration at any time.

## License

The Orca Unlocker source code is licensed under the
[PolyForm Noncommercial License 1.0.0](LICENSE.md).

Copyright © 2026 MiningOrca.

Non-commercial use, modification and redistribution are permitted subject to the license terms.

**Commercial use requires separate permission from the copyright holder.**

### Bundled runtime components

Some runtime components distributed with Orca Unlocker are proprietary software and are **not** licensed under the PolyForm Noncommercial License.

Those components remain:

```text
Copyright © 2026 MiningOrca. All rights reserved.
```

## Disclaimer

Orca Unlocker is an independent project and is not affiliated with, endorsed by, or sponsored by Valve Corporation or any game publisher or developer.

Steam is a trademark of Valve Corporation.
