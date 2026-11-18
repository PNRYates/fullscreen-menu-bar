import AppKit
import SwiftUI

struct BarSettingsView: View {
    private struct OpenApp: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
    }

    private struct AppSelection: Identifiable {
        let id = UUID()
        let apps: [OpenApp]
    }

    @ObservedObject var controller: BarController
    let chooseApp: () -> Void
    @State private var appSelection: AppSelection?

    private let tint = Color(red: 0.29, green: 0.39, blue: 0.80)
    private let columns: [GridItem] = [GridItem(.flexible(minimum: 110)), GridItem(.fixed(132)), GridItem(.fixed(132)), GridItem(.fixed(22))]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "macwindow")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                Text("Full Screen Bar")
                    .font(.system(size: 25, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Toggle("Apply rules", isOn: Binding(get: { controller.settings.enabled }, set: controller.setEnabled))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Display rules").font(.headline).accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    defaultRow(.notched, icon: "laptopcomputer")
                    Divider().padding(.horizontal, 12)
                    defaultRow(.unnotched, icon: "display")
                }
                .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("App exceptions").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(action: showAppPicker) { Label("Add App…", systemImage: "plus") }
                        .popover(item: $appSelection, arrowEdge: .bottom) { selection in
                            appPickerPopover(selection.apps)
                        }
                }
                if controller.settings.apps.isEmpty {
                    VStack {
                        Spacer(minLength: 15)
                        Text("No exceptions")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 15)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                            Text("App")
                            Text("With a notch")
                            Text("Without a notch")
                            Color.clear.frame(height: 1)
                            ForEach(controller.settings.apps) { app in
                                Text(app.name).lineLimit(1).help(app.name).foregroundStyle(.primary)
                                appPicker(app, kind: .notched)
                                appPicker(app, kind: .unnotched)
                                Button(role: .destructive) { controller.removeApp(app.id) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove \(app.name)")
                                .accessibilityLabel("Remove \(app.name)")
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                    }
                    .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Label {
                    Text(controller.issue ?? controller.status)
                } icon: {
                    Image(systemName: controller.issue == nil ? "circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(controller.issue != nil ? Color.orange : controller.settings.enabled ? Color.green : .secondary)
                }
                .foregroundStyle(.secondary)
                .font(.callout)
                Text("Rules follow the full-screen app you’re using. Other full-screen displays may change too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .tint(tint)
        .frame(minWidth: 540, minHeight: 410)
    }

    private func showAppPicker() {
        var seen = Set(controller.settings.apps.map(\.id))
        let openApps = NSWorkspace.shared.runningApplications.compactMap { app -> OpenApp? in
            guard app.activationPolicy == .regular, !app.isTerminated, let id = app.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier, let name = app.localizedName,
                  seen.insert(id).inserted else { return nil }
            return OpenApp(id: id, name: name, icon: app.icon)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        appSelection = AppSelection(apps: openApps)
    }

    private func appPickerPopover(_ openApps: [OpenApp]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open Apps").font(.headline)
            if openApps.isEmpty {
                Text("No other apps are open").foregroundStyle(.secondary)
            } else {
                List(openApps) { app in
                    Button {
                        controller.addApp(id: app.id, name: app.name)
                        appSelection = nil
                    } label: {
                        Label {
                            Text(app.name)
                        } icon: {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable().scaledToFit().frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "app").frame(width: 20, height: 20)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .frame(height: min(CGFloat(openApps.count) * 30, 240))
            }
            Divider()
            Button("Browse Applications…") {
                appSelection = nil
                chooseApp()
            }
        }
        .padding(12)
        .frame(width: 270)
    }

    private func defaultRow(_ kind: DisplayKind, icon: String) -> some View {
        HStack {
            Label(kind.title, systemImage: icon)
            Spacer()
            Picker(kind.title, selection: Binding(get: { controller.settings.displays[kind] ?? .system },
                                                   set: { controller.setDefault($0, for: kind) })) {
                ForEach(BarMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 145)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func appPicker(_ app: BarSettings.AppRule, kind: DisplayKind) -> some View {
        Picker("\(app.name): \(kind.title)", selection: Binding(get: { app.modes[kind] },
                                                                set: { controller.setAppMode($0, for: app.id, kind: kind) })) {
            Text("Follow Display").tag(nil as BarMode?)
            ForEach(BarMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode as BarMode?) }
        }
        .labelsHidden()
        .controlSize(.small)
    }
}
