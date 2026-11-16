#!/bin/sh
# Runs every test. Needs root (network namespaces), nft (or ./nftb), unshare,
# python3, and a C compiler for the helpers (run 'make' first, or use 'make test').
cd "$(dirname "$0")/.." || exit 1
fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

echo "== qvif against a fake xenstore"
python3 tests/test_qvif.py || fail=1

echo "== qvpn flow (real nft ruleset, stubbed ifconfig/route/wg)"
sh tests/make-fake-vpn.sh "$T/vpn.tar" || fail=1
sh tests/test_qvpn.sh "$T/vpn.tar" > "$T/flow.out" 2>&1
grep -E '^(ok|FAIL)' "$T/flow.out"
grep -q '^FAIL' "$T/flow.out" && fail=1
grep -q '^ok' "$T/flow.out" || fail=1

echo "== kill switch without /dev/stdin"
sh tests/test_nodev.sh || fail=1

[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit $fail
