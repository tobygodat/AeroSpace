import Foundation

/// One entry of hidutil's UserKeyMapping: HID usages, e.g. 0x700000039 is Caps Lock
struct HidKeyMapping: Hashable, Sendable {
    let src: UInt64
    let dst: UInt64
}

let capsLockUsage: UInt64 = 0x7_0000_0039
let f18Usage: UInt64 = 0x7_0000_006D
let capsLockToF18 = HidKeyMapping(src: capsLockUsage, dst: f18Usage)

/// A keyboard service: the hidutil `--matching` that selects only it, and its UserKeyMapping
struct HidKeyboard: Equatable, Sendable {
    let matching: String
    let mappings: [HidKeyMapping]
}

/// Remaps Caps Lock to F18 for the Super key tap, one keyboard at a time, keeping each keyboard's other UserKeyMapping
/// entries (System Settings → Modifier Keys is per keyboard). Where Caps Lock went on each keyboard is saved to
/// `markerUrl` first, so `restore` can put it back after a quit, a settings change, or a crash (at the next launch).
/// Both operations are idempotent
struct CapsLockRemap: Sendable {
    /// Runs /usr/bin/hidutil with these arguments and returns its standard output
    let hidutil: @Sendable (_ arguments: [String]) throws -> String
    let markerUrl: URL

    private struct Marker: Codable {
        /// Where Caps Lock went before the remap, by keyboard `matching`. A keyboard that isn't here had it unmapped
        var previousCapsLockDst: [String: UInt64]
    }

    /// Maps Caps Lock to F18 on every keyboard that doesn't have that yet, e.g. one plugged in since the last call
    func apply() -> Result<Void, String> {
        let keyboards: [HidKeyboard]
        do {
            keyboards = try readKeyboards()
        } catch {
            return .failure("Couldn't read the key remaps: \(error)")
        }
        let missing = keyboards.filter { !$0.mappings.contains(capsLockToF18) }
        if missing.isEmpty { return .success(()) }
        var marker = readMarker() ?? Marker(previousCapsLockDst: [:])
        for keyboard in missing {
            marker.previousCapsLockDst[keyboard.matching] = keyboard.mappings.first { $0.src == capsLockUsage }?.dst
        }
        do {
            try FileManager.default.createDirectory(at: markerUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(marker).write(to: markerUrl, options: .atomic)
        } catch {
            return .failure("Couldn't save the current Caps Lock mapping, so Caps Lock was left alone: \(error.localizedDescription)")
        }
        do {
            for keyboard in missing {
                try setMappings(keyboard.matching, keyboard.mappings.filter { $0.src != capsLockUsage } + [capsLockToF18])
            }
            return .success(())
        } catch {
            return .failure("hidutil couldn't remap Caps Lock: \(error)")
        }
    }

    /// Puts back what Caps Lock was mapped to before `apply`, on each keyboard where it's still F18. Does nothing without
    /// a saved marker: Caps Lock → F18 is then somebody else's
    func restore() -> Result<Void, String> {
        guard let marker = readMarker() else { return .success(()) }
        do {
            for keyboard in try readKeyboards() where keyboard.mappings.contains(capsLockToF18) {
                let previous = marker.previousCapsLockDst[keyboard.matching].map { [HidKeyMapping(src: capsLockUsage, dst: $0)] } ?? []
                try setMappings(keyboard.matching, keyboard.mappings.filter { $0 != capsLockToF18 } + previous)
            }
            try? FileManager.default.removeItem(at: markerUrl)
            return .success(())
        } catch {
            return .failure("Couldn't restore Caps Lock: \(error). Restarting the Mac fixes it, and so does hidutil property --set '{\"UserKeyMapping\":[]}' (it also clears other key remaps until you log in again)")
        }
    }

    private func readMarker() -> Marker? {
        (try? Data(contentsOf: markerUrl)).flatMap { try? JSONDecoder().decode(Marker.self, from: $0) }
    }

    private func readKeyboards() throws -> [HidKeyboard] {
        let values = parseUserKeyMappings(try hidutil(["property", "--matching", "keyboard", "--get", "UserKeyMapping"]))
        if values.count == 1, values[0].registryID == nil { // Older macOS: one value for all keyboards
            return [HidKeyboard(matching: "keyboard", mappings: values[0].mappings)]
        }
        let mappingsById = Dictionary(values.compactMap { value in value.registryID.map { ($0, value.mappings) } }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        return parseKeyboardServices(try hidutil(["list", "--matching", "keyboard"])).compactMap { service in
            guard seen.insert(service.matching).inserted else { return nil }
            return HidKeyboard(matching: service.matching, mappings: mappingsById[service.registryID] ?? [])
        }
    }

    private func setMappings(_ matching: String, _ mappings: [HidKeyMapping]) throws {
        _ = try hidutil(["property", "--matching", matching, "--set", userKeyMappingJson(mappings)])
    }
}

/// The UserKeyMapping of each service in the output of `hidutil property --get UserKeyMapping`. Recent macOS prints a
/// table with a row per service, older versions print the value alone (no registry ID)
func parseUserKeyMappings(_ output: String) -> [(registryID: UInt64?, mappings: [HidKeyMapping])] {
    let rowStart = /^\s*([0-9A-Fa-f]+)\s+UserKeyMapping\s+(.*)$/
    var values: [(registryID: UInt64?, text: String)] = []
    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
        if let match = line.wholeMatch(of: rowStart) {
            values.append((UInt64(match.1, radix: 16), String(match.2)))
        } else if !values.isEmpty {
            values[values.count - 1].text += "\n" + line
        }
    }
    if values.isEmpty { values = [(nil, output)] }
    return values.map { value in
        let mappings: [HidKeyMapping] = value.text.split(separator: "{").dropFirst().compactMap { block in
            let entry = block.prefix { $0 != "}" }
            guard let src = entry.firstMatch(of: /HIDKeyboardModifierMappingSrc\s*=\s*(\w+)/).flatMap({ parseHidNumber($0.1) }),
                  let dst = entry.firstMatch(of: /HIDKeyboardModifierMappingDst\s*=\s*(\w+)/).flatMap({ parseHidNumber($0.1) })
            else { return nil }
            return HidKeyMapping(src: src, dst: dst)
        }
        return (value.registryID, mappings)
    }
}

/// The keyboard services in the output of `hidutil list --matching keyboard`, each with a `--matching` that selects it.
/// Rows whose IDs aren't numbers are left out, so those keyboards are never touched
func parseKeyboardServices(_ output: String) -> [(registryID: UInt64, matching: String)] {
    let row = /^\s*(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/
    var result: [(registryID: UInt64, matching: String)] = []
    for line in output.split(separator: "\n") {
        if line.hasPrefix("Devices:") { break }
        guard let match = line.prefixMatch(of: row),
              let vendor = parseHidNumber(match.1), let product = parseHidNumber(match.2), let location = parseHidNumber(match.3),
              let usagePage = parseHidNumber(match.4), let usage = parseHidNumber(match.5), let registryID = parseHidNumber(match.6)
        else { continue }
        let matching = #"{"VendorID":\#(vendor),"ProductID":\#(product),"LocationID":\#(location),"PrimaryUsagePage":\#(usagePage),"PrimaryUsage":\#(usage)}"#
        result.append((registryID, matching))
    }
    return result
}

private func parseHidNumber(_ raw: Substring) -> UInt64? {
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
