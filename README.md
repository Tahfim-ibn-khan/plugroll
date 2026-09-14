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
- The sort button (top right) orders by newest, oldest, name or size, and is remembered
  between launches. The date orders group the grid under sticky day headers.
- Tap a photo for the full-screen viewer: swipe between items, pinch or double-tap to
  zoom, drag to pan while zoomed, and tap once to hide the top bar.

## Project file
`VimageReader.xcodeproj` is generated from `project.yml` and lists every source file by
name. After adding or removing files, run `xcodegen generate` (`brew install xcodegen`) —
otherwise a new file will not be compiled.
