import Foundation
import CoreWLAN
import AudioToolbox

// ---------------------------------------------------------------------------
// Signal Scout — Wi-Fi Geiger counter
// Locks onto the BSSID of the access point you're connected to, emits
// Poisson-distributed Geiger clicks whose rate rises with signal strength,
// and renders a live hotter/colder dashboard with a signal history graph.
// Every reading is logged to a timestamped CSV in ./logs/.
// ---------------------------------------------------------------------------

// --- Tunables ----------------------------------------------------------------
// -90ish = barely hearing it / far away,  -35ish = right on top of it.
let farRSSI: Double = -85
let nearRSSI: Double = -38
// Click rate: a real Geiger counter clicks at random (Poisson) intervals whose
// average rate rises with intensity.
let slowClickRate: Double = 1.1   // mean clicks/sec when far
let fastClickRate: Double = 33.0  // mean clicks/sec when very close
let pollSleep: useconds_t = 120_000  // ~8 RSSI reads/sec
let uiSleep: useconds_t = 250_000    // 4 dashboard redraws/sec
let avgWindow = 12         // rolling-average window (~1.5 s at 8 Hz)
let trendWindow = 24       // samples kept for the trend comparison (~3 s)
let historyCapacity = 120  // averaged samples in the graph (~30 s at 4 Hz)
let trendThreshold = 1.0   // dB of average movement that counts as a real move

// --- ANSI helpers ------------------------------------------------------------
let esc = "\u{001B}"
let red = "\(esc)[31m", blue = "\(esc)[34m", yellow = "\(esc)[33m"
let bold = "\(esc)[1m", dim = "\(esc)[2m", reset = "\(esc)[0m"

// --- Rolling buffers ---------------------------------------------------------
struct RingBuffer {
    let capacity: Int
    private(set) var values: [Double] = []
    init(capacity: Int) { self.capacity = capacity }
    mutating func append(_ v: Double) {
        values.append(v)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
    var isFull: Bool { values.count == capacity }
    func mean(last n: Int) -> Double? {
        let slice = values.suffix(n)
        return slice.isEmpty ? nil : slice.reduce(0, +) / Double(slice.count)
    }
    func mean(first n: Int) -> Double? {
        let slice = values.prefix(n)
        return slice.isEmpty ? nil : slice.reduce(0, +) / Double(slice.count)
    }
}

enum Trend { case hotter, colder, steady, unknown }

enum WifiEvent {
    case locked(bssid: String)
    case roamed(from: String, to: String)
    case reassociated(bssid: String)
    case newPeak(Int)
}

struct Snapshot {
    var rssi: Int
    var avg: Double?
    var trend: Trend
    var peak: Int
    var ssid: String
    var lockedBSSID: String?
    var currentBSSID: String?
    var roamed: Bool
    var ssidOnlyMode: Bool
    var history: [Double]
}

// --- Shared state ------------------------------------------------------------
final class State {
    private let lock = NSLock()
    private var rssi = 0  // 0 == not connected
    private var samples = RingBuffer(capacity: trendWindow)
    private var history = RingBuffer(capacity: historyCapacity)
    private var ssid = "—"
    private var currentBSSID: String?
    private var lockedBSSID: String?
    private var roamed = false
    private var ssidOnlyMode = false
    private var peak = -200

    func update(rssi newRSSI: Int, ssid newSSID: String?, bssid newBSSID: String?) -> [WifiEvent] {
        lock.lock(); defer { lock.unlock() }
        var events: [WifiEvent] = []
        rssi = newRSSI
        if let s = newSSID { ssid = s }
        currentBSSID = newBSSID
        guard newRSSI != 0 else { return events }

        if let b = newBSSID {
            ssidOnlyMode = false
            if let target = lockedBSSID {
                if b != target {
                    if !roamed {
                        roamed = true
                        events.append(.roamed(from: target, to: b))
                    }
                } else if roamed {
                    roamed = false
                    events.append(.reassociated(bssid: b))
                }
            } else {
                lockedBSSID = b
                events.append(.locked(bssid: b))
            }
        } else {
            // macOS 14+ hides the BSSID unless Location Services is granted.
            ssidOnlyMode = true
        }

        // While roamed we're reading a different AP — don't pollute the data.
        if !roamed {
            samples.append(Double(newRSSI))
            if newRSSI > peak {
                peak = newRSSI
                events.append(.newPeak(newRSSI))
            }
        }
        return events
    }

