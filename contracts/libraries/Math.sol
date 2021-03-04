// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;
import {Liquifi} from "./Liquifi.sol";

library Math {
    function max(uint256 x, uint256 y) internal pure returns (uint256 result) {
        result = x > y ? x : y;
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256 result) {
        result = x < y ? x : y;
    }

    function sqrt(uint256 x) internal pure returns (uint256 result) {
        uint256 y = x;
        result = (x + 1) / 2;
        while (result < y) {
            y = result;
            result = (x / result + result) / 2;
        }
    }

    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        Liquifi._require(y == 0 || (z = x * y) / y == x, Liquifi.Error.A_MUL_OVERFLOW, Liquifi.ErrorArg.A_NONE);
    }

    function mulWithClip(
        uint256 x,
        uint256 y,
        uint256 maxValue
    ) internal pure returns (uint256 z) {
        if (y != 0 && ((z = x * y) / y != x || z > maxValue)) {
            z = maxValue;
        }
    }

    function subWithClip(uint256 x, uint256 y) internal pure returns (uint256 z) {
        if ((z = x - y) > x) {
            return 0;
        }
    }

    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        Liquifi._require((z = x + y) >= x, Liquifi.Error.B_ADD_OVERFLOW, Liquifi.ErrorArg.A_NONE);
    }

    function addWithClip(
        uint256 x,
        uint256 y,
        uint256 maxValue
    ) internal pure returns (uint256 z) {
        if ((z = x + y) < x || z > maxValue) {
            z = maxValue;
        }
    }

    // function div(uint x, uint y, Liquifi.ErrorArg scope) internal pure returns (uint z) {
    //     Liquifi._require(y != 0, Liquifi.Error.R_DIV_BY_ZERO, scope);
    //     z = x / y;
    // }
}
