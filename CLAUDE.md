# DarwinScan — Claude orientation

A macOS app that catalogues a **system image** — `/System`, `/bin`, `/sbin`,
`/usr` (and cryptex firmlinks under `/System/Cryptexes/{OS,App,ExclaveOS}`).
NOT user data. The image can be either the running OS or an IPSW file.

Results live in a `.darwinscan` directory package. One bundle holds many
**snapshots** — chain two IPSWs to diff a macOS upgrade, or re-import the
running system over time.

## The two-phase model

Scanning is split into two independent phases:

1. **Import** (fast). Walks a `SourceProvider`, hashes every file,
   captures bytes into the content-addressed blob store, and writes
   minimal items rows with `category = .unanalyzed`. Bound to a new
   snapshot row that records source provenance (current system or IPSW).
   No inspectors run here.
2. **Analyze** (re-runnable). Iterates a snapshot's items, runs the
   inspectors against captured blob bytes (preferred) or the live
   filesystem (fallback for current-system imports without capture).
   Refines category, populates per-category payloads, symbols, strings,
   relationships. Idempotent — running again wipes stale output and
   re-applies. Records `analyzed_at` + `analyzer_version` per item and
   per snapshot.

The user explicitly chooses a source on every import. UI offers Current
System / IPSW; CLI exposes `--ipsw <file>` on `import`.

## Build

```sh
# App
xcodebuild -project DarwinScan.xcodeproj -scheme DarwinScan -configuration Debug -destination 'platform=macOS' build
# CLI
xcodebuild -project DarwinScan.xcodeproj -scheme darwin-scan -configuration Debug -destination 'platform=macOS' build
```

Deployment target macOS 26.5, Xcode 26+. Open in Xcode and Cmd+R.

## CLI

```sh
darwin-scan create scan.darwinscan
darwin-scan import scan.darwinscan                       # current system
darwin-scan import scan.darwinscan --ipsw foo.ipsw       # IPSW snapshot
darwin-scan import scan.darwinscan --then-analyze        # both phases
darwin-scan analyze scan.darwinscan                      # latest snapshot
darwin-scan analyze scan.darwinscan --snapshot 3         # specific snapshot
darwin-scan snapshots scan.darwinscan                    # list
darwin-scan delete-snapshot scan.darwinscan --snapshot 3
darwin-scan extract scan.darwinscan /tmp/recreated
```

## Project shape

Xcode 26 file-system-synchronized groups — drop a file under any source
root and it's compiled automatically.

```
DarwinScan/                # App target (SwiftUI). DarwinScanApp, ContentView, UI/, Document/
DarwinScanCore/            # Framework — all non-UI logic.
├── Models/                # ScanItem, ScanOptions, ScanProgress, SystemInfo
├── Document/              # ScanPackage, ScanStore, BlobStore, Database, Extract
├── Scanning/              # SourceProvider, Scanner (ImportPipeline/Worker),
│                          # AnalysisPipeline/Worker, FileWalker, per-domain
│                          # Inspectors, StringsExtractor, SymbolInspector
├── Search/                # SearchQuery (parser + evaluator + FTS resolution)
└── CommandLineRunner.swift  # async drivers for the CLI subcommands

DarwinScanCommand/         # CLI target (ArgumentParser): create / import /
                           # analyze / snapshots / delete-snapshot / extract

DarwinScanCoreTests/       # Swift Testing — framework unit tests
DarwinScanTests/           # Swift Testing — app-level integration tests
DarwinScanUITests/         # XCUI smoke tests
```

## Critical build settings (DO NOT casually change)

- `ENABLE_APP_SANDBOX = NO` — required for `/System`, `/bin`, `/usr`.
- `ENABLE_HARDENED_RUNTIME = YES` — we spawn `/usr/bin/strings`,
  `/usr/bin/hdiutil`, `/usr/bin/ditto`, `/usr/bin/aea`; all Apple-signed.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — *infectious*. Anything
  the worker pipelines call must be explicitly `nonisolated` (search the
  codebase for the pattern).

## Architecture sketch

