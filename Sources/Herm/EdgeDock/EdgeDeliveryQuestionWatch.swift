import Darwin
import Foundation

/// Watches question-file arrivals and replacements, including creation of the inbox itself.
@MainActor
final class EdgeDeliveryQuestionWatch {
    private let directory: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var watchedDirectory: URL?
    private var generation = 0

    init(directory: URL, onChange: @escaping () -> Void) {
        self.directory = directory.standardizedFileURL
        self.onChange = onChange
    }

    deinit { source?.cancel() }

    func restart() {
        stop()
        watchNearestDirectory()
    }

    private func stop() {
        generation += 1
        source?.cancel()
        source = nil
        watchedDirectory = nil
    }

    private func watchNearestDirectory() {
        var candidate = directory
        while true {
            if candidate == watchedDirectory { return }
            let descriptor = open(candidate.path, O_EVTONLY | O_CLOEXEC | O_DIRECTORY)
            if descriptor >= 0 {
                stop()
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke], queue: .main)
                let generation = self.generation
                source.setEventHandler { [weak self] in
                    MainActor.assumeIsolated { self?.directoryChanged(generation: generation) }
                }
                source.setRegistrationHandler { [weak self] in
                    MainActor.assumeIsolated { self?.directoryChanged(generation: generation) }
                }
                source.setCancelHandler { close(descriptor) }
                self.source = source
                watchedDirectory = candidate
                source.activate()
                return
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path, !parent.path.isEmpty else { return }
            candidate = parent
        }
    }

    private func directoryChanged(generation: Int) {
        guard generation == self.generation, let source else { return }
        let previouslyWatchedInbox = watchedDirectory == directory
        if !source.data.intersection([.delete, .rename, .revoke]).isEmpty { stop() }
        watchNearestDirectory()
        if previouslyWatchedInbox || watchedDirectory == directory { onChange() }
    }
}
