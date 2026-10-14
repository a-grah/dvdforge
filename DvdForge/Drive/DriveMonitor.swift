import DiskArbitration
import Foundation
import IOKit
import Observation

/// A DVD currently in an optical drive.
struct OpticalDisc: Sendable, Hashable, Identifiable {
    var bsdName: String        // "disk4"
    var volumeName: String?    // set once macOS mounts it
    var driveModel: String?

    var id: String { bsdName }
    /// Raw device node; libdvdread uses it for CSS authentication via libdvdcss.
    var devicePath: String { "/dev/r\(bsdName)" }
}

/// Watches DVD drives being connected (IOKit) and DVDs appearing in and
/// disappearing from them (DiskArbitration), all on the main queue.
@MainActor @Observable
final class DriveMonitor {
    private(set) var discs: [OpticalDisc] = []
    /// Connected DVD drives ("TSSTcorp CDDVDW SN-208FB"), with or without a disc.
    private(set) var drives: [String] = []
    private(set) var lastEjectError: String?

    @ObservationIgnored private var session: DASession?
    @ObservationIgnored private var notifyPort: IONotificationPortRef?

    func start() {
        startDriveNotifications()
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        DASessionSetDispatchQueue(session, .main)

        let match = [
            kDADiskDescriptionMediaKindKey as String: "IODVDMedia",
            kDADiskDescriptionMediaWholeKey as String: true,
        ] as CFDictionary
        let context = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, match, { disk, context in
            let monitor = Unmanaged<DriveMonitor>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.update(disk) }
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, match, nil, { disk, _, context in
            let monitor = Unmanaged<DriveMonitor>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.update(disk) }
        }, context)
        DARegisterDiskDisappearedCallback(session, match, { disk, context in
            let monitor = Unmanaged<DriveMonitor>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.remove(disk) }
        }, context)
    }

    /// Unmounts the whole disc, then ejects the tray.
    func eject(_ disc: OpticalDisc) {
        guard let session, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, disc.bsdName)
        else { return }
        lastEjectError = nil
        let context = Unmanaged.passUnretained(self).toOpaque()
        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), { disk, dissenter, context in
            let monitor = Unmanaged<DriveMonitor>.fromOpaque(context!).takeUnretainedValue()
            if let dissenter {
                MainActor.assumeIsolated { monitor.reportEjectFailure(dissenter) }
                return
            }
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, context in
                guard let dissenter else { return }
                let monitor = Unmanaged<DriveMonitor>.fromOpaque(context!).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.reportEjectFailure(dissenter) }
            }, context)
        }, context)
    }

    private func startDriveNotifications() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            // Drain the iterator to re-arm the notification, then recount.
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            let monitor = Unmanaged<DriveMonitor>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refreshDrives() }
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, type, IOServiceMatching("IODVDServices"), callback, context,
                                             &iterator)
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
        }
        refreshDrives()
    }

    private func refreshDrives() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODVDServices"), &iterator)
            == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var names: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            let traits = IORegistryEntryCreateCFProperty(service, "Device Characteristics" as CFString,
                                                         kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            let vendor = (traits?["Vendor Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let product = (traits?["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let name = [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
            names.append(name.isEmpty ? "DVD drive" : name)
            IOObjectRelease(service)
        }
        if names != drives { drives = names }
    }

    private func update(_ disk: DADisk) {
        guard let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        let desc = DADiskCopyDescription(disk) as? [String: Any] ?? [:]
        let disc = OpticalDisc(
            bsdName: bsd,
            volumeName: desc[kDADiskDescriptionVolumeNameKey as String] as? String,
            driveModel: (desc[kDADiskDescriptionDeviceModelKey as String] as? String)?
                .trimmingCharacters(in: .whitespaces))
        if let i = discs.firstIndex(where: { $0.bsdName == bsd }) {
            if discs[i] != disc { discs[i] = disc }
        } else {
            discs.append(disc)
        }
    }

    private func remove(_ disk: DADisk) {
        guard let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        discs.removeAll { $0.bsdName == bsd }
    }

    private func reportEjectFailure(_ dissenter: DADissenter) {
        let status = DADissenterGetStatusString(dissenter) as String?
        lastEjectError = status ?? "The disc could not be ejected (status \(DADissenterGetStatus(dissenter)))."
    }
}
