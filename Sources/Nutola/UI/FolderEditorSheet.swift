import SwiftUI

enum FolderIconCatalog {
    static let symbols: [String] = [
        "folder.fill", "person.fill", "person.2.fill", "person.3.fill",
        "heart.fill", "star.fill", "flag.fill", "bookmark.fill",
        "briefcase.fill", "building.2.fill", "house.fill", "graduationcap.fill",
        "lightbulb.fill", "brain.head.profile", "cpu.fill", "gearshape.fill",
        "wrench.and.screwdriver.fill", "hammer.fill", "paintbrush.fill", "pencil",
        "doc.text.fill", "note.text", "calendar", "clock.fill",
        "bell.fill", "envelope.fill", "phone.fill", "video.fill",
        "mic.fill", "speaker.wave.2.fill", "music.note", "headphones",
        "camera.fill", "photo.fill", "film.fill", "tv.fill",
        "gamecontroller.fill", "sportscourt.fill", "figure.run", "bicycle",
        "car.fill", "airplane", "globe.americas.fill", "map.fill",
        "location.fill", "mappin.and.ellipse", "cloud.fill", "sun.max.fill",
        "moon.fill", "sparkles", "bolt.fill", "flame.fill",
        "leaf.fill", "tree.fill", "pawprint.fill", "hare.fill",
        "ant.fill", "ladybug.fill", "fish.fill", "bird.fill",
        "cross.case.fill", "pills.fill", "heart.text.square.fill", "stethoscope",
        "dollarsign.circle.fill", "chart.line.uptrend.xyaxis", "chart.bar.fill", "creditcard.fill",
        "cart.fill", "bag.fill", "gift.fill", "tag.fill",
        "lock.fill", "key.fill", "shield.fill", "checkmark.seal.fill",
        "exclamationmark.triangle.fill", "questionmark.circle.fill", "info.circle.fill", "hand.raised.fill",
        "hands.clap.fill", "hand.thumbsup.fill", "face.smiling.fill", "theatermasks.fill",
        "book.fill", "books.vertical.fill", "newspaper.fill", "magazine.fill",
        "puzzlepiece.fill", "cube.fill", "shippingbox.fill", "archivebox.fill",
        "tray.full.fill", "trash.fill", "arrow.triangle.2.circlepath", "infinity",
    ]

