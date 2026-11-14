import Combine

@MainActor
final class DockActivityPresentation: ObservableObject {
    @Published var revision = 0
}
