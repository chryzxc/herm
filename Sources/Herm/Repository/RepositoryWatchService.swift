import CoreServices
import Foundation

private struct WatchedRepository {
    let id: String
    let path: String
}

/// Owns FSEvent stream lifetime. It only reports filesystem activity; callers
/// decide whether Git state changed and whether to show a notification.
final class RepositoryWatchService {
    enum Change: Equatable, Sendable {
        case files(Set<String>)
        case rescan

        func merging(_ other: Change) -> Change {
            guard case .files(let lhs) = self, case .files(let rhs) = other else { return .rescan }
            let paths = lhs.union(rhs)
            return paths.count <= 128 ? .files(paths) : .rescan
        }
    }

    var onEvent: ((String, Change) -> Void)?
    // Watched-repository file storms are delivered and filtered here, off the
    // main thread; consumers hop to the main actor for refresh decisions.
    private let watchQueue = DispatchQueue(label: "io.github.chryzxc.Herm.repository-watch", qos: .utility)
    private var registrations: [String: Registration] = [:]

    func synchronize(_ paths: [String: String]) {
        for (id, registration) in registrations where paths[id] != registration.repository.path { stop(id) }
        for (id, path) in paths where registrations[id] == nil {
            start(WatchedRepository(id: id, path: path))
        }
    }

    deinit {
        for id in Array(registrations.keys) { stop(id) }
    }

    private func start(_ repository: WatchedRepository) {
        let registration = Registration(repository: repository, service: self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(registration).toOpaque(),
            retain: nil,
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<Registration>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                repositoryWatchFSEventCallback,
                &context,
                [repository.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.75,
                UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
            )
        else { return }
        registration.stream = stream
        registrations[repository.id] = registration
        FSEventStreamSetDispatchQueue(stream, watchQueue)
        FSEventStreamStart(stream)
    }

    private func stop(_ id: String) {
        guard let registration = registrations.removeValue(forKey: id), let stream = registration.stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    fileprivate func receive(_ repositoryID: String, change: Change) {
        onEvent?(repositoryID, change)
    }

    static func change(root: String, paths: [String], flags: [FSEventStreamEventFlags]) -> Change {
        guard !paths.isEmpty, paths.count == flags.count, paths.count <= 128 else { return .rescan }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var files: Set<String> = []
        for (path, flag) in zip(paths, flags) {
            // A directory event may conceal tracked children, and a lost event may conceal anything.
            let uncertain =
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved
            guard flag & UInt32(uncertain) == 0, flag & UInt32(kFSEventStreamEventFlagItemIsFile) != 0,
                path.hasPrefix(prefix)
            else { return .rescan }
            let relative = String(path.dropFirst(prefix.count))
            // Git metadata (including linked-worktree markers) is never an ignore candidate.
            guard !relative.isEmpty, relative != ".git", !relative.hasPrefix(".git/") else { return .rescan }
            files.insert(relative)
        }
        return .files(files)
    }

    fileprivate final class Registration {
        let repository: WatchedRepository
        weak var service: RepositoryWatchService?
        var stream: FSEventStreamRef?

        init(repository: WatchedRepository, service: RepositoryWatchService) {
            self.repository = repository
            self.service = service
        }
    }
}

private func repositoryWatchFSEventCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo else { return }
    let registration = Unmanaged<RepositoryWatchService.Registration>.fromOpaque(clientCallBackInfo)
        .takeUnretainedValue()
    let id = registration.repository.id
    // Runs on the watch queue, not the main queue; onEvent consumers hop to
    // the main actor themselves (see DeveloperWorkflowModel's watcher setup).
    guard numEvents > 0, numEvents <= 128 else {
        registration.service?.receive(id, change: .rescan)
        return
    }
    let cPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    let paths = (0..<numEvents).compactMap { String(validatingCString: cPaths[$0]) }
    let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
    registration.service?.receive(
        id, change: RepositoryWatchService.change(root: registration.repository.path, paths: paths, flags: flags))
}
