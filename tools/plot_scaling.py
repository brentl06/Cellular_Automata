import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
K   = [1, 8, 16, 32]
cyc = [10614, 10943, 11319, 12071]                       # 7-seg readings, measured on the board
thr = [k*307200/c*150e6/1e9 for k, c in zip(K, cyc)]
ideal = [thr[0]*k for k in K]
SURF, TXT, TXT2, MUTED, GRID, S1 = "#fcfcfb", "#0b0b0b", "#52514e", "#8a8984", "#e6e5e1", "#2a78d6"
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11})
fig, ax = plt.subplots(figsize=(8, 4.8), dpi=150)
fig.patch.set_facecolor(SURF); ax.set_facecolor(SURF)
for y, lab in [(60.6, "6-core bit-packed C (M3 Pro): 60.6"), (13.3, "1-core bit-packed C: 13.3")]:
    ax.axhline(y, color=MUTED, lw=1, ls=(0, (4, 3)), zorder=1)
    ax.text(20, y + 2.2, lab, color=TXT2, va="bottom", ha="left", fontsize=9.5)
ax.plot(K, ideal, color=MUTED, lw=1, ls=":", zorder=1)
ax.text(32.6, ideal[-1], "ideal linear", color=TXT2, ha="left", va="center", fontsize=9.5)
ax.plot(K, thr, color=S1, lw=2, zorder=3)
ax.scatter(K, thr, s=64, color=S1, edgecolor=SURF, linewidth=2, zorder=4)
offs = {1: (10, -7, "left"), 8: (10, -7, "left"), 16: (-10, 12, "right"), 32: (10, -7, "left")}
for k, t in zip(K, thr):
    dx, dy, ha = offs[k]
    ax.annotate(f"{t:.1f}", (k, t), textcoords="offset points", xytext=(dx, dy), ha=ha, va="center", color=TXT, fontsize=10)
ax.set_xlim(0, 37.5); ax.set_ylim(0, 150)
ax.set_xticks(K)
ax.set_xlabel("Pipeline stages K (generations per memory pass)", color=TXT2)
ax.set_ylabel("Billion cells/s", color=TXT2)
ax.set_title("Measured throughput on Nexys A7 at 150 MHz (640x480 grid)", color=TXT, loc="left", fontsize=12.5, pad=12)
ax.grid(axis="y", color=GRID, lw=0.8); ax.set_axisbelow(True)
for sp in ["top", "right"]: ax.spines[sp].set_visible(False)
for sp in ["left", "bottom"]: ax.spines[sp].set_color(GRID)
ax.tick_params(colors=TXT2, length=0)
fig.subplots_adjust(right=0.97, left=0.09, bottom=0.13, top=0.88)
fig.savefig("docs/scaling.png", facecolor=SURF)
