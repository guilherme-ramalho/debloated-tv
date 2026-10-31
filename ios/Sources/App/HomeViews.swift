import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct TVHomeView: View {
    @ObservedObject var model: RemoteModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var editor: HomeEditor
    @State private var applying = false
    @State private var importLayout = false
    @State private var addingProfile = false
    @State private var profileName = ""
    private var wallpaperName: String { switch settings.layout.wallpaper { case "quiet-night": return "Quiet night"; case "aurora": return "Aurora"; case "dusk": return "Dusk"; default: return "Photo" } }
    var body: some View {
        NavigationStack {
            QuietPage {
                QuietHeading(title: "TV") { EmptyView() }
                HStack {
                    Menu {
                        ForEach(settings.value.profiles) { profile in
                            Button { settings.update { $0.profileID = profile.id } } label: {
                                if settings.profile.id == profile.id { Label(profile.name, systemImage: "checkmark") } else { Text(profile.name) }
                            }
                        }
                    } label: {
                        HStack(spacing: 12) { Text(settings.profile.name); Image(systemName: "chevron.down").font(.caption) }
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 12).frame(minHeight: 44)
                            .background(Color(red: 29/255, green: 45/255, blue: 70/255), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(QuietTheme.edge, lineWidth: 1))
                    }.accessibilityLabel("Launcher profile").accessibilityValue(settings.profile.name)
                    Spacer()
                    Button("New profile", systemImage: "plus") { addingProfile = true }.font(.system(size: 13)).foregroundStyle(QuietTheme.cyan).frame(minHeight: 44)
                }
                HomePreview(layout: settings.layout)
                QuietCard {
                    HStack {
                        Text("Dock icons").font(.system(size: 14, weight: .medium)); Spacer()
                        QuietCounter(label: "dock icons", value: settings.layoutBinding(\.dockCount), range: 1...7)
                    }.padding(13).frame(minHeight: 61)
                }
                QuietCard {
                    NavigationLink { WallpaperView() } label: { QuietRow(title: "Wallpaper", symbol: "photo", value: wallpaperName) }
                    Divider().overlay(QuietTheme.edge)
                    NavigationLink { HomeAppsView() } label: { QuietRow(title: "Apps & order", detail: "Reorder, hide or uninstall", symbol: "square.grid.2x2") }
                    Divider().overlay(QuietTheme.edge)
                    NavigationLink { ProfilesView() } label: { QuietRow(title: "Profiles", detail: "Save a layout for each person", symbol: "person.2") }
                }.buttonStyle(.plain)
                Button(applying ? "Applying…" : "Apply to TV", systemImage: "checkmark") {
                    applying = true
                    Task { _ = await editor.applyDraft(settings); applying = false }
                }.buttonStyle(QuietPrimaryStyle()).disabled(!editor.ready || applying || !model.ready)
                QuietCaption(text: "Edits are saved on this phone until you apply them to the TV.")
                QuietCard(spacing: 12) {
                    EditorConnectionView(model: model).padding(14)
                    if editor.ready {
                        Button("Refresh installed apps", systemImage: "arrow.clockwise") { Task { do { try await editor.refresh() } catch { settings.notice = error.localizedDescription } } }.padding(.horizontal, 14)
                        Button("Load current TV layout", systemImage: "arrow.down.doc") { importLayout = true }.padding([.horizontal, .bottom], 14)
                    }
                }
            }.toolbar(.hidden, for: .navigationBar)
                .alert("New profile", isPresented: $addingProfile) {
                    TextField("Profile name", text: $profileName)
                    Button("Cancel", role: .cancel) { profileName = "" }
                    Button("Create") { settings.addProfile(profileName); profileName = "" }
                }
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

/// TV Home connects by itself when Home is in front on the TV. With an app or input on screen it asks first, because
/// opening the editor can pause what's playing. No Pair or Connect step (docs/launcher-editor-contract.md).
struct EditorConnectionView: View {
    @ObservedObject var model: RemoteModel
    @EnvironmentObject private var editor: HomeEditor
    private var tvState: String { "\(model.ready)|\(model.powerOn.map { $0 ? "on" : "off" } ?? "?")|\(model.foregroundPackage)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(editor.ready ? "Connected to TV Home" : (editor.busy ? "Connecting to TV Home…" : "TV Home"),
                  systemImage: editor.ready ? "checkmark.shield" : "tv")
            Text(editor.message).font(.footnote).foregroundStyle(.secondary)
            if editor.waitingFor != nil {
                Button("Connect now", systemImage: "link") { editor.connect(model: model, force: true) }.buttonStyle(QuietPrimaryStyle())
            } else if !editor.ready && !editor.busy && model.ready && model.powerOn != false {
                Button("Try again", systemImage: "arrow.clockwise") { editor.connect(model: model, force: true) }.buttonStyle(QuietSecondaryStyle())
            }
            if !model.ready { Text("TV unavailable. Local drafts remain editable.").font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { editor.autoConnect(model: model) }
        .task(id: tvState) { editor.autoConnect(model: model) }
    }
}

struct HomePreview: View {
    let layout: HomeLayout
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        ZStack {
            WallpaperSurface(id: layout.wallpaper)
            VStack(alignment: .leading) {
                HStack {
                    Text(Date(), style: .time).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(settings.profile.name).font(.system(size: 12))
                }.foregroundStyle(.white).shadow(radius: 3)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(layout.dock, id: \.self) { id in
                        StreamingLogo(app: settings.app(id))
                            .frame(maxWidth: .infinity).frame(height: 18).padding(.vertical, 5).padding(.horizontal, 5)
                            .background(StreamingBrand.color(id), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }.padding(.horizontal, 15).padding(.vertical, 15)
        }.aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(red: 5/255, green: 11/255, blue: 20/255), lineWidth: 5))
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
    @EnvironmentObject private var editor: HomeEditor
    @State private var photo: PhotosPickerItem?
    @State private var loading = false
    @State private var applying = false
    @State private var framing: FramingPhoto?
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
                if HomeLayout.validPhoto(settings.layout.wallpaper) {
                    Button("Adjust photo framing", systemImage: "crop") {
                        if let image = settings.framingSource(settings.layout.wallpaper) { framing = FramingPhoto(image: image) }
                    }.buttonStyle(QuietSecondaryStyle())
                }
                Button(applying ? "Applying…" : "Apply to TV", systemImage: "checkmark") {
                    applying = true
                    Task { _ = await editor.applyDraft(settings); applying = false }
                }.buttonStyle(QuietPrimaryStyle()).disabled(!editor.ready || applying)
                QuietCaption(text: editor.ready ? "Applies this profile's whole Home draft, wallpaper included." : editor.message)
                Text("Presets are drawn by the TV and use no picture memory. Photos are sent at 1280×720.").font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }.background(Color("LaunchBackground")).navigationTitle("Wallpaper")
            .onChange(of: photo) { _, item in
                guard let item else { return }; loading = true
                Task {
                    defer { loading = false; photo = nil }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw RemoteFailure.message("Could not load this photo") }
                        framing = FramingPhoto(image: try AppSettings.framingImage(data))
                    } catch { settings.notice = error.localizedDescription }
                }
            }
            .fullScreenCover(item: $framing) { item in
                WallpaperFramingView(image: item.image, canApply: editor.ready) { crop, apply in
                    do {
                        let id = try settings.saveFramedPhoto(item.image, crop: crop)
                        settings.editLayout { $0.wallpaper = id }
                        framing = nil
                        if apply { applying = true; Task { _ = await editor.applyDraft(settings); applying = false } }
                    } catch { settings.notice = error.localizedDescription }
                } cancel: { framing = nil }
            }
    }
}

