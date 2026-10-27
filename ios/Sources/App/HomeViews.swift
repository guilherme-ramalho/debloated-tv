import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct TVHomeView: View {
    @ObservedObject var model: RemoteModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var editor: HomeEditor
    @State private var applying = false
    @State private var importLayout = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Profile", selection: settings.binding(\.profileID)) {
                        ForEach(settings.value.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    HomePreview(layout: settings.layout)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 10, trailing: 0)).listRowBackground(Color.clear)
                }
                Section {
                    Stepper("Dock icons: \(settings.layout.dockCount)", value: settings.layoutBinding(\.dockCount), in: 1...7)
                    NavigationLink { WallpaperView() } label: { Label("Wallpaper", systemImage: "photo") }
                    NavigationLink { HomeAppsView() } label: { Label("Apps & order", systemImage: "square.grid.2x2") }
                    NavigationLink { ProfilesView() } label: { Label("Profiles", systemImage: "person.2") }
                }
                Section {
                    EditorConnectionView(model: model)
                    if editor.ready {
                        Button("Refresh installed apps", systemImage: "arrow.clockwise") { Task {
                            do { try await editor.refresh() } catch { settings.notice = error.localizedDescription }
                        } }
                        Button("Load current TV layout", systemImage: "arrow.down.doc") { importLayout = true }
                    }
                    Button(applying ? "Applying…" : "Apply to TV", systemImage: "checkmark") {
                        applying = true
                        Task {
                            defer { applying = false }
                            do {
                                _ = try settings.backup(name: "Before applying · " + settings.profile.name)
                                try await editor.apply(settings.layout, wallpaper: settings.wallpaperData(settings.layout))
                            } catch { settings.notice = error.localizedDescription }
                        }
                    }.disabled(!editor.ready || applying || !model.ready)
                } footer: { Text("Edits are drafts on this phone until you apply them. The TV editor closes when you leave this section or background the app.") }
            }.remoteForm().navigationTitle("TV Home")
                .confirmationDialog("Replace this profile’s draft with the TV layout?", isPresented: $importLayout) {
                    Button("Load TV layout") {
                        guard let snapshot = editor.snapshot else { return }
                        do {
                            _ = try settings.backup(name: "Before loading TV layout")
                            var layout = snapshot.layout
                            if HomeLayout.validPhoto(layout.wallpaper) {
                                guard let data = snapshot.wallpaperJPEG else { throw RemoteFailure.message("The TV did not include its wallpaper. Refresh before loading this layout.") }
                                layout.wallpaper = try settings.importPhoto(data)
                            }
                            settings.editLayout { $0 = layout }
                        } catch { settings.notice = error.localizedDescription }
                    }
                }
        }
    }
}

struct EditorConnectionView: View {
    @ObservedObject var model: RemoteModel
    @EnvironmentObject private var editor: HomeEditor
    @State private var code = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(editor.ready ? "TV editor connected" : "TV editor", systemImage: editor.ready ? "checkmark.shield" : "tv")
            Text(editor.message).font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button(editor.busy ? "Connecting…" : "Connect editor") { editor.connect(model: model) }
                Button("Pair TV Home") { code = ""; editor.connect(model: model, pair: true) }
            }.disabled(editor.busy || !model.ready)
            if !model.ready { Text("TV unavailable. Local drafts remain editable.").font(.caption).foregroundStyle(.secondary) }
        }

    }
}

struct HomePreview: View {
    let layout: HomeLayout
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        ZStack {
            WallpaperSurface(id: layout.wallpaper)
            VStack(alignment: .leading) {
                Text(Date(), style: .time).font(.headline)
                Spacer()
                HStack(spacing: 5) {
                    ForEach(layout.dock, id: \.self) { id in
                        Group {
                            if let logo = settings.app(id)?.logo { Image(logo).resizable().renderingMode(.template).scaledToFit().padding(5) }
                            else { Image(systemName: "app").resizable().scaledToFit().padding(7) }
                        }.foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 30)
                            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }.padding(17)
        }.aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(.black.opacity(0.75), lineWidth: 5))
            .accessibilityElement(children: .ignore).accessibilityLabel("TV Home preview with \(layout.dock.count) dock apps")
    }
}

