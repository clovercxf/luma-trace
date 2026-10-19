# LumaTrace Privacy Policy

**Effective date: October 19, 2026**

LumaTrace is a local-first macOS photo library published by Clover F. This policy describes the current desktop application.

On first launch, the app displays a privacy overview and asks you to confirm that you have read and agree to this policy before opening the library. You can review the complete policy from that screen and later revisit permission status in Settings.

## Data stored on your Mac

When you add folders, LumaTrace reads media that you select and creates a searchable library index, thumbnails, preferences, and (when requested) memory films on this Mac. Your original photos and videos remain in their existing locations. The app does not include a LumaTrace account, cloud library, advertising SDK, or analytics service.

The app may read image and video metadata such as capture time, dimensions, and GPS coordinates so it can sort, search, and map your media. Text recognition and system image analysis use Apple frameworks on your Mac. Search and analysis results are kept in the local library.

## Network connections

- **OpenStreetMap:** The Locations page requests map tiles from `tile.openstreetmap.org`. Like ordinary web requests, the tile service can receive your network address, the requested tile coordinates, and standard request metadata. Tile coordinates reveal the approximate map area currently displayed. LumaTrace does not send your photo files, filenames, or embedded GPS metadata to the tile server. See the [OpenStreetMap tile usage policy](https://operations.osmfoundation.org/policies/tiles/) and [OpenStreetMap Foundation privacy policy](https://osmfoundation.org/wiki/Privacy_Policy).
- **Apple MapKit place search:** When you search for a city, district, or place to assign a location label, the search text is sent to Apple's mapping service to find matching places. The search is initiated by you; LumaTrace does not attach selected photos or their GPS metadata to that query.
- **Optional Ollama:** If you enable local vision descriptions, LumaTrace connects only to `127.0.0.1:11434`. Selected image content may be sent to the Ollama service running on your own Mac. LumaTrace rejects remote Ollama hosts.
- **No LumaTrace cloud:** The app has no LumaTrace backend and does not transmit your library to Clover F.

## Permissions and notifications

macOS may ask for access to folders you select, the camera when you use motion capture, or notifications if you enable scheduled memory reminders. These permissions are controlled in macOS System Settings. Camera recordings and generated memories are saved locally.

## Your choices

You choose which folders to index, whether to enable the optional local model, whether to use the map, and whether to allow notifications. Removing a watched folder removes it from monitoring; it does not delete the original media. You can remove local app data using macOS storage tools after quitting the app, but deleting its index will remove locally stored organization and analysis results.

## Changes and contact

This policy may be updated when app behavior changes. For privacy questions, contact the publisher through the GitHub repository where LumaTrace is distributed. Do not include private photos or library databases in a support request.
