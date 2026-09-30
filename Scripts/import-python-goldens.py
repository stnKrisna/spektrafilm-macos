#!/usr/bin/env python3
"""Import spektrafilm's committed Python regression snapshots as JSON.

Usage:
    python3 Scripts/import-python-goldens.py /path/to/andreavolpato/spektrafilm

This does NOT regenerate baselines. It imports the snapshots committed by upstream,
so Swift compares against the Python project's own regression oracle.

The importer uses only the Python standard library: `.npz` files are ZIP archives
of `.npy` arrays, so no third-party packages (e.g. numpy) are required.
"""
from __future__ import annotations
import argparse
import ast
import json
import struct
import subprocess
import zipfile
from pathlib import Path

DEFAULT_RTOL = 1.5e-3
DEFAULT_ATOL = 1e-6

_MAGIC = b"\x93NUMPY"


def read_npy(archive: zipfile.ZipFile, member: str) -> list[list[int] | float]:
    """Read a single-array `.npy` member from an `.npz` ZIP archive.

    Supports NPY file format versions 1.0 and 2.0 with little/big-endian
    float64 payloads, returning `arr.reshape(-1)` as plain floats plus the
    original C-order shape.
    """
    data = archive.read(member)
    if not data.startswith(_MAGIC):
        raise SystemExit(f"{member}: not a numpy array file")
    offset = len(_MAGIC)
    major, minor = data[offset], data[offset + 1]
    offset += 2
    if major not in (1, 2, 3):
        raise SystemExit(f"{member}: unsupported NPY version {major}.{minor}")
    header_len = struct.unpack("<H", data[offset:offset + 2])[0] if major == 1 \
        else struct.unpack("<I", data[offset:offset + 4])[0]
    offset += 2 if major == 1 else 4
    header = data[offset:offset + header_len].decode("ascii")
    offset += header_len

    metadata = ast.literal_eval(header.strip())
    descr = metadata["descr"]
    if metadata["fortran_order"]:
        raise SystemExit(f"{member}: fortran-ordered arrays are not supported")
    if descr not in ("<f8", ">f8", "=f8", "f8"):
        raise SystemExit(f"{member}: expected float64, got dtype {descr!r}")
    endian = "<" if descr[0] == "<" or descr[0] == "=" else ">"
    shape = tuple(metadata["shape"])
    n = 1
    for dim in shape:
        n *= dim
    values = struct.unpack(f"{endian}{n}d", data[offset:offset + 8 * n])
    return list(values), shape, metadata["descr"]


def git_revision(repo: Path) -> str:
    try:
        return subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        return "unknown"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("upstream", type=Path, help="local checkout of andreavolpato/spektrafilm")
    ap.add_argument("--out", type=Path, default=Path(__file__).resolve().parents[1] / "Tests/Fixtures/Golden")
    args = ap.parse_args()
    upstream = args.upstream.resolve()
    rb = upstream / "tests" / "regression_baselines.py"
    if not rb.exists():
        raise SystemExit(f"Not a spektrafilm checkout: missing {rb}")

    # Avoid importing the whole runtime. Parse the simple case declarations from the
    # upstream module source, then load NPZ files directly. This keeps the importer
    # usable without installing spektrafilm's runtime dependencies.
    tree = ast.parse(rb.read_text())
    cases = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "RegressionCase":
            kv = {kw.arg: ast.literal_eval(kw.value) for kw in node.keywords}
            if kv: cases.append(kv)
    if not cases:
        raise SystemExit("Could not discover REGRESSION_CASES in upstream regression_baselines.py")

    args.out.mkdir(parents=True, exist_ok=True)
    rev = git_revision(upstream)
    imported = 0
    for case in cases:
        case_id = case["case_id"]
        npz = upstream / "tests" / "baselines" / f"{case_id}.npz"
        if not npz.exists():
            raise SystemExit(f"Missing upstream baseline: {npz}")
        with zipfile.ZipFile(npz) as archive:
            values, shape, descr = read_npy(archive, "output.npy")
        if len(shape) != 3 or shape[-1] != 3:
            raise SystemExit(f"Unexpected shape for {case_id}: {shape}")
        payload = {
            "schemaVersion": 1,
            "source": "andreavolpato/spektrafilm",
            "sourceRevision": rev,
            "caseID": case_id,
            "filmProfile": case["film_profile"],
            "printProfile": case["print_profile"],
            "imageRecipe": case["image_recipe"],
            "outputMode": case["output_mode"],
            "tolerance": {"rtol": DEFAULT_RTOL, "atol": DEFAULT_ATOL},
            "expected": {"shape": list(shape), "values": values},
        }
        out = args.out / f"{case_id}.json"
        out.write_text(json.dumps(payload, separators=(",", ":")) + "\n")
        print(f"wrote {out} ({shape}, {descr}, revision {rev[:12]})")
        imported += 1
    print(f"Imported {imported} upstream golden fixtures.")


if __name__ == "__main__":
    main()