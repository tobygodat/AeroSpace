import Foundation

/// One entry of hidutil's UserKeyMapping: HID usages, e.g. 0x700000039 is Caps Lock
struct HidKeyMapping: Hashable, Sendable {
    let src: UInt64
    let dst: UInt64
}

let capsLockUsage: UInt64 = 0x7_0000_0039
let f18Usage: UInt64 = 0x7_0000_006D

/// Remaps Caps Lock to F18 for the Super key tap, keeping every other UserKeyMapping entry as it is. Whatever Caps Lock
/// was mapped to before is saved to `markerUrl` first, so `restore` can put it back after a quit, a settings change, or
/// a crash (at the next launch). Both operations are idempotent
struct CapsLockRemap: Sendable {
    /// Runs /usr/bin/hidutil with these arguments and returns its standard output
    let hidutil: @Sendable (_ arguments: [String]) throws -> String
    let markerUrl: URL

    private struct Marker: Codable {
        /// Where Caps Lock went before the remap. nil: it wasn't remapped
        let previousCapsLockDst: UInt64?
    }

    func apply() -> Result<Void, String> {
        let lists: [[HidKeyMapping]]
        do {
            lists = try readKeyboardMappings()
        } catch {
            return .failure("Couldn't read the key remaps: \(error)")
        }
        let current = lists.first ?? []
        guard lists.allSatisfy({ Set($0) == Set(current) }) else {
            return .failure("Your keyboards have different key remaps (System Settings → Keyboard → Keyboard Shortcuts → Modifier Keys), so Caps Lock was left alone")
        }
        if readMarker() == nil {
            do {
                let marker = Marker(previousCapsLockDst: current.first { $0.src == capsLockUsage }?.dst)
                try FileManager.default.createDirectory(at: markerUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(marker).write(to: markerUrl, options: .atomic)
            } catch {
                return .failure("Couldn't save the current Caps Lock mapping, so Caps Lock was left alone: \(error.localizedDescription)")
            }
        }
        let remapped = current.filter { $0.src != capsLockUsage } + [HidKeyMapping(src: capsLockUsage, dst: f18Usage)]
        if remapped == current { return .success(()) }
        do {
            try setKeyboardMappings(remapped)
            return .success(())
        } catch {
            try? FileManager.default.removeItem(at: markerUrl)
            return .failure("hidutil couldn't remap Caps Lock: \(error)")
        }
    }

    /// Puts back what Caps Lock was mapped to before `apply`. Does nothing without a saved marker, or when something else
    /// changed the Caps Lock mapping since
    func restore() -> Result<Void, String> {
        guard let marker = readMarker() else { return .success(()) }
        do {
            let lists = try readKeyboardMappings()
            let ours = HidKeyMapping(src: capsLockUsage, dst: f18Usage)
            let current = lists.first { $0.contains(ours) } ?? lists.first ?? []
            if current.contains(ours) {
                let restored = current.filter { $0.src != capsLockUsage } + (marker.previousCapsLockDst.map { [HidKeyMapping(src: capsLockUsage, dst: $0)] } ?? [])
                if restored != current { try setKeyboardMappings(restored) }
            }
            try? FileManager.default.removeItem(at: markerUrl)
            return .success(())
        } catch {
            return .failure("Couldn't restore Caps Lock: \(error). Run hidutil property --set '{\"UserKeyMapping\":[]}' or restart the Mac")
        }
    }

    private func readMarker() -> Marker? {
        (try? Data(contentsOf: markerUrl)).flatMap { try? JSONDecoder().decode(Marker.self, from: $0) }
    }

    private func readKeyboardMappings() throws -> [[HidKeyMapping]] {
        parseUserKeyMappings(try hidutil(["property", "--matching", "keyboard", "--get", "UserKeyMapping"]))
    }

    private func setKeyboardMappings(_ mappings: [HidKeyMapping]) throws {
        _ = try hidutil(["property", "--matching", "keyboard", "--set", userKeyMappingJson(mappings)])
    }
}

/// The UserKeyMapping of each service in the output of `hidutil property --get UserKeyMapping`. Recent macOS prints a
/// table with a row per service, older versions print the value alone
func parseUserKeyMappings(_ output: String) -> [[HidKeyMapping]] {
    let rowStart = /^\s*[0-9A-Fa-f]+\s+UserKeyMapping\s+(.*)$/
    var values: [String] = []
    var sawTable = false
    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
        if let match = line.wholeMatch(of: rowStart) {
            sawTable = true
            values.append(String(match.1))
        } else if sawTable, !values.isEmpty {
            values[values.count - 1] += "\n" + line
        }
    }
    if !sawTable { values = [output] }
    return values.map { value in
        value.split(separator: "{").dropFirst().compactMap { block in
            let entry = block.prefix { $0 != "}" }
            guard let src = entry.firstMatch(of: /HIDKeyboardModifierMappingSrc\s*=\s*(\w+)/).flatMap({ parseHidUsage($0.1) }),
                  let dst = entry.firstMatch(of: /HIDKeyboardModifierMappingDst\s*=\s*(\w+)/).flatMap({ parseHidUsage($0.1) })
            else { return nil }
            return HidKeyMapping(src: src, dst: dst)
        }
    }
}

private func parseHidUsage(_ raw: Substring) -> UInt64? {
    raw.lowercased().hasPrefix("0x") ? UInt64(raw.dropFirst(2), radix: 16) : UInt64(raw)
}

func userKeyMappingJson(_ mappings: [HidKeyMapping]) -> String {
    let entries = mappings.map { "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}" }
    return "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
}

struct HidutilError: Error, CustomStringConvertible {
    let description: String
}

func runHidutil(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/hidutil")
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errors = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw HidutilError(description: "hidutil exited with \(process.terminationStatus): \(String(decoding: errors, as: UTF8.self))")
    }
    return String(decoding: output, as: UTF8.self)
}
