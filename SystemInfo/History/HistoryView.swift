//
//  HistoryView.swift
//  SystemInfo
//

import SwiftUI
import SwiftData

/// The history window: a sidebar with pages, and a toolbar that sets the time span for all of them.
struct HistoryView: View {
    static let windowID = "history"

    enum Page: String, CaseIterable, Identifiable {
        case overview, energy, sleep

        var id: Self { self }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .energy: "Energy"
            case .sleep: "Sleep"
            }
        }

        var systemImage: String {
            switch self {
            case .overview: "chart.xyaxis.line"
            case .energy: "powerplug"
            case .sleep: "moon.zzz"
            }
        }
    }

    @Environment(HistoryRecorder.self) private var recorder
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsKey.hideGaps) private var hideGaps = false
    @State private var store: HistoryStore
    @State private var page: Page? = .overview

    init(container: ModelContainer) {
        let store = HistoryStore(container: container)
        #if DEBUG
        if let range = DemoData.initialRange {
            store.range = range
        }
        _page = State(initialValue: DemoData.initialPage ?? .overview)
        #endif
        _store = State(initialValue: store)
    }

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            List(Page.allCases, selection: $page) { page in
                Label(page.title, systemImage: page.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            switch page ?? .overview {
            case .overview: OverviewPage(store: store, hideGaps: hideGaps)
            case .energy: EnergyPage(store: store)
            case .sleep: SleepPage(store: store)
            }
        }
        .navigationTitle("History")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Earlier", systemImage: "chevron.left") {
                    store.page(-1)
                }
                .disabled(!store.canPageBack)
                .help("Show the time before this")

                Button("Later", systemImage: "chevron.right") {
                    store.page(1)
                }
                .disabled(!store.canPageForward)
                .help("Show the time after this")
            }

            ToolbarItem(placement: .principal) {
                Picker("Range", selection: $store.range) {
                    ForEach(HistoryRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .help("How much time to show")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                    store.zoomOut()
                }
                .disabled(!store.isZoomed)
                .help("Go back to the time span shown before zooming in")

                Toggle("Hide Gaps", systemImage: "arrow.right.and.line.vertical.and.arrow.left", isOn: $hideGaps)
                    .help("Squeeze out the time your Mac was asleep or off")

                Button("Settings", systemImage: "gearshape") {
                    openSettings()
                    AppWindows.bringToFront(AppWindows.settingsIdentifier)
                }
                .help("Electricity price and history storage")
            }
        }
        .frame(minWidth: 860, minHeight: 600)
        .task {
            store.reload()
            #if DEBUG
            DemoData.saveSnapshotIfRequested()
            #endif
        }
        // The recorder bumps its revision whenever the database changes, so the window follows new samples.
        .onChange(of: recorder.revision) {
            store.reload()
        }
    }

    /// The visible time span, shown under the window title.
    private var subtitle: String {
        guard store.hasLoaded else { return "" }
        let domain = store.snapshot.domain
        let span = (domain.lowerBound..<domain.upperBound).formatted(date: .abbreviated, time: .shortened)
        return store.customRange == nil ? "\(span) · Live" : span
    }
}
