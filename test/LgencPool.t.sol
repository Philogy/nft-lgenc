// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {MockERC721} from "./mock/MockERC721.sol";
import {LgencPool} from "../src/LgencPool.sol";

/// @author philogy <https://github.com/philogy>
contract LgencPoolTest is Test {
    address owner = vm.addr(0x1000000);
    uint oraclePrivKey = 0x2000000;
    address oracle = vm.addr(oraclePrivKey);

    address user1 = vm.addr(0x1);
    address user2 = vm.addr(0x2);
    address user3 = vm.addr(0x3);

    LgencPool pool;

    function setUp() public {
        vm.prank(owner);
        pool = new LgencPool("LLama V3 Pool", "LOAN");
        vm.prank(owner);
        pool.setOracle(oracle);
    }

    event OracleSet(address indexed oracle);

    function testSetOracle_fuzzing(address _oracle) public {
        vm.expectEmit(true, true, true, true);
        emit OracleSet(_oracle);
        vm.prank(owner);
        pool.setOracle(_oracle);
    }

    function testSendETH() public {
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        payable(pool).transfer(1 ether);
    }

    function testTransferFree() public {
        vm.deal(address(pool), 1 ether);
        uint balBefore = user1.balance;
        pool.pushFree(user1);
        assertEq(user1.balance - balBefore, 1 ether);
    }

    function testDeposit() public {
        uint x = 1.83 ether;
        vm.deal(owner, x);
        vm.prank(owner);
        pool.deposit{value: x}();
        assertEq(address(pool).balance, x);
        assertEq(pool.totalReserves(), x);

        uint balBefore = user1.balance;
        pool.pushFree(user1);
        assertEq(user1.balance, balBefore);
    }

    function testActivatePool() public {
        LgencPool.PoolData memory poolData = LgencPool.PoolData({
            nftContract: address(0),
            baseRate: uint(0.30e18) / uint(365 days),
            maxVarRate: uint(1.5e18) / (365 days),
            maxLoanLength: 14 days,
            maxLtv: 0.5e18
        });
        bytes32 poolId = pool.getPoolId(poolData);
        vm.prank(owner);
        pool.configurePool(poolId, true, 2 ether);
    }
}
