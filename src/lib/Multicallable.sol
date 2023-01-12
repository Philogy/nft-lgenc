// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/// @author philogy <https://github.com/philogy>
abstract contract Multicallable {
    function multicall(bytes[] calldata _calls) public payable virtual returns (bytes[] memory rets) {
        uint totalCalls = _calls.length;
        rets = new bytes[](totalCalls);
        for (uint i; i < totalCalls; ) {
            (bool success, bytes memory ret) = address(this).delegatecall(_calls[i]);
            assembly {
                if iszero(success) {
                    returndatacopy(0x00, 0x00, returndatasize())
                    revert(0x00, returndatasize())
                }
            }
            rets[i] = ret;

            // prettier-ignore
            unchecked { ++i; }
        }
    }
}
