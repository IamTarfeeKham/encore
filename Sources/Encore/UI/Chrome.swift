import SwiftUI

// MARK: - Top bar

/// Window top bar: sidebar toggle, logo and back/forward on the left, search in
/// the centre, settings and account on the right.
struct TopBar: View {
    @EnvironmentObject var model: AppModel

    /// Visual gap between neighbouring glyphs, used throughout the bar.
    static let gap: CGFloat = 20
    /// Space between the search field and the groups either side of it.
    static let searchMargin: CGFloat = 28
    /// Where the first glyph starts: one gap after the (enlarged) zoom button.
    static var firstGlyphX: CGFloat {
        typealias T = WindowConfigurator.TrafficLights
        return T.left + 2 * T.spacing + (14 * T.scale).rounded() + gap
    }

    var body: some View {
        // Left group · search · right group, with the SAME gap on both sides of the
        // search field; it fills the space between the groups (up to a generous cap,
        // centred in that space when capped), so there is never a lopsided gap.
        HStack(spacing: 0) {
            left.fixedSize()
            HStack(spacing: 0) {
                Spacer(minLength: Self.searchMargin)
                SearchField().frame(maxWidth: 900)
                Spacer(minLength: Self.searchMargin)
            }
            .frame(maxWidth: .infinity)
            right.fixedSize()
        }
        .padding(.horizontal, 14)
        // Window buttons follow this row's real vertical centre.
        .background(GeometryReader { g in
            Color.clear
                .onAppear { WindowConfigurator.TrafficLights.align(toRowMidY: g.frame(in: .global).midY) }
                .onChange(of: g.frame(in: .global).midY) { _, y in WindowConfigurator.TrafficLights.align(toRowMidY: y) }
        })
    }

    private var left: some View {
        HStack(spacing: 0) {
            // 14 = bar padding, 6 = the sidebar glyph's inset inside its 30 pt circle.
            Color.clear.frame(width: Self.firstGlyphX - 14 - 6)
            Button { withAnimation(.easeInOut(duration: 0.3)) { model.sidebarVisible.toggle() } } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(BarIconStyle(size: 14))
            .hoverTip(model.sidebarVisible ? "Hide sidebar" : "Show sidebar", edge: .bottom)
            AppLogo()
                .onTapGesture { model.goHome() }
                .hoverTip("Home", edge: .bottom)
                .padding(.leading, Self.gap - 6)
                .padding(.trailing, Self.gap - 6.5)
            NavButtons()
        }
    }

    private var right: some View {
        HStack(spacing: 0) {
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(BarIconStyle(size: 14))
                .hoverTip("Refresh", edge: .bottom)
            Button { model.showNowPlaying = false; model.selection = model.selection == .settings ? .home : .settings } label: {
                Image(systemName: model.selection == .settings ? "gearshape.fill" : "gearshape")
            }
            .buttonStyle(BarIconStyle(size: 14))
            .hoverTip("Settings", edge: .bottom)
            .padding(.leading, Self.gap - 14)
            AccountButton()
                .padding(.leading, Self.gap - 7)
        }
        .padding(.trailing, 6)   // avatar edge 20 pt from the window edge, like the window buttons
    }

}

