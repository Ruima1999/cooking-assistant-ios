# Cooking Assistant (iOS)

Hands-free, slide-by-slide cooking guidance with voice control, audio narration, and smart timers. This repo is the iOS app shell plus Cloudflare Worker configuration for future LLM-backed recipe normalization.

## Project Status
- Early scaffolding only. See `design.md` as the source of truth for product decisions.
- No production logic is implemented yet.

## iOS App
- Stack: SwiftUI + Xcode project
- Targets: iPhone and iPad

Open `ios/CookingAssistant.xcodeproj` in Xcode to run the app.

### Run Locally (Simulator)
1. Install an iOS simulator runtime in Xcode:
   - Xcode → Settings → Platforms → Download iOS runtime (e.g. 26.2).
2. Verify available devices:
   ```sh
   xcrun simctl list devices
   ```
3. Build for a simulator (update the device name + OS version to match your list):
   ```sh
   xcodebuild -project ios/CookingAssistant.xcodeproj \
     -scheme CookingAssistant \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
   ```
4. Find the build output directory:
   ```sh
   xcodebuild -project ios/CookingAssistant.xcodeproj \
     -scheme CookingAssistant \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' \
     -showBuildSettings | grep -m1 BUILT_PRODUCTS_DIR
   ```
5. Boot the simulator (if needed):
   ```sh
   open -a Simulator
   xcrun simctl boot "iPhone 17 Pro"
   ```
6. Install and launch the app (replace the path from step 4 if needed):
   ```sh
   xcrun simctl install "iPhone 17 Pro" \
     /Users/mareal/Library/Developer/Xcode/DerivedData/CookingAssistant-ddirmplyjxpeozgblzdgjramdonx/Build/Products/Debug-iphonesimulator/CookingAssistant.app
   xcrun simctl launch "iPhone 17 Pro" com.example.CookingAssistant
   ```

### App Config (Supabase)
Update `ios/CookingAssistant/Config.xcconfig`:
```
SUPABASE_URL = https://YOUR-PROJECT.supabase.co
SUPABASE_ANON_KEY = YOUR_SUPABASE_ANON_KEY
```

## Cloudflare Worker (Wrangler)
This repo includes a basic Wrangler setup for future LLM-backed services.

- Config: `wrangler.toml`
- Local vars: `.dev.vars` (not committed)
- Example env: `.env.example`

### Local secrets
Use Wrangler secrets for sensitive values:

```sh
wrangler secret put LLM_API_KEY
```

### KV
This project is set up to use a KV namespace. Replace the placeholder IDs in `wrangler.toml` after creating the namespace:

```sh
wrangler kv:namespace create RECIPES_KV
```

## Repo Layout
- `ios/` — iOS app (SwiftUI)
- `workers/` — Cloudflare Worker stub
- `design.md` — product and UX spec (authoritative)

## Next Steps
- Validate the MVP flow described in `design.md`.
- Flesh out Cooking Mode UI and voice controls.
- Implement Worker endpoints for recipe normalization.
