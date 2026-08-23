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
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            repositoryWatchFSEventCallback,
            &context,
            [repository.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.75,
            UInt32(kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        registration.stream = stream
        registrations[repository.id] = registration
        FSEventStreamSetDispatchQueue(stream, .main)
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
    let registration = Unmanaged<RepositoryWatchService.Registration>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
    let id = registration.repository.id
    // The stream is explicitly scheduled on the main queue.
    registration.service?.receive(id)
}
