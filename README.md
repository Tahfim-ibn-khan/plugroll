# vimage

A personal iPhone app for browsing photos and videos on an external SSD, styled like the Photos app.

## Run it on your iPhone
1. Install **Xcode** from the Mac App Store and open it once so it can finish setting up.
2. Open `VimageReader.xcodeproj`.
3. In Xcode, click the **VimageReader** target, then **Signing & Capabilities**. Under **Team**, add and pick your Apple ID.
   If Xcode says the bundle ID is taken, change `com.tahfim.vimagereader` to something unique.
4. Plug in the iPhone and select it as the run destination at the top of the window. On the phone, turn on **Settings → Privacy & Security → Developer Mode** (the phone restarts).
5. Press **Run** (⌘R). The first time only, trust your certificate on the phone: **Settings → General → VPN & Device Management**.
6. With a free Apple ID, the app stops opening after 7 days. Press Run again to re-install it.

## Using it
Plug in the SSD, tap **Open SSD**, and pick the drive (or any folder on it).

- Folders show as album cards with a cover; photos and videos fill a Photos-style grid.
  Videos show their length in the corner.
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
`VimageReader.xcodeproj` is generated from `project.yml` and lists every source file by
name. After adding or removing files, run `xcodegen generate` (`brew install xcodegen`) —
otherwise a new file will not be compiled.
