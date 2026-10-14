import RecallCore
import SwiftUI

struct SearchView: View {
    var projectID: Int64? = nil

    @EnvironmentObject private var state: AppState
    @State private var query = ""
    @State private var exact = false
    @State private var results: SearchResults?
    @State private var searching = false
    @State private var error: String?
    @State private var answer: GroundedAnswer?
    @State private var answering = false
    @State private var selectedCaptureID: Int64?
    @State private var searchTask: Task<Void, Never>?
    @State private var askTask: Task<Void, Never>?
    @State private var recent: [String] = RecentSearches.load()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
        }
        .navigationTitle(projectID == nil ? "Search" : "Search Project")
        .inspector(isPresented: Binding(get: { selectedCaptureID != nil }, set: { if !$0 { selectedCaptureID = nil } })) {
            if let id = selectedCaptureID {
                CaptureDetailView(captureID: id, sequence: results?.captures.map(\.id),
                                  onClose: { selectedCaptureID = nil; fieldFocused = true },
                                  onSelect: { selectedCaptureID = $0 })
                    .inspectorColumnWidth(min: 380, ideal: 520, max: 900)
            }
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your history — e.g. “postgres error yesterday” or “when was I troubleshooting Docker networking?”", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { remember(); runSearch() }
                    .onChange(of: query) { debounceSearch() }
                if searching { ProgressView().controlSize(.small) }
                if !query.isEmpty {
                    Button { clear() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                        .help("Clear search")
                }
                Menu {
                    if recent.isEmpty {
                        Text("No recent searches")
                    } else {
                        ForEach(recent, id: \.self) { item in Button(item) { use(item) } }
                        Divider()
                        Button("Clear Recent Searches") { recent = []; RecentSearches.save([]) }
                    }
                } label: { Image(systemName: "clock.arrow.circlepath") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Recent searches")
                Toggle("Exact", isOn: $exact).toggleStyle(.checkbox).help("Require every word (keyword search only)")
                    .onChange(of: exact) { runSearch() }
                Button("Ask") { remember(); ask() }
                    .disabled(query.isEmpty || state.settings.summaryModel.isEmpty || !state.settings.aiTransmissionAllowed || answering)
                    .help(state.settings.summaryModel.isEmpty ? "Select a summary model in Settings → AI to ask questions"
                          : !state.settings.aiTransmissionAllowed ? "Approve the AI provider in Settings → AI first"
                          : "Answer using only your captured history")
            }
            if let r = results {
                HStack(spacing: 6) {
                    if let range = r.interpretation.range {
                        StatusPill(text: "\(range.start.formatted(date: .abbreviated, time: .shortened)) – \(range.end.formatted(date: .abbreviated, time: .shortened))", color: .blue)
                    }
                    ForEach(r.interpretation.applicationNames, id: \.self) { StatusPill(text: $0, color: .purple) }
                    if !r.interpretation.keywords.isEmpty { StatusPill(text: "terms: " + r.interpretation.keywords.joined(separator: " ")) }
                    StatusPill(text: r.semanticUsed ? "keyword + semantic" : "keyword only", color: r.semanticUsed ? .green : .secondary)
                    if !r.relaxedFilters.isEmpty { StatusPill(text: "relaxed: " + r.relaxedFilters.joined(separator: ", "), color: .orange) }
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        if let error {
            ContentUnavailableView("Search failed", systemImage: "exclamationmark.magnifyingglass", description: Text(error))
        } else if let results {
            List {
                if answering || answer != nil {
                    Section("Answer") { answerView }
                }
                if !results.sessions.isEmpty {
                    Section("Sessions") {
                        ForEach(results.sessions) { hit in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(hit.session.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    ForEach(hit.session.bundleIdentifiers.prefix(4), id: \.self) { AppIcon(bundleIdentifier: $0, size: 13) }
                                    if let p = hit.session.projectName { StatusPill(text: p, color: .accentColor) }
                                }
                                Text(hit.session.title).font(.headline)
                                if !hit.snippet.isEmpty { HighlightedText(snippet: hit.snippet).font(.callout).lineLimit(3) }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let first = try? state.store?.captures(inSession: hit.session.id).first { selectedCaptureID = first.id }
                            }
                        }
                    }
                }
                Section("Screenshots (\(results.captures.count))") {
                    if results.captures.isEmpty {
                        Text("No matching screenshots.").foregroundStyle(.secondary)
                    }
                    ForEach(results.captures) { hit in
                        CaptureHitRow(hit: hit, selected: selectedCaptureID == hit.id)
                            .contentShape(Rectangle())
                            .onTapGesture { remember(); selectedCaptureID = hit.id }
                    }
                }
            }
            .listStyle(.inset)
        } else {
            VStack(spacing: 16) {
                ContentUnavailableView {
                    Label("Search your history", systemImage: "magnifyingglass")
                } description: {
                    Text("Matches recognized text, window titles, applications, AI descriptions and projects. Dates like “yesterday morning” or “last Tuesday” and app names like “terminal” become filters.")
                }
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recent searches").font(.headline)
                        ForEach(recent.prefix(8), id: \.self) { item in
                            Button { use(item) } label: { Label(item, systemImage: "clock") }.buttonStyle(.link)
                        }
                    }
                    .frame(maxWidth: 420, alignment: .leading)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder private var answerView: some View {
        if answering {
            HStack {
                ProgressView().controlSize(.small)
                Text("Asking \(state.settings.summaryModel)… background analysis is paused until it answers.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { cancelAsk() }
            }
        } else if let answer {
            VStack(alignment: .leading, spacing: 8) {
                Text(answer.text).textSelection(.enabled)
                    .foregroundStyle(answer.sufficientEvidence ? .primary : .secondary)
                if !answer.citations.isEmpty {
                    HStack {
                        Text("Sources:").font(.caption).foregroundStyle(.secondary)
                        ForEach(answer.citations, id: \.self) { citation in
                            switch citation {
                            case .capture(let id):
                                Button("C\(id)") { selectedCaptureID = id }.buttonStyle(.link)
                            case .session(let id):
                                Button("S\(id)") {
                                    if let first = try? state.store?.captures(inSession: id).first { selectedCaptureID = first.id }
                                }.buttonStyle(.link)
                            }
                        }
                    }
                    .font(.caption)
                }
                Text("Generated by \(state.settings.summaryModel) from the records cited above.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func debounceSearch() {
        searchTask?.cancel()
        cancelAsk()
        answer = nil
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { await performSearch() }
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        searchTask = Task { await performSearch() }
    }

    private func performSearch() async {
        guard let store = state.store else { return }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = nil; return }
        searching = true
        defer { searching = false }
        let s = state.settings
        let usable = state.queueStatus.providerReachable && s.aiTransmissionAllowed
        let search = HybridSearch(store: store, ai: usable ? state.ai : nil, embeddingModel: s.embeddingModel, embeddingKey: s.embeddingIndexKey)
        do {
            let r = try await search.search(q, projectID: projectID, exact: exact)
            if !Task.isCancelled { results = r; error = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func ask() {
        let q = query
        let s = state.settings
        askTask?.cancel()
        answering = true
        answer = nil
        askTask = Task {
            defer { if !Task.isCancelled { answering = false } }
            if results == nil { await performSearch() }
            guard let results, !Task.isCancelled else { return }
            let answerer = GroundedAnswerer(ai: state.ai, model: s.summaryModel, redactWith: s.redactionEnabled ? s.sensitiveRules : nil)
            do {
                let result = try await state.interactive { try await answerer.answer(question: q, results: results) }
                if !Task.isCancelled { answer = result }
            } catch {
                if !Task.isCancelled {
                    answer = GroundedAnswer(text: "Couldn't get an answer: \(error.localizedDescription)", citations: [], sufficientEvidence: false)
                }
            }
        }
    }

    private func cancelAsk() {
        askTask?.cancel()
        askTask = nil
        answering = false
    }

    private func clear() {
        searchTask?.cancel()
        cancelAsk()
        query = ""
        results = nil
        answer = nil
        error = nil
        selectedCaptureID = nil
        fieldFocused = true
    }

    private func use(_ item: String) {
        query = item
        remember()
        runSearch()
        fieldFocused = true
    }

    private func remember() {
        recent = RecentSearches.add(query, to: recent)
    }
}

/// Recent queries, kept in UserDefaults as a per-user convenience.
enum RecentSearches {
    private static let key = "RecentSearches"
    static let limit = 15

    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func save(_ items: [String]) { UserDefaults.standard.set(items, forKey: key) }

    static func add(_ query: String, to list: [String]) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return list }
        let updated = Array(([q] + list.filter { $0.caseInsensitiveCompare(q) != .orderedSame }).prefix(limit))
        save(updated)
        return updated
    }
}

struct CaptureHitRow: View {
    let hit: CaptureHit
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StoredImage(relativePath: hit.capture.thumbnailPath, maxPixel: 320)
                .frame(width: 140, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    AppIcon(bundleIdentifier: hit.capture.bundleIdentifier, size: 14)
                    Text(hit.capture.applicationName).font(.subheadline.weight(.medium))
                    Text(hit.capture.capturedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    if hit.matchedSemantic { Image(systemName: "sparkles").font(.caption2).foregroundStyle(.green).help("Semantic match") }
                }
                if !hit.capture.windowTitle.isEmpty { Text(hit.capture.windowTitle).font(.callout).lineLimit(1) }
                HighlightedText(snippet: hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }
}
