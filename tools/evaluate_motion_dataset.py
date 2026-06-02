#!/usr/bin/env python3
"""Evaluate a MotionSound CSV dataset grouped by gesture.

Expected layout:

    data/raw/<gesture-name>/positive-001.csv
    data/raw/<gesture-name>/negative-walking-001.csv
    data/raw/<gesture-name>/debug-001.csv

The script stays on the Python standard library and reuses the single-file
metrics from analyze_motion_csv.py. It is meant for the first real Watch data
collection pass: check whether each gesture has enough positive/negative data,
then produce a first-pass burst gate recommendation.
"""

from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

from analyze_motion_csv import analyze_file, percentile


MIN_POSITIVE_SAMPLES = 5
TARGET_POSITIVE_SAMPLES = 10
MIN_NEGATIVE_SAMPLES = 3


@dataclass(frozen=True)
class LabeledResult:
    gesture: str
    role: str
    path: Path
    metrics: dict[str, object]


def infer_role(path: Path) -> str:
    name = path.stem.lower()
    parts = name.replace("_", "-").split("-")
    if "positive" in parts or "pos" in parts:
        return "positive"
    if "negative" in parts or "neg" in parts:
        return "negative"
    if "debug" in parts:
        return "debug"
    return "unknown"


def discover_csvs(root: Path) -> list[Path]:
    if root.is_file():
        return [root]
    return sorted(path for path in root.glob("*/*.csv") if path.is_file())


def load_results(paths: list[Path], root: Path) -> tuple[list[LabeledResult], int]:
    results: list[LabeledResult] = []
    errors = 0

    for path in paths:
        gesture = path.parent.name if path.parent != root else "ungrouped"
        role = infer_role(path)
        try:
            metrics = analyze_file(path)
        except Exception as exc:
            errors += 1
            print(f"ERROR {path}: {exc}", file=sys.stderr)
            continue
        results.append(LabeledResult(gesture=gesture, role=role, path=path, metrics=metrics))

    return results, errors


def mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def role_counts(items: list[LabeledResult]) -> dict[str, int]:
    counts = {"positive": 0, "negative": 0, "debug": 0, "unknown": 0}
    for item in items:
        counts[item.role] = counts.get(item.role, 0) + 1
    return counts


def print_collection_status(counts: dict[str, int]) -> None:
    positives = counts.get("positive", 0)
    negatives = counts.get("negative", 0)

    if positives >= TARGET_POSITIVE_SAMPLES and negatives >= MIN_NEGATIVE_SAMPLES:
        print("collection_status: good")
    elif positives >= MIN_POSITIVE_SAMPLES:
        print("collection_status: usable_for_first_profile")
    else:
        print("collection_status: needs_more_positive_samples")

    if positives < MIN_POSITIVE_SAMPLES:
        print(f"collect_next: add at least {MIN_POSITIVE_SAMPLES - positives} positive CSV files")
    elif positives < TARGET_POSITIVE_SAMPLES:
        print(f"collect_next: add {TARGET_POSITIVE_SAMPLES - positives} more positive CSV files for better calibration")

    if negatives < MIN_NEGATIVE_SAMPLES:
        print(f"collect_next: add {MIN_NEGATIVE_SAMPLES - negatives} negative daily-motion CSV files")


def print_burst_gate_suggestion(items: list[LabeledResult]) -> None:
    positives = [item for item in items if item.role == "positive"]
    negatives = [item for item in items if item.role == "negative"]
    if not positives:
        print("burst_gate: unavailable_without_positive_samples")
        return

    positive_peaks = [float(item.metrics["peak_acceleration"]) for item in positives]
    positive_durations = [float(item.metrics["duration"]) for item in positives]
    positive_axes = [str(item.metrics["dominant_axis"]) for item in positives]

    pos_floor = percentile(positive_peaks, 0.20)
    threshold = max(0.10, pos_floor * 0.75)
    print("burst_gate:")
    print(f"  minimumPeakAcceleration: {threshold:.3f}")
    print(f"  maximumDuration: {max(positive_durations) * 1.25:.3f}s")
    print(f"  expectedDominantAxis: {max(set(positive_axes), key=positive_axes.count)}")

    if negatives:
        negative_peaks = [float(item.metrics["peak_acceleration"]) for item in negatives]
        neg_ceiling = percentile(negative_peaks, 0.95)
        separation = pos_floor - neg_ceiling
        print(f"  positiveP20MinusNegativeP95: {separation:.3f}")
        if separation <= 0:
            print("  warning: negative samples overlap positive peak acceleration; rely more on DTW/margin and collect cleaner negatives")
        else:
            print(f"  negativeAwareMinimumPeakAcceleration: {max(threshold, neg_ceiling * 1.10):.3f}")


def print_gesture_report(gesture: str, items: list[LabeledResult]) -> None:
    counts = role_counts(items)
    durations = [float(item.metrics["duration"]) for item in items]
    sample_rates = [float(item.metrics["sample_rate"]) for item in items]
    peaks = [float(item.metrics["peak_acceleration"]) for item in items]

    print(f"\n== {gesture} ==")
    print(f"files: {len(items)}")
    print(f"roles: positive={counts.get('positive', 0)} negative={counts.get('negative', 0)} debug={counts.get('debug', 0)} unknown={counts.get('unknown', 0)}")
    print(f"duration: min={min(durations):.3f}s mean={mean(durations):.3f}s max={max(durations):.3f}s")
    print(f"sample_rate: min={min(sample_rates):.1f}Hz mean={mean(sample_rates):.1f}Hz max={max(sample_rates):.1f}Hz")
    print(f"peak_acceleration: min={min(peaks):.3f}g p50={percentile(peaks, 0.50):.3f}g max={max(peaks):.3f}g")
    print_collection_status(counts)
    print_burst_gate_suggestion(items)


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate MotionSound gesture CSV datasets.")
    parser.add_argument(
        "root",
        nargs="?",
        type=Path,
        default=Path("data/raw"),
        help="Dataset root containing <gesture>/*.csv, or a single CSV file.",
    )
    args = parser.parse_args()

    paths = discover_csvs(args.root)
    if not paths:
        print(f"No CSV files found under {args.root}", file=sys.stderr)
        return 1

    results, errors = load_results(paths, args.root)
    if not results:
        return 1

    grouped: dict[str, list[LabeledResult]] = defaultdict(list)
    for result in results:
        grouped[result.gesture].append(result)

    print(f"dataset: {args.root}")
    print(f"valid_files: {len(results)}")
    if errors:
        print(f"invalid_files: {errors}")

    for gesture in sorted(grouped):
        print_gesture_report(gesture, grouped[gesture])

    return 0 if errors == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