    // Called at the UI cadence so the graph spans a predictable time window.
    func recordHistory() {
        lock.lock(); defer { lock.unlock() }
        guard rssi != 0, !roamed, let avg = samples.mean(last: avgWindow) else { return }
        history.append(avg)
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        let avg = samples.mean(last: avgWindow)
        var trend = Trend.unknown
        if samples.isFull,
           let now = samples.mean(last: avgWindow),
           let past = samples.mean(first: trendWindow - avgWindow) {
            let d = now - past
            if d > trendThreshold { trend = .hotter }
            else if d < -trendThreshold { trend = .colder }
            else { trend = .steady }
        }
        return Snapshot(rssi: rssi, avg: avg, trend: trend, peak: peak, ssid: ssid,
                        lockedBSSID: lockedBSSID, currentBSSID: currentBSSID,
                        roamed: roamed, ssidOnlyMode: ssidOnlyMode, history: history.values)
    }
}
let state = State()

// --- CSV logging -------------------------------------------------------------
final class CSVLogger {
    let path: String
    private let handle: FileHandle
    private let timeFormatter: ISO8601DateFormatter

    init?() {
        let dir = "logs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let nameFormatter = DateFormatter()
        nameFormatter.dateFormat = "yyyyMMdd-HHmmss"
        path = "\(dir)/scout-\(nameFormatter.string(from: Date())).csv"
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else { return nil }
        handle = h
        timeFormatter = ISO8601DateFormatter()
        timeFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        writeLine("timestamp,rssi_dbm,avg_dbm,ssid,bssid,event")
    }

