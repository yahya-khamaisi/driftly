import AppKit
import CoreAudio
import CoreLocation
import CoreWLAN
import IOBluetooth
import IOKit
import IOKit.ps

/// What turns Awake or Drift on automatically. The feature uses its own settings, and turns
/// off again when no trigger for it matches any more.
enum TriggerKind: String, Codable, CaseIterable, Identifiable {
    case schedule, app, power, display, device, network, audio, drive, download, cpu
    var id: Self { self }
}

enum PowerCondition: String, Codable, CaseIterable, Identifiable {
    case charger, battery, batteryAbove
    var id: Self { self }
}

enum DisplayCondition: String, Codable, CaseIterable, Identifiable {
    case external, mirroring
    var id: Self { self }
}

enum NetworkCondition: String, Codable, CaseIterable, Identifiable {
    case wifi, vpn
    var id: Self { self }
}

/// One flat record per trigger; each kind reads only its own fields.
struct Trigger: Codable, Identifiable, Equatable {
    var id = UUID()
    var enabled = true
    var kind: TriggerKind
    var target: FeatureTarget = .awake

    var from = ClockTime(hour: 9, minute: 0)        // schedule
    var to = ClockTime(hour: 17, minute: 30)
    var days: Set<Int> = [2, 3, 4, 5, 6]
    var bundleID = ""                               // app
    var frontOnly = false
    var power: PowerCondition = .charger            // power
    var batteryAbove = 50
    var display: DisplayCondition = .external       // display
    var network: NetworkCondition = .wifi           // network
    var name = ""                                   // device, Wi-Fi network, audio output, drive
    var cpuAbove = 50                               // cpu, percent

    init(kind: TriggerKind) { self.kind = kind }

    /// True when the trigger has everything it needs to be added.
    var isComplete: Bool {
        switch kind {
        case .app: !bundleID.isEmpty
        case .device, .audio, .drive: !name.isEmpty
        case .network: network == .vpn || !name.isEmpty
        case .schedule: !days.isEmpty
        default: true
        }
    }
}

/// Reads the system state each trigger kind looks at. Cheap checks run every evaluation;
/// the rest are only queried when an enabled trigger of that kind exists.
@MainActor
final class TriggerProbes {
    private var cpu = CPULoad()
    private var lastDownloadSeen = Date.distantPast

    /// Ids of enabled, complete triggers that match right now.
    func matching(_ triggers: [Trigger], natural: Bool, now: Date) -> Set<UUID> {
        let active = triggers.filter { $0.enabled && $0.isComplete }
        let kinds = Set(active.map(\.kind))
        let devices = kinds.contains(.device) ? Self.connectedDevices() : []
        let drives = kinds.contains(.drive) ? Self.mountedDrives() : []
        let output = kinds.contains(.audio) ? Self.defaultOutputName() : nil
        let wifi = active.contains { $0.kind == .network && $0.network == .wifi } ? Self.wifiName() : nil
        if kinds.contains(.cpu) { cpu.sample() }
        if kinds.contains(.download), Self.downloadInProgress() { lastDownloadSeen = now }

        return Set(active.filter { t in
            switch t.kind {
            case .schedule:
                Schedule(from: t.from, to: t.to, days: t.days, natural: natural).isInWindow(now)
            case .app:
                NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == t.bundleID }
                    && (!t.frontOnly || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == t.bundleID)
            case .power:
                switch t.power {
                case .charger: Self.onACPower()
                case .battery: !Self.onACPower()
                case .batteryAbove: (Self.batteryLevel() ?? 100) > t.batteryAbove
                }
            case .display:
                t.display == .external ? Self.externalDisplayConnected() : Self.mirroring()
            case .device: devices.contains(t.name)
            case .network: t.network == .vpn ? Self.vpnConnected() : wifi == t.name
            case .audio: output == t.name
            case .drive: drives.contains(t.name)
            // Browsers rename the file between chunks; a short grace keeps the session from flapping.
            case .download: now.timeIntervalSince(lastDownloadSeen) < 30
            case .cpu: cpu.usage * 100 >= Double(t.cpuAbove)
            }
        }.map(\.id))
    }

    // MARK: Power

    static func onACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return type != kIOPSBatteryPowerValue
    }

    /// Battery percentage, or nil on Macs without a battery.
    static func batteryLevel() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            if let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                return d[kIOPSCurrentCapacityKey] as? Int
            }
        }
        return nil
    }

    // MARK: Displays

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func externalDisplayConnected() -> Bool {
        onlineDisplays().contains { CGDisplayIsBuiltin($0) == 0 }
    }

    static func mirroring() -> Bool {
        onlineDisplays().contains { CGDisplayIsInMirrorSet($0) != 0 }
    }

    // MARK: Devices

    /// Names of connected USB devices and connected Bluetooth devices.
    static func connectedDevices() -> [String] {
        var names: [String] = []
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS {
            while case let service = IOIteratorNext(iterator), service != 0 {
                if let name = IORegistryEntryCreateCFProperty(service, "USB Product Name" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                    names.append(name)
                }
                IOObjectRelease(service)
            }
            IOObjectRelease(iterator)
        }
        let bluetooth = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        names += bluetooth.filter { $0.isConnected() }.compactMap(\.name)
        return Array(Set(names)).sorted()
    }

    // MARK: Network

    static func wifiName() -> String? { CWWiFiClient.shared().interface()?.ssid() }

    /// A tunnel interface (utun, ppp, ipsec) that has an IPv4 address. macOS's own utun
    /// interfaces only carry link-local IPv6, so they don't count.
    static func vpnConnected() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = ptr.pointee
            let name = String(cString: a.ifa_name)
            guard ["utun", "ppp", "ipsec"].contains(where: name.hasPrefix),
                  a.ifa_flags & UInt32(IFF_UP) != 0,
                  a.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }
            return true
        }
        return false
    }

    // MARK: Audio

    private static func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                         _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        } == noErr
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        guard audioProperty(id, kAudioObjectPropertyName, &name) else { return nil }
        return name?.takeRetainedValue() as String?
    }

    static func defaultOutputName() -> String? {
        var id = AudioDeviceID(0)
        guard audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &id)
        else { return nil }
        return deviceName(id)
    }

    /// Every device that can play sound.
    static func outputDevices() -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr && bytes > 0
        }
        .compactMap(deviceName)
    }

    // MARK: Files

    static func mountedDrives() -> [String] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return v?.volumeIsRootFileSystem == true ? nil : v?.volumeName
        }
    }

    private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload"]

    /// A browser or download manager is writing into the Downloads folder.
    static func downloadInProgress() -> Bool {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.resolvingSymlinksInPath().path)
        else { return false }
        return names.contains { partialExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }
}

/// Whole-machine CPU use between the last two samples, 0…1.
struct CPULoad {
    private var last: (busy: UInt64, total: UInt64)?
    private(set) var usage = 0.0

    mutating func sample() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let t = info.cpu_ticks
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)   // user, system, nice
        let total = busy + UInt64(t.2)                       // + idle
        if let last, total > last.total {
            usage = Double(busy - last.busy) / Double(total - last.total)
        }
        last = (busy, total)
    }
}

/// Wi-Fi network names need Location access on recent macOS.
@MainActor
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAccess()
    private let manager = CLLocationManager()
    private var completion: (() -> Void)?

    var granted: Bool {
        [.authorizedAlways, .authorized].contains(manager.authorizationStatus)
    }

    func request(then done: @escaping () -> Void) {
        if granted { done(); return }
        completion = done
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.granted, let done = self.completion else { return }
            self.completion = nil
            done()
        }
    }
}
