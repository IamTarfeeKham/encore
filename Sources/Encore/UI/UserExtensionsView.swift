import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Extensions › Your Extensions: add, edit, switch on and off, and
/// remove your own JavaScript extensions.
struct UserExtensionsSettings: View {
    @ObservedObject private var store = UserExtensions.shared
    @State private var editing: UserExtensions.Ext?
    @State private var showingLog: UUID?

    var body: some View {
        SettingsCard("Your extensions") {
            SettingsNote("Write or import small JavaScript extensions that react to songs and control the player: skip things, send songs to a web address, change the volume at night and more. They run in their own engine inside the app, with no access to your files. Only add code you trust.")
            ForEach($store.items) { $ext in
                HStack(spacing: 10) {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ext.name).font(.system(size: 13, weight: .medium))
                        if let last = store.logs[ext.id]?.last {
                            Text(last).font(.system(size: 11)).foregroundStyle(last.hasPrefix("Error") ? .red : .secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("Log") { showingLog = ext.id }.disabled((store.logs[ext.id] ?? []).isEmpty)
                    Button("Edit") { editing = ext }
                    Button(role: .destructive) { store.items.removeAll { $0.id == ext.id } } label: { Image(systemName: "trash") }
                        .help("Remove")
                    Toggle("", isOn: $ext.enabled).toggleStyle(.switch).labelsHidden()
                }
                .padding(.vertical, 8)
            }
            ButtonRow {
                Button { editing = UserExtensions.Ext(name: "My Extension", code: UserExtensions.template) } label: {
                    Label("New Extension", systemImage: "plus")
                }
                Button { importFile() } label: { Label("Import .js File…", systemImage: "square.and.arrow.down") }
                Menu {
                    ForEach(UserExtensions.examples, id: \.0) { name, code in
                        Button(name) { store.items.append(.init(name: name, code: code)) }
                    }
                } label: { Label("Add an Example", systemImage: "sparkles") }
                .menuStyle(.button).fixedSize()
            }
        }
        .sheet(item: $editing) { ext in
            ExtensionEditor(ext: ext) { saved in
                if let i = store.items.firstIndex(where: { $0.id == saved.id }) { store.items[i] = saved }
                else { store.items.append(saved) }
            }
        }
        .sheet(isPresented: Binding(get: { showingLog != nil }, set: { if !$0 { showingLog = nil } })) {
            if let id = showingLog {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Log").font(.headline)
                    ScrollView {
                        Text((store.logs[id] ?? []).joined(separator: "\n"))
                            .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack { Button("Clear") { store.clearLog(id) }; Spacer(); Button("Done") { showingLog = nil }.keyboardShortcut(.defaultAction) }
                }
                .padding(18).frame(width: 520, height: 360)
            }
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.javaScript, .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let code = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let name = UserExtensions.name(in: code) ?? url.deletingPathExtension().lastPathComponent
            store.items.append(.init(name: name, code: code))
        }
    }
}

private struct ExtensionEditor: View {
    @State var ext: UserExtensions.Ext
    let save: (UserExtensions.Ext) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $ext.name).textFieldStyle(.roundedBorder).font(.system(size: 14, weight: .medium))
            TextEditor(text: $ext.code)
                .font(.system(size: 12.5, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            Text("API: encore.on(\"track\" | \"play\" | \"pause\", fn), encore.nowPlaying(), encore.player.play/pause/toggle/next/previous/seek/setVolume/like, encore.toast, encore.notify, encore.storage.get/set, await encore.fetch(url, options), console.log, setTimeout.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(ext); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(ext.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 620, height: 480)
    }
}
