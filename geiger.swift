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
let historyCapacity = 120  // averaged history samples kept (~60 s at 2 Hz)
let trendThreshold = 1.0   // dB of average movement that counts as a real move

// --- ANSI helpers ------------------------------------------------------------
let esc = "\u{001B}"
let red = "\(esc)[31m", blue = "\(esc)[34m", yellow = "\(esc)[33m"
let green = "\(esc)[32m", cyan = "\(esc)[36m"
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
    var trendDelta: Double?
    var peak: Int
    var low: Int
    var readings: Int
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
    private var low = 0   // 0 == no reading yet
    private var readings = 0

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
            readings += 1
            if low == 0 || newRSSI < low { low = newRSSI }
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
        var trendDelta: Double?
        if samples.isFull,
           let now = samples.mean(last: avgWindow),
           let past = samples.mean(first: trendWindow - avgWindow) {
            let d = now - past
            trendDelta = d
            if d > trendThreshold { trend = .hotter }
            else if d < -trendThreshold { trend = .colder }
            else { trend = .steady }
        }
        return Snapshot(rssi: rssi, avg: avg, trend: trend, trendDelta: trendDelta,
                        peak: peak, low: low, readings: readings, ssid: ssid,
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
let graphRows = 6      // chart height in terminal rows
let graphWidth = 64    // chart width in columns (one history sample per column)
let historyEvery = 2   // record a history sample every Nth UI tick (2 Hz)
let startDate = Date()

// Heat color on the absolute far↔near scale: blue = far/cold … red = near/hot.
func heatColor(_ rssi: Double) -> String {
    let t = max(0.0, min(1.0, (rssi - farRSSI) / (nearRSSI - farRSSI)))
    switch t {
    case ..<0.2: return blue
    case ..<0.4: return cyan
    case ..<0.6: return green
    case ..<0.8: return yellow
    default:     return red
    }
}

func bar(forAvg avg: Double, width: Int = 26) -> String {
    let pct = max(0.0, min(1.0, (avg - farRSSI) / (nearRSSI - farRSSI)))
    let filled = Int((Double(width) * pct).rounded())
    return heatColor(avg) + String(repeating: "█", count: filled) + reset
        + dim + String(repeating: "·", count: width - filled) + reset
}

let blockChars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

// Multi-row column chart, auto-scaled to the visible data (with a minimum
// 4 dB span) so small wobbles around a steady signal are actually visible.
// Always returns graphRows + 2 lines (chart, x-axis, time labels).
func graphLines(_ values: [Double]) -> [String] {
    let axisPrefix = "     │", axisCorner = "     └"
    let shown = Array(values.suffix(graphWidth))
    guard !shown.isEmpty else {
        var lines = Array(repeating: axisPrefix, count: graphRows)
        lines[graphRows / 2] += dim + "  (signal history will appear here)" + reset
        lines.append(axisCorner + String(repeating: "─", count: graphWidth))
        lines.append("      " + dim + "waiting for data…" + reset)
        return lines
    }

    var lo = shown.min()!, hi = shown.max()!
    if hi - lo < 4 {                      // enforce a minimum span
        let mid = (hi + lo) / 2
        lo = mid - 2; hi = mid + 2
    }
    let pad = (hi - lo) * 0.10
    let gLo = lo - pad, gHi = hi + pad

    var lines: [String] = []
    for r in 0..<graphRows {
        let rowTop = Double(graphRows - r)       // row edges, in row units from the bottom
        let rowBottom = rowTop - 1
        let labelValue = gHi - (Double(r) + 0.5) / Double(graphRows) * (gHi - gLo)
        var line = r % 2 == 0 ? String(format: "%4.0f ┤", labelValue) : axisPrefix
        for v in shown {
            let h = (v - gLo) / (gHi - gLo) * Double(graphRows)
            if h >= rowTop {
                line += heatColor(v) + "█" + reset
            } else if h > rowBottom {
                let idx = min(blockChars.count - 1, Int((h - rowBottom) * 8))
                line += heatColor(v) + String(blockChars[idx]) + reset
            } else {
                line += " "
            }
        }
        lines.append(line)
    }
    lines.append(axisCorner + String(repeating: "─", count: graphWidth))

    let span = Double(shown.count) * Double(uiSleep) / 1_000_000 * Double(historyEvery)
    let leftLabel = String(format: "-%.0fs", span)
    let gap = max(1, graphWidth - leftLabel.count - 3)
    lines.append("      " + dim + leftLabel + String(repeating: " ", count: gap) + "now" + reset)
    return lines
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

var tick = 0
while keepGoing {
    if tick % historyEvery == 0 { state.recordHistory() }
    tick += 1
    let s = state.snapshot

    let elapsed = Int(Date().timeIntervalSince(startDate))
    let clock = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    let sessionNote = dim + "elapsed \(clock) · \(s.readings) readings" + reset

    let header: String
    if let target = s.lockedBSSID {
        header = " Locked: \(bold)\(target)\(reset)  (\(s.ssid))   \(sessionNote)"
    } else if s.ssidOnlyMode {
        header = " " + yellow + "SSID-only mode — grant Location Services to lock the BSSID" + reset
            + "   \(sessionNote)"
    } else {
        header = " " + dim + "Waiting for Wi-Fi connection…" + reset + "   \(sessionNote)"
    }

    let readout: String
    let barLine: String
    if s.rssi == 0 {
        readout = " " + dim + "[not connected]  join the target network…" + reset
        barLine = " "
    } else {
        let avgText = s.avg.map { String(format: "%.1f", $0) } ?? "—"
        let lowText = s.low < 0 ? "\(s.low)" : "—"
        let rateText = s.avg.map { String(format: "%.1f", clickRate(forAvg: $0)) } ?? "—"
        readout = " now " + heatColor(Double(s.rssi)) + bold + "\(s.rssi) dBm" + reset
            + "   avg \(avgText)   peak \(s.peak)   low \(lowText)   "
            + dim + "~\(rateText) clicks/s" + reset

        let status: String
        if s.roamed {
            status = red + bold + "⚠ ROAMED" + reset + red
                + " — on \(s.currentBSSID ?? "?"), clicks paused" + reset
        } else {
            let deltaText = s.trendDelta.map { String(format: " %+.1f dB", $0) } ?? ""
            switch s.trend {
            case .hotter:  status = red + bold + "▲ HOTTER" + reset + red + deltaText + reset
            case .colder:  status = blue + bold + "▼ COLDER" + reset + blue + deltaText + reset
            case .steady:  status = dim + "· steady" + deltaText + reset
            case .unknown: status = dim + "… gathering signal" + reset
            }
        }
        barLine = " far ▕" + bar(forAvg: s.avg ?? Double(s.rssi)) + "▏near   " + status
    }

    let footer = " " + dim + "log: \(logger?.path ?? "—")  ·  Ctrl-C to stop" + reset

    render([header, readout, barLine, ""] + graphLines(s.history) + [footer])
    usleep(uiSleep)
}

// Let the background loops notice keepGoing before closing the log.
usleep(200_000)
logger?.close()
print("\(esc)[?25h\nStopped." + (logger.map { "  Log saved to \($0.path)" } ?? ""))
