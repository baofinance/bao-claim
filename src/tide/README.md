# HarborTideDistributor_v1

One-shot, **non-upgradeable** TGE distributor for the **TIDE** token. Deploy once, fund it, run the claim
window, sweep leftovers, retire. There is no proxy, no `initialize()`, no UUPS — the `_v1` suffix is a naming
convention (harbor style), not an upgradeable implementation slot. Users can verify the final bytecode and trust
that the owner cannot replace the implementation mid-claim.

## Layout

```
src/tide/
  HarborTideDistributor_v1.sol       # implementation
  README.md                          # this file
  interfaces/
    IHarborTideDistributor.sol       # user API: convertBao, claimVeBao, claimStandard, getVeClaimStatus, helpers
    IHarborTideDistributorConfig.sol # admin API: setRoots, setMultisig, sweep, recoverySweep + events
    IHarborTideDistributorErrors.sol # all custom errors
    IVotingEscrow.sol                # external veBAO read interface (locked, locked__end, balanceOfAt)
```

## Three independent paths

A single address may use **all three** paths — there is no cross-path exclusion.

| Path | Function | Source | TIDE cap |
|---|---|---|---|
| 1 | `convertBao(baoAmount)` | swaps BAO -> TIDE at a fixed rate | shared **250m** (`MAX_TIDE_SWAP_AND_VE`) |
| 2 | `claimVeBao(tideAmount, proof)` | merkle claim for eligible veBAO positions | shared **250m** (with path 1) |
| 3 | `claimStandard(tideAmount, proof)` | merkle claim for a standard allocation | separate **30m** (`MAX_TIDE_STANDARD`) |

All paths are only active during `[startDate, endDate)`. Total funding budget: **280,000,000 TIDE**
(<= 250m shared across paths 1+2, <= 30m for path 3).

### Merkle leaf encoding (paths 2 and 3)

Leaves are `(address account, uint256 tideAmount)` where `tideAmount` is denominated in **TIDE**. The contract
uses the OpenZeppelin StandardMerkleTree double-hash:

```solidity
bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, tideAmount))));
```

The leaf amount is **authoritative** — calling a claim with any `tideAmount` other than the one in your proof
fails with `InvalidProof`. The contract pays exactly the proven `tideAmount`.

## Conversion math (fixed rate)

`1 BAO -> 0.1758 TIDE`, stored as integer constants `TIDE_NUMERATOR = 1758`, `RATE_DENOMINATOR = 10000`
(no floating point).

```solidity
baoToTide(bao)  = bao * 1758 / 10000                  // TIDE rounded DOWN (user receives floor)
tideToBao(tide) = (tide * 10000 + 1758 - 1) / 1758    // BAO rounded UP   (user must cover ceil)
```

Rounding always favors the protocol by at most a tiny dust amount; `tideToBao(baoToTide(x)) <= x` always holds,
so the round-trip never over-credits a user.

### Worked example — minimum swap (path 1)

`MIN_TIDE_OUT = 10 TIDE`. The minimum BAO input is `tideToBao(10e18)`:

| Input (wei) | `baoToTide` output (wei) | Result |
|---|---|---|
| `56882821387940841866` (≈ 56.8828 BAO) | `10000000000000000000` (exactly 10 TIDE) | accepted |
| `56882821387940841865` (one wei less) | `9999999999999999999` (< 10 TIDE) | reverts `BelowMinSwap` |

### Worked example — veBAO snapshot (path 2)

The path-2 merkle is built **off-chain from raw locked BAO** (`locked.amount`) at `SNAPSHOT_BLOCK = 25,000,000`,
not from decaying `balanceOfAt` ve power. For each eligible address:

```
lockedBao    = veBAO.locked(addr).amount at block 25_000_000   // raw locked BAO (wei), via archive/indexer
tideAmount   = baoToTide(lockedBao)                             // leaf amount (TIDE, rounded down)
leaf         = (addr, tideAmount)
```

On-chain, `claimVeBao` verifies the live position still backs the claim:

| Field | Example value | Notes |
|---|---|---|
| `locked(addr).amount` at snapshot | `10000000000000000000000000` (10m BAO) | merkle input (off-chain) |
| `tideAmount` (leaf) | `1758000000000000000000000` (1.758m TIDE) | `baoToTide(lockedBao)`, paid on claim |
| `locked(addr).amount` at claim | must be `>= tideToBao(tideAmount)` | live anti-withdraw check |
| `locked(addr).end` | must be `> endDate` | extend the lock on veBAO if needed |

**The off-chain merkle builder MUST use the exact same `baoToTide` / `tideToBao` rounding as the contract.**
veBAO has no `lockedAt(block)` on-chain — the merkle root caps each user's max TIDE from the off-chain snapshot;
the live `locked.amount` check ensures they have not withdrawn below what they are claiming.

