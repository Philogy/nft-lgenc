// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/// @author philogy <https://github.com/philogy>
interface ILlamaFlashBorrower {
    function llamaFlashBorrowETH(
        address _caller,
        bytes memory _data
    ) external payable returns (bytes32);
}
