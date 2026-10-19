# Testing and release notes

## Current release

- Version: 0.4.5 (build 17)
- Platform: macOS 14 or later
- Release build: completed successfully with Swift Package Manager.
- Installer package: the embedded app version, executable and package payload were checked.
- Signing: local ad hoc application signature only; no Developer ID signature or Apple notarization.

## Test status for this source upload

The renamed LumaTrace target completed a Debug build. The Release compiler and linker completed, but this restricted environment blocked `dsymutil` while generating the dSYM bundle. The source therefore has not yet been independently packaged as a renamed Release app.

Automated run: 37 of 41 tests passed. `LibraryTests` passed 31/34; three tests could not encode sample video or allocate a Vision pixel-buffer pool on this host. `WorkflowAuditTests` passed 6/7; the remaining video-cache test could not open its synthetic video. These failures are environment-dependent AVFoundation/Vision media capabilities, not brand rename compile failures. Run `./run-tests.command` on a fully provisioned Mac before release.

Automated tests do not replace testing on a physical Mac. Trackpad gestures, camera hardware, scheduled execution across sleep/wake, large libraries, and real OpenStreetMap tile loading should be verified on the target system.

## Known limitations

- The installer is not Developer ID signed or notarized; Gatekeeper may warn on first launch.
- Apple Photos library direct import and common camera RAW formats are not implemented. Export original files from Photos and add the exported folder.
- Search uses local labels, OCR, and available text semantics; a general cross-modal image-text embedding system is not included.
- Motion capture uses an app-specific JPG + MOV pairing, not Apple's standard Live Photo format.
- The map uses the public OpenStreetMap tile service, which has no availability guarantee and may rate-limit requests.
- Some video codecs may be readable as files but not decodable by the current macOS media framework.
- Automatic memory creation depends on the app's local schedule and may be delayed while the Mac sleeps, is shut down, or the user is logged out.

## Reproduce a local build

On macOS 14 or later with Xcode Command Line Tools:

```sh
./build-app.command
./run-tests.command
```