```
ScanController (@Observable, MainActor)
   │   startImport(source:options:into:)
   │   startAnalysis(snapshotID:options:in:)
   │   analyzeItem(id:options:in:)
   ▼
ImportWorker (actor)    AnalysisWorker (actor)
   │                        │
   ▼                        ▼
ImportPipeline          AnalysisPipeline (uses Inspectors)
   │                        │
   ▼                        ▼
ScanStore.ingest        ScanStore.applyAnalysis
   │                        │
   ▼                        ▼
Database (SQLite v6) + BlobStore (content-addressed files)
```

`ScanStore` keeps a slim `ItemHeader` per item for the **active snapshot**
in memory; full `ScanItem` payloads come from SQLite on demand. Switching
snapshots is `setActiveSnapshot(_:)`.

## Source providers

`SourceProvider` (in `Scanning/SourceProvider.swift`) abstracts where files
come from. Two implementations:

- **`CurrentSystemSource`** — walks live filesystem. Roots default to
  `/System`, `/bin`, `/sbin`, `/usr`. The walker handles the cryptex
  firmlink carve-out so the dyld_shared_cache is visible on macOS 14+.
- **`IPSWSource`** — `ditto -x -k` the IPSW into a temp dir, parse
  `BuildManifest.plist` for `productVersion` / `productBuildVersion`,
  `hdiutil attach -nobrowse -readonly` every embedded `.dmg`. For AEA
  payloads, tries `/usr/bin/aea decrypt`; AEA-encrypted DMGs that need
  FCS keys from Apple's signing servers fail with a clear message.
  Mountpoints + extraction dirs are cleaned up via `cleanup()` after the
  import completes (or in `deinit`).

`canonicalPath(for:)` translates a mounted-IPSW URL back to its canonical
`/System/...` path so the snapshot records compare cleanly across sources.

## `.darwinscan` bundle layout (format v6)

```
MyScan.darwinscan/
├── data.db           # SQLite schema v6
├── format.txt        # "darwinscan v6"
└── blobs/<2-char>/<ref>.bin
```

Hard-break on older bundles — opening v5 (or earlier) returns
`ScanPackage.LoadError.unsupportedFormat`. No in-place migration.

SQLite tables (key shape only):

| Table             | Notable columns |
|-------------------|-----------------|
| `snapshots`       | `source_kind` (currentSystem/ipsw), `source_ref`, `import_state`, `analysis_state`, `analyzed_at`, `analyzer_version`, `system_info`, `options` |
| `items`           | 28 hot columns + `analysis_state`, `analyzed_at`, `analyzer_version`, `payload BLOB` (full ScanItem JSON). Path is **not unique** — multi-version items share a path with different sha256s/ids. |
| `snapshot_items`  | Membership: `(snapshot_id, item_id)` |
| `tags`, `architectures`, `relationships` | Rebuilt during analysis. |
| `symbols` + `symbols_fts` | FTS5 mirror via AFTER INSERT/DELETE triggers. |
| `strings_fts`     | FTS5 contentless index. `clearAnalysisOutputForItem` deletes rows by item_id. |
| `blobs`           | `(ref, sha256, size, kind)` registry. |

WAL mode + `synchronous=NORMAL`. The bundle directory is the live working
copy — no save-time copy; `File > Save` is just a WAL checkpoint.

Item identity for hashed regular files:
`UUID = SHA256("darwinscan-itemid::\(path)::\(sha256)")[0..16]`. Same
content at the same path → same id (snapshot dedup); different content at
the same path → two rows (diff backbone). Bundles use path-only identity.

## Default scan scope

| Include | Exclude |
|---------|---------|
| `/System` | `/System/Volumes` (carve-out for cryptex preboot) |
| `/bin`    | `/usr/local` |
| `/sbin`   | `/usr/spool` |
| `/usr`    | `/private/var/folders`, `/private/tmp` |

User-state paths (`/Users`, `/Applications`, `/Library`, `/Volumes`,
`/opt`) are never walked.

## Concurrency

- `ScanController` is `@Observable @MainActor`.
- `ScanStore`, `BlobStore`, `Database`, `SQLiteConnection`, every model
  and inspector are `nonisolated`.
