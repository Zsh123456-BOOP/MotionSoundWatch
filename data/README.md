# Motion Data Directory

Runtime data should stay out of Git. Use this directory layout for real Apple Watch captures:

```text
data/
├── raw/
│   └── <gesture-name>/
│       ├── positive-001.csv
│       ├── positive-002.csv
│       └── negative-walking-001.csv
├── reports/
└── splits/
```

Recommended first collection:

- 10 positive CSV files per gesture.
- 3-5 negative daily-motion CSV files per gesture.
- Separate left-hand and right-hand captures.
- Record Watch model, watchOS version, crown direction, strap tightness, and notes.

Run:

```bash
tools/analyze_motion_csv.py data/raw/punch/*.csv
tools/evaluate_motion_dataset.py data/raw
swift run motion-sound-profile --gesture punch --kind burst --sound punch.wav
```

The iPhone remote-collection UI can mark samples as `positive`, `negative`, or `debug`.
Keep that token in the filename when copying files into `data/raw/<gesture>/`.

Use `analyze_motion_csv.py` for one gesture or a small batch. Use
`evaluate_motion_dataset.py` after copying multiple gestures into `data/raw/`;
it checks positive/negative sample counts, sample-rate consistency, duration
spread, and first-pass `MotionBurstGate` values.

Use `motion-sound-profile` when one gesture has enough `positive` files and at
least a few `negative` daily-motion files. It reads `data/raw/<gesture>/*.csv`
and writes a `GestureProfileArchive` JSON under `data/reports/` by default. The
JSON can be sent back to the Watch as a Profile after real-device validation.
