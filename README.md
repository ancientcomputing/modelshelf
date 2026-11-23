# Model Shelf

A macOS app for people who run local models and keep running out of disk. It treats an external
drive as your **model library** and the Hugging Face cache (`~/.cache/huggingface/hub`) as a
**staging area**: models download to the cache, you move them to the library, and you copy them
back when you want to run them again.

Model Shelf knows the cache layout, so models keep working after they're moved. Every copy is
verified before anything is deleted.

## Why not just rsync?

Each model in the cache is a folder like `models--mlx-community--Qwen3-4B-4bit` with three parts:
`blobs/` holds the data, `snapshots/<commit>/` holds the file names as **symlinks** into
`../../blobs`, and `refs/` maps branches to commits. Copying with `rsync -r` (without `-l` or `-a`)
skips those symlinks. You get every byte of the weights, but nothing in `snapshots/`, so no library
can load the copy. Model Shelf finds copies damaged this way and repairs them.

## Features

- **One table for both places.** Each model shows where it is (library, this Mac, or both), its
  size, and whether each copy is healthy.
- **Move to library.** Copy a new download to the drive, verify it, then remove it from the cache.
- **Copy to Mac.** Bring a model back to the cache to use it. The library copy stays.
- **Remove from Mac.** Allowed only when the library copy is healthy and holds every blob and
  snapshot file the Mac copy has.
- **Repair or update the library** from a good Mac copy. Blobs already on the drive are cloned
  instead of copied, so repairing a large model takes seconds.
- **Redownload** a broken library copy that isn't on this Mac, through the
  [LocalLM SDK](https://github.com/ancientcomputing/locallm), at the exact revision you had.
- **Drag and drop** models onto *Library* or *On this Mac* in the sidebar.
- **Activity log** of every move, copy, repair, removal and download, with revisions.
- Storage bars for both disks, and banners for new downloads and copies that need attention.

## Requirements

- macOS 27 on Apple silicon (the LocalLM SDK's download support needs macOS 27)
- Xcode 27 / Swift 6.4 to build
- A library drive formatted APFS or Mac OS Extended. exFAT can't store symlinks.

## Build and run

```bash
./build-app.sh            # builds build/ModelShelf.app
./build-app.sh --install  # also copies it to /Applications
open build/ModelShelf.app
```

The build fetches the LocalLM SDK frameworks from the
[v3.0.0-GA release](https://github.com/ancientcomputing/locallm/releases/tag/v3.0.0-GA), checks
them against the published checksums, and bundles them into the app.

The first time it opens, choose your library folder in **Settings** (⌘,). The library is a hub
folder: it contains `models--org--name` folders, just like the cache. The cache location follows
`HF_HUB_CACHE` or `HF_HOME` if you set them.

## How it keeps your models safe

- **Verify, then delete.** A copy is assembled in a hidden staging folder next to its destination.
  Every copied blob is hashed (SHA-256) and compared with the source. Only then is the copy swapped
  into place, and only after that is the source removed. If anything fails or you cancel, the
  staging folder is deleted and the source is untouched.
- **Symlinks stay symlinks.** Snapshot links are recreated exactly, so the copy works wherever it
  lands.
- **No page-cache flooding.** Large files are copied with `F_NOCACHE`, so moving 40 GB doesn't
  push everything else out of memory.
- **Downloads in progress are left alone.** A model with `.incomplete` files in `blobs/` can't be
  moved.
- **Health checks look at what loaders need.** A copy is healthy only when its snapshots contain
  real model files and every link resolves. Hidden marker files such as
  `.locallm-download-complete` don't count.

## Redownloading

A redownload goes straight into the library:

1. **Pick the revision.** In order: the commit the library copy was at, the Mac copy's commit, a pin
   recorded by a LocalLM Lab app (`~/Library/Application Support/<app>/mlx-pins.json`), or the
   latest on `main`. The confirmation shows which one and where it came from, and offers
   *Download latest instead*. A branch name is resolved to a commit once, before anything
   downloads.
2. **Reuse what's on the drive.** Blobs already in the library are checked against Hugging Face's
   hashes and linked. Blobs that fail the check are deleted.
3. **Download the rest** with the SDK's
   `MLXModelProvider(cacheDirectory:pinnedRevisions:).download(_:)`, which verifies what it
   fetches, resumes interrupted files and writes its completion marker.
4. **Check the result.** Every file the SDK delivered is hashed again before the model counts as
   repaired.

Gated models need a Hugging Face token, in `HF_TOKEN` or saved with `hf auth login`.

## Activity log

Every action is written to `~/Library/Application Support/ModelShelf/activity.jsonl`, one JSON
object per line. Each entry records the time, action, model, revision (and for downloads, where the
revision came from), bytes copied, downloaded or freed, duration, and whether it succeeded, failed
or was cancelled. The **Activity** view in the sidebar shows the same log.

```bash
jq -r '[.date, .action, .repoID, .revision] | @tsv' ~/Library/Application\ Support/ModelShelf/activity.jsonl
```

## Development

```
Sources/ShelfCore       scanning, health checks, copy/verify/swap, pins, activity log (no SDK)
Sources/ShelfDownload   redownloads through the LocalLM SDK
Sources/ModelShelf      the SwiftUI app
Tests/                  XCTest suites
```

`swift test` runs the engine tests against temporary folders. Two end-to-end tests are opt-in:

```bash
# Real copy across volumes: reads one repo (never modified), uses two scratch folders it deletes.
MODELSHELF_E2E_SRC=~/.cache/huggingface/hub/models--org--small-model \
MODELSHELF_E2E_DST=/Volumes/YourDrive/.modelshelf-e2e \
MODELSHELF_E2E_BACK=/tmp/modelshelf-e2e-back \
swift test --filter CrossVolumeTests
```

```bash
# Real download through the SDK (~12 MB public test repo) into a scratch folder.
MODELSHELF_NET_E2E=/tmp/modelshelf-net swift test --filter SDKDownloadTests
```

To point the app at test folders without changing your settings, set `MODELSHELF_CACHE` and
`MODELSHELF_LIBRARY` when launching it.

## License

Apache 2.0. See [LICENSE](LICENSE).
