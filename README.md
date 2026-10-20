<p align="center"><img src="docs/icon.png" width="96" alt=""></p>

<h1 align="center">Vitals</h1>

<p align="center">A tiny menu bar app that watches your Macs — this one and any other over SSH —<br>
and controls their fans. Watts, CPU, memory pressure, temperatures, and a year of power history.</p>

<p align="center"><img src="docs/menubar.png" alt="Vitals in the menu bar: watts over CPU temperature for each Mac"></p>

![The Mac mini view: 4.6 W now, a one-hour power chart, per-core CPU bars, memory pressure, thermals, fan and processes](docs/mac-mini.png)

Built for a headless Mac mini (a home server, a build box, an AI rig) that you want to keep an eye on
from your laptop — without installing a 100 MB monitoring suite on either.

## What it shows

- **Power** — the whole machine's watts right now, where they go (CPU, GPU, memory, other), and how
  much energy each day used. On a MacBook: adapter watts and battery.
- **History** — 10 minutes, 1 hour, 24 hours and 14 days. Each Mac logs one row a minute to CSV, kept
  a year, even while the app is closed.
- **Pressure, in every sense** — a bar per CPU core, load, memory pressure and swap, macOS thermal
  pressure, CPU/GPU/SSD temperatures, GPU load, network and disk throughput, and the processes behind
  the load.
- **One finding** — a sentence under the title says what needs attention ("Memory is the pressure
  point: 19.8 of 24 GB used, 4.5 GB in swap").
- **Fans** — Auto, Fixed (drag to a speed) or Curve (follows CPU temperature between two points).

![The MacBook view, under load: 80 W, all cores busy, 98 °C, both fans near maximum](docs/macbook.png)

## Light by design

| | Memory | CPU at rest |
| --- | --- | --- |
| Vitals app | ~20–35 MB | ~0.3% |
| Agent on each Mac | ~5 MB | ~0.2% |

Native AppKit drawn in a single view: no web view, no SwiftUI, no dependencies. Sampling is 1 s while
the panel is open, 5 s for the menu bar, and the costly process scan only runs while you are looking.

## Requirements

- Apple Silicon Macs (M1 and later), macOS 14 or later.
- For a remote Mac: key-based SSH that works without a password prompt, e.g. a `Host mac-mini`
  entry in `~/.ssh/config`. Tailscale works well.

## Install

**From source** (needs only the Xcode Command Line Tools):

```bash
git clone https://github.com/samvladd/vitals.git && cd vitals && ./build.sh && cp -R build/Vitals.app /Applications/
```

**Or download** `Vitals.zip` from [Releases](https://github.com/samvladd/vitals/releases). The app is not
notarized, so macOS will block the first launch; allow it once in System Settings → Privacy & Security
→ Open Anyway, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Vitals.app
```

Then open Vitals, click the readings in the menu bar → **Settings**, and enter your remote Mac's SSH
host (default `mac-mini`). Vitals copies its agent to `~/.vitals/` on that Mac and starts the logger
there by itself.

![Settings](docs/settings.png)

## Fan control

Writing fan speeds needs root, so it is opt-in, once per Mac: **Settings → Fan control → Set up**.
It asks for your password once, then installs a root-owned copy of the agent at
`/usr/local/libexec/vitals-agent` and a sudo rule that allows exactly `vitals-agent stream` and nothing
else. By hand:

```bash
sudo "$HOME/Library/Application Support/Vitals/bin/vitals-agent" setup-root
```

```bash
ssh -t mac-mini 'sudo ~/.vitals/vitals-agent setup-root'
```

Safety:

- Above **95 °C** the fans go to full speed, whatever mode you chose.
- Fans return to **Auto** whenever Vitals quits, crashes or loses the connection.
- Speeds are kept within each fan's own minimum and maximum.

Quit other fan apps (Macs Fan Control, Stats' fan module) first, or they will fight over the fans.
Fan control talks to the SMC directly, as those apps do; use it at your own risk.

## How it works

| Piece | Runs on | Job |
| --- | --- | --- |
| `Vitals.app` | your Mac | Menu bar item and panel. |
| `vitals-agent stream` | each Mac | Reads the SMC (temperatures, fans, system watts), IOReport (CPU/GPU/memory energy), CPU ticks, VM stats and I/O counters; prints one JSON line per tick. The remote one runs over a single SSH connection. |
| `vitals-agent log` | each Mac, under launchd | Writes the per-minute log to `~/Library/Application Support/Vitals/Logs/`. |

No network traffic leaves your machines except that SSH connection. No analytics, no accounts.

Some chips do not fill in every counter (on the M5, CPU and memory energy read zero); Vitals shows a
dash rather than a made-up 0 W. The total system power is still measured.

## Uninstall

```bash
sudo "$HOME/Library/Application Support/Vitals/bin/vitals-agent" remove-root
launchctl bootout gui/$(id -u)/com.vitals.logger; rm ~/Library/LaunchAgents/com.vitals.logger.plist
rm -rf /Applications/Vitals.app "$HOME/Library/Application Support/Vitals"
```

On the remote Mac, the same with `~/.vitals/vitals-agent` and `rm -rf ~/.vitals`.

## License

MIT