- **`Database` is a connection pool, not a single locked handle.** One
  **writer** connection (all mutations, serialized by `writeLock`) plus a
  **pool of read-only connections** leased per query (`withReader` /
  `withWriter`). In WAL mode SQLite runs one writer concurrent with many
  readers, so UI reads (header listing, scroll lookups, FTS search) run in
  parallel with each other *and* with background analysis — nothing
  serializes behind one global mutex. Each `SQLiteConnection` is
  single-threaded-at-a-time (writer behind the lock; each reader leased to
  one caller), so its prepared-statement cache + JSON coders need no extra
  synchronization.
- **Analysis is parallel.** `AnalysisWorker.run` drives a bounded
  `TaskGroup` (`maxConcurrent ≈ cores − 1`): per-item read + inspect runs
  across cores on reader connections; writes serialize on the writer.
  Progress aggregation stays on the actor. `analyzeOne` is a `nonisolated
  static` so it runs off the actor/MainActor.
- Shared mutable state the parallel analyzer touches is locked:
  `BlobStore.refs` (`os_unfair_lock`) and
  `DyldCachedImageInspector.SharedStringTable.mapped` (`NSLock`). Both were
  `@unchecked Sendable` with unsynchronized mutation before — fix any new
  shared state the same way before reading/writing it from worker tasks.
- Worker pipelines run on `actor`s; results cross back via
  `@Sendable @MainActor` sinks.
- FTS5 strings writes are issued directly from the worker, bypassing
  the main actor — tokenising a 10 MB dump on MainActor would stall the
  UI.
- UI detail rows that need a DB lookup (linked libraries, "referenced by")
  resolve in `.task` with `@State`, never synchronously in `body`.

If you see a "main actor-isolated X in a synchronous nonisolated
context" warning, the fix is almost always `nonisolated` on the
declaration (this is why `SQLiteConnection` is `nonisolated` — its readers
run on background threads).

## Inspectors (analysis phase)

Lives under `Scanning/`. Each is `nonisolated enum X { static func
inspect(url:) -> ... }`:

- `MachOInspector` — header + load-command parse (no `<mach-o/loader.h>`
  import). Reads first 256 KB of file.
- `SymbolInspector` — LC_SYMTAB walk + `__TEXT,__objc_classname` raw
  read. (`__objc_classlist` chained-fixup chasing is a known follow-up.)
- `CodeSignatureInspector` — decodes the LC_CODE_SIGNATURE SuperBlob's
  CodeDirectory (signing id, team id, hardened-runtime flag).
- `DyldCacheInspector` + `DyldCacheLayout` + `DyldCachedImageInspector`
  — extracts symbols and `__TEXT,__cstring` from every image in a
  modern split dyld_shared_cache. Subcache `__LINKEDIT` mmaps once per
  shard so the per-image lookups don't re-fault.
- `PlistInspector`, `AppBundleInspector`, `IconInspector`,
  `LocalizationInspector`, `ManPageInspector`, `MLModelInspector`,
  `StringsExtractor`.

`AnalysisPipeline.analyze(item:)` reads bytes from the item's
`fileBlobRef` (via `BlobStore.blobURL`) and falls back to the live path
only when the blob is missing. So an IPSW snapshot is analyzable purely
from the bundle — no need for the original IPSW after import.

## Recipe — adding a new inspector

1. Drop `Scanning/FooInspector.swift` with `nonisolated enum
   FooInspector { static func inspect(url: URL) -> FooInfo? }`.
2. If the category is new: add a case to `ItemCategory` and a payload
   `FooInfo: Codable` on `ScanItem`.
3. Add a dispatch arm in `AnalysisPipeline.analyzeFile` (richer
   inspectors before the Mach-O fallback).
4. Add a `private struct FooDetailView` in `UI/DetailView.swift` and
   wire it into `DetailContent.body`.

Bump `Database.currentAnalyzerVersion` (just a string) when the
analyzer output changes meaningfully — surfaces in the UI so users know
to re-run analysis.

## Recipe — adding a queryable field

1. Add the field to the relevant `Info` struct (rides in `payload`
   automatically).
2. Promote to a real column: add to the `items` DDL in `Database.ddlCore`
   and to the bind list in `upsertItemLocked` (and the `upsertItemSQL`
   column/placeholder list).
3. Decide if it needs an index — anything on the LHS of a hot `WHERE`
   probably does.
4. Bump `Database.currentSchemaVersion` and
   `ScanPackage.packageVersion` / `formatStampLine`. No in-place
   migration today — old bundles fail to open with a clear error.

