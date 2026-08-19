# Rules for Making Systems Judgments Inside a Codebase

*Agent-first: you are changing code in a system you cannot profile, in a
session that ends before the load does. The constants at the bottom are your
only ground truth. Each rule is checkable against your own diff.*

1. **Name the number before you add the dependency.** A cache, a queue, a second datastore, a new index, a background worker — each must be preceded in your own reasoning by an explicit estimate that justifies it. No number means the answer is no. This is the single gate that separates sizing from vibes, and it is the one you will be tempted to skip because the architecture "obviously" needs it.

2. **The default answer is what the repo already runs.** Reuse the existing Postgres before reaching for Redis; reuse the existing cron before reaching for Kafka. Infrastructure you add is infrastructure a human operates at 3am, and you will not be there. A design that is 30% slower and has one fewer moving part is usually the better patch.

3. **Match the tier to the load, and assume the low tier.** Under ~1k QPS: one box, one Postgres, no cache, no queue — this covers the large majority of what you will be asked to build. 1k–10k: read replicas and a cache. 10k–100k: sharding, real queues, service splits. Above that, stop and say the design needs a human. Absent evidence, assume you are in the first tier; over-engineering is the failure mode agents regress to.

4. **IO inside a loop over user-controlled N is a defect until you state the bound on N.** 100 iterations x 0.5 ms round trip = 50 ms, which is an entire latency budget spent in a loop that reads as harmless. Grep your own diff for a query, an HTTP call, or a file read nested inside an iteration before you call the change done.

5. **Never put an LLM call on a synchronous request path.** Time-to-first-token is ~1 s against a hosted frontier model. A same-zone round trip is 300 us and a warm indexed query 0.5 ms, so one token alone lands three orders of magnitude beyond the operations a request budget is actually built from, and a short response at ~3 s is closer to four. It belongs behind a queue, a stream, or a cache, never between a user's click and their response.

6. **Prefer the change that removes work over the change that adds capacity.** Collapsing an N+1 into one join beats provisioning a read replica: it is cheaper, it is reversible, and it does not add a component. Reach for more hardware only after the wasteful work is gone.

7. **Working set versus RAM decides sharding — not row count, not table size.** A 500 GB table whose hot 8 GB fits in memory is a single-node problem. A 20 GB table read uniformly at random on a 16 GB box is not. State which case you are in before proposing to split anything.

8. **Design for peak, cost for average, and assume peak is 3x average** unless you have real traffic data. Say which number you used. A design justified with average load is a design that fails on its first busy day.

9. **A cache is a correctness liability before it is a performance win.** Name the staleness the caller tolerates and the invalidation path, in that order. If you cannot state both in one sentence each, you are not ready to add the cache.

10. **Every network call needs an explicit timeout, shorter than its caller's.** Most client libraries default to unbounded, so silence in your diff means infinity. Nested calls whose timeouts are not strictly decreasing produce a caller that gives up while the work is still running.

11. **A retry without an idempotency key and a cap is an outage amplifier.** If you add a retry, name both, plus the backoff. Retrying a non-idempotent write turns a slow dependency into a corrupted one.

12. **Two services that must be deployed together to avoid breaking are one service.** Merge them. This is the checkable form of "distributed monolith" — you can evaluate it against a release process, whereas the label alone you cannot.

13. **Sequential still beats random by more than an order of magnitude, NVMe included.** Check it against the table below: 1 MB sequentially from NVMe in 150 us is ~6.8 GB/s, while 4K random reads at 15 us each is ~270 MB/s — about 25x. Sort keys and batch reads before you optimize anything further up the stack. The gap narrowed against spinning disks; it did not close.

14. **State the condition under which your design breaks.** Every choice has a losing case — 10x the data, a second region, a strict-consistency requirement. Naming it converts an unfalsifiable recommendation into one a human can accept or reject, and it is the part reviewers most often find missing.

15. **Treat every constant below as order-of-magnitude and check its date.** These rot: disk seek fell from milliseconds to microseconds when NVMe landed, and datacenter round trips now beat local spinning-disk reads. Re-derive on the target hardware with `scripts/bench.sh` before any number drives a decision you cannot cheaply reverse.

## Constants

Order-of-magnitude, commodity server hardware, **as-of 2026-08**.
Re-derive locally: `scripts/bench.sh`

### Latency

| Operation | Latency |
|---|---|
| L1 cache reference | 1 ns |
| Branch mispredict | 5 ns |
| Mutex lock/unlock | 25 ns |
| Main memory reference (DDR5) | 80 ns |
| NVMe random read, 4K | 15 us |
| Read 1 MB sequentially from memory | 30 us |
| Read 1 MB sequentially from NVMe | 150 us |
| Round trip, same availability zone | 300 us |
| Postgres indexed point query, warm, local | 0.5 ms |
| HDD seek | 5 ms |
| Round trip, cross-region same continent | 30 ms |
| Round trip, cross-continent | 65 ms |
| LLM time-to-first-token, hosted frontier model | 1 s |
| LLM short response, ~100 output tokens | 3 s |

### Capacity

| Component | Throughput |
|---|---|
| One app process, JSON API | 1k–5k RPS |
| One Postgres, simple point queries | ~10k QPS |
| One Postgres, durable writes | ~5k TPS |
| One Redis instance | ~100k ops/s |
| One NVMe device | ~500k IOPS, ~7 GB/s |
| One Kafka partition | ~10 MB/s |
| Server NIC | 25–100 Gbps |

Lineage: the latency column descends from Peter Norvig's original list, popularized
and extended by Jeff Dean as "Numbers Everyone Should Know" (2009–2010). Dean never
published an update; the values here are re-derived for current hardware, which is
why every one of them carries a date.
