#!/usr/bin/env python3
"""DuckDB side of the official 10M/43 ClickBench comparison (DuckDB 2.0.1).

Usage:
    .venv-duckdb201/bin/python bench/duck43_10m.py [tsv] [sql] [repeat] [db]

Defaults:
    tsv     bench/hits_10m_25col.tsv   (25 columns, `#schema:` header line)
    sql     bench/clickbench_43.sql    (official 43 queries)
    repeat  3                          (best-of-N per query)
    db      none                       (in-memory; pass a path for a file DB)

Prints one `qN<TAB>best ms` line per query plus a `# total` line to stderr,
the same shape zhdb's benchmark prints, and the peak RSS / database size when
run with a file DB. Requires duckdb 2.0.1 (`.venv-duckdb201`).
"""
import os
import resource
import sys
import time

import duckdb

if duckdb.__version__ != "2.0.1":
    raise SystemExit(
        f"duckdb 2.0.1 required, got {duckdb.__version__}; "
        "run with ../.venv-duckdb201/bin/python"
    )

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(here)

tsv = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "hits_10m_25col.tsv")
sql_file = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "clickbench_43.sql")
repeat = int(sys.argv[3]) if len(sys.argv) > 3 else 3
db_path = sys.argv[4] if len(sys.argv) > 4 else None

# Types for the 25 projected ClickBench columns. EventDate is loaded as text
# and cast to DATE so date comparisons use DuckDB's date type.
COLS = [
    ("UserID", "BIGINT"), ("AdvEngineID", "INT"), ("ResolutionWidth", "INT"),
    ("SearchPhrase", "VARCHAR"), ("EventDate", "VARCHAR"), ("RegionID", "INT"),
    ("MobilePhoneModel", "VARCHAR"), ("MobilePhone", "INT"), ("SearchEngineID", "INT"),
    ("EventTime", "BIGINT"), ("URL", "VARCHAR"), ("Title", "VARCHAR"),
    ("CounterID", "INT"), ("Referer", "VARCHAR"), ("WatchID", "BIGINT"),
    ("ClientIP", "INT"), ("IsRefresh", "INT"), ("DontCountHits", "INT"),
    ("IsLink", "INT"), ("IsDownload", "INT"), ("TraficSourceID", "INT"),
    ("URLHash", "BIGINT"), ("RefererHash", "BIGINT"), ("WindowClientWidth", "INT"),
    ("WindowClientHeight", "INT"),
]

if db_path and os.path.exists(db_path):
    os.remove(db_path)
con = duckdb.connect(db_path) if db_path else duckdb.connect()
con.execute("SET threads=8")
con.execute("SET TimeZone='UTC'")

spec = "{" + ", ".join(f"'{n}': '{t}'" for n, t in COLS) + "}"
select_list = ", ".join(
    f"{n}::DATE AS EventDate" if n == "EventDate" else n for n, _ in COLS
)
t0 = time.time()
con.execute(
    f"CREATE TABLE hits AS SELECT {select_list} FROM read_csv('{tsv}', "
    f"delim='\t', header=false, skip=1, columns={spec}, nullstr='\\\\N', "
    f"quote='', escape='')"
)
load = time.time() - t0
print(f"# load {load:.2f} s", file=sys.stderr)

queries = [line.strip() for line in open(sql_file) if line.strip() and not line.startswith("--")]
total = 0.0
for i, q in enumerate(queries, 1):
    best = float("inf")
    rows = 0
    for _ in range(repeat):
        t = time.perf_counter()
        rows = len(con.execute(q).fetchall())
        best = min(best, (time.perf_counter() - t) * 1000.0)
    total += best
    print(f"q{i}\t{best:.3f} ms\t{rows} rows", file=sys.stderr)

rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
print(f"# total {total:.1f} ms", file=sys.stderr)
print(f"# peak {rss} B", file=sys.stderr)
if db_path:
    print(f"# disk {os.path.getsize(db_path)} B", file=sys.stderr)
con.close()
