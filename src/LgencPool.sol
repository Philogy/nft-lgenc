// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IERC721} from "./interfaces/IERC721.sol";
import {Multicallable} from "./lib/Multicallable.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {ERC721} from "@openzeppelin/token/ERC721/ERC721.sol";
import {Ownable2Step} from "@openzeppelin/access/Ownable2Step.sol";

/// @author philogy <https://github.com/philogy>
contract LgencPool is Multicallable, ERC721, Ownable2Step {
    using SafeTransferLib for address;
    using SafeCastLib for uint;

    uint internal constant ALL = 0x8000000000000000000000000000000000000000000000000000000000000000;

    bool public checkingSolvency;
    uint120 public totalCollateralizedDebt;
    uint120 public totalReserves;

    address public oracle;

    struct PoolData {
        address nftContract;
        uint baseInterest;
        uint maxVarInterest;
        uint maxAmount;
        uint maxLoanLength;
        uint maxLtv;
    }

    struct PoolState {
        bool isActive;
        uint debt;
    }
    mapping(bytes32 => PoolState) public pools;

    error PoolNonexistent();

    struct Loan {
        bytes32 poolId;
        address nftContract;
        uint tokenId;
        uint startTime;
        uint deadline;
        uint interest;
        uint120 debt;
    }

    event LoanCreated(
        uint indexed loanId,
        address indexed nftContract,
        uint indexed tokenId,
        uint debt,
        uint deadline,
        uint interest
    );
    event LoanRepayed(uint indexed loanId, uint interestPaid);
    event LoanLiquidated(uint indexed loanId);
    event OracleSet(address indexed oracle);

    error Insolvent();
    error PriceExpired();
    error NotOracle();
    error TooHighCollateralValue();
    error NotLoanOwner();
    error IncorrectLiquidation();
    error UnexpectedUtilization();

    modifier ensureSolvency() {
        bool callNeedsToCheck = !checkingSolvency;
        if (callNeedsToCheck) checkingSolvency = true;
        _;
        if (callNeedsToCheck) {
            checkingSolvency = false;
            if (address(this).balance + totalCollateralizedDebt < totalReserves) revert Insolvent();
        }
    }

    receive() external payable {}

    constructor(string memory _name, string memory _symbol) ERC721(_name, _symbol) {}

    function checkedMulticall(
        bytes[] calldata _calls
    ) public payable ensureSolvency returns (bytes[] memory) {
        return super.multicall(_calls);
    }

    function deposit() external payable {
        totalReserves = address(this).balance.toUint120() + totalCollateralizedDebt;
    }

    function withdrawTo(address _recipient, uint _amount) external payable onlyOwner {
        if (_amount == ALL) _amount = address(this).balance;

        totalReserves -= _amount.toUint120();
        _recipient.safeTransferETH(_amount);
    }

    function pushFree(address _recipient) external payable {
        uint amount = address(this).balance + totalCollateralizedDebt - totalReserves;
        if (amount == 0) return;
        _recipient.safeTransferETH(amount);
    }

    function setOracle(address _oracle) external payable onlyOwner {
        oracle = _oracle;
        emit OracleSet(_oracle);
    }

    function getPoolId(PoolData calldata _pool) public pure returns (bytes32) {
        return keccak256(abi.encode(_pool));
    }

    function setPool(bytes32 _poolId, bool _active) external payable onlyOwner {
        pools[_poolId].isActive = _active;
    }

    function getLoanId(Loan memory _loan) public pure returns (uint) {
        return uint(keccak256(abi.encode(_loan)));
    }

    function validateOraclePrice(
        uint _price,
        uint _expiry,
        address _nftContract,
        bytes calldata _signature
    ) public view {
        if (block.timestamp > _expiry) revert PriceExpired();
        address signer = ECDSA.recover(
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n111",
                    _price,
                    _expiry,
                    block.chainid,
                    _nftContract
                )
            ),
            _signature
        );
        if (signer != oracle) revert NotOracle();
    }

    struct LoanCreationParams {
        // oracle
        uint maxPrice;
        uint expiry;
        bytes signature;
        // slippage
        uint maxPoolUtilization;
        // borrow
        address recipient;
        uint[] tokenIds;
        uint nftValue;
        bool averageInterest;
    }

    function createLoan(
        PoolData calldata _pool,
        // Fix stack too deep
        LoanCreationParams calldata _params
    ) external payable {
        bytes32 poolId = getPoolId(_pool);
        uint poolDebt = pools[poolId].debt;
        if (!pools[poolId].isActive) revert PoolNonexistent();
        validateOraclePrice(_params.maxPrice, _params.expiry, _pool.nftContract, _params.signature);
        if ((_params.maxPrice * _pool.maxLtv) / 1e18 < _params.nftValue)
            revert TooHighCollateralValue();
        uint totalReservesCached = totalReserves;
        if (_params.maxPoolUtilization * totalReservesCached < poolDebt * 1e18)
            revert UnexpectedUtilization();

        Loan memory loan = Loan({
            poolId: poolId,
            nftContract: _pool.nftContract,
            tokenId: 0,
            startTime: block.timestamp,
            deadline: block.timestamp + _pool.maxLoanLength,
            interest: 0,
            debt: _params.nftValue.toUint120()
        });

        uint totalTokens = _params.tokenIds.length;
        uint totalNewDebt = _params.nftValue * totalTokens;

        if (_params.averageInterest) {
            loan.interest =
                _pool.baseInterest +
                ((poolDebt + totalNewDebt / 2) * _pool.maxVarInterest) /
                totalReservesCached;
            for (uint i; i < totalTokens; ) {
                loan.tokenId = _params.tokenIds[i];
                _createLoan(loan, _params.recipient);
                // prettier-ignore
                unchecked { ++i; }
            }
        } else {
            uint virtualInterest = (poolDebt + _params.nftValue / 2) * _pool.maxVarInterest;
            uint interestStep = _params.nftValue * _pool.maxVarInterest;
            for (uint i; i < totalTokens; ) {
                loan.tokenId = _params.tokenIds[i];
                loan.interest = virtualInterest / totalReservesCached;
                _createLoan(loan, _params.recipient);
                virtualInterest += interestStep;
                // prettier-ignore
                unchecked { ++i; }
            }
        }

        totalCollateralizedDebt += totalNewDebt.toUint120();
        pools[poolId].debt += totalNewDebt;
    }

    function repayLoan(Loan memory _loan, address _recipient) external payable ensureSolvency {
        uint loanId = getLoanId(_loan);
        if (!_isApprovedOrOwner(msg.sender, loanId)) revert NotLoanOwner();
        uint interestPaid = (_loan.debt * (block.timestamp - _loan.startTime) * _loan.interest) /
            1e18;
        totalReserves += interestPaid.toUint120();
        emit LoanRepayed(loanId, interestPaid);
        _closeLoan(loanId, _loan, _recipient);
    }

    // No solvency check required, cannot break invariant
    function doEffectiveAltruism(Loan memory _loan, address _recipient) external payable onlyOwner {
        uint loanId = getLoanId(_loan);
        if (_loan.deadline >= block.timestamp) revert IncorrectLiquidation();
        totalReserves -= _loan.debt;
        emit LoanLiquidated(loanId);
        _closeLoan(loanId, _loan, _recipient);
    }

    function _createLoan(Loan memory _loan, address _recipient) internal {
        uint loanId = getLoanId(_loan);
        _mint(_recipient, loanId);
        emit LoanCreated(
            loanId,
            _loan.nftContract,
            _loan.tokenId,
            _loan.debt,
            _loan.deadline,
            _loan.interest
        );
        IERC721(_loan.nftContract).transferFrom(msg.sender, address(this), _loan.tokenId);
    }

    function _closeLoan(uint _loanId, Loan memory _loan, address _recipient) internal {
        totalCollateralizedDebt -= _loan.debt;
        _burn(_loanId);
        IERC721(_loan.nftContract).transferFrom(address(this), _recipient, _loan.tokenId);
    }
}
