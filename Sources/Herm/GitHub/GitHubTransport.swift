import Foundation
import SwiftUI

protocol GitHubIssueTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: GitHubIssueTransport {}