struct WallpaperSurface: View {
    let id: String
    @EnvironmentObject private var settings: AppSettings
    private var colors: [Color] {
        switch id {
        case "aurora": return [Color(red: 0.03, green: 0.17, blue: 0.24), Color(red: 0.15, green: 0.48, blue: 0.47), Color(red: 0.65, green: 0.62, blue: 0.48)]
        case "dusk": return [Color(red: 0.15, green: 0.19, blue: 0.33), Color(red: 0.53, green: 0.35, blue: 0.47), Color(red: 0.83, green: 0.61, blue: 0.5)]
        default: return [Color(red: 0.04, green: 0.09, blue: 0.2), Color(red: 0.14, green: 0.27, blue: 0.42), Color(red: 0.32, green: 0.39, blue: 0.55)]
        }
    }
    var body: some View {
        GeometryReader { geometry in
            if let url = settings.photoURL(id), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
            } else { LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing) }
        }
    }
}

struct WallpaperView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var photo: PhotosPickerItem?
    @State private var loading = false
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HomePreview(layout: settings.layout)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach([("quiet-night", "Quiet night"), ("aurora", "Aurora"), ("dusk", "Dusk")], id: \.0) { id, name in
                        Button { settings.editLayout { $0.wallpaper = id } } label: {
                            ZStack(alignment: .bottomLeading) {
                                WallpaperSurface(id: id)
                                HStack { Text(name); Spacer(); if settings.layout.wallpaper == id { Image(systemName: "checkmark.circle.fill") } }.padding(12)
                            }.frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 17))
                        }.buttonStyle(RemotePressStyle())
                    }
                    PhotosPicker(selection: $photo, matching: .images) { Label(loading ? "Preparing…" : "Choose a photo", systemImage: "photo.badge.plus").frame(maxWidth: .infinity, minHeight: 110) }
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 17)).disabled(loading)
                }
                Text("Wallpapers are resized to 1920 pixels and compressed below 1 MB before they can be sent to the TV.").font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }.background(Color("LaunchBackground")).navigationTitle("Wallpaper")
            .onChange(of: photo) { _, item in
                guard let item else { return }; loading = true
                Task {
                    defer { loading = false; photo = nil }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw RemoteFailure.message("Could not load this photo") }
                        let id = try settings.importPhoto(data); settings.editLayout { $0.wallpaper = id }
                    } catch { settings.notice = error.localizedDescription }
                }
            }
    }
}

struct HomeAppsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var editor: HomeEditor
    @State private var selected: RemoteApp?
    var body: some View {
        List {
            Section("Order") {
                ForEach(settings.layout.order, id: \.self) { id in
                    if let app = settings.app(id) {
                        Button { selected = app } label: {
                            HStack {
                                AppBadge(app: app)
                                VStack(alignment: .leading) { Text(app.name); Text(settings.layout.dock.contains(id) ? "In TV dock" : "Not in dock").font(.caption).foregroundStyle(.secondary) }
                                Spacer(); Image(systemName: "ellipsis").foregroundStyle(.secondary)
                            }
                        }
                    }
                }.onMove { from, to in settings.editLayout { $0.order.move(fromOffsets: from, toOffset: to) } }
            }
            let extra = settings.value.apps.filter { !settings.layout.order.contains($0.id) }
            if !extra.isEmpty {
                Section("More apps") { ForEach(extra) { app in Button("Add " + app.name, systemImage: "plus") { settings.editLayout { $0.order.append(app.id) } } } }
            }
            Section { Text("Use Edit to reorder. Hiding changes the Home layout only; uninstalling requires a connected TV and confirmation on its screen.").font(.footnote).foregroundStyle(.secondary) }
        }.remoteForm().navigationTitle("Apps & order").toolbar { EditButton() }
            .sheet(item: $selected) { app in HomeAppForm(app: app).environmentObject(settings).environmentObject(editor) }
    }
}

