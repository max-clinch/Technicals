// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title ACTXToken
 * @author Suleman Ismaila
 * @notice Upgradeable ERC20 token for BlessUP (ACT.X)
 * @dev UUPS upgradeable; fixed supply minted at initialization to treasury multisig.
 */
contract ACTXToken is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    AccessControlUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /// Roles
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");

    /// Tokenomics
    uint256 public constant TOTAL_SUPPLY = 100_000_000 * 10 ** 18; // 100,000,000 ACTX with 18 decimals

    /// Tax/Recycling
    /// tax rate in basis points (10000 = 100%)
    uint16 private _taxRateBasisPoints;
    uint16 public constant MAX_TAX_BPS = 1000; // hard cap 10%

    /// reservoir address receives taxes to be recycled/distributed
    address private _reservoirAddress;

    /// Reward pool holds pre-allocated rewards (defaults to proxy address)
    address private _rewardPool;

    /// exempt list (e.g., treasury, exchanges)
    mapping(address => bool) private _isTaxExempt;

    /// Events
    event TaxCollected(address indexed from, address indexed to, uint256 amount, uint256 tax);
    event TaxRateUpdated(uint16 oldRate, uint16 newRate);
    event ReservoirUpdated(address oldReservoir, address newReservoir);
    event TaxExemptUpdated(address indexed account, bool isExempt);
    event RewardDistributed(
        address indexed manager, address indexed recipient, uint256 amount, bytes32 indexed activityId
    );
    event RewardPoolFunded(address indexed funder, uint256 amount, uint256 newBalance);
    event RewardPoolWithdrawn(address indexed to, uint256 amount, uint256 newBalance);
    event RewardPoolUpdated(address indexed oldPool, address indexed newPool, uint256 migratedBalance);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the ACTX token behind a UUPS proxy
     * @param name_ token name
     * @param symbol_ token symbol
     * @param treasury initial treasury (multi-sig) receives full supply
     * @param initialReservoir reservoir address for taxes (can be treasury)
     * @param initialTaxBps initial tax in basis points (e.g., 200 = 2%)
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        address treasury,
        address initialReservoir,
        uint16 initialTaxBps
    ) external initializer {
        require(treasury != address(0), "treasury-required");
        require(initialTaxBps <= MAX_TAX_BPS, "tax-too-high");

        __ERC20_init(name_, symbol_);
        __ERC20Burnable_init();
        __AccessControl_init();
        __Ownable_init(treasury);

        // Roles
        _grantRole(DEFAULT_ADMIN_ROLE, treasury);
        _grantRole(REWARD_MANAGER_ROLE, treasury);

        // Tokenomics: mint fixed supply to treasury
        _mint(treasury, TOTAL_SUPPLY);

        // tax settings
        _taxRateBasisPoints = initialTaxBps;
        _reservoirAddress = initialReservoir == address(0) ? treasury : initialReservoir;
        _rewardPool = address(this);

        // Exempt treasury and reservoir by default
        _setTaxExemptInternal(treasury, true);
        _setTaxExemptInternal(_reservoirAddress, true);
        _setTaxExemptInternal(_rewardPool, true);
    }

    // --- View helpers ---
    /// @notice Current transfer tax rate in basis points
    function taxRateBasisPoints() external view returns (uint16) {
        return _taxRateBasisPoints;
    }

    /// @notice Wallet receiving recycling taxes
    function reservoirAddress() external view returns (address) {
        return _reservoirAddress;
    }

    /// @notice Address that currently escrows the reward pool
    function rewardPool() external view returns (address) {
        return _rewardPool;
    }

    /// @notice Balance available for future reward distributions
    function rewardPoolBalance() public view returns (uint256) {
        return balanceOf(_rewardPool);
    }

    /// @notice Returns true if the account is exempt from transaction tax
    function isTaxExempt(address account) external view returns (bool) {
        return _isTaxExempt[account];
    }

    // --- Admin functions (only owner / multisig expected) ---
    /// @notice Update tax rate (only owner/multisig)
    function setTaxRate(uint16 newTaxBps) external onlyOwner {
        require(newTaxBps <= MAX_TAX_BPS, "tax-too-high");
        uint16 old = _taxRateBasisPoints;
        _taxRateBasisPoints = newTaxBps;
        emit TaxRateUpdated(old, newTaxBps);
    }

    /// @notice Update reservoir address (only owner)
    function setReservoirAddress(address newReservoir) external onlyOwner {
        require(newReservoir != address(0), "zero-reservoir");
        address old = _reservoirAddress;
        _reservoirAddress = newReservoir;
        _setTaxExemptInternal(newReservoir, true);
        if (old != owner() && old != _rewardPool) {
            _setTaxExemptInternal(old, false);
        }
        emit ReservoirUpdated(old, newReservoir);
    }

    /// @notice Set tax exemption for an account
    function setTaxExempt(address account, bool exempt) external onlyOwner {
        require(account != address(0), "zero-account");
        _setTaxExemptInternal(account, exempt);
    }

    /// @notice Move reward pool bookkeeping to a new address (e.g. dedicated vault)
    /// @dev Any balance held by the previous pool is automatically migrated
    function setRewardPool(address newPool) external onlyOwner {
        require(newPool != address(0), "zero-pool");
        address oldPool = _rewardPool;
        if (oldPool == newPool) {
            return;
        }

        uint256 balanceToMove = balanceOf(oldPool);
        _rewardPool = newPool;

        _setTaxExemptInternal(newPool, true);
        if (balanceToMove > 0) {
            _transfer(oldPool, newPool, balanceToMove);
        }

        if (oldPool != owner() && oldPool != _reservoirAddress) {
            _setTaxExemptInternal(oldPool, false);
        }

        emit RewardPoolUpdated(oldPool, newPool, balanceToMove);
    }

    // --- Reward distribution (REWARD_MANAGER_ROLE) ---
    /// @notice Distribute pre-funded rewards to a recipient
    function distributeReward(address recipient, uint256 amount) external onlyRole(REWARD_MANAGER_ROLE) {
        _distributeReward(recipient, amount, bytes32(0));
    }

    /// @notice Distribute rewards with an off-chain activity identifier for analytics
    function distributeRewardWithContext(address recipient, uint256 amount, bytes32 activityId)
        external
        onlyRole(REWARD_MANAGER_ROLE)
    {
        _distributeReward(recipient, amount, activityId);
    }

    /// @notice Allow owner to fund internal reward pool
    function fundRewardPool(uint256 amount) external onlyOwner {
        require(amount > 0, "zero-amount");
        _transfer(owner(), _rewardPool, amount);
        emit RewardPoolFunded(msg.sender, amount, rewardPoolBalance());
    }

    /// @notice Owner can withdraw from internal reward pool
    function withdrawFromPool(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero-to");
        _transfer(_rewardPool, to, amount);
        emit RewardPoolWithdrawn(to, amount, rewardPoolBalance());
    }

    // --- Transfer override with tax ---
    function _update(address from, address to, uint256 amount) internal override(ERC20Upgradeable) {
        bool isStandardTransfer = from != address(0) && to != address(0);
        bool exempt = _isTaxExempt[from] || _isTaxExempt[to];
        bool applyTax = isStandardTransfer && _taxRateBasisPoints > 0 && !exempt;

        if (applyTax) {
            uint256 tax = (amount * uint256(_taxRateBasisPoints)) / 10_000;
            if (tax > 0) {
                uint256 netAmount;
                unchecked {
                    netAmount = amount - tax;
                }
                super._update(from, _reservoirAddress, tax);
                super._update(from, to, netAmount);
                emit TaxCollected(from, to, amount, tax);
                return;
            }
        }

        super._update(from, to, amount);
    }

    // --- Upgradeability guard ---
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // --- Rescue helpers (owner only) ---
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(this), "cannot rescue self");
        require(to != address(0), "zero-to");
        require(IERC20(token).transfer(to, amount), "rescue-failed");
    }

    // --- Internal helpers ---
    /// @dev Shared reward distribution logic (no minting, only spends pre-funded balance)
    function _distributeReward(address recipient, uint256 amount, bytes32 activityId) internal {
        require(recipient != address(0), "zero-recipient");
        require(amount > 0, "zero-amount");
        require(rewardPoolBalance() >= amount, "insufficient-pool");

        _transfer(_rewardPool, recipient, amount);
        emit RewardDistributed(msg.sender, recipient, amount, activityId);
    }

    /// @dev Internal helper to manage the tax exemption bitmap
    function _setTaxExemptInternal(address account, bool exempt) internal {
        _isTaxExempt[account] = exempt;
        emit TaxExemptUpdated(account, exempt);
    }

    /// @dev Storage gap for future upgrades
    uint256[50] private __gap;
}
