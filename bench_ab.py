#!/usr/bin/env python3

import re
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

RUNS = 5
SAMPLES = RUNS * 2
SUMMARY_RE = re.compile(r"^\s+jsonz (decode|encode):\s+([0-9.]+) MiB/s \(\d+ datasets\)$", re.MULTILINE)


def run(command: list[str], cwd: Path, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
        check=False,
    )


def benchmark(root: Path, command: list[str], label: str, round_index: int) -> dict[str, float]:
    print(f"=== {label} round {round_index}/{RUNS} ===")
    completed = run(command, root, capture=True)
    print(completed.stdout, end="")
    if completed.returncode != 0:
        raise subprocess.CalledProcessError(completed.returncode, command)

    values = {metric: float(value) for metric, value in SUMMARY_RE.findall(completed.stdout)}
    if values.keys() != {"decode", "encode"}:
        raise RuntimeError(f"missing benchmark summary for {label}")
    return values


def warmup(root: Path, command: list[str], label: str) -> None:
    print(f"=== {label} warmup ===", flush=True)
    completed = run(command, root, capture=True)
    if completed.returncode != 0:
        print(completed.stdout, end="")
        raise subprocess.CalledProcessError(completed.returncode, command)


def print_summary(results: dict[str, list[dict[str, float]]]) -> None:
    print(f"\n=== A/B summary ({SAMPLES} samples each) ===")
    print(f"{'case':<6} {'metric':<8} {'mean':>10} {'min':>10} {'max':>10} {'stdev':>10} {'B vs A':>10}")
    means: dict[tuple[str, str], float] = {}

    for label in ("A", "B"):
        for metric in ("decode", "encode"):
            values = [result[metric] for result in results[label]]
            mean = statistics.mean(values)
            means[label, metric] = mean
            delta = "-" if label == "A" else f"{(mean / means['A', metric] - 1) * 100:+.2f}%"
            print(
                f"{label:<6} {metric:<8} {mean:10.2f} {min(values):10.2f} "
                f"{max(values):10.2f} {statistics.pstdev(values):10.2f} {delta:>10}"
            )


def main() -> int:
    mode = "dynamic"
    base = "HEAD"
    args = sys.argv[1:]
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--typed":
            mode = "typed"
        elif arg == "--base" and index + 1 < len(args):
            index += 1
            base = args[index]
        elif arg.startswith("--base="):
            base = arg[len("--base=") :]
        else:
            print(f"usage: {Path(sys.argv[0]).name} [--typed] [--base REF]", file=sys.stderr)
            return 2
        index += 1

    command = ["only", "bench", "typed"] if mode == "typed" else ["only", "bench"]
    root = Path(__file__).resolve().parent
    results: dict[str, list[dict[str, float]]] = {"A": [], "B": []}

    with tempfile.TemporaryDirectory(prefix="jsonz-bench-") as temp:
        baseline = Path(temp) / "head"
        completed = run(["git", "worktree", "add", "--detach", "--quiet", str(baseline), base], root)
        if completed.returncode != 0:
            return completed.returncode

        try:
            print(f"mode: {mode}")
            print(f"A: {base}")
            print("B: working tree")

            # Build, warm the caches and let the CPU settle before measuring.
            for label, bench_root in (("A", baseline), ("B", root)):
                warmup(bench_root, command, label)

            for round_index in range(1, RUNS + 1):
                order = (("A", baseline), ("B", root), ("B", root), ("A", baseline))
                for label, bench_root in order:
                    results[label].append(benchmark(bench_root, command, label, round_index))
        finally:
            run(["git", "worktree", "remove", "--force", str(baseline)], root)

    print_summary(results)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