    static let emojiSections: [(title: String, emojis: [String])] = [
        ("Frequently used", ["👍", "👌", "🙏", "😂", "❤️", "👀", "✅", "🙂", "😃", "😁", "🤔", "😅", "⚠️", "😕", "❌", "🙌", "🎉", "😉", "😌", "🤷", "👋", "❓"]),
        ("Smileys", ["😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "😊", "😇", "🥰", "😍", "🤩", "😘", "😗", "😚", "😙", "🥲", "😋", "😛", "😜", "🤪", "😝", "🤑", "🤗", "🤭", "🤫", "🤔", "🤐", "🤨", "😐", "😑", "😶", "😏", "😒", "🙄", "😬", "😮‍💨", "🤥", "😌", "😔", "😪", "🤤", "😴", "😷", "🤒", "🤕", "🤢", "🤮", "🤧", "🥵", "🥶", "🥴", "😵", "🤯", "🤠", "🥳", "🥸", "😎", "🤓", "🧐"]),
        ("People", ["👋", "🤚", "🖐️", "✋", "🖖", "👌", "🤌", "🤏", "✌️", "🤞", "🤟", "🤘", "🤙", "👈", "👉", "👆", "👇", "☝️", "👍", "👎", "✊", "👊", "🤛", "🤜", "👏", "🙌", "👐", "🤲", "🤝", "🙏", "💪", "🦾", "🦿", "🦵", "🦶", "👂", "👃", "🧠", "👀", "👁️", "👅", "👄"]),
        ("Nature", ["🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔", "🐧", "🐦", "🐤", "🦆", "🦅", "🦉", "🦇", "🐺", "🐗", "🐴", "🦄", "🐝", "🐛", "🦋", "🐌", "🐞", "🐜", "🪲", "🐢", "🐍", "🦎", "🐙", "🦑", "🦐", "🐠", "🐟", "🐬", "🐳", "🌸", "🌺", "🌻", "🌹", "🌷", "🌱", "🌲", "🌳", "🍀", "🍁", "🍂", "☀️", "🌤️", "⛅", "🌧️", "⛈️", "❄️", "🌈", "⭐", "🔥", "💧", "🌊"]),
        ("Objects", ["⌚", "📱", "💻", "⌨️", "🖥️", "🖨️", "🖱️", "💾", "💿", "📷", "📹", "🎥", "📞", "☎️", "📺", "📻", "🎙️", "🎚️", "🎛️", "⏰", "⏱️", "🔋", "🔌", "💡", "🔦", "🕯️", "🧯", "💰", "💳", "💎", "⚖️", "🔧", "🔨", "⚒️", "🛠️", "⛏️", "🔩", "⚙️", "🔗", "⛓️", "🔫", "💣", "🔪", "🗡️", "🛡️", "🚬", "⚰️", "🏺", "🔮", "📿", "💈", "⚗️", "🔭", "🔬", "🩹", "💊", "💉", "🩺", "🚪", "🛏️", "🛋️", "🚽", "🚿", "🛁", "🧴", "🧷", "🧹", "🧺", "🧻", "🪣", "🧼", "🧽", "🧯"]),
        ("Work", ["💼", "📁", "📂", "🗂️", "📋", "📊", "📈", "📉", "🗒️", "🗓️", "📆", "📅", "📇", "🗃️", "🗄️", "📌", "📍", "✂️", "🖊️", "🖋️", "✒️", "📝", "✏️", "📎", "🖇️", "📐", "📏", "🗞️", "📰", "📓", "📔", "📒", "📕", "📗", "📘", "📙", "📚", "📖", "🔖", "🏷️", "💡", "🏢", "🏛️", "🏗️", "🧱", "🏠", "🏡", "🏘️", "🏚️", "🏭", "🏫", "🏬", "🏪", "🏨", "🏦", "🏥", "⛪", "🕌", "🕍", "⛩️"]),
        ("Activities", ["⚽", "🏀", "🏈", "⚾", "🥎", "🎾", "🏐", "🏉", "🥏", "🎱", "🏓", "🏸", "🏒", "🥅", "⛳", "🏹", "🎣", "🤿", "🥊", "🥋", "🎽", "🛹", "🛼", "⛸️", "🎿", "⛷️", "🏂", "🏋️", "🤸", "⛹️", "🤺", "🤾", "🏌️", "🏇", "🧘", "🏄", "🏊", "🚣", "🧗", "🚴", "🚵", "🎪", "🎭", "🎨", "🎬", "🎤", "🎧", "🎼", "🎹", "🥁", "🎷", "🎺", "🎸", "🎻", "🎲", "♟️", "🎯", "🎳", "🎮", "🕹️", "🎰", "🧩"]),
    ]

    static func filteredSymbols(query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return symbols }
        return symbols.filter { $0.lowercased().contains(q) }
    }

    static func filteredEmojiSections(query: String) -> [(title: String, emojis: [String])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return emojiSections }
        return emojiSections.compactMap { section in
            let filtered = section.emojis.filter { $0.contains(q) }
            return filtered.isEmpty ? nil : (section.title, filtered)
        }
    }
}

