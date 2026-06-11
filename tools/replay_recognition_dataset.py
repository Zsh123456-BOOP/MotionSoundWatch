#!/usr/bin/env python3
"""Replay a real MotionSound CSV dataset with a lightweight DTW evaluator.

Expected layout:

    data/eval/<gesture>/positive/*.csv
    data/eval/<gesture>/negative/*.csv
    data/eval/<gesture>/distractor/*.csv
    data/eval/<gesture>/missed/*.csv
    data/eval/<gesture>/false-trigger/*.csv

The replay is intentionally standard-library-only so it can run on a fresh Mac.
It is not a replacement for the Swift runtime, but it gives a stable before/after
regression harness for recall, false positives, latency, confusion, reject
reasons, and threshold sweeps on real Watch CSV exports.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import time
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path


ROLES = ("positive", "negative", "distractor", "missed", "false-trigger")
VECTOR_COLUMNS = (
    "userAccelerationX",
    "userAccelerationY",
    "userAccelerationZ",
    "rotationRateX",
    "rotationRateY",
    "rotationRateZ",
)


@dataclass(frozen=True)
class MotionSeries:
    gesture: str
    role: str
    path: Path
    timestamps: list[float]
    vectors: list[list[float]]

    @property
    def duration(self) -> float:
        if len(self.timestamps) < 2:
            return 0.0
        return max(0.0, self.timestamps[-1] - self.timestamps[0])


def parse_float(row: dict[str, str], key: str) -> float:
    raw = row.get(key, "")
    if raw == "":
        return 0.0
    return float(raw)


def load_csv(path: Path, gesture: str, role: str) -> MotionSeries:
    with path.open("r", newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise ValueError(f"{path}: missing header")
        missing = {"timestamp", *VECTOR_COLUMNS}.difference(reader.fieldnames)
        if missing:
            raise ValueError(f"{path}: missing columns {sorted(missing)}")
        rows = list(reader)
    if len(rows) < 2:
        raise ValueError(f"{path}: needs at least two samples")
    timestamps = [parse_float(row, "timestamp") for row in rows]
    vectors = [[parse_float(row, col) for col in VECTOR_COLUMNS] for row in rows]
    return MotionSeries(gesture=gesture, role=role, path=path, timestamps=timestamps, vectors=vectors)


def discover(root: Path) -> list[MotionSeries]:
    output: list[MotionSeries] = []
    for gesture_dir in sorted(path for path in root.iterdir() if path.is_dir()):
        for role in ROLES:
            role_dir = gesture_dir / role
            if not role_dir.exists():
                continue
            for csv_path in sorted(role_dir.glob("*.csv")):
                output.append(load_csv(csv_path, gesture_dir.name, role))
    return output


def resample(series: MotionSeries, target_count: int = 48) -> list[list[float]]:
    if len(series.vectors) <= 1:
        return series.vectors
    output: list[list[float]] = []
    last_index = len(series.vectors) - 1
    for index in range(target_count):
        position = index * last_index / max(1, target_count - 1)
        lower = int(math.floor(position))
        upper = int(math.ceil(position))
        if lower == upper:
            output.append(series.vectors[lower])
            continue
        fraction = position - lower
        output.append([
            series.vectors[lower][dim] * (1 - fraction) + series.vectors[upper][dim] * fraction
            for dim in range(len(VECTOR_COLUMNS))
        ])
    return output


def normalize(frames: list[list[float]]) -> list[list[float]]:
    if not frames:
        return []
    dims = len(frames[0])
    means = [statistics.fmean(frame[dim] for frame in frames) for dim in range(dims)]
    centered = [[frame[dim] - means[dim] for dim in range(dims)] for frame in frames]
    peak = max((abs(value) for frame in centered for value in frame), default=0.0)
    scale = peak if peak > 1e-6 else 1.0
    return [[value / scale for value in frame] for frame in centered]


def frame_distance(lhs: list[float], rhs: list[float]) -> float:
    return math.sqrt(sum((a - b) ** 2 for a, b in zip(lhs, rhs)) / max(1, len(lhs)))


def dtw(lhs: MotionSeries, rhs: MotionSeries, radius: int = 8) -> float:
    left = normalize(resample(lhs))
    right = normalize(resample(rhs))
    n, m = len(left), len(right)
    inf = float("inf")
    previous = [inf] * (m + 1)
    previous[0] = 0.0
    for i in range(1, n + 1):
        current = [inf] * (m + 1)
        start = max(1, i - radius)
        end = min(m, i + radius)
        for j in range(start, end + 1):
            cost = frame_distance(left[i - 1], right[j - 1])
            current[j] = cost + min(previous[j], current[j - 1], previous[j - 1])
        previous = current
    return previous[m] / max(n, m)


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    position = (len(ordered) - 1) * pct
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] * (upper - position) + ordered[upper] * (position - lower)


def nearest_distance(candidate: MotionSeries, templates: list[MotionSeries]) -> tuple[str | None, float]:
    best_gesture: str | None = None
    best_distance = float("inf")
    for template in templates:
        distance = dtw(candidate, template)
        if distance < best_distance:
            best_distance = distance
            best_gesture = template.gesture
    return best_gesture, best_distance


def thresholds_by_gesture(positives: dict[str, list[MotionSeries]], strictness: float) -> dict[str, float]:
    thresholds: dict[str, float] = {}
    for gesture, items in positives.items():
        distances: list[float] = []
        for index, candidate in enumerate(items):
            others = [item for other_index, item in enumerate(items) if other_index != index]
            if others:
                distances.append(nearest_distance(candidate, others)[1])
        base = percentile(distances, 0.85) if distances else 0.30
        thresholds[gesture] = max(0.05, base * (1.0 + (1.0 - strictness) * 0.45) + 0.025)
    return thresholds


def evaluate(series: list[MotionSeries], strictness: float) -> dict[str, object]:
    positives: dict[str, list[MotionSeries]] = defaultdict(list)
    for item in series:
        if item.role == "positive":
            positives[item.gesture].append(item)
    templates = [item for items in positives.values() for item in items]
    thresholds = thresholds_by_gesture(positives, strictness)

    rows: list[dict[str, object]] = []
    started = time.perf_counter()
    for item in series:
        if not templates:
            continue
        candidates = [template for template in templates if not (item.role == "positive" and template.path == item.path)]
        predicted, distance = nearest_distance(item, candidates)
        threshold = thresholds.get(predicted or "", 0.0)
        triggered = predicted is not None and distance <= threshold
        expected_positive = item.role in {"positive", "missed"}
        reject_reason = "triggered" if triggered else ("distanceAboveThreshold" if predicted else "noCandidate")
        rows.append({
            "gesture": item.gesture,
            "role": item.role,
            "file": str(item.path),
            "duration": item.duration,
            "predicted": predicted,
            "distance": distance,
            "threshold": threshold,
            "triggered": triggered,
            "expected_positive": expected_positive,
            "latency": min(item.duration, item.duration * 0.72) if triggered else None,
            "recognitionMs": (time.perf_counter() - started) * 1000.0 / max(1, len(rows) + 1),
            "rejectReason": reject_reason,
        })

    return summarize(rows, thresholds, strictness)


def summarize(rows: list[dict[str, object]], thresholds: dict[str, float], strictness: float) -> dict[str, object]:
    by_gesture: dict[str, dict[str, object]] = {}
    confusion: Counter[tuple[str, str]] = Counter()
    reject_histogram: Counter[str] = Counter()

    for gesture in sorted({str(row["gesture"]) for row in rows}):
        gesture_rows = [row for row in rows if row["gesture"] == gesture]
        positives = [row for row in gesture_rows if row["expected_positive"]]
        negatives = [row for row in gesture_rows if not row["expected_positive"]]
        true_positive = [row for row in positives if row["triggered"] and row["predicted"] == gesture]
        false_positive = [row for row in negatives if row["triggered"]]
        latencies = [float(row["latency"]) for row in true_positive if row["latency"] is not None]
        recognition_ms = [float(row["recognitionMs"]) for row in gesture_rows]
        by_gesture[gesture] = {
            "recall": len(true_positive) / len(positives) if positives else 0.0,
            "false_positive_rate": len(false_positive) / len(negatives) if negatives else 0.0,
            "false_triggers_per_hour_estimate": len(false_positive) * 3600.0 / max(1.0, sum(float(row.get("duration", 1.0) or 1.0) for row in negatives)),
            "average_latency": statistics.fmean(latencies) if latencies else None,
            "p50_recognitionMs": percentile(recognition_ms, 0.50),
            "p95_recognitionMs": percentile(recognition_ms, 0.95),
            "threshold": thresholds.get(gesture),
        }

    for row in rows:
        expected = str(row["gesture"]) if row["expected_positive"] else f"not-{row['gesture']}"
        predicted = str(row["predicted"]) if row["triggered"] else "none"
        confusion[(expected, predicted)] += 1
        reject_histogram[str(row["rejectReason"])] += 1

    return {
        "strictness": strictness,
        "per_gesture": by_gesture,
        "confusion_matrix": [
            {"expected": expected, "predicted": predicted, "count": count}
            for (expected, predicted), count in sorted(confusion.items())
        ],
        "reject_reason_histogram": dict(sorted(reject_histogram.items())),
        "threshold_sweep": [],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Replay MotionSound recognition dataset.")
    parser.add_argument("root", nargs="?", type=Path, default=Path("data/eval"))
    parser.add_argument("--strictness", type=float, default=0.55)
    parser.add_argument("--json", type=Path, help="Write machine-readable report JSON")
    args = parser.parse_args()

    series = discover(args.root)
    if not series:
        print(f"No CSV files found under {args.root}")
        return 1

    report = evaluate(series, strictness=max(0.0, min(1.0, args.strictness)))
    report["threshold_sweep"] = [
        evaluate(series, strictness=value)["per_gesture"]
        for value in [0.35, 0.50, 0.65, 0.80]
    ]

    text = json.dumps(report, ensure_ascii=False, indent=2)
    print(text)
    if args.json:
        args.json.write_text(text + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
