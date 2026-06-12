import Foundation
import CoreWLAN
import CoreLocation

let iface = CWWiFiClient.shared().interface()
print("interface:", iface?.interfaceName ?? "nil")
print("associated ssid:", iface?.ssid() ?? "—")
print("associated rssi:", iface?.rssiValue() ?? 0)
print("location auth:", CLLocationManager().authorizationStatus.rawValue,
      "(3/4 = authorized, 0 = notDetermined, 2 = denied)")
do {
    let nets = try iface?.scanForNetworks(withName: nil) ?? []
    print("scan found \(nets.count) networks:")
    for n in nets.sorted(by: { $0.rssiValue > $1.rssiValue }) {
        print(String(format: "  %4d dBm  %@", n.rssiValue, n.ssid ?? "<hidden>"))
    }
} catch {
    print("scan error:", error)
}
