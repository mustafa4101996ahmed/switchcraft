import AppKit
import Carbon
import IOKit
import SwitchcraftCore

/// Who holds macOS secure keyboard input right now, read from public sources only:
/// Carbon's `IsSecureEventInputEnabled` and the console session in the IORegistry.
enum SecureInputProbe {
    static func holder() -> SecureInputHolder? {
        guard IsSecureEventInputEnabled() else { return nil }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]]
        guard let pid = users?.compactMap({ ($0["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value }).first, pid > 0 else {
            return SecureInputHolder(pid: 0, name: "another app")
        }
        return SecureInputHolder(pid: pid, name: name(of: pid))
    }

    private static func name(of pid: Int32) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "another app" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
