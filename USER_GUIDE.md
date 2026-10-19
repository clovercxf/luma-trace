# LumaTrace User Guide

LumaTrace organizes local photos and videos while leaving the original files where they are. This guide covers the current macOS 14+ build.

## First launch

1. Review the privacy overview on first launch and accept the policy to continue. You can open the full policy from that screen.
2. Open **Monitored Folders** and add one or more media folders. A macOS folder selection panel lets you choose exactly which locations LumaTrace can read.
3. Choose **Start** in the lower-left analysis controls. The sidebar shows the current scanning path and stage. Indexed items appear as analysis completes.
4. Open **Settings → Privacy & Permissions** to review folder availability, camera authorization, and notification authorization. Camera permission is requested when you open motion capture; notification permission is requested when you enable reminders. Full Disk Access is not required.
5. Choose **Settings** to select the interface language, configure video analysis, optional local Ollama, and memory schedules.

The app stores its searchable index and thumbnails locally. It does not move or rewrite original media. Removing a monitored folder stops scanning it but keeps its source files and existing library records.

## Install from the DMG

Open `LumaTrace-<version>-macOS-<architecture>.dmg`, then drag **LumaTrace** onto **Applications**. The distributed local build is ad hoc signed and not notarized, so macOS may require you to confirm the first launch in Privacy & Security. Do not install builds from sources you do not trust.

## Browse and search

Use **All Media**, **Photos**, **Videos**, **Motion Photos**, **Places**, **Time Travel**, and **Duplicates & Picks** in the sidebar. Search matches indexed labels, recognized text, and available descriptions. Results depend on the formats and metadata available to macOS.

Click a thumbnail to open its preview. In the preview, swipe horizontally to move between items, pinch on the trackpad to zoom, drag to pan when zoomed, and use the filmstrip to choose another item. The top-right information button opens a closable details drawer. Use it to inspect metadata or add a place label. Full screen is optional.

Hover over a thumbnail for five seconds to show a larger preview. Only the selected item keeps the blue selection outline; hover follows the pointer.

## Places and location labels

The Places page displays an online OpenStreetMap base map even when no media has GPS metadata. GPS-tagged media appear as markers; zooming changes how locations are grouped. You can also select media and add a city, district, or more specific place label. Place search requires an internet connection. Map tile requests disclose the approximate area displayed to the tile provider; see [Privacy](PRIVACY.md).

## Video analysis and retries

By default, video analysis samples frames. Deep analysis can decode more frames and may take substantially longer. Unsupported or damaged encodings may fail to decode. Failed items appear in **Retry Needed**; retry an individual folder or all failed items. Retry requests made during an active scan are queued until it finishes.

If a video fails repeatedly, confirm that it plays in a current macOS player. If necessary, convert a copy to H.264 and add the converted file. Do not delete the original until you have checked the copy.

## Duplicate suggestions

LumaTrace groups exact duplicates and likely similar media separately. Suggestions include a reason, such as resolution, file size, or video duration. Review the files yourself before removing anything. LumaTrace does not automatically delete duplicates.

## Time Travel memories

Create a memory film manually from **Time Travel**, or configure a daily time or selected weekdays in Settings. Only indexed, available media is used. Films are generated and stored locally. Scheduled generation may be delayed while the Mac is asleep, shut down, or logged out. Notifications require macOS permission.

## Motion capture

When a camera is available and camera access is granted, LumaTrace can save an app-specific still image and video pair. This is not an Apple-standard Live Photo export. Camera files are stored locally and can be indexed by a monitored folder.

## Settings and troubleshooting

- **Folder unavailable:** Connect the disk or mount the volume, then refresh the folder.
- **Counts seem low:** Counts reflect items currently indexed by LumaTrace. Start or refresh a scan to discover new files.
- **Progress appears stuck:** Check the current path and stage in the lower-left status. Long videos and deep frame analysis take longer.
- **Map is blank:** Check the network connection; the Places page loads online map tiles.
- **Local model unavailable:** Start Ollama locally, install a compatible vision model, and use the connection check in Settings.
- **Install warning:** Local builds are not Developer ID signed or notarized. Gatekeeper can warn on first open.

See [Privacy](PRIVACY.md) for data handling and [Testing notes](TESTING.md) for known limitations.

## Privacy and permission checks

The first-run screen explains local storage and network use and requires agreement before opening the library. If a drive is disconnected or access is revoked, use **Settings → Privacy & Permissions** to review the status, reconnect the disk, and add the folder again. macOS does not let apps silently grant themselves Full Disk Access. Camera and notification controls can open the relevant System Settings pane after a denial.
