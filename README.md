# reval-summary

A `pt-summary`-style summary and health check for **Valkey** and **Redis OSS**.
It works on a standalone instance, a primary/replica group or a cluster. It prints a
text report to the terminal and writes a **self-contained HTML health report** (in the
spirit of `pg_gather`) with findings and recommendations for DBAs and support engineers.

- Single bash script. Needs only `bash` >= 4.2, `awk`, `sed`, `sort` and `valkey-cli` or `redis-cli`.
- Read-only: it runs only INFO / CONFIG GET / CLUSTER INFO|NODES / SLOWLOG GET / LATENCY / MEMORY / CLIENT LIST / ACL LIST.
  The optional `--bigkeys` runs SCAN, which adds load.
- Discovers every node from the seed (`CLUSTER NODES`, or the primary/replica links in `INFO replication`).
- Secrets are redacted (`requirepass`, `masterauth`, ACL password hashes). The password is passed through
  the environment, not on the command line.

## Quick start

```bash
# Standalone or replication group
VALKEYCLI_AUTH='secret' ./reval-summary -h 10.0.0.5 -p 6379

# Cluster: any node works as the seed
./reval-summary -h node1 -p 7000 --user monitor --ask-pass

# TLS
./reval-summary -h node1 -p 6380 --tls --cacert ca.crt --ask-pass
```

Output: the text report on stdout, plus `./reval-summary_<host>_<port>_<timestamp>/report.html` and the raw data.

### Customer / support workflow

```bash
# collect only, then send the .tar.gz
./reval-summary -h 10.0.0.5 -p 6379 --ask-pass --collect-only
# -> ./reval-summary_10.0.0.5_6379_20261119_101500.tar.gz

# build the reports offline
tar xzf reval-summary_10.0.0.5_6379_20261119_101500.tar.gz
./reval-summary --from-dir reval-summary_10.0.0.5_6379_20261119_101500
```

Run the tool on one of the Valkey hosts to also collect OS settings (THP, overcommit,
swappiness, somaxconn, process limits, swap, free disk space of `dir`). They are collected
automatically when a node runs on the local host. Use `--os` / `--no-os` to force or skip this.

## Options

| Option | Description |
| --- | --- |
| `-h, --host` / `-p, --port` | Seed node (default `127.0.0.1:6379`) |
| `--user`, `-a/--password`, `--ask-pass` | ACL user and password. Prefer `VALKEYCLI_AUTH` / `REDISCLI_AUTH` or `--ask-pass` |
| `--tls --cacert --cacertdir --cert --key --sni --insecure` | TLS connection |
| `--cli PATH` | `valkey-cli` / `redis-cli` to use |
| `--no-discover`, `--nodes h:p,h:p`, `--max-nodes N` | Control node discovery (`--nodes` helps when announced IPs are not reachable, e.g. NAT/k8s) |
| `--slowlog N`, `--no-client-list`, `--bigkeys` | Collection depth |
| `-o DIR`, `--html FILE`, `--no-text`, `-q` | Output |
| `--collect-only`, `--from-dir DIR` | Split collection and analysis |

Minimal ACL user for the tool:

```
ACL SETUSER reval-summary on >password -@all +ping +info +config|get +cluster|info +cluster|nodes
  +slowlog|get +slowlog|len +latency|latest +latency|doctor +memory|doctor +memory|stats
  +client|list +acl|list +module|list +commandlog|get
```

If a command is not permitted, the tool reports it and skips the checks that depend on it.

## What it checks

| Area | Checks |
| --- | --- |
| Version | EOL / old Redis releases, Valkey 7.x vs 8.x, mixed versions |
| Memory | no maxmemory, maxmemory vs RAM, usage vs maxmemory, eviction policy vs TTLs, evictions, OOM errors, fragmentation (activedefrag), RSS < used (swap), client buffer memory, Lua script cache, per-host over-commit |
| Persistence | failed BGSAVE / AOF rewrite / AOF write, no recent snapshot, primary without persistence that has replicas, slow fork, delayed AOF fsync, appendfsync always, data-dir disk usage |
| Replication | link down, stale I/O, full sync in progress, replica state and lag, failed partial resyncs, backlog size, diskless sync, replica output buffer limit, writable replicas |
| Clients | maxclients usage, rejected connections, connection churn, idle connections, tcp-keepalive, MONITOR, large output buffers, READONLY errors |
| Performance | slowlog settings and entries, KEYS / FLUSH*, commands with high latency, LATENCY LATEST events, hit ratio, expiry backlog, lazyfree, io-threads, main-thread CPU, hz, BUSY scripts |
| Security | no authentication / protected-mode, ACL users without password, auth failures, debug/module commands enabled |
| Cluster | cluster_state, unassigned / pfail / fail slots, failed nodes, open (migrating/importing) slots, primaries without replicas, replica on same host as primary, primaries concentrated on one host (quorum), epoch collisions, slot / key / memory / ops skew, membership disagreement, MOVED storms, node-timeout, full coverage, config drift between nodes |
| OS (local) | THP, vm.overcommit_memory, swappiness, somaxconn vs tcp-backlog, open files vs maxclients, process swap, container memory limit vs maxmemory, load |

Findings that repeat on several nodes are grouped. The health score starts at 100 and loses
15 points per critical, 5 per warning and 1 per info finding (info costs at most 10 points in total).

## HTML report

- Summary cards: health score, number of findings, nodes, data size, ops/s, cluster state.
- Findings table with severity filter, search and a recommendation for each finding.
- Topology (shards, slot ranges, replicas and their state) and a nodes overview with highlighted values.
- Key configuration and the parameters that differ between nodes.
- Per node: server, memory, persistence, replication, cluster, clients and stats, plus keyspace, top commands,
  error stats, slow log, latency events, memory stats, top clients, LATENCY/MEMORY DOCTOR, ACL, full
  config (filterable) and raw INFO.
- One self-contained file (no external resources), sortable tables, light/dark theme, printable.

<img width="1894" height="944" alt="image" src="https://github.com/user-attachments/assets/123d7eb4-0df0-4d75-bf27-0a66dbf0bbf5" />

## Raw data layout

```
<output-dir>/
  meta.txt  nodes.txt
  nodes/<host>_<port>/  info.txt config.txt cluster_info.txt cluster_nodes.txt slowlog.txt
                        latency_*.txt memory_*.txt client_list.txt acl.txt module_list.txt
                        proc_*.txt df_dir.txt (local) bigkeys.txt (optional) *.err
  os/                   os.txt df.txt free.txt ps.txt (local)
  report/               derived tables + findings.tsv
  report.html

- Kubernetes: collect from the pods of the Valkey operators/Helm charts (`kubectl exec`), and include pod
  resources and limits.
- Sentinel: topology, quorum and configuration checks.
- Read `valkey-ftdc` / log data for trends over time.
