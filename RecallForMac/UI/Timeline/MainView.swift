import RecallCore
import SwiftUI

enum SidebarSection: Hashable {
    case today, yesterday, thisWeek, calendar
    case search, projects, summaries, queue
}

struct MainView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var nav = NavigationRequest.shared
    @State private var section: SidebarSection? = .today
    @State private var calendarDate = Date()

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("History") {
                    Label("Today", systemImage: "sun.max").tag(SidebarSection.today)
                    Label("Yesterday", systemImage: "clock.arrow.circlepath").tag(SidebarSection.yesterday)
                    Label("This Week", systemImage: "calendar.day.timeline.left").tag(SidebarSection.thisWeek)
                    Label("Calendar", systemImage: "calendar").tag(SidebarSection.calendar)
                }
                Section("Explore") {
                    Label("Search", systemImage: "magnifyingglass").tag(SidebarSection.search)
                    Label("Projects", systemImage: "folder").tag(SidebarSection.projects)
                    Label("Daily Summaries", systemImage: "doc.text").tag(SidebarSection.summaries)
                }
                Section("System") {
                    Label {
                        HStack {
                            Text("Processing")
                            Spacer()
                            if state.queueStatus.actionablePending > 0 {
                                Text("\(state.queueStatus.actionablePending)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: { Image(systemName: "cpu") }
                        .tag(SidebarSection.queue)
                }
                if section == .calendar {
                    Section("Date") {
                        DatePicker("Date", selection: $calendarDate, in: ...Date(), displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) { statusFooter }
        } detail: {
            // A detail view must never dictate the window's minimum height: if one reports a large
            // minimum, SwiftUI lays the split view out taller than the window and both columns shift off-screen.
            detail.frame(minHeight: 0, maxHeight: .infinity)
        }
        .onAppear { consumeNavigation() }
        .onChange(of: nav.section) { consumeNavigation() }
        .overlay {
            if let error = state.startupError {
                ContentUnavailableView("Recall couldn't start", systemImage: "externaldrive.badge.exclamationmark", description: Text(error))
                    .background(.background)
            }
        }
    }

    private func consumeNavigation() {
        if let requested = nav.section {
            section = requested
            nav.section = nil
        }
    }

    @ViewBuilder private var detail: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch section ?? .today {
        case .today:
            TimelineView(title: "Today", range: DateInterval(start: today, end: cal.date(byAdding: .day, value: 1, to: today)!))
        case .yesterday:
            TimelineView(title: "Yesterday", range: DateInterval(start: cal.date(byAdding: .day, value: -1, to: today)!, end: today))
        case .thisWeek:
            let start = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? today
            TimelineView(title: "This Week", range: DateInterval(start: start, end: cal.date(byAdding: .day, value: 1, to: today)!))
        case .calendar:
            let day = cal.startOfDay(for: calendarDate)
            TimelineView(title: calendarDate.formatted(date: .complete, time: .omitted),
                         range: DateInterval(start: day, end: cal.date(byAdding: .day, value: 1, to: day)!))
        case .search: SearchView()
        case .projects: ProjectsView()
        case .summaries: SummariesView()
        case .queue: QueueView()
        }
    }

    private var statusFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: state.recordingState.symbol)
                .foregroundStyle(state.recordingState == .recording ? .red : .secondary)
            Text(state.recordingState.label).font(.caption).lineLimit(1)
            Spacer()
            if state.recordingState == .recording {
                Button { state.pause() } label: { Image(systemName: "pause.fill") }.buttonStyle(.borderless).help("Pause recording")
            } else if case .paused = state.recordingState {
                Button { state.resume() } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless).help("Resume recording")
            }
        }
        .padding(10)
    }
}
