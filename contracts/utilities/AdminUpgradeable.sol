// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12 <=0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";

/**
 * @title AdminUpgradeable
 *
 * @dev This is an upgradeable version of `Admin` by replacing the constructor with
 * an initializer and reserving storage slots.
 */
contract AdminUpgradeable is Initializable {
    event CandidateChanged(address oldCandidate, address newCandidate);
    event AdminChanged(address oldAdmin, address newAdmin);

    address public admin;
    address public candidate;

    function __AdminUpgradeable_init(address _admin) public virtual initializer {
        require(_admin != address(0), "AdminUpgradeable: zero address");
        admin = _admin;
        emit AdminChanged(address(0), _admin);
    }

    function setCandidate(address _candidate) external onlyAdmin {
        address old = candidate;
        candidate = _candidate;
        emit CandidateChanged(old, candidate);
    }

    function becomeAdmin() external {
        require(msg.sender == candidate, "AdminUpgradeable: only candidate can become admin");
        address old = admin;
        admin = candidate;
        emit AdminChanged(old, admin);
    }

    modifier onlyAdmin {
        require((msg.sender == admin), "AdminUpgradeable: only the contract admin can perform this action");
        _;
    }

    // Reserved storage space to allow for layout changes in the future.
    uint256[48] private __gap;
}
