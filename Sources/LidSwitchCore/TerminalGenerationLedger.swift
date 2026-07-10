import Foundation

public enum TerminalGenerationLedger {
    public static let maximumEntries = 64
    public static let maximumBytes = maximumEntries * 40

    public static func parse(_ raw: String) -> [UUID]? {
        guard raw.utf8.count <= maximumBytes else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let payloadLines = lines.last == "" ? lines.dropLast() : lines[...]
        guard payloadLines.count <= maximumEntries else { return nil }
        var seen = Set<UUID>()
        var entries: [UUID] = []
        for line in payloadLines {
            guard !line.isEmpty,
                  let sessionID = UUID(uuidString: String(line)),
                  seen.insert(sessionID).inserted
            else { return nil }
            entries.append(sessionID)
        }
        return entries
    }
}
