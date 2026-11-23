#!/usr/bin/env python3
"""Builds a fake Hugging Face cache and model library for App Store screenshots.

    python3 packaging/screenshots/make_demo_library.py [--root build/demo] [--scenario tidy|attention]

Layout (both are real hub folders that Model Shelf scans like any other):

    <root>/Mac/.cache/huggingface/hub        the "Hugging Face cache"
    <root>/ModelDrive/models/hub             the "model library"
    <root>/activity.jsonl                    a seeded activity log

Model weights are sparse files: they report their real size (GBs) but take no space on disk.
Small JSON files are written for real. Everything is rebuilt from scratch on each run.

Scenarios:
    tidy       a healthy library, two new downloads on the Mac and one still downloading
    attention  adds a library copy broken by a copy that skipped the snapshot links (repairable
               from the Mac) and one broken copy that only the library has (needs a redownload)
    review     tidy plus the repairable copy; with --tiny, a library App Review can unzip and use
"""
import argparse
import hashlib
import json
import os
import shutil
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

GB = 1_000_000_000
SHARD = 5 * GB

# (repo id, weight bytes). Sizes are close to the real 4-bit MLX conversions.
MODELS = {
    "qwen3-8b": ("mlx-community/Qwen3-8B-4bit", int(4.62 * GB)),
    "qwen3-30b": ("mlx-community/Qwen3-30B-A3B-4bit", int(17.19 * GB)),
    "qwen3-4b": ("mlx-community/Qwen3-4B-4bit", int(2.26 * GB)),
    "coder": ("mlx-community/Qwen2.5-Coder-14B-Instruct-4bit", int(8.31 * GB)),
    "vl": ("mlx-community/Qwen2.5-VL-7B-Instruct-4bit", int(5.64 * GB)),
    "gemma": ("mlx-community/gemma-3-12b-it-4bit", int(8.07 * GB)),
    "llama": ("mlx-community/Llama-3.2-3B-Instruct-4bit", int(1.81 * GB)),
    "mistral-small": ("mlx-community/Mistral-Small-3.2-24B-Instruct-2506-4bit", int(13.28 * GB)),
    "mistral-7b": ("mlx-community/Mistral-7B-Instruct-v0.3-4bit", int(4.08 * GB)),
    "gpt-oss": ("mlx-community/gpt-oss-20b-MXFP4-Q8", int(12.10 * GB)),
    "r1": ("mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit", int(4.28 * GB)),
    "phi": ("mlx-community/Phi-4-mini-instruct-4bit", int(2.16 * GB)),
    "smol": ("mlx-community/SmolLM3-3B-4bit", int(1.74 * GB)),
    "whisper": ("mlx-community/whisper-large-v3-turbo", int(1.61 * GB)),
    "lfm": ("LiquidAI/LFM2-1.2B-MLX-8bit", int(1.25 * GB)),
}

# Where each model lives: "both" (synced), "mac" (new download), "library", "downloading" (Mac only,
# unfinished), "repair" (library copy without snapshot links, good copy on the Mac),
# "lost" (library copy without snapshot links, nothing on the Mac).
SCENARIOS = {
    "tidy": {
        "qwen3-8b": "both", "gemma": "both", "llama": "both", "whisper": "both",
        "qwen3-30b": "mac", "smol": "mac", "vl": "downloading",
        "coder": "library", "mistral-small": "library", "gpt-oss": "library", "r1": "library",
        "phi": "library", "lfm": "library", "mistral-7b": "library", "qwen3-4b": "library",
    },
}
SCENARIOS["attention"] = dict(SCENARIOS["tidy"], **{"qwen3-4b": "repair", "mistral-7b": "lost"})
# For App Review (with --tiny): everything works offline. No "lost" copy, whose redownload would
# ask Hugging Face for a commit that doesn't exist.
SCENARIOS["review"] = dict(SCENARIOS["tidy"], **{"qwen3-4b": "repair"})


def sha(kind, *parts):
    h = hashlib.sha256() if kind == 256 else hashlib.sha1()
    h.update("/".join(parts).encode())
    return h.hexdigest()


