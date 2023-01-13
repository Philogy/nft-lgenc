// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IERC721} from "./interfaces/IERC721.sol";
import {Multicallable} from "./lib/Multicallable.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {ERC721} from "@openzeppelin/token/ERC721/ERC721.sol";
import {Ownable2Step} from "@openzeppelin/access/Ownable2Step.sol";
import {ILlamaFlashBorrower} from "./interfaces/ILlamaFlashBorrower.sol";

/// @author philogy <https://github.com/philogy>
contract LgencPool is Multicallable, ERC721, Ownable2Step {
    using SafeTransferLib for address;
    using SafeCastLib for uint;

    /// @dev Not 0xfff..ffff to save gas, calldata zero bytes cost 4 gas vs 16 gas for non-zero bytes
    uint internal constant ALL = 0x8000000000000000000000000000000000000000000000000000000000000000;
    /// @dev `keccak256("LLAMA_BORROW_MAGIC") - 1`
    bytes32 internal constant LLAMA_FLASH_BORROW_MAGIC =
        0xb996126305cd04eaa8c492853f591f60a10bedcefe5665f4080d2bc210e73045;

    bool public checkingSolvency;
    uint120 public totalCollateralizedDebt;
    uint120 public totalReserves;

    address public oracle;

    struct PoolData {
        address nftContract;
        uint baseInterest;
        uint maxVarInterest;
        uint maxLoanLength;
        uint maxLtv;
    }

    struct PoolState {
        bool isActive;
        uint120 debt;
        uint120 maxValue;
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
    event PoolConfigured(bytes32 indexed poolId, bool indexed activated, uint120 maxValue);

    error Insolvent();
    error PriceExpired();
    error NotOracle();
    error TooHighCollateralValue();
    error TokenValueExceedsPoolMax();
    error NotLoanOwner();
    error IncorrectLiquidation();
    error InterestSlippage();
    error IncorrectBorrowMagic();

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
        uint120 reserves = totalReserves;
        uint120 collateralizedDebt = totalCollateralizedDebt;
        uint120 maxReserves = address(this).balance.toUint120() + collateralizedDebt;
        if (maxReserves < reserves) revert Insolvent();
        totalReserves = maxReserves;
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

    function borrowETH(
        address _recipient,
        uint _amount,
        bytes memory _data
    ) external payable ensureSolvency {
        bytes32 ret = ILlamaFlashBorrower(_recipient).llamaFlashBorrowETH{value: _amount}(
            msg.sender,
            _data
        );

        if (ret != LLAMA_FLASH_BORROW_MAGIC) revert IncorrectBorrowMagic();
    }

    function setOracle(address _oracle) external payable onlyOwner {
        oracle = _oracle;
        emit OracleSet(_oracle);
    }

    function getPoolId(PoolData calldata _pool) public pure returns (bytes32) {
        return keccak256(abi.encode(_pool));
    }

    function configurePool(
        bytes32 _poolId,
        bool _active,
        uint120 _maxValue
    ) external payable onlyOwner {
        pools[_poolId].isActive = _active;
        pools[_poolId].maxValue = _maxValue;
        emit PoolConfigured(_poolId, _active, _maxValue);
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
        uint maxInterest;
        // borrow
        address recipient;
        uint[] tokenIds;
        uint nftValue;
    }

    function createLoan(
        PoolData calldata _pool,
        // Fixes stack too deep
        LoanCreationParams calldata _params
    ) external payable {
        // Load and validate pool.
        bytes32 poolId = getPoolId(_pool);
        PoolState memory poolState = pools[poolId];
        if (!poolState.isActive) revert PoolNonexistent();

        // Validate loan value and oracle price.
        if (_params.nftValue > poolState.maxValue) revert TokenValueExceedsPoolMax();
        validateOraclePrice(_params.maxPrice, _params.expiry, _pool.nftContract, _params.signature);
        if ((_params.maxPrice * _pool.maxLtv) / 1e18 < _params.nftValue)
            revert TooHighCollateralValue();

        // Calculate and check interest for slippage.
        uint totalReservesCached = totalReserves;
        uint totalTokens = _params.tokenIds.length;
        uint totalNewDebt = _params.nftValue * totalTokens;
        uint loanInterest = _pool.baseInterest +
            ((poolState.debt + totalNewDebt / 2) * _pool.maxVarInterest) /
            totalReservesCached;
        if (_params.maxInterest < loanInterest) revert InterestSlippage();

        Loan memory loan = Loan({
            poolId: poolId,
            nftContract: _pool.nftContract,
            tokenId: 0,
            startTime: block.timestamp,
            deadline: block.timestamp + _pool.maxLoanLength,
            interest: loanInterest,
            debt: _params.nftValue.toUint120()
        });

        for (uint i; i < totalTokens; ) {
            loan.tokenId = _params.tokenIds[i];
            _createLoan(loan, _params.recipient);
            // prettier-ignore
            unchecked { ++i; }
        }

        totalCollateralizedDebt += totalNewDebt.toUint120();
        pools[poolId].debt += totalNewDebt.toUint120();
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
        pools[_loan.poolId].debt -= _loan.debt;
        _burn(_loanId);
        IERC721(_loan.nftContract).transferFrom(address(this), _recipient, _loan.tokenId);
    }
}
