import Foundation

struct BuildIdentity: Decodable {
    let commit: String
    let hasLocalChanges: Bool
    let builtAt: Date

    static let current: BuildIdentity? = {
        guard let url = Bundle.main.url(forResource: "BuildIdentity", withExtension: "plist"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? PropertyListDecoder().decode(BuildIdentity.self, from: data)
    }()

    var shortCommit: String { String(commit.prefix(12)) }

    var shareText: String {
        """
        Berms Beta
        Commit: \(commit)
        Source: \(hasLocalChanges ? "Local changes" : "Committed source")
        Built: \(builtAt.ISO8601Format())
        """
    }
}
