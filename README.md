# Plugroll

A personal iPhone app for browsing photos and videos on an external SSD, styled like the Photos app.

## Run it on your iPhone
1. Install **Xcode** from the Mac App Store and open it once so it can finish setting up.
2. Open `Plugroll.xcodeproj`.
3. In Xcode, click the **Plugroll** target, then **Signing & Capabilities**. Under **Team**, add and pick your Apple ID.
   If Xcode says the bundle ID is taken, change `com.tahfim.vimagereader` to something unique.
4. Plug in the iPhone and select it as the run destination at the top of the window. On the phone, turn on **Settings → Privacy & Security → Developer Mode** (the phone restarts).
5. Press **Run** (⌘R). The first time only, trust your certificate on the phone: **Settings → General → VPN & Device Management**.
6. With a free Apple ID, the app stops opening after 7 days. Press Run again to re-install it.

## Using it
Plug in the SSD, tap **Open SSD**, and pick the drive (or any folder on it). The app
remembers it and opens it again at the next launch if it is plugged in.

- Folders show as album cards with a cover; photos and videos fill a Photos-style grid.
  Videos show their length in the corner. Pull down to rescan a folder after changing
  files on the drive elsewhere.
- The sort button (top right) orders photos and videos by newest, oldest, name or size,
  and folders by name or date. Both are remembered between launches. The date orders
  group the grid under sticky day headers.
- Search by name at the top: **This Folder** filters instantly, **All Subfolders** searches
  everything below the current folder.
- **Select** lets you tap or drag across items, then Share, Save to Photos or Delete.
  Delete removes files from the drive permanently.
- Tap an item for the full-screen viewer: swipe between items, pinch or double-tap photos
  to zoom, and tap once to hide the bars. The bottom bar has Share, Save and Delete; the
  top-right button rotates the screen, even with Portrait Lock on.
- Videos play in a Photos-style player: scrub bar, play/pause, skip 10 seconds (or
  double-tap a side), mute and AirPlay. Controls hide on their own while playing.

## Project file
`Plugroll.xcodeproj` is generated from `project.yml` and lists every source file by
name. After adding or removing files, run `xcodegen generate` (`brew install xcodegen`) —
otherwise a new file will not be compiled.

Unit tests live in `PlugrollTests/`. Run them with ⌘U, or:

```sh
xcodebuild test -project Plugroll.xcodeproj -scheme Plugroll \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

Thumbnails and video lengths are cached on the phone (encrypted while it is locked),
capped at about 500 MB and trimmed at launch.

## Building without Xcode

`.github/workflows/build-ipa.yml` builds the app on GitHub's Macs and publishes an
unsigned `.ipa` to a rolling release tagged `latest`. Nothing is signed in CI — a free
Apple ID cannot sign there anyway. **SideStore** or **AltStore** signs the `.ipa` on the
phone with your Apple ID, which keeps the usual free-account limits: the app stops
opening after 7 days unless it is refreshed, and three sideloaded apps at a time.

1. Push this repository to GitHub. Every push to `main` runs the tests and builds it.
2. On the phone, open the repository's **Releases** page and download `Plugroll.ipa`.
   `Plugroll.ipa.sha256` next to it has its checksum.
3. Open it in SideStore and let it install.

macOS runner minutes are free on a public repository. On a private one they bill at 10x
against the 2,000 free minutes a month, which is roughly 40 builds of this app.
