# Data safety: what each action can change

The rule: **the library is a backup.** Nothing is deleted or overwritten unless you choose an
action that says it deletes. This page lists every action and situation, what it can change, and
the test that covers it (`Tests/ShelfCoreTests/TransferTests.swift` unless noted).

A model folder (`models--org--name`) holds:

- `blobs/`: the data, each file named by its hash (SHA-256 for large files, git's SHA-1 for small
  ones). Two blobs with the same name are byte-for-byte identical.
- `snapshots/<commit>/`: one folder per revision, of links into `blobs/`.
- `refs/main`: the commit that `main` means, which tools use to load "the latest" offline.

## The two actions that delete

| Action | Deletes | Refuses when |
|---|---|---|
| **Remove from Mac** | This Mac's copy of the model | The library copy is missing, broken or still downloading; it lacks any revision, file or link the Mac copy has; any library file the Mac copy relies on fails its hash check (read back from the drive); a file on the Mac was edited in place and differs from the library's; the Mac copy is still downloading; the library and the cache are the same folder. If this Mac's `main` differed from the library's, the activity log records it. Tests: `testRemoveLocalRequiresCompleteLibraryCopy`, `testRemoveFromMacRefusesWhenALibraryFileIsDamaged`, `testRemoveFromMacRefusesWhileTheMacCopyIsDownloading`, `testRemoveFromMacRefusesWhenAFileWasEditedInPlace`, `testRemoveFromMacRefusesWhenLibraryIsTheSameFolder`, `testMarkerOnlySnapshotIsBrokenAndNeverCoversTheMac`, `testMissingOneSnapshotLinkDoesNotCover` |
| **Delete from library…** | The library's copy of the model | Asks for confirmation first. Blocked when the library and the cache are the same folder. |

## Actions that only add

**Back up to library**, **Update library**, **Repair library**, **Copy to Mac**, **Restore from
library**, the banners' **Back up all** and **Repair all**, and dragging models onto *Library* or
*On this Mac* all run the same merge (`Transfer.backup`):

- **No copy at the destination:** the copy is built in a hidden staging folder, verified, then
  moved into place. Cancel or failure leaves nothing behind (`testCancelLeavesNothingBehind`).
- **A copy is already there:** the source is merged into it.
  - Missing files are copied to staging, verified against the source, checked against their hash
    name, and renamed into place.
  - Files already there are read and checked against their hash, and kept.
  - Revisions, refs, links and files only the destination has are left alone, broken ones included
    (`testBackupFromSecondMacKeepsTheLibrarysOtherRevision`,
    `testRestoreToMacKeepsTheMacsOwnRevision`,
    `testRepairKeepsARevisionOnlyTheLibraryHasEvenIfItIsBroken`).
  - `refs/main` keeps the destination's value, unless that revision is missing or incomplete there.
    The log says when a ref was kept or moved.
- **What a merge may replace**, and only these:
  - A destination file that fails its hash check: it's damaged and gets a verified copy
    (`testDamagedFileInTheDestinationIsReplacedNotTrusted`).
  - A link of the source's revision that is missing its blob or points elsewhere.
  - A real file where a link belongs (from `rsync -L`) is data, and is kept
    (`testRealFilesWhereLinksBelongAreKept`).
- **Refused, with nothing changed:**
  - The source is still downloading or broken (`testRefusesSourceStillDownloading`,
    `testDanglingLinkIsBroken`).
  - The destination is still downloading (`testRefusesADestinationThatIsStillDownloading`).
  - A source file fails its hash name, so a damaged copy never overwrites or sits next to good data
    (`testBackupRefusesASourceFileThatFailsItsHashName`).
- **Cancel or failure part-way:** files added before the stop stay, since they were verified. Nothing
  that was there before is removed (`testCancelledMergeLeavesTheDestinationsFilesInPlace`).

## Redownload

**Redownload**, **Redownload all** and **Download again into library…** fetch a revision with the
LocalLM SDK. The SDK never writes into the library copy itself:

1. A private staging copy is made on the drive, seeded with the files the library copy already has
   as clones (APFS: separate files sharing the data) or, on other drives, hard links.
2. Files whose hashes check out are linked into the revision. Files that fail are dropped from the
   staging copy only. A file that can't be read is an error, not damage.
3. The SDK downloads what's missing into the staging copy, and every file is checked against
   Hugging Face's hashes.
4. The result is merged into the library with the same merge as above, and the staging copy is
   removed.

Refused when the library copy is still downloading. Only offered for models, not datasets or
spaces. Test: `Tests/ShelfDownloadTests/SDKDownloadTests.swift` (opt-in, uses the network),
including another Mac's revision and `main` surviving a redownload.

## Situations

| Situation | What happens |
|---|---|
| Two Macs share one library drive, with different revisions of a model | Each backup adds its revisions; neither removes the other's. `main` on the drive stays where it was. |
| A library copy made with `rsync -r` (links missing) | Shows as broken. **Repair library** adds the links, reusing the data already on the drive; **Remove from Mac** is refused until then. |
| A library copy made with `rsync -L` (real files instead of links) | The real files are kept. |
| A download in progress on either side | Copies to or from it are refused; **Remove from Mac** is refused. |
| The drive is ejected, the app quits or the Mac loses power mid-job | A new copy appears only through a final move from staging; a merge renames verified files in before anything links to them. What's left is staging folders, which only hold Model Shelf's own temporary files. |
| Leftover staging folders | Removed at launch only when untouched for 24 hours, so another window's or another Mac's job in progress is left alone. |
| `.modelshelf-old-*` folders (left by versions up to 1.0.3 after an interrupted copy) | Never deleted, since one may hold a model's only copy. A banner points to them. |
| The cache and the library are the same folder (however the path is spelled) | Every job is blocked, and a banner says why. |
| The status on screen is out of date | Every job inspects both copies again when it runs. |

## Not covered

- What the closed-source LocalLM SDK does inside its staging copy. On APFS it can only affect that
  copy: the library's files are cloned in, and a clone is a separate file. On a Mac OS Extended
  drive they're hard links instead, so if the SDK ever wrote into an existing file rather than
  replacing it, the library's file would change too. The merge's hash check would catch the damage
  but not undo it.
- A library on exFAT: it can't store links, so copies to it fail inside staging and nothing lands.
- Writes of refs and links aren't flushed to disk individually; a power cut right after a job can
  lose the newest ones, which the next backup adds again.
