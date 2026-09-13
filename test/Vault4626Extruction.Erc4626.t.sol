// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vault4626Extruction} from "../src/Vault4626Extruction.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockERC4626} from "../src/mocks/MockERC4626.sol";
import {AquiferTestBase} from "./helpers/AquiferTestBase.sol";

/// @notice Integration coverage against a real OpenZeppelin ERC-4626 implementation, including the
///         donation-driven rate manipulation the bounds are supposed to stop.
contract Vault4626ExtructionErc4626Test is AquiferTestBase {
    MockERC20 internal asset6;
    MockERC4626 internal vault;

    address internal depositor = makeAddr("depositor");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant SEED_ASSETS = 1_000_000e6;

    function setUp() public override {
        super.setUp();
        asset6 = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockERC4626(IERC20(address(asset6)), 0);

        asset6.mint(depositor, SEED_ASSETS);
        vm.startPrank(depositor);
        asset6.approve(address(vault), SEED_ASSETS);
        vault.deposit(SEED_ASSETS, depositor);
        vm.stopPrank();
    }

    function _cfg(
        uint16 spreadBps,
        uint256 minRate,
        uint256 maxRate
    ) internal view returns (bytes memory) {
        return config(address(vault), spreadBps, minRate, maxRate);
    }

    /*//////////////////////////////////////////////////////////////
                               BASELINE
    //////////////////////////////////////////////////////////////*/

    function test_realVault_decimalsAndRate() public view {
        assertEq(vault.decimals(), 6, "zero decimals offset means shares mirror the asset");
        (uint256 rate, uint256 shareUnit, address asset) = ext.currentRate(address(vault));
        assertEq(shareUnit, 1e6);
        assertEq(rate, 1e6, "a freshly seeded 1:1 vault quotes one asset unit per share");
        assertEq(asset, address(asset6));
    }

    // rate = 1e6, shareUnit = 1e6, spread = 15bps.
    // exact-in 100e6 shares: fair = 100e6; out = floor(100e6 * 9_985 / 10_000) = 99_850_000
    function test_realVault_exactInSharesToAssets() public view {
        (, uint256 amountOut) =
            priceCurrent(address(vault), address(asset6), true, true, 100e6, 15, 900_000, 1_100_000, type(uint256).max);
        assertEq(amountOut, 99_850_000);
    }

    function test_realVault_exactInAssetsToShares() public view {
        (, uint256 amountOut) =
            priceCurrent(address(vault), address(asset6), false, true, 100e6, 15, 900_000, 1_100_000, type(uint256).max);
        assertEq(amountOut, 99_850_000);
    }

    /*//////////////////////////////////////////////////////////////
                       YIELD ACCRUAL WITHIN BOUNDS
    //////////////////////////////////////////////////////////////*/

    /// @dev A 2% yield accrual stays inside the band and must raise the assets paid per share.
    function test_realVault_yieldAccrualInsideBandRepricesUpward() public {
        (, uint256 beforeOut) =
            priceCurrent(address(vault), address(asset6), true, true, 100e6, 15, 900_000, 1_100_000, type(uint256).max);

        asset6.mint(address(vault), SEED_ASSETS * 2 / 100);
        (uint256 rate,,) = ext.currentRate(address(vault));
        assertApproxEqAbs(rate, 1_020_000, 1, "2% accrual moves the rate to ~1.02");

        (, uint256 afterOut) =
            priceCurrent(address(vault), address(asset6), true, true, 100e6, 15, 900_000, 1_100_000, type(uint256).max);
        assertGt(afterOut, beforeOut, "shares must fetch more assets after accrual");
        // OpenZeppelin's virtual assets make the exact rate 1_019_999 here.
        // fair = 101_999_900; out = floor(fair * 9_985 / 10_000) = 101_846_900.
        assertEq(afterOut, 101_846_900);
    }

    /// @dev The reverse leg must get *worse* for the taker after accrual: assets buy fewer shares.
    function test_realVault_yieldAccrualMakesSharesMoreExpensive() public {
        (, uint256 beforeOut) =
            priceCurrent(address(vault), address(asset6), false, true, 100e6, 15, 900_000, 1_100_000, type(uint256).max);
        asset6.mint(address(vault), SEED_ASSETS * 2 / 100);
        (, uint256 afterOut) =
            priceCurrent(address(vault), address(asset6), false, true, 100e6, 15, 900_000, 1_100_000, type(uint256).max);
        assertLt(afterOut, beforeOut, "100 assets must buy fewer shares once shares are worth more");
    }

    /*//////////////////////////////////////////////////////////////
                            DONATION ATTACK
    //////////////////////////////////////////////////////////////*/

    /// @dev The headline guard: an attacker donating assets straight to the vault inflates
    ///      convertToAssets and would otherwise let them drain the maker's asset balance at a
    ///      manipulated rate. maxRate must shut the strategy instead.
    function test_donationAttack_pushesRateAboveMaxAndBlocksTheQuote() public {
        (uint256 rateBefore,,) = ext.currentRate(address(vault));
        assertEq(rateBefore, 1e6);

        asset6.mint(attacker, SEED_ASSETS);
        vm.prank(attacker);
        asset6.transfer(address(vault), SEED_ASSETS / 2);

        (uint256 rateAfter,,) = ext.currentRate(address(vault));
        assertApproxEqAbs(rateAfter, 1_500_000, 1, "a 50% donation inflates the rate by 50%");

        vm.expectRevert(
            abi.encodeWithSelector(Vault4626Extruction.RateOutOfBounds.selector, rateAfter, 900_000, 1_100_000)
        );
        quoteCurrent(
            query(address(vault), address(asset6), true),
            registers(true, 100e6, type(uint256).max, type(uint256).max),
            _cfg(15, 900_000, 1_100_000)
        );
    }

    /// @dev Both directions and both exact modes must be blocked, not only the profitable one.
    function test_donationAttack_blocksEveryLegAndMode() public {
        asset6.mint(attacker, SEED_ASSETS);
        vm.prank(attacker);
        asset6.transfer(address(vault), SEED_ASSETS / 2);
        (uint256 rateAfter,,) = ext.currentRate(address(vault));

        for (uint256 i = 0; i < 4; ++i) {
            bool sharesIn = i % 2 == 0;
            bool isExactIn = i < 2;
            (address tokenIn, address tokenOut) =
                sharesIn ? (address(vault), address(asset6)) : (address(asset6), address(vault));

            vm.expectRevert(
                abi.encodeWithSelector(Vault4626Extruction.RateOutOfBounds.selector, rateAfter, 900_000, 1_100_000)
            );
            quoteCurrent(
                query(tokenIn, tokenOut, isExactIn),
                registers(isExactIn, 100e6, type(uint256).max, type(uint256).max),
                _cfg(15, 900_000, 1_100_000)
            );
        }
    }

    /// @dev A donation small enough to stay inside the band is *not* blocked. This is the residual
    ///      exposure the bounds intentionally accept, bounded by maxRate.
    function test_donationAttack_withinBandIsStillHonoured() public {
        asset6.mint(attacker, SEED_ASSETS);
        vm.prank(attacker);
        asset6.transfer(address(vault), SEED_ASSETS * 5 / 100);

        (uint256 rateAfter,,) = ext.currentRate(address(vault));
        assertApproxEqAbs(rateAfter, 1_050_000, 1);

        (, uint256 amountOut) =
            priceCurrent(address(vault), address(asset6), true, true, 100e6, 15, 900_000, 1_100_000, type(uint256).max);
        // OpenZeppelin's virtual assets make the exact rate 1_049_999 here.
        // fair = 104_999_900; out = floor(fair * 9_985 / 10_000) = 104_842_400.
        assertEq(amountOut, 104_842_400);
    }

    /*//////////////////////////////////////////////////////////////
                          DECIMALS OFFSET VAULTS
    //////////////////////////////////////////////////////////////*/

    /// @dev The inflation-attack-resistant configuration (6-decimal asset, 12-offset, 18-decimal share).
    function test_realVault_decimalsOffset12() public {
        MockERC4626 offset = new MockERC4626(IERC20(address(asset6)), 12);
        assertEq(offset.decimals(), 18);

        asset6.mint(depositor, SEED_ASSETS);
        vm.startPrank(depositor);
        asset6.approve(address(offset), SEED_ASSETS);
        offset.deposit(SEED_ASSETS, depositor);
        vm.stopPrank();

        (uint256 rate, uint256 shareUnit, address asset) = ext.currentRate(address(offset));
        assertEq(shareUnit, 1e18);
        assertEq(asset, address(asset6));
        assertApproxEqAbs(rate, 1e6, 1, "a virtual-offset vault still quotes ~1 asset unit per whole share");

        // exact-in one whole share at spread 0 returns the rate itself.
        (, uint256 amountOut) =
            priceCurrent(address(offset), address(asset6), true, true, 1e18, 0, 1, type(uint256).max, type(uint256).max);
        assertEq(amountOut, rate);
    }

    /// @dev An 18-decimal asset with an 18-decimal share is the wstETH-shaped case.
    function test_realVault_asset18Share18() public {
        MockERC20 asset18 = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC4626 v = new MockERC4626(IERC20(address(asset18)), 0);
        asset18.mint(depositor, 1_000e18);
        vm.startPrank(depositor);
        asset18.approve(address(v), 1_000e18);
        v.deposit(1_000e18, depositor);
        vm.stopPrank();

        asset18.mint(address(v), 100e18);
        (uint256 rate, uint256 shareUnit,) = ext.currentRate(address(v));
        assertEq(shareUnit, 1e18);
        assertApproxEqAbs(rate, 1.1e18, 1);

        (, uint256 amountOut) =
            priceCurrent(address(v), address(asset18), true, true, 1e18, 30, 1e18, 1.2e18, type(uint256).max);
        // fair = rate; out = floor(rate * 9_970 / 10_000)
        assertEq(amountOut, rate * 9_970 / 10_000);
    }

    /*//////////////////////////////////////////////////////////////
                            EMPTY / BROKEN VAULT
    //////////////////////////////////////////////////////////////*/

    /// @dev An empty OZ vault reports a virtual 1:1 rate, so it is quotable rather than rejected.
    function test_realVault_emptyVaultQuotesVirtualRate() public {
        MockERC4626 empty = new MockERC4626(IERC20(address(asset6)), 0);
        (uint256 rate, uint256 shareUnit,) = ext.currentRate(address(empty));
        assertEq(shareUnit, 1e6);
        assertEq(rate, 1e6);
    }

    /// @dev A total-loss vault (shares outstanding, no assets) rounds the rate to zero and must be rejected.
    function test_realVault_totalLossRevertsZeroVaultRate() public {
        // Burn the vault's entire asset balance out from under the outstanding shares.
        vm.prank(address(vault));
        asset6.transfer(address(0xdead), SEED_ASSETS);
        assertEq(asset6.balanceOf(address(vault)), 0);

        vm.expectRevert(abi.encodeWithSelector(Vault4626Extruction.ZeroVaultRate.selector, address(vault)));
        ext.currentRate(address(vault));
    }
}