struct FramingPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Drag and pinch a photo inside the TV's 16:9 frame. The dock and clock are sketched on top, so it's clear what
/// the tiles will cover. Hands back the visible part as a rect in the image's pixels.
struct WallpaperFramingView: View {
    let image: UIImage
    let canApply: Bool
    let done: (CGRect, Bool) -> Void
    let cancel: () -> Void
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    @State private var frameWidth: CGFloat = 1

    private var pixelSize: CGSize { CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale) }
    /// Points per image pixel when the photo just covers the frame, times the zoom.
    private func pointsPerPixel(_ width: CGFloat) -> CGFloat {
        let fill = max(width / pixelSize.width, width * 9 / 16 / pixelSize.height)
        return fill * zoom
    }
    private func clamped(_ proposed: CGSize, width: CGFloat) -> CGSize {
        let k = pointsPerPixel(width)
        let maxX = max(0, (pixelSize.width * k - width) / 2), maxY = max(0, (pixelSize.height * k - width * 9 / 16) / 2)
        return CGSize(width: min(maxX, max(-maxX, proposed.width)), height: min(maxY, max(-maxY, proposed.height)))
    }
    private var crop: CGRect {
        let k = pointsPerPixel(frameWidth)
        let size = CGSize(width: frameWidth / k, height: frameWidth * 9 / 16 / k)
        let center = CGPoint(x: pixelSize.width / 2 - offset.width / k, y: pixelSize.height / 2 - offset.height / k)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("Drag to move and pinch to zoom. The tiles show what the dock will cover.")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let k = pointsPerPixel(width)
                    ZStack {
                        Image(uiImage: image).resizable().interpolation(.medium)
                            .frame(width: pixelSize.width * k, height: pixelSize.height * k)
                            .offset(offset)
                        FramingGuide()
                    }
                    .frame(width: width, height: width * 9 / 16).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.35), lineWidth: 1))
                    .contentShape(Rectangle())
                    .gesture(DragGesture()
                        .onChanged { value in
                            offset = clamped(CGSize(width: settledOffset.width + value.translation.width, height: settledOffset.height + value.translation.height), width: width)
                        }
                        .onEnded { _ in settledOffset = offset })
                    .simultaneousGesture(MagnificationGesture()
                        .onChanged { value in zoom = min(4, max(1, settledZoom * value)); offset = clamped(offset, width: width) }
                        .onEnded { _ in settledZoom = zoom; settledOffset = offset })
                    .onAppear { frameWidth = width }
                    .onChange(of: width) { _, new in frameWidth = new; offset = clamped(offset, width: new); settledOffset = offset }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                Button("Reset framing", systemImage: "arrow.counterclockwise") {
                    withAnimation(.easeOut(duration: 0.2)) { zoom = 1; settledZoom = 1; offset = .zero; settledOffset = .zero }
                }.font(.footnote).foregroundStyle(QuietTheme.cyan)
                Spacer()
                if canApply {
                    Button("Apply to TV", systemImage: "checkmark") { done(crop, true) }.buttonStyle(QuietPrimaryStyle())
                    Button("Save to draft") { done(crop, false) }.buttonStyle(QuietSecondaryStyle())
                } else {
                    Button("Save to draft", systemImage: "checkmark") { done(crop, false) }.buttonStyle(QuietPrimaryStyle())
                    QuietCaption(text: "Connect to TV Home from the TV tab to apply it.")
                }
            }
            .padding(20).background(Color("LaunchBackground")).navigationTitle("Frame wallpaper").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) } }
        }.preferredColorScheme(.dark)
    }
}

