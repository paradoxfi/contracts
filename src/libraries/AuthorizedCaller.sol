// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Context} from "@openzeppelin/contracts/utils/Context.sol";

abstract contract AuthorizedCaller is Context {
    address private _authorizedCaller;

    error NotAuthorized();

    event AuthorizedCallerSet(address indexed previous, address indexed next);

    constructor(address caller) {
        _authorizedCaller = caller;
    }

    modifier onlyAuthorized() {
        if (_msgSender() != _authorizedCaller) {
            revert NotAuthorized();
        }
        _;
    }

    function _setAuthorizedCaller(address caller) internal {
        address prev = _authorizedCaller;
        _authorizedCaller = caller;
        emit AuthorizedCallerSet(prev, caller);
    }

    function authorizedCaller() public view virtual returns (address) {
        return _authorizedCaller;
    }
}
