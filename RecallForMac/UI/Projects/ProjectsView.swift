import RecallCore
import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject private var state: AppState
    @State private var projects: [ProjectRecord] = []
    @State private var selection: Int64?
    @State private var editing: ProjectRecord?
    @State private var creating = false
    @State private var mergeSource: ProjectRecord?

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(projects) { project in
                    Text(project.name).tag(project.id)
                        .contextMenu {
                            Button("Edit…") { editing = project }
                            Button("Merge Into…") { mergeSource = project }
                            Divider()
                            Button("Delete", role: .destructive) {
                                try? state.store?.deleteProject(id: project.id)
                                if selection == project.id { selection = nil }
                                reload()
                                state.historyChanged()
                            }
                        }
                }
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { creating = true } label: { Image(systemName: "plus") }
                    Button { if let p = projects.first(where: { $0.id == selection }) { editing = p } } label: { Image(systemName: "pencil") }
                        .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }

            Group {
                if let id = selection, let project = projects.first(where: { $0.id == id }) {
                    ProjectDetailView(project: project)
                } else {
                    ContentUnavailableView {
                        Label("Projects", systemImage: "folder")
                    } description: {
                        Text("Create a project with keywords, repository paths or domains. Activity is associated automatically when the match is unambiguous; you can always reassign sessions from the timeline.")
                    } actions: {
                        Button("New Project…") { creating = true }
                    }
                }
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Projects")
        .task(id: state.revision) { reload() }
        .sheet(isPresented: $creating) {
            ProjectEditor(project: nil) { name, description, rules in
                if let id = try? state.store?.createProject(name: name, description: description, rules: rules) {
                    selection = id
                    reassociateRecent()
                }
                reload()
            }
        }
        .sheet(item: $editing) { project in
            ProjectEditor(project: project) { name, description, rules in
                var updated = project
                updated.name = name
                updated.description = description
                updated.rules = rules
                try? state.store?.updateProject(updated)
                reassociateRecent()
                reload()
                state.historyChanged()
            }
        }
        .sheet(item: $mergeSource) { source in
            MergeProjectSheet(source: source, candidates: projects.filter { $0.id != source.id }) { target in
                try? state.store?.mergeProjects(source: source.id, into: target)
                selection = target
                reload()
                state.historyChanged()
            }
        }
    }

    private func reload() { projects = (try? state.store?.projects()) ?? [] }

    /// New or changed rules apply to the last two weeks of unassigned sessions.
    private func reassociateRecent() {
        guard let store = state.store else { return }
        let rows = (try? store.db.query("SELECT id FROM sessions WHERE project_source != 'user' AND started_at > ?",
                                        [Date().addingTimeInterval(-14 * 86400)])) ?? []
        for row in rows { try? store.enqueueJob(.projectAssociation, entityType: "session", entityID: row.int("id")!, priority: 5) }
        let caps = (try? store.db.query("SELECT id FROM captures WHERE project_id IS NULL AND captured_at > ?",
                                        [Date().addingTimeInterval(-14 * 86400)])) ?? []
        for row in caps { try? store.enqueueJob(.projectAssociation, entityType: "capture", entityID: row.int("id")!, priority: 5) }
        state.refreshQueue()
    }
}

struct ProjectDetailView: View {
    let project: ProjectRecord
    @EnvironmentObject private var state: AppState
    @State private var tab = 0
    @State private var totals: (all: Double, week: Double, today: Double) = (0, 0, 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(project.name).font(.largeTitle.bold())
                if !project.description.isEmpty { Text(project.description).foregroundStyle(.secondary) }
                HStack(spacing: 16) {
                    stat("Today", totals.today)
                    stat("This week", totals.week)
                    stat("All time", totals.all)
                }
                Picker("", selection: $tab) {
                    Text("Timeline").tag(0)
                    Text("Search").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding(16)
            Divider()
            if tab == 0 {
                TimelineView(title: project.name, range: DateInterval(start: .distantPast, end: .distantFuture), projectID: project.id)
            } else {
                SearchView(projectID: project.id)
            }
        }
        .task(id: "\(project.id)-\(state.revision)") {
            guard let store = state.store else { return }
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let week = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? today
            totals = ((try? store.projectActiveSeconds(projectID: project.id)) ?? 0,
                      (try? store.projectActiveSeconds(projectID: project.id, from: week)) ?? 0,
                      (try? store.projectActiveSeconds(projectID: project.id, from: today)) ?? 0)
        }
    }

    private func stat(_ label: String, _ seconds: Double) -> some View {
        VStack(alignment: .leading) {
            Text(formatDuration(seconds)).font(.title3.monospacedDigit().weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ProjectEditor: View {
    let project: ProjectRecord?
    let onSave: (String, String, ProjectRules) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var keywords = ""
    @State private var aliases = ""
    @State private var paths = ""
    @State private var domains = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(project == nil ? "New Project" : "Edit Project").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $description)
                TextField("Keywords", text: $keywords, prompt: Text("truesoc, minio, elasticmq"))
                TextField("Aliases", text: $aliases, prompt: Text("Other names for this project"))
                TextField("Repository paths", text: $paths, prompt: Text("~/Github/truesoc"))
                TextField("Domains", text: $domains, prompt: Text("truesoc.example.com"))
            }
            Text("Comma-separated. Matching is case-insensitive; activity matching two projects equally stays unclassified.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(name.trimmingCharacters(in: .whitespaces), description,
                           ProjectRules(keywords: split(keywords), aliases: split(aliases), repositoryPaths: split(paths), domains: split(domains)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            guard let project else { return }
            name = project.name
            description = project.description
            keywords = project.rules.keywords.joined(separator: ", ")
            aliases = project.rules.aliases.joined(separator: ", ")
            paths = project.rules.repositoryPaths.joined(separator: ", ")
            domains = project.rules.domains.joined(separator: ", ")
        }
    }

    private func split(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct MergeProjectSheet: View {
    let source: ProjectRecord
    let candidates: [ProjectRecord]
    let onMerge: (Int64) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var target: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge “\(source.name)” into…").font(.headline)
            Picker("Target", selection: $target) {
                Text("Choose a project").tag(Int64?.none)
                ForEach(candidates) { Text($0.name).tag(Optional($0.id)) }
            }
            Text("All sessions move to the target project and “\(source.name)” becomes one of its aliases.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Merge") { if let target { onMerge(target) }; dismiss() }.disabled(target == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
