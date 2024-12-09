pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {OriginSettler} from "../src/OriginSettler.sol";

contract OriginSettlerTest is Test {
    OriginSettler public originSettler;

    function setUp() public {
        originSettler = new OriginSettler();
    }

    function test_openFor() public {
        // TODO test gas-less Permit2 path
    }
}
