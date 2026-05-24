# DarwinScan — Claude orientation

A macOS app that catalogues everything interesting in the **system image** —
NOT user data. Default roots: `/System` (excluding `/System/Volumes` but
walking the cryptex firmlinks at `/System/Cryptexes/{OS,App,ExclaveOS}`),
`/bin`, `/sbin`, `/usr` (excluding `/usr/local`).

Stores results in a `.darwinscan` directory package. Each scan is recorded
as a snapshot row chained off the previous; if a re-scan produces no
content changes (deterministic-id match against parent), the new snapshot
is discarded so the bundle stays unchanged. `captureFiles` is on by
default — the original bytes of every classified file land in the
content-addressed blob store so `darwin-scan extract` can rebuild the
source tree. Cross-scan diff is content-addressed at the item level: same
(path, sha256) → same id → dedup; different sha256 at the same path →
two rows, one per generation.

## Build

```sh
# App
xcodebuild -project DarwinScan.xcodeproj -scheme DarwinScan -configuration Debug -destination 'platform=macOS' build
# CLI
xcodebuild -project DarwinScan.xcodeproj -scheme darwin-scan -configuration Debug -destination 'platform=macOS' build
```

Open in Xcode and Cmd+R to run. Deployment target is macOS 26.5; Xcode 26+.
The top-level **Run** group in the project navigator surfaces the built
`DarwinScan.app` and `darwin-scan` binaries — Cmd+click to reveal in Finder.

## CLI

`darwin-scan` ships next to the app target as a separate scheme. Two
subcommands:

```sh
# generate (default) — produce a .darwinscan bundle
darwin-scan generate LocalSystem.darwinscan

# Restrict scope, skip hashing for a fast structural scan
darwin-scan generate --roots /usr/bin --no-hash-files --no-index-man-pages out.darwinscan

# Capture file bytes so the bundle is self-contained for later extraction
darwin-scan generate --capture-files --extract-strings full.darwinscan

# Extract symbols (default on); off for a much faster scan if you don't care
darwin-scan generate --no-extract-symbols quick.darwinscan

# extract — rebuild the captured directory tree from a bundle
darwin-scan extract full.darwinscan /tmp/recreated

# Every ScanOptions toggle is exposed; see --help.
darwin-scan generate --help
darwin-scan extract --help
```

When run from `BUILT_PRODUCTS_DIR` the framework is loaded via the
`@executable_path/` rpath; copy `DarwinScanCore.framework` alongside the
binary if you install it elsewhere.

## Project shape

Xcode 26's **file-system-synchronized groups** are in use — anything you drop
inside any of the source roots is automatically compiled. No need to touch
the pbxproj to add files. We split into three buildable targets plus three
test targets:

```
DarwinScan/                        # App target (SwiftUI)
├── DarwinScanApp.swift            # @main, DocumentGroup
├── ContentView.swift              # NavigationSplitView root
├── Document/ScanDocument.swift    # ReferenceFileDocument; everything else is in core
└── UI/                            # SidebarView, ItemListView, DetailView, ScanProgressView, WelcomeView

DarwinScanCore/                    # Framework — all non-UI logic. Both app and CLI link this.
├── Models/                        # ScanItem, ScanOptions, ScanProgress, SystemInfo
├── Document/                      # ScanPackage, ScanStore, BlobStore, Database, Extract
├── Scanning/                      # Scanner + per-domain Inspectors + FileWalker
│                                  # + StringsExtractor + SymbolInspector
│                                  # + CodeSignatureInspector
├── Search/                        # SearchQuery (parser + evaluator + FTS resolution)
├── Utilities/                     # Hash, ByteFormat, SystemInfoCollector
└── CommandLineRunner.swift        # Synchronous-style scan driver for the CLI

DarwinScanCommand/                 # CLI target (ArgumentParser)
└── DarwinScanCommand.swift        # `darwin-scan generate` + `darwin-scan extract`

DarwinScanCoreTests/               # Swift Testing — framework unit tests (no app dependency)
DarwinScanTests/                   # Swift Testing — app-level integration tests (hosted in DarwinScan.app)
DarwinScanUITests/                 # XCTest — XCUI smoke tests
```

