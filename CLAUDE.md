# DarwinScan — Claude orientation

A macOS app that catalogues everything interesting in the **system image** —
NOT user data. Default roots: `/System` (excluding `/System/Volumes` but
including cryptexes), `/bin`, `/sbin`, `/usr` (excluding `/usr/local`).

Stores results in a `.darwinscan` directory package so multiple scans can be
diffed by SHA-256.

## Build

```sh
xcodebuild -project DarwinScan.xcodeproj -scheme DarwinScan -configuration Debug -destination 'platform=macOS' build
```

Open in Xcode and Cmd+R to run. Deployment target is macOS 26.5; Xcode 26+.

## Project shape

Xcode 26's **file-system-synchronized groups** are in use — anything you drop
inside `DarwinScan/` is automatically compiled. No need to touch the pbxproj
to add files. Subdirectories are fine; we organize by concern:

```
DarwinScan/
├── DarwinScanApp.swift            # @main, DocumentGroup
├── ContentView.swift              # NavigationSplitView root
├── Models/                        # ScanItem, ScanOptions, ScanProgress, SystemInfo
├── Document/                      # ScanDocument (ReferenceFileDocument), ScanPackage (FileWrapper), ScanStore (@Observable)
├── Scanning/                      # Scanner + per-domain Inspectors + FileWalker + StringsExtractor
├── UI/                            # SidebarView, ItemListView, DetailView, ScanProgressView, WelcomeView
└── Utilities/                     # Hash, ByteFormat, SystemInfoCollector
```

## Critical build settings (DO NOT casually change)

- `ENABLE_APP_SANDBOX = NO` — required to read `/System`, `/bin`, `/usr`.
  Re-enabling the sandbox will break the entire app.
- `ENABLE_HARDENED_RUNTIME = YES` — kept on. We spawn `/usr/bin/strings` and
  `/usr/bin/csrutil`; those are Apple-signed so the hardened runtime is fine.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — *infectious*. Every file-scope
  `let`, free function, type, and extension defaults to `@MainActor`. **Any
  helper called from `ScanWorker` (background actor) must be explicitly
  `nonisolated`.** Search the codebase for `nonisolated` to see the pattern.
  This bit us during the initial build — full cascade of warnings cleaned up
  by marking the inspectors and their file-scope helpers `nonisolated`.

## Architecture

```
┌─────────────────────────┐         ┌──────────────────────────────────────┐
│ ScanController          │         │ ScanWorker (actor)                   │
│  @Observable @MainActor │ ──────▶ │  drives a bounded TaskGroup          │
│  isRunning              │ ◀────── │  (window = activeCPUs - 1)           │
│  progress               │         │  consumes URLs from FileWalker stream│
└─────────────────────────┘         └──────────────────────────────────────┘
            │                                    │
            ▼                                    ▼ (child tasks, parallel)
┌─────────────────────────┐         ┌──────────────────────────────────────┐
│ ScanDocument            │         │ ScanPipeline (Sendable struct)       │
│  ReferenceFileDocument  │         │  - classifies one URL → ScanItem     │
│  ObservableObject       │         │  - populates context + relationships │
│   └─ store (ScanStore)  │         │  - writes blob bytes to disk via     │
└─────────────────────────┘         │    BlobWriter before returning       │
            │                       └──────────────────────────────────────┘
            ▼                                    │
┌─────────────────────────┐                      ▼
│ ScanStore               │         ┌──────────────────────────┐
│  @Observable @MainActor │         │ Inspectors               │
│  items: [UUID:ScanItem] │         │  MachOInspector          │
│  itemsByPath            │         │  PlistInspector          │
│  blobStore: BlobStore   │ ──────▶ │  AppBundleInspector      │
└─────────────────────────┘         │  MLModelInspector / etc. │
            │                       │  (all `nonisolated`)     │
            ▼                       └──────────────────────────┘
┌─────────────────────────┐
│ BlobStore               │
│  @Observable @MainActor │
│  refs: Set<String>      │  ← lightweight registry; bytes live on disk
│  cacheDirectory: URL    │
│  loadedWrappers (after  │
│   document open)        │
└─────────────────────────┘
```

