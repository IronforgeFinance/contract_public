// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "./interfaces/IPlatformToken.sol";
import "./libs/StringHelper.sol";

contract IronForgeToken is ERC20Upgradeable, OwnableUpgradeable, IPlatformToken {
    using SafeMathUpgradeable for uint256;
    using StringHelper for string;

    uint256 public constant MAX_SUPPLY = 10000000000e18;

    uint256 public constant MINT_REWARD_LIMIT = 5000000000e18;

    uint256 public manualMinted;

    function initialize() public initializer {
        ERC20Upgradeable.__ERC20_init("IronForgeToken", "IFT");
        OwnableUpgradeable.__Ownable_init();
        manualMinted = 0;
    }

    function symbol() public view override(IPlatformToken,ERC20Upgradeable) returns (string memory){
        return ERC20Upgradeable.symbol();
    }

    function symbolBytes32() public view override returns (bytes32 result){
        return ERC20Upgradeable.symbol().string2Bytes32();
    }

    function mint(address account, uint256 amount) public onlyOwner {
        require(totalSupply().add(amount) <= MAX_SUPPLY, "IronForgeToken: max supply exceeded!!!");
        _mint(account, amount);
    }

    function manualMint(address account, uint256 amount) public override onlyOwner {
        require(manualMinted.add(amount) <= MINT_REWARD_LIMIT, "IronForgeToken: manual mint limit exceeded");
        manualMinted = manualMinted.add(amount);
        mint(account, amount);
    }

    function burn(address account, uint256 amount) public onlyOwner {
        _burn(account, amount);
    }

    function transfer(address recipient, uint256 amount) public virtual override(ERC20Upgradeable,IERC20Upgradeable) returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override(ERC20Upgradeable,IERC20Upgradeable) returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(
            sender,
            _msgSender(),
            allowance(sender, _msgSender()).sub(amount, "ERC20: transfer amount exceeds allowance")
        );
        return true;
    }
}