Adding a file under any synchronized root puts it in the corresponding
target. The app and CLI both `import DarwinScanCore`; the framework is
macOS-only with `SUPPORTED_PLATFORMS = macosx` and inherits the project's
MainActor default actor isolation.

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
│  ObservableObject       │         │  - extracts symbols / strings        │
│   └─ store (ScanStore)  │         │  - writes blob bytes to disk via     │
└─────────────────────────┘         │    BlobWriter                        │
            │                       │  - tokenises strings → strings_fts   │
            ▼                       │    directly on the worker thread     │
┌─────────────────────────┐         └──────────────────────────────────────┘
│ ScanStore               │                      │
│  @Observable nonisolated│         ┌──────────────────────────┐
│  items: [UUID:ItemHdr]  │         │ Inspectors (nonisolated) │
│  itemsByPath            │ ──────▶ │  MachOInspector          │
│  currentSnapshotID      │         │  SymbolInspector         │
│  blobStore: BlobStore   │         │  PlistInspector          │
│  database: Database     │         │  AppBundleInspector      │
└─────────────────────────┘         │  MLModelInspector / etc. │
            │                       └──────────────────────────┘
            ▼
┌─────────────────────────┐         ┌──────────────────────────┐
│ BlobStore (nonisolated) │         │ Database (nonisolated,   │
│  refs: Set<String>      │         │   thread-safe via lock)  │
│  cacheDirectory: URL    │         │  items + 28 hot columns  │
│  + copy(from:ref:) for  │ ◀─────▶ │  symbols + symbols_fts   │
│  whole-file capture     │         │  strings_fts (contentless│
└─────────────────────────┘         │  snapshots / snapshot_   │
                                    │  items / blobs / tags    │
                                    └──────────────────────────┘
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

### ScanStore indexes

Three indexes are maintained incrementally inside `Document/ScanStore.swift`,
all updated in `addIndexes(for:)` / `removeIndexes(for:)` on every `upsert`:

| Index                       | Shape                            | Purpose                                                         |
|-----------------------------|----------------------------------|-----------------------------------------------------------------|
| `categoryCounts`            | `[ItemCategory: Int]`            | Sidebar badge counts in O(1) per render                         |
| `pathReferencedBy`          | `[String: [UUID]]`               | Inverse adjacency — "Referenced By" panel in O(1) instead of O(N×E) |
| `itemsByOwningBundle`       | `[String: [UUID]]`               | "Contents" panel for `.app` / `.framework` / `.kext` bundles    |

These are not persisted — they're rebuilt in `load()` when a document opens.
Cost is one pass over the manifest at open time, ~10 ms for a /System scan.

**Adding a new index:** edit `addIndexes(for:)` / `removeIndexes(for:)` in
lockstep, plus `reset()`. Don't try to keep an index sorted — sort at read
time (it's cheap and avoids `Array.insert` shifting on every upsert).

## Rich search

`Search/SearchQuery.swift` parses Console.app-style faceted queries:

```
arch:x86_64 app:"Time Machine" tag:cli       # AND across filters
foo arch:arm64                                # filters + free text
bundle:CoreFoundation                         # any kind of bundle
private:true lang:en                          # boolean + value filters
symbol:NSURL                                  # FTS5: name in symbol table
strings:libcurl                               # FTS5: term in strings dump
```

Tokenizer respects `"quoted strings"` so values can contain spaces. Unknown
`field:value` pairs fall through to free text (no silent zeroing out of
results). Field aliases are intentional (`arch` / `architecture` /
`abi`; `framework` / `fw`; `kext` / `extension`; `lang` / `language` /
`locale`; `symbol` / `sym`; `strings` / `str`; …).

Free text matches across `name`, `path`, `context`, `tags`,
`executable.usageLine`, `application.bundleIdentifier`, and
`launchService.label`. Lowercased once per call to keep the per-item cost
near-zero — every filter is a substring test on already-lowered fields.

**FTS-backed filters** (`symbol:` / `strings:`) can't be answered from the
in-memory `ItemHeader`. `SearchQuery.resolveFTSItemIDs(against:)` runs a
SQLite FTS5 MATCH query for each FTS filter, intersects the resulting
item-id sets, and returns a `Set<UUID>` of allowed items. `ItemListView`
calls this once per query change and uses the set as a pre-filter before
the per-row `matches()` pass. Values are wrapped in FTS5 phrase syntax
(`"…"`) so reserved tokens like `AND` / `OR` / `:` in user input are
treated as literal text.

**Wired into `ItemListView`** via `.searchable`. The list shows recognized
filters as pill chips above the table; the `?` toolbar button opens a help
popover (driven by `SearchHelp.entries`) listing every field and example.

**Adding a new filter:** extend `SearchQuery.Filter`, add a case to
`filter(field:value:)`, `displayLabel`, `systemImage`, and `evaluate`. For
substring-on-header filters that's all. For an FTS-backed filter, add a
case to `resolveFTSItemIDs` and have `evaluate` return `true` (the FTS
pass handles restriction). Add a `SearchHelp.entries` entry either way.

## Graph model

`ScanItem.relationships: [Relationship]` carries outgoing edges keyed by
`targetPath`:

| Kind                  | Source                                                                  | Target                                                       |
|-----------------------|-------------------------------------------------------------------------|--------------------------------------------------------------|
| `linksDylib`          | Mach-O LC_LOAD_DYLIB                                                    | linked library path / `@rpath/…`                             |
| `ownedByBundle`       | child of any `.app/.framework/.bundle/.kext/.mlpackage/.mlmodelc`       | enclosing bundle path                                        |
| `containsExecutable`  | `.app/.framework/.kext` bundle                                          | the main executable Mach-O (Contents/MacOS/, Versions/A/, …) |
| `launchesProgram`     | LaunchAgent / LaunchDaemon plist                                        | program executable path                                      |
| `inDyldCache`         | virtual framework item synthesised from a dyld_shared_cache image entry | the on-disk `dyld_shared_cache_<arch>` file                  |
| `containsImage`       | reserved (cache file → image, currently emitted by the inverse path)    |                                                              |
| `sameBundle`          | reserved for future                                                     |                                                              |

`DetailView` renders both outgoing relationships *and* incoming references
(via `store.pathReferencedBy[…]`). The inverse index is the cheap way to
get "Cached Images" on a dyld cache file's page — virtuals point at the
cache via `inDyldCache`, so the index gives the cache file its children
for free.

Item identity is deterministic for hashed regular files:
`UUID = SHA256("darwinscan-itemid::\(path)::\(sha256)")[0..16]` (UUIDv4-
stamped). Bundles use `path`-only since they're conceptually identity-
stable regardless of child changes. Two items at the same path with
different sha256s get different IDs — that's exactly what makes
"content X at path P, then Y at path P" represent as two rows in two
snapshots rather than one row that mutates.

## `.darwinscan` bundle layout

```
MyScan.darwinscan/
├── data.db           # SQLite (schema v3): see table list below
├── format.txt        # one-line version stamp: "darwinscan v5"
└── blobs/
    └── <2-char prefix>/
        └── <ref>.bin # content-addressed payload (icon PNG, strings dump,
                      # whole-file capture, etc.)
```

(Bundle format version 5. Any older bundle — v2 JSON, v3 schema-v1, or
v4 schema-v2 — fails to open with
`ScanPackage.LoadError.unsupportedFormat` and instructs the user to
re-scan. There is no in-place migration. v4→v5 dropped items.path's
UNIQUE constraint to support multi-version items, added a
`system_info` column to snapshots, and made item IDs deterministic
from `(path, sha256)`.)

The SQLite database has these tables — every field a query is likely to
filter or sort on is its own indexed column:

| Table             | Purpose                                                                |
|-------------------|------------------------------------------------------------------------|
| `meta`            | `(key TEXT PK, value BLOB)` — schema_version, options JSON, last-scan timestamps. `system_info` moved out of meta and onto each snapshot row in v3. |
| `snapshots`       | `(id INTEGER PK, parent_id, label, started_at REAL, completed_at REAL, system_info BLOB)` — append-only scan history; `system_info` is the sw_vers + uname + SIP-state snapshot captured at scan start. The parent_id chain is the diff backbone. |
| `items`           | Items table — 28 columns + a `payload BLOB`. Denormalised: `path`, `name`, `category`, `size`, `modified_at`, `sha256`, `inside_bundle`, `owning_bundle_path`, `context`, `macho_kind`/`macho_platform`/`macho_min_os`/`macho_sdk`/`macho_is_fat`/`macho_is_apple`/`macho_is_xplat`/`macho_usage`, `bundle_identifier`/`bundle_short_version`/`bundle_version`/`bundle_display_name`/`bundle_exec_name`/`is_private_bundle`, `language`, `icon_blob_ref`, `strings_blob_ref`, `file_blob_ref`. The `payload` blob holds the full ScanItem JSON for fields not promoted to columns (per-category structs etc.). Indexes on `path` (non-unique — multi-version items can share a path), `category`, `owning_bundle_path`, `sha256`, `bundle_identifier`, `language`. |
| `snapshot_items`  | `(snapshot_id, item_id, PK (snapshot_id, item_id))` — membership. An item belongs to many snapshots when its content hasn't changed since the prior scan; that's how diff works. |
| `tags`            | `(item_id, tag, PK (item_id, tag))` — chips for UI display + tag-filter |
| `architectures`   | `(item_id, arch, PK (item_id, arch))` — supports `arch:` filter without JSON decode |
| `relationships`   | `(source_id, kind, target_path, target_id, note, PK (source_id, kind, target_path))` — `target_id` is reserved for finalize-time path-to-id resolution; today it's always NULL |
| `symbols`         | `(id INTEGER PK, item_id, name, demangled, kind, library_ordinal)` — populated by `SymbolInspector` (LC_SYMTAB walk + `__TEXT,__objc_classname` raw-section read for Obj-C class names) |
| `symbols_fts`     | FTS5 virtual table, `content='symbols'`, mirrors `symbols.name` + `symbols.demangled` via AFTER INSERT / AFTER DELETE triggers |
| `strings_fts`     | FTS5 virtual table, **contentless** (`content=''`), holds `(item_id UNINDEXED, item_path UNINDEXED, content)` for the strings-dump tokens of each item |
| `blobs`           | `(ref PK, sha256, size, kind)` — registry of every blob in `blobs/`; lookup by ref or sha256 |

WAL mode + `synchronous=NORMAL`. Writes are transactional: `ScanStore.ingest`
batches one transaction per ~250 ms flush (items + tags + architectures +
relationships + snapshot_items, all together). Reads happen at document
open (`Database.allItems` populates the in-memory `ItemHeader` map) and
on-demand for the heavy `ScanItem` payload via `Database.item(id:)`.

When a document is **open**, the live `data.db` lives in
`~/Library/Caches/io.zenla.DarwinScan/session-<uuid>/data.db` alongside the
blob shards. `ScanDocument.snapshot` calls `database.checkpoint()` (WAL →
main file) before `FileWrapper(url:)` streams the file into the saved
bundle. On open we copy `data.db` out of the bundle into a fresh session
cache dir and attach it — that way the saved bundle stays untouched while
the user works.

`<ref>` is `<hint>-<sha256-hex>`, e.g. `icon-3a4f...`, `strings-9b21...`,
`file-a97c...` (whole-file capture), `appicon-5d0e...`. Sharding by 2-char
prefix mirrors git's loose-object scheme.

### FTS5 maintenance gotcha

`clearItems()` can't use `INSERT INTO strings_fts(strings_fts) VALUES
('delete-all')` because that command isn't supported on contentless FTS5
tables. The implementation does `DROP TABLE strings_fts; CREATE VIRTUAL
TABLE strings_fts ...;` inside the transaction, then re-prepares the
`insertStringsFTS` and `deleteStringsFTSForItem` statements — they point
at the now-invalidated virtual table. The `symbols_fts` side uses the
external-content `content='symbols'` mode so the per-row triggers handle
the bookkeeping on DELETE FROM symbols.

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

Two cases:

1. **The field rides in `payload`** (most fields). Add it to the struct
   with a sensible default (`var newField: T? = nil`). Existing
   `.darwinscan` bundles continue to decode because JSONDecoder tolerates
   missing keys when the property has a default. No schema change.

2. **The field needs to be queryable / filterable**. Promote it to a
   real column on `items`:
   - Add the field to the struct (same as case 1) so it round-trips
     through `payload`.
   - Add a column in `Database.runDDL()` and a bind in
     `Database.upsertItemLocked` (these two must stay in lockstep).
   - Decide if it needs an index — anything that's the LHS of a `WHERE`
     in a hot query path probably does.
   - Bump `Database.currentSchemaVersion` and `ScanPackage.packageVersion`
     / `formatStampLine` if the change is incompatible. There is no
     in-place migration today (bundle v4 dropped legacy v2/v3 readers
     entirely); a future migration framework would handle this, but
     until then a schema bump means "old bundles fail to open."

## Mach-O parsing

`Scanning/MachOInspector.swift` parses headers directly via `FileHandle`
without importing `<mach-o/loader.h>` (their C structs aren't `Sendable`).
The constants are defined inline. Reads the first 256 KB — covers headers +
load commands for all reasonable binaries.

FAT binaries: parses the fat header, then descends into the first slice for
load-command data. The extra arch names are recorded for the architecture
list but not re-parsed (load commands repeat).

`Scanning/SymbolInspector.swift` does a separate Mach-O parse on
`.executable` / `.framework` items when `options.extractSymbols` is on.
Reads up to 64 KB of slice header, walks load commands looking for
LC_SYMTAB, then reads the nlist_64 table + string table from the file
(both can be tens of MB — bounded by `Limits.maxStringTableBytes`). Each
external symbol is classified by name pattern:

- `_OBJC_CLASS_$_…` → `.objcClass`, `_OBJC_METACLASS_$_…` → `.objcMetaClass`
- `_$s…` / `_$S…` (Swift mangled) → `.swiftClass` / `.swiftStruct`
- N_UNDF symbols → `.undefined` (imports)
- everything else → `.function`

LC walk gotcha: the load-command iterator must accept `cmdsize >= 8`, not
`cmdsize >= 24` — a too-strict minimum would skip past LC_BUILD_VERSION /
LC_UUID / LC_VERSION_MIN_* (all 24-byte commands that often precede
LC_SYMTAB) and break out of the loop without finding the symtab. The bug
that motivated this comment returned 0 symbols from every binary whose
LC_SYMTAB wasn't the first command.

Modern Apple binaries on disk rarely expose Obj-C class names as
LC_SYMTAB externals — the toolchain ships them as section data
referenced from `__objc_classlist`. As a partial workaround,
SymbolInspector also reads the raw bytes of the `__TEXT,__objc_classname`
and `__TEXT,__objc_methname` string pools and emits one row per
null-terminated string (tagged `.objcClass` and `.function`
respectively). Strict pointer-chasing through
`__objc_classlist → objc_class → class_ro_t → name` — which would
correctly distinguish classes from method/ivar/protocol names — is
still deferred; it needs chained-fixup decoding on modern binaries.

## DYLD shared cache + cryptex firmlinks

`Scanning/DyldCacheInspector.swift` parses the `dyld_cache_header`. On
macOS 14+ the image table moved: `imagesCountOld` at offset 0x1C is always
zero, and the real count is `imagesCount` at offset 0x1C4 with the table
itself at `imagesOffset` (0x1C0). Inspector prefers the legacy slot when
populated and falls back to the modern field. Also surfaces
`subCacheCount` (offset 0x18C) so the detail view can show "Subcaches: N"
for a split cache.

`DyldCacheInspector.enumerateImages(url:)` walks the image array and
returns each cached dylib's path, unslid load address, modTime, and
inode. The ScanPipeline emits a virtual `framework` item per image with
a synthesised path `<cachePath>#<imagePath>` (the `#` makes the same
dylib distinct across architecture caches — arm64e and x86_64 each get
their own row). Image enumeration is **gated on
`DyldCacheInspector.isSubcache(filename:)`**: each numbered
`.NN` subcache shard still classifies as `.dyldCache`, but only the
main cache file (no numeric suffix) emits virtual children — otherwise
every cached dylib reappears once per shard (the x86_64 shards
replicate the main cache's `imagesCount` in their headers). Virtual
items carry `.inDyldCache → cachePath`, no
fileBlobRef (the cache file itself is what gets captured), and a
`dyld-cache-image` tag. `darwin-scan extract` therefore restores the
cache file, not the thousands of virtuals — the user's stated
preference.

Symbol/strings extraction from inside cached images is **not yet
done**. Doing it requires resolving image addresses through the cache's
mapping table to file offsets, then parsing each image's Mach-O via the
shared LC_SYMTAB. Schema and identity are already in place; the work
lives in DyldCacheInspector + a SymbolInspector-like cached-image
walker.

`FileWalker` treats `/System/Cryptexes/{OS,App,ExclaveOS}` as cryptex
firmlinks: it resolves them through `resolvingSymlinksInPath()` and walks
the target subtree under `/System/Volumes/Preboot/Cryptexes/`,
regardless of `options.followSymlinks`. The `isExcluded()` predicate
also carves `/System/Volumes/Preboot/Cryptexes/` out of the
`/System/Volumes` exclude. Without this special-casing the
dyld_shared_cache wasn't visible on macOS 14+.

## Snapshots and incremental scans

Every scan opens one row in `snapshots`. `parent_id` points at the
previous scan's row, forming a linked list per bundle.
`snapshots.system_info` carries sw_vers + uname + hardware + SIP-state
captured at scan start, so a diff across an OS update is visible even
when no items moved.

`ScanController.startScan` (GUI) and `CommandLineRunner.runScan` (CLI)
both:

1. **Capture `SystemInfo` first.** Seeded into `store.systemInfo` for
   immediate UI surfacing and passed to `beginSnapshot(systemInfo:)`
   so the snapshot row records it.
2. **Open the existing bundle** if the destination already exists
   (CLI only — the GUI is always inside an open document). The
   previous snapshots + items are loaded; the new scan lands as an
   additional snapshot.
3. **Begin a new snapshot row**, with `parent_id` pointing at the
   previous one.
4. **Stream items through ingest.** Each item's deterministic id
   either creates a new row or upserts an existing one (same content
   = same id). Each id is also added to `snapshot_items(currentID, id)`.
5. **Finalize.** `ScanStore.finalizeScan` compares
   `itemsInSnapshot(current)` to `itemsInSnapshot(parent)`. If
   identical, the new snapshot row is deleted (and the in-memory
   view is reloaded from the parent so it reflects what's actually
   on disk). Otherwise, completed_at is stamped and the bundle is
   written with the new snapshot retained.

The discard-empty path matters because re-scanning is the obvious way
to update a bundle, and a no-op re-scan shouldn't bloat the snapshot
chain. Today the GUI surfaces the snapshot list in the sidebar with a
detail card showing diff stats vs parent; switching the displayed
items to a historical snapshot is a wired-but-not-exposed
ScanStore.reloadFromLatestSnapshot()-style call.

### Code signature

`Scanning/CodeSignatureInspector.swift` decodes the LC_CODE_SIGNATURE
SuperBlob to extract:

  - `signingIdentifier` (the bundle id the binary signed as, from the
    CodeDirectory.identOffset string)
  - `teamIdentifier` (the developer team id, when
    CodeDirectory.version >= 0x20200 has it)
  - `isHardenedRuntime` (CS_RUNTIME flag = 0x00010000 in
    CodeDirectory.flags)

MachOInspector records the slice-relative blob offset + size on
`ExecutableInfo.codeSignatureSliceOffset / codeSignatureSize`.
Scanner.makeMachOItem converts to a file-absolute offset via
`machO.sliceFileOffset(for:)` (needed for FAT binaries where the first
slice sits 16+ KB into the file) and asks CodeSignatureInspector for
the rest. DetailView surfaces a "Hardened runtime" chip + "Signed as"
+ "Team ID" rows on the Executable section.

Entitlements XML, the Requirements blob, and the CMS signature chain
are deliberately not parsed — none of them are needed for indexing,
and an entitlements viewer in DetailView is the natural follow-up.

## Concurrency

- `ScanController` is `@Observable @MainActor` — drives the SwiftUI scan
  state binding (`isRunning`, `progress`).
- `ScanStore`, `ScanDocument`, `BlobStore` are explicitly `nonisolated`
  (overriding the project's `@MainActor` default), because SwiftUI's
  `ReferenceFileDocument` invokes `init(configuration:)` / `snapshot` /
  `fileWrapper` from background threads — making the document MainActor-
  isolated would trap in `assumeIsolated`. Mutations to the store happen
  through `@Sendable @MainActor` sinks from the worker, so the
  observable invariants still hold.
- `ScanWorker` is an `actor` with its own isolation domain.
- `ScanPipeline` is a `nonisolated struct: Sendable` — child tasks of the
  worker's TaskGroup execute its methods directly, without any actor hops.
- `BlobWriter` is `nonisolated struct: Sendable` and just carries a directory
  URL. Concurrent writes to distinct files are safe on APFS.
- `Database` is `nonisolated final class @unchecked Sendable` with an
  internal `os_unfair_lock` — passable through to the worker pipeline so
  that strings tokenisation, symbol inserts, and snapshot bookkeeping
  can all happen off the main actor.
- Inspectors and `FileWalker` are `nonisolated` so the pipeline can call
  them synchronously.
- Progress and batch ingestion cross actor boundaries via
  `@Sendable @MainActor` closures (`progressSink`, `batchSink`,
  `systemInfoSink`). FTS5 strings-index writes deliberately do NOT —
  they go through the `Database` handle directly from the worker.

If you see a "main actor-isolated X in a synchronous nonisolated context"
warning when adding a helper, the fix is almost always: add `nonisolated`
to the declaration (type, extension, or `let`).

## Storage decisions

- **Denormalised SQLite (schema v2)** for the manifest. Every field a
  query is likely to filter or sort on is its own column with an index;
  the residual fields (per-category discriminated payloads, plus the
  full relationship list) live in a `payload BLOB` per item that's only
  decoded on detail-view open. The old "JSON-first" framing was retired
  in bundle format v4 — substring filters on architecture, bundle id,
  platform, language, etc. all paid an O(N) JSON decode pass under it.
- **Content-addressed blobs** so identical icons across 50 apps occupy
  one blob. Hashing twice is cheaper than storing duplicates. With
  `--capture-files`, the whole file bytes (`file-<sha256>` blobs) also
  dedupe across the scan — a dylib shipped under five framework paths
  costs one blob.
- **`sha256` field on every ScanItem** so cross-scan diff is a simple
  set comparison and the blob registry is queryable by content.
- **Snapshot rows** capture the temporal dimension: every scan opens a
  `snapshots` row chained to the previous via `parent_id` and writes
  membership into `snapshot_items`. The diff command itself is
  deferred, but the foundation is in place.

## SQLite design notes

The store keeps an in-memory `[UUID: ItemHeader]` dictionary plus a few
derived indexes as the working set for sidebar / list / search. Full
`ScanItem` payloads come from SQLite via `Database.item(id:)` on detail-
view selection. This is the "SQLite primary, in-memory working set"
arrangement — for a /System scan it's ~5-10× less RAM than holding full
`ScanItem`s in memory.

Why some fields are denormalised columns AND some stay in `payload`:
the model has 11+ optional discriminated payload structs (Executable,
App, Framework, LaunchService, MLModel, …) and a per-item
`relationships` array; promoting *every* field would balloon the
schema and the migration churn. So we promoted exactly the fields that
queries / sort orders / FTS pre-resolution actually touch — the rest
ride in `payload`, which is the **only column read on document open**
that requires a JSON decode and is **never** read during ordinary
filter passes.

Why content-addressed blobs stay as files outside SQLite: a single
strings-dump blob can be 50+ MB and a `--capture-files` whole-binary
blob can be 200 MB+; SQLite BLOBs aren't great at that size. Files in
`blobs/<2-prefix>/<ref>.bin` are also straightforward to diff between
bundles with `git diff` or `diff -r`, and `darwin-scan extract` just
`copyItem`s them out (APFS clonefile under the hood).

**Sendable / actor isolation gotcha:** the project's
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` means all model types
(`ScanItem`, `ScanOptions`, `SystemInfo`, every `*Info` struct) are
implicitly `@MainActor`, **including their `Codable` conformances**. The
nonisolated `Database` couldn't use those conformances. Every model
type is therefore explicitly `nonisolated` — if you add a new payload
struct, mark it `nonisolated` too or you'll get "main actor-isolated
conformance of X to Decodable cannot be used in nonisolated context".

## Known follow-ups (not yet built)

- **`darwin-scan diff` command.** Schema and snapshot bookkeeping are
  ready — `Database.itemsInSnapshot(id)` returns the set-of-ids for
  any snapshot, so the diff is `current.symmetric-difference(parent)`
  + a path-keyed join to find "same path, different content" entries.
  The CLI wrapper + a UI surface are the missing pieces. The
  SnapshotDetailView already shows added/removed counts inline; a
  full diff list is the natural next step.
- **Snapshot switching in the GUI.** Sidebar lists snapshots; clicking
  one shows its metadata but doesn't swap the displayed items.
  `ScanStore.reloadFromLatestSnapshot()` already exists — needs a
  `reloadSnapshot(id:)` variant and a "viewing historical" banner.
- **Symbol + strings extraction from cached dylibs inside the dyld
  shared cache.** We enumerate the image table and emit virtual
  framework items, but each virtual today has zero symbols and no
  strings. Doing it needs the cache-mapping pointer → file-offset
  translation, then a SymbolInspector-style walk per image.
- **`__objc_classlist` pointer chasing.** Today's Obj-C class
  extraction reads raw bytes from `__TEXT,__objc_classname` — which
  catches names but mixes them with method/protocol/ivar identifiers
  in the same string pool. Proper extraction needs walking the
  `__objc_classlist` pointer array through the objc_class →
  class_ro_t → name chain (with chained-fixup decoding on modern
  binaries).
- **Swift symbol demangling.** Raw mangled names go in
  `symbols.name`; `symbols.demangled` is always nil. `swift-demangle`
  ships only inside Xcode's toolchain, so demangling at scan time
  would force an Xcode dependency. Punted until either: (a) Apple
  ships a redistributable demangler, or (b) we adopt the
  swift-demangling crate / fork.
- **Asset catalog (`Assets.car`) extraction** — Apple's CUICatalog
  SPI parses these but isn't a public API. We'd need to either
  embed a `.car` parser or shell out to `assetutil`.
- **Token-pill UI for search** (`.searchable(text:tokens:)`) so
  typed filters become removable chips inside the search field
  instead of below it.

## Testing

Three test targets cover the stack:

| Target | Framework | Hosted in | What it covers |
|--------|-----------|-----------|----------------|
| `DarwinScanCoreTests` | Swift Testing | Framework-only | Search parser/evaluator (incl. FTS filter parse), ScanItem Codable round-trip, ItemHeader projection, Database upsert/load/meta/clear, ScanStore indexes, ScanPackage save/load, every inspector (PlistInspector, MachOInspector, DyldCacheInspector, LocalizationInspector, ManPageInspector, StringsExtractor), FileWalker excludes (incl. cryptex carve-out), CommandLineRunner smoke. SymbolInspector / Extract / snapshot row creation are exercised end-to-end via CommandLineRunner today; dedicated unit suites for each would be welcome additions. |
| `DarwinScanTests` | Swift Testing | `DarwinScan.app` | UTType registration, SidebarSelection equality/hashing, ScanDocument lifecycle (init / snapshot / round-trip to disk), ScanController startScan + cancel against /bin, view-construction smoke. |
| `DarwinScanUITests` | XCTest / XCUI | App runner | Welcome view, sidebar category labels, toolbar Scan button, the New Scan options sheet. Deliberately does NOT trigger a real /System scan. |

Run everything from the command line:

```sh
xcodebuild -project DarwinScan.xcodeproj -scheme DarwinScan -configuration Debug -destination 'platform=macOS' test
```

…or a single target:

```sh
xcodebuild -project DarwinScan.xcodeproj -scheme DarwinScan -configuration Debug -destination 'platform=macOS' -only-testing:DarwinScanCoreTests test
```

### Conventions

- New core logic → `DarwinScanCore/`, paired with a test in
  `DarwinScanCoreTests/`. Suites that touch `@MainActor` types use
  `@MainActor @Suite(..., .serialized)` to avoid parallel xctest
  isolation crashes.
- App-side glue → `DarwinScan/`, paired with a test in `DarwinScanTests/`.
  `@testable import DarwinScan` reaches `ScanDocument` (internal).
- New user-visible UI → add a smoke assertion to `DarwinScanUITests/`.
  Prefer the resilient predicate-based query (see
  `testSidebarListsCategoryLabels` for an example) over strict
  `app.staticTexts[...]` lookups — SwiftUI's accessibility-element
  type mapping drifts between SDK versions.
- Tests must NOT depend on the user's `/System` or anything outside the
  temp dir / `/bin`. The slowest sanctioned scan target is `/bin`
  (~37 binaries, sub-second).

### Path-canonicalisation note

The macOS temp dir lives under `/var/folders/...` and `/var` is a symlink
to `/private/var`. Foundation's `URL.path`, `URL.resolvingSymlinksInPath`,
and `NSString.resolvingSymlinksInPath` disagree about which form to
return. If a test compares paths produced by both `FileManager` and
`URL.appendingPathComponent` it'll trip over this. Prefer asserting on
counts or on substring containment over exact equality, or test the pure
predicate (`FileWalker.isExcluded`) directly.