    // SSIDs are arbitrary user-controlled strings; quote anything unsafe.
    private func field(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private func writeLine(_ line: String) {
        handle.write((line + "\n").data(using: .utf8)!)
    }

    func log(rssi: Int, avg: Double?, ssid: String, bssid: String?, event: String = "") {
        let row = [
            timeFormatter.string(from: Date()),
            rssi == 0 ? "" : String(rssi),
            avg.map { String(format: "%.1f", $0) } ?? "",
            field(ssid),
            field(bssid ?? ""),
            event,
        ].joined(separator: ",")
        writeLine(row)
    }

    func close() { try? handle.close() }
}
let logger = CSVLogger()
logger?.log(rssi: 0, avg: nil, ssid: "", bssid: nil, event: "start")

// --- Audio -------------------------------------------------------------------
var clickSound: SystemSoundID = 0
AudioServicesCreateSystemSoundID(
    URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff") as CFURL, &clickSound)
var alertSound: SystemSoundID = 0
AudioServicesCreateSystemSoundID(
    URL(fileURLWithPath: "/System/Library/Sounds/Basso.aiff") as CFURL, &alertSound)

func clickRate(forAvg avg: Double) -> Double {
    let r = max(farRSSI, min(nearRSSI, avg))
    let t = (r - farRSSI) / (nearRSSI - farRSSI)       // 0 = far, 1 = near
    return slowClickRate * pow(fastClickRate / slowClickRate, t)  // exponential
}

// --- CoreWLAN reader ---------------------------------------------------------
guard let iface = CWWiFiClient.shared().interface() else {
    FileHandle.standardError.write("No Wi-Fi interface found.\n".data(using: .utf8)!)
    exit(1)
}

var keepGoing = true
signal(SIGINT) { _ in keepGoing = false }

DispatchQueue.global(qos: .userInitiated).async {
    while keepGoing {
        let rssi = iface.rssiValue()
        let ssid = iface.ssid()
        let bssid = iface.bssid()
        let events = state.update(rssi: rssi, ssid: ssid, bssid: bssid)

        var eventNames: [String] = []
        for event in events {
            switch event {
            case .locked:
                eventNames.append("locked")
            case .roamed:
                eventNames.append("roam")
                AudioServicesPlaySystemSound(alertSound)
            case .reassociated:
                eventNames.append("reassociated")
            case .newPeak:
                eventNames.append("peak")
            }
        }

        if rssi != 0 || !eventNames.isEmpty {
            let s = state.snapshot
            logger?.log(rssi: rssi, avg: s.avg, ssid: s.ssid, bssid: bssid,
                        event: eventNames.joined(separator: ";"))
        }
        usleep(rssi != 0 ? pollSleep : 250_000)
    }
}

// --- Geiger clicker: Poisson process driven by the rolling average -----------
DispatchQueue.global(qos: .userInteractive).async {
    while keepGoing {
        let s = state.snapshot
        guard s.rssi != 0, !s.roamed, let avg = s.avg else {
            usleep(250_000)
            continue
        }
        AudioServicesPlaySystemSound(clickSound)
        // Exponentially distributed gap => Poisson click train at rate λ.
        let rate = clickRate(forAvg: avg)
        let u = Double.random(in: Double.leastNonzeroMagnitude..<1)
        let gap = min(2.0, max(0.004, -log(u) / rate))
        usleep(useconds_t(gap * 1_000_000))
    }
}

// --- Dashboard rendering -------------------------------------------------------
func bar(forAvg avg: Double, width: Int = 26) -> String {
    let pct = max(0.0, min(1.0, (avg - farRSSI) / (nearRSSI - farRSSI)))
    let filled = Int((Double(width) * pct).rounded())
    return String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
}

let sparkChars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
func sparkline(_ values: [Double]) -> String {
    String(values.map { v -> Character in
        let t = max(0.0, min(1.0, (v - farRSSI) / (nearRSSI - farRSSI)))
        let idx = min(sparkChars.count - 1, Int(t * Double(sparkChars.count)))
        return sparkChars[idx]
    })
}

var firstDraw = true
func render(_ lines: [String]) {
    if !firstDraw { print("\(esc)[\(lines.count)A", terminator: "") }
    firstDraw = false
    for line in lines { print("\(esc)[2K" + line) }
    fflush(stdout)
}

print("\(esc)[?25l", terminator: "")
print("Signal Scout — Wi-Fi Geiger counter.  Get closer = faster clicks.  Ctrl-C to stop.\n")

while keepGoing {
    state.recordHistory()
    let s = state.snapshot
    let logNote = dim + "log: \(logger?.path ?? "—")" + reset

    let header: String
    if let target = s.lockedBSSID {
        header = "Locked: \(bold)\(target)\(reset)  (\(s.ssid))   \(logNote)"
    } else if s.ssidOnlyMode {
        header = yellow + "SSID-only mode — grant Location Services to lock the BSSID" + reset
            + "  (\(s.ssid))   \(logNote)"
    } else {
        header = dim + "Waiting for Wi-Fi connection…" + reset + "   \(logNote)"
    }

    let readout: String
    let status: String
    if s.rssi == 0 {
        readout = dim + "[not connected]  join the target network…" + reset
        status = " "
    } else {
        let avgText = s.avg.map { String(format: "%.1f", $0) } ?? "—"
        readout = String(format: "%4d dBm  avg %@  peak %d   %@",
                         s.rssi, avgText, s.peak, bar(forAvg: s.avg ?? Double(s.rssi)))
        if s.roamed {
            status = red + bold + "⚠ ROAMED" + reset + red
                + " — now on \(s.currentBSSID ?? "?"), clicks paused (restart to re-lock)" + reset
        } else {
            switch s.trend {
            case .hotter:  status = red + bold + "▲ HOTTER" + reset
            case .colder:  status = blue + bold + "▼ COLDER" + reset
            case .steady:  status = dim + "· steady" + reset
            case .unknown: status = dim + "… gathering signal" + reset
            }
        }
    }

    let graph: String
    if s.history.isEmpty {
        graph = dim + "(history graph will appear here)" + reset
    } else {
        let span = Double(s.history.count) * Double(uiSleep) / 1_000_000
        graph = sparkline(s.history) + dim
            + String(format: "  (%.0f … %.0f dBm, last ~%.0fs)", farRSSI, nearRSSI, span) + reset
    }

    render([header, readout, status, graph])
    usleep(uiSleep)
}

// Let the background loops notice keepGoing before closing the log.
usleep(200_000)
logger?.close()
print("\(esc)[?25h\nStopped." + (logger.map { "  Log saved to \($0.path)" } ?? ""))
