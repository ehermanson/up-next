import SwiftUI

struct TMDBAttributionView: View {
    var body: some View {
        VStack(spacing: 8) {
            tmdbLogo
                .frame(height: 14)
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var tmdbLogo: some View {
        Link(destination: URL(string: "https://www.themoviedb.org")!) {
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
                    .frame(width: 32, height: 16)
                    .overlay {
                        Text("TMDB")
                            .font(.system(size: 7, weight: .heavy))
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
