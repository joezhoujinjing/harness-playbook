#!/usr/bin/env bash
# Re-derive several of the constants in system-design/performance-arithmetic.md
# on this machine.
# Output: TSV on stdout, schema=bench.v1. Errors: line-oriented on stderr.
# Exit: 0 ok, 2 validation, 3 no python3, 6 measurement aborted.
set -uo pipefail

SIZE_MB=128
MAX_SIZE_MB=16384
WORKDIR="${TMPDIR:-/tmp}"

usage() {
  cat <<'USAGE'
bench.sh - measure local latency/throughput constants

  --size-mb N   file-IO test size in MiB, 1..16384 (default 128)
  --workdir DIR where the IO test file is written (default $TMPDIR)
  --describe    print metrics, units, statuses, and exit codes, then exit
  -h, --help    this text

Optional: set BENCH_PG_DSN to a libpq DSN to measure Postgres point-query QPS.

Every metric listed by --describe prints exactly one row, in that order,
whatever happens. Never silence. Check the status column before using a
value: only status=ok is safe to substitute into the constants table.
USAGE
}

describe() {
  cat <<'DESC'
metric	unit	notes
mem_copy_bandwidth	GB/s	memcpy, source bytes per second, after warmup
mem_read_1mb	us	derived from mem_copy_bandwidth; copy-derived, not a pure read
disk_seq_write	MB/s	includes fsync (F_FULLFSYNC on macOS) of the whole file
disk_random_read_4k	us	cache eviction attempted; degraded if the median beats 5 us, which only cache can
disk_seq_read_1mb	us	same descriptor, so it inherits the random-read cache verdict
fsync_latency	us	4K write + durable flush, median of 100, write included in timing
loopback_rtt	us	TCP round trip over 127.0.0.1, median of 1000
pg_point_query	QPS	single connection, SELECT 1, requires BENCH_PG_DSN

status	meaning
ok	measured; safe to use
degraded	measured but known-biased; do NOT substitute into the constants table
skipped	not measured; reason is in the method column

exit	0	ok
exit	2	validation
exit	3	python3 not found
exit	6	measurement aborted before the table was complete
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

case "$SIZE_MB" in
  ''|0|*[!0-9]*) echo "--size-mb must be an integer >= 1, got: '$SIZE_MB'" >&2; exit 2 ;;
esac
if [ "$SIZE_MB" -gt "$MAX_SIZE_MB" ]; then
  echo "--size-mb must be <= $MAX_SIZE_MB, got: $SIZE_MB" >&2
  echo "retry: bench.sh --size-mb $MAX_SIZE_MB" >&2
  exit 2
fi
[ -d "$WORKDIR" ] || { echo "--workdir does not exist: $WORKDIR" >&2; exit 2; }

# Refuse to fill the disk. df failure is not fatal; the check is best-effort.
AVAIL_KB="$(df -Pk "$WORKDIR" 2>/dev/null | awk 'NR==2 {print $4}')"
case "$AVAIL_KB" in
  ''|*[!0-9]*) : ;;
  *) if [ "$AVAIL_KB" -lt $((SIZE_MB * 1024 + 65536)) ]; then
       echo "not enough free space in $WORKDIR: need ${SIZE_MB} MiB, have $((AVAIL_KB / 1024)) MiB" >&2
       exit 2
     fi ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "python3 not found; required for timing" >&2; exit 3; }

printf 'schema=bench.v1\thost=%s\tas_of=%s\n' "$(uname -sm | tr ' ' '-')" "$(date -u +%Y-%m)"
printf 'metric\tvalue\tunit\tstatus\tmethod\n'

SIZE_MB="$SIZE_MB" WORKDIR="$WORKDIR" python3 - <<'PY'
import atexit, fcntl, os, socket, statistics, sys, tempfile, threading, time

MB = 1024 * 1024
size = int(os.environ["SIZE_MB"]) * MB
workdir = os.environ["WORKDIR"]

# Declared order is the contract: --describe lists these, and every one of them
# emits exactly one row even when its section dies early.
DECLARED = [
    ("mem_copy_bandwidth", "GB/s"), ("mem_read_1mb", "us"),
    ("disk_seq_write", "MB/s"), ("disk_random_read_4k", "us"),
    ("disk_seq_read_1mb", "us"), ("fsync_latency", "us"),
    ("loopback_rtt", "us"), ("pg_point_query", "QPS"),
]
rows = {}
_flushed = False


def clean(text):
    return " ".join(str(text).split())[:120] or "unknown"


def emit(metric, value, unit, status="ok", method=""):
    v = f"{value:.1f}" if isinstance(value, float) else str(value)
    rows[metric] = f"{metric}\t{v}\t{unit}\t{status}\t{method}"


def skip(metric, unit, reason):
    rows[metric] = f"{metric}\t-\t{unit}\tskipped\t{clean(reason)}"


def skip_pending(metrics, reason):
    # Only for metrics with no result yet: a late failure must never overwrite
    # a value that was already measured successfully.
    for metric, unit in metrics:
        if metric not in rows:
            skip(metric, unit, reason)


def why(exc):
    return f"{type(exc).__name__}: {clean(exc)}"


def flush_table():
    global _flushed
    if _flushed:
        return
    _flushed = True
    for metric, unit in DECLARED:
        print(rows.get(metric, f"{metric}\t-\t{unit}\tskipped\tnot-reached"), flush=True)


# Registered before any measurement so even an early crash yields a full table.
atexit.register(flush_table)

F_NOCACHE = 48       # darwin
F_FULLFSYNC = 51     # darwin


