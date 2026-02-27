import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var appLanguage: String = {
        if let lang = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage) {
            return lang
        }
        return Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en"
    }()
    @State private var showRestartAlert = false
    @State private var showMenuBarIconHiddenAlert = false
    @AppStorage(UserDefaultsKeys.showMenuBarIcon) private var showMenuBarIcon = true
    @ObservedObject private var modelManager = ModelManagerViewModel.shared
    @ObservedObject private var settings = SettingsViewModel.shared

    var body: some View {
        Form {
            Section(String(localized: "Spoken Language")) {
                Picker(String(localized: "Spoken language"), selection: $settings.selectedLanguage) {
                    Text(String(localized: "Auto-detect")).tag(nil as String?)
                    Divider()
                    ForEach(settings.availableLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code as String?)
                    }
                }

                Text(String(localized: "The language being spoken. Setting this explicitly improves accuracy."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Translation")) {
                Toggle(String(localized: "Enable translation"), isOn: $settings.translationEnabled)

                if settings.translationEnabled {
                    Picker(String(localized: "Target language"), selection: $settings.translationTargetLanguage) {
                        ForEach(TranslationService.availableTargetLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                }

                Text(String(localized: "Uses Apple Translate (on-device)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Default Model")) {
                if modelManager.readyModels.isEmpty && modelManager.configuredPluginEngines.isEmpty {
                    Text(String(localized: "No models available. Download or configure a model in the Models tab."))
                        .foregroundStyle(.secondary)
                } else {
                    Picker(String(localized: "Model"), selection: Binding(
                        get: { modelManager.selectedModelId },
                        set: { if let id = $0 { modelManager.selectDefaultModel(id) } }
                    )) {
                        ForEach(modelManager.readyModels) { model in
                            Text("\(model.displayName) (\(model.engineType.displayName))")
                                .tag(model.id as String?)
                        }

                        if !modelManager.configuredPluginEngines.isEmpty && !modelManager.readyModels.isEmpty {
                            Divider()
                        }

                        ForEach(modelManager.configuredPluginEngines, id: \.providerId) { engine in
                            ForEach(engine.transcriptionModels, id: \.id) { model in
                                Text("\(model.displayName) (\(engine.providerDisplayName))")
                                    .tag(CloudProvider.fullId(provider: engine.providerId, model: model.id) as String?)
                            }
                        }
                    }
                }

                Text(String(localized: "The model used for transcription unless overridden by a profile."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Language")) {
                Picker(String(localized: "App Language"), selection: $appLanguage) {
                    Text("English").tag("en")
                    Text("Deutsch").tag("de")
                }
                .onChange(of: appLanguage) {
                    UserDefaults.standard.set(appLanguage, forKey: UserDefaultsKeys.preferredAppLanguage)
                    UserDefaults.standard.set([appLanguage], forKey: "AppleLanguages")
                    showRestartAlert = true
                }
            }

            Section(String(localized: "Startup")) {
                Toggle(String(localized: "Launch at Login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }

                Text(String(localized: "TypeWhisper will start automatically when you log in."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Appearance")) {
                Toggle(String(localized: "Show menu bar icon"), isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { _, newValue in
                        if !newValue {
                            let alertShown = UserDefaults.standard.bool(forKey: UserDefaultsKeys.menuBarIconHiddenAlertShown)
                            if !alertShown {
                                showMenuBarIconHiddenAlert = true
                                UserDefaults.standard.set(true, forKey: UserDefaultsKeys.menuBarIconHiddenAlertShown)
                            }
                        }
                    }

                Text(String(localized: "When hidden, the app is accessible via the Dock icon."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            #if !APPSTORE
            Section(String(localized: "Updates")) {
                HStack {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                    Text("Version \(version) (\(build))")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(String(localized: "Check for Updates...")) {
                        UpdateChecker.shared?.checkForUpdates()
                    }
                    .disabled(UpdateChecker.shared?.canCheckForUpdates() != true)
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .alert(String(localized: "Restart Required"), isPresented: $showRestartAlert) {
            Button(String(localized: "Restart Now")) {
                restartApp()
            }
            Button(String(localized: "Later"), role: .cancel) {}
        } message: {
            Text(String(localized: "The language change will take effect after restarting TypeWhisper."))
        }
        .alert(String(localized: "Menu bar icon hidden"), isPresented: $showMenuBarIconHiddenAlert) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "You can access TypeWhisper settings via the Dock icon."))
        }
    }

    private func restartApp() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func toggleLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert toggle on failure
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
