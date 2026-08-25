#!/usr/bin/env python3
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Training/data/corpus.jsonl"
OUTPUT = ROOT / "Training/generated/mlx"
SYSTEM = "Return only a conservative Cleanup edit plan; preserve wording and meaning."

def main() -> None:
    records = [json.loads(line) for line in SOURCE.read_text().splitlines() if line.strip()]
    ids = set()
    splits = {"train": [], "valid": [], "test": []}
    for record in records:
        assert record["id"] not in ids
        ids.add(record["id"])
        provenance = record["provenance"]
        assert provenance == {
            "kind": "authoredSynthetic", "author": "Playground Labs",
            "license": "CC0-1.0", "source": "repository"
        }
        assert record["split"] in splits and record["raw"] and record["clean"]
        splits[record["split"]].append({"messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": record["raw"]},
            {"role": "assistant", "content": record["clean"]}
        ]})
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for split, values in splits.items():
        text = "".join(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n" for value in values)
        (OUTPUT / f"{split}.jsonl").write_text(text)
    print(json.dumps({"status": "ok", "records": len(records), "splits": {k: len(v) for k, v in splits.items()}}, sort_keys=True))

if __name__ == "__main__":
    main()
