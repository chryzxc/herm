import CoreServices
import Foundation

struct WatchedRepository: Hashable {
    let id: String
    let path: String
}

/// Owns FSEvent stream lifetime. It only reports filesystem activity; callers
/// decide whether Git state changed and whether to show a notification.
final class RepositoryWatchService {
    var onEvent: ((String) -> Void)?
    // Watched-repository file storms are delivered and filtered here, off the
    // main thread; consumers hop to the main actor for refresh decisions.
    private let watchQueue = DispatchQueue(label: "io.github.chryzxc.Herm.repository-watch", qos: .utility)
    private var registrations: [String: Registration] = [:]

    func synchronize(_ repositories: Set<WatchedRepository>) {
        let desired = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
        for id in Set(registrations.keys).subtracting(desired.keys) { stop(id) }
        for repository in desired.values where registrations[repository.id] == nil {
            start(repository)
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
                UInt32(kFSEventStreamCreateFlagFileEvents)
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

    fileprivate func receive(_ repositoryID: String) {
        onEvent?(repositoryID)
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
    registration.service?.receive(id)
}
