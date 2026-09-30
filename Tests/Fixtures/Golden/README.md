# Python golden fixtures

This directory contains language-neutral JSON exports of the **committed upstream Python regression snapshots**.

Do not hand-edit numerical values. Generate/import them with:

```bash
python3 Scripts/import-python-goldens.py /path/to/andreavolpato/spektrafilm
```

The importer reads the upstream `tests/baselines/*.npz` snapshots and their case definitions, then emits JSON fixtures consumed directly by Swift Testing.

Upstream currently uses `rtol=1.5e-3`, `atol=1e-6`; those tolerances are copied into each fixture.