private struct HomeAppForm: View {
    let app: RemoteApp
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var editor: HomeEditor
    @Environment(\.dismiss) private var dismiss
    @State private var uninstall = false
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Toggle("Show on TV Home", isOn: Binding(get: { !settings.layout.hidden.contains(app.id) }, set: { visible in
                    settings.editLayout { $0.hidden.removeAll { $0 == app.id }; if !visible { $0.hidden.append(app.id) } }
                }))
                Button("Move up", systemImage: "arrow.up") { move(-1) }
                Button("Move down", systemImage: "arrow.down") { move(1) }
                Section {
                    if app.system { Text("System app · cannot uninstall") }
                    else { Button("Uninstall from TV", systemImage: "trash", role: .destructive) { uninstall = true }.disabled(!editor.ready || app.installed != true || busy) }
                } footer: { Text(editor.ready ? "The TV will ask for confirmation. Nothing is removed until you approve there." : "Connect the TV editor and sync installed apps to uninstall.") }
            }.navigationTitle(app.name).toolbar { Button("Done") { dismiss() } }
                .confirmationDialog("Uninstall \(app.name) and its local data?", isPresented: $uninstall, titleVisibility: .visible) {
                    Button("Continue on TV", role: .destructive) { busy = true; Task {
                        defer { busy = false }
                        do { try await editor.uninstall(app); dismiss() } catch { settings.notice = error.localizedDescription }
                    } }
                }
        }.presentationDetents([.medium, .large])
    }
    private func move(_ offset: Int) {
        settings.editLayout { layout in
            guard let index = layout.order.firstIndex(of: app.id) else { return }
            let target = max(0, min(layout.order.count - 1, index + offset)); layout.order.remove(at: index); layout.order.insert(app.id, at: target)
        }
    }
}

struct ProfilesView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var adding = false
    @State private var name = ""
    var body: some View {
        List {
            ForEach(settings.value.profiles) { profile in
                Button { settings.update { $0.profileID = profile.id } } label: { HStack { Label(profile.name, systemImage: "person"); Spacer(); if settings.profile.id == profile.id { Image(systemName: "checkmark") } } }
            }.onDelete { offsets in
                guard settings.value.profiles.count - offsets.count > 0 else { settings.notice = "Keep at least one profile."; return }
                settings.update { value in value.profiles.remove(atOffsets: offsets); if !value.profiles.contains(where: { $0.id == value.profileID }) { value.profileID = value.profiles.first?.id } }
            }
            Button("New profile", systemImage: "plus") { name = ""; adding = true }.disabled(settings.value.profiles.count >= 20)
            Text("Each profile’s draft is saved automatically on this phone. Switching profiles does not apply anything to the TV.").font(.footnote).foregroundStyle(.secondary)
        }.remoteForm().navigationTitle("Profiles").toolbar { EditButton() }
            .alert("New profile", isPresented: $adding) { TextField("Profile name", text: $name); Button("Create") { settings.addProfile(name) }; Button("Cancel", role: .cancel) {} }
    }
}

struct BackupsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var importing = false
    @State private var exporting = false
    @State private var document: BackupDocument?
    @State private var restoring: HomeBackup?
    var body: some View {
        List {
            Section {
                Button("Create backup", systemImage: "plus") { do { _ = try settings.backup() } catch { settings.notice = error.localizedDescription } }
                Button("Import backup", systemImage: "square.and.arrow.down") { importing = true }
            }
            Section("Saved backups") {
                ForEach(settings.backups) { backup in
                    HStack {
                        Button { restoring = backup } label: { VStack(alignment: .leading) { Text(backup.name); Text(backup.date, style: .date).font(.caption).foregroundStyle(.secondary) } }
                        Spacer()
                        Button { do { document = try BackupDocument(backup); exporting = true } catch { settings.notice = error.localizedDescription } } label: { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }.accessibilityLabel("Export " + backup.name)
                    }
                }
                if settings.backups.isEmpty { Text("No backups yet").foregroundStyle(.secondary) }
            }
        }.remoteForm().navigationTitle("Backup & restore")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 2_000_000 else { throw RemoteFailure.message("Backup exceeds 2 MB") }
                    restoring = try HomeBackup.decode(Data(contentsOf: url))
                } catch { settings.notice = error.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "TV-Home-backup") { result in if case .failure(let error) = result { settings.notice = error.localizedDescription } }
            .confirmationDialog("Restore this layout to the current profile’s draft?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible) {
                Button("Restore draft") {
                    guard let backup = restoring else { return }
                    do { _ = try settings.backup(name: "Before restoring"); try settings.restore(backup) } catch { settings.notice = error.localizedDescription }
                    restoring = nil
                }
            } message: { Text("The TV changes only when you apply the draft.") }
    }
}

extension View {
    func remoteForm() -> some View { scrollContentBackground(.hidden).background(Color("LaunchBackground")) }
}
