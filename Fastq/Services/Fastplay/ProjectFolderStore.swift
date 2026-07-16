import Foundation
import Combine

/// Maps Fastplay project IDs → local folder paths on this Mac.
@MainActor
final class ProjectFolderStore: ObservableObject {
    static let shared = ProjectFolderStore()

    @Published private(set) var pathsByProjectID: [String: String] = [:]

    private let defaultsKey = "fastq.fastplay.projectFolders.v1"

    private init() {
        load()
    }

    func path(for projectID: String) -> String? {
        pathsByProjectID[projectID]
    }

    func hasFolder(for projectID: String) -> Bool {
        guard let path = pathsByProjectID[projectID], !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func displayName(for projectID: String) -> String? {
        guard let path = path(for: projectID) else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    func setPath(_ path: String, for projectID: String) {
        pathsByProjectID[projectID] = path
        save()
    }

    func clear(for projectID: String) {
        pathsByProjectID.removeValue(forKey: projectID)
        save()
    }

    /// Linked folders for a set of projects (order preserved).
    func paths(forProjectIDs ids: [String]) -> [String] {
        ids.compactMap { path(for: $0) }
    }

    private func load() {
        pathsByProjectID = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    private func save() {
        UserDefaults.standard.set(pathsByProjectID, forKey: defaultsKey)
        objectWillChange.send()
    }
}
