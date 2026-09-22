// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../../src/library/typesHelper/AccountTypePositionHelper.sol";

/// @title Unit tests for tryCalAverageEntryPrice
/// @notice Verifies the reporting variant behaves identically to the reverting
///         overload for normal inputs, reports success=false when the result is
///         out of unsigned range, and still reverts on invalid (qty == 0) input.
contract CalAvgSkipTest is Test {
    using AccountTypePositionHelper for *;

    /// @dev Uses a position whose stored opening cost sign does not match the
    ///      resulting position direction, so the recomputed average entry price
    ///      is out of unsigned range. The reporting variant should return
    ///      success=false rather than revert.
    function test_tryCalAvg_returnsFalse_whenResultOutOfRange() public {
        int128 positionQty = -329700000;
        int128 openingCostOld = -30976563000;
        int128 tradeQty = -76000000;
        int128 price = 21854000000;

        (bool ok,,) = AccountTypePositionHelper.tryCalAverageEntryPrice(positionQty, openingCostOld, tradeQty, price, 0);

        assertEq(ok, false, "out-of-range result should report ok=false");
    }

    /// @dev The reverting overload must still revert on the same input, so
    ///      accounts not in the skip list keep the standard behaviour. Routed
    ///      through an external harness so vm.expectRevert can catch the revert
    ///      from the internal library call.
    function test_calAvg_stillReverts_onSameInput() public {
        CalAvgHarness h = new CalAvgHarness();
        vm.expectRevert();
        h.callReverting(-329700000, -30976563000, -76000000, 21854000000);
    }

    /// @dev qty == 0 is invalid input and must still revert in the reporting
    ///      variant, matching the original behaviour.
    function test_tryCalAvg_revertsOnZeroQty() public {
        CalAvgHarness h = new CalAvgHarness();
        vm.expectRevert();
        h.callTry(100000000, 0, 0, 20000000000);
    }

    /// @dev For a normal input the two variants must agree exactly.
    function test_tryCalAvg_matchesRevertingVariant_onNormalInput() public {
        int128 positionQty = 0;
        int128 openingCostOld = 0;
        int128 tradeQty = 100000000;
        int128 price = 20000000000;

        (bool ok, uint128 avgT, int128 ocT) =
            AccountTypePositionHelper.tryCalAverageEntryPrice(positionQty, openingCostOld, tradeQty, price, 0);
        (uint128 avgR, int128 ocR) =
            AccountTypePositionHelper.calAverageEntryPrice(positionQty, openingCostOld, tradeQty, price, 0);

        assertEq(ok, true, "normal input should succeed");
        assertEq(avgT, avgR, "averageEntryPrice must match reverting variant");
        assertEq(ocT, ocR, "openingCost must match reverting variant");
    }
}

/// @dev External harness so vm.expectRevert can catch reverts from the internal
///      library functions (internal calls don't create a catchable sub-frame).
contract CalAvgHarness {
    function callReverting(int128 positionQty, int128 openingCostOld, int128 qty, int128 price)
        external
        pure
        returns (uint128 avg, int128 oc)
    {
        return AccountTypePositionHelper.calAverageEntryPrice(positionQty, openingCostOld, qty, price, 0);
    }

    function callTry(int128 positionQty, int128 openingCostOld, int128 qty, int128 price)
        external
        pure
        returns (bool ok, uint128 avg, int128 oc)
    {
        return AccountTypePositionHelper.tryCalAverageEntryPrice(positionQty, openingCostOld, qty, price, 0);
    }
}
