# FileKit

Where my apps keep their data: folder sizes, moving a data folder to another disk, APFS clones, JSON files saved a
moment after the last change, and secrets in the Keychain. Shared by RenChan, Kamiro, Hangar, Starseed, Tadpole,
Attic, AM2RLauncherPlus, SMLauncherPlus, Porthole, VoxDen, Hearthside, BenchLog and Thimble, and the next ones.
A change here reaches every app at its next package update, so keep the API stable and additive.

Shared rules for how every project is laid out and named:
@~/.claude/project-layout.md

## Layout

- `Sources/FileKit/` no SwiftUI, macOS and iOS:
  - `FolderSize`: `allocated(of:)`, `logical(of:)`, `measure` (async), `summary(of:)` (sync); hard links once,
    links not followed, `Options` (excluding, skipping, staysOnVolume), `otherAppsData`.
  - `FolderMove`: `move(_:into:keeping:progress:)` (rename on one disk; copy, check, delete across disks),
    `databaseFiles`, `listFiles`, `size(of:excluding:)`.
  - `FileClone`: `clone(_:to:fallback:)`, `copy(_:to:stop:copied:)`, `sameVolume`.
  - `JSONFile<Value>`: `load`, `load(or:)`, `save`, `remove`, damaged files set aside.
  - `DebouncedSaver<Value>`: `schedule`, `flush`, `takePending`, `cancel`, `maxWait`.
  - `Keychain`: `string`/`data(for:)`, `set(_:for:)`, `remove`, `contains`, `adopt(_:from:)`, `inMemory(service:)`.
- `Tests/FileKitTests/` Swift Testing. Files only under `FileManager.default.temporaryDirectory` (`Scratch`); Keychain
  tests use a service named `FileKitTests.<uuid>` and remove it.

## Rules

- Never lose data. A move deletes the old items only after the copy is checked; a failure leaves the old folder as it
  was. Nothing the person put somewhere is overwritten or removed: targets that exist are refused, staging folders
  have names of our own.
- Everything is safe from any thread and does no I/O on the main thread by itself. `DebouncedSaver` is on the main
  actor; its saves run off it.
- No strings shown to people: errors are cases an app words in its own languages.
- Add a test for every change. `swift build && swift test` pass with no warnings, and the iOS build, then CI on macOS.
- Release: tag `x.y.z` and push the tag; apps use `from:`.

## Git

Commit after each working change, with a message that says what an app can now do.
