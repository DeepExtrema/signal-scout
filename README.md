# Signal Scout

A macOS Wi-Fi "Geiger counter" that helps you physically locate a device by tracking signal strength. Clicks get faster as you get closer — far more precise than glancing at three bars.

Built for situations like finding a misplaced hotspot, router, or IoT device in a large space when someone keeps moving it around.

## Requirements

- macOS with Wi-Fi
- Xcode Command Line Tools (`swiftc`)

## Quick start

```bash
git clone https://github.com/DeepExtrema/signal-scout.git
cd signal-scout
./find.sh YourNetworkName
```

Or build and run directly:

```bash
swiftc -O geiger.swift -o geiger
./geiger YourNetworkName
```

Press **Ctrl-C** to stop.

## How it works

Signal Scout reads **RSSI** (received signal strength, in dBm) and maps it to click rate:

| Mode | When | Speed |
|------|------|-------|
| **LINKED** | Your Mac is connected to the target network | ~8 reads/sec, instant |
| **SCAN** | Not connected; scans for the SSID by name | ~1–3 sec per read |

**LINKED mode is best.** Stay connected to the target network and walk toward stronger signal. The live display shows:

- Exact dBm reading
- Signal bar
- **WARMER / colder** trend arrow
- Peak dBm (strongest spot you've found)

### Rough distance guide

| dBm | Meaning |
|-----|---------|
| -40 to -50 | Within a few feet |
| -60s | Same room / area |
| -80s | Far away or blocked by walls |

## Tips for hunting

1. Connect your Mac to the target network before starting.
2. Walk slowly and watch the dBm number and click rate.
3. Higher (closer to 0) = warmer. Lower = colder.
4. Use the **peak** readout to remember your best location.
5. If the device moves, your reading drops — sweep until it climbs again.

## Scan mode & permissions

If you lose the connection and fall back to scan mode, macOS may hide network names unless **Location Services** is enabled for your terminal:

**System Settings → Privacy & Security → Location Services → Terminal → On**

## Diagnostics

A small helper is included to inspect what your Mac can see:

```bash
swiftc -O diag.swift -o diag
./diag
```

## License

MIT
