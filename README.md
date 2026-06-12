# Signal Scout

A macOS Wi-Fi "Geiger counter" that helps you physically locate a device by tracking signal strength. Clicks get faster as you get closer — far more precise than glancing at three bars.

Built for situations like finding a misplaced hotspot, router, or IoT device in a large space when someone keeps moving it around.

## Requirements

- macOS with Wi-Fi
- Xcode Command Line Tools (`swiftc`)

## Quick start

Connect your Mac to the network you want to locate, then run:

```bash
git clone https://github.com/DeepExtrema/signal-scout.git
cd signal-scout
./find.sh
```

Or build and run directly:

```bash
swiftc -O geiger.swift -o geiger
./geiger
```

Press **Ctrl-C** to stop.

## How it works

Signal Scout reads **RSSI** (received signal strength, in dBm) from your current Wi-Fi connection ~8 times per second and turns it into sound and a live dashboard:

```text
Locked: AA:BB:CC:DD:EE:FF  (MyNetwork)   log: logs/scout-20260612-181203.csv
 -52 dBm  avg -54.1  peak -41   ████████████████··········
 ▲ HOTTER
 ▂▂▃▃▄▅▅▆▆▇▇▆▅▅▄▄▅▆▇█▇▇▆▅▄▃▂▂▃▄▅▆▇█  (-85 … -38 dBm, last ~30s)
```

### BSSID lock

On startup Signal Scout locks onto the **BSSID** (the hardware address of the exact access point you're associated with), not just the network name. If macOS silently roams to a different AP broadcasting the same SSID — the classic way signal hunting goes wrong — it plays an alert sound, shows a red `ROAMED` warning, and pauses the clicks so a stronger signal from the *wrong* device never misleads you. Walk back into range to re-associate, or restart to lock onto the new AP.

On macOS 14+ the system hides the BSSID unless the terminal app has **Location Services** permission (System Settings → Privacy & Security → Location Services). Without it, Signal Scout falls back to SSID-only mode with a visible warning.

### Geiger-style clicking

Like a real Geiger counter, clicks fire at *random* (Poisson-distributed) intervals whose average rate rises with signal strength — roughly 1 click/sec when far, a ~30 clicks/sec crackle when you're on top of it.

### Rolling average and hotter/colder

The click rate, bar, and trend are driven by a ~1.5 s rolling average rather than raw readings, so single noisy jumps don't mislead you. The trend compares the current average against the average from ~3 s ago:

- Red **▲ HOTTER** — signal is genuinely climbing, keep going
- Blue **▼ COLDER** — you're walking away from it
- Dim **· steady** — no real change

### History graph

The bottom line is a sparkline of the last ~30 seconds of averaged signal, scaled between -85 and -38 dBm, so you can see the shape of your approach at a glance.

### CSV logs

Every session writes `logs/scout-YYYYMMDD-HHMMSS.csv` with one row per reading (~8 Hz):

```csv
timestamp,rssi_dbm,avg_dbm,ssid,bssid,event
2026-06-12T22:12:03.251Z,-69,-69.0,MyNetwork,aa:bb:cc:dd:ee:ff,peak
```

The `event` column marks `start`, `locked`, `roam`, `reassociated`, and `peak` moments, so you can reconstruct a hunt afterwards.

### Rough distance guide

| dBm | Meaning |
|-----|---------|
| -40 to -50 | Within a few feet |
| -60s | Same room / area |
| -80s | Far away or blocked by walls |

## Tips for hunting

1. Connect your Mac to the device’s network before starting.
2. Walk slowly and watch the dBm number and click rate.
3. Higher (closer to 0) = warmer. Lower = colder.
4. Use the **peak** readout to remember your best location.
5. If the device moves, your reading drops — sweep until it climbs again.
6. If you see the red **ROAMED** warning, you're now reading a different access point — don't trust the numbers until you re-associate or re-lock.

## Diagnostics

A small helper is included to inspect what your Mac can see:

```bash
swiftc -O diag.swift -o diag
./diag
```

## License

MIT
