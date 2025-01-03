pragma solidity ^0.8.0;

contract HelloWorld {
    event Hello(string message);

    function hello() external payable{
        emit Hello("Hello, World!");
    }
}
