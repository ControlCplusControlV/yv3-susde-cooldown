// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {BaseHealthCheck} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {Auction, AuctionSwapper} from "@periphery/swappers/AuctionSwapper.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISUSDe, UserCooldown} from "./interfaces/ethena/ISUSDe.sol";

import "forge-std/console.sol"; // TODO: delete

contract Strategy is BaseHealthCheck, AuctionSwapper {
    using SafeERC20 for ERC20;

    address private constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    ISUSDe private constant SUSDE =
        ISUSDe(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);

    uint64 public maxTendBasefee = 30e9; // 30 gwei
    uint80 public minCooldownAmount = 1_000e18; // default minimium is 1_000e18;
    uint80 public minAuctionAmount = 1_000e18; // 1000 USDe
    uint16 public minSUSDeDiscountBps = 50; // 0.50%
    uint256 public depositLimit;

    constructor(string memory _name) BaseHealthCheck(USDE, _name) {
        _enableAuction(USDE, address(SUSDE));
    }

    /*//////////////////////////////////////////////////////////////
                      External Views
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the amount of usde being cooldown
     * @return . The cooldown amount in usde
     */
    function coolingUSDe() external view returns (uint256) {
        return _coolingUSDe();
    }

    /**
     * @notice Returns the amount of asset with expect to report
     * @return . The amount of asset this strategy expects to report
     */
    function estimatedTotalAssets() external view returns (uint256) {
        return _estimatedTotalAssets();
    }

    /*//////////////////////////////////////////////////////////////
                      External Setters
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the deposit limit. Can only be called by management
     * @param _depositLimit The deposit limit
     */
    function setDepositLimit(uint256 _depositLimit) external onlyManagement {
        depositLimit = _depositLimit;
    }

    /**
     * @notice Sets the max base fee for tends. Can only be called by management
     * @param _maxTendBasefee The maximum base fee allowed
     */
    function setMaxTendBasefee(uint64 _maxTendBasefee) external onlyManagement {
        maxTendBasefee = _maxTendBasefee;
    }

    /**
     * @notice Sets the min amount to be cooled down. Can only be called by management
     * @param _minCooldownAmount The minimum amount of sUSDe before a cooldown is triggered
     */
    function setMinCooldownAmount(uint80 _minCooldownAmount)
        external
        onlyManagement
    {
        minCooldownAmount = _minCooldownAmount;
    }

    /**
     * @notice Sets the min amount to be auctioned. Can only be called by management
     * @param _minAuctionAmount The minimum amount of USDe to auction
     */
    function setMinAuctionAmount(uint80 _minAuctionAmount)
        external
        onlyManagement
    {
        minAuctionAmount = _minAuctionAmount;
    }

    /**
     * @notice Sets the min discount on sUSDe to accept. Can only be called by management
     * @param _minSUSDeDiscountBps The minimum discount in basis points when buying sUSDe
     */
    function setMinSUSDeDiscountBps(uint16 _minSUSDeDiscountBps)
        external
        onlyManagement
    {
        minSUSDeDiscountBps = _minSUSDeDiscountBps;
    }

    /**
     * @notice Sets the auction contract. Can only be called by emergency authorized
     * @param _auction The minimum auction contract address
     */
    function setAuction(address _auction) external onlyEmergencyAuthorized {
        if (_auction != address(0)) {
            require(Auction(_auction).want() == address(SUSDE)); // dev: wrong want
        }
        auction = _auction;
    }

    /*//////////////////////////////////////////////////////////////
                     BaseStrategy Overrides 
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Can deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy can attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        // do nothing
    }

    /**
     * @dev Should attempt to free the '_amount' of 'asset'.
     *
     * NOTE: The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        // 1. we can check if any sUSDe with redeemable/withdrawable
        if (SUSDE.cooldownDuration() == 0) {
            uint256 _amountRedeemed = _redeemSUSDe();
            if (_amountRedeemed >= _amount) return;
        }
        UserCooldown memory _cooldown = _cooldownStatus();
        if (
            _cooldown.underlyingAmount != 0 &&
            _cooldown.cooldownEnd <= block.timestamp
        ) {
            _unstakeSUSDe();
        }
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        _adjustPosition();
        _totalAssets = _estimatedTotalAssets();
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies.
     *
     *   EX:
     *       return asset.balanceOf(yieldSource);
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return _withdrawLimit The available amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256 _withdrawLimit) {
        _withdrawLimit = asset.balanceOf(address(this));

        if (SUSDE.cooldownDuration() == 0) {
            _withdrawLimit += SUSDE.convertToAssets(
                SUSDE.balanceOf(address(this))
            );
        }
        UserCooldown memory _cooldown = _cooldownStatus();
        if (
            _cooldown.underlyingAmount != 0 &&
            _cooldown.cooldownEnd <= block.timestamp
        ) {
            _withdrawLimit += _cooldown.underlyingAmount;
        }
        console.log("wl: %e", _withdrawLimit);
    }

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     *
     */
    function availableDepositLimit(address _owner)
        public
        view
        override
        returns (uint256)
    {
        uint256 _totalAssets = TokenizedStrategy.totalAssets();
        return _totalAssets >= depositLimit ? 0 : depositLimit - _totalAssets;
    }

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * This will have no effect on PPS of the strategy till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     *
     */
    function _tend(uint256 _totalIdle) internal override {
        _adjustPosition();
    }

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     *
     */
    function _tendTrigger() internal view override returns (bool) {
        if (TokenizedStrategy.totalAssets() == 0) {
            return false;
        }

        if (block.basefee >= maxTendBasefee) {
            return false;
        }

        UserCooldown memory _cooldown = _cooldownStatus();

        if (_cooldown.underlyingAmount != 0) {
            return _cooldown.cooldownEnd <= block.timestamp;
        }

        if (TokenizedStrategy.isShutdown()) {
            return false;
        }

        if (SUSDE.balanceOf(address(this)) >= minCooldownAmount) {
            return true;
        }

        return false;
    }

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     *
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // TODO: do we need to do more
        _freeFunds(_amount);
    }

    /*//////////////////////////////////////////////////////////////
                     AuctionSwapper Overrides 
    //////////////////////////////////////////////////////////////*/

    /**
     * @param _token Address of the token being auctioned off
     */
    function _auctionKicked(address _token)
        internal
        virtual
        override
        returns (uint256 _kicked)
    {
        require(_token == USDE); // dev: only sell usde
        //_kicked = super._auctionKicked(_token);
        _kicked = _looseAsset();
        require(_kicked >= minAuctionAmount); // dev: too little
    }

    /**
     * @param . Address of the token being taken.
     * @param _usdeTakeAmount Amount of `_token` needed.
     * @param _susdeReceiveAmount Amount of `want` that will be payed.
     */
    function _preTake(
        address, /*_token*/
        uint256 _usdeTakeAmount,
        uint256 _susdeReceiveAmount
    ) internal virtual override {
        uint256 _receiveAmountInUSDe = SUSDE.convertToAssets(
            _susdeReceiveAmount
        );
        uint256 _surplusBps = ((_receiveAmountInUSDe - _usdeTakeAmount) *
            MAX_BPS) / _usdeTakeAmount;
        console.log("surplus: %e", _surplusBps);
        require(_surplusBps >= minSUSDeDiscountBps); // dev: below minDiscount
        asset.transfer(address(auction), _usdeTakeAmount);
    }

    /*//////////////////////////////////////////////////////////////
                     Internal Doers of Things
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adjusts the strategy's position
     */
    function _adjustPosition() internal {
        uint24 _cooldownDuration = SUSDE.cooldownDuration();

        // Check if we can directly redeem
        if (_cooldownDuration == 0 && _looseSUDe() != 0) {
            _redeemSUSDe();
        }

        // Check if we have shares to unstake
        UserCooldown memory _cooldown = _cooldownStatus();
        if (
            _cooldown.underlyingAmount != 0 &&
            _cooldown.cooldownEnd <= block.timestamp
        ) {
            _unstakeSUSDe();
            // zero the cooldown info
            _cooldown.underlyingAmount = 0;
            _cooldown.cooldownEnd = 0;
        }

        // Cooldown sUSDE if there is no funds being cooled down
        if (
            _cooldownDuration != 0 &&
            _cooldown.underlyingAmount == 0 &&
            _looseSUDe() >= minCooldownAmount
        ) {
            _cooldownSUSDe();
        }

        // 3. kick auction?
    }

    /**
     * @notice Initiates cooldown of sUSDe
     * @return . Amount of asset that will be released after cooldown
     */
    function _cooldownSUSDe() internal returns (uint256) {
        uint256 sharesToCooldown = Math.min(
            _looseSUDe(),
            SUSDE.maxRedeem(address(this))
        );
        return SUSDE.cooldownShares(sharesToCooldown);
    }

    /**
     * @notice Redeeems USDe from sUSDe stakingInitiates cooldown of
     * @return . Amount of asset redeemed
     */
    function _redeemSUSDe() internal returns (uint256) {
        uint256 sharesToRedeem = Math.min(
            _looseSUDe(),
            SUSDE.maxRedeem(address(this))
        );
        return SUSDE.redeem(sharesToRedeem, address(this), address(this));
    }

    /**
     * @notice Unstakes cooldowned sUSDe
     */
    function _unstakeSUSDe() internal {
        SUSDE.unstake(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                          Internal Views
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns this contract's loose asset
     * @return . The asset loose in this contract
     */
    function _looseAsset() internal view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Returns this contract's loose sUSDe
     * @return . The sUSDe loose in this contract
     */
    function _looseSUDe() internal view returns (uint256) {
        return SUSDE.balanceOf(address(this));
    }

    /**
     * @notice Returns the amount of usde being cooldown
     * @return . The cooldown amount in usde
     */
    function _coolingUSDe() internal view returns (uint256) {
        UserCooldown memory _cooldown = _cooldownStatus();
        return _cooldown.underlyingAmount;
    }

    /**
     * @notice Returns the amount of asset with expect to report
     * @return . The amount of asset this strategy expects to report
     */
    function _estimatedTotalAssets() internal view returns (uint256) {
        return
            _looseAsset() +
            _coolingUSDe() +
            SUSDE.convertToAssets(_looseSUDe());
    }

    /**
     * @notice Returns this contract's cooldown
     * @return . The cooldown for this contract
     */
    function _cooldownStatus() internal view returns (UserCooldown memory) {
        return SUSDE.cooldowns(address(this));
    }
}