## Path 2 eligibility rules (in `claimVeBao`)

1. `block.number >= SNAPSHOT_BLOCK` — claims only after the snapshot block (`SnapshotNotReached`).
2. `block.timestamp` within `[startDate, endDate)` (`ClaimNotStarted` / `ClaimEnded`).
3. Not already claimed (`AlreadyClaimed`).
4. Valid merkle proof for `(msg.sender, tideAmount)` (`InvalidProof`).
5. `locked__end(msg.sender) > endDate` — lock must extend strictly past the window (`LockEndTooEarly`).
6. `locked(msg.sender).amount >= tideToBao(tideAmount)` — current locked BAO covers the merkle allocation
   (`InsufficientLocked`).
7. Shared pool cap (`TideSwapVeCapExceeded`) and TIDE balance (`InsufficientBalance`).

### Intentional behaviors (not bugs)

- `locked.amount > tideToBao(tideAmount)` is **allowed** (e.g. the user added BAO after the snapshot).
- A **partial** withdraw where `locked.amount` is still `>= tideToBao(tideAmount)` is **allowed** — enough BAO
  remains locked to back the claim.
- The only thing rule 6 blocks is withdrawing **below** the BAO equivalent of the merkle allocation, which would
  let someone free BAO and use it again on path 1. Using path 1 and/or path 3 **in addition to** path 2 is
  allowed by design.

`getVeClaimStatus(user, tideAmount)` returns a read-only preview (`VeClaimStatus`) mirroring every check above
except the merkle proof, so frontends and the contract share the same rules. Lock extension is a **frontend**
action against veBAO directly (`create_lock` / `increase_unlock_time`) — the distributor never calls veBAO writes.

## Admin / governance

| Action | Who | When |
|---|---|---|
| `setVeBaoMerkleRoot`, `setStandardMerkleRoot` | owner or `CONFIG_ROLE` | **before `startDate` only** |
| `setMultisig` | owner only | **before `startDate` only** |
| `sweep` (TIDE -> multisig) | owner only | **after `endDate` only** |
| `recoverySweep(token)` (stray tokens) | owner only | **after `endDate` only** |
| `grantRoles` / `revokeRoles` | owner only | any time |

- `startDate`, `endDate`, `SNAPSHOT_BLOCK`, token addresses, caps, and the conversion rate are **immutable**
  (set at deploy). There is no `setDates`.
- Operationally, `startDate` must be **after block 25,000,000** so the snapshot block exists before claims open.
- BAO is **never held**: each `convertBao` forwards BAO straight to the multisig in the same transaction. If that
  transfer fails, the whole swap reverts (`SafeERC20`).
- `recoverySweep` cannot move **TIDE** or **BAO** (`CannotRecoverClaimToken`); use `sweep` for leftover TIDE.

## Threat model

- **No upgrades.** Bytecode is final; the owner cannot change logic, dates, caps, or rate post-deploy.
- **Roots/multisig frozen at window open.** Nothing an admin can do during or after the window affects claim
  outcomes — late root changes are impossible (`ConfigLocked`), and sweep only runs after `endDate`.
- **Hard on-chain caps.** `MAX_BAO` (1,422m), `MAX_TIDE_SWAP_AND_VE` (250m), `MAX_TIDE_STANDARD` (30m) are
  enforced on every path. Off-chain merkle trees + max swap must be sized so the sums stay within these caps; the
  contract will not over-distribute regardless.
- **No role self-grant.** `CONFIG_ROLE` can only touch merkle roots before `startDate`; sweep/recovery and role
  management are owner-only.
- **Standard ERC20 only.** No fee-on-transfer or rebasing support — TIDE/BAO are assumed standard.

## Lifecycle

```
deploy (immutable config) -> fund up to 280m TIDE -> claim window (paths 1/2/3) -> sweep leftover TIDE -> retire
```

## Funding checklist

1. Deploy the TIDE token.
2. Copy `deployments/deploy-config.example.json` to `deployments/deploy-config.json` and fill in token
   addresses, claim window, and merkle roots. Then run `script/deploy.sh --network mainnet`.
3. Fund with up to **280,000,000 TIDE** (<= 250m shared for paths 1+2, <= 30m for path 3).
4. Publish the merkle trees — leaves `(address, tideAmount)` in TIDE; path 2 derives `tideAmount` from
   `locked(addr).amount` at block 25_000_000 via `baoToTide` (identical rounding to the contract).
5. Communicate to veBAO users: claim during `[startDate, endDate)` after block 25M, ensure
   `locked__end > endDate`, and keep `locked.amount >= tideToBao(yourLeafAmount)`. Paths 1/3 may be used on the same address.
