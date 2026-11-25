# FileKit

Where my apps keep their data. It gathers what each app wrote on its own: Kamiro's folder sizes that count hard
links once, the launchers' data-folder move that never loses a file across disks, RenChan's APFS clones, the JSON
library files saved a moment after the last change, and a dozen copies of the same Keychain code.

- **FolderSize**: how much room a folder takes, allocated (as the Finder shows it) and logical (as a copy needs).
- **FolderMove**: move a data folder to another disk: copy, check, then delete.
- **FileClone**: APFS clones, with a copy when the disk can't clone.
- **JSONFile** and **DebouncedSaver**: a Codable value in one JSON file, saved atomically, off the main thread, once
  changes settle.
- **Keychain**: secrets as text or bytes, with an in-memory store for tests.

macOS 14 or iOS 17 or later. No SwiftUI.

## Add it to an app

SwiftPM (`Package.swift`):

```swift
.package(url: "https://github.com/matguitarist/FileKit", from: "0.1.0"),
// in the app or Kit target:
.product(name: "FileKit", package: "FileKit"),
```

XcodeGen (`project.yml`):

```yaml
packages:
  FileKit:
    url: https://github.com/matguitarist/FileKit
    from: 0.1.0
targets:
  App:
    dependencies:
      - package: FileKit
```

## Folder sizes

```swift
import FileKit

let onDisk = await FolderSize.allocated(of: runtimesFolder)    // what the Finder shows; 0 when unreadable
let toCopy = await FolderSize.logical(of: dataFolder, options: .init(excluding: database))

// Both sizes and counts, telling "can't read it" from zero; stops when the task is cancelled.
let summary = try await FolderSize.measure(home, options: .init(skipping: FolderSize.otherAppsData))
summary.allocated; summary.logical; summary.files; summary.items
```

A file with several hard links counts once; symbolic links are not followed; hidden files count. `skipping` leaves
folders out wherever they are (`otherAppsData`: ~/Library/Containers and Group Containers, which make macOS ask for
permission). `staysOnVolume` leaves out disks mounted inside. Code already off the main thread can call
`FolderSize.summary(of:options:)` directly.

## Move a data folder

```swift
let keeping = FolderMove.databaseFiles(store: Store.url, in: DataFolder.url)   // the open database stays
let moved = try await Task.detached {
    try FolderMove.move(DataFolder.url, into: chosenParent, keeping: keeping) { done, total in
        Task { @MainActor in progress = (done, total) }
    }
}.value
```

On one disk each item is renamed, and the renames are undone if one fails. On another disk, everything is copied into
a hidden staging folder beside the destination (files cloned where the disk can, links kept as links, permissions and
tags kept), each file is checked (size, and where each link points), then put in place, and only then deleted from the
old folder. Any failure before that leaves the old folder as it was. A destination that already has one of the items
is refused (`.destinationExists`), so nothing is overwritten. Errors are cases (`destinationExists`, `insideItself`,
`notEnoughSpace`, `copyFailed`, `verifyFailed`) for the app to word in its own languages.

## Clone

```swift
switch try FileClone.clone(game.baseURL, to: workingCopy, fallback: .none) {
case .cloned: break                       // instant, no extra space
case .copied: break                       // only with fallback: .copy
}
// Another disk with fallback: .none throws FileClone.Failure.cannotClone: ask before a full copy.

// File by file, with progress and a stop flag (each file still cloned where it can be):
try FileClone.copy(source, to: target, stop: { flag.isCancelled }, copied: { bytes in done += bytes })
```

The target must not exist yet (`.targetExists`); its folder is made. A copy that fails or stops removes what it made.

## JSON files, saved once changes settle

```swift
let file = JSONFile<[Game]>(folder.appending(path: "library.json"))   // ISO dates, pretty, sorted keys
do {
    games = try file.load(setAsideDamaged: true) ?? []
} catch let damaged as JSONFile<[Game]>.Damaged {
    log("The library couldn't be read (\(damaged.reason)); kept as \(damaged.keptAt?.lastPathComponent ?? "-")")
}

@MainActor let saver = DebouncedSaver(file, delay: .milliseconds(400)) { error in notice = error.localizedDescription }
saver.schedule(games)                       // after every change: one write once they settle, off the main thread
await saver.flush()                         // before reading the file again
if let last = saver.takePending() { try? file.save(last) }    // at quit, synchronously
```

`setAsideDamaged` renames a file that can't be read to "library (damaged <date>).json", so the next save can't erase
what the person had. Other date styles: `.foundation` (what a plain `JSONEncoder()` writes), `.secondsSince1970`.

`DebouncedSaver` saves anything, not only files: `DebouncedSaver(delay: .milliseconds(700)) { try await api.post($0) }`.
Saves run one at a time, in order. With `maxWait`, changes that never settle (typing) are still saved that often.

## Keychain

```swift
let keychain = Keychain(service: "com.mathieuares.hangar")
try keychain.set(token, for: "steam")            // nil or "" removes it
let token = keychain.string(for: "steam")        // nil when there is none
try keychain.set(keyData, for: "sync-key")       // Data too
try keychain.remove(nil)                         // every item of the service

// Test runs never touch the person's Keychain:
let keychain = Store.isOverridden ? Keychain.inMemory(service: service) : Keychain(service: service)

// An app's old name: move its secret once.
try keychain.adopt("user", from: Keychain(service: "com.romsbox.app"))
```

Options: `label` (the name Keychain Access shows), `accessible` (`.afterFirstUnlock` for a sync that runs while
locked, `.afterFirstUnlockThisDeviceOnly`, ...), `synchronizable` (iCloud Keychain) and `accessGroup` (apps of one
team); the last two use the data protection keychain, which needs a signed app with a team. Writing updates the item
in place, so the access list the person allowed stays.
