## ACT.X Overview

**Author:** Suleman Ismaila

ACT.X is a UUPS-upgradeable ERC-20 rewards token designed for BlessUP's time-banked media engagement program. The contract locks a fixed 100,000,000 ACT.X supply at deployment, enforces a recycling tax, and exposes reward distribution hooks that BlessUP's off-chain engine can call once an agent completes their daily 15-minute positive media requirement.

Key highlights:

- Fixed supply minted to a Gnosis Safe treasury; no further minting functions exist.
- Role-gated reward distribution from a pre-funded reservoir (`distributeReward` / `distributeRewardWithContext`).
- Transfer tax (basis points) routed to a recycling reservoir wallet to sustain future rewards.
- Hardened UUPS upgrade path guarded by the multi-sig (`DEFAULT_ADMIN_ROLE`) plus owner-only operational levers.
- Event surface tailored for the BlessUP RPC node so leaderboards and time-bank proofs can sync instantly.

## Contract Architecture

`src/ACTXToken.sol`

- Inherits `ERC20Upgradeable`, `ERC20BurnableUpgradeable`, `AccessControlUpgradeable`, `OwnableUpgradeable`, and `UUPSUpgradeable`.
- State:
  - `TOTAL_SUPPLY` (100M ACT.X with 18 decimals).
  - `_taxRateBasisPoints` and `_reservoirAddress` for the recycling mechanism (capped at `MAX_TAX_BPS = 10%`).
  - `_rewardPool` address (default = proxy itself) holding the pre-funded reward quota.
  - `_isTaxExempt` map for treasury, reservoir, reward pool, exchanges, etc.
- Roles:
  - `DEFAULT_ADMIN_ROLE` (multi-sig) authorizes upgrades and grants/revokes roles.
  - `REWARD_MANAGER_ROLE` is given to BlessUP's backend/RPC node.
- Reward lifecycle:
  1. Treasury calls `fundRewardPool(amount)` to move tokens into the pool (tax-exempt).
  2. RPC node calls `distributeReward` or `distributeRewardWithContext(recipient, amount, activityId)`.
  3. Event `RewardDistributed` logs the manager, recipient, amount, and optional activity hash for off-chain verification.
  4. `withdrawFromPool` lets the treasury reclaim unused tokens.
- Tax lifecycle:
  - `_transfer` enforces the tax unless either side is `taxExempt`.
  - Taxes are forwarded to `_reservoirAddress` and surface via `TaxCollected`.
  - Owner-only setters adjust tax rate, reservoir wallet, and exemption list.
- Safety:
  - `_authorizeUpgrade` is restricted to `DEFAULT_ADMIN_ROLE`.
  - Rescue hook protects against accidentally stuck ERC-20s.
  - Reward pool migration (`setRewardPool`) automatically moves balances and manages exemptions so new vaults can come online without downtime.

Supplementary contracts (`src/Vesting.sol`, `src/Airdrop.sol`) give auditors reference implementations for the 4-year vesting schedule and Sybil-resistant airdrops; both are intentionally minimal and Ownable, ready to be swapped for Merkle/KYC gates.

## Testing & Validation

Run the full suite (unit, fuzz, invariants):

```bash
forge test
```

The suite covers:

- Initialization invariants (supply, roles, exemptions).
- Tax routing + opt-out behavior.
- Reward pool funding, withdrawals, metadata-aware distribution, and access control.
- Upgrade authorization plus a mock V2 upgrade proving the storage layout works.
- Fuzz tests that stress transfer/tax bounds and ensure total supply never drifts.

Gas profiling / invariant scripting hooks are already wired through Forge—run `forge snapshot` or `forge test --gas-report` before deployments.

## Deployment Workflow

1. Configure `script/Deploy.s.sol` environment variables:
   - Required: `RPC_URL`, `PRIVATE_KEY`, `TREASURY_ADDRESS`, `RESERVOIR_ADDRESS`, `INITIAL_TAX_BPS`
   - Optional overrides: `TOKEN_NAME`, `TOKEN_SYMBOL`, `NETWORK_LABEL`, `METADATA_DIR` (defaults to `./broadcast`)
   - Auto-verification (optional): set `AUTO_VERIFY=true`, `ETHERSCAN_API_KEY=<key>`, and optionally override `VERIFIER` (default `etherscan`) or `VERIFY_CHAIN` (default `sepolia`)
