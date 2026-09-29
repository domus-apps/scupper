# Changelog

All notable changes to Scupper are documented here. The release workflow publishes each version's section as the GitHub release notes and embeds it in the Sparkle appcast, so the in-app update dialog shows the same notes. A release fails early if its version has no section here.

Keep each bullet on a single line: release notes render line breaks literally (both on GitHub and in the update dialog), so wrapped lines would break mid-sentence.

## 1.1.1

### Fixed

- A mounted disk image of the app counted as another installed copy, so nothing was checked.
- Folders named after the app without its spaces were missed.
- The recent documents list was missed on macOS 26 and later.

## 1.1.0

### Added

- Files left by the helpers and extensions inside an app are found too. Xcode's Instruments and Icon Composer containers are listed with Xcode.
- Group containers with names unlike the app's are found too. Slack's BQR82RBBHL.slack is listed with Slack.
- Background tasks that run from the app's folders are found under any name. Steam's steamclean is listed with Steam.
- Files in the system Library are listed in their own section and move to the Trash after you enter an administrator password. Zoom's daemon and helper tool are listed with Zoom.
- Items another installed app also uses show that app's name and stay unchecked. The iWork folder Pages shares with Keynote and Numbers stays unchecked.
- Protected containers are marked in the list before anything moves.
- When macOS protects another app's container, Scupper shows how to turn on Full Disk Access and can try again, so the container goes to the Trash too.

### Changed

- Removing an app also stops its background tasks and helpers, so nothing keeps running from the Trash.
- Nothing is checked at first for apps that are part of macOS.

### Fixed

- Removing an app that had crash reports also moved the whole crash report folder to the Trash, including reports from other apps.
- An item that couldn't be moved could appear twice in the list.

## 1.0.0

The first release.

- Drop an app onto the window or the Dock icon to see every file it left in your Library, from settings and caches to logs and saved state.
- Every item shows its size and can be unchecked before anything moves.
- One click moves the app and its leftovers to the Trash, so nothing is gone for good until you empty it.
- A running app is asked to quit first.
- Speaks Korean, following the macOS language.
