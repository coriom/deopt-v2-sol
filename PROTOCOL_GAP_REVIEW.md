# PROTOCOL_GAP_REVIEW

## Goal
Finalize DeOpt v2 protocol code toward production readiness without uncontrolled refactors.

## Priority A — launch safety
- [ ] finer launch caps by market
- [ ] collateral universe restriction mode
- [ ] progressive activation controls
- [ ] tighter launch-only safety knobs

## Priority B — emergency granularity
- [ ] per-market emergency controls
- [ ] per-underlying emergency controls
- [ ] finer close-only / settlement-freeze paths

## Priority C — preview / observability
- [ ] richer liquidation previews
- [ ] richer settlement previews
- [ ] portfolio/account breakdown helpers
- [ ] more complete critical events

## Priority D — protocol ergonomics
- [ ] access-control readability improvements
- [ ] config separation clarity
- [ ] internal helper harmonization

## Explicitly out of scope for now
- full cosmetic refactor
- broad lint cleanup
- unrelated frontend work
- non-critical naming cleanup