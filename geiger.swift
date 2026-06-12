import Foundation
import CoreWLAN
import CoreLocation
import AudioToolbox

// ---------------------------------------------------------------------------
// WiFi Geiger Counter
// Tracks a target SSID's signal strength (RSSI, in dBm) and emits Geiger-style
// clicks that get faster as you get closer. Far more precise than "3 bars".
//
//   LINKED mode: if your Mac is connected to the target network, RSSI is read
//                directly off the radio many times a second (instant, exact).
//   SCAN mode:   otherwise it actively scans for the target by name and uses
//                the strongest matching access point (slower, ~1-3s per read,
//                and may require Location Services permission).
// ---------------------------------------------------------------------------

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write("""
    Usage: geiger <SSID>

    Tracks Wi-Fi signal strength (RSSI) and plays Geiger-style clicks
    that speed up as you get closer to the target network.

    """.data(using: .utf8)!)
    exit(1)
}
let target = args[1]

// --- Tunable signal range (dBm) -------------------------------------------
// -90ish = barely hearing it / far away,  -35ish = right on top of it.
let farRSSI:  Double = -85
let nearRSSI: Double = -38
// Click cadence: slow when far, a near-buzz when close.
let slowInterval: Double = 0.90   // seconds between clicks when far
let fastInterval: Double = 0.030  // seconds between clicks when very close

// --- Shared state ----------------------------------------------------------
final class State {
    private let lock = NSLock()
    private var _rssi: Int = 0          // 0 == not found this read
    private var _smooth: Double = -100
    private var _mode: String = "…"
    private var _bssid: String = "—"
    private var _peak: Int = -200

    func update(rssi: Int, mode: String, bssid: String?) {
        lock.lock(); defer { lock.unlock() }
        _rssi = rssi
        _mode = mode
        _bssid = bssid ?? _bssid
        if rssi != 0 {
            // exponential moving average for a steadier "warmer/colder" read
            _smooth = _smooth == -100 ? Double(rssi) : _smooth * 0.6 + Double(rssi) * 0.4
            if rssi > _peak { _peak = rssi }
        }
    }
    var snapshot: (rssi: Int, smooth: Double, mode: String, bssid: String, peak: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_rssi, _smooth, _mode, _bssid, _peak)
    }
}
let state = State()

// --- Audio: short click via system sound ----------------------------------
var clickSound: SystemSoundID = 0
let clickURL = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff") as CFURL
AudioServicesCreateSystemSoundID(clickURL, &clickSound)

func intervalFor(rssi: Int) -> Double {
    let r = max(farRSSI, min(nearRSSI, Double(rssi)))
    let t = (r - farRSSI) / (nearRSSI - farRSSI)        // 0 = far, 1 = near
    return slowInterval * pow(fastInterval / slowInterval, t)  // exponential
}

// --- CoreWLAN reader -------------------------------------------------------
guard let iface = CWWiFiClient.shared().interface() else {
    FileHandle.standardError.write("No Wi-Fi interface found.\n".data(using: .utf8)!)
    exit(1)
}

let running = DispatchSemaphore(value: 0)
var keepGoing = true

// Clean exit: restore cursor.
signal(SIGINT) { _ in
    print("\u{001B}[?25h\nStopped.")
    exit(0)
}

// Reader thread.
// Preferred: read the signal of the network we're CONNECTED to (instant,
// exact, needs no permission). If you're connected to the target network, the link
// RSSI is literally your distance-to-device signal — perfect for homing in.
// Fallback: if not connected, actively scan for the target by name (slower,
// and needs Location Services enabled for the terminal to see network names).
DispatchQueue.global(qos: .userInitiated).async {
    while keepGoing {
        let assoc = iface.rssiValue()
        if assoc != 0 {
            state.update(rssi: assoc, mode: "LINKED", bssid: iface.bssid())
            usleep(120_000) // ~8 reads/sec, very responsive
        } else {
            do {
                let nets = try iface.scanForNetworks(withName: target)
                if let best = nets.max(by: { $0.rssiValue < $1.rssiValue }) {
                    state.update(rssi: best.rssiValue, mode: "SCAN", bssid: best.bssid)
                } else {
                    state.update(rssi: 0, mode: "no signal", bssid: nil)
                }
            } catch {
                state.update(rssi: 0, mode: "scan err", bssid: nil)
            }
            usleep(200_000)
        }
    }
}

// Clicker thread
DispatchQueue.global(qos: .userInteractive).async {
    while keepGoing {
        let s = state.snapshot
        if s.rssi == 0 {
            usleep(250_000)
            continue
        }
        AudioServicesPlaySystemSound(clickSound)
        usleep(useconds_t(intervalFor(rssi: s.rssi) * 1_000_000))
    }
}

// --- Display loop (main) ---------------------------------------------------
func bar(forRSSI rssi: Double, width: Int = 30) -> String {
    let pct = max(0.0, min(1.0, (rssi - farRSSI) / (nearRSSI - farRSSI)))
    let filled = Int((Double(width) * pct).rounded())
    return String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
}

print("\u{001B}[?25l", terminator: "")           // hide cursor
print("WiFi Geiger Counter  —  target: \(target)")
print("Get closer = faster clicks.  Ctrl-C to stop.\n")

var lastSmooth = -100.0
while keepGoing {
    let s = state.snapshot
    let smooth = s.smooth
    var trend = "  steady "
    if s.rssi != 0 && lastSmooth != -100 {
        let d = smooth - lastSmooth
        if d > 0.6 { trend = "↑ WARMER" }
        else if d < -0.6 { trend = "↓ colder" }
    }
    lastSmooth = smooth

    let line: String
    if s.rssi == 0 {
        line = String(format: "[%@]  searching for %@ …            ", s.mode, target)
    } else {
        line = String(format: "[%@] %4d dBm  %@  %@   peak:%d dBm  %@   ",
                      s.mode, s.rssi, bar(forRSSI: Double(s.rssi)), trend, s.peak, s.bssid)
    }
    print("\r\u{001B}[2K" + line, terminator: "")
    fflush(stdout)
    usleep(120_000)
}
running.wait()
