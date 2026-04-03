import SwiftUI

struct EqualiserSettingsView: View {
    @Bindable var equaliserSettings: EqualiserSettingsStore
    @State private var showCustomEditor = false

    var body: some View {
        List {
            Section {
                Toggle("Enable equaliser", isOn: $equaliserSettings.isEnabled)
                Picker("Preset", selection: $equaliserSettings.selectedPresetId) {
                    ForEach(equaliserSettings.presets) { p in
                        Text(p.displayName).tag(p.id)
                    }
                    Text("Custom").tag(EqualiserSettingsStore.customPresetId)
                }
            } footer: {
                Text(presetFooterText)
            }

            Section {
                Button("Edit custom curve…") {
                    showCustomEditor = true
                }
                .disabled(!equaliserSettings.isEnabled)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Equaliser")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showCustomEditor) {
            EqualiserCustomCurveSheet(equaliserSettings: equaliserSettings)
        }
    }

    private var presetFooterText: String {
        let hz = EqualiserConstants.centreFrequenciesHz
        let labels = hz.map { f in
            f >= 1000 ? String(format: "%.0fk", f / 1000) : String(format: "%.0f", f)
        }
        return "Bands (Hz): " + labels.joined(separator: ", ")
    }
}

private struct EqualiserCustomCurveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var equaliserSettings: EqualiserSettingsStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Preamp")
                        Spacer()
                        Text(String(format: "%.1f dB", equaliserSettings.customPreampDb))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $equaliserSettings.customPreampDb, in: -12...12, step: 0.5)
                } footer: {
                    Text("Reduce preamp if the combined curve pushes output into clipping.")
                }

                Section {
                    ForEach(0..<EqualiserConstants.bandCount, id: \.self) { i in
                        HStack {
                            Text(bandLabel(index: i))
                                .monospacedDigit()
                            Spacer()
                            Text(String(format: "%.1f dB", equaliserSettings.customBandGainsDb[i]))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: bandBinding(index: i),
                            in: -12...12,
                            step: 0.5
                        )
                    }
                }

                Section {
                    Button("Reset custom to flat") {
                        equaliserSettings.resetCustomToFlat()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Custom EQ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func bandLabel(index: Int) -> String {
        let f = EqualiserConstants.centreFrequenciesHz[index]
        if f >= 1000 {
            return String(format: "%.0f kHz", f / 1000)
        }
        return String(format: "%.0f Hz", f)
    }

    private func bandBinding(index: Int) -> Binding<Float> {
        Binding(
            get: { equaliserSettings.customBandGainsDb[index] },
            set: { equaliserSettings.setCustomBandGain(index: index, value: $0) }
        )
    }
}
