# HarborTideDistributor_v1 — Frontend Integration Guide

One-shot, **non-upgradeable** TGE distributor. Users can participate via **three independent paths** — a wallet may use **all three**. There is no cross-path exclusion.

| Path | Function | What user does |
|---|---|---|
| 1 | `convertBao(baoAmount)` | Swap BAO → TIDE at fixed rate |
| 2 | `claimVeBao(tideAmount, proof)` | Merkle claim for veBAO holders |
| 3 | `claimStandard(tideAmount, proof)` | Merkle claim for standard allocation |

Contract reference: [`HarborTideDistributor_v1.sol`](HarborTideDistributor_v1.sol)  
Full architecture / threat model: [`README.md`](README.md)  
User-facing interface: [`interfaces/IHarborTideDistributor.sol`](interfaces/IHarborTideDistributor.sol)

---

## Production TIDE token (mainnet)

| | |
|---|---|
| **TIDE** | `0xDA187eB6F4D7eE3a0b8f5cd81eED8d347f5693aD` |
| **Name / symbol** | Harbor Tide / `TIDE` |
| **Decimals** | 18 |
| **Total supply** | 1,000,000,000 TIDE |

Use this address in `deployments/deploy-config.json` for production distributor deploys. The distributor pays this token on all three paths.

**Planned production claim window** (`deploy-config.json`):

| | Timestamp | Time (UTC) |
|---|---|---|
| **startDate** | `1782936000` | Jul 1, 2026 20:00 GMT |
| **endDate** | `1798761600` | Jan 1, 2027 00:00 GMT *(exclusive — includes all of Dec 31, 2026)* |

---

