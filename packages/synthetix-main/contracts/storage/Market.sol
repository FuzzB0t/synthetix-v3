//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@synthetixio/core-contracts/contracts/utils/SetUtil.sol";

import "@synthetixio/core-contracts/contracts/utils/HeapUtil.sol";

import "./Distribution.sol";
import "./CollateralConfiguration.sol";
import "./MarketPoolInfo.sol";

import "../interfaces/external/IMarket.sol";

/**
 * @title TODO The Market object connects external contracts that implement the `IMarket` interface to the system, thus providing them with liquidity, and exposing the system itself to the market's debt.
 *
 * The Market object's main responsibility is to track collateral provided by the pools that support it, and to trace their debt back to such pools.
 */
library Market {
    using Distribution for Distribution.Data;
    using HeapUtil for HeapUtil.Data;
    using DecimalMath for uint256;
    using DecimalMath for uint128;
    using DecimalMath for int256;
    using DecimalMath for int128;

    using SafeCastU256 for uint256;
    using SafeCastU128 for uint128;
    using SafeCastI256 for int256;
    using SafeCastI128 for int128;

    error MarketNotFound(uint128 marketId);

    struct Data {
        /**
         * @dev Numeric identifier for the market.
         *
         * Must be unique.
         */
        uint128 id;
        /**
         * @dev External contract address of the market that implements the `IMarket` interface, which this Market objects wraps.
         *
         * Note: This object is how the system tracks the market. The actual market is external to the system, i.e. its own contract.
         */
        address marketAddress;
        /**
         * @dev TODO Issuance can be seen as how much USD the Market "has issued", printed, or has asked the system to mint on its behalf.
         *
         * More precisely it can be seen as the net difference between the USD burnt and the USD minted by the market.
         *
         * More issuance means that the market owes more USD to the system.
         *
         * A market burns USD when users deposit it in exchange for some asset that the market offers.
         * The Market object calls `MarketManager.depositUSD()`, which burns the USD, and decreases its issuance.
         *
         * A market mints USD when users return the asset that the market offered and thus withdraw their USD.
         * The Market object calls `MarketManager.withdrawUSD()`, which mints the USD, and increases its issuance.
         *
         * Instead of burning, the Market object could transfer USD to and from the MarketManager, but minting and burning takes the USD out of circulation, which doesn't affect `totalSupply`, thus simplifying accounting.
         *
         * How much USD a market can mint depends on how much credit capacity is given to the market by the pools that support it, and reflected in `Market.capacity`.
         *
         * TODO: Consider renaming this to netIssuance.
         */
        int128 issuanceD18;
        /**
         * @dev TODO The total amount of USD that the market could withdraw if it were to immediately unwrap all its positions.
         *
         * The Market's capacity increases when the market burns USD, i.e. when it deposits USD in the MarketManager.
         *
         * It decreases when the market mints USD, i.e. when it withdraws USD from the MarketManager.
         *
         * The Market's capacity also depends on how much credit is given to it by the pools that support it.
         *
         * TODO: How does reported debt play with this definition?
         * TODO: Consider renaming to creditCapacity.
         */
        uint128 capacityD18;
        /**
         * @dev TODO The total balance that the market had the last time that its debt was distributed.
         *
         * A Market's debt is distributed when the reported debt of its associated external market is rolled into the pools that provide liquidity to it.
         */
        int128 lastDistributedMarketBalanceD18;
        /**
         * @dev A heap of pools for which the market has not yet hit its maximum credit capacity.
         *
         * The heap is ordered according to this market's max value per share setting in the pools that provide liquidity to it. See `MarketConfiguration.maxDebtShareValue`.
         *
         * The heap's getMax() and extractMax() functions allow us to retrieve the pool with the lowest `maxDebtShareValue`, since its elements are inserted and prioritized by negating their `maxDebtShareValue`.
         *
         * Lower max values per share are on the top of the heap. I.e. the heap could look like this:
         *  .    -1
         *      / \
         *     /   \
         *    -2    \
         *   / \    -3
         * -4   -5
         *
         * TL;DR: This data structure allows us to easily find the pool with the lowest or "most vulnerable" max value per share and process it if its actual value per share goes beyond this limit.
         *
         * TODO: Check that the "max credit capacity" naming is consistent with what's actually on the code.
         */
        HeapUtil.Data inRangePools;
        /**
         * @dev An array of pools for which the market has hit its maximum credit capacity.
         *
         * Used to reconnect pools to the market, when it falls back below its maximum credit capacity.
         *
         * See inRangePools for why a heap is used here.
         *
         * TODO: Where is this used? Maybe just here because we probably need this. If not needed we can remove this property or empty the slot.
         */
        HeapUtil.Data outRangePools;
        /**
         * @dev A market's debt distribution connects markets to the debt distribution chain, in this case pools. Pools are actors in the market's debt distribution, where the amount of shares they possess depends on the amount of collateral they provide to the market. The value per share of this distribution depends on the total debt or balance of the market (netIssuance + reportedDebt).
         *
         * The debt distribution chain will move debt from the market into its connected pools.
         *
         * Actors: Pools.
         * Shares: (TODO is it 1:1 or proportional?) The USD denominated credit capacity that the pool provides to the market.
         * Value per share: Debt per dollar of credit that the associated external market accrues.
         *
         */
        Distribution.Data poolsDebtDistribution;
        /**
         * @dev Additional info needed to remebmer pools when they are removed from the distribution (or subsequently re-added)
         */
        mapping(uint128 => MarketPoolInfo.Data) pools;
        /**
         * @dev TODO Array of entries of market provided collateral.
         *
         * Markets may obtain additional liquidity, beyond that coming from stakers, by providing their own collateral.
         *
         * TODO: Rename to depositedCollaterals?
         */
        DepositedCollateral[] depositedCollateral;
        /**
         * @dev TODO The maximum amount of market provided collateral, per type, that this market can deposit.
         */
        mapping(address => uint) maximumDepositableD18;
    }

    /**
     * @dev TODO Data structure that allows the Market to track the amount of market provided collateral, per type.
     */
    struct DepositedCollateral {
        address collateralType;
        uint amountD18;
    }

    /**
     * @dev Returns the market stored at the specified market id.
     *
     * TODO: Consider using a constant instead of a hardcoded string here, and likewise to all similar uses of storage access in the code.
     */
    function load(uint128 id) internal pure returns (Data storage data) {
        bytes32 s = keccak256(abi.encode("Market", id));
        assembly {
            data.slot := s
        }
    }

    /**
     * @dev TODO Queries the external market contract for the amount of debt it has issued.
     *
     * The reported debt of a market represents the amount of USD that the market would ask the system to mint, if all of its positions were to be immediately closed.
     *
     * The reported debt of a market is collateralized by the assets in the pools which back it.
     *
     * See the `IMarket` interface.
     */
    function getReportedDebt(Data storage self) internal view returns (uint) {
        return IMarket(self.marketAddress).reportedDebt(self.id);
    }

    /**
     * @dev TODO
     *
     * SIP 309 markets can lock x amount of credit - use case: insurance market (read SIP)
     * If a pool config change decreases credit available to market AND amount is less - prevents pools from decreasing if resulting amount is below this value.
     */
    function getLockedLiquidity(Data storage self) internal view returns (uint) {
        return IMarket(self.marketAddress).locked(self.id);
    }

    /**
     * @dev TODO Returns the total balance of the market.
     *
     * A market's total balance represents its debt plus its issuance, and thus represents the total outstanding debt of the market.
     *
     * Example:
     * (1 EUR = 1.11 USD)
     * If an Euro market has received 100 USD to mint 90 EUR, its reported debt is 90 EUR or 100 USD, and its issuance is -100 USD.
     * Thus, its total balance is 100 USD of reported debt minus 100 USD of issuance, which is 0 USD.
     *
     * Additionally, the market's totalBalance might be affected by price fluctuations via reportedDebt, or fees.
     *
     * TODO: Consider renaming to totalDebt()? totalBalance is more correct, but totalDebt is easier to understand.
     */
    function totalBalance(Data storage self) internal view returns (int) {
        return int(getReportedDebt(self)) + self.issuanceD18 - int(getDepositedCollateralValue(self));
    }

    /**
     * @dev TODO Returns the USD value for the total amount of collateral provided by the market itself.
     *
     * Note: This is not liquidity provided by stakers through pools.
     *
     * See SIP 308.
     */
    function getDepositedCollateralValue(Data storage self) internal view returns (uint) {
        uint totalDepositedCollateralValueD18 = 0;

        // Sweep all DepositedCollateral entries and aggregate their USD value.
        for (uint i = 0; i < self.depositedCollateral.length; i++) {
            DepositedCollateral memory entry = self.depositedCollateral[i];
            CollateralConfiguration.Data storage config = CollateralConfiguration.load(entry.collateralType);

            uint priceD18 = CollateralConfiguration.getCollateralPrice(config);

            totalDepositedCollateralValueD18 += priceD18.mulDecimal(entry.amountD18);
        }

        return totalDepositedCollateralValueD18;
    }

    /**
     * @dev TODO Returns the amount of liquidity that a certain pool provides to the market.

     * This liquidity is obtained by reading the amount of shares that the pool has in the market's debt distribution, which in turn represents the amount of USD denominated credit capacity that the pool has provided to the market.
     */
    function getPoolLiquidity(Data storage self, uint128 poolId) internal view returns (uint) {
        return self.poolsDebtDistribution.getActorShares(bytes32(uint(poolId)));
    }

    /**
     * @dev TODO Given an amount of shares that represent USD liquidity from a pool, and a maximum value per share, returns the potential contribution to debt that these shares could accrue, if their value per share was to hit the maximum.
     *
     * The amount of liquidity provided by the pool * delta of maxValue per share.
     *
     * TODO: Try to illustrate with an example why this could be useful...
     * 100 collateral, 50% coming to this market
     * In docs maxDebtPerDollarOfCollateral - here maxDebtPerShare
     * Goes from debt shares to credit capacity and applying the maxDebtPerDollarOfCollateral to that value.
     *
     * TODO: Explain how this is used.
     * TODO: If the term "capacity" refers to something other than `Market.capacity` then either this should use a different term, of the other one should.
     */
    function getCapacityContribution(
        Data storage self,
        uint liquiditySharesD18,
        int maxDebtShareValueD18
    ) internal view returns (uint contribution) {
        // Determine how much the current value per share deviates from the maximum.
        uint deltaValuePerShareD18 = uint(
            maxDebtShareValueD18 - self.poolsDebtDistribution.valuePerShareD27 / DecimalMath.PRECISION_DOWN_SCALE_INT128
        );

        return uint(deltaValuePerShareD18).mulDecimal(liquiditySharesD18);
    }

    /**
     * @dev TODO Returns true if the market's current capacity is below the amount of locked liquidity.
     *
     * TODO: Should this be <=?
     */
    function isCapacityLocked(Data storage self) internal view returns (bool) {
        return self.capacityD18 < getLockedLiquidity(self);
    }

    /**
     * @dev Gets any outstanding debt. Do not call this method except in tests
     *
     * TODO: Understand distributeDebt() first.
     * TODO: Enforce how this is only to be used in tests!
     */
    function getOutstandingDebt(Data storage self, uint128 poolId) internal returns (int debtChangeD18) {
        return self.pools[poolId].pendingDebtD18.toInt() + self.poolsDebtDistribution.accumulateActor(bytes32(uint(poolId)));
    }

    function getDebtPerShare(Data storage self) internal view returns (int debtPerShareD18) {
        return self.poolsDebtDistribution.valuePerShareD27 / DecimalMath.PRECISION_DOWN_SCALE_INT128;
    }

    /**
     * @dev TODO
     *
     * Just wraps distributeDebtToPools and adjustPoolShares
     *
     * TODO: Understand distributeDebtToPools() first.
     */
    function rebalance(
        uint128 marketId,
        uint128 poolId,
        int maxDebtShareValueD18, // (in USD)
        uint amountD18 // in collateralValue (USD)
    ) internal returns (int debtChangeD18) {
        Data storage self = load(marketId);

        // this function is called by the pool at rebalance markets

        if (self.marketAddress == address(0)) {
            revert MarketNotFound(marketId);
        }

        // Iter avoids griefing - MarketManager can call this with user specified iters and thus clean up a grieved market.
        distributeDebtToPools(self, 9999999999);

        return adjustPoolShares(self, poolId, amountD18, maxDebtShareValueD18);
    }

    /**
     * @dev TODO
     *
     * Determines if a market is joining a pool or not and makes the proper adjustments to the heap and shares,
     * and figures out how much capacity is associated to the pool. Called whenever the pool changes its config.
     *
     * If a vault is reconfigured, if maxPerShareValue is above, it needs to be removed.
     * Updates the heap per changes in maxPerShareValue, not changes in the actual debt of the market.
     *
     * TODO: Understand distributeDebtToPools() first.
     */
    function adjustPoolShares(
        Data storage self,
        uint128 poolId,
        uint newLiquidityD18,
        int newPoolMaxShareValueD18
    ) internal returns (int debtChangeD18) {
        uint oldLiquidityD18 = getPoolLiquidity(self, poolId);
        int oldPoolMaxShareValueD18 = -self.inRangePools.getById(poolId).priority;

        //require(oldPoolMaxShareValue == 0, "value is not 0");
        //require(newPoolMaxShareValue == 0, "new pool max share value is in fact set");

        self.pools[poolId].liquidityAmountD18 = newLiquidityD18.to128();

        int128 valuePerShareD18 = self.poolsDebtDistribution.valuePerShareD27 / DecimalMath.PRECISION_DOWN_SCALE_INT128;

        if (newPoolMaxShareValueD18 < valuePerShareD18) {
            // this will ensure calculations below can correctly gauge shares changes
            newLiquidityD18 = 0;
            self.inRangePools.extractById(poolId);
            self.outRangePools.insert(poolId, newPoolMaxShareValueD18.to128());
        } else {
            self.inRangePools.insert(poolId, -newPoolMaxShareValueD18.to128());
            self.outRangePools.extractById(poolId);
        }

        int changedValueD18 = self.poolsDebtDistribution.setActorShares(bytes32(uint(poolId)), newLiquidityD18);
        debtChangeD18 = self.pools[poolId].pendingDebtD18.toInt() + changedValueD18;
        self.pools[poolId].pendingDebtD18 = 0;

        // recalculate market capacity
        if (newPoolMaxShareValueD18 > valuePerShareD18) {
            self.capacityD18 += getCapacityContribution(self, newLiquidityD18, newPoolMaxShareValueD18).to128();
        }

        if (oldPoolMaxShareValueD18 > valuePerShareD18) {
            self.capacityD18 -= getCapacityContribution(self, oldLiquidityD18, oldPoolMaxShareValueD18).to128();
        }
    }

    /**
     * @dev TODO
     */
    // the second parameter exists to act as an escape hatch/discourage against griefing
    /**
     * Rotates recorded allocation of debt to any connected pools.
     * NOTE: this function should be called before any pool alters its liquidity allocation (see `rebalance` above)
     */
    function distributeDebtToPools(Data storage self, uint maxIter) internal {
        // Get the current and last distributed market balances.
        // Note: The last distributed balance will be cached within this function's execution.
        int256 targetBalanceD18 = totalBalance(self);
        int256 outstandingBalanceD18 = targetBalanceD18 - self.lastDistributedMarketBalanceD18;

        (, bool exhaustedUp) = bumpPoolsOut(self, outstandingBalanceD18, maxIter);
        (, bool exhaustedDown) = bumpPoolsIn(self, outstandingBalanceD18, maxIter);

        if (!exhaustedDown && !exhaustedUp && self.poolsDebtDistribution.totalSharesD18 > 0) {
            // cannot use `outstandingBalance` here because `self.lastDistributedMarketBalance`
            // may have changed after calling the bump functions above
            self.poolsDebtDistribution.distributeValue(targetBalanceD18 - self.lastDistributedMarketBalanceD18);
            self.lastDistributedMarketBalanceD18 = targetBalanceD18.to128();
        }
    }

    function bumpPoolsOut(
        Data storage self,
        int maxDistributedD18,
        uint maxIter
    ) internal returns (int actuallyDistributedD18, bool exhausted) {
        if (maxDistributedD18 <= 0) {
            return (0, false);
        }

        // Find pools for which this market's max value per share limit is exceeded.
        // Remove them, and distribute their debt up to the limit that is hit.
        // TODO: Polish these comments.
        // Note: This loop should rarely execute the body. When it does, it only executes once for each pool that exceeds the limit since `distributeValue` is not run for most pools. Thus, market users are not hit with any overhead as a result of this.
        uint iters;
        for (iters = 0; iters < maxIter; iters++) {
            // Exit if there are no in range pools.
            if (self.inRangePools.size() == 0) {
                break;
            }

            int targetValuePerShareD18 = self.poolsDebtDistribution.valuePerShareD27 /
                DecimalMath.PRECISION_DOWN_SCALE_INT128 +
                (maxDistributedD18 - actuallyDistributedD18).divDecimal(self.poolsDebtDistribution.totalSharesD18.toInt());

            // Exit if the lowest max value per share does not hit the limit.
            HeapUtil.Node memory lowestLimitPool = self.inRangePools.getMax();

            // `-lowestLimitPool.priority` is actually the max value per share limit of the pool
            if (-lowestLimitPool.priority >= targetValuePerShareD18) {
                break;
            }

            // The pool has hit its maximum value per share and needs to be removed.
            // Update the global distributed and outstanding balances with the debt that was just distributed.
            togglePool(self.inRangePools, self.outRangePools);

            int128 poolMaxValuePerShareD18 = -lowestLimitPool.priority;

            // Distribute the market's debt to the limit, i.e. for that which exceeds the maximum value per share.
            int debtToLimitD18 = self.poolsDebtDistribution.totalSharesD18.toInt().mulDecimal(
                poolMaxValuePerShareD18 -
                    self.poolsDebtDistribution.valuePerShareD27 /
                    DecimalMath.PRECISION_DOWN_SCALE_INT128 // Diff between current value and max value per share.
            );
            self.poolsDebtDistribution.distributeValue(debtToLimitD18);
            actuallyDistributedD18 += debtToLimitD18;

            uint128 poolId = lowestLimitPool.id;

            // Sanity check: The pool should have shares in the market's debt distribution.
            require(self.poolsDebtDistribution.getActorShares(bytes32(uint(poolId))) > 0, "no shares before actor removal");

            // Detach the market from this pool by removing the pool's shares from the market.
            // The pool will remain "detached" until the pool manager specifies a new poolsDebtDistribution.
            uint newPoolDebtD18 = uint(self.poolsDebtDistribution.setActorShares(bytes32(uint(poolId)), 0));
            self.pools[poolId].pendingDebtD18 += newPoolDebtD18.to128();
        }

        self.lastDistributedMarketBalanceD18 += actuallyDistributedD18.to128();

        exhausted = iters == maxIter;
    }

    function bumpPoolsIn(
        Data storage self,
        int maxDistributedD18,
        uint maxIter
    ) internal returns (int actuallyDistributedD18, bool exhausted) {
        if (maxDistributedD18 >= 0 || self.poolsDebtDistribution.totalSharesD18 == 0) {
            return (0, false);
        }

        uint iters;
        for (iters = 0; iters < maxIter; iters++) {
            int targetValuePerShareD18 = self.poolsDebtDistribution.valuePerShareD27 /
                DecimalMath.PRECISION_DOWN_SCALE_INT128 +
                (maxDistributedD18 - actuallyDistributedD18).divDecimal(self.poolsDebtDistribution.totalSharesD18.toInt());

            // Exit if there are no out range pools
            if (self.outRangePools.size() == 0) {
                break;
            }

            // Exit if the lowest max value per share does not hit the limit.
            HeapUtil.Node memory highestLimitPool = self.outRangePools.getMax();

            // highestLimitPool.priority` is actually the max value per share limit of the pool
            if (highestLimitPool.priority < targetValuePerShareD18) {
                break;
            }

            // The pool has hit its maximum value per share and needs to be removed.
            // Update the global distributed and outstanding balances with the debt that was just distributed.
            togglePool(self.outRangePools, self.inRangePools);

            int128 poolMaxValuePerShareD18 = highestLimitPool.priority;

            // Distribute the market's debt to the limit, i.e. for that which exceeds the maximum value per share.
            int debtToLimitD18 = self.poolsDebtDistribution.totalSharesD18.toInt().mulDecimal(
                poolMaxValuePerShareD18 -
                    self.poolsDebtDistribution.valuePerShareD27 /
                    DecimalMath.PRECISION_DOWN_SCALE_INT128 // Diff between current value and max value per share.
            );
            self.poolsDebtDistribution.distributeValue(debtToLimitD18);
            actuallyDistributedD18 += debtToLimitD18;

            uint128 poolId = highestLimitPool.id;

            require(self.poolsDebtDistribution.getActorShares(bytes32(uint(poolId))) == 0, "actor has shares before add");

            // Attach the market from this pool by setting the pool's shares to the value before exiting the market.
            self.poolsDebtDistribution.setActorShares(bytes32(uint(poolId)), self.pools[poolId].liquidityAmountD18);
        }

        self.lastDistributedMarketBalanceD18 += actuallyDistributedD18.to128();

        exhausted = iters == maxIter;
    }

    function togglePool(HeapUtil.Data storage from, HeapUtil.Data storage to) internal {
        HeapUtil.Node memory node = from.extractMax();
        to.insert(node.id, -node.priority);
        // Note: We don't have to update the capacity because pool max share value - valuePerShare = 0, so no change, and conceptually it makes sense because this pools contribution to the capacity should have been used at this point.
    }
}
