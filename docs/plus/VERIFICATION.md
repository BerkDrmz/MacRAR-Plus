# Verification — MacRAR Plus 2.0.0

- Compiled optimized arm64 application targeting macOS 13 with Swift 6.4 (Swift 5 language mode).
- Executed on this Apple Silicon Mac. Older macOS versions were not available for runtime testing.
- `./test.sh`: 72 passing checks using actual RAR/UNRAR and 7zz engines.
- All seven offered creation formats produced archives with matching file counts.
- Production extraction tested with Unicode filenames, RAR, ZIP, AES-encrypted ZIP and the macOS temporary directory.
- Invalid path/size metadata, ZIP/TAR symlinks and destination symlinks rejected. Upstream pipeline failures propagated in synchronous and asynchronous runners.
- Literal selection, overwrite, auto-rename, add/delete, cancellation and multi-volume handling verified.
- Batch ZIP/RAR extraction and integrity testing completed; separate destination folders and stop behavior verified.
- Native UI: category filtering, file selection, actual Quick Look contents and batch window inspected through accessibility and screenshots. Wide and compact archive windows inspected.
- Local package is ad-hoc signed. Developer ID signing and Apple notarization were not performed.
- Original copper/teal archive icon is drawn in `makeicon.swift` without stock symbols. Its PNG is exactly 1024×1024 with transparency; ICNS includes all standard 16–1024 px representations.
- Icon inspected at 16, 32, 64, 128 and 256 px, and confirmed in the running application's About panel. Rebuilt app signature, regenerated DMG checksum and ZIP integrity verified.

The test output is saved locally in `artifacts/test-results.txt`.
