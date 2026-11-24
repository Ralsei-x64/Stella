import SwiftUI

struct GameCompatibilityEditor: View {
    @EnvironmentObject private var settings: LauncherSettings
    @Environment(\.dismiss) private var dismiss
    let game: GameStatsStore.Game
    @ObservedObject var recommendations: GameRecommendations
    @State private var draft: GameProfile
    @State private var runtime = false
    @State private var editingPresets = false
    @State private var presetName = ""
    @State private var chosenPreset = ""
    @State private var showSecurity = false

    init(game: GameStatsStore.Game, profile: GameProfile, recommendations: GameRecommendations) {
        self.game = game
        self.recommendations = recommendations
        _draft = State(initialValue: profile)
    }

    private var presets: [CompatibilityPreset] { settings.compatibilityPresets(for: game.appid) }
    private var valid: Bool { GameProfile.validEnv(draft.env) }
    private var selectedPreset: String {
        guard valid else { return "" }
        let matches = presets.filter { $0.profile == draft.normalized }
        return matches.first { $0.id == chosenPreset }?.id ?? matches.first?.id ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: game.title).font(.title2.bold())
                Text("Compatibility").foregroundStyle(.secondary)
            }.padding([.horizontal, .top], 20)
            HStack {
                Picker("Preset", selection: Binding(get: { selectedPreset }, set: { id in
                    guard let preset = presets.first(where: { $0.id == id }) else { return }
                    draft = preset.profile
                    chosenPreset = id
                })) {
                    if selectedPreset.isEmpty { Text("Custom settings").tag("") }
                    ForEach(CompatibilityPreset.builtIns(for: game.appid)) { preset in
                        Text(verbatim: preset.name).tag(preset.id)
                            .disabled(preset.profile.driver.flatMap(LauncherSettings.VulkanDriver.init(rawValue:))?.unavailableReason != nil)
                    }
                    if !settings.savedPresets.isEmpty {
                        Section("My presets") {
                            ForEach(presets.filter { $0.id.hasPrefix("saved.") }) { preset in
                                Text(verbatim: preset.name).tag(preset.id)
                            }
                        }
                    }
                }
                Button("My presets…") { presetName = ""; editingPresets = true }
                    .popover(isPresented: $editingPresets) { personalPresets }
            }.padding(.horizontal, 20).padding(.vertical, 10)
            if selectedPreset == "sm66" && game.appid == 2776090 {
                Text("Verified in gameplay on an M4 Max using KosmicKrisp.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 8)
            }
            Picker("Compatibility controls", selection: $runtime) {
                Text("Graphics").tag(false)
                Text("Runtime").tag(true)
            }.labelsHidden().pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 8)
            Form {
                if runtime { runtimeControls } else { graphicsControls }
            }
            .formStyle(.grouped)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Launch options").font(.headline)
                TextField("Launch options", text: $draft.env).labelsHidden().textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced)).accessibilityIdentifier("game-launch-options")
                    .help("Use NAME=value words (up to 256 characters). Names must start with VKD3D_, DXVK_, PROTON_, WINE_, MESA_, RADV_, VK_, DXMT_, MTL_ or STEAMAC_; values may contain letters, digits and _.,:;+- only.")
                if !valid {
                    Text("Use up to 256 characters of supported NAME=value assignments.")
                        .font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text("Steam may need to restart to apply changes.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Apply") {
                        settings.setProfile(draft, for: game.appid)
                        dismiss()
                    }.keyboardShortcut(.defaultAction).disabled(!valid)
                }
            }.padding(16)
        }
        .frame(width: 540, height: 590)
        .alert("Allow DXMT?", isPresented: $showSecurity) {
            Button("Allow DXMT") { settings.wmtr = true }
            Button("Cancel", role: .cancel) {}
        } message: { Text(verbatim: GameProfile.securityText) }
    }

    @ViewBuilder private var graphicsControls: some View {
        Section {
            Picker("Graphics", selection: $draft.gfx) {
                Text("Default").tag(nil as String?)
                Text(verbatim: "Vulkan").tag(Optional("vulkan"))
                Text(verbatim: "DXMT").tag(Optional("dxmt"))
            }
            Picker("Vulkan driver", selection: $draft.driver) {
                Text("Default").tag(nil as String?)
                ForEach(LauncherSettings.VulkanDriver.allCases) { driver in
                    Text(verbatim: driver.name).tag(Optional(driver.rawValue)).disabled(driver.unavailableReason != nil)
                }
            }
            Picker("Falsify GPU Vendor", selection: $draft.gpuVendor) {
                Text("Off").tag(nil as GameProfile.GPUVendor?)
                ForEach(GameProfile.GPUVendor.allCases, id: \.self) { vendor in
                    Text(verbatim: vendor.name).tag(Optional(vendor))
                }
            }.help("Change the adapter name and PCI IDs this game sees. Its graphics features stay the same.")
            if draft.gfx == "dxmt" && !settings.wmtr {
                HStack {
                    Text("DXMT is not in effect while Allow DXMT is off.").font(.caption)
                    Spacer()
                    Button("Allow DXMT…") { showSecurity = true }
                }
            } else if draft.gfx == "dxmt" && settings.bootedDXMT == false {
                Text("Allow DXMT applies on the next VM start.").font(.caption)
            }
            if (draft.driver ?? settings.vulkanDriver.rawValue) != (settings.bootedDriver ?? settings.vulkanDriver).rawValue {
                Text("Vulkan driver applies on the next start of this game (VM restart required).").font(.caption)
            }
        }
        Section {
            option("Shader model", "VKD3D_SHADER_MODEL", numbers(["6_0", "6_1", "6_2", "6_3", "6_4", "6_5", "6_6"]))
            option("Feature level", "VKD3D_FEATURE_LEVEL", numbers(["11_0", "11_1", "12_0", "12_1"]))
            option("64-bit atomics", "VKD3D_DISABLE_EXTENSIONS", [("", String(localized: "Expose driver support"))])
        } header: { Text("DirectX 12") } footer: {
            Text("Shader model and feature level change what vkd3d reports. Rendering still depends on the Vulkan driver.")
        }
        recommendation
    }

    @ViewBuilder private var runtimeControls: some View {
        Section {
            option("DirectX 12 frame limit", "VKD3D_FRAME_RATE", ["30", "40", "60", "90", "120"].map { ($0, $0 + " FPS") })
            option("DXVK overlay", "DXVK_HUD", [("fps", String(localized: "Frame rate")),
                                                 ("fps,frametimes", String(localized: "Frame rate and frame times"))])
        }
        Section {
            option("Microphone", "STEAMAC_DISABLE_MIC", [("1", String(localized: "Disable for this game"))])
            option("Proton log", "PROTON_LOG", [("1", String(localized: "Write log"))])
        } footer: {
            Text("Disable the microphone for games that stall when opening voice input. Proton writes its launch log to the SteamOS home folder.")
        }
        recommendation
    }

    private func numbers(_ values: [String]) -> [(String, String)] {
        values.map { ($0, $0.replacingOccurrences(of: "_", with: ".")) }
    }

    private func option(_ label: LocalizedStringKey, _ key: String, _ choices: [(String, String)]) -> some View {
        let current = draft.option(key)
        return Picker(label, selection: Binding(get: { draft.option(key) }, set: { draft.setOption(key, to: $0) })) {
            Text("Default").tag(nil as String?)
            ForEach(choices, id: \.0) { value, title in Text(verbatim: title).tag(Optional(value)) }
            if let current, !choices.contains(where: { $0.0 == current }) {
                Text("Custom (\(current))").tag(Optional(current))
            }
        }
    }

    @ViewBuilder private var recommendation: some View {
        switch recommendations.rows[game.appid] {
        case .found(let row):
            Section("Community recommendation") {
                HStack {
                    Text(verbatim: row.profile.summary).font(.caption)
                    Spacer()
                    Button("Use recommendation") {
                        var suggested = row.profile
                        suggested.gpuVendor = draft.gpuVendor
                        draft = suggested
                    }.disabled(!row.usable)
                }
            }
        case .loading: Text("Recommended: loading…").font(.caption).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }

    private var personalPresets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("My presets").font(.headline)
            if !settings.savedPresets.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(settings.savedPresets.keys.sorted(), id: \.self) { name in
                            HStack {
                                Text(verbatim: name).lineLimit(1)
                                Spacer()
                                Button { settings.removePreset(named: name) } label: { Image(systemName: "trash") }
                                    .accessibilityLabel(Text("Delete preset \(name)"))
                            }
                        }
                    }
                }.frame(maxHeight: 150)
            }
            TextField("Preset name", text: $presetName)
            Button("Save current settings as preset") {
                settings.savePreset(draft, named: trimmedName)
                chosenPreset = "saved." + trimmedName
                editingPresets = false
            }.disabled(!valid || trimmedName.isEmpty || settings.savedPresets[trimmedName] != nil)
        }.padding().frame(width: 285)
    }

    private var trimmedName: String { presetName.trimmingCharacters(in: .whitespacesAndNewlines) }
}
