import SwiftUI
import AppKit
import LanternCore

@main
struct LanternApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        WindowGroup("Lantern", id: "main") { MainView(model: model).frame(minWidth: 900, minHeight: 630) }
            .defaultSize(width: 1080, height: 740)
        MenuBarExtra("Lantern", systemImage: model.sharing ? "tv.and.mediabox.fill" : "tv") {
            Text(model.status)
            Button(model.sharing ? "Stop Sharing" : "Start Sharing") { model.sharing ? model.stop() : model.start() }.disabled(model.busy || model.starting)
            Divider()
            Button("Show Lantern") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title == "Lantern" }) { window.makeKeyAndOrderFront(nil) }
                else { openWindow(id: "main") }
            }
            Button("Quit Lantern") { model.stop(); NSApp.terminate(nil) }
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "tv.and.mediabox.fill").font(.system(size: 32)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lantern").font(.largeTitle.bold())
                    Text("Your videos. Your TV. Your network.").foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy || model.starting { ProgressView().controlSize(.small) }
                Label(model.sharing ? "Sharing" : "Not sharing", systemImage: model.sharing ? "circle.fill" : "circle")
                    .foregroundStyle(model.sharing ? Color.green : Color.secondary)
                Button(model.sharing ? "Stop Sharing" : "Start Sharing") { model.sharing ? model.stop() : model.start() }
                    .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
                    .disabled(model.busy || model.starting || model.library == nil)
            }.padding(24)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("SHARED LIBRARY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Label(model.folder.lastPathComponent, systemImage: "folder.fill").font(.headline)
                    Text(model.folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("Choose Folder…", action: model.chooseFolder)
                        Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }.help("Refresh library")
                    }.disabled(model.busy || model.starting)
                    Divider()
                    Text("LOCAL NETWORK").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("Interface", selection: $model.interfaceID) {
                        ForEach(model.interfaces) { Text($0.label).tag($0.id) }
                    }.labelsHidden().disabled(model.sharing || model.starting)
                    Button("Refresh Networks", action: model.refreshInterfaces).disabled(model.sharing || model.starting)
                    Text("Devices on this network can browse this folder while sharing is on. Use a trusted home network, not public Wi-Fi.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("ON YOUR SAMSUNG TV").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("1. Connect to the same home network.\n\n2. Open Connected Devices or Sources.\n\n3. Choose Lantern and browse your videos.\n\n4. Enable subtitles in the player's options.").font(.callout)
                    Spacer()
                    Label("Mac stays awake while sharing", systemImage: "moon.zzz").font(.caption)
                    Text("Keep the lid open. Allow Local Network access if macOS asks.").font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(minWidth: 230, idealWidth: 260, maxWidth: 300)
                VStack(spacing: 0) {
                    HStack {
                        TextField("Search videos", text: $model.search).textFieldStyle(.roundedBorder)
                        Text("\(model.videos.count) videos").font(.caption).foregroundStyle(.secondary)
                    }.padding(16)
                    List(selection: $model.selection) {
                        ForEach(model.videos) { item in
                            HStack(spacing: 12) {
                                Image(systemName: "film").foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).lineLimit(2)
                                    Text("\(item.url.pathExtension.uppercased()) · \(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)) · \(item.url.deletingLastPathComponent().lastPathComponent)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if item.subtitle != nil { Image(systemName: "captions.bubble.fill").foregroundStyle(.green).help("External subtitles ready") }
                            }.padding(.vertical, 5).tag(item.id)
                        }
                    }.onChange(of: model.selection) { _ in model.inspectSelection() }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Subtitles", systemImage: "captions.bubble").font(.headline)
                            Spacer()
                            if let preparation = model.preparation {
                                Button("Cancel After Current Video") { preparation.cancel() }
                            }
                            Button("Prepare English for Library", action: model.prepareEnglish).disabled(model.busy || model.starting || model.library == nil)
                        }
                        if let item = model.selected {
                            Text(item.title).font(.subheadline).lineLimit(1)
                            Text(model.detailStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            HStack {
                                Picker("Track", selection: $model.subtitleIndex) {
                                    Text("Choose a text subtitle track").tag(-1)
                                    ForEach(model.textTracks) { Text($0.label).tag($0.index) }
                                }
                                Button("Use on TV", action: model.prepareSelected).disabled(model.busy || model.starting || model.subtitleIndex < 0)
                            }
                        } else {
                            Text("Embedded subtitles are kept in the original stream. Prepare English subtitles to also provide Samsung-compatible SRT sidecars.").font(.callout).foregroundStyle(.secondary)
                        }
                        Text("Matching .srt files are shared automatically. Preparation uses a cache, never edits originals, and briefly restarts sharing. Burn-in is not available in this build; image subtitles and unsupported audio may need conversion.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(16)
                }.frame(minWidth: 560)
            }
            Divider()
            HStack {
                Text(model.status).lineLimit(1)
                Spacer()
                Text(model.address).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Activity") { model.showActivity.toggle() }
            }.padding(12).font(.callout)
        }
        .alert("Lantern", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
        .sheet(isPresented: $model.showActivity) {
            VStack(alignment: .leading) {
                HStack { Text("Activity").font(.title2.bold()); Spacer(); Button("Done") { model.showActivity = false } }
                ScrollView { Text(model.logs.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(20).frame(width: 780, height: 430)
        }
    }
}
