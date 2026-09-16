import SwiftUI

struct TMDBAttributionView: View {
    var body: some View {
        VStack(spacing: 8) {
            tmdbLogo
                .frame(height: 20)
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private static let tmdbURL = URL(string: "https://www.themoviedb.org")!

    private var tmdbLogo: some View {
        Link(destination: Self.tmdbURL) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.56, green: 0.84, blue: 0.80),
                                Color(red: 0.01, green: 0.81, blue: 0.53),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 44, height: 20)
                    .overlay {
                        Text("TMDB")
                            .font(.caption2.weight(.heavy))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .padding(.horizontal, 3)
                            .foregroundStyle(.black)
                    }
                Text("Powered by The Movie Database")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    TMDBAttributionView()
}