def durable_flush(fd):
    """fsync on macOS does not reach the device; F_FULLFSYNC does."""
    if sys.platform == "darwin":
        try:
            fcntl.fcntl(fd, F_FULLFSYNC)
            return "F_FULLFSYNC"
        except OSError:
            pass
    os.fsync(fd)
    return "fsync"


def open_cold(path):
    """Reopen the file trying to bypass the page cache. Returns (fd, method)."""
    fd = os.open(path, os.O_RDONLY)
    if sys.platform == "darwin":
        try:
            fcntl.fcntl(fd, F_NOCACHE, 1)
            return fd, "F_NOCACHE"
        except OSError:
            return fd, "cached"
    if hasattr(os, "posix_fadvise"):
        try:
            os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
            return fd, "POSIX_FADV_DONTNEED"
        except OSError:
            return fd, "cached"
    return fd, "cached"


# One file, one cache state: probe it once with the most sensitive metric
# (a 4K random read cannot beat ~5 us on real hardware) and apply that single
# verdict to every read metric, rather than letting each guess from its own floor.
COLD_FLOOR_4K_US = 5.0


# ---- memory ----------------------------------------------------------------
try:
    src = bytearray(b"\xa5" * (64 * MB))   # touched, so no lazy-zero page faults
    dst = bytearray(b"\x00" * (64 * MB))
    mv_s, mv_d = memoryview(src), memoryview(dst)
    for _ in range(2):                     # warmup
        mv_d[:] = mv_s
    iters = 8
    t0 = time.perf_counter()
    for _ in range(iters):
        mv_d[:] = mv_s
    el = time.perf_counter() - t0
    gbs = (iters * 64 * MB) / el / 1e9
    emit("mem_copy_bandwidth", gbs, "GB/s", method="memcpy-src-bytes")
    emit("mem_read_1mb", (MB / (gbs * 1e9)) * 1e6, "us", method="copy-derived")
except Exception as e:
    skip_pending(DECLARED[0:2], why(e))

# ---- file IO ---------------------------------------------------------------
DISK = DECLARED[2:6]
path = fd = None
try:
    fd, path = tempfile.mkstemp(dir=workdir, prefix="bench.")
    try:
        chunk = os.urandom(MB)
        t0 = time.perf_counter()
        written = 0
        while written < size:
            os.write(fd, chunk)
            written += MB
        flush = durable_flush(fd)
        el = time.perf_counter() - t0
        emit("disk_seq_write", (size / MB) / el, "MB/s", method=f"write+{flush}")
    except Exception as e:
        skip_pending(DISK, why(e))

    if "disk_seq_write" in rows and not rows["disk_seq_write"].count("\tskipped\t"):
        cold_fd = None
        try:
            cold_fd, cmethod = open_cold(path)

            rnd = []
            for i in range(2000):
                os.lseek(cold_fd, (i * 7919 * 4096) % max(size - 4096, 1), os.SEEK_SET)
                t = time.perf_counter()
                os.read(cold_fd, 4096)
                rnd.append((time.perf_counter() - t) * 1e6)
            rnd_med = statistics.median(rnd)

            cold = rnd_med >= COLD_FLOOR_4K_US
            status = "ok" if cold else "degraded"
            m = cmethod if cold else f"{cmethod}-still-cached"
            emit("disk_random_read_4k", rnd_med, "us", status=status, method=m)

            reads = []
            for i in range(64):
                os.lseek(cold_fd, (i * MB) % max(size - MB, 1), os.SEEK_SET)
                t = time.perf_counter()
                os.read(cold_fd, MB)
                reads.append((time.perf_counter() - t) * 1e6)
            emit("disk_seq_read_1mb", statistics.median(reads), "us",
                 status=status, method=m)
        except Exception as e:
            skip_pending(DISK, why(e))
        finally:
            if cold_fd is not None:
                try:
                    os.close(cold_fd)
                except OSError:
                    pass

        try:
            syncs = []
            for _ in range(100):
                os.lseek(fd, 0, os.SEEK_SET)
                t = time.perf_counter()          # write is part of the operation
                os.write(fd, chunk[:4096])
                flush = durable_flush(fd)
                syncs.append((time.perf_counter() - t) * 1e6)
            emit("fsync_latency", statistics.median(syncs), "us",
                 method=f"4K-write+{flush}")
        except Exception as e:
            skip_pending(DISK, why(e))
except Exception as e:
    skip_pending(DISK, why(e))
finally:
    skip_pending(DISK, "write-failed")
    if path is not None:
        for closer in (lambda: os.close(fd), lambda: os.unlink(path)):
            try:
                closer()
            except OSError:
                pass

# ---- loopback --------------------------------------------------------------
try:
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
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

    threading.Thread(target=echo, daemon=True).start()
    cli = socket.create_connection(addr)
    cli.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    rtts = []
    for _ in range(1000):
        t = time.perf_counter()
        cli.sendall(b"x")
        cli.recv(64)
        rtts.append((time.perf_counter() - t) * 1e6)
    cli.close()
    srv.close()
    emit("loopback_rtt", statistics.median(rtts), "us", method="tcp-nodelay-median")
except Exception as e:
    skip("loopback_rtt", "us", why(e))

# ---- postgres --------------------------------------------------------------
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
                cur.execute("SELECT 1")
                cur.fetchone()
            el = time.perf_counter() - t0
            emit("pg_point_query", 2000 / el, "QPS", method="single-conn-SELECT-1")
    except ImportError:
        skip("pg_point_query", "QPS", "psycopg-not-installed")
    except Exception as e:
        skip("pg_point_query", "QPS", why(e))
PY
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "measurement aborted: python3 exited $rc; table above may be incomplete" >&2
  exit 6
fi
echo "done" >&2
