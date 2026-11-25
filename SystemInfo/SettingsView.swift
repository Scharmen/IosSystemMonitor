//
//  SettingsView.swift
//  SystemInfo
//

import SwiftUI

/// `UserDefaults` keys for settings that aren't about the menu bar.
enum SettingsKey {
    static let pricePerKWh = "electricityPricePerKWh"
    static let hideGaps = "historyHideGaps"
}

/// The app's Settings window: electricity price and how much history is kept.
struct SettingsView: View {
    @Environment(HistoryRecorder.self) private var recorder

    @AppStorage(SettingsKey.pricePerKWh) private var pricePerKWh = 0.0
    @AppStorage(HistoryRetention.storageKey) private var retention = HistoryRetention.month
    @AppStorage(HistoryRetention.yearsStorageKey) private var retentionYears = HistoryRetention.defaultYears
    /// The years value being edited; only saved with "Apply" so stepping down doesn't delete data on the way.
    @State private var draftYears = HistoryRetention.currentYears
    @State private var isConfirmingYears = false
    @State private var isConfirmingClear = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Electricity price per kWh") {
                    HStack(spacing: 4) {
                        TextField("Price", value: $pricePerKWh, format: .number.precision(.fractionLength(0...4)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text(Locale.current.currency?.identifier ?? "EUR")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Energy")
            } footer: {
                Text("Used to show what your Mac's energy use costs. Leave it at 0 to hide costs.")
            }

            Section {
                Picker("Keep history for", selection: $retention) {
                    ForEach(HistoryRetention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                }

                if retention == .years {
                    HStack {
                        Stepper("\(draftYears) \(draftYears == 1 ? "year" : "years")", value: $draftYears, in: HistoryRetention.yearsRange)
                        if draftYears != retentionYears {
                            Button("Apply") {
                                if draftYears < retentionYears {
                                    isConfirmingYears = true
                                } else {
                                    applyYears()
                                }
                            }
                            Button("Cancel") {
                                draftYears = retentionYears
                            }
                        }
                    }
                    .confirmationDialog("Keep only \(draftYears) \(draftYears == 1 ? "year" : "years") of history?", isPresented: $isConfirmingYears) {
                        Button("Delete Older Data", role: .destructive, action: applyYears)
                    } message: {
                        Text("Data older than that is deleted and can't be restored.")
                    }
                }

                LabeledContent("Database size") {
                    Text("\(recorder.storeSize.formatted(.byteCount(style: .file))) · \(recorder.sampleCount.formatted()) samples")
                        .monospacedDigit()
                }

                if recorder.isPausedForLowDiskSpace {
                    Label("Recording is paused because your disk is almost full.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                Button("Clear History…", role: .destructive) {
                    isConfirmingClear = true
                }
                .confirmationDialog("Delete all recorded history?", isPresented: $isConfirmingClear) {
                    Button("Clear History", role: .destructive) {
                        recorder.clearHistory()
                    }
                } message: {
                    Text("This can't be undone.")
                }
            } header: {
                Text("History Storage")
            } footer: {
                Text("To keep storage small, older data is condensed automatically: 30-second values for the last 7 days, 15-minute averages up to 90 days, and hourly averages beyond that. Recording pauses when less than 1 GB of disk space is free.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: retention) {
            recorder.performMaintenance()
        }
    }

    private func applyYears() {
        retentionYears = draftYears
        recorder.performMaintenance()
    }
}
