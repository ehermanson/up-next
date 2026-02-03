# Watch List

A Swift app for managing your watch list of movies and TV shows.

## Setup

1. **Get a TMDB API Key**

   - Sign up for a free account at [The Movie Database (TMDB)](https://www.themoviedb.org/settings/api)
   - Create an API key in your account settings

2. **Configure Info.plist**

   - Copy the template file:
     ```bash
     cp "Watch List/Info.plist.template" "Watch List/Info.plist"
     ```
   - Open `Watch List/Info.plist` and replace `YOUR_API_KEY_HERE` with your actual TMDB API key

3. **Open the Project**
   - Open `Watch List.xcodeproj` in Xcode
   - Build and run the project

## Notes

- `Info.plist` is gitignored to prevent committing your API key
- Use `Info.plist.template` as a reference for the required configuration
