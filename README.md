# Paradox Fi

<img src="https://i.imgur.com/iUSsiOX.jpeg" width="50%">



**Fixed-income infrastructure for Uniswap v4 liquidity providers.**

Visit [demo.paradoxfi.xyz](https://demo.paradoxfi.xyz) for a Unichain Testnet demo.

Paradox Fi is a Uniswap v4 hook protocol that splits LP fee streams into two tradeable instruments, each also representing half of the LP's underlying liquidity principal:

- **FYT (Fixed Yield Token)** — ERC-1155, `tokenId = positionId`, `amount = halfNotional`. Entitles the holder to half the LP's v4 liquidity principal plus a guaranteed fixed fee yield at epoch maturity.
- **VYT (Variable Yield Token)** — ERC-1155, `tokenId = positionId`, `amount = 1`. Entitles the holder to the other half of the LP's v4 liquidity principal plus any fee income above the fixed obligation (Zone A only).

LPs deposit into v4 pools as normal. The hook intercepts each deposit, mints FYT and VYT atomically to the LP, and routes all swap fees through a priority waterfall. At epoch maturity, FYT and VYT holders redeem independently — each token removes half the position's v4 liquidity plus its respective fee tranche.

> [!WARNING]
> **Unaudited Smart Contracts**
> 
> This repository contains smart contracts that have **not** been audited. 
> Do **not** use in production environments until a formal security audit has been completed.

---

## Table of Contents

1. [How It Works](#how-it-works)
2. [Token Model](#token-model)
3. [Architecture](#architecture)
4. [Contract Reference](#contract-reference)
5. [Rate Formula](#rate-formula)
6. [Settlement Zones](#settlement-zones)
7. [Epoch Models](#epoch-models)
8. [Repository Structure](#repository-structure)
9. [Getting Started](#getting-started)
10. [Running Tests](#running-tests)
11. [Security Considerations](#security-considerations)
12. [Deployment](#deployment)

---

## How It Works

### The LP Experience

1. An LP adds liquidity to a Uniswap v4 pool that has Paradox Fi's hook attached.
2. The `afterAddLiquidity` callback fires. The hook mints to the LP:
   - **FYT** (`tokenId = positionId`, `amount = notional/2`) — half the position value at current price
   - **VYT** (`tokenId = positionId`, `amount = 1`) — a flag token representing the other half
3. Every swap generates protocol fees. `afterSwap` routes them to `YieldRouter`, which fills the fixed tranche first, skims to the reserve buffer, then credits the variable tranche.
4. **Liquidity removal is blocked until epoch maturity.** `beforeRemoveLiquidity` reverts unconditionally while an epoch is active.
5. At maturity, anyone calls `EpochManager.settle()`, then `YieldRouter.finalizeEpoch()` pushes funds to `MaturityVault`.
6. **FYT holders** call `MaturityVault.redeemFYT(positionId, poolKey)` — burns FYT, removes `liquidity/2` from the v4 pool (underlying tokens to caller), plus pays fixed fee yield.
7. **VYT holders** call `MaturityVault.redeemVYT(positionId, poolKey)` — burns VYT, removes the other `liquidity/2` from v4, plus pays variable fee yield (or zero in Zone B/C).

### What Makes FYT a Bond

- The fixed rate is **locked at deposit time** from the oracle TWAP. It cannot change.
- The maturity date is **set at epoch open** by the epoch model. It cannot change.
- FYT is **transferable** — the holder at maturity receives the payout, not the original minter.
- Both principal (v4 liquidity) and fee yield are returned at redemption.

### Exploit Prevention

The constraint "no removal until maturity" closes the deposit–transfer–withdraw exploit class entirely. An attacker who deposits, transfers FYT+VYT to another wallet, then tries to withdraw finds that `beforeRemoveLiquidity` reverts — the liquidity is locked until the epoch settles, at which point the token holders (whoever they are) redeem independently.

---

## Token Model

### FYT and VYT are position-unique

Unlike classical fixed-income protocols that issue epoch-fungible bonds, FYT and VYT in Paradox Fi are **position-unique**: both use `positionId` as the ERC-1155 `tokenId`. Two LPs in the same epoch with different tick ranges hold FYT with different tokenIds.

This is a deliberate trade-off: fungibility would allow the deposit→transfer→withdraw exploit. Position-uniqueness closes the exploit while preserving transferability — each token can still be sold on secondary markets, the buyer simply acquires the claim on that specific position's principal and fees.

### Token amounts

| Token | TokenId | Amount | Represents |
|---|---|---|---|
| FYT | `positionId` | `notional / 2` | Half the LP's token0-denominated deposit value |
| VYT | `positionId` | `1` | The other half (flag token) |

### Position metadata

FYToken is the **single source of truth** for position data. Each `positionId` stores:

```solidity
struct PositionData {
    bytes32 poolId;       // v4 PoolId
    int24   tickLower;    // LP range lower bound
    int24   tickUpper;    // LP range upper bound
    uint128 liquidity;    // v4 liquidity units at deposit
    uint128 halfNotional; // notional / 2 (token0-denominated)
    uint256 epochId;      // epoch this position was opened in
}
```

VYToken reads from FYToken rather than duplicating this storage. MaturityVault also reads from FYToken at redemption to know which liquidity to remove from v4.

### Principal recovery at maturity

FYT and VYT together reconstruct the full LP position:

- `redeemFYT` removes `floor(liquidity / 2)` — underlying tokens go to the FYT holder
- `redeemVYT` removes `liquidity - floor(liquidity / 2)` — underlying tokens go to the VYT holder

Whatever is actually withdrawn (accounting for price drift and impermanent loss since deposit) is sent directly to each holder. Together they receive the full position value.

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
                    └─┬──┬──┬────────┘
                      │  │  │
           ┌──────────┘  │  └──────────────┐
           │             │                  │
  ┌────────▼───┐  ┌──────▼─────┐  ┌────────▼──────┐
  │EpochManager│  │ YieldRouter│  │  RateOracle   │
  │            │  │ (waterfall)│  │  (ring buf)   │
  └────────────┘  └─────┬──────┘  └───────────────┘
                        │ finalizeEpoch()
                  ┌─────▼──────┐
                  │MaturityVault│  ← escrow + liquidity removal + redemption
                  └──────┬──────┘
                    ┌────┴─────┐
                    │          │
                 FYToken    VYToken
                (ERC-1155) (ERC-1155)
                 stores      reads
                 pos data   from FYT
```

### Design Principles

**Thin hook, fat core.** `ParadoxHook` contains no business logic. Each callback extracts the minimum data from v4 context and delegates to core contracts.

**Accounting vs. settlement separation.** `YieldRouter.ingest()` is pure accounting — no token transfers. Tokens move exactly twice per epoch: `finalizeEpoch()` pushes fee tokens to `MaturityVault`, and `redeem*()` returns principal (via v4 `modifyLiquidity`) plus fees to holders.

**No PositionManager NFT.** The original design issued an ERC-721 as a position receipt. This is eliminated — FYT and VYT together fully reconstruct the position and serve as both the economic instrument and the exit credential. FYToken stores the canonical position metadata.

**Liquidity locked until maturity.** `beforeRemoveLiquidity` reverts while an epoch is active. After `settle()` clears the active epoch, removal is permitted — used exclusively by `MaturityVault` acting as an operator of the hook.

---

## Contract Reference

### Core Contracts

| Contract | Path | Description |
|---|---|---|
| `ParadoxHook` | `src/core/ParadoxHook.sol` | v4 hook. Mints FYT+VYT on deposit, blocks early removal, routes fees. Holds v4 LP positions as operator. |
| `EpochManager` | `src/core/EpochManager.sol` | Epoch state machine (ACTIVE → SETTLED). Tracks `totalNotional` and `fixedObligation`. |
| `YieldRouter` | `src/core/YieldRouter.sol` | Fee ingestion and priority waterfall. Tracks `fixedAccrued`, `variableAccrued`, `reserveBuffer`. |
| `MaturityVault` | `src/core/MaturityVault.sol` | Escrow. At redemption: removes v4 liquidity via `modifyLiquidity` + pays fee tranches. |
| `RateOracle` | `src/core/RateOracle.sol` | 360-slot ring buffer. Provides 30-day TWAP and volatility for the rate formula. |

### Token Contracts

| Contract | Path | Description |
|---|---|---|
| `FYToken` | `src/tokens/FYToken.sol` | ERC-1155. `tokenId = positionId`, `amount = notional/2`. Canonical store for position metadata. |
| `VYToken` | `src/tokens/VYToken.sol` | ERC-1155. `tokenId = positionId`, `amount = 1`. Reads position metadata from FYToken. |

### Epoch Models

| Contract | Path | Description |
|---|---|---|
| `IEpochModel` | `src/epochs/IEpochModel.sol` | Interface all epoch models must implement. |
| `FixedDateEpochModel` | `src/epochs/FixedDateEpochModel.sol` | Fixed-duration epochs (1 day – 2 years). `shouldAutoRoll()` = false. |

### Libraries

| Library | Path | Description |
|---|---|---|
| `EpochId` | `src/libraries/EpochId.sol` | Packs `[64-bit chainId][160-bit poolId][32-bit epochIndex]` into `uint256`. Used as epoch identifier. |
| `PositionId` | `src/libraries/PositionId.sol` | Same bit layout as EpochId but lower field is a per-pool deposit counter. Used as FYT/VYT tokenId. |
| `FixedRateMath` | `src/libraries/FixedRateMath.sol` | Rate formula and obligation arithmetic. All values WAD (1e18 = 100%). |
| `FeeAccounting` | `src/libraries/FeeAccounting.sol` | Extracts fee amounts from v4 `BalanceDelta`. |

---

## Rate Formula

The fixed rate offered to each LP at deposit time:

```
r_fixed = α × r_TWAP − β × (σ / 3) + γ × max(0, util − 0.5)
```

| Variable | Description |
|---|---|
| `r_TWAP` | 30-day TWAP of annualised fee yield (from `RateOracle`) |
| `σ` | Annualised standard deviation of per-observation fee yields |
| `util` | Fraction of epoch FYTs already sold (0–1 in WAD) |
| `α, β, γ` | Governance weights stored per pool in `EpochManager` |

**Bounds:** floored at `MIN_RATE = 0.0001e18` (0.01% APR), capped at `r_TWAP`. The cap ensures the protocol never commits to more than its historical average fee yield.

**Genesis rate:** the first epoch opens with a governance-supplied `genesisTwapWad` since the oracle has no history at pool creation. Should be set to a realistic estimate for the pool's expected fee yield. A low genesis rate (e.g. `MIN_RATE`) produces a near-zero obligation for the first epoch, making the demo output look like all fees go to variable — this is correct but can be confusing. Use `GENESIS_TWAP=0.05e18` for a more visible first epoch.

**Fixed obligation** (simple interest):

```
obligation = totalNotional × r_fixed × epochDuration / SECONDS_PER_YEAR
```

---

## Settlement Zones

At epoch maturity, `YieldRouter.finalizeEpoch()` classifies the epoch:

| Zone | Condition | FYT Fee Payout | VYT Fee Payout | Buffer Effect |
|---|---|---|---|---|
| **A — Full coverage** | `fixedAccrued ≥ obligation` | Full obligation | `variableAccrued` | Grows by skim |
| **B — Buffer rescue** | `fixedAccrued + buffer ≥ obligation` | Full obligation | 0 | Decreases by shortfall |
| **C — Haircut** | `fixedAccrued + buffer < obligation` | `fixedAccrued + buffer` | 0 | Depleted to 0 |

Note: fee payouts are in addition to the principal (v4 liquidity) returned at redemption. Even in Zone C, both FYT and VYT holders receive their full principal back — only the fee yield is haircut.

The **reserve buffer** is a cross-epoch pool-level cushion. It grows from a 10% skim on surplus fees in Zone A epochs and is drawn down before haircuts occur.

---

## Epoch Models

Epoch models implement `IEpochModel` and determine when an epoch matures.

### `FixedDateEpochModel`

Every epoch has a fixed calendar duration. `computeMaturity(startTime, params)` returns `startTime + duration`. Supported durations: 1 day – 2 years. `shouldAutoRoll()` returns `false`.

After settlement, a keeper calls `ParadoxHook.openNextEpoch(poolId)` to start the next epoch using fresh oracle values.

### Adding a New Model

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

---

## Repository Structure

```
src/
├── core/
│   ├── ParadoxHook.sol         # v4 hook — mints FYT+VYT, blocks early removal, routes fees
│   ├── EpochManager.sol        # epoch state machine + notional tracking
│   ├── YieldRouter.sol         # fee waterfall accounting
│   ├── MaturityVault.sol       # escrow + v4 liquidity removal + redemption
│   └── RateOracle.sol          # fee TWAP + volatility ring buffer
├── tokens/
│   ├── FYToken.sol             # ERC-1155, tokenId=positionId, stores position metadata
│   └── VYToken.sol             # ERC-1155, tokenId=positionId, reads from FYToken
├── epochs/
│   ├── IEpochModel.sol         # pluggable maturity strategy interface
│   └── FixedDateEpochModel.sol # fixed-duration epoch model
└── libraries/
    ├── EpochId.sol             # epoch identifier codec
    ├── PositionId.sol          # position identifier codec (FYT/VYT tokenId)
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
│   ├── YieldRouter.t.sol
│   ├── MaturityVault.t.sol
│   ├── RateOracle.t.sol
│   ├── ParadoxHook.t.sol
│   └── TokenTest.t.sol         # FYToken + VYToken
├── integration/
│   ├── IntegrationBase.sol     # full stack harness: MockPoolManager with modifyLiquidity stub
│   ├── HookFlow.t.sol          # deposit → swap → settle → redeem end-to-end
│   ├── DeficitScenarios.t.sol  # Zone A / B / C coverage scenarios
│   └── EpochRollover.t.sol     # epoch lifecycle: settle → open next
└── invariant/
    └── Invariants.t.sol        # solvency + conservation + no-double-spend

script/
├── Deploy.s.sol                # full protocol deployment (CREATE2 hook, setOperator)
├── CreatePool.s.sol            # initialize pool + seed liquidity
├── Demo.s.sol                  # live demo: swaps + fee accounting + payout preview
└── RedeemSimulation.s.sol      # local-only: warp to maturity + simulate redemption
```

---

## Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh/) (`forge`, `cast`, `anvil`)

### Installation

```bash
git clone https://github.com/deme-ventures/paradox-fi
cd paradox-fi
forge install
```

### Dependencies

| Package | Purpose |
|---|---|
| `uniswap/v4-core` | `PoolManager`, `BalanceDelta`, `PoolKey`, `StateLibrary` |
| `uniswap/v4-periphery` | `BaseHook`, `IPositionManager`, `PoolSwapTest` |
| `OpenZeppelin/openzeppelin-contracts` | `ERC1155`, `ERC1155Supply`, `AccessControl`, `ReentrancyGuard`, `SafeERC20` |

---

## Running Tests

```bash
# All tests
forge test

# Unit tests only
forge test --match-path "test/unit/*"

# Integration tests
forge test --match-path "test/integration/*"

# Verbose with traces
forge test -vvv

# Specific test
forge test --match-test test_zoneC_haircutApplied -vvv

# Higher fuzz coverage
forge test --fuzz-runs 10000
```

---

## Security Considerations

### Access Control

| Function | Caller |
|---|---|
| `afterAddLiquidity`, `afterSwap` | `onlyPoolManager` (BaseHook) |
| `beforeRemoveLiquidity` | `onlyPoolManager` — reverts while epoch active |
| `initializePool`, `openNextEpoch` | owner only |
| `EpochManager.settle()` | permissionless after maturity |
| `YieldRouter.finalizeEpoch()` | `authorizedCaller` (hook) or owner |
| `MaturityVault.redeemFYT/redeemVYT` | unrestricted — any token holder |
| FYT/VYT mint | `MINTER_ROLE` → hook |
| FYT/VYT burn | `BURNER_ROLE` → MaturityVault |

### Reentrancy

`YieldRouter` and `MaturityVault` use OZ `ReentrancyGuard`. The critical invariant: `ingest()` never transfers tokens. Token movement in `redeemFYT`/`redeemVYT` follows checks-effects-interactions: claimed flag set → burn token → call `poolManager.modifyLiquidity` → transfer fee payout.

### Liquidity Lock

`beforeRemoveLiquidity` reverts with `RemovalBlockedUntilMaturity` while `epochManager.activeEpochIdFor(poolId) != 0`. After `settle()` clears the active epoch, removal proceeds. MaturityVault is granted `setOperator` rights over the hook in PoolManager, allowing it to call `modifyLiquidity` at redemption without the LP's direct involvement.

### Hook Address Validation

The hook must be deployed at an address whose lower 14 bits equal `0x1640` (permission flags: `afterInitialize | afterAddLiquidity | beforeRemoveLiquidity | afterSwap`). This is enforced by `PoolManager` at pool creation. `Deploy.s.sol` verifies this on-chain after deployment.

### hookData recipient

`sender` in v4 hook callbacks is always the periphery contract (`IPositionManager`), not the end user. The actual LP address must be passed through `hookData`. `afterAddLiquidity` decodes `abi.decode(hookData, (address))` as the FYT/VYT recipient, falling back to `sender` when `hookData` is empty (tests). Production calls via `CreatePool.s.sol` encode `deployer` as hookData in the `MINT_POSITION` action.

### Supply Snapshot Timing

`MaturityVault.receiveSettlement()` snapshots `FYToken.epochPositionCount(epochId)` at settlement time. Any FYT/VYT minted after settlement does not participate in that epoch's fee distribution. Principal (v4 liquidity) is always recoverable regardless of snapshot timing.

### Known Limitations

- **Notional is static.** Computed as `liquidity × sqrtPrice >> 96` at deposit time. Impermanent loss is not reflected in the fixed obligation.
- **Principal split is asymmetric for odd liquidity.** FYT gets `floor(liquidity/2)`, VYT gets `liquidity - floor(liquidity/2)`. The difference is at most 1 liquidity unit.
- **No mid-epoch exit.** Liquidity is locked until maturity. Early sellers must find a buyer for their FYT and VYT on secondary markets.
- **Keeper dependency.** After a non-auto-roll epoch settles, a keeper must call `openNextEpoch()`. No on-chain automation in v1.

---

## Deployment

### Full protocol deployment

```bash
SALT=0x... \
POOL_MANAGER=0x... \
DEPLOYER=0x... \
GOVERNANCE=0x... \
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

`Deploy.s.sol` deploys all contracts, wires authorizations, grants token roles, calls `poolManager.setOperator(maturityVault, true)` (required for liquidity removal at redemption), and initiates two-step ownership transfer to governance.

### Pool creation

```bash
KEY=<pk> \
TOKEN_A=0x... TOKEN_B=0x... \
PARADOX_HOOK=0x... EPOCH_MODEL=0x... \
EPOCH_DURATION=2592000 \
GENESIS_TWAP=50000000000000000 \
forge script script/CreatePool.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  -vvvv
```

`CreatePool.s.sol` calls `hook.initializePool()` first (registers with EpochManager/RateOracle, opens first epoch), then atomically creates the v4 pool and seeds liquidity via `IPositionManager.multicall`. The deployer's FYT and VYT are minted atomically during the seed liquidity step.

### Live demo

```bash
KEY=<pk> TOKEN_A=0x... TOKEN_B=0x... \
PARADOX_HOOK=0x... POSITION_ID=<n> \
SWAP_COUNT=10 SWAP_AMOUNT=5000000000000000000000 \
forge script script/Demo.s.sol --rpc-url $RPC_URL --broadcast -vvvv
```

### Redemption simulation (local only)

```bash
TOKEN_A=0x... TOKEN_B=0x... PARADOX_HOOK=0x... \
POSITION_ID=<n> HOLDER=0x... \
forge script script/RedeemSimulation.s.sol --rpc-url $RPC_URL -vvvv
```

### Contract Addresses

| Contract | Address |
|----------|---------|
| FixedDateEpochModel | 0x22BEA8EB8A3d61Cb183E1Bd048DC177F9E383E51 |
| EpochManager | 0xd9a1053f3A81E38f4d91622A88936a8417736D00 |
| RateOracle | 0x2D6def49AA9dEBFc19FA9691CC5755d4bA0d1F6A |
| YieldRouter | 0xBBD6aB4183a765705d6C00f4c91255acFd8FB61f |
| FYToken | 0xD429959619A21A1A9425ce8a9D1404Bf315C022B |
| VYToken | 0x99C6eBa2318918c7C8Fa12505B3BE7D153659A57 |
| MaturityVault | 0x586A85671780f7756f4d46231845A28D102B7152 |
| ParadoxHook | 0xE5295e92c18De8A07E631e1C6154cb4eEC315640 |

---

## License

MIT
