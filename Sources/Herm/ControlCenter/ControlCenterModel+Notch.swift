import Combine
import Foundation

extension ControlCenterModel {
    var notchPresentationChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany(
            $projectionRefreshStates.map { $0["kanban.global"]?.isRefreshing ?? false }
                .removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $routineProfileID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $cronJobs.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $cronRuns.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $cronRunsByJob.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ).receive(on: RunLoop.main).eraseToAnyPublisher()
    }
}
