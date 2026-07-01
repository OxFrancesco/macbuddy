import SwiftUI

/// Spotlight-style fuzzy search over existing project folders. Arrow keys move
/// the selection, return opens the project, escape dismisses.
struct ProjectSearchView: View {
    let projects: [ProjectEntry]
    let terminalName: String
    let onSelect: (ProjectEntry) -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var hasAppeared = false
    /// Cached per query change: hover and arrow-key selection updates
    /// invalidate the body, and re-running the fuzzy match over every project
    /// on each of those is wasted work.
    @State private var results: [SearchResult]
    @FocusState private var isSearchFocused: Bool

    private struct SearchResult: Identifiable {
        let entry: ProjectEntry
        let matchedOffsets: [Int]
        var id: URL { entry.url }
    }

    init(
        projects: [ProjectEntry],
        terminalName: String,
        onSelect: @escaping (ProjectEntry) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.projects = projects
        self.terminalName = terminalName
        self.onSelect = onSelect
        self.onCancel = onCancel
        _results = State(initialValue: Self.results(matching: "", in: projects))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            divider
            resultsList(results)
            divider
            footer(results)
        }
        .frame(width: 480)
        .panelGlass()
        .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.94)
        .opacity(hasAppeared ? 1 : 0)
        .onExitCommand(perform: onCancel)
        .defaultFocus($isSearchFocused, true)
        .onChange(of: query) {
            selectedIndex = 0
            results = Self.results(matching: query, in: projects)
        }
        .task { animateIn() }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(height: 1)
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Text("❯")
                .font(Theme.mono(20, weight: .bold))
                .foregroundStyle(Theme.amber)
            TextField("search projects", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.mono(18))
                .foregroundStyle(Theme.textPrimary)
                .focused($isSearchFocused)
                .onSubmit { openSelection() }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func resultsList(_ results: [SearchResult]) -> some View {
        if results.isEmpty {
            Text("no matching projects")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 288)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            row(result, isSelected: index == clampedIndex(in: results))
                                .id(result.id)
                                .onTapGesture { onSelect(result.entry) }
                                .onHover { hovering in
                                    if hovering { selectedIndex = index }
                                }
                        }
                    }
                    .padding(8)
                }
                .frame(height: 288)
                .onChange(of: selectedIndex) {
                    guard results.indices.contains(selectedIndex) else { return }
                    proxy.scrollTo(results[selectedIndex].id)
                }
            }
        }
    }

    private func row(_ result: SearchResult, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Text("▸")
                .font(Theme.mono(12, weight: .bold))
                .foregroundStyle(isSelected ? Theme.amber : Theme.textTertiary)
            Text(highlightedName(result))
                .font(Theme.mono(13))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 16)
            if let modifiedAt = result.entry.modifiedAt {
                Text(modifiedAt, format: .relative(presentation: .named))
                    .font(Theme.mono(10))
                    .foregroundStyle(isSelected ? Theme.textSecondary : Theme.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            isSelected ? Theme.amber.opacity(0.12) : .clear,
            in: .rect(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Theme.amber.opacity(0.35) : .clear)
        )
        .contentShape(.rect)
    }

    private func footer(_ results: [SearchResult]) -> some View {
        HStack(spacing: 14) {
            Text("\(results.count)/\(projects.count)")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            footerHint(keys: ["↑", "↓"], label: "navigate")
            footerHint(keys: ["↩"], label: "open in \(terminalName)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func footerHint(keys: [String], label: String) -> some View {
        HStack(spacing: 5) {
            KeycapRow(labels: keys)
            Text(label)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private static func results(matching query: String, in projects: [ProjectEntry]) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return projects.map { SearchResult(entry: $0, matchedOffsets: []) }
        }
        return projects
            .compactMap { entry in
                FuzzyMatcher.match(trimmed, in: entry.name).map { (entry: entry, match: $0) }
            }
            .sorted { lhs, rhs in
                if lhs.match.score != rhs.match.score {
                    return lhs.match.score > rhs.match.score
                }
                return lhs.entry.name.localizedStandardCompare(rhs.entry.name) == .orderedAscending
            }
            .map { SearchResult(entry: $0.entry, matchedOffsets: $0.match.matchedOffsets) }
    }

    private func highlightedName(_ result: SearchResult) -> AttributedString {
        var attributed = AttributedString(result.entry.name)
        for offset in result.matchedOffsets {
            let start = attributed.index(attributed.startIndex, offsetByCharacters: offset)
            let end = attributed.index(start, offsetByCharacters: 1)
            attributed[start..<end].font = Theme.mono(13, weight: .bold)
            attributed[start..<end].foregroundColor = Theme.amber
        }
        return attributed
    }

    private func clampedIndex(in results: [SearchResult]) -> Int {
        min(selectedIndex, results.count - 1)
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(clampedIndex(in: results) + delta, results.count - 1))
    }

    private func openSelection() {
        guard !results.isEmpty else { return }
        onSelect(results[clampedIndex(in: results)].entry)
    }

    private func animateIn() {
        isSearchFocused = true
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3)) {
            hasAppeared = true
        }
    }
}

#Preview {
    ProjectSearchView(
        projects: [
            ProjectEntry(url: URL(filePath: "/tmp/macbuddy"), modifiedAt: .now),
            ProjectEntry(url: URL(filePath: "/tmp/side-project"), modifiedAt: .now.addingTimeInterval(-86400)),
            ProjectEntry(url: URL(filePath: "/tmp/project-1"), modifiedAt: nil),
        ],
        terminalName: "Ghostty",
        onSelect: { _ in },
        onCancel: {}
    )
    .padding(40)
    .background(ThemeBackground())
    .preferredColorScheme(.dark)
}