## Known follow-ups

- **Parallelize the dyld inner image loop.** The per-item analysis loop is
  parallel, but a single dyld_shared_cache item still extracts its ~3000
  images serially inside one task (it's one long-running task among many).
  `SharedStringTable` is now thread-safe and the per-symbol path no longer
  touches its shared dict, so the inner loop can be parallelized — mind
  oversubscription against the outer `TaskGroup` (don't nest unbounded
  parallelism).
- **AEA decryption with FCS keys.** `IPSWSource` tries `aea decrypt`
  with no key (works for unencrypted payloads). Modern Apple Silicon
  IPSWs ship AEA payloads whose keys live on Apple's signing servers.
  Implement the FCS fetch (or accept a pre-decrypted directory as a
  generic "filesystem source").
- **`darwin-scan diff <a> <b>`.** Schema + snapshot bookkeeping ready;
  `Database.itemsInSnapshot(id)` returns the set-of-ids per snapshot,
  so the diff is `current.symmetric-difference(parent)` plus a
  path-keyed join for "same path, different content."
- **Snapshot switcher UI.** Sidebar lists snapshots and a context menu
  activates one (`store.setActiveSnapshot(id)`), but there's no
  "viewing historical" banner yet.
- **Per-category analysis re-run.** Today: whole-snapshot or per-item.
  Re-running just "symbols extraction" across the snapshot would be
  cheaper for many edits.
- **`__objc_classlist` pointer chasing.** Today's Obj-C class
  extraction reads raw bytes from `__TEXT,__objc_classname` — mixes
  classes with method/protocol/ivar names. Proper chained-fixup walk
  through `objc_class → class_ro_t → name` is deferred.
- **Swift symbol demangling.** Raw mangled names go in `symbols.name`;
  `symbols.demangled` is always nil. Demangling needs `swift-demangle`
  from Xcode's toolchain.
- **Asset catalog (`Assets.car`).** Apple's CUICatalog SPI parses
  these but isn't public.

## Testing

```sh
xcodebuild -project DarwinScan.xcodeproj -scheme DarwinScan -configuration Debug -destination 'platform=macOS' test
# or one target:
xcodebuild -project DarwinScan.xcodeproj -scheme DarwinScan -configuration Debug -destination 'platform=macOS' -only-testing:DarwinScanCoreTests test
```

Conventions:

- New core logic → `DarwinScanCore/` + test in `DarwinScanCoreTests/`.
- `@MainActor @Suite(..., .serialized)` for suites that touch MainActor
  types.
- Tests must NOT depend on `/System` or anything outside the temp dir
  / `/bin`. `/bin` (≈37 binaries, sub-second) is the slowest sanctioned
  root.
- The macOS temp dir is `/var/...` → `/private/var/...`. Prefer
  asserting on counts or substring containment over exact path
  equality, or test `FileWalker.isExcluded` directly.

## Storage decisions (kept brief)

- **Denormalised SQLite** + `payload BLOB` per item. Hot fields are
  columns + indexes; the rest rides in the JSON payload and is only
  decoded on detail-view open.
- **Content-addressed blobs** outside SQLite. Identical icons across
  apps occupy one blob; a dylib shipped under five framework paths
  costs one capture.
- **Bundle = live working copy.** No session cache dir, no save-time
  copy. Writes land in the bundle directory as the scanner produces
  them; Save is a WAL checkpoint.
- **Connection pool over one locked handle.** `Database` keeps SQLite as
  the engine (FTS5, relational joins, ACID, single-file portability all
  fit) but stopped funnelling every call through one `os_unfair_lock`-ed
  connection. One writer + a WAL reader pool is what lets the UI stay
  responsive during analysis. Engine swap (DuckDB / Tantivy) was
  considered and rejected for now — see the git history of this file.
- **Single-pass import.** Files are hashed *while* being captured into the
  blob store (`BlobWriter.captureHashing`), not read twice.
- **Sendable / actor isolation gotcha.** `SWIFT_DEFAULT_ACTOR_ISOLATION
  = MainActor` makes every model type implicitly `@MainActor` — that
  blocks the nonisolated `Database` from using their `Codable`
  conformances. Every model (and `SQLiteConnection`) is therefore
  explicitly `nonisolated`.