/// A light sketch of Home over the photo: the clock corner and the dock row.
private struct FramingGuide: View {
    var body: some View {
        GeometryReader { g in
            VStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.55)).frame(width: g.size.width * 0.12, height: g.size.height * 0.05)
                Spacer()
                HStack(spacing: g.size.width * 0.012) {
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.22))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.35), lineWidth: 0.5))
                            .frame(height: g.size.height * 0.16)
                    }
                }
            }.padding(g.size.width * 0.04)
        }.allowsHitTesting(false)
    }
}

struct HomeAppsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var editor: HomeEditor
    @State private var selected: RemoteApp?
    var body: some View {
        List {
                Group {
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

                }.listRowBackground(QuietTheme.panel)
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
                Group {
                Toggle("Show on TV Home", isOn: Binding(get: { !settings.layout.hidden.contains(app.id) }, set: { visible in
                    settings.editLayout { $0.hidden.removeAll { $0 == app.id }; if !visible { $0.hidden.append(app.id) } }
                }))
                Button("Move up", systemImage: "arrow.up") { move(-1) }
                Button("Move down", systemImage: "arrow.down") { move(1) }
                Section {
                    if app.system { Text("System app · cannot uninstall") }
                    else { Button("Uninstall from TV", systemImage: "trash", role: .destructive) { uninstall = true }.disabled(!editor.ready || app.installed != true || busy) }
                } footer: { Text(editor.ready ? "The TV will ask for confirmation. Nothing is removed until you approve there." : "Open the TV tab with the TV on to sync installed apps before uninstalling.") }

                }.listRowBackground(QuietTheme.panel)
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
                Group {
            ForEach(settings.value.profiles) { profile in
                Button { settings.update { $0.profileID = profile.id } } label: { HStack { Label(profile.name, systemImage: "person"); Spacer(); if settings.profile.id == profile.id { Image(systemName: "checkmark") } } }
            }.onDelete { offsets in
                guard settings.value.profiles.count - offsets.count > 0 else { settings.notice = "Keep at least one profile."; return }
                settings.update { value in value.profiles.remove(atOffsets: offsets); if !value.profiles.contains(where: { $0.id == value.profileID }) { value.profileID = value.profiles.first?.id } }
            }
            Button("New profile", systemImage: "plus") { name = ""; adding = true }.disabled(settings.value.profiles.count >= 20)
            Text("Each profile’s draft is saved automatically on this phone. Switching profiles does not apply anything to the TV.").font(.footnote).foregroundStyle(.secondary)

                }.listRowBackground(QuietTheme.panel)
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
                Group {
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

                }.listRowBackground(QuietTheme.panel)
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
    func remoteForm() -> some View { scrollContentBackground(.hidden).background(QuietTheme.background).tint(QuietTheme.cyan).toolbar(.visible, for: .navigationBar).toolbarBackground(QuietTheme.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar) }
}
