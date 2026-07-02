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
| `setVeBaoMerkleRoot` | owner or `CONFIG_ROLE` | **before `startDate` only** |
| `setStandardMerkleRoot` | owner or `CONFIG_ROLE` | **before `endDate` only** (expand tree during window) |
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
- **ve root frozen at window open; standard root expandable until close.** The veBAO merkle root and multisig lock
  at `startDate`. The standard merkle root may still be updated during `[startDate, endDate)` so the allocation
  tree can grow as it is finalized — each address remains one-shot via `hasClaimedStandard`. Sweep only runs after
  `endDate`.
- **Hard on-chain caps.** `MAX_BAO` (1,422m), `MAX_TIDE_SWAP_AND_VE` (250m), `MAX_TIDE_STANDARD` (30m) are
  enforced on every path. Off-chain merkle trees + max swap must be sized so the sums stay within these caps; the
  contract will not over-distribute regardless.
- **No role self-grant.** `CONFIG_ROLE` can update the ve root before `startDate` and the standard root before
  `endDate`; sweep/recovery and role management are owner-only.
- **Standard ERC20 only.** No fee-on-transfer or rebasing support — TIDE/BAO are assumed standard.

## Lifecycle

```
deploy (immutable config) -> fund up to 280m TIDE -> claim window (paths 1/2/3) -> sweep leftover TIDE -> retire
```

## Production deployment (mainnet)

Live distributor: [0x7C5791e6F37d2fFdd4DAbf17d170556828C20fCD](https://etherscan.io/address/0x7c5791e6f37d2ffdd4dabf17d170556828c20fcd)  
Canonical config: `deployments/aux-1.json`. Frontend integration: [`FRONTEND.md`](FRONTEND.md).

| | Address / value |
|---|---|
| **Distributor** | `0x7C5791e6F37d2fFdd4DAbf17d170556828C20fCD` |
| **TIDE** | `0xDA187eB6F4D7eE3a0b8f5cd81eED8d347f5693aD` |
| **BAO** | `0xCe391315b414D4c7555956120461D21808A69F3A` |
| **veBAO** | `0x8Bf70DFE40F07a5ab715F7e888478d9D3680a2B6` |
| **Multisig** (owner) | `0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2` |
| **startDate** | `1782936000` — Jul 1 2026 20:00 GMT |
| **endDate** | `1798761600` — Jan 1 2027 00:00 UTC *(exclusive; claims through Dec 31 2026)* |
| **SNAPSHOT_BLOCK** | `25000000` |
| **veBaoMerkleRoot** | `0xfdd432ab8ae9cf7629c0b184dbe31ca5e8b0ebb00e58ea63594375090bfec563` *(frozen at `startDate`)* |
| **standardMerkleRoot** | `0x2e14222f9f0754e9b48f6a55034024aacc72539ac4d3848a2836a0d1c30e2b31` *(set via `setStandardMerkleRoot` after deploy)* |

Deployed with an empty standard root (`0x0`); the multisig set the live standard root above during the claim window.
Read `standardMerkleRoot()` on-chain before enabling path 3 in a frontend.

### Merkle data (separate trees)

Paths 2 and 3 use **different** merkle roots and allocation files. Same leaf format `(address, tideAmount)`; do not
mix proofs across paths.

| Path | Function | Off-chain data | Pool |
|---|---|---|---|
| 2 — veBAO | `claimVeBao` | `vebao_tide_allocation.json` | ~85m TIDE (846 addresses; within 250m shared cap with path 1) |
| 3 — standard (veFXN) | `claimStandard` | `vefxn_tide_allocation.json` | 30m TIDE (683 addresses; `MAX_TIDE_STANDARD`) |

Path 2 `tideAmount` per address: `baoToTide(locked.amount)` at block 25_000_000. Path 3: pro-rata by aggregated
veFXN weight at the same snapshot (floor division; see `vefxn_tide_allocation.json` metadata).

### Path 3 eligibility (standard / veFXN)

Unlike path 2, `claimStandard` has **no veBAO checks** — only:

1. `block.timestamp` within `[startDate, endDate)`
2. Not already claimed (`hasClaimedStandard`)
3. Valid merkle proof for `(msg.sender, tideAmount)` vs `standardMerkleRoot`
4. Path cap (`MAX_TIDE_STANDARD`) and distributor TIDE balance

Same address may claim path 2 and path 3 if present in both trees.

### Launch checklist

| Step | Status |
|---|---|
| Deploy distributor | Done |
| Set `standardMerkleRoot` | Done (`0x2e14222…`) |
| Fund **280,000,000 TIDE** to distributor | **Required before payouts** — claims revert `InsufficientBalance` until funded |
| Publish allocation JSON + frontend | Use separate files per path; see [`FRONTEND.md`](FRONTEND.md) |
| veBAO users extend lock past Dec 31 2026 | Required for path 2 only (`locked__end > endDate`) |

Fork tests target this contract (`script/test-fork.sh`); they `deal` TIDE in `setUp` for integration coverage.

### Legacy test deployment

| | Address / value |
|---|---|
| **Distributor** | `0x1B12e5bae8be22D653D0833A70D951505d017BF9` |
| **TIDE** (test token `NOTIDE`) | `0xB324bA448Ac468015cB86039314ada42E198aA5c` |
| **Claim window** | Short test window (Jul 2026) |

## Funding checklist

For **new** deployments (not the live production contract above):

1. Production **TIDE** on mainnet: `0xDA187eB6F4D7eE3a0b8f5cd81eED8d347f5693aD` (Harbor Tide / `TIDE`, 18 decimals).
2. Copy `deployments/deploy-config.example.json` to `deployments/deploy-config.json` and fill in token
   addresses, claim window, and merkle roots. Then run `script/deploy.sh --network mainnet`.
   `standardMerkleRoot` may be `0x0` at deploy — set via `setStandardMerkleRoot` before path 3 goes live.
3. Fund with up to **280,000,000 TIDE** (<= 250m shared for paths 1+2, <= 30m for path 3).
4. Publish the merkle trees — leaves `(address, tideAmount)` in TIDE; path 2 derives `tideAmount` from
   `locked(addr).amount` at block 25_000_000 via `baoToTide` (identical rounding to the contract).
5. Communicate to veBAO users: claim during `[startDate, endDate)` after block 25M, ensure
   `locked__end > endDate`, and keep `locked.amount >= tideToBao(yourLeafAmount)`. Paths 1/3 may be used on the same address.

## Testing

Run **local unit + invariant tests** (no RPC):

```bash
forge test --match-path "test/tide/**" --no-match-path "test/tide/*.fork.t.sol"
```

Run **mainnet fork integration tests** separately. `MAINNET_RPC_URL` lives in `.env`, but the shell does not load it automatically — use either:

```bash
script/test-fork.sh -vv
```

or Foundry's `mainnet` alias (Forge reads `.env` for `foundry.toml`):

```bash
forge test --match-path "test/tide/HarborTideDistributor_v1.fork.t.sol" -vv --fork-url mainnet
```

To pass the URL explicitly: `source .env && forge test ... --fork-url "$MAINNET_RPC_URL"`.

Keep these separate: running fork tests together with the invariant suite can hit RPC rate limits on archive nodes.
