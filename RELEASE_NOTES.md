# MacRAR Plus 2.3.2

Splits the archive map into smaller SwiftUI view properties and isolates string expressions, fixing the older Swift compiler's type-checking timeout on the GitHub macOS 14 runner. Keeps the same interface and archive behavior as 2.3.1. Build 13.

# MacRAR Plus 2.3.1

Removes unused category-count scans and caches workspace summaries per listing. Selection coverage now follows parent links rather than comparing every pair of selected paths. Filter results reuse their sort order; clearing a filter does not re-sort an unchanged tree. Cheap metadata conditions run before localized text matching. Preview navigation reuses its candidate list, discards results from an outdated listing, and file icons use an evictable cache with a 128-object count limit.

Preserves exact Unicode engine arguments, fixing selected Turkish-name previews and non-ASCII 7z passwords. Unsupported ZIP password characters are rejected before work with a 7z suggestion. Old documentation screenshots containing temporary development paths are replaced with current application captures.

Energy saver thread/dictionary budgets and event-driven task tracking are preserved. No idle timers, animations or GPU workload are added. Source and engine licenses remain intact; the displayed developer is BerkDrmz.

Validation: **530 checks passed**, 100,000-entry benchmarks, native Unicode preview/navigation, filtered sort changes and password validation. A visible idle archive window used no measurable additional CPU time over a 20-second sample (0.01-second CPU-time resolution).

# MacRAR Plus 2.3.0

Simplifies the workspace: removes the sidebar, shows only name/size by default, and places Preview, Compress and Extract actions beside the current selection. With no selection, Extract asks for a destination for the whole archive. File-type filters sit in the header; More contains optional details, testing, the archive map, exports, batch work and history. Existing shortcuts and context actions remain available.

Compression starts with destination and format. Password fields appear after Protect with password; advanced engine options expand on demand. Checked password protection requires a nonempty password. The same form is used by Finder compression.

Validation: build and **505 checks passed**. Native UI verified at normal and compact window sizes, advanced options/details toggling, encrypted ZIP creation, empty-password rejection and selected encrypted-file extraction with exact output bytes. Local arm64/macOS 13+ release, ad-hoc signed.

# MacRAR Plus 2.2.1

Selected archive entries can be compressed into a new ZIP, RAR or another supported format from the inspector, context menu or ⇧⌘K. Parent paths and empty folders are preserved, temporary copies are cleaned up, and the original archive cannot be replaced. Source deletion is disabled in this flow.

Finder now labels the configurable compression workflow “MacRAR Plus • Sıkıştır…” / “MacRAR Plus • Compress…”. Install with `./build.sh install` or the application menu; macOS exposes it under Quick Actions or Services. Installation preserves unrelated workflows. No idle watcher is added.

# MacRAR Plus 2.2.0

Adds an on-demand archive map with largest files, size totals by extension and duplicate candidates based on valid CRC32 plus file size. The Locate action selects the original entry; metadata candidates never trigger deletion. Rendering is bounded while totals use every file. No extraction or idle work is needed.

Search adds quoted phrases, exclusions, file/folder and encryption filters; extension sets are compiled once per query. Adds search help, ready-made large/empty/encrypted searches, reset filters, name copying and Finder reveal.

Exports metadata to CSV/JSON from selected subtrees or filtered listing records. CSV escapes multiline names and neutralizes spreadsheet formulas; JSON preserves exact names. Writes are atomic, cancellable before commit and cannot target source archive volumes.

This local release is not uploaded to GitHub. The obsolete upstream remote was removed. Original MIT notices and human commit authors are preserved.

## 2.1.3

Build 8 also simplifies engine argument assembly for compatibility with the macOS 14/15 Swift compilers, preserving identical command options and energy budgets.

Rollback checks output ownership and contents before reclaiming files or folders. External edits survive extraction and split-publication cancellation; retained recovery copies include destination mappings. Approved overwrite targets are rechecked after backup. Preparation and engine results carry cancellation through main-thread delivery, while completed filesystem commits retain their successful result. Extreme packed-size ratios cannot crash listing, and packed-size aggregate overflow is rejected before UI construction.

Validation: **434 checks passed**, including 65 final-audit regressions. [2.1.3 technical notes](docs/plus/2.1.3.tr.md). Local arm64/macOS 13+ package, ad-hoc signed.

## 2.1.2

Creates archives privately and publishes complete output families without replacing existing volumes. Returns the real first split/SFX volume. Streamed SHA-256 revisions protect metadata-preserving external edits and changed later volumes. Rejects ambiguous input/archive paths before engines can collapse entries; empty RAR extraction succeeds. Fixes native file-picker filtering and counts all volumes in archive disk-size summaries.

Adds extraction rollback, source preservation on failed placement, late collision protection and concurrent operation locks. Mutations verify unselected entries and archive integrity; editor saves compare the actual archived bytes with the editor copy. Expensive validation runs in utility queues with no idle polling.

Validation: **369 checks passed**. Details and limits: [2.1.2 technical notes](docs/plus/2.1.2.tr.md). Local arm64/macOS 13+ package, ad-hoc signed.

## 2.1.1

Prevents renamed extraction outputs from being overwritten by another incoming entry. ZIP/7z/TAR creation and addition use literal filenames; RAR operations with wildcard-containing paths stop safely and suggest ZIP/7z. Editor saves retain the archive version from the editing session and reject external changes before or during save, while consecutive app-owned saves advance the baseline.

Source-to-Trash cleanup verifies streamed SHA-256 content against both the original sources and actual archived bytes. Sources are detached and rechecked before Trash, with restoration on failure. Normal TAR root paths and empty link metadata are accepted; links and traversal stay blocked. Password diagnostics exclude filename payloads. Closing the creation window ends its modal loop. Deleting the last RAR entry leaves a valid empty archive and retains encrypted headers. Finder's final transfer runs on its utility operation queue.

Validation and limitations: [2.1.1 technical notes](docs/plus/2.1.1.tr.md). Local arm64/macOS 13+ package, ad-hoc signed.

## 2.1.0

Adds energy saver/balanced/fast modes, thread and compression dictionary budgets, per-file collision comparison, retrying failed queue entries, preview navigation/cache, rename and nested archives, external editor write-back, compression profiles, advanced search and persisted list preferences. Source validation, copy preparation and final transfer run away from the UI thread. Active tasks prevent quitting; archive loading is cancellable.

Fixes warning exits counted as success, RAR wildcard deletion, unsafe Finder target replacement, whitespace loss in filenames, overwritten executable permissions and bundled SFX creation/output paths. Destructive source cleanup checks the source manifest and complete archive; edits preserve concurrent external changes. Includes checksum-pinned official engine downloads and a local macOS CI definition.

Local validation and known limits: [2.1.0 technical notes](docs/plus/2.1.0.tr.md).

## 2.0.0

Native archive workspace with recent archives, file categories, sortable columns, a selection inspector, Quick Look, batch extraction/testing and local activity history.

Background listing keeps the UI responsive. Extraction checks archive paths, links and destination space, stages engine output, then merges regular files into the destination. Add/delete modify a copy and replace the original after success. Source deletion occurs only after final compression and integrity verification, using Trash.

Fixed incorrect password switches, suppressed upstream pipeline failures, archive chooser format filtering, malformed imported-type registration and unsupported RAR4 creation. Keeps the original MacRAR license and engine notices.

Local arm64/macOS 13+ build, ad-hoc signed. Link-containing archives are intentionally rejected; split archives cannot be edited.
