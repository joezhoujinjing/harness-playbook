#!/usr/bin/env bash
# Re-derive the constants in system-design/performance-arithmetic.md on this machine.
# Output: TSV on stdout, schema=bench.v1. Errors: line-oriented on stderr.
# Exit: 0 ok, 2 validation, 3 no python3.
set -uo pipefail

SIZE_MB=128
WORKDIR="${TMPDIR:-/tmp}"

usage() {
  cat <<'USAGE'
bench.sh - measure local latency/throughput constants

  --size-mb N   file-IO test size in MiB (default 128)
  --workdir DIR where the IO test file is written (default $TMPDIR)
  --describe    print metrics, units, and exit codes, then exit
  -h, --help    this text

Optional: set BENCH_PG_DSN to a libpq DSN to measure Postgres point-query QPS.
Every metric listed by --describe prints exactly one row, in that order;
unavailable ones print status=skipped with a reason. Never silence.
USAGE
}

describe() {
  cat <<'DESC'
metric	unit	notes
mem_bandwidth	GB/s	sequential copy through memoryview
mem_read_1mb	us	derived from mem_bandwidth
disk_seq_write	MB/s	includes fsync of the whole file
disk_seq_read_1mb	us	page cache NOT dropped; treat as an upper bound on speed
disk_random_read_4k	us	page cache NOT dropped; treat as an upper bound on speed
fsync_latency	us	single 4K write + fsync, median of 100
loopback_rtt	us	TCP round trip over 127.0.0.1, median of 1000
pg_point_query	QPS	single connection, SELECT 1, requires BENCH_PG_DSN
exit	0	ok
exit	2	validation
exit	3	python3 not found
DESC
}

while [ $# -gt 0 ]; do
  case "$1" in
    --size-mb) SIZE_MB="${2:-}"; shift 2 || { echo "missing value for --size-mb" >&2; exit 2; } ;;
    --workdir) WORKDIR="${2:-}"; shift 2 || { echo "missing value for --workdir" >&2; exit 2; } ;;
    --describe) describe; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; echo "retry: bench.sh --help" >&2; exit 2 ;;
  esac
done

