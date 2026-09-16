// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.2 <0.9.0;


library EscrowStatus {
    enum Status {
        open,
        ongoing, 
        finished,
        delivered,
        refunded
    }
}

library CalculationUtils {
    function calculatePlatformFee(uint256 _amount, uint256 _platformFee) internal pure returns (uint256) {
        return (_amount * _platformFee) / 100;
    }
}

contract MyToken {
    string public name;
    string public symbol;
    uint public decimal;
    uint public totalSupply;
    address public owner;

    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;


        error NoAddressZero();


    event OwnerShipTransferred(
    address previousOwner,
    address newOwner
    );

        event Transfer(address sender,  address receiver,   uint256 amount );

     constructor(
        string memory _name,
        string memory _symbol,
        uint _decimal
    ) {
        name = _name;
        symbol = _symbol;
        decimal = _decimal;
        owner = msg.sender;

        emit OwnerShipTransferred(address(0), owner);
    }

      function _transfer(
        address from,
        address to,
        uint256 amount,
        bool _mint,
        bool _burn
    ) public {

        if (!_mint) {
            require(
                balances[from] >= amount,
                "Insufficient balance"
            );
        }

        if (!_burn && to == address(0)) {
            revert NoAddressZero();
        }

        balances[to] += amount;

        if (!_mint) {
            balances[from] -= amount;
        }

        emit Transfer(from, to, amount);
    }



    function mint(
        address to,
        uint256 _toSend
    ) public {

        _transfer(
            address(0),
            to,
            _toSend * 1e18,
            true,
            false
        );

        totalSupply += _toSend * 1e18;
    }

     function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {

        _transfer(
            msg.sender,
            to,
            amount,
            false,
            false
        );

        return true;
    }
      function transferFrom(
        address _from,
        address _to,
        uint256 _amount
    ) external returns (bool) {

        require(
            allowances[_from][msg.sender] >= _amount,
            "Not enough allowance"
        );

        allowances[_from][msg.sender] -= _amount;

        _transfer(
            _from,
            _to,
            _amount,
            false,
            false
        );

        return true;
    }

}


interface IMyToken {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

contract Escrows {

    IMyToken public immutable token;

    uint256 public platformFee;
    address public owner;
    uint256 public platformBalance;
    // uint256 public amountToSend;


    struct Escrow {
        uint256 _amount;
        address client_address;
        address recepient_address;
        uint256 expiry_date;
        EscrowStatus.Status status;
    }

      constructor(uint256 _platformFee, address  _token) {
        require(_platformFee <= 10, "Platformfee is already more than 10%");
        platformFee = _platformFee;
        token = IMyToken(_token);
        owner = msg.sender;
    }

    uint256 public nextEscrowId;
    mapping(uint256 => Escrow) public escrows; 
    mapping(address => uint256) public _receipientBalance;

    event EscrowCreated(address _address, address receipient_address, uint256 amount, uint256 expiry_date);
    event EscrowPaid(address _client_address, uint256 amount, uint256 platformoney, uint256 amountPaid, address receipient_address);
    event EscrowRefunded(address client_address, uint256 amount);
    event EscrowTaskStarted(address receipient_address, EscrowStatus.Status _status);
    event EscrowWithdrawal(address receipient_address, uint256 amount);
    event EscrowDelivered(uint256 _escrowId, EscrowStatus.Status _status );

    function createEscrow(uint256 _amount,  address _receipient_address,  uint256 _expiry_date) external  returns (uint256 escrowId) {
        escrowId = nextEscrowId++;
        escrows[escrowId]= Escrow(_amount, msg.sender, _receipient_address, _expiry_date, EscrowStatus.Status.open);
        token.transferFrom(msg.sender, address(this), _amount);
        emit EscrowCreated(msg.sender, _receipient_address, _amount, _expiry_date);
    }

    function startTask(uint256 _escrowId) public {
        Escrow storage escrow = escrows[_escrowId]; 

        require(escrow.status != EscrowStatus.Status.ongoing, "Escrow has been started");
        require(escrow.status != EscrowStatus.Status.finished, "Escrow has been completed");
        require(escrow.status != EscrowStatus.Status.refunded, "Escrow has been refunded");
        require(escrow.expiry_date > block.timestamp , "Escrow has expired");
        require(escrow.recepient_address == msg.sender, "So sorry you were not assigned this task");

        escrow.status = EscrowStatus.Status.ongoing;
        emit EscrowTaskStarted(escrow.recepient_address, escrow.status);
    }

    function markDelivered( uint256 _escrowId ) external { 
        Escrow storage escrow = escrows[_escrowId];
        require(escrow.status == EscrowStatus.Status.ongoing, "The escrow task isn't ongoing");
        require(escrow.recepient_address == msg.sender, "You can't mark it delivered");
       
        escrow.status = EscrowStatus.Status.delivered; 
        emit EscrowDelivered( _escrowId, EscrowStatus.Status.delivered );
      }

    function requestRefund(uint256 _escrowId) public {
        Escrow storage escrow = escrows[_escrowId];

        require(
            escrow.status == EscrowStatus.Status.open ||
            escrow.status == EscrowStatus.Status.ongoing,
            "Escrow cannot be refunded"
        );      
      require(escrow.expiry_date < block.timestamp, "Escrow has not expired yet");
        require(escrow.client_address == msg.sender, "It is not your money na ");

        require (token.transfer(escrow.client_address, escrow._amount), "refund unsuccessful try agin or check your network");
        escrow.status = EscrowStatus.Status.refunded;

       emit EscrowRefunded(escrow.client_address, escrow._amount);
    }

    function approval(uint256 _escrowId) external  {
        Escrow storage escrow = escrows[_escrowId];

        require(escrow.status == EscrowStatus.Status.delivered, "Escrow is not delivered yet");
        require(escrow.client_address == msg.sender, "omo you be thief oo, This is not your escrow please");


        escrow.status = EscrowStatus.Status.finished;
        payRecepient(escrow.recepient_address, escrow._amount, escrow.client_address);
    }

    function withdrawMoney() external {
        uint256 amountToSend = _receipientBalance[msg.sender];

        require(amountToSend > 0, "No balance to withdraw");


        require(
            token.transfer(msg.sender, amountToSend),
            "Unable to disburse out payment"
        );

         _receipientBalance[msg.sender] = 0;


        emit EscrowWithdrawal(msg.sender, amountToSend);
    }

    function payRecepient(address _receipient_address, uint _amount, address client_address) private  {
        uint256 platformMoney = CalculationUtils.calculatePlatformFee(_amount, platformFee);
        uint256 amountToSend = _amount - platformMoney;
        platformBalance +=platformMoney;
        _receipientBalance[_receipient_address] +=amountToSend;

        emit EscrowPaid(client_address, _amount, platformMoney, amountToSend, _receipient_address);
    }

}