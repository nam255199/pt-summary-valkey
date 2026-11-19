#!/usr/bin/env bash
# Spin up the test lab, load some data and run pt-summary-valkey against
# a standalone node, a primary/replica pair and a 6-node cluster.
#
#   test/run-tests.sh          # up + load + run
#   test/run-tests.sh down     # remove the lab
set -euo pipefail
cd "$(dirname "$0")"
DC="docker compose"
EX="$DC exec -T runner"

if [[ ${1:-} == down ]]; then $DC down -v; exit 0; fi

$DC up -d
echo "Waiting for nodes..."
for h in valkey-standalone valkey-primary; do
  until $EX valkey-cli -h "$h" -a secret --no-auth-warning ping 2>/dev/null | grep -q PONG; do sleep 1; done
done
for i in 1 2 3 4 5 6; do
  until $EX valkey-cli -h "valkey-c$i" -p 7000 -a secret --no-auth-warning ping 2>/dev/null | grep -q PONG; do sleep 1; done
done

# Create the cluster once
if ! $EX valkey-cli -h valkey-c1 -p 7000 -a secret --no-auth-warning cluster info | grep -q 'cluster_state:ok'; then
  ips=""
  for i in 1 2 3 4 5 6; do
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "ptsv-lab-valkey-c$i-1")
    ips+="$ip:7000 "
  done
  # shellcheck disable=SC2086
  $EX valkey-cli -a secret --no-auth-warning --cluster create $ips --cluster-replicas 1 --cluster-yes
  until $EX valkey-cli -h valkey-c1 -p 7000 -a secret --no-auth-warning cluster info | grep -q 'cluster_state:ok'; do sleep 1; done
fi

echo "Loading data..."
$EX sh -c 'for i in $(seq 1 2000); do echo "SET key:$i value$i"; done | valkey-cli -h valkey-standalone >/dev/null'
$EX sh -c 'valkey-cli -h valkey-standalone KEYS "key:1*" >/dev/null; valkey-cli -h valkey-standalone DEBUG SLEEP 0 >/dev/null 2>&1 || true'
$EX sh -c 'for i in $(seq 1 5000); do echo "SET user:$i value$i"; done | valkey-cli -h valkey-primary -a secret --no-auth-warning >/dev/null'
$EX sh -c 'for i in $(seq 1 3000); do echo "SET {hot}:$i value$i"; done | valkey-cli -c -h valkey-c1 -p 7000 -a secret --no-auth-warning >/dev/null'
$EX sh -c 'for i in $(seq 1 3000); do valkey-cli -c -h valkey-c1 -p 7000 -a secret --no-auth-warning SET "k$i" "v$i" >/dev/null; done' &
wait

mkdir -p out
rm -rf out/*
echo "== standalone"
$EX bash pt-summary-valkey -h valkey-standalone -p 6379 -o test/out/standalone > out/standalone.txt
echo "== replication"
$EX env VALKEYCLI_AUTH=secret bash pt-summary-valkey -h valkey-replica -p 6379 -o test/out/replication > out/replication.txt
echo "== cluster"
$EX env VALKEYCLI_AUTH=secret bash pt-summary-valkey -h valkey-c1 -p 7000 -o test/out/cluster > out/cluster.txt
echo "== collect-only + from-dir"
$EX env VALKEYCLI_AUTH=secret bash pt-summary-valkey -h valkey-c1 -p 7000 -o test/out/collect --collect-only -q
$EX bash pt-summary-valkey --from-dir test/out/collect --no-text -q
echo "Reports:"
ls -1 out/*/report.html