struct FolderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var title: String = "Edit folder"
    var initialName: String = ""
    var initialDescription: String = ""
    var initialKind: FolderIconKind = .symbol
    var initialValue: String = "folder.fill"
    var initialColorHex: String = "#3FB27F"
    var onSave: (String, String?, FolderIconKind, String, String) -> Void

    @State private var name: String
    @State private var descriptionText: String
    @State private var tab: Tab = .icons
    @State private var iconKind: FolderIconKind
    @State private var iconValue: String
    @State private var iconColorHex: String
    @State private var symbolQuery = ""
    @State private var emojiQuery = ""
    @FocusState private var nameFocused: Bool

    enum Tab: String, CaseIterable {
        case icons = "Icons"
        case emojis = "Emojis"
    }

    init(
        title: String = "Edit folder",
        initialName: String = "",
        initialDescription: String = "",
        initialKind: FolderIconKind = .symbol,
        initialValue: String = "folder.fill",
        initialColorHex: String = "#3FB27F",
        onSave: @escaping (String, String?, FolderIconKind, String, String) -> Void
    ) {
        self.title = title
        self.initialName = initialName
        self.initialDescription = initialDescription
        self.initialKind = initialKind
        self.initialValue = initialValue
        self.initialColorHex = initialColorHex
        self.onSave = onSave
        _name = State(initialValue: initialName)
        _descriptionText = State(initialValue: initialDescription)
        _iconKind = State(initialValue: initialKind)
        _iconValue = State(initialValue: initialValue)
        _iconColorHex = State(initialValue: initialColorHex)
        _tab = State(initialValue: initialKind == .emoji ? .emojis : .icons)
    }

    private var previewFolder: MeetingFolder {
        MeetingFolder(
            name: name.isEmpty ? "Folder" : name,
            description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: .now,
            iconKind: iconKind,
            iconValue: iconValue,
            iconColorHex: iconColorHex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader
            fieldsSection
            Divider()
            iconSection
            Divider()
            footer
        }
        .frame(width: 380, height: 560)
        .background(Theme.surface(scheme))
        .onAppear {
            nameFocused = true
        }
    }

    private var sheetHeader: some View {
        Text(title)
            .font(.nutola(12, .medium))
            .foregroundStyle(Theme.secondary(scheme))
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                    .font(.nutola(11, .semibold))
                    .foregroundStyle(Theme.secondary(scheme))
                TextField("Folder name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.nutola(22, .bold))
                    .foregroundStyle(Theme.heading(scheme))
                    .focused($nameFocused)
                    .onSubmit(save)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.nutola(11, .semibold))
                    .foregroundStyle(Theme.secondary(scheme))
                TextField("Add description…", text: $descriptionText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.nutola(13))
                    .foregroundStyle(Theme.secondary(scheme))
                    .lineLimit(1...3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Icon")
                    .font(.nutola(11, .semibold))
                    .foregroundStyle(Theme.secondary(scheme))
                Spacer()
                FolderIconView(folder: previewFolder, size: 36)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            tabBar
            Divider()
            colorRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            pickerContent
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    Text(t.rawValue)
                        .font(.nutola(13, tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? Theme.heading(scheme) : Theme.secondary(scheme))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) {
                            if tab == t {
                                Rectangle()
                                    .fill(Theme.blueberry(scheme))
                                    .frame(height: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var colorRow: some View {
        HStack(spacing: 10) {
            Text(iconColorHex.uppercased())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.secondary(scheme))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ActionColorPreset.allCases) { preset in
                        Button {
                            iconColorHex = preset.rawValue
                        } label: {
                            Circle()
                                .fill(preset.color)
                                .frame(width: 20, height: 20)
                                .overlay {
                                    if iconColorHex.uppercased() == preset.rawValue.uppercased() {
                                        Circle().strokeBorder(.white, lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 28, height: 28)
        }
    }

    @ViewBuilder
    private var pickerContent: some View {
        switch tab {
        case .icons:
            symbolPicker
        case .emojis:
            emojiPicker
        }
    }

    private var symbolPicker: some View {
        VStack(spacing: 8) {
            TextField("Search icons…", text: $symbolQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8),
                    spacing: 6
                ) {
                    ForEach(FolderIconCatalog.filteredSymbols(query: symbolQuery), id: \.self) { symbol in
                        symbolCell(symbol)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    private func symbolCell(_ symbol: String) -> some View {
        let selected = iconKind == .symbol && iconValue == symbol
        return Button {
            iconKind = .symbol
            iconValue = symbol
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(selected ? previewFolder.iconColor : Theme.secondary(scheme))
                .frame(width: 36, height: 36)
                .background(
                    selected ? previewFolder.iconColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(previewFolder.iconColor, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Folder icon: \(symbol.replacingOccurrences(of: ".", with: " "))")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private var emojiPicker: some View {
        VStack(spacing: 8) {
            TextField("Search emoji…", text: $emojiQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(FolderIconCatalog.filteredEmojiSections(query: emojiQuery), id: \.title) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.nutola(11, .semibold))
                                .foregroundStyle(Theme.secondary(scheme))
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 10),
                                spacing: 4
                            ) {
                                ForEach(section.emojis, id: \.self) { emoji in
                                    emojiCell(emoji)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    private func emojiCell(_ emoji: String) -> some View {
        let selected = iconKind == .emoji && iconValue == emoji
        return Button {
            iconKind = .emoji
            iconValue = emoji
        } label: {
            Text(emoji)
                .font(.system(size: 22))
                .frame(width: 32, height: 32)
                .background(
                    selected ? Theme.card(scheme) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.blueberry(scheme), lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Folder emoji: \(emoji)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: iconColorHex) ?? Theme.mint },
            set: { iconColorHex = $0.hexString ?? iconColorHex })
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let desc = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(trimmed, desc.isEmpty ? nil : desc, iconKind, iconValue, iconColorHex)
        dismiss()
    }
}
