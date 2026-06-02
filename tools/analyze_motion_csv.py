#!/usr/bin/env python3
"""Analyze exported Apple Watch motion CSV files.

The script intentionally uses only the Python standard library so it can run on
a fresh Mac. It reads the CSV format emitted by MotionSampleCSVCodec and prints
the metrics needed for first-pass burst gate tuning.
"""

from __future__ import annotations

import argparse
import csv
import math
import statistics
from pathlib import Path


REQUIRED_COLUMNS = {
    "timestamp",
    "userAccelerationX",
    "userAccelerationY",
    "userAccelerationZ",
    "rotationRateX",
    "rotationRateY",
    "rotationRateZ",
}


def parse_float(row: dict[str, str], key: str) -> float:
    value = row.get(key, "")
    if value == "":
        raise ValueError(f"missing value for {key}")
    return float(value)


def magnitude(row: dict[str, str], x_key: str, y_key: str, z_key: str) -> float:
    x = parse_float(row, x_key)
    y = parse_float(row, y_key)
    z = parse_float(row, z_key)
    return math.sqrt(x * x + y * y + z * z)


def dominant_axis(row: dict[str, str]) -> str:
    values = {
        "x": abs(parse_float(row, "userAccelerationX")),
        "y": abs(parse_float(row, "userAccelerationY")),
        "z": abs(parse_float(row, "userAccelerationZ")),
    }
    return max(values, key=values.get)


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = (len(ordered) - 1) * pct
    lower = math.floor(index)
    upper = math.ceil(index)
    if lower == upper:
        return ordered[int(index)]
    return ordered[lower] * (upper - index) + ordered[upper] * (index - lower)


def analyze_file(path: Path) -> dict[str, object]:
    with path.open("r", newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise ValueError("CSV has no header")
        missing = REQUIRED_COLUMNS.difference(reader.fieldnames)
        if missing:
            raise ValueError(f"CSV missing required columns: {', '.join(sorted(missing))}")
        rows = list(reader)

    if len(rows) < 2:
        raise ValueError("CSV needs at least two samples")

    timestamps = [parse_float(row, "timestamp") for row in rows]
    acc_magnitudes = [
        magnitude(row, "userAccelerationX", "userAccelerationY", "userAccelerationZ")
        for row in rows
    ]
    gyro_magnitudes = [
        magnitude(row, "rotationRateX", "rotationRateY", "rotationRateZ")
        for row in rows
    ]

    deltas = [
        timestamps[index] - timestamps[index - 1]
        for index in range(1, len(timestamps))
        if timestamps[index] > timestamps[index - 1]
    ]
    jerk_magnitudes = [
        abs(acc_magnitudes[index] - acc_magnitudes[index - 1]) / deltas[index - 1]
        for index in range(1, min(len(acc_magnitudes), len(deltas) + 1))
        if deltas[index - 1] > 0
    ]
    energy = [
        acc_magnitudes[index]
        + 0.25 * gyro_magnitudes[index]
        + (0.1 * jerk_magnitudes[index - 1] if index > 0 and index - 1 < len(jerk_magnitudes) else 0)
        for index in range(len(acc_magnitudes))
    ]

    peak_index = max(range(len(acc_magnitudes)), key=lambda index: acc_magnitudes[index])
    axis_counts = {"x": 0, "y": 0, "z": 0}
    for row in rows:
        axis_counts[dominant_axis(row)] += 1

    duration = timestamps[-1] - timestamps[0]
    sample_rate = (len(rows) - 1) / duration if duration > 0 else 0.0
    dominant = max(axis_counts, key=axis_counts.get)

    return {
        "file": str(path),
        "samples": len(rows),
        "duration": duration,
        "sample_rate": sample_rate,
        "peak_acceleration": acc_magnitudes[peak_index],
        "peak_rotation_rate": max(gyro_magnitudes),
        "mean_acceleration": statistics.fmean(acc_magnitudes),
        "p95_acceleration": percentile(acc_magnitudes, 0.95),
        "max_energy": max(energy),
        "p95_energy": percentile(energy, 0.95),
        "dominant_axis": dominant,
        "axis_counts": axis_counts,
    }


def print_report(results: list[dict[str, object]]) -> None:
    for result in results:
        print(f"\n== {result['file']} ==")
        print(f"samples: {result['samples']}")
        print(f"duration: {result['duration']:.3f}s")
        print(f"sample_rate: {result['sample_rate']:.1f}Hz")
        print(f"peak_acceleration: {result['peak_acceleration']:.3f}g")
        print(f"p95_acceleration: {result['p95_acceleration']:.3f}g")
        print(f"mean_acceleration: {result['mean_acceleration']:.3f}g")
        print(f"peak_rotation_rate: {result['peak_rotation_rate']:.3f}rad/s")
        print(f"max_energy: {result['max_energy']:.3f}")
        print(f"p95_energy: {result['p95_energy']:.3f}")
        print(f"dominant_axis: {result['dominant_axis']} {result['axis_counts']}")

    if len(results) > 1:
        peaks = [float(result["peak_acceleration"]) for result in results]
        durations = [float(result["duration"]) for result in results]
        print("\n== Suggested First-Pass Burst Gate ==")
        print(f"minimumPeakAcceleration: {max(0.10, percentile(peaks, 0.20) * 0.80):.3f}")
        print(f"maximumDuration: {max(durations) * 1.25:.3f}s")
        print("requiresDominantAxisMatch: true for clean burst gestures, false for messy multi-axis gestures")


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze MotionSound Watch CSV files.")
    parser.add_argument("csv", nargs="+", type=Path, help="CSV files exported from the Watch app")
    args = parser.parse_args()

    results: list[dict[str, object]] = []
    for path in args.csv:
        try:
            results.append(analyze_file(path))
        except Exception as exc:
            print(f"ERROR {path}: {exc}")

    if not results:
        return 1

    print_report(results)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
