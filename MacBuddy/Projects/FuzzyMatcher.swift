import Foundation

/// Case-insensitive subsequence matching with a small score model: matches at
/// the start of the name or after a separator rank highest, consecutive runs
/// beat scattered hits. Greedy left-to-right is plenty for project names.
nonisolated enum FuzzyMatcher {
    struct Match {
        let score: Int
        /// Character offsets into the candidate, for highlighting.
        let matchedOffsets: [Int]
    }

    private static let separators: Set<Character> = ["-", "_", ".", " ", "/"]

    static func match(_ query: String, in candidate: String) -> Match? {
        let queryChars = Array(query.lowercased())
        guard !queryChars.isEmpty else { return Match(score: 0, matchedOffsets: []) }
        let candidateChars = Array(candidate.lowercased())

        var offsets: [Int] = []
        var score = 0
        var queryIndex = 0
        var previousMatch = -2

        for (index, character) in candidateChars.enumerated() {
            guard queryIndex < queryChars.count, character == queryChars[queryIndex] else { continue }
            var characterScore = 1
            if index == 0 {
                characterScore += 8
            } else if separators.contains(candidateChars[index - 1]) {
                characterScore += 6
            }
            if index == previousMatch + 1 {
                characterScore += 4
            }
            score += characterScore
            offsets.append(index)
            previousMatch = index
            queryIndex += 1
        }

        guard queryIndex == queryChars.count else { return nil }
        return Match(score: score, matchedOffsets: offsets)
    }
}
