// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ERC721} from "@openzeppelin/token/ERC721/ERC721.sol";

/// @author philogy <https://github.com/philogy>
contract MockERC721 is ERC721("Mock", "MCK") {
    function mint(address _recipient, uint _tokenId) external {
        _mint(_recipient, _tokenId);
    }
}
