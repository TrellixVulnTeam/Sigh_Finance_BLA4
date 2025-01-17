pragma solidity ^0.5.0;


import "./MintableERC20.sol";


contract MockAAVE is MintableERC20 {

    uint256 minBlockGap = 6500;
    mapping(address => uint256) private mintHistory;
    
    function mint(uint256 value) public returns (bool) {
        require(value < 1000000 * 10**decimals,"Maximum 1000000 Tokens can minted.");
        uint deltaBlocks = block.number - mintHistory[msg.sender];
        require(minBlockGap < deltaBlocks,"6500 Blocks need to be passed before tokens can be minted again by the same user");  
        mintHistory[msg.sender] = block.number;
        _mint(msg.sender, value);
        return true;
    }


    uint256 public decimals = 18;
    string public symbol = "AAVE";
    string public name = "AAVE";
}