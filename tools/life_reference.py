"""
life_reference.py

Independent, vectorized numpy implementation of toroidal Conway's Game of
Life. Two jobs:

  1. Ground truth for correctness: cross-checked against the cycle-accurate
     hardware model (see golden_model.py) over dozens of generations on
     several grid sizes, including wraparound edge cases.

  2. CPU baseline for the accelerator's benchmark story: run_benchmark()
     times N generations on a WIDTH x HEIGHT grid the same size as the
     planned FPGA grid (default 640x480), so the eventual hardware
     cells/sec number has a concrete, reproducible number to beat.

Usage:
    python3 life_reference.py                # runs the default benchmark
    python3 life_reference.py 320 240 50      # width height n_generations
"""
import sys
import time
import numpy as np


def step(grid):
    """One generation of toroidal Game of Life (B3/S23)."""
    nbrs = sum(
        np.roll(np.roll(grid, dy, axis=0), dx, axis=1)
        for dy in (-1, 0, 1) for dx in (-1, 0, 1)
        if not (dy == 0 and dx == 0)
    )
    return ((grid == 1) & ((nbrs == 2) | (nbrs == 3))) | ((grid == 0) & (nbrs == 3))


def run_benchmark(width=640, height=480, n_gens=100, density=0.35, seed=42):
    rng = np.random.default_rng(seed)
    grid = (rng.random((height, width)) < density).astype(np.uint8)

    # warm up (first call pays numpy import / cache costs)
    _ = step(grid)

    t0 = time.perf_counter()
    for _ in range(n_gens):
        grid = step(grid).astype(np.uint8)
    elapsed = time.perf_counter() - t0

    gens_per_sec = n_gens / elapsed
    cells_per_sec = gens_per_sec * width * height

    print(f"grid: {width}x{height}  generations: {n_gens}")
    print(f"elapsed: {elapsed*1000:.2f} ms")
    print(f"throughput: {gens_per_sec:.1f} generations/sec")
    print(f"throughput: {cells_per_sec/1e6:.2f} million cells/sec")
    print()
    print("Compare this cells/sec figure against the FPGA engine's measured")
    print("throughput (streamed via UART, see the accelerator's benchmark log)")
    print("to get the actual speedup number for the writeup.")
    return gens_per_sec, cells_per_sec


if __name__ == "__main__":
    args = sys.argv[1:]
    w = int(args[0]) if len(args) > 0 else 640
    h = int(args[1]) if len(args) > 1 else 480
    n = int(args[2]) if len(args) > 2 else 100
    run_benchmark(w, h, n)
