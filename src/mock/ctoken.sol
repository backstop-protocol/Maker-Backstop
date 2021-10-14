// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity >=0.6.12;

interface GemLike {
    function approve(address, uint256) external returns(bool);
    function transfer(address, uint256) external returns(bool);
    function transferFrom(address, address, uint256) external returns(bool);
    function balanceOf(address) view external returns(uint);
}

contract CToken {
    GemLike immutable dai;
    bool shouldFail;

    constructor(address _dai) public {
        dai = GemLike(_dai);
    }

    function setFail(bool fail) public {
        shouldFail = fail;
    }

    function mint(uint amount) public returns(uint) {
        if(shouldFail) return 1;

        dai.transferFrom(msg.sender, address(this), amount);

        return 0;
    }

    function redeemUnderlying(uint redeemAmount) public returns(uint) {
        if(shouldFail) return 1;

        dai.transfer(msg.sender, redeemAmount);

        return 0;
    }

    function balanceOfUnderlying(address) public view returns(uint) {
        return dai.balanceOf(address(this));
    }
}
