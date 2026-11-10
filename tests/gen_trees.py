#!/usr/bin/env python3
"""Generate reproducible benchmark trees (Newick) of increasing size.

  python3 gen_trees.py [outdir] [--neutral] [--sizes 1k,5k,20k]

  --neutral   name tips "Sample123_Iowa_2019". 
  --sizes     comma-separated subset of: 1k 5k 20k 50k 100k 500k (default: all)

Writes tree_1k.nwk ... tree_500k.nwk plus MANIFEST.tsv (sizes and SHA-256) so the
exact inputs can be archived with the paper (Zenodo) and re-created by anyone.
Trees are random birth-process-like topologies with exponential branch lengths and
tip names shaped like real surveillance IDs (A/swine/State/ID/YEAR|...), so label
widths and clustering resemble real data. Fully iterative: no recursion limit.
"""
import hashlib, os, random, sys

SIZES = {"1h": 100, "2h": 200, "5h": 500, "1k": 1_000, "5k": 5_000, "20k": 20_000, "50k": 50_000, "100k": 100_000, "500k": 500_000}
STATES = ["Iowa", "Illinois", "Minnesota", "Nebraska", "Ohio", "Indiana", "NorthCarolina", "Kansas"]

def make_tree(n_tips, seed, neutral=False):
    rng = random.Random(seed)
    # forward simulation: repeatedly split a random tip (Yule-like), then name tips
    left, right, blen = [-1], [-1], [0.0]
    tips = [0]
    for _ in range(n_tips - 1):
        k = rng.randrange(len(tips))
        v = tips[k]
        a, b = len(left), len(left) + 1
        for _ in range(2):
            left.append(-1); right.append(-1); blen.append(rng.expovariate(20.0))
        left[v], right[v] = a, b
        tips[k] = a
        tips.append(b)
    names = {}
    for i, t in enumerate(tips):
        if neutral:
            names[t] = "Sample%d_%s_%d" % (i + 1, rng.choice(STATES), rng.randrange(2010, 2025))
            continue
        names[t] = "A/swine/%s/A%08d/%d|A_/_H3N2|2024-%02d-%02d|HA|EPI_ISL_%d" % (
            rng.choice(STATES), rng.randrange(10**8), rng.randrange(1990, 2025),
            rng.randrange(1, 13), rng.randrange(1, 29), rng.randrange(10**6))
    # iterative serialisation (explicit stack)
    out, stack = [], [(0, 0)]
    while stack:
        v, st = stack.pop()
        if left[v] < 0:
            out.append("'%s':%.6f" % (names[v], blen[v]))
        elif st == 0:
            out.append("("); stack.append((v, 1)); stack.append((left[v], 0))
        elif st == 1:
            out.append(","); stack.append((v, 2)); stack.append((right[v], 0))
        else:
            out.append(")" + (":%.6f" % blen[v] if v else ""))
    return "".join(out) + ";\n"

if __name__ == "__main__":
    args = sys.argv[1:]
    neutral = "--neutral" in args
    sizes = SIZES
    if "--sizes" in args:
        want = args[args.index("--sizes") + 1].split(",")
        sizes = {k: SIZES[k] for k in want}
    pos = [a for i, a in enumerate(args) if not a.startswith("--") and (i == 0 or args[i - 1] != "--sizes")]
    outdir = pos[0] if pos else "."
    os.makedirs(outdir, exist_ok=True)
    rows = []
    for label, n in sizes.items():
        path = os.path.join(outdir, "tree_%s.nwk" % label)
        txt = make_tree(n, seed=n, neutral=neutral)
        open(path, "w").write(txt)
        rows.append((os.path.basename(path), n, hashlib.sha256(txt.encode()).hexdigest()))
        print("wrote", path, n, "tips")
    with open(os.path.join(outdir, "MANIFEST.tsv"), "w") as f:
        f.write("file\ttips\tsha256\n")
        for r in rows: f.write("%s\t%d\t%s\n" % r)
