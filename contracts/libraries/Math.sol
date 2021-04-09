// SPDX-License-Identifier: GPL-3.0
pragma solidity = 0.7.6;
import { Liquifi } from "./Liquifi.sol";

library Math {
    
    function max(uint256 x, uint256 y) internal pure returns (uint256 result) {
        result = x > y ? x : y;
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256 result) {
        result = x < y ? x : y;
    }

    function sqrt(uint x) internal pure returns (uint result) {
        uint y = x;
        result = (x + 1) / 2;
        while (result < y) {
            y = result;
            result = (x / result + result) / 2;
        }
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        Liquifi._require(y == 0 || (z = x * y) / y == x, Liquifi.Error.A_MUL_OVERFLOW, Liquifi.ErrorArg.A_NONE);
    }

    function mulWithClip(uint x, uint y, uint maxValue) internal pure returns (uint z) {
        if (y != 0 && ((z = x * y) / y != x || z > maxValue)) {
            z = maxValue;
        }
    }

    function subWithClip(uint x, uint y) internal pure returns (uint z) {
        if ((z = x - y) > x) {
            return 0;
        }
    }

    function add(uint x, uint y) internal pure returns (uint z) {
        Liquifi._require((z = x + y) >= x, Liquifi.Error.B_ADD_OVERFLOW, Liquifi.ErrorArg.A_NONE);
    }

    function addWithClip(uint x, uint y, uint maxValue) internal pure returns (uint z) {
        if ((z = x + y) < x || z > maxValue) {
            z = maxValue;
        }
    }

    // function div(uint x, uint y, Liquifi.ErrorArg scope) internal pure returns (uint z) {
    //     Liquifi._require(y != 0, Liquifi.Error.R_DIV_BY_ZERO, scope);
    //     z = x / y;
    // }
}