import Foundation

extension Bundle {
    /// Herm's SwiftPM resources. Packaged apps ship them in Contents/Resources, which the
    /// generated `Bundle.module` never searches: it traps when the build machine's path is gone.
    static let herm: Bundle =
        Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("Herm_Herm.bundle"))
        } ?? Bundle.module
}
