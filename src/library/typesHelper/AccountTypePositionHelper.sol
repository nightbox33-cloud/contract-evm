// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.18;

import "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import "../types/AccountTypes.sol";
import "../Utils.sol";
import "./SafeCastHelper.sol";

/// @title AccountTypePositionHelper library
/// @author Orderly_Rubick
library AccountTypePositionHelper {
    error QtyZero();

    using SafeCastHelper for *;

    int128 constant FUNDING_MOVE_RIGHT_PRECISIONS = 1e17; // 1e17
    int128 constant PRICE_QTY_MOVE_RIGHT_PRECISIONS = 1e10; // 1e10
    int32 constant MARGIN_100PERCENT = 1e4; // 1e4

    /// @notice charge funding fee
    function chargeFundingFee(AccountTypes.PerpPosition storage position, int128 sumUnitaryFundings) internal {
        int128 accruedFeeUnconverted = position.positionQty * (sumUnitaryFundings - position.lastSumUnitaryFundings);
        int128 accruedFee = accruedFeeUnconverted / FUNDING_MOVE_RIGHT_PRECISIONS;
        int128 remainder = accruedFeeUnconverted - (accruedFee * FUNDING_MOVE_RIGHT_PRECISIONS);
        if (remainder > 0) {
            accruedFee += 1;
        }
        position.costPosition += accruedFee;
        position.lastSumUnitaryFundings = sumUnitaryFundings;
    }

    function chargeFundingFee(AccountTypes.IsoPerpPosition storage isoPosition, int128 sumUnitaryFundings) internal {
        int128 accruedFeeUnconverted = isoPosition.positionQty * (sumUnitaryFundings - isoPosition.lastSumUnitaryFundings);
        int128 accruedFee = accruedFeeUnconverted / FUNDING_MOVE_RIGHT_PRECISIONS;
        int128 remainder = accruedFeeUnconverted - (accruedFee * FUNDING_MOVE_RIGHT_PRECISIONS);
        if (remainder > 0) {
            accruedFee += 1;
        }
        isoPosition.costPosition += accruedFee;
        isoPosition.lastSumUnitaryFundings = sumUnitaryFundings;
    }

    /// @notice cal pnl
    function calPnl(AccountTypes.PerpPosition storage position, int128 markPrice) internal view returns (int128) {
        return position.positionQty * markPrice / FUNDING_MOVE_RIGHT_PRECISIONS - position.costPosition;
    }

    /// @notice maintenance margin
    function maintenanceMargin(
        AccountTypes.PerpPosition storage position,
        int128 markPrice,
        int128 baseMaintenanceMargin
    ) internal view returns (int128) {
        return position.positionQty.abs().toInt128() * markPrice * baseMaintenanceMargin
            / (int128(MARGIN_100PERCENT) * PRICE_QTY_MOVE_RIGHT_PRECISIONS);
    }

    /// @notice is full settled
    function isFullSettled(AccountTypes.PerpPosition storage position) internal view returns (bool) {
        return position.positionQty == 0 && position.costPosition == 0;
    }

    /// @notice Check if isolated position is fully settled
    /// @dev For multi-collateral, we only check position fields. Margin cleanup is handled separately.
    /// @param isoPosition The isolated perpetual position
    /// @return bool True if position is fully settled (qty, cost, and specified margin are all zero)
    /// margin should be 0, because of the business logic, margin should be 0 when position is fully settled
    function isFullSettled(AccountTypes.IsoPerpPosition storage isoPosition) internal view returns (bool) {
        return isoPosition.positionQty == 0 && isoPosition.costPosition == 0;
    }

    /// @notice Check if isolated position has no position (ignores margin)
    /// @dev Use this when you only need to check if position is closed, regardless of margin
    function isPositionClosed(AccountTypes.IsoPerpPosition storage isoPosition) internal view returns (bool) {
        return isoPosition.positionQty == 0 && isoPosition.costPosition == 0;
    }

    /// @notice only change averageEntryPrice, openingCost
    /// params:
    ///     qty: decimal is 8
    ///     price: decimal is 8
    ///     liquidationQuoteDiff: decimal is 6
    /// for:
    ///     perp trade: liquidationQuoteDiff should be empty
    ///     liquidation: liquidationQuoteDiff should no be empty
    function calAverageEntryPrice(
        AccountTypes.PerpPosition storage position,
        int128 qty,
        int128 price,
        int128 liquidationQuoteDiff
    ) internal {
        if (qty == 0) {
            return;
        }
        int128 currentHolding = position.positionQty + qty;
        if (currentHolding == 0) {
            position.averageEntryPrice = 0;
            position.openingCost = 0;
            return;
        }
        // precision 16 = 6 + 10
        int128 quoteDiff = liquidationQuoteDiff != 0 ? liquidationQuoteDiff * 1e10 : -qty * price;
        // precision 16 = 8 + 8
        int128 openingCost = position.openingCost * 1e8;
        if (position.positionQty * currentHolding > 0) {
            if (qty * position.positionQty > 0) {
                openingCost += quoteDiff;
            } else {
                int128 v = halfUp24_8_i256(int256(openingCost) * int256(qty), position.positionQty);
                openingCost += v;
            }
        } else {
            openingCost = halfUp24_8_i256(int256(quoteDiff) * int256(currentHolding), qty);
        }
        if (currentHolding > 0) {
            position.averageEntryPrice = halfDown16_8(-openingCost, currentHolding).toUint128();
        } else {
            position.averageEntryPrice = halfUp16_8(-openingCost, currentHolding).toUint128();
        }
        position.openingCost = halfUp16_8(openingCost, 1e8);
    }

    function calAverageEntryPrice(
        AccountTypes.IsoPerpPosition storage isoPosition,
        int128 qty,
        int128 price,
        int128 liquidationQuoteDiff
    ) internal {
        if (qty == 0) {
            return;
        }
        int128 currentHolding = isoPosition.positionQty + qty;
        if (currentHolding == 0) {
            isoPosition.averageEntryPrice = 0;
            isoPosition.openingCost = 0;
            return;
        }
        // precision 16 = 6 + 10
        int128 quoteDiff = liquidationQuoteDiff != 0 ? liquidationQuoteDiff * 1e10 : -qty * price;
        // precision 16 = 8 + 8
        int128 openingCost = isoPosition.openingCost * 1e8;
        if (isoPosition.positionQty * currentHolding > 0) {
            if (qty * isoPosition.positionQty > 0) {
                openingCost += quoteDiff;
            } else {
                int128 v = halfUp24_8_i256(int256(openingCost) * int256(qty), isoPosition.positionQty);
                openingCost += v;
            }
        } else {
            openingCost = halfUp24_8_i256(int256(quoteDiff) * int256(currentHolding), qty);
        }
        if (currentHolding > 0) {
            isoPosition.averageEntryPrice = halfDown16_8(-openingCost, currentHolding).toUint128();
        } else {
            isoPosition.averageEntryPrice = halfUp16_8(-openingCost, currentHolding).toUint128();
        }
        isoPosition.openingCost = halfUp16_8(openingCost, 1e8);
    }

    /// @dev similar to the above function, but with an additional parameter `positionQty` equal to `position.positionQty`
    function calAverageEntryPrice(
        AccountTypes.PerpPosition storage position,
        int128 positionQty,
        int128 qty,
        int128 price,
        int128 liquidationQuoteDiff
    ) internal {
        if (qty == 0) {
            return;
        }
        int128 currentHolding = positionQty + qty;
        if (currentHolding == 0) {
            position.averageEntryPrice = 0;
            position.openingCost = 0;
            return;
        }
        // precision 16 = 6 + 10
        int128 quoteDiff = liquidationQuoteDiff != 0 ? liquidationQuoteDiff * 1e10 : -qty * price;
        // precision 16 = 8 + 8
        int128 openingCost = position.openingCost * 1e8;
        if (positionQty * currentHolding > 0) {
            if (qty * positionQty > 0) {
                openingCost += quoteDiff;
            } else {
                int128 v = halfUp24_8_i256(int256(openingCost) * int256(qty), positionQty);
                openingCost += v;
            }
        } else {
            openingCost = halfUp24_8_i256(int256(quoteDiff) * int256(currentHolding), qty);
        }
        if (currentHolding > 0) {
            position.averageEntryPrice = halfDown16_8(-openingCost, currentHolding).toUint128();
        } else {
            position.averageEntryPrice = halfUp16_8(-openingCost, currentHolding).toUint128();
        }
        position.openingCost = halfUp16_8(openingCost, 1e8);
    }

    function calAverageEntryPrice(
        AccountTypes.IsoPerpPosition storage isoPosition,
        int128 positionQty,
        int128 qty,
        int128 price,
        int128 liquidationQuoteDiff
    ) internal {
        if (qty == 0) {
            return;
        }
        int128 currentHolding = positionQty + qty;
        if (currentHolding == 0) {
            isoPosition.averageEntryPrice = 0;
            isoPosition.openingCost = 0;
            return;
        }
        // precision 16 = 6 + 10
        int128 quoteDiff = liquidationQuoteDiff != 0 ? liquidationQuoteDiff * 1e10 : -qty * price;
        // precision 16 = 8 + 8
        int128 openingCost = isoPosition.openingCost * 1e8;
        if (positionQty * currentHolding > 0) {
            if (qty * positionQty > 0) {
                openingCost += quoteDiff;
            } else {
                int128 v = halfUp24_8_i256(int256(openingCost) * int256(qty), positionQty);
                openingCost += v;
            }
        } else {
            openingCost = halfUp24_8_i256(int256(quoteDiff) * int256(currentHolding), qty);
        }
        if (currentHolding > 0) {
            isoPosition.averageEntryPrice = halfDown16_8(-openingCost, currentHolding).toUint128();
        } else {
            isoPosition.averageEntryPrice = halfUp16_8(-openingCost, currentHolding).toUint128();
        }
        isoPosition.openingCost = halfUp16_8(openingCost, 1e8);
    }

    /// @dev similar to the above function, but with two additional parameters
    /// `positionQty` equal to `position.positionQty`
    /// `openingCostOld` equal to `position.openingCost`
    function calAverageEntryPrice(
        int128 positionQty,
        int128 openingCostOld,
        int128 qty,
        int128 price,
        int128 liquidationQuoteDiff
    ) internal pure returns (uint128 averageEntryPrice, int128 openingCost) {
        if (qty == 0) {
            revert QtyZero();
        }
        int128 currentHolding = positionQty + qty;
        if (currentHolding == 0) {
            averageEntryPrice = 0;
            openingCost = 0;
            return (averageEntryPrice, openingCost);
        }
        // precision 16 = 6 + 10
        int128 quoteDiff = liquidationQuoteDiff != 0 ? liquidationQuoteDiff * 1e10 : -qty * price;
        // precision 16 = 8 + 8
        openingCost = openingCostOld * 1e8;
        if (positionQty * currentHolding > 0) {
            if (qty * positionQty > 0) {
                openingCost += quoteDiff;
            } else {
                int128 v = halfUp24_8_i256(int256(openingCost) * int256(qty), positionQty);
                openingCost += v;
            }
        } else {
            openingCost = halfUp24_8_i256(int256(quoteDiff) * int256(currentHolding), qty);
        }
        if (currentHolding > 0) {
            averageEntryPrice = halfDown16_8(-openingCost, currentHolding).toUint128();
        } else {
            averageEntryPrice = halfUp16_8(-openingCost, currentHolding).toUint128();
        }
        openingCost = halfUp16_8(openingCost, 1e8);
    }

    /// @notice Variant of the value-based `calAverageEntryPrice` that reports an
    ///         out-of-range result instead of reverting on the final cast.
    /// @return success false if the average entry price is out of unsigned range
    /// @return averageEntryPrice the recomputed average entry price (valid only if success)
    /// @return openingCost the recomputed opening cost (valid only if success)
    function tryCalAverageEntryPrice(
        int128 positionQty,
        int128 openingCostOld,
        int128 qty,
        int128 price,
        int128 liquidationQuoteDiff
    ) internal pure returns (bool success, uint128 averageEntryPrice, int128 openingCost) {
        if (qty == 0) {
            revert QtyZero();
        }
        int128 currentHolding = positionQty + qty;
        if (currentHolding == 0) {
            return (true, 0, 0);
        }
        // precision 16 = 6 + 10
        int128 quoteDiff = liquidationQuoteDiff != 0 ? liquidationQuoteDiff * 1e10 : -qty * price;
        // precision 16 = 8 + 8
        openingCost = openingCostOld * 1e8;
        if (positionQty * currentHolding > 0) {
            if (qty * positionQty > 0) {
                openingCost += quoteDiff;
            } else {
                int128 v = halfUp24_8_i256(int256(openingCost) * int256(qty), positionQty);
                openingCost += v;
            }
        } else {
            openingCost = halfUp24_8_i256(int256(quoteDiff) * int256(currentHolding), qty);
        }
        int128 avgSigned =
            currentHolding > 0 ? halfDown16_8(-openingCost, currentHolding) : halfUp16_8(-openingCost, currentHolding);
        if (avgSigned < 0) {
            return (false, 0, 0);
        }
        averageEntryPrice = uint128(avgSigned);
        openingCost = halfUp16_8(openingCost, 1e8);
        success = true;
    }

    /// @notice dividend has move right 24 precisions, divisor move right 8
    function halfUp24_8(int128 dividend, int128 divisor) internal pure returns (int128) {
        // to eliminate effects of dividend extra move right 8 precision in outer
        return halfUp16_8(dividend, divisor * 1e8) * 1e8;
    }

    function halfUp24_8_i256(int256 dividend, int128 divisor) internal pure returns (int128) {
        // to eliminate effects of dividend extra move right 8 precision in outer
        return halfUp16_8_i256(dividend, divisor * 1e8) * 1e8;
    }

    /// @notice HALF UP
    /// Rounding mode to round towards "nearest neighbor"
    /// unless both neighbors are equidistant, in which case round up.
    /// Behaves as for RoundingMode UP if the discarded
    /// fraction is >=0.5;
    /// half up
    /// 5.5 -> 6
    /// 2.5 -> 3
    /// 1.6 -> 2
    /// 1.1 -> 1
    /// 1.0 -> 1
    /// -1.0 -> -1
    /// -1.1 -> -1
    /// -1.6 -> -2
    /// -2.5 -> -3
    /// -5.5 -> -6
    function halfUp16_8(int128 dividend, int128 divisor) internal pure returns (int128) {
        require(divisor != 0, "Division by zero");
        int128 quotient = dividend / divisor;
        int128 remainder = dividend % divisor;
        if (remainder.abs() * 2 >= divisor.abs()) {
            bool positive = (dividend > 0) == (divisor > 0);

            if (positive) {
                quotient += 1;
            } else {
                quotient -= 1;
            }
        }
        return quotient;
    }

    function halfUp16_8_i256(int256 dividend, int128 divisor) internal pure returns (int128) {
        require(divisor != 0, "Division by zero");
        int256 quotient = dividend / divisor;
        int256 remainder = dividend % divisor;

        if (remainder.abs_i256() * 2 >= (divisor).abs()) {
            bool positive = (dividend > 0) == (divisor > 0);

            if (positive) {
                quotient += 1;
            } else {
                quotient -= 1;
            }
        }

        return SafeCast.toInt128(quotient);
    }

    /// @notice HALF DOWN
    /// Rounding mode to round towards "nearest neighbor"
    /// unless both neighbors are equidistant, in which case round
    /// down.  Behaves as for RoundingMode UP if the discarded
    /// fraction is > 0.5;
    /// Example:
    /// 5.5 -> 5
    /// 2.5 -> 2
    /// 1.6 -> 2
    /// 1.1 -> 1
    /// 1.0 -> 1
    /// -1.0 -> -1
    /// -1.1 -> -1
    /// -1.6 -> -2
    /// -2.5 -> -2
    /// -5.5 -> -5
    function halfDown16_8(int128 dividend, int128 divisor) internal pure returns (int128) {
        require(divisor != 0, "Division by zero");
        int128 quotient = dividend / divisor;
        int128 remainder = dividend % divisor;
        if (remainder.abs() * 2 > divisor.abs()) {
            bool positive = (dividend > 0) == (divisor > 0);

            if (positive) {
                quotient += 1;
            } else {
                quotient -= 1;
            }
        }
        return quotient;
    }
}