**Production distributor (mainnet):** [0x7C5791e6F37d2fFdd4DAbf17d170556828C20fCD](https://etherscan.io/address/0x7c5791e6f37d2ffdd4dabf17d170556828c20fcd)

| | Address / value |
|---|---|
| **Distributor** | `0x7C5791e6F37d2fFdd4DAbf17d170556828C20fCD` |
| **TIDE** | `0xDA187eB6F4D7eE3a0b8f5cd81eED8d347f5693aD` |
| **BAO** | `0xCe391315b414D4c7555956120461D21808A69F3A` |
| **veBAO** | `0x8Bf70DFE40F07a5ab715F7e888478d9D3680a2B6` |
| **Multisig** (owner) | `0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2` |
| **veBao merkle root** | `0xfdd432ab8ae9cf7629c0b184dbe31ca5e8b0ebb00e58ea63594375090bfec563` *(frozen at `startDate`)* |
| **Standard merkle root** | `0x0` at deploy — set via `setStandardMerkleRoot` before path 3 goes live |
| **Claim window** | Jul 1 2026 20:00 GMT → Dec 31 2026 (via `startDate` / `endDate`) |

Fork tests target this contract (`script/test-fork.sh`); they `deal` TIDE and set standard root in `setUp` for integration coverage.

---

## Legacy test deployment

| | Address / value |
|---|---|
| **Distributor** | `0x1B12e5bae8be22D653D0833A70D951505d017BF9` |
| **TIDE** (test token `NOTIDE`) | `0xB324bA448Ac468015cB86039314ada42E198aA5c` |
| **BAO** | `0xCe391315b414D4c7555956120461D21808A69F3A` |
| **veBAO** | `0x8Bf70DFE40F07a5ab715F7e888478d9D3680a2B6` |
| **Multisig** (owner) | `0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2` |
| **veBao merkle root** | `0xfdd432ab8ae9cf7629c0b184dbe31ca5e8b0ebb00e58ea63594375090bfec563` *(frozen at `startDate`)* |
| **Standard merkle root** | read `standardMerkleRoot()` — **updatable until `endDate`** via `setStandardMerkleRoot` |
| **Claim window** | `startDate` → `endDate` (Wed Jul 1 ~00:12 CEST → Sun Jul 5 12:00 CEST 2026) |

Read from chain (do not hardcode long-term):

- `startDate()`, `endDate()` — claim window `[startDate, endDate)`
- `veBaoMerkleRoot()`, `standardMerkleRoot()`
- `hasClaimedVeBao(user)`, `hasClaimedStandard(user)`
- `SNAPSHOT_BLOCK()` → `25000000`

---

## Claim window

All three paths are active only when:

```
block.timestamp >= startDate  AND  block.timestamp < endDate
```

Path 2 additionally requires:

```
block.number >= SNAPSHOT_BLOCK  (25_000_000 on mainnet — already passed)
```

---

## Path 1 — BAO → TIDE swap

**Flow:**

1. User approves BAO on the distributor
2. Call `convertBao(baoAmount)`
3. BAO goes to multisig in the same tx; user receives TIDE

**Rate:** `1 BAO = 0.1758 TIDE` (integer math on-chain)

```javascript
tideOut = baoAmount * 1758n / 10000n   // rounds DOWN
```

**Constraints:**

- Min output: `MIN_TIDE_OUT()` = **10 TIDE** (~**57 BAO** min input)
- No per-user limit on swaps (can swap multiple times)
- Global caps: `MAX_BAO`, `MAX_TIDE_SWAP_AND_VE` (shared with path 2)

**Preview helpers (on distributor):**

- `baoToTide(baoAmount)` — expected TIDE out
- `tideToBao(tideAmount)` — BAO required for a TIDE amount (rounds up)

---

## Path 2 & 3 — Merkle claims

### Leaf format (OpenZeppelin StandardMerkleTree)

```
leaf = keccak256(abi.encodePacked(
  keccak256(abi.encode(address account, uint256 tideAmount))
))
```

- `tideAmount` is in **TIDE wei** (18 decimals)
- Amount in the tx **must exactly match** the proven leaf — otherwise `InvalidProof`
- Contract pays exactly `tideAmount` from the leaf

### One-shot per path

- `hasClaimedVeBao[user]` — path 2, once only → second call reverts `AlreadyClaimed`
- `hasClaimedStandard[user]` — path 3, once only → same

**Important:** Same address can claim **both** path 2 and path 3 if in both trees (or same test root). This is intentional.

### Path 2 — veBAO eligibility

Use **`getVeClaimStatus(user, tideAmount)`** for UI preview:

```solidity
struct VeClaimStatus {
    uint256 veEnd;           // veBAO lock end timestamp
    uint256 lockedAmount;    // current locked BAO
    uint256 baoRequired;     // tideToBao(tideAmount)
    uint256 minUnlockTime;   // endDate + 1 (user must extend lock past window)
    bool canClaimNow;        // all checks except merkle proof
    bool alreadyClaimed;
    bool poolCapAvailable;
}
```

**On-chain rules for `claimVeBao`:**

1. Valid merkle proof for `(user, tideAmount)` vs `veBaoMerkleRoot`
2. `veBAO.locked__end(user) > endDate` — lock must extend **strictly past** the window
3. `veBAO.locked(user).amount >= tideToBao(tideAmount)` — enough BAO still locked (anti-withdraw)

**Not used:** `balanceOfAt` / ve power — merkle is built from **raw locked BAO at snapshot block 25M** off-chain.

Data source: `harbor-app/public/data/tide/vebao_tide_allocation.json` (846 addresses, `merkleRoot` matches `veBaoMerkleRoot`).

#### veBAO lock must extend past **31 December 2026** (production)

Production `endDate` is **1 Jan 2027 00:00 UTC** (exclusive). Claims are allowed through **31 Dec 2026 23:59:59 UTC**.

On-chain rule: `locked__end(user) > endDate` — the lock must end **strictly after** the distributor window, i.e. **into 2027**.

Many users are in the merkle tree but have `lockedEnd` in the JSON **before** that deadline. They **cannot claim** until they extend on veBAO, even with a valid proof.

**UI must check at claim time (not only JSON snapshot):**

```typescript
const endDate = await distributor.endDate();
const status = await distributor.getVeClaimStatus(user, tideAmount);

// Authoritative on-chain read (prefer over JSON lockedEnd)
const lockOk = status.veEnd > endDate;
```

**When `status.veEnd <= endDate` (or JSON `lockedEnd` ≤ endDate as a pre-check), show:**

> **Extend your veBAO lock**  
> Your lock must end **after 31 December 2026** to claim TIDE.  
> Extend your lock on [veBAO](https://…/) so it runs past the claim window, then return here to claim.

Optional detail line:

> Your lock currently ends: {formatDate(status.veEnd)} · Required: after {formatDate(endDate)} ({formatDate(status.minUnlockTime)} or later)

**CTA:** Link/button to veBAO lock extension (`increase_unlock_time` / `create_lock`) — the distributor never writes to veBAO.

**Do not enable the claim button** when `!status.canClaimNow` because of lock timing — the tx will revert with `LockEndTooEarly`.

**Other ve claim blockers (show similarly):**

| Check | User message |
|---|---|
| `status.lockedAmount < status.baoRequired` | Keep at least {baoRequired} BAO locked on veBAO (do not withdraw below your allocation). |
| `status.alreadyClaimed` | You have already claimed your veBAO TIDE allocation. |
| `!status.poolCapAvailable` | veBAO claim pool cap reached — try again later. |
| Before `startDate` / after `endDate` | Claim window closed (opens {startDate}, closes 31 Dec 2026). |

**Frontend actions for ineligible ve users:**

- Extend lock on veBAO so `locked__end > endDate` (must be **after 31 Dec 2026** for production)
- Ensure locked BAO ≥ `baoRequired` at the moment they claim

### Path 3 — standard claim

- Merkle proof only (+ window open + not already claimed)
- No veBAO checks
- **`standardMerkleRoot` may be updated by owner/`CONFIG_ROLE` until `endDate`** — the tree can expand as allocations are finalized; each address still claims once (`hasClaimedStandard`)

---

## Suggested UI flow

```
1. Connect wallet
2. Read startDate / endDate → show countdown or "not started" / "ended"
3. For each path, show eligibility:

   SWAP:
   - User BAO balance
   - Preview: baoToTide(amount)
   - Check amount >= min (~57 BAO)
   - Approve BAO → convertBao

   ve CLAIM:
   - Load (tideAmount, proof) from vebao_tide_allocation.json (or API mirroring it)
   - getVeClaimStatus(user, tideAmount)
   - If status.veEnd <= endDate → show "Extend lock past 31 Dec 2026" + link to veBAO
   - If status.lockedAmount < status.baoRequired → show insufficient locked BAO
   - If !canClaimNow → show specific blocker; disable claim button
   - claimVeBao(tideAmount, proof)

   STANDARD CLAIM:
   - Load (tideAmount, proof) from backend
   - Check !hasClaimedStandard(user)
   - claimStandard(tideAmount, proof)
```

---

## Events (for indexing)

| Event | When |
|---|---|
| `BaoConverted(user, baoIn, tideOut)` | Path 1 swap |
| `VeBaoClaimed(user, amount)` | Path 2 claim |
| `StandardClaimed(user, amount)` | Path 3 claim |

---

## Common revert reasons (for error messages)

| Error | Meaning |
|---|---|
| `ClaimNotStarted` | Before `startDate` |
| `ClaimEnded` | At or after `endDate` |
| `AlreadyClaimed` | Second claim on same path |
| `InvalidProof` | Wrong proof or wrong `tideAmount` |
| `BelowMinSwap` | Swap too small |
| `LockEndTooEarly` | ve lock ends on or before 31 Dec 2026 — extend veBAO lock past the claim window |
| `InsufficientLocked` | Locked BAO below `tideToBao(tideAmount)` |
| `InsufficientBalance` | Distributor out of TIDE |
| `TideSwapVeCapExceeded` / `TideStandardCapExceeded` | Pool cap hit |
| `BaoCapExceeded` | Global BAO swap cap hit |

Error definitions: [`interfaces/IHarborTideDistributorErrors.sol`](interfaces/IHarborTideDistributorErrors.sol)

---

## Merkle data (backend responsibility)

Frontend should fetch per user from your API:

```json
{
  "address": "0x...",
  "tideAmount": "692340796268698531702446",
  "proof": ["0x...", "..."]
}
```

- **Path 2 tree:** built from `locked.amount` at block **25_000_000**, converted via `baoToTide`
- **Path 3 tree:** separate standard allocation
- Use **identical** `baoToTide` / `tideToBao` rounding as the contract

Example test allocation (for fork/integration tests):

- Address: `0xb9ab9578a34a05c86124c399735fdE44dEc80E7F`
- Amount: `692340796268698531702446` wei TIDE (~692,340.8 TIDE)

---

## UX notes / footguns

1. **Three paths are independent** — user can swap, ve-claim, and standard-claim in any order.
2. **ve claim is one-shot** — show clear confirmation before submitting.
3. **Lock extension** is done on **veBAO directly**, not the distributor.
4. **Approve BAO** to distributor before swap (`convertBao`).
5. **TIDE amount in calldata must match proof exactly** — no partial claims.
6. **Test deployment** uses same merkle root for both paths — production will use separate roots.
7. Contract is **not upgradeable** — address and rules are final after deploy.

---

## Read-only getters useful for UI

```solidity
// Timing
startDate(), endDate(), SNAPSHOT_BLOCK()

// Caps / totals
totalBaoConverted(), totalTideSwapAndVe(), totalTideStandard()
MAX_BAO(), MAX_TIDE_SWAP_AND_VE(), MAX_TIDE_STANDARD(), MIN_TIDE_OUT()

// User state
hasClaimedVeBao(user), hasClaimedStandard(user), baoConverted(user)

// Tokens (immutable)
TIDE(), BAO(), VEBAO()

// Conversion
baoToTide(baoAmount), tideToBao(tideAmount)
```

---

## Constants (immutable on-chain)

| Constant | Value |
|---|---|
| `TIDE_NUMERATOR` / `RATE_DENOMINATOR` | 1758 / 10000 → 0.1758 TIDE per BAO |
| `MIN_TIDE_OUT` | 10 TIDE |
| `MAX_BAO` | 1,422,000,000 BAO |
| `MAX_TIDE_SWAP_AND_VE` | 250,000,000 TIDE (paths 1 + 2 shared) |
| `MAX_TIDE_STANDARD` | 30,000,000 TIDE (path 3) |
| `SNAPSHOT_BLOCK` | 25,000,000 |

---

## Testing status

- Unit + fork tests pass against deployed contract
- Verified on mainnet fork: swap, ve claim, standard claim, combined flows, double-claim reverts
- Distributor funded with **11M TIDE** for live testing

Run fork tests:

```bash
script/test-fork.sh -vv
# or: forge test --match-path "test/tide/HarborTideDistributor_v1.fork.t.sol" -vv --fork-url mainnet
```

Run local unit + invariant tests (no RPC):

```bash
forge test --match-path "test/tide/**" --no-match-path "test/tide/*.fork.t.sol"
```

---

## Production note

Production distributor deploys use **production TIDE** (`0xDA187eB6F4D7eE3a0b8f5cd81eED8d347f5693aD`), a new distributor address, production merkle roots, and final claim window dates. Read `TIDE()` from the deployed distributor — do not assume the test fork address.