`ScanItem` is a single discriminated record (one row per discovered thing).
The `category` field picks which of `executable` / `application` / `mlModel` /
etc. is populated. Tags are free-form chips for the UI; `context` is the
human disambiguator (e.g. owning bundle's display name); `relationships`
holds outgoing graph edges.

### Throttling and parallelism

- **Concurrency:** TaskGroup keeps `activeCPUs - 1` inspector tasks in flight
  at any time. The FileWalker producer is pumped from the actor body (single
  consumer), child tasks each process one URL.
- **Batch flush:** worker accumulates `InspectResult`s and flushes to the
  MainActor `batchSink` every **250 ms** or **256 items**, whichever comes
  first. Each flush is one SwiftUI re-render rather than N.
- **Progress emit:** separate **150 ms** throttle on `ScanProgress` snapshots
  so the toolbar/footer stays responsive without spam.
- **Blob bytes never cross actor boundaries.** Worker writes the data to
  `~/Library/Caches/io.zenla.DarwinScan/session-<uuid>/` via `BlobWriter`,
  then sends just the ref strings to MainActor. Peak memory bounded by
  ~workerCount × one blob.

### Graph model

`ScanItem.relationships: [Relationship]` carries outgoing edges keyed by
`targetPath` (paths are stable across scans, UUIDs aren't):

| Kind             | Source                  | Target                         |
|------------------|-------------------------|--------------------------------|
| `linksDylib`     | Mach-O LC_LOAD_DYLIB    | linked library path/`@rpath/…` |
| `ownedByBundle`  | child of any `.app/.framework/.bundle/.kext/.mlpackage/.mlmodelc` | enclosing bundle path |
| `launchesProgram`| LaunchAgent / LaunchDaemon plist | program executable path |
| `sameBundle`     | reserved for future     |                                |

`DetailView` renders both outgoing relationships *and* incoming references
(scans `store.items` for anyone pointing at this item's path).

## `.darwinscan` bundle layout

```
MyScan.darwinscan/
├── metadata.json     # version (currently 2), SystemInfo, ScanOptions, timestamps
├── items.json        # array of ScanItem (the manifest, incl. context+relationships)
└── blobs/
    └── <2-char prefix>/
        └── <ref>.bin # content-addressed payload (icon PNG, strings dump…)
```

`<ref>` is `<hint>-<sha256-hex>`, e.g. `icon-3a4f...`, `strings-9b21...`.
Sharding by 2-char prefix mirrors git's loose-object scheme.

When a document is **open** the live blobs sit in
`~/Library/Caches/io.zenla.DarwinScan/session-<uuid>/` and the BlobStore
points at them. On save, `FileWrapper(url:)` streams those files into the
saved package without materializing the bytes in memory. On open, the
BlobStore registers each blob's source FileWrapper instead of copying.

## Default scan scope

Set in `Models/ScanOptions.swift`. Material that ships in an IPSW:

| Include             | Exclude                                       |
|---------------------|-----------------------------------------------|
| `/System`           | `/System/Volumes` (user data, mounts)         |
| `/bin`              | `/usr/local` (Homebrew etc.)                  |
| `/sbin`             | `/usr/spool`                                  |
| `/usr`              | `/private/var/folders`, `/private/tmp`        |

User-state paths (`/Users`, `/Applications`, `/Library`, `/Volumes`, `/opt`)
are never scanned. The UI surfaces this guarantee.

## Recipe — adding a new category

1. Add a case in `ItemCategory` (`Models/ScanItem.swift`) with `displayName`
   and `systemImageName`.
2. If the category has a structured payload, add a `struct FooInfo: Codable`
   in the same file and a corresponding optional on `ScanItem`.
3. Write `Scanning/FooInspector.swift`:

   ```swift
   nonisolated enum FooInspector {
       static func inspect(url: URL) -> FooInfo? { ... }
   }
   ```

4. In `Scanning/Scanner.swift`, the `ScanPipeline.classify(url:)` switch —
   add a dispatch arm. Order matters (richer inspectors before fall-through
   Mach-O detection). If the item should have graph edges or a custom
   `context`, update `populateContextAndRelationships` too.
5. Add a `private struct FooDetailView` in `UI/DetailView.swift` and wire it
   into `DetailContent.body`.

If the inspector touches AppKit drawing APIs (NSGraphicsContext, image
drawing), it needs to be thread-safe — see `AppBundleInspector`/
`IconInspector` for the pattern (TIFF round-trip or `CGImageSource`
thumbnail).

## Recipe — adding a new field to an existing payload

Just add the field with a sensible default (`var newField: T? = nil`). Old
`.darwinscan` bundles continue to decode because JSONDecoder tolerates
missing keys when the property has a default.

## Mach-O parsing

`Scanning/MachOInspector.swift` parses headers directly via `FileHandle`
without importing `<mach-o/loader.h>` (their C structs aren't `Sendable`).
The constants are defined inline. Reads the first 256 KB — covers headers +
load commands for all reasonable binaries.

FAT binaries: parses the fat header, then descends into the first slice for
load-command data. The extra arch names are recorded for the architecture
list but not re-parsed (load commands repeat).

## Concurrency

- `ScanStore`, `ScanDocument`, `ScanController`, `BlobStore` are
  `@MainActor`-isolated.
- `ScanWorker` is an `actor` with its own isolation domain.
- `ScanPipeline` is a `nonisolated struct: Sendable` — child tasks of the
  worker's TaskGroup execute its methods directly, without any actor hops.
- `BlobWriter` is `nonisolated struct: Sendable` and just carries a directory
  URL. Concurrent writes to distinct files are safe on APFS.
- Inspectors and `FileWalker` are `nonisolated` so the pipeline can call
  them synchronously.
- Progress and batch ingestion cross actor boundaries via
  `@Sendable @MainActor` closures (`progressSink`, `batchSink`,
  `systemInfoSink`).

If you see a "main actor-isolated X in a synchronous nonisolated context"
warning when adding a helper, the fix is almost always: add `nonisolated`
to the declaration (type, extension, or `let`).

## Storage decisions

- **JSON for the manifest** because it's diff-friendly, human-inspectable, and
  fine up to tens of thousands of items. SQLite would scale further but adds
  complexity; defer it until a real scan blows past JSON's comfort zone.
- **Content-addressed blobs** so identical icons across 50 apps occupy one
  blob. Hashing twice is cheaper than storing duplicates.
- **`sha256` field on every ScanItem** so cross-scan diff is a simple set
  comparison.

## Known follow-ups (not yet built)

- Code signature parsing for team identifier extraction (we detect
  `LC_CODE_SIGNATURE` but don't parse the blob).
- DYLD shared cache *image enumeration* (we parse the header but not the
  image list — needs more dyld_cache_format.h ported in).
- Cross-scan diff UI — the schema supports it but no command/view exists yet.
- SQLite-backed `ScanStore` for very-large bundles.
- Asset catalog (`Assets.car`) extraction.
- Full strings-cache search UI (the blob is stored when extracted, but no
  global search across blobs yet).

## Testing

Test targets exist (`DarwinScanTests`, `DarwinScanUITests`) but are empty
placeholder files from the template. No real coverage yet.
