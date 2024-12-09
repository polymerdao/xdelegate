pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {DestinationSettler} from "../src/DestinationSettler.sol";

contract DestinationSettlerTest is Test {
    DestinationSettler public destinationSettler;

    function setUp() public {
        destinationSettler = new DestinationSettler();
    }

    function test_fill() public {
        // TODO
    }
}
