import Foundation

/// Bounded, read-only projection of Hermes' human-facing skin and pet CLI
/// tables. `hermes skin list` and `hermes pets list --installed` publish no
/// JSON contract, so the Dock keeps the same live-CLI-projection boundary it
/// uses for cron run history. Switching skins or pets stays copy-only until a
/// verified mutation contract exists.
enum AppearanceCLIProjection {
    static let maxSkins = 64
    static let maxPets = 16
    static let maxRowLength = 256

    struct Inventory: Equatable, Sendable {
        var skins: [AppearanceSkin] = []
        var installedPets: [AppearancePet] = []
    }

    static func inventory(skinsOutput: String, petsOutput: String) -> Inventory {
        Inventory(skins: skins(skinsOutput), installedPets: installedPets(petsOutput))
    }

    static func skins(_ output: String) -> [AppearanceSkin] {
        var rows: [AppearanceSkin] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard rows.count < maxSkins else { break }
            let raw = String(line)
            guard raw.count <= maxRowLength else { continue }
            let isActive = raw.hasPrefix("*")
            let content = isActive ? String(raw.dropFirst()) : raw
            let columns = content.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard columns.count == 3 else { continue }
            let slug = String(columns[0])
            let source = String(columns[1])
            let description = String(columns[2]).trimmingCharacters(in: .whitespaces)
            guard ["builtin", "hub", "local"].contains(source) else { continue }
            guard safeLabel(slug), safeLabel(description) else { continue }
            rows.append(AppearanceSkin(id: slug, name: description, isActive: isActive, source: source))
        }
        return rows
    }

    static func installedPets(_ output: String) -> [AppearancePet] {
        var rows: [AppearancePet] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard rows.count < maxPets else { break }
            let raw = String(line).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty, raw.count <= maxRowLength else { continue }
            guard !raw.hasPrefix("Installed pets") else { continue }
            guard let separator = raw.range(of: "  ") else { continue }
            let slug = raw[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let name = raw[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            guard safeLabel(String(slug)), safeLabel(String(name)) else { continue }
            rows.append(AppearancePet(id: String(slug), name: String(name), isActive: false))
        }
        return rows
    }

    private static func safeLabel(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    }
}
