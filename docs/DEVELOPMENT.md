# Development guide

Where the project stands, how it's put together, and how to pick it up again. Read this before
changing anything; the README covers using the app.

## Status (version 0.1, October 2026)

Working and in daily use, installed in `/Applications`. Everything below is built and tested.

| Area | What's there |
|---|---|
| Scan (read-only) | File types, junk skipped, dates from EXIF / MP4 `mvhd` / Takeout `.json` / file names / modified date, camera names, GPS samples, camera folders (`DCIM/100CANON`, `DJI/100MEDIA`) dissolved unless names would clash |
| Proposal | Event name from the folder name (dates removed, camera names rejected), special dates from settings, album name `YYYY-MM – Event` / range / year-only, year folder chosen by start year, nearby-album hints, notices (blockers, warnings, info) with fix buttons |
| Year folders | Read from the drive every time (`YYYY - YYYY`, `YYYY`, or a named single year like `1990 - Wedding`); overlap checks; new-folder suggestion next to existing ranges; bulk setup screen; suggestions from the added folders (one per year, blocks of N, balanced by size) |
| Duplicates | Name + size against a cached index of the whole library, including zip contents; contents check by CRC32 (zip entries use their stored CRC); renamed copies found by size + CRC; other libraries' cached indexes checked too, even when their drive is unplugged |
| Copy | Plan, dry run, unlock only with permission, pilot (smallest file, checked: photo decodes / video structure complete), the rest, final check, relock; exclusive create, SHA-256 read-back, dates kept; cancel between files |
| Records | `runs/NN_<slug>/` (plan.json, plan.csv, logs, lock_log.csv, run_report.md, timeline backup), timeline .xlsx row inserted in date order, "By year" formulas stretched, new workbook when none exists, `HISTORY_<date>.md` section |
| Libraries | Any folder or drive; recent libraries; live mount/unmount detection; readiness icon (green / yellow / orange / red) with hover and click details; free-space blocker and near-full warning |
| CLI | `albumctl scan`, `import` (dry run by default, `--execute`, `--allow-unlock`), `index`, `year-folders` |
| Tests | 25 tests in 6 suites (`swift test`), plus an optional check against a copy of a real timeline sheet |

## Ground rules (don't change these)

These come from how the library was built by hand, and they're why the app is trusted with it.

- **Never delete, move or overwrite.** The engine can only `mkdir` and copy with `O_EXCL`. There's no
  delete code anywhere; keep it that way. A failed copy is left in place and named in the log.
- **Read-only until the owner confirms.** Scanning, indexing and the dry run write nothing to the
  library. The only writes outside the library are the records folder and the index cache.
- **Locks:** a Locked folder (`uchg`) is unlocked only after the owner ticks the box, only the folders
  the dry run named, and is locked again afterwards. Both changes go in `lock_log.csv`.
- **Never rename existing year folders** (paths in logs, timeline and undo files would break). Add a
  new folder instead.
- **Every run is recorded** in the same format the hand-made runs used (plan.json is readable by the
  original `run_copy.py` toolkit).
- **No personal data in the repo.** Birthdays and other personal dates belong in the app's settings
  only; examples in code, tests and docs use neutral names ("Beach Trip", "Family Dinner").

## Layout

```
Sources/AlbumCore/          the engine (no UI)
  MediaTypes.swift          file kinds, junk, camera-folder and device-name rules
  DateReader.swift          dates per file; Floating (wall-clock) dates; MP4 atom reader
  SourceScanner.swift       scan a folder → SourceScan; DateSummary (range, confidence, outliers)
  Naming.swift              album names, event-name suggestion, special dates, slugs
  YearFolders.swift         parse/list year folders, overlaps, suggestions; Locks (chflags)
  YearFolderSetup.swift     create year folders (plan, dry run, unlock, log, lock)
  YearSuggest.swift         year stats from proposals; perYear / blocks / balanced ranges
  LibraryIndex.swift        cached file index per library (incremental by folder mtime)
  ZipReader.swift           zip central directory (ZIP64), CRC32
  Duplicates.swift          name+size check, contents check, across several libraries
  Proposal.swift            Proposal (owner's choices), ProposalBuilder, Notice
  Plan.swift                ImportPlan, DryRun, Volumes (free space), Format
  Executor.swift            CSVLog, copyVerified, pilotCheck, LockKeeper
  ImportJob.swift           the whole run, report, timeline update
  Records.swift             RecordsFolder (runs, history, timeline path)
  TimelineSheet.swift       insert a row into the .xlsx, stretch formulas, create a new workbook
  XLSX.swift                zip container read/write (Compression framework)
  Settings.swift            settings in UserDefaults; index cache location
Sources/AlbumImporter/      SwiftUI app
  AppModel.swift            state: items, library availability/health, index, actions
  ContentView.swift         split view, sidebar rows, library status + health popover, drop zone
  ReviewView.swift          review card, confirm sheet
  RunViews.swift            progress and done screens
  YearFolderSetupView.swift year folder setup with suggestions
  SettingsView.swift        locations, other libraries, year folders, special dates, index
  Snapshot.swift            developer aid: render screens to PNG (see Testing)
Sources/albumctl/main.swift command-line tool
Tests/AlbumCoreTests/       Sandbox fixtures (JPEGs with EXIF, MP4s, xlsx) and the tests
scripts/                    build-app.sh, make-icon.swift, make-demo-library.swift
```

