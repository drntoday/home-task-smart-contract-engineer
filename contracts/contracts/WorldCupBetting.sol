// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IReputationSystem {
    function updateReputation(address user, bool correct) external;
    function getReputation(address user) external view returns (uint256);
}

contract WorldCupBetting is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    enum MarketStatus { Open, Closed, Resolved, Cancelled }

    struct Market {
        uint256 id;
        string name;
        string description;
        string[] outcomeNames;
        uint256 resolutionTime;
        address arbitrator;
        address collateralToken;
        MarketStatus status;
        uint256 totalPool;
        uint8 winningOutcome;
        mapping(uint8 => uint256) outcomePools;
        mapping(uint8 => uint256) outcomeShares;
        address creator;
    }

    struct Bet {
        uint256 id;
        address bettor;
        uint256 marketId;
        uint8 outcome;
        uint256 amount;
        uint256 shares;
        bool claimed;
        bool listed;
    }

    struct Listing {
        uint256 price;
        bool active;
    }

    IReputationSystem public immutable reputationSystem;
    uint256 public marketCount;
    uint256 public betCount;

    mapping(uint256 => Market) private markets;
    mapping(uint256 => Bet) private bets;
    mapping(uint256 => Listing) private listings;

    mapping(address => uint256[]) private userBets;
    mapping(uint256 => uint256[]) private marketBets;

    mapping(address => uint256) public availableFees;

    event MarketCreated(uint256 indexed marketId, string name, string description);
    event BetPlaced(uint256 indexed marketId, uint256 indexed betId, address bettor, uint8 outcome, uint256 amount, uint256 shares);
    event MarketResolved(uint256 indexed marketId, uint8 winningOutcome);
    event WinningsClaimed(uint256 indexed marketId, uint256 indexed betId, address claimer, uint256 payout);
    event PositionListed(uint256 indexed betId, uint256 price);
    event ListingCancelled(uint256 indexed betId);
    event PositionBought(uint256 indexed betId, address buyer, uint256 price);
    event FeesWithdrawn(address token, uint256 amount);

    modifier onlyArbitrator(uint256 marketId) {
        require(msg.sender == markets[marketId].arbitrator, "Only arbitrator");
        _;
    }

    constructor(address _reputationSystem) Ownable(msg.sender) {
        reputationSystem = IReputationSystem(_reputationSystem);
    }

    function createMarket(
        string memory _name,
        string memory _description,
        string[] memory _outcomeNames,
        uint256 _resolutionTime,
        address _arbitrator,
        address _collateralToken
    ) external returns (uint256) {
        require(_outcomeNames.length >= 2, "WorldCupBetting: at least 2 outcomes");
        require(_resolutionTime > block.timestamp, "WorldCupBetting: resolution time in the past");

        uint256 newId = ++marketCount;
        Market storage m = markets[newId];
        m.id = newId;
        m.name = _name;
        m.description = _description;
        m.outcomeNames = _outcomeNames;
        m.resolutionTime = _resolutionTime;
        m.arbitrator = _arbitrator;
        m.collateralToken = _collateralToken;
        m.status = MarketStatus.Open;
        m.creator = msg.sender;

        emit MarketCreated(newId, _name, _description);
        return newId;
    }

    function placeBet(
        uint256 _marketId,
        uint256 _outcome,
        uint256 _amount,
        uint256 _minShares
    ) external payable nonReentrant returns (uint256) {
        Market storage m = markets[_marketId];
        require(m.status == MarketStatus.Open, "Market closed");
        require(block.timestamp < m.resolutionTime, "Market closed");
        require(_outcome < m.outcomeNames.length, "WorldCupBetting: invalid outcome");

        if (m.collateralToken == address(0)) {
            require(msg.value == _amount, "WorldCupBetting: incorrect ETH amount");
        } else {
            require(msg.value == 0, "WorldCupBetting: no ETH accepted for ERC20");
            IERC20(m.collateralToken).safeTransferFrom(msg.sender, address(this), _amount);
        }

        uint256 shares = calculateShares(_amount, m.outcomePools[uint8(_outcome)], m.totalPool);
        require(shares >= _minShares, "Slippage exceeded");

        m.outcomePools[uint8(_outcome)] += _amount;
        m.totalPool += _amount;
        m.outcomeShares[uint8(_outcome)] += shares;

        uint256 betId = ++betCount;
        bets[betId] = Bet({
            id: betId,
            bettor: msg.sender,
            marketId: _marketId,
            outcome: uint8(_outcome),
            amount: _amount,
            shares: shares,
            claimed: false,
            listed: false
        });

        userBets[msg.sender].push(betId);
        marketBets[_marketId].push(betId);

        emit BetPlaced(_marketId, betId, msg.sender, uint8(_outcome), _amount, shares);
        return betId;
    }

    function resolveMarket(uint256 _marketId, uint256 _winningOutcome) external onlyArbitrator(_marketId) {
        Market storage m = markets[_marketId];
        require(m.status == MarketStatus.Open, "WorldCupBetting: market not open");
        require(block.timestamp >= m.resolutionTime, "Too early");
        require(_winningOutcome < m.outcomeNames.length, "WorldCupBetting: invalid outcome");

        m.winningOutcome = uint8(_winningOutcome);
        m.status = MarketStatus.Resolved;

        emit MarketResolved(_marketId, m.winningOutcome);
    }

    function claimWinnings(uint256 _betId) external nonReentrant {
        Bet storage bet = bets[_betId];
        require(bet.bettor == msg.sender, "WorldCupBetting: not your bet");
        require(!bet.claimed, "Already claimed");

        Market storage m = markets[bet.marketId];
        require(m.status == MarketStatus.Resolved, "WorldCupBetting: market not resolved");

        bet.claimed = true;
        uint256 payout = 0;
        bool correct = (bet.outcome == m.winningOutcome);

        if (correct) {
            uint256 winningPool = m.outcomePools[m.winningOutcome];
            uint256 winningShares = m.outcomeShares[m.winningOutcome];
            uint256 gross = (bet.shares * winningPool) / winningShares;
            uint256 fee = (gross * 2) / 100;
            payout = gross - fee;

            availableFees[m.collateralToken] += fee;

            if (m.collateralToken == address(0)) {
                (bool sent, ) = msg.sender.call{value: payout}("");
                require(sent, "WorldCupBetting: ETH transfer failed");
            } else {
                IERC20(m.collateralToken).safeTransfer(msg.sender, payout);
            }
        }

        reputationSystem.updateReputation(msg.sender, correct);
        emit WinningsClaimed(bet.marketId, _betId, msg.sender, payout);
    }

    function listPosition(uint256 _betId, uint256 _price) external {
        Bet storage bet = bets[_betId];
        require(bet.bettor == msg.sender, "WorldCupBetting: not your bet");
        require(!bet.claimed, "WorldCupBetting: already claimed");
        require(!bet.listed, "WorldCupBetting: already listed");

        Market storage m = markets[bet.marketId];
        require(m.status == MarketStatus.Open, "WorldCupBetting: market not open");

        listings[_betId] = Listing({price: _price, active: true});
        bet.listed = true;

        emit PositionListed(_betId, _price);
    }

    function cancelListing(uint256 _betId) external {
        Listing storage listing = listings[_betId];
        require(listing.active, "WorldCupBetting: not listed");

        Bet storage bet = bets[_betId];
        require(bet.bettor == msg.sender, "WorldCupBetting: not your bet");

        Market storage m = markets[bet.marketId];
        require(m.status == MarketStatus.Open, "WorldCupBetting: market not open");

        listing.active = false;
        bet.listed = false;

        emit ListingCancelled(_betId);
    }

    function buyPosition(uint256 _betId) external payable nonReentrant {
        Listing storage listing = listings[_betId];
        require(listing.active, "WorldCupBetting: not listed");

        Bet storage bet = bets[_betId];
        Market storage m = markets[bet.marketId];
        require(m.status == MarketStatus.Open, "WorldCupBetting: market not open");

        address seller = bet.bettor;
        uint256 price = listing.price;

        if (m.collateralToken == address(0)) {
            require(msg.value == price, "WorldCupBetting: incorrect price");
            (bool sent, ) = seller.call{value: price}("");
            require(sent, "WorldCupBetting: payment to seller failed");
        } else {
            require(msg.value == 0, "WorldCupBetting: no ETH for ERC20");
            IERC20(m.collateralToken).safeTransferFrom(msg.sender, seller, price);
        }

        _removeBetFromUser(seller, _betId);
        bet.bettor = msg.sender;
        bet.listed = false;
        listing.active = false;
        userBets[msg.sender].push(_betId);

        emit PositionBought(_betId, msg.sender, price);
    }

    function _removeBetFromUser(address user, uint256 betId) private {
        uint256[] storage betsList = userBets[user];
        for (uint256 i = 0; i < betsList.length; i++) {
            if (betsList[i] == betId) {
                betsList[i] = betsList[betsList.length - 1];
                betsList.pop();
                break;
            }
        }
    }

    function withdrawFees(address _token) external onlyOwner nonReentrant {
        uint256 amount = availableFees[_token];
        require(amount > 0, "WorldCupBetting: no fees");
        availableFees[_token] = 0;

        if (_token == address(0)) {
            (bool sent, ) = owner().call{value: amount}("");
            require(sent, "WorldCupBetting: ETH withdrawal failed");
        } else {
            IERC20(_token).safeTransfer(owner(), amount);
        }

        emit FeesWithdrawn(_token, amount);
    }

    function getAvailableFees(address _token) external view returns (uint256) {
        return availableFees[_token];
    }

    function calculateShares(
        uint256 _amount,
        uint256 /* _outcomePool */,
        uint256 _totalPool
    ) public pure returns (uint256) {
        if (_totalPool == 0) return _amount;
        return (_amount * _totalPool) / (_totalPool + _amount);
    }

    function getPrice(uint256 _marketId, uint256 _outcome) public view returns (uint256) {
        Market storage m = markets[_marketId];
        uint8 outcome = uint8(_outcome);
        if (m.outcomeShares[outcome] == 0) return 0;
        return (m.outcomePools[outcome] * 1e18) / m.outcomeShares[outcome];
    }

    function getTotalPool(uint256 _marketId) public view returns (uint256) {
        return markets[_marketId].totalPool;
    }

    function getUserBets(address _user) external view returns (uint256[] memory) {
        return userBets[_user];
    }

    function getMarketBets(uint256 _marketId) external view returns (uint256[] memory) {
        return marketBets[_marketId];
    }

    function getMarket(uint256 _marketId)
        external
        view
        returns (
            uint256 id,
            string memory name,
            string memory description,
            string[] memory outcomeNames,
            uint256 resolutionTime,
            address arbitrator,
            address collateralToken,
            MarketStatus status,
            uint256 totalPool,
            address creator
        )
    {
        Market storage m = markets[_marketId];
        return (
            m.id,
            m.name,
            m.description,
            m.outcomeNames,
            m.resolutionTime,
            m.arbitrator,
            m.collateralToken,
            m.status,
            m.totalPool,
            m.creator
        );
    }

    receive() external payable {}
}
