import CoreText
import SwiftUI

/// A Desktop plugin's own sidebar icon: the codicon it declares, drawn with the codicon font
/// that ships in the built plugin host. `nil` when the host is not built or the name is unknown.
enum DesktopPluginIcon {
    /// `codicon name → glyph`, from the `codicons.json` the host build reads out of Desktop's
    /// stylesheet (`.codicon-compass:before { content: "\ebd5" }`), so names follow the bundled codicons.
    static func glyph(_ name: String?, size: CGFloat) -> Text? {
        guard let name, let character = bundled[name], let family else { return nil }
        // A skin's font design (rounded, monospaced) would swap the codicon font for a system
        // face without these glyphs, so the glyph opts out of both.
        return Text(String(character)).font(.custom(family, fixedSize: size)).monospaced(false).fontDesign(nil)
    }

    /// `{"compass": "ebd5"}` as glyphs; entries that are not a hex code point are skipped.
    static func codepoints(json: Data) -> [String: Character] {
        let hex = (try? JSONDecoder().decode([String: String].self, from: json)) ?? [:]
        return hex.compactMapValues { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init).map(Character.init) }
    }

    private static let sdk = Bundle.herm.resourceURL?.appendingPathComponent("DesktopPluginHost/sdk")

    private static let bundled: [String: Character] = {
        guard let url = sdk?.appendingPathComponent("codicons.json"), let data = try? Data(contentsOf: url)
        else { return [:] }
        return codepoints(json: data)
    }()

    /// The bundled font, registered for this process only (SwiftUI cannot draw an unregistered
    /// file). The family name comes from the file; `nil` when it cannot be registered.
    private static let family: String? = {
        guard let url = sdk?.appendingPathComponent("fonts/codicon.ttf"),
            let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first,
            let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
        else { return nil }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        // Already registered (by an earlier load) is fine.
        let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
        return registered || code == CTFontManagerError.alreadyRegistered.rawValue ? name : nil
    }()
}

/// The pill that marks a Hermes Desktop plugin page in menus and its page header.
struct DesktopPluginBadge: View {
    var body: some View {
        Text("Plugin").dockFont(size: 10, weight: .medium)
            .foregroundStyle(Color.dockSecondaryText).dockPill(compact: true)
            .help("A Hermes Desktop plugin page")
    }
}
