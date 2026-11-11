import SwiftUI

/// The Settings window (Command-Comma). One tab per topic. Each tab is a grouped
/// Form that sizes to its content, so the window grows to fit and shows no scroll bar it does not need.
struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        TabView(selection: $settings.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .noInitialFocus()
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        Form {
            switch tab {
            case .folders: FolderSettings()
            case .saves: SaveSettings()
            case .appearance: AppearanceSettings()
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 520)
    }
}

/// The Settings tabs. Snapshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case folders, saves, appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folders: "Folders"
        case .saves: "Saves"
        case .appearance: "Appearance"
        }
    }

    var symbol: String {
        switch self {
        case .folders: "folder"
        case .saves: "square.and.arrow.down"
        case .appearance: "paintpalette"
        }
    }
}

struct FolderSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Section {
            ForEach($settings.folderSlots) { $slot in
                LabeledContent(slot.label) {
                    PathRow(path: slot.path) {
                        if let url = Panels.chooseFolder(title: "Choose Video Folder", current: slot.path) {
                            slot.path = url.path
                            slot.label = url.lastPathComponent
                        }
                    }
                }
            }
        } header: {
            Text("Video folder shortcuts")
        } footer: {
            Text("These five folders appear in the sidebar's folder menu.")
        }
    }
}

struct SaveSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Section("Automatic saves") {
            LabeledContent("Screenshots") {
                PathRow(path: settings.screenshotDirectory) {
                    if let url = Panels.chooseFolder(title: "Screenshot Folder", current: settings.screenshotDirectory) {
                        settings.screenshotDirectory = url.path
                    }
                }
            }
            LabeledContent("Exports") {
                PathRow(path: settings.exportDirectory) {
                    if let url = Panels.chooseFolder(title: "Export Folder", current: settings.exportDirectory) {
                        settings.exportDirectory = url.path
                    }
                }
            }
        }
    }
}

private struct PathRow: View {
    let path: String
    let choose: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            Text((path as NSString).abbreviatingWithTildeInPath)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Button("Choose…", action: choose)
        }
    }
}