def repo_files(repo_id, weights):
    """[(filename, size or bytes, is_lfs)] for a typical MLX repo."""
    name = repo_id.split("/")[1]
    shards = max(1, -(-weights // SHARD))
    files = [
        ("config.json", json.dumps({"model_type": name.split("-")[0].lower(), "quantization": {"bits": 4, "group_size": 64}}, indent=2).encode(), False),
        ("generation_config.json", json.dumps({"do_sample": True, "temperature": 0.7}, indent=2).encode(), False),
        ("special_tokens_map.json", json.dumps({"eos_token": "<|endoftext|>"}, indent=2).encode(), False),
        ("tokenizer_config.json", json.dumps({"model_max_length": 131072}, indent=2).encode() * 40, False),
        ("README.md", f"# {repo_id}\n\nConverted to MLX format.\n".encode(), False),
        ("tokenizer.json", 11_422_654 if SHARD > 1_000_000 else 11_422, True),
    ]
    if shards == 1:
        files.append(("model.safetensors", weights, True))
    else:
        index = {"metadata": {"total_size": weights}, "weight_map": {}}
        files.append(("model.safetensors.index.json", json.dumps(index).encode() * 300, False))
        for i in range(shards):
            size = min(SHARD, weights - i * SHARD)
            files.append((f"model-{i + 1:05d}-of-{shards:05d}.safetensors", size, True))
    return files


def write_blob(path, content):
    with open(path, "wb") as f:
        if isinstance(content, bytes):
            f.write(content)
        else:
            f.truncate(content)  # sparse: real size, no blocks (zero bytes either way)


def make_repo(hub, repo_id, weights, state, age_days):
    org, name = repo_id.split("/")
    repo = hub / f"models--{org}--{name}"
    commit = sha(1, repo_id, "main")
    (repo / "blobs").mkdir(parents=True)
    (repo / "refs").mkdir()
    (repo / "refs" / "main").write_text(commit)
    snap = repo / "snapshots" / commit
    snap.mkdir(parents=True)
    files = repo_files(repo_id, weights)
    for i, (fname, content, lfs) in enumerate(files):
        blob = sha(256 if lfs else 1, repo_id, fname)
        last = i == len(files) - 1
        if state == "downloading" and last:
            write_blob(repo / "blobs" / f"{blob}.incomplete", content // 3)
            continue
        write_blob(repo / "blobs" / blob, content)
        if state != "nolinks":
            os.symlink(f"../../blobs/{blob}", snap / fname)
    if state == "nolinks":
        # What `rsync -r` leaves behind: the data, but no snapshot links.
        (snap / ".locallm-download-complete").write_text("")
    stamp = (datetime.now() - timedelta(days=age_days)).timestamp()
    os.utime(repo, (stamp, stamp))


def activity(models):
    now = datetime.now(timezone.utc).replace(microsecond=0)
    rows = []

    def add(hours_ago, action, key, nbytes=None, detail=None, source=None, duration=None, outcome="succeeded"):
        repo_id, weights = models[key]
        rows.append({
            "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"{action}/{key}/{hours_ago}")).upper(),
            "date": (now - timedelta(hours=hours_ago)).isoformat().replace("+00:00", "Z"),
            "action": action, "repoID": repo_id, "outcome": outcome,
            "revision": sha(1, repo_id, "main"),
            **({"revisionSource": source} if source else {}),
            **({"bytes": nbytes if nbytes is not None else weights} if nbytes != 0 else {}),
            **({"duration": duration} if duration else {}),
            **({"detail": detail} if detail else {}),
        })

    add(330, "Moved to library", "mistral-small", duration=118)
    add(329, "Moved to library", "gpt-oss", duration=104)
    add(260, "Repaired library copy", "coder", duration=71)
    add(200, "Downloaded into library", "r1", source="library copy", duration=262,
        detail="downloaded 1.2 GB, reused 9 files (3.1 GB) already on the drive")
    add(150, "Copied to Mac", "gemma", duration=66)
    add(98, "Removed from Mac", "phi", detail="freed on this Mac", duration=1)
    add(97, "Removed from Mac", "lfm", detail="freed on this Mac", duration=1)
    add(52, "Moved to library", "whisper", duration=14)
    add(30, "Copied to Mac", "qwen3-8b", duration=39)
    add(6, "Moved to library", "llama", duration=16, outcome="cancelled", nbytes=0)
    add(5, "Moved to library", "llama", duration=17)
    rows.sort(key=lambda r: r["date"])
    return "".join(json.dumps(r, sort_keys=True) + "\n" for r in rows)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--root", default=str(Path(__file__).resolve().parents[2] / "build" / "demo"))
    p.add_argument("--scenario", choices=sorted(SCENARIOS), default="tidy")
    p.add_argument("--tiny", action="store_true",
                   help="real (not sparse) files a millionth of the size, small enough to zip for App Review")
    args = p.parse_args()
    if args.tiny:
        global SHARD, MODELS
        SHARD //= 1_000_000
        MODELS = {k: (r, w // 1_000_000) for k, (r, w) in MODELS.items()}

    root = Path(args.root)
    if root.exists():
        shutil.rmtree(root)
    cache = root / "Mac" / ".cache" / "huggingface" / "hub"
    library = root / "ModelDrive" / "models" / "hub"
    cache.mkdir(parents=True)
    library.mkdir(parents=True)

    for i, (key, where) in enumerate(SCENARIOS[args.scenario].items()):
        repo_id, weights = MODELS[key]
        age = 2 + i * 3
        if where in ("both", "library", "repair", "lost"):
            make_repo(library, repo_id, weights, "nolinks" if where in ("repair", "lost") else "ok", age + 20)
        if where in ("both", "mac", "repair"):
            make_repo(cache, repo_id, weights, "ok", age)
        if where == "downloading":
            make_repo(cache, repo_id, weights, "downloading", 0)

    (root / "activity.jsonl").write_text(activity(MODELS))
    print(f"Demo library ({args.scenario}) in {root}")
    print(f"  cache:   {cache}")
    print(f"  library: {library}")


if __name__ == "__main__":
    main()
