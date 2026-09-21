import SwiftUI

struct SFSymbolPickerGrid: View {
    @Binding var selectedSymbol: String

    private let symbols = [
        // Lists & Organization
        "list.bullet", "list.star", "list.number", "checklist",
        "bookmark.fill", "folder.fill", "tag.fill", "archivebox.fill",
        "tray.fill", "doc.text.fill", "note.text",
        
        // Media & Entertainment
        "film.fill", "tv.fill", "popcorn.fill", "theatermasks.fill",
        "play.rectangle.fill", "movieclapper", "ticket.fill", "videoprojector",
        "headphones", "music.note", "guitars.fill",
        "gamecontroller.fill", "arcade.stick.console.fill",
        
        // Favorites & Rating
        "star.fill", "heart.fill", "flame.fill", "sparkles",
        "trophy.fill", "crown.fill", "medal.fill", "rosette",
        "hand.thumbsup.fill", "hand.thumbsdown.fill",
        
        // Mood & Atmosphere  
        "moon.stars.fill", "sun.max.fill", "sparkle", "cloud.moon.fill",
        "cloud.sun.fill", "sunset.fill", "moonphase.new.moon",
        "eye.fill", "eye.trianglebadge.exclamationmark.fill",
        
        // Emotions & Reactions
        "face.smiling", "face.dashed", "brain.fill", "exclamationmark.triangle.fill",
        "questionmark.circle.fill", "lightbulb.fill", "bolt.fill",
        
        // Celebration & Events
        "party.popper", "gift.fill", "balloon.fill", "birthday.cake",
        "fireworks", "flag.checkered", "flag.filled.and.flag.crossed",
        
        // Time & Status
        "clock.fill", "timer", "hourglass", "calendar",
        "checkmark.circle.fill", "xmark.circle.fill", "pause.circle.fill",
        
        // Nature & Weather
        "leaf.fill", "tree.fill", "snowflake", "drop.fill",
        "tornado", "rainbow", "umbrella.fill",
        
        // Animals & Creatures
        "hare.fill", "tortoise.fill", "bird.fill", "lizard.fill",
        "fish.fill", "ant.fill", "ladybug.fill", "pawprint.fill",
        
        // Places & Travel
        "house.fill", "building.2.fill", "airplane", "car.fill",
        "sailboat.fill", "ferry.fill", "bicycle", "tent.fill",
        "globe.americas.fill", "map.fill", "signpost.right.fill",
        
        // Food & Drink
        "cup.and.saucer.fill", "fork.knife", "wineglass.fill",
        "takeoutbag.and.cup.and.straw.fill", "carrot.fill", "apple.logo",
        
        // Objects & Items
        "paintbrush.fill", "camera.fill", "phone.fill", "envelope.fill",
        "book.fill", "newspaper.fill", "magazine.fill", "backpack.fill",
        "key.fill", "lock.fill", "shield.fill", "briefcase.fill",
        
        // Sports & Activities
        "figure.run", "figure.walk", "sportscourt.fill", "basketball.fill",
        "football.fill", "baseball.fill", "soccerball", "tennis.racket",
        
        // Symbols & Shapes
        "circle.fill", "square.fill", "triangle.fill", "diamond.fill",
        "heart.circle.fill", "star.circle.fill", "burst.fill", "sparkles.rectangle.stack.fill",
    ]

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(symbols, id: \.self) { symbol in
                Button {
                    selectedSymbol = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .cellSurface(tint: selectedSymbol == symbol ? .accentColor : nil)
                        .foregroundStyle(selectedSymbol == symbol ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: symbol))
                .accessibilityAddTraits(selectedSymbol == symbol ? .isSelected : [])
            }
        }
    }

    /// "star.fill" -> "star", "moon.stars.fill" -> "moon stars" — SF Symbol names read as
    /// dotted identifiers, not words; VoiceOver users shouldn't hear the punctuation.
    private func accessibilityLabel(for symbol: String) -> String {
        symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " ")
    }
}

#Preview {
    @Previewable @State var selected = "star.fill"
    ScrollView {
        SFSymbolPickerGrid(selectedSymbol: $selected)
            .padding()
    }
}
