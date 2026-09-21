import SwiftUI

struct TMDBAttributionView: View {
    @State private var showingSafari = false

    var body: some View {
        VStack(spacing: 8) {
            tmdbLogo
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .sheet(isPresented: $showingSafari) {
            SafariView(url: Self.tmdbURL)
                .ignoresSafeArea()
        }
    }

    private static let tmdbURL = URL(string: "https://www.themoviedb.org")!

    private var tmdbLogo: some View {
        Button {
            showingSafari = true
        } label: {
            HStack(spacing: 6) {
                Image("TMDBLogo")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 16)
                Text("Powered by The Movie Database")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    TMDBAttributionView()
}
