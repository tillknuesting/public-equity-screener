import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Share mode (⌘4): pick a card, tune it, and export a PNG sized for Threads or X.
struct ShareStudio: View {
    @Environment(ScreenerStore.self) private var store
    @AppStorage("shareTemplate") private var templateName = ShareTemplate.stock.rawValue
    @AppStorage("shareFormat") private var formatName = ShareFormat.landscape.rawValue
    @AppStorage("shareRange") private var rangeName = ShareRange.y1.rawValue
    @AppStorage("shareTheme") private var themeName = ShareTheme.solarizedDark.rawValue
    @AppStorage("shareAverages") private var averages = true
    @AppStorage("shareSpikes") private var spikes = true
    @AppStorage("shareBranding") private var branding = true
    @State private var symbol = ""
    @State private var search = ""
    @State private var title = ""
    @State private var subtitle = ""
    @State private var caption = ""
    @State private var flash: String?

    private var settings: ShareSettings {
        ShareSettings(template: ShareTemplate(rawValue: templateName) ?? .stock,
                      format: ShareFormat(rawValue: formatName) ?? .landscape,
                      range: ShareRange(rawValue: rangeName) ?? .y1,
                      theme: ShareTheme(rawValue: themeName) ?? .solarizedDark, symbol: symbol, title: title, subtitle: subtitle, caption: caption,
                      averages: averages, spikes: spikes, branding: branding)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Panel("Share card", marker: Theme.cyan) {
                ScrollView { controls.padding(12) }
            }
            .frame(width: 330)

            Panel("Preview · \(settings.format.hint)", marker: Theme.violet) {
                preview
            }
        }
        .onAppear {
            if symbol.isEmpty { symbol = store.chartSymbol ?? store.selection ?? store.topPicks.first?.id ?? store.universe.first?.symbol ?? "" }
        }
    }

    // MARK: Preview

    private var preview: some View {
        let s = settings
        return GeometryReader { geo in
            let scale = min((geo.size.width - 48) / s.format.size.width, (geo.size.height - 90) / s.format.size.height, 1.6)
            VStack(spacing: 14) {
                ShareCard(store: store, settings: s)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .scaleEffect(scale)
                    .frame(width: s.format.size.width * scale, height: s.format.size.height * scale)
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
                    .animation(Motion.ui, value: formatName)
                HStack(spacing: 8) {
                    Button { copy() } label: { Label("Copy image", systemImage: "doc.on.doc") }
                        .buttonStyle(TermButtonStyle(prominent: true))
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    Button { save() } label: { Label("Save PNG…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(TermButtonStyle())
                        .keyboardShortcut("s")
                    if let flash {
                        Text(flash).font(Theme.label(12)).foregroundStyle(Theme.green).transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Card") {
                VStack(spacing: 0) {
                    ForEach(ShareTemplate.allCases) { t in
                        Button { withAnimation(Motion.ui) { templateName = t.rawValue } } label: {
                            HStack {
                                Image(systemName: icon(t)).frame(width: 18)
                                Text(t.rawValue)
                                Spacer()
                            }
                        }
                        .buttonStyle(TermButtonStyle(selected: settings.template == t))
                    }
                }
            }

            if settings.template.needsSymbol {
                section("Stock") { symbolPicker }
            }

            if settings.template != .matches {
                section("Range") {
                    HStack(spacing: 0) {
                        ForEach(ShareRange.allCases) { r in
                            Button(r.rawValue) { withAnimation(Motion.ui) { rangeName = r.rawValue } }
                                .buttonStyle(TermButtonStyle(selected: settings.range == r, compact: true))
                        }
                    }
                }
            }

            section("Format") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 0) {
                        ForEach(ShareFormat.allCases) { f in
                            Button(f.rawValue) { withAnimation(Motion.ui) { formatName = f.rawValue } }
                                .buttonStyle(TermButtonStyle(selected: settings.format == f, compact: true))
                        }
                    }
                    Text(settings.format.hint).font(Theme.label(11.5)).foregroundStyle(Theme.muted)
                }
            }

            section("Theme") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(ShareTheme.allCases) { t in
                        ThemeSwatch(theme: t, selected: settings.theme == t) {
                            withAnimation(Motion.ui) { themeName = t.rawValue }
                        }
                    }
                }
            }

            section("Text") {
                VStack(alignment: .leading, spacing: 6) {
                    field("Title (automatic when empty)", text: $title)
                    field("Subtitle (automatic when empty)", text: $subtitle)
                    TextField("Caption under the chart", text: $caption, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.plain)
                        .font(Theme.label(13))
                        .padding(7)
                        .background(Theme.panel, in: Rectangle())
                        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
                }
            }

            section("Show") {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.template == .stock { Toggle("50- and 200-day averages", isOn: $averages) }
                    if settings.template == .stock || settings.template == .vol {
                        Toggle("\(VolIndex.current.name) spike markers", isOn: $spikes)
                    }
                    Toggle("Branding, data source and disclaimer", isOn: $branding)
                }
                .toggleStyle(CheckToggleStyle())
            }

            Text("Cards show data only. The footer notes the source, the date and that this is not investment advice.")
                .font(Theme.label(11.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var symbolPicker: some View {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let pool = query.isEmpty
            ? (store.topPicks.map(\.instrument) + store.visibleResults.prefix(8).map(\.instrument))
            : store.universe.filter { $0.symbol.lowercased().contains(query) || $0.name.lowercased().contains(query) }
        var seen = Set<String>()
        let list = pool.filter { seen.insert($0.symbol).inserted }.prefix(8)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(store.universe.first { $0.symbol == symbol }.map { "\($0.flag) \($0.name)" } ?? symbol)
                    .font(Theme.label(14, .semibold)).foregroundStyle(Theme.bright).lineLimit(1)
                Text(symbol).font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            field("Search \(store.universeKind.shortTitle)", text: $search)
            VStack(spacing: 0) {
                ForEach(Array(list), id: \.symbol) { inst in
                    Button {
                        symbol = inst.symbol
                        search = ""
                    } label: {
                        HStack(spacing: 6) {
                            Text(inst.symbol).font(Theme.mono(11, .bold)).foregroundStyle(Theme.bright).frame(width: 70, alignment: .leading)
                            Text(inst.name).font(Theme.label(12.5)).foregroundStyle(Theme.strong).lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 4).padding(.horizontal, 6)
                        .background(inst.symbol == symbol ? Theme.selection.opacity(0.18) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if query.isEmpty {
                Text("Top matches and the highest scores; type to search the whole universe.")
                    .font(Theme.label(11)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) { Caption(title, color: Theme.accent); Theme.border.frame(height: 1) }
            content()
        }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(Theme.label(13))
            .padding(7)
            .background(Theme.panel, in: Rectangle())
            .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
    }

    private func icon(_ t: ShareTemplate) -> String {
        switch t {
        case .stock: "chart.xyaxis.line"
        case .compare: "arrow.left.arrow.right"
        case .vol: "waveform.path.ecg"
        case .matches: "list.number"
        }
    }

    // MARK: Export

    private func copy() {
        guard let png = ShareRenderer.png(store: store, settings: settings) else { return show("Couldn't render the card") }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(png, forType: .png)
        if let image = NSImage(data: png), let tiff = image.tiffRepresentation { board.setData(tiff, forType: .tiff) }
        show("Copied. Paste it into your post.")
    }

    private func save() {
        guard let png = ShareRenderer.png(store: store, settings: settings) else { return show("Couldn't render the card") }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ShareRenderer.fileName(settings)
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
            show("Saved \(url.lastPathComponent)")
        } catch {
            show("Couldn't save: \(error.localizedDescription)")
        }
    }

    private func show(_ text: String) {
        withAnimation(Motion.ui) { flash = text }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(Motion.ui) { if flash == text { flash = nil } }
        }
    }
}

/// A small preview of a theme: its background, a line in its chart colour and its type.
private struct ThemeSwatch: View {
    let theme: ShareTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let p = theme.palette
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [p.top, p.bottom], startPoint: .top, endPoint: .bottom)
                    Path { path in
                        path.move(to: CGPoint(x: 3, y: 17))
                        path.addCurve(to: CGPoint(x: 31, y: 5), control1: CGPoint(x: 12, y: 4), control2: CGPoint(x: 20, y: 20))
                    }
                    .stroke(p.line, lineWidth: 1.6)
                    Text("Aa").font(p.title(9)).foregroundStyle(p.text).padding(3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .frame(width: 34, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: max(p.radius / 3, 1)))
                .overlay(RoundedRectangle(cornerRadius: max(p.radius / 3, 1)).stroke(Theme.border, lineWidth: 1))
                Text(theme.rawValue).font(Theme.label(12.5, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.bright : Theme.strong).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(5)
            .background(selected ? Theme.selection.opacity(0.18) : Color.clear)
            .overlay(Rectangle().stroke(selected ? Theme.selection.opacity(0.8) : Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