case "$SIZE_MB" in ''|*[!0-9]*) echo "--size-mb must be a positive integer, got: $SIZE_MB" >&2; exit 2 ;; esac
[ -d "$WORKDIR" ] || { echo "--workdir does not exist: $WORKDIR" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found; required for timing" >&2; exit 3; }

printf 'schema=bench.v1\thost=%s\tas_of=%s\n' "$(uname -sm | tr ' ' '-')" "$(date -u +%Y-%m)"
printf 'metric\tvalue\tunit\tstatus\tmethod\n'

SIZE_MB="$SIZE_MB" WORKDIR="$WORKDIR" python3 - <<'PY'
import atexit, os, socket, statistics, tempfile, threading, time

MB = 1024 * 1024
size = int(os.environ["SIZE_MB"]) * MB
workdir = os.environ["WORKDIR"]

# Declared order is the contract: --describe lists these, and every one of them
# emits exactly one row even when its section dies early.
DECLARED = [
    ("mem_bandwidth", "GB/s"), ("mem_read_1mb", "us"),
    ("disk_seq_write", "MB/s"), ("disk_seq_read_1mb", "us"),
    ("disk_random_read_4k", "us"), ("fsync_latency", "us"),
    ("loopback_rtt", "us"), ("pg_point_query", "QPS"),
]
rows = {}

def clean(text):
    return " ".join(str(text).split())[:120] or "unknown"

def emit(metric, value, unit, status="ok", method=""):
    v = f"{value:.1f}" if isinstance(value, float) else str(value)
    rows[metric] = f"{metric}\t{v}\t{unit}\t{status}\t{method}"

def skip(metric, unit, reason):
    rows[metric] = f"{metric}\t-\t{unit}\tskipped\t{clean(reason)}"

def why(exc):
    return f"{type(exc).__name__}: {clean(exc)}"

_flushed = False

def flush_table():
    # atexit so an unexpected crash still yields a complete, parseable table
    global _flushed
    if _flushed:
        return
    _flushed = True
    for metric, unit in DECLARED:
        print(rows.get(metric, f"{metric}\t-\t{unit}\tskipped\tnot-reached"), flush=True)

atexit.register(flush_table)

# memory bandwidth
try:
    buf = bytearray(64 * MB)
    dst = bytearray(64 * MB)
    mv_s, mv_d = memoryview(buf), memoryview(dst)
    t0 = time.perf_counter()
    for _ in range(4):
        mv_d[:] = mv_s
    el = time.perf_counter() - t0
    gbs = (4 * 64 * MB) / el / 1e9
    emit("mem_bandwidth", gbs, "GB/s", method="memoryview-copy")
    emit("mem_read_1mb", (MB / (gbs * 1e9)) * 1e6, "us", method="derived")
except Exception as e:
    skip("mem_bandwidth", "GB/s", why(e))

# file IO
path = None
try:
    fd, path = tempfile.mkstemp(dir=workdir, prefix="bench.")
    chunk = os.urandom(MB)
    t0 = time.perf_counter()
    written = 0
    while written < size:
        os.write(fd, chunk)
        written += MB
    os.fsync(fd)
    el = time.perf_counter() - t0
    emit("disk_seq_write", (size / MB) / el, "MB/s", method="write+fsync")

    reads = []
    for i in range(64):
        os.lseek(fd, (i * MB) % max(size - MB, 1), os.SEEK_SET)
        t = time.perf_counter()
        os.read(fd, MB)
        reads.append((time.perf_counter() - t) * 1e6)
    emit("disk_seq_read_1mb", statistics.median(reads), "us", method="cached-upper-bound")

    rnd = []
    for i in range(2000):
        os.lseek(fd, (i * 7919 * 4096) % max(size - 4096, 1), os.SEEK_SET)
        t = time.perf_counter()
        os.read(fd, 4096)
        rnd.append((time.perf_counter() - t) * 1e6)
    emit("disk_random_read_4k", statistics.median(rnd), "us", method="cached-upper-bound")

    syncs = []
    for _ in range(100):
        os.lseek(fd, 0, os.SEEK_SET)
        os.write(fd, chunk[:4096])
        t = time.perf_counter()
        os.fsync(fd)
        syncs.append((time.perf_counter() - t) * 1e6)
    emit("fsync_latency", statistics.median(syncs), "us", method="4K-write+fsync")
except Exception as e:
    skip("disk_seq_write", "MB/s", why(e))
finally:
    if path:
        try:
            os.close(fd); os.unlink(path)
        except Exception:
            pass

# loopback TCP round trip
try:
    srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1)
    addr = srv.getsockname()
    def echo():
        c, _ = srv.accept()
        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        while True:
            d = c.recv(64)
            if not d:
                break
            c.sendall(d)
        c.close()
    th = threading.Thread(target=echo, daemon=True); th.start()
    cli = socket.create_connection(addr)
    cli.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    rtts = []
    for _ in range(1000):
        t = time.perf_counter()
        cli.sendall(b"x"); cli.recv(64)
        rtts.append((time.perf_counter() - t) * 1e6)
    cli.close(); srv.close()
    emit("loopback_rtt", statistics.median(rtts), "us", method="tcp-nodelay-median")
except Exception as e:
    skip("loopback_rtt", "us", why(e))

# postgres
dsn = os.environ.get("BENCH_PG_DSN")
if not dsn:
    skip("pg_point_query", "QPS", "BENCH_PG_DSN-unset")
else:
    try:
        import psycopg  # type: ignore
        with psycopg.connect(dsn) as conn, conn.cursor() as cur:
            for _ in range(100):
                cur.execute("SELECT 1")
            t0 = time.perf_counter()
            for _ in range(2000):
                cur.execute("SELECT 1"); cur.fetchone()
            el = time.perf_counter() - t0
            emit("pg_point_query", 2000 / el, "QPS", method="single-conn-SELECT-1")
    except ImportError:
        skip("pg_point_query", "QPS", "psycopg-not-installed")
    except Exception as e:
        skip("pg_point_query", "QPS", why(e))

flush_table()
PY

echo "done" >&2