2. Deploy implementation + proxy:

```bash
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --verify \
  --fs-write    # required so the script can emit metadata via vm.writeJson
```

3. After deployment:
   - Review `./broadcast/actx-latest.json` (auto-written by the script) for the canonical implementation, proxy, airdrop, and vesting addresses plus the chain metadata.
   - Treasury (multi-sig) calls `fundRewardPool` to seed the reward pipeline (can be done in the same Safe transaction bundle).
   - Assign BlessUP’s RPC signer to `REWARD_MANAGER_ROLE`.
   - If `AUTO_VERIFY=true`, the script will invoke `forge verify-contract` via `ffi` so no manual CLI call is required; otherwise, record the proxy address + initialization tx hash for the audit log and verify manually when ready.

## RPC Node & Integration Plan

The BlessUP RPC node is the interface between the time-bank engine and the token:

- **Read path**
  - Poll `RewardDistributed` and `TaxCollected` events for leaderboard/state sync.
  - Expose lightweight REST/WebSocket endpoints so the mobile app can display balances, reward histories, and outstanding quotas in real time.
- **Write path**
  - After the backend verifies 15 minutes of positive media (plus referral/vendor logic), it calls `distributeRewardWithContext`.
  - The `activityId` is a deterministic hash (e.g., keccak256(agentId, yyyy-mm-dd, missionType)) so off-chain analytics can cross-match.
  - If the recycle reservoir dips below a threshold, the RPC node can alert the treasury to call `fundRewardPool` or rotate the reservoir wallet.
- **Resilience**
  - Use a dedicated Sepolia/Base RPC provider with auto-retry + nonce management for high-frequency micro rewards.
  - Run health checks that watch total supply, reward pool balance, and reservoir inflows; alert if any invariant drifts.

## Security Posture

- All sensitive actions (`setTaxRate`, `setReservoirAddress`, `setRewardPool`, `fundRewardPool`, upgrades) are owner-only and expected to run through a Gnosis Safe.
- `DEFAULT_ADMIN_ROLE` is intentionally scoped to the multi-sig to ensure `_authorizeUpgrade` can’t be bypassed.
- Reward distribution cannot mint—managers can only spend what the treasury has already escrowed.
- Transfer tax is hard-capped and guarded by input validation.
- Vesting & Airdrop helpers defer to external audits and can be replaced with more sophisticated Merkle/zero-knowledge flows.
- Recommended checks before mainnet:
  - `forge coverage` + `forge fmt`.
  - Static analyzers (Slither, MythX, or Foundry’s `anvil --fork` differential testing).
  - Third-party review (Code4rena/Immunefi bounty) per BlessUP policy.

## Folder Map

- `src/`
  - `ACTXToken.sol` – core token logic, tax, reward distribution, upgrade controls.
  - `Airdrop.sol` – owner-controlled batch airdrop helper (replace with Merkle for production).
  - `Vesting.sol` – 4-year linear vesting with 1-year cliff for team/advisors.
- `test/`
  - `ACTX.t.sol` – unit tests for roles, rewards, taxes, upgrades.
  - `FuzzInvariants.t.sol` – fuzz + invariant coverage for supply/tax/pool behavior.
- `script/`
  - `Deploy.s.sol` – Foundry script that deploys implementation + ERC1967 proxy and runs initializer.

## Next Steps Before Base Mainnet

1. Deploy and validate on Sepolia; capture tx hashes, addresses, and block numbers in an audit appendix.
2. Integrate the BlessUP RPC node with `distributeRewardWithContext` and event listeners.
3. Add gas benchmarking + snapshot diffs once production traffic models are finalized.
4. Commission an external audit and prep a Code4rena/Immunefi bounty brief.
5. Configure monitoring (Grafana/ELK) for the reservoir balance, reward throughput, and tax inflows to keep micro-reward UX snappy.


# ACTX Impl: 0x461005Ba8908E4EFcC33C099160D203a9F879124

# ACTX Proxy: 0x658d3d892D1fA63DdCA509924a4be175ebd2F487

# Airdrop: 0x64fccff8f9217dbF0e3C20F434C9d007AEFE2aCA

# Vesting: 0x2267123AaC4c7AcB4334368Df7cB0b4f4ae2F6b4
