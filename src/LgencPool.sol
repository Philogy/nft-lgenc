// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IERC721} from "./interfaces/IERC721.sol";

/// @author philogy <https://github.com/philogy>
contract LgencPool {
    bool public checkingSolvency;
    uint public totalCollateral;
    uint public totalReserves;
    address public owner;

    mapping(bytes32 => bool) public poolActive;
    mapping(bytes32 => address) public loanOwner;

    modifier ensureSolvency() {
        bool callNeedsToCheck = !checkingSolvency;
        if (callNeedsToCheck) checkingSolvency = true;
        _;
        if (callNeedsToCheck) {
            checkingSolvency = false;
            require(address(this).balance + totalCollateral >= totalReserves, "Pool: Insolvent");
        }
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Pool: Not Owner");
        _;
    }

    receive() external payable {}

    constructor() {
        owner = msg.sender;
    }

    function multicall(bytes[] calldata _calls) external payable ensureSolvency returns (bytes[] memory rets) {
        uint totalCalls = _calls.length;
        rets = new bytes[](totalCalls);
        for (uint i; i < totalCalls; ++i) {
            (bool success, bytes memory ret) = address(this).delegatecall(_calls[i]);
            require(success);
            rets[i] = ret;
        }
    }

    function deposit(uint _amount) external payable ensureSolvency onlyOwner {
        totalReserves += _amount;
    }

    function withdraw(uint _amount) external payable onlyOwner {
        totalReserves -= _amount;
    }

    function push(address _recipient, uint _amount) external payable ensureSolvency {
        (bool success, ) = _recipient.call{value: _amount}("");
        require(success);
    }

    struct PoolData {
        address nftContract;
        uint interestPerSecond;
        uint maxAmount;
        uint maxLoanLength;
    }

    function getPoolHash(PoolData memory _pool) public pure returns (bytes32) {
        return keccak256(abi.encode(_pool));
    }

    function setPool(bytes32 _poolHash, bool _active) external payable onlyOwner {
        poolActive[_poolHash] = _active;
    }

    struct Loan {
        address nftContract;
        uint tokenId;
        uint startTime;
        uint endTime;
        uint interestPerSecond;
        uint totalBorrowed;
    }

    function getLoanHash(Loan memory _loan) public pure returns (bytes32) {
        return keccak256(abi.encode(_loan));
    }

    function borrow(PoolData memory _pool, uint _tokenId, uint _borrowAmount) external payable ensureSolvency {
        require(poolActive[getPoolHash(_pool)], "Pool: Nonexistent");
        require(_borrowAmount <= _pool.maxAmount, "Pool: Borrow amount exceeds max");
        Loan memory loan = Loan({
            nftContract: _pool.nftContract,
            tokenId: _tokenId,
            startTime: block.timestamp,
            endTime: block.timestamp + _pool.maxLoanLength,
            interestPerSecond: _pool.interestPerSecond,
            totalBorrowed: _borrowAmount
        });
        loanOwner[getLoanHash(loan)] = msg.sender;
        totalCollateral += _borrowAmount;
        IERC721(_pool.nftContract).transferFrom(msg.sender, address(this), _tokenId);
    }

    function repay(Loan memory _loan, address _recipient) external payable ensureSolvency {
        bytes32 loanId = getLoanHash(_loan);
        require(loanOwner[loanId] == msg.sender, "Pool: Not loan owner");
        uint interest = (_loan.totalBorrowed * (block.timestamp - _loan.startTime) * _loan.interestPerSecond) / 1e18;
        totalReserves += interest;
        _closeLoan(loanId, _loan, _recipient);
    }

    // No solvency check required, cannot break invariant
    function liquidate(Loan memory _loan, address _recipient) external payable onlyOwner {
        bytes32 loanId = getLoanHash(_loan);
        require(loanOwner[loanId] != address(0), "Pool: Nonexistent loan");
        require(_loan.endTime < block.timestamp, "Pool: Too early liquidation");
        totalReserves -= _loan.totalBorrowed;
        _closeLoan(loanId, _loan, _recipient);
    }

    function _closeLoan(bytes32 _loanId, Loan memory _loan, address _recipient) internal {
        totalCollateral -= _loan.totalBorrowed;
        delete loanOwner[_loanId];
        IERC721(_loan.nftContract).transferFrom(address(this), _recipient, _loan.tokenId);
    }
}
