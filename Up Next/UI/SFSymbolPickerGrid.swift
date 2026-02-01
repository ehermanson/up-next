import SwiftUI

struct SFSymbolPickerGrid: View {
    @Binding var selectedSymbol: String

    private let symbols = [
        "list.bullet", "star", "heart", "film", "tv", "popcorn",
        "theatermasks", "bookmark", "flag", "flame", "sparkles",
        "moon", "globe", "trophy", "gift", "tag", "folder",
        "clock", "eye", "music.note", "gamecontroller", "cup.and.saucer",
        "airplane", "house", "party.popper", "camera", "paintbrush",
        "bolt", "leaf", "snowflake",
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(symbols, id: \.self) { symbol in
                Button {
                    selectedSymbol = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .glassEffect(
                            .regular.tint(
                                selectedSymbol == symbol ? .indigo.opacity(0.4) : .clear
                            ).interactive(),
                            in: .rect(cornerRadius: 12)
                        )
                        .foregroundStyle(selectedSymbol == symbol ? .white : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
