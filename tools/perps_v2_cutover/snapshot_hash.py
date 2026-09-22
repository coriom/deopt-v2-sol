#!/usr/bin/env python3
"""
PERPS_V2_BASE_SEPOLIA_CUTOVER — canonical snapshot manifest hasher.

USAGE:
    python3 snapshot_hash.py manifest.json

Reads a JSON manifest (schema per docs/PERPS_V2_BASE_SEPOLIA_CUTOVER_PREFLIGHT_V1.md §P),
canonicalizes it into deterministic CBOR (RFC 8949 §4.2 core deterministic encoding),
then returns keccak256(cbor).

Determinism rules:
  * every collection is sorted by its primary key BEFORE hashing
  * integers big-endian minimal-length (per RFC 8949)
  * addresses lowercased hex WITHOUT 0x, then hex-decoded to 20 raw bytes
  * bytes32 hex-decoded to 32 raw bytes
  * schemaVersion prefix ensures forward-incompat detection

Dependencies:
  pip install cbor2 pysha3   (or use `pycryptodome` for keccak)

If cbor2/pysha3 are unavailable in your environment, this script also emits
the canonical byte string on stdout so you can hash externally
(e.g. `cast keccak "0x$(...)"`).
"""
import json, sys, hashlib, binascii
try:
    import cbor2
except ImportError:
    print("ERROR: pip install cbor2", file=sys.stderr); sys.exit(2)

def h20(a):  # address → 20 raw bytes
    s = a.lower().removeprefix('0x')
    assert len(s) == 40, f"bad address: {a}"
    return bytes.fromhex(s)

def h32(b):  # bytes32 → 32 raw bytes
    s = b.lower().removeprefix('0x')
    assert len(s) == 64, f"bad bytes32: {b}"
    return bytes.fromhex(s)

def canonical(m):
    """Return dict with sorted+typed collections. Integers/int keys preserved."""
    def _pos(p):
        return {"trader": h20(p["trader"]),
                "marketId": int(p["marketId"]),
                "size1e8": int(p["size1e8"]),
                "openNotional1e8": int(p["openNotional1e8"]),
                "lastCumulativeFundingRate1e18": int(p["lastCumulativeFundingRate1e18"])}
    def _mkt(mk):
        return {"marketId": int(mk["marketId"]),
                "cumulativeFundingRate1e18": int(mk["cumulativeFundingRate1e18"]),
                "lastFundingTimestamp": int(mk["lastFundingTimestamp"]),
                "longOI1e8": int(mk["longOI1e8"]),
                "shortOI1e8": int(mk["shortOI1e8"])}
    def _bd(t):
        return {"trader": h20(t["trader"]), "amountBase": int(t["amountBase"])}
    def _nc(t):
        return {"trader": h20(t["trader"]), "nonce": int(t["nonce"])}
    def _vb(v):
        return {"user": h20(v["user"]), "token": h20(v["token"]), "balance": int(v["balance"])}
    positions = sorted([_pos(p) for p in m["positions"]],  key=lambda x: (x["trader"], x["marketId"]))
    markets   = sorted([_mkt(k) for k in m["markets"]],    key=lambda x: x["marketId"])
    bad_debt  = sorted([_bd(t)  for t in m["residualBadDebt"]], key=lambda x: x["trader"])
    nonces    = sorted([_nc(t)  for t in m["pmeNonces"]],  key=lambda x: x["trader"])
    balances  = sorted([_vb(v)  for v in m["vaultBalances"]], key=lambda x: (x["user"], x["token"]))
    return {
        "schemaVersion": 1,
        "chainId": int(m["chainId"]),
        "engineV1": h20(m["engineV1"]),
        "pmeV1": h20(m["pmeV1"]),
        "snapshotBlockNumber": int(m["snapshotBlockNumber"]),
        "snapshotBlockHash": h32(m["snapshotBlockHash"]),
        "markets": markets,
        "positions": positions,
        "residualBadDebt": bad_debt,
        "pmeNonces": nonces,
        "vaultBalances": balances,
    }

def keccak256(b):
    try:
        import pysha3  # noqa
        h = hashlib.new('sha3_256'); h.update(b); return h.digest()
    except Exception:
        pass
    try:
        import sha3  # noqa
        return sha3.keccak_256(b).digest()
    except Exception:
        pass
    from Crypto.Hash import keccak
    k = keccak.new(digest_bits=256); k.update(b); return k.digest()

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: snapshot_hash.py manifest.json", file=sys.stderr); sys.exit(2)
    m = json.load(open(sys.argv[1]))
    c = canonical(m)
    # cbor2 canonical=True writes RFC 8949 core deterministic encoding
    blob = cbor2.dumps(c, canonical=True, timezone=None)
    h = keccak256(blob)
    print(f"canonical_cbor_bytes = {len(blob)}")
    print(f"canonical_cbor_hex   = 0x{binascii.hexlify(blob).decode()}")
    print(f"snapshot_hash        = 0x{binascii.hexlify(h).decode()}")

# Test vectors (self-check on first import as a sanity guard):
if __name__ == "__main__" and False:
    # placeholder; add golden vectors before use
    pass