## Key decisions

- **Swift package + `scripts/build-app.sh`**, not an Xcode project (same as other projects here). The
  script builds release binaries, writes Info.plist and ad-hoc signs the bundle.
- **No dependencies.** ImageIO for EXIF, a small MP4 atom reader for video dates, CryptoKit for
  SHA-256, Compression for zip/xlsx, regex XML edits for the timeline (the sheet's format is known).
- **Dates are wall-clock ("floating"):** stored as `Date` read with a GMT calendar. Video `mvhd` times
  (UTC) are converted to this Mac's time zone first. Future dates and camera defaults (1970,
  1 Jan 2000…) are rejected, so a test photo dated next year falls back to its modified date.
- **An album goes in the year folder where it starts.** Year stats for suggestions count start years.
- **Duplicate index** is a cache in `~/Library/Application Support/Album Importer/library_index-<hash>.json`,
  one per library root. Refresh re-lists only folders whose mtime changed; "Rebuild" does a full scan.
- **Timeline sheet** rows use inline strings and copy the style of the row above; `fullCalcOnLoad` is
  set so Excel recalculates the "By year" formulas.
- **Settings** are JSON in UserDefaults under key `settings`. Inside the app bundle (the app and the
  bundled `albumctl`) that's `.standard`; macOS refuses a suite named after the running bundle, so
  `Settings.store` picks the right one. Missing keys keep defaults (older settings still load).

## Building, installing, testing

```sh
swift build                    # debug
swift test                     # all tests
scripts/build-app.sh           # build/Album Importer.app
ditto "build/Album Importer.app" "/Applications/Album Importer.app"   # update the installed app (quit it first)
swift scripts/make-icon.swift  # regenerate assets/AppIcon.icns and icon-256.png
```

- **Real timeline sheet check** (writes only to the output copy):
  `ALBUM_TIMELINE_XLSX=<sheet> ALBUM_TIMELINE_OUT=/tmp/t.xlsx swift test --filter RealTimeline`
- **Demo library** for trying the app safely: `swift scripts/make-demo-library.swift <empty folder>`,
  then point Settings at `<folder>/Photo Library` and `<folder>/Records`.
- **Screens without a display or Screen Recording permission:** run the unbundled binary with
  `ALBUM_IMPORTER_SNAPSHOT=<out dir>` (optionally `ALBUM_IMPORTER_ADD=<folder>:<folder>`,
  `ALBUM_IMPORTER_EVENT=<name>`, `ALBUM_IMPORTER_COPY=1`). It renders each screen to PNG and quits.
  Offscreen rendering can't draw `NavigationSplitView`, so it renders the detail panel, the library
  status, the health popover, the confirm sheet, year folders and settings separately, in light mode;
  scroll views are laid out flat in this mode. Point the settings at a demo library first
  (`defaults write app.albumimporter.AlbumImporter settings -data <hex JSON>`) and restore them after.

## Lessons learned

- Test the **bundled** app, not just the `.build` binary: the settings bug above only showed up inside
  the bundle.
- Observation doesn't track values read straight from disk. Availability, free space and similar are
  stored properties updated on mount/unmount notifications and on Check Again.
- Menu labels lose colour; draw coloured status icons outside the `Menu`.
- In zsh, a word starting with `=` is expanded (`echo ======` fails); use quotes.

## Not done yet (ideas, roughly by value)

1. Find resized or recompressed copies (perceptual hash), flagged for review rather than skipped.
2. Merge into an existing album file by file (today: only as a subfolder of one).
3. Undo for a run: move its copies into a holding folder (never delete), from the run's log.
4. Place-name suggestion from GPS (MapKit reverse geocoding), as an opt-in.
5. Background re-index of other libraries when their drive is plugged in.
6. Signed and notarized builds, so the app can be shared without building it.
7. Takeout zip extraction and splitting mixed period folders (done by hand with scripts so far).

## Picking it up again

1. `git pull`, then `swift test` (25 tests should pass).
2. Read this file, then the README.
3. Make the change; add a test next to the existing ones (the `Sandbox` fixture makes JPEGs with EXIF,
   MP4s and timeline workbooks in a temporary folder).
4. `scripts/build-app.sh`, check the screens (snapshot mode or by hand), then update `/Applications`.
5. Keep the README and this file current; keep personal data out of the repo.
