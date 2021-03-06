pragma solidity ^0.4.24;
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "../Events/Event.sol";

contract MarketMaker is Ownable {
    using SafeMath for *;
    
    /*
     *  Constants
     */    
    uint64 public constant FEE_RANGE = 10**18;

    /*
     *  Events
     */
    event AutomatedMarketMakerFunding(uint funding);
    event AutomatedMarketMakerClosing();
    event FeeWithdrawal(uint fees);
    event OutcomeTokenTrade(address indexed transactor, int[] outcomeTokenAmounts, int outcomeTokenNetCost, uint marketFees);
    
    /*
     *  Storage
     */
    Event public eventContract;
    uint64 public fee;
    uint public funding;
    int[] public netOutcomeTokensSold;
    Stages public stage;
    enum Stages {
        MarketCreated,
        MarketFunded,
        MarketClosed
    }

    /*
     *  Modifiers
     */
    modifier atStage(Stages _stage) {
        // Contract has to be in given stage
        require(stage == _stage);
        _;
    }

    constructor(Event _eventContract, uint64 _fee)
        public
    {
        // Validate inputs
        require(address(_eventContract) != 0 && _fee < FEE_RANGE);
        eventContract = _eventContract;
        netOutcomeTokensSold = new int[](eventContract.getOutcomeCount());
        fee = _fee;
        stage = Stages.MarketCreated;
    }

    function calcNetCost(int[] outcomeTokenAmounts) public view returns (int netCost);

    /// @dev Allows to fund the market with collateral tokens converting them into outcome tokens
    /// @param _funding Funding amount
    function fund(uint _funding)
        public
        onlyOwner
        atStage(Stages.MarketCreated)
    {
        // Request collateral tokens and allow event contract to transfer them to buy all outcomes
        require(   eventContract.collateralToken().transferFrom(msg.sender, this, _funding)
                && eventContract.collateralToken().approve(eventContract, _funding));
        eventContract.buyAllOutcomes(_funding);
        funding = _funding;
        stage = Stages.MarketFunded;
        emit AutomatedMarketMakerFunding(funding);
    }

    /// @dev Allows market owner to close the markets by transferring all remaining outcome tokens to the owner
    function close()
        public
        onlyOwner
        atStage(Stages.MarketFunded)
    {
        uint8 outcomeCount = eventContract.getOutcomeCount();
        for (uint8 i = 0; i < outcomeCount; i++)
            require(eventContract.outcomeTokens(i).transfer(owner, eventContract.outcomeTokens(i).balanceOf(this)));
        stage = Stages.MarketClosed;
        emit AutomatedMarketMakerClosing();
    }

    /// @dev Allows market owner to withdraw fees generated by trades
    /// @return Fee amount
    function withdrawFees()
        public
        onlyOwner
        returns (uint fees)
    {
        fees = eventContract.collateralToken().balanceOf(this);
        // Transfer fees
        require(eventContract.collateralToken().transfer(owner, fees));
        emit FeeWithdrawal(fees);
    }

    /// @dev Allows to trade outcome tokens and collateral with the market maker
    /// @param outcomeTokenAmounts Amounts of each outcome token to buy or sell. If positive, will buy this amount of outcome token from the market. If negative, will sell this amount back to the market instead.
    /// @param collateralLimit If positive, this is the limit for the amount of collateral tokens which will be sent to the market to conduct the trade. If negative, this is the minimum amount of collateral tokens which will be received from the market for the trade. If zero, there is no limit.
    /// @return If positive, the amount of collateral sent to the market. If negative, the amount of collateral received from the market. If zero, no collateral was sent or received.
    function trade(int[] outcomeTokenAmounts, int collateralLimit)
        public
        atStage(Stages.MarketFunded)
        returns (int netCost)
    {
        uint8 outcomeCount = eventContract.getOutcomeCount();
        require(outcomeTokenAmounts.length == outcomeCount);

        // Calculate net cost for executing trade
        int outcomeTokenNetCost = calcNetCost(outcomeTokenAmounts);
        int fees;
        if(outcomeTokenNetCost < 0)
            fees = int(calcMarketFee(uint(-outcomeTokenNetCost)));
        else
            fees = int(calcMarketFee(uint(outcomeTokenNetCost)));

        require(fees >= 0);
        netCost = outcomeTokenNetCost.add(fees);

        require(
            (collateralLimit != 0 && netCost <= collateralLimit) ||
            collateralLimit == 0
        );

        if(outcomeTokenNetCost > 0) {
            require(
                eventContract.collateralToken().transferFrom(msg.sender, this, uint(netCost)) &&
                eventContract.collateralToken().approve(eventContract, uint(outcomeTokenNetCost))
            );

            eventContract.buyAllOutcomes(uint(outcomeTokenNetCost));
        }

        for (uint8 i = 0; i < outcomeCount; i++) {
            if(outcomeTokenAmounts[i] != 0) {
                if(outcomeTokenAmounts[i] < 0) {
                    require(eventContract.outcomeTokens(i).transferFrom(msg.sender, this, uint(-outcomeTokenAmounts[i])));
                } else {
                    require(eventContract.outcomeTokens(i).transfer(msg.sender, uint(outcomeTokenAmounts[i])));
                }

                netOutcomeTokensSold[i] = netOutcomeTokensSold[i].add(outcomeTokenAmounts[i]);
            }
        }

        if(outcomeTokenNetCost < 0) {
            // This is safe since
            // 0x8000000000000000000000000000000000000000000000000000000000000000 ==
            // uint(-int(-0x8000000000000000000000000000000000000000000000000000000000000000))
            eventContract.sellAllOutcomes(uint(-outcomeTokenNetCost));
            if(netCost < 0) {
                require(eventContract.collateralToken().transfer(msg.sender, uint(-netCost)));
            }
        }

        emit OutcomeTokenTrade(msg.sender, outcomeTokenAmounts, outcomeTokenNetCost, uint(fees));
    }

    /// @dev Calculates fee to be paid to market maker
    /// @param outcomeTokenCost Cost for buying outcome tokens
    /// @return Fee for trade
    function calcMarketFee(uint outcomeTokenCost)
        public
        view
        returns (uint)
    {
        return outcomeTokenCost * fee / FEE_RANGE;
    }
}