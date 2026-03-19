# Paradox Fi

<img src="https://github.com/user-attachments/assets/a0df709e-8817-418e-90d0-3e0e241d90e8" width="50%">

**Fixed-income infrastructure for Uniswap v4 liquidity providers.**

Paradox Fi is a Uniswap v4 hook protocol that splits LP fee streams into two tradeable instruments:

- **FYT (Fixed Yield Token)** — an ERC-1155 bond. Holders receive a guaranteed annualised yield at epoch maturity, regardless of actual fee volume (subject to reserve buffer coverage).
- **VYT (Variable Yield Token)** — an ERC-1155 residual claim. Holders receive any fee income above the fixed obligation after each epoch settles.

LPs deposit into v4 pools as normal. The hook intercepts each deposit, mints FYT and VYT atomically, and routes all fee income through a priority waterfall that honours fixed obligations first.

---

## Table of Contents

1. [How It Works](#how-it-works)
2. [Architecture](#architecture)
3. [Contract Reference](#contract-reference)
4. [Rate Formula](#rate-formula)
5. [Settlement Zones](#settlement-zones)
6. [Epoch Models](#epoch-models)
7. [Token Economics](#token-economics)
8. [Repository Structure](#repository-structure)
9. [Getting Started](#getting-started)
10. [Running Tests](#running-tests)
11. [Security Considerations](#security-considerations)
12. [Deployment](#deployment)

---

## How It Works

### The LP Experience

1. An LP adds liquidity to a Uniswap v4 pool that has Paradox Fi's hook attached.
2. The `afterAddLiquidity` callback fires. The hook mints:
   - An **ERC-721 position NFT** representing the deposit (via `PositionManager`)
   - **FYT tokens** equal to the LP's token0-denominated notional (via `FYToken`)
   - **One VYT token** for the position (via `VYToken`)
3. Every swap generates protocol fees. The hook's `afterSwap` callback routes fees to `YieldRouter`, which fills the fixed tranche first, then skims to the reserve buffer, then credits the variable tranche.
4. At epoch maturity, anyone can call `settle()`. The protocol computes coverage, transfers funds to `MaturityVault`, and marks the epoch closed.
5. FYT holders call `redeemFYT()` to receive their pro-rata share of the fixed tranche. VYT holders call `redeemVYT()` for their share of the variable tranche.

### What Makes It a Bond

- The fixed rate is **locked at deposit time** from the oracle TWAP. It cannot change.
- The maturity date is **set at epoch open** by the epoch model. It cannot change.
- FYT is **fungible within an epoch** — all LPs in the same epoch hold the same tokenId and trade at the same market price.
- Both FYT and VYT are **freely transferable**. The holder at settlement time receives the payout, not the original minter.

---

## Architecture

```
                    ┌─────────────────┐
                    │  Uniswap v4     │
                    │  PoolManager    │
                    └────────┬────────┘
                             │ callbacks
                    ┌────────▼────────┐
                    │  ParadoxHook    │  ← thin orchestrator, no business logic
                    └─┬──┬──┬──┬─────┘
                      │  │  │  │
           ┌──────────┘  │  │  └──────────────┐
           │             │  │                  │
  ┌────────▼───┐  ┌──────▼──┴──┐  ┌───────────▼──┐
  │EpochManager│  │PositionMgr │  │  RateOracle  │
  │            │  │  (ERC-721) │  │  (ring buf)  │
  └────────────┘  └────────────┘  └──────────────┘
           │
  ┌────────▼────────┐
  │   YieldRouter   │  ← fee waterfall, pure accounting
  └────────┬────────┘
           │ finalizeEpoch()
  ┌────────▼────────┐
  │  MaturityVault  │  ← escrow + pro-rata redemption
  └─────────────────┘
           │
    ┌──────┴──────┐
    │             │
  FYToken      VYToken
  (ERC-1155)  (ERC-1155)
```

### Design Principles

**Thin hook, fat core.** `ParadoxHook` contains no business logic. Each callback extracts the minimum data from the v4 context and delegates to core contracts. This keeps the hook auditable and the core contracts testable in isolation.

**Accounting vs. settlement separation.** `YieldRouter.ingest()` runs on every swap and is pure accounting — no token transfers. Token movement happens exactly twice per epoch: `finalizeEpoch()` pushes funds to `MaturityVault`, and `redeem*()` pulls them to holders. This eliminates reentrancy on the swap-critical path.

**Pluggable epoch models.** `EpochManager` delegates maturity computation to an `IEpochModel` contract. `FixedDateEpochModel` (30-day, 90-day, etc.) is the v1 implementation. Rolling and coverage-triggered models can be added without changing the core.

---

## Contract Reference

### Core Contracts

| Contract | Path | Description |
|---|---|---|
| `ParadoxHook` | `src/core/ParadoxHook.sol` | Uniswap v4 hook. Entry point for all LP interactions. Inherits `BaseHook`. |
| `EpochManager` | `src/core/EpochManager.sol` | Sole source of truth for epoch state transitions. Owns the PENDING → ACTIVE → SETTLED state machine. |
| `PositionManager` | `src/core/PositionManager.sol` | ERC-721 registry. One NFT per LP deposit. Stores tick range, notional, epoch, and fixed rate. |
| `YieldRouter` | `src/core/YieldRouter.sol` | Fee ingestion and priority waterfall. Tracks `fixedAccrued`, `variableAccrued`, and `reserveContrib` per epoch. |
| `MaturityVault` | `src/core/MaturityVault.sol` | Escrow and pro-rata redemption. Receives settled funds from `YieldRouter`. Burns FYT/VYT on redemption. |
| `RateOracle` | `src/core/RateOracle.sol` | Per-pool fee TWAP and volatility oracle. 360-slot ring buffer, rate-limited to one new slot per 4 hours. |

### Token Contracts

| Contract | Path | Description |
|---|---|---|
| `FYToken` | `src/tokens/FYToken.sol` | ERC-1155. `tokenId = epochId`. Fungible within an epoch. Minted by `PositionManager`, burned by `MaturityVault`. |
| `VYToken` | `src/tokens/VYToken.sol` | ERC-1155. `tokenId = positionId`. One token per position (amount always 1). Tracks `epochSupply` for settlement snapshots. |

### Epoch Models

| Contract | Path | Description |
|---|---|---|
| `IEpochModel` | `src/epochs/IEpochModel.sol` | Interface all epoch models must implement. |
| `FixedDateEpochModel` | `src/epochs/FixedDateEpochModel.sol` | Fixed-duration epochs. Supports 1 day – 2 year durations. `shouldAutoRoll()` returns false. |

### Libraries

| Library | Path | Description |
|---|---|---|
| `EpochId` | `src/libraries/EpochId.sol` | Packs `[64-bit chainId][160-bit poolId][32-bit epochIndex]` into a single `uint256`. Used as FYT tokenId. |
| `PositionId` | `src/libraries/PositionId.sol` | Same bit layout as `EpochId` but lower field is a per-pool deposit counter. Used as the ERC-721 and VYT tokenId. |
| `FixedRateMath` | `src/libraries/FixedRateMath.sol` | Fixed-rate formula and obligation arithmetic. All values in WAD (1e18 = 100%). |
| `FeeAccounting` | `src/libraries/FeeAccounting.sol` | Extracts fee amounts from v4 `BalanceDelta`. Handles both swap directions and price conversion. |

---

## Rate Formula

The fixed rate offered to each LP at deposit time is:

```
r_fixed = α × r_TWAP − β × (σ / 3) + γ × max(0, util − 0.5)
```

| Variable | Description |
|---|---|
| `r_TWAP` | 30-day TWAP of annualised fee yield for the pool (from `RateOracle`) |
| `σ` | Annualised standard deviation of per-observation fee yields |
| `util` | Fraction of epoch FYTs already sold (0–1 in WAD) |
| `α, β, γ` | Governance-controlled weights, stored per pool in `EpochManager` |

**Bounds:** result is floored at `MIN_RATE = 0.0001e18` (0.01% APR) and capped at `r_TWAP`. The cap ensures the protocol never commits to more than its historical average fee yield.

**Default weights:** `α = 0.80`, `β = 0.30`, `γ = 0.15`. Higher-volatility pools should use a larger `β` to widen the safety margin.

**Fixed obligation** is computed as simple interest:

```
obligation = notional × r_fixed × epochDuration / SECONDS_PER_YEAR
```

---

## Settlement Zones

At epoch maturity, `YieldRouter.finalizeEpoch()` classifies the epoch into one of three zones:

| Zone | Condition | FYT Payout | VYT Payout | Buffer Effect |
|---|---|---|---|---|
| **A — Full coverage** | `fixedAccrued ≥ obligation` | `obligation` (full) | `variableAccrued` | Grows by skim |
| **B — Buffer rescue** | `fixedAccrued + buffer ≥ obligation` | `obligation` (full) | 0 | Decreases by shortfall |
| **C — Haircut** | `fixedAccrued + buffer < obligation` | `fixedAccrued + buffer` (< obligation) | 0 | Depleted to 0 |

The **reserve buffer** is a cross-epoch pool-level cushion. It grows automatically during Zone A epochs via a configurable skim rate (default 10% of surplus fees) and is drawn down in Zone B before haircuts occur in Zone C.

---

## Epoch Models

Epoch models are pluggable strategies implementing `IEpochModel`. They are registered per-pool at initialisation time and determine when an epoch matures.

### `FixedDateEpochModel`

The v1 model. Every epoch has a fixed calendar duration. `computeMaturity(startTime, params)` returns `startTime + duration`.

Supported durations: any value between `MIN_DURATION = 1 day` and `MAX_DURATION = 2 years`. Canonical production durations: 7d, 30d, 90d, 180d, 365d.

`shouldAutoRoll()` returns `false` — each epoch is discrete. After settlement, the owner or a keeper must call `ParadoxHook.openNextEpoch()` to start the next epoch.

### Adding a New Model

Implement `IEpochModel`:

```solidity
interface IEpochModel {
    function computeMaturity(uint64 startTime, bytes calldata modelParams)
        external view returns (uint64 maturity);
    function shouldAutoRoll() external view returns (bool);
    function modelType() external pure returns (bytes32);
    function validateParams(bytes calldata modelParams) external pure returns (bool);
    function paramsDescription() external pure returns (string memory);
}
```

Register via `EpochManager.registerPool()` with the new model address.

---

## Token Economics

### FYT (Fixed Yield Token)

- **TokenId:** `epochId` — the same for all LPs in one epoch.
- **Amount minted:** equal to the LP's token0-denominated notional at deposit price.
- **Redemption:** `holderBalance × fytTotal / fytSupplyAtSettle`. Supply is snapshotted at settlement; late buyers do not dilute early holders.
- **Access control:** `MINTER_ROLE` → `PositionManager`. `BURNER_ROLE` → `PositionManager` (early exit) + `MaturityVault` (redemption).

### VYT (Variable Yield Token)

- **TokenId:** `positionId` — unique per LP deposit.
- **Amount:** always exactly 1 per position.
- **Redemption:** `vytTotal / vytSupplyAtSettle` — a flat per-position share of the variable tranche. Zero in Zone B and C.
- **Epoch supply tracking:** `VYToken.epochSupply(epochId)` tracks the count of VYT positions in each epoch for the settlement snapshot. This is separate from `ERC1155Supply.totalSupply(positionId)` (which is 0 or 1).
- **Access control:** same as FYToken.

### Position NFT (ERC-721)

- One NFT per LP deposit. Holds tick range, liquidity, notional, epoch, and fixed rate.
- Marked `exited = true` on `beforeRemoveLiquidity`. The NFT is **not burned** — it is the bearer credential for `MaturityVault` redemption.
- Freely transferable. The holder at redemption time receives the payout.

---

## Repository Structure

```
src/
├── core/
│   ├── ParadoxHook.sol         # v4 hook — callbacks only
│   ├── EpochManager.sol        # epoch state machine
│   ├── PositionManager.sol     # ERC-721 position registry
│   ├── YieldRouter.sol         # fee waterfall accounting
│   ├── MaturityVault.sol       # escrow + redemption
│   └── RateOracle.sol          # fee TWAP + volatility
├── tokens/
│   ├── FYToken.sol             # ERC-1155 fixed yield token
│   └── VYToken.sol             # ERC-1155 variable yield token
├── epochs/
│   ├── IEpochModel.sol         # pluggable maturity strategy interface
│   └── FixedDateEpochModel.sol # fixed-duration epoch model
└── libraries/
    ├── EpochId.sol             # epoch identifier codec
    ├── PositionId.sol          # position identifier codec
    ├── FixedRateMath.sol       # rate formula + obligation math
    └── FeeAccounting.sol       # v4 BalanceDelta fee extraction

test/
├── unit/
│   ├── EpochId.t.sol
│   ├── PositionId.t.sol
│   ├── FixedRateMath.t.sol
│   ├── FeeAccounting.t.sol
│   ├── FixedDateEpochModel.t.sol
│   ├── EpochManager.t.sol
│   ├── PositionManager.t.sol
│   ├── YieldRouter.t.sol
│   ├── MaturityVault.t.sol
│   ├── RateOracle.t.sol
│   ├── ParadoxHook.t.sol
│   └── TokenTest.t.sol         # FYToken + VYToken
├── integration/
│   ├── IntegrationBase.sol     # shared harness: full stack deployment + helpers
│   ├── HookFlow.t.sol          # deposit → swap → settle → redeem end-to-end
│   ├── DeficitScenarios.t.sol  # Zone A / B / C coverage scenarios
│   └── EpochRollover.t.sol     # epoch lifecycle: settle → open next
└── invariant/
    └── Invariants.t.sol        # solvency + conservation + no-double-spend

script/
└── 01_DeployTokens.s.sol
└── 02_DeployCore.s.sol
└── 03_DeployParadoxFi.s.sol
└── 04_CreatePool.s.sol
└── 05_DemoParadoxFi.s.sol
└── MineAddress.s.sol
```

---

## Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh/) (`forge`, `cast`, `anvil`)

### Installation

```bash
git clone https://github.com/paradoxfi/contracts
cd contracts
forge install
```

### Dependencies

| Package | Version | Purpose |
|---|---|---|
| `uniswap/v4-core` | latest | `PoolManager`, `BalanceDelta`, `PoolKey`, `StateLibrary` |
| `uniswap/v4-periphery` | latest | `BaseHook` |
| `OpenZeppelin/openzeppelin-contracts` | ^5.0 | `ERC721`, `ERC1155`, `ERC1155Supply`, `AccessControl`, `ReentrancyGuard`, `SafeERC20` |

---

## Running Tests

```bash
# All tests
forge test

# Unit tests only
forge test --match-path "test/unit/*"

# Integration tests only
forge test --match-path "test/integration/*"

# Invariant tests only
forge test --match-path "test/invariant/*"

# Verbose output with traces
forge test -vvv

# Specific test
forge test --match-test test_zoneC_haircutApplied -vvv

# Fuzz runs (default 256, increase for deeper coverage)
forge test --fuzz-runs 10000
```

### Test Coverage

The test suite covers:

| Layer | Tests | Coverage |
|---|---|---|
| Libraries | Unit + fuzz for all four libraries | Bit layout, overflow, round-trips |
| Epoch models | Unit + fuzz for `FixedDateEpochModel` | Duration bounds, maturity computation |
| Core contracts | Unit + fuzz per contract | State transitions, access control, arithmetic |
| Hook | Unit with mock `PoolManager` | All four callback paths |
| Integration | Full stack with real contracts | Zone A/B/C, rollover, redemption |
| Invariants | Fuzz across fee/obligation space | Solvency, conservation, no double-spend |

---

## Security Considerations

### Access Control

Every state-mutating function is either:
- **`onlyPoolManager`** (hook callbacks) — only the v4 `PoolManager` may call
- **`onlyAuthorized`** (core contracts) — only the hook or owner may call `ingest`, `addNotional`, `openEpoch`
- **`onlyOwner`** — governance operations (pool registration, rate parameter changes)
- **Permissionless** — `settle()` on `EpochManager` after maturity (anyone can trigger settlement)

Token mint and burn use OZ `AccessControl` with separate `MINTER_ROLE` and `BURNER_ROLE`. `PositionManager` holds both; `MaturityVault` holds only `BURNER_ROLE`.

### Reentrancy

`YieldRouter` and `MaturityVault` use OZ `ReentrancyGuard` on all state-mutating functions. The key invariant: `ingest()` never transfers tokens. All ERC-20 movement is deferred to `finalizeEpoch()`, which executes checks-effects-interactions correctly (state updated before external calls).

### Hook Address Validation

The `ParadoxHook` address must have specific bits set to match the declared permission flags (`0x1640` for the current flag combination). This is a v4 protocol invariant enforced by `PoolManager` at pool initialisation. In tests this is handled via `vm.etch`.

### Oracle Manipulation

`RateOracle` uses a rate-limited ring buffer (minimum 4 hours between new slots). A single large swap cannot meaningfully manipulate the 30-day TWAP. The rate cap at `r_TWAP` means even a manipulated oracle cannot cause the protocol to commit to an obligation that exceeds historical fee yield.

### Supply Snapshot Timing

`MaturityVault.receiveSettlement()` snapshots FYT and VYT supply at the moment it is called (inside `YieldRouter.finalizeEpoch()`). Any FYT/VYT minted **after** settlement does not participate in that epoch's redemption. This is the intended behaviour — it prevents late buyers from diluting early holders.

### Known Limitations

- **Notional is static.** The LP notional is computed at deposit price (`liquidity × sqrtPrice >> 96`) and never updated. Impermanent loss after deposit is not reflected in the fixed obligation.
- **Single fee token.** All fee accounting is denominated in token0. Pools where fees accrue in token1 use a conversion approximation in `afterSwap`.
- **No early FYT redemption.** FYT can only be redeemed at maturity. Early exit requires selling on the secondary market.
- **Keeper dependency.** After a non-auto-roll epoch settles, a keeper (or governance) must call `openNextEpoch()`. There is no on-chain automation for this in v1.

---

## Deployment

Pool registration follows a two-step process:

**Step 1** — Register with Paradox Fi by calling `ParadoxHook.initializePool()`:

```solidity
hook.initializePool(
    poolKey,
    ParadoxHook.InitParams({
        model:       address(fixedDateModel),
        modelParams: abi.encode(uint32(30 days)),
        alphaWad:    0.80e18,
        betaWad:     0.30e18,
        gammaWad:    0.15e18
    }),
    0.0001e18  // genesisTwapWad — MIN_RATE for the first epoch
);

**Step 2** — Initialise the v4 pool normally via `IPoolManager.initialize()`.

```

This registers the pool with `EpochManager` and `RateOracle`, and opens the first epoch at the genesis rate. Subsequent epochs use live oracle data via `openNextEpoch()`.

### Contract Addresses

> Mainnet and testnet deployments are not yet live.

---

## License

TODO