/// The app mark: a music note in YouTube red on a tile that follows light/dark
/// mode — the same drawing as the Dock icon (AppIcon.swift) and the menu-bar note.
struct AppMark: View {
    var size: CGFloat = 24
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(scheme == .dark
                      ? LinearGradient(colors: [Color(white: 0.2), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
                      : LinearGradient(colors: [.white, Color(white: 0.9)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            Image(systemName: "music.note")
                .font(.system(size: size * 0.56, weight: .bold))
                .foregroundStyle(Color(red: 1, green: 0, blue: 0))
                .offset(x: -size * 0.02)
        }
        .frame(width: size, height: size)
    }
}

struct AppLogo: View {
    var body: some View {
        HStack(spacing: 8) {
            AppMark(size: 24)
            Text(AppInfo.name).font(.system(size: 14, weight: .bold)).tracking(-0.2).lineLimit(1)
        }
        .fixedSize()
        .contentShape(Rectangle())
    }
}

struct NavButtons: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        // Chevrons are narrow glyphs, so they get smaller circles and tighter
        // spacing: every glyph-to-glyph gap comes out the same as the rest of the bar.
        HStack(spacing: 0) {
            Button { model.goHome() } label: { Image(systemName: "house") }
                .buttonStyle(BarIconStyle(size: 13))
                .hoverTip("Home", edge: .bottom)
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(BarIconStyle(size: 13, diameter: 26))
                .disabled(!model.canGoBack)
                .hoverTip("Back", edge: .bottom)
                .padding(.leading, TopBar.gap - 6.5 - 9)
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(BarIconStyle(size: 13, diameter: 26))
                .disabled(!model.canGoForward)
                .hoverTip("Forward", edge: .bottom)
                .padding(.leading, TopBar.gap - 18)
        }
    }
}

/// Avatar that opens a small account panel (a Menu would render the photo full-size).
struct AccountButton: View {
    @EnvironmentObject var model: AppModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Group {
                if let url = model.account?.avatar {
                    Artwork(url: url, cornerRadius: 15, symbol: "person.fill", size: 30)
                } else {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)
            .overlay(Circle().strokeBorder(.white.opacity(open ? 0.6 : 0.15), lineWidth: 1))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverTip(model.account?.name ?? "Account", edge: .bottom)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if let a = model.account {
                    HStack(spacing: 10) {
                        Artwork(url: a.avatar, cornerRadius: 20, symbol: "person.fill", size: 40).frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.system(size: 13, weight: .semibold))
                            if let h = a.handle { Text(h).font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.bottom, 6)
                    Divider()
                    PopoverRow("Refresh Library", "arrow.clockwise") { open = false; Task { await model.refreshAccount() } }
                    PopoverRow("Settings", "gearshape") { open = false; model.selection = .settings }
                    PopoverRow("Sign Out", "rectangle.portrait.and.arrow.right") {
                        open = false
                        Task { await WebBridge.shared.signOut(); model.account = nil; model.playlists = []; model.signedIn = false }
                    }
                } else {
                    PopoverRow("Sign In…", "person.crop.circle") { open = false; model.showSignIn = true }
                    PopoverRow("Settings", "gearshape") { open = false; model.selection = .settings }
                }
            }
            .padding(12)
            .frame(width: 240)
        }
    }
}

struct PopoverRow: View {
    let title: String, symbol: String, action: () -> Void
    @State private var hover = false
    init(_ title: String, _ symbol: String, action: @escaping () -> Void) { self.title = title; self.symbol = symbol; self.action = action }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(title)
            Spacer()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.accentColor.opacity(0.25) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
    }
}

// MARK: - Settings sidebar

struct SettingsSidebar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarRow(title: "Back to Music", symbol: "chevron.backward", roomy: true, selected: false) {
                withAnimation(.easeInOut(duration: 0.25)) { model.selection = .home }
            }
            Text("Settings").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 22).padding(.bottom, 6)
            ForEach(SettingsView.Section.allCases) { s in
                SidebarRow(title: s.rawValue, symbol: s.symbol, roomy: true, selected: model.settingsSection == s) {
                    withAnimation(.easeInOut(duration: 0.2)) { model.settingsSection = s }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 14)
    }
}

// MARK: - Hover tooltips

/// Shows a small label next to a control after the pointer rests on it briefly.
/// The label is kept inside the window: near the right edge it grows leftwards,
/// near the left edge rightwards.
struct HoverTip: ViewModifier {
    let text: String
    var edge: VerticalEdge = .top
    @State private var shown = false
    @State private var pending: DispatchWorkItem?
    @State private var align: HorizontalAlignment = .center

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear.onChange(of: shown) {
                    guard shown, let w = NSApp.keyWindow?.contentView?.bounds.width ?? NSApp.mainWindow?.contentView?.bounds.width else { return }
                    let f = g.frame(in: .global)
                    let est = CGFloat(text.count) * 6.6 + 24
                    align = f.midX + est / 2 > w - 8 ? .trailing : (f.midX - est / 2 < 8 ? .leading : .center)
                }
            })
            .onHover { inside in
                pending?.cancel()
                if inside {
                    let work = DispatchWorkItem { withAnimation(.easeOut(duration: 0.15)) { shown = true } }
                    pending = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
                } else if shown {
                    withAnimation(.easeOut(duration: 0.1)) { shown = false }
                }
            }
            .overlay(alignment: Alignment(horizontal: align, vertical: edge == .top ? .top : .bottom)) {
                if shown {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.85)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                        .fixedSize()
                        .alignmentGuide(HorizontalAlignment.trailing) { d in d[.trailing] }
                        .offset(y: edge == .top ? -34 : 34)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        .zIndex(100)
                }
            }
    }
}

extension View {
    func hoverTip(_ text: String, edge: VerticalEdge = .top) -> some View { modifier(HoverTip(text: text, edge: edge)) }
}

// MARK: - Capsule dropdown

/// A dropdown with the same rounded-capsule look as the app's buttons.
struct PillMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { v, title in
                Button { selection = v } label: {
                    if v == selection { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.0 == selection }?.1 ?? "")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.09)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.6))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
