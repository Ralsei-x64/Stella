import Combine
import Foundation
import IOKit.ps
import notify

struct MacBattery: Equatable {
    enum State: String { case charging, discharging, full, idle }
    let percent: Int
    let state: State

    init?(_ source: [String: Any]) {
        guard source[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              source[kIOPSIsPresentKey] as? Bool == true,
              let current = source[kIOPSCurrentCapacityKey] as? Int,
              let maximum = source[kIOPSMaxCapacityKey] as? Int,
              maximum > 0, (0...maximum).contains(current),
              let power = source[kIOPSPowerSourceStateKey] as? String else { return nil }
        percent = Int((Double(current) / Double(maximum) * 100).rounded())
        switch power {
        case kIOPSBatteryPowerValue: state = .discharging
        case kIOPSACPowerValue:
            if source[kIOPSIsChargingKey] as? Bool == true { state = .charging }
            else if source[kIOPSIsChargedKey] as? Bool == true || current == maximum { state = .full }
            else { state = .idle }
        default: return nil
        }
    }

    static func current() -> MacBattery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            if let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               let battery = MacBattery(values) { return battery }
        }
        return nil
    }

    var line: String { "\(percent) \(state.rawValue)" }

    static func selfCheck() -> [String] {
        var source: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsPresentKey: true,
                                     kIOPSCurrentCapacityKey: 33, kIOPSMaxCapacityKey: 40,
                                     kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue]
        var failures: [String] = []
        func check(_ expected: String?) {
            if MacBattery(source)?.line != expected { failures.append("battery: expected \(expected ?? "absent")") }
        }
        check("83 discharging")
        source[kIOPSPowerSourceStateKey] = kIOPSACPowerValue
        check("83 idle")
        source[kIOPSIsChargingKey] = true
        check("83 charging")
        source[kIOPSIsChargingKey] = false
        source[kIOPSCurrentCapacityKey] = 40
        check("100 full")
        source[kIOPSCurrentCapacityKey] = 0
        source[kIOPSPowerSourceStateKey] = kIOPSBatteryPowerValue
        check("0 discharging")
        source[kIOPSMaxCapacityKey] = 0
        check(nil)
        source[kIOPSMaxCapacityKey] = 100
        source[kIOPSTypeKey] = "UPS"
        check(nil)
        return failures
    }
}

/// The guest requests a fresh snapshot every time it opens the port, including after a service restart.
final class BatterySync {
    static let portName = "fx.battery"
    private var ready = false
    private var enabled: Bool
    private var previous: String?
    private let port: ProgressPort
    private var subscription: AnyCancellable?
    private var token: Int32 = -1
    private var fallback: DispatchSourceTimer?

    init(port: ProgressPort, settings: LauncherSettings) {
        self.port = port
        enabled = settings.shareMacBattery
        port.start(name: Self.portName) { [weak self] line in
            guard let self, line == "battery-ready" else { return }
            self.ready = true
            self.previous = nil
            self.update()
        }
        subscription = settings.$shareMacBattery.removeDuplicates().sink { [weak self] value in
            self?.enabled = value
            self?.update()
        }
        if notify_register_dispatch(kIOPSNotifyAnyPowerSource, &token, .main, { [weak self] _ in self?.update() }) != NOTIFY_STATUS_OK {
            token = -1
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.update() }
            timer.resume()
            fallback = timer
        }
    }

    deinit { if token >= 0 { notify_cancel(token) } }

    private func update() {
        guard ready else { return }
        let line = enabled ? (MacBattery.current()?.line ?? "off") : "off"
        if line != previous {
            port.send(line)
            previous = line
        }
    }
}
