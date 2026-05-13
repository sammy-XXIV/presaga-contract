// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title Presaga — Agentic Prediction Market
 * @notice Prediction market where AI agents are the only traders.
 *         Markets are created and resolved by the owner (automated backend).
 *         Agents earn reputation through accurate predictions and successful hires.
 *         Humans interact only by hiring agents to bet on their behalf.
 */
contract Presaga is ReentrancyGuard, Ownable {

    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ── Enums ──────────────────────────────────────────────────

    enum MarketStatus { Open, Resolved, Cancelled }
    enum Outcome      { None, Yes, No }
    enum HireStatus   { Pending, Executed, Settled, Refunded }

    // ── Structs ────────────────────────────────────────────────

    struct Market {
        uint256      id;
        string       question;
        string       resolutionSource;
        uint256      expiresAt;
        uint256      createdAt;
        uint256      totalYes;
        uint256      totalNo;
        uint256      protocolFeePool;
        MarketStatus status;
        Outcome      outcome;
    }

    struct Agent {
        address wallet;
        string  agentId;
        uint256 reputation;
        uint256 correctPredictions;
        uint256 totalPredictions;
        uint256 correctHires;
        uint256 totalHires;
        uint256 feePerDay;        // USDT per day for hire
        bool    registered;
        uint256 registeredAt;
    }

    struct Position {
        uint256 yesAmount;
        uint256 noAmount;
        bool    claimed;
    }

    struct Hire {
        uint256     id;
        address     human;
        address     agent;
        uint256     marketId;
        bool        isYes;
        uint256     betAmount;
        uint256     hireFee;       // total hire fee paid (feePerDay * days)
        uint256     days_;         // number of days hired for
        uint256     createdAt;
        HireStatus  status;
    }

    // ── Constants ──────────────────────────────────────────────

    uint256 public constant BASE_REPUTATION     = 100;
    uint256 public constant REP_CORRECT_BET     = 10;
    uint256 public constant REP_WRONG_BET       = 3;
    uint256 public constant REP_CORRECT_HIRE    = 15;
    uint256 public constant REP_WRONG_HIRE      = 5;
    uint256 public constant PROTOCOL_FEE_BPS    = 250;  // 2.5% total
    uint256 public constant AGENT_BONUS_BPS     = 1000; // 10% of winnings on correct hire
    uint256 public constant MIN_BET             = 1e6;  // $1 USDT (6 decimals)
    uint256 public constant MIN_MARKET_DURATION = 1 hours;
    uint256 public constant MAX_MARKET_DURATION = 30 days;
    uint256 public constant EXECUTE_WINDOW      = 1 hours; // agent must execute within 1hr

    // Reputation tiers
    uint256 public constant TIER_BRONZE         = 100;
    uint256 public constant TIER_SILVER         = 250;
    uint256 public constant TIER_GOLD           = 500;
    uint256 public constant TIER_PLATINUM       = 1000;

    // ── State ──────────────────────────────────────────────────

    IERC20  public immutable usdt;

    uint256 public marketCount;
    uint256 public hireCount;

    mapping(uint256 => Market)                       public markets;
    mapping(address => Agent)                        public agents;
    mapping(uint256 => mapping(address => Position)) public positions;  // marketId → agent → position
    mapping(string  => address)                      public agentIdToWallet;
    mapping(uint256 => Hire)                         public hires;
    mapping(address => bool)                         public usedSignatures; // prevent sig replay

    // ── Events ─────────────────────────────────────────────────

    event AgentRegistered(address indexed wallet, string agentId);
    event HireFeeSet(address indexed agent, uint256 feePerDay);
    event MarketCreated(uint256 indexed id, string question, uint256 expiresAt);
    event BetPlaced(uint256 indexed marketId, address indexed agent, bool isYes, uint256 amount);
    event MarketResolved(uint256 indexed id, Outcome outcome);
    event MarketCancelled(uint256 indexed id, string reason);
    event WinningsClaimed(uint256 indexed marketId, address indexed agent, uint256 amount);
    event AgentHired(uint256 indexed hireId, address indexed human, address indexed agent, uint256 marketId, uint256 days_);
    event HireExecuted(uint256 indexed hireId, address indexed agent);
    event HireSettled(uint256 indexed hireId, uint256 humanPayout, uint256 agentBonus);
    event HireRefunded(uint256 indexed hireId, address indexed human, uint256 amount);
    event ReputationChanged(address indexed agent, uint256 oldRep, uint256 newRep, string reason);

    // ── Modifiers ──────────────────────────────────────────────

    modifier onlyAgent() {
        require(agents[msg.sender].registered, "Presaga: not a registered agent");
        _;
    }

    modifier marketExists(uint256 marketId) {
        require(marketId < marketCount, "Presaga: market does not exist");
        _;
    }

    modifier hireExists(uint256 hireId) {
        require(hireId < hireCount, "Presaga: hire does not exist");
        _;
    }

    // ── Constructor ────────────────────────────────────────────

    constructor(address _usdt) Ownable(msg.sender) {
        require(_usdt != address(0), "Presaga: zero address");
        usdt = IERC20(_usdt);
    }

    // ── Agent Registration ─────────────────────────────────────

    /**
     * @notice Register as an agent using a Kite Passport agent ID.
     *         Requires a signature from the contract owner verifying the agent ID.
     * @param agentId   Your Kite Passport agent identifier
     * @param signature Owner signature over keccak256(abi.encodePacked(msg.sender, agentId))
     */
    function registerAgent(string calldata agentId, bytes calldata signature) external {
        require(!agents[msg.sender].registered,          "Presaga: already registered");
        require(bytes(agentId).length > 0,               "Presaga: empty agent ID");
        require(agentIdToWallet[agentId] == address(0),  "Presaga: agent ID already used");
        require(!usedSignatures[msg.sender],             "Presaga: signature already used");

        // Verify the owner signed (wallet, agentId)
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encodePacked(msg.sender, agentId))
        );
        address signer = hash.recover(signature);
        require(signer == owner(), "Presaga: invalid signature");

        usedSignatures[msg.sender] = true;

        agents[msg.sender] = Agent({
            wallet:             msg.sender,
            agentId:            agentId,
            reputation:         BASE_REPUTATION,
            correctPredictions: 0,
            totalPredictions:   0,
            correctHires:       0,
            totalHires:         0,
            feePerDay:          0,
            registered:         true,
            registeredAt:       block.timestamp
        });

        agentIdToWallet[agentId] = msg.sender;
        emit AgentRegistered(msg.sender, agentId);
    }

    /**
     * @notice Set your hire fee in USDT per day.
     * @param feePerDay Amount in USDT (6 decimals) per day
     */
    function setHireFee(uint256 feePerDay) external onlyAgent {
        agents[msg.sender].feePerDay = feePerDay;
        emit HireFeeSet(msg.sender, feePerDay);
    }

    // ── Market Creation ────────────────────────────────────────

    /**
     * @notice Create a new prediction market. Owner only — called by automated backend.
     * @param question         The yes/no question
     * @param resolutionSource How the market resolves
     * @param duration         Seconds until market expires
     */
    function createMarket(
        string calldata question,
        string calldata resolutionSource,
        uint256 duration
    ) external onlyOwner returns (uint256 marketId) {
        require(bytes(question).length > 0,       "Presaga: empty question");
        require(duration >= MIN_MARKET_DURATION,   "Presaga: duration too short");
        require(duration <= MAX_MARKET_DURATION,   "Presaga: duration too long");

        marketId = marketCount++;
        markets[marketId] = Market({
            id:               marketId,
            question:         question,
            resolutionSource: resolutionSource,
            expiresAt:        block.timestamp + duration,
            createdAt:        block.timestamp,
            totalYes:         0,
            totalNo:          0,
            protocolFeePool:  0,
            status:           MarketStatus.Open,
            outcome:          Outcome.None
        });

        emit MarketCreated(marketId, question, block.timestamp + duration);
    }

    // ── Betting ────────────────────────────────────────────────

    /**
     * @notice Place a bet on a market. Agents only.
     * @param marketId The market to bet on
     * @param isYes    True for YES, false for NO
     * @param amount   USDT amount (6 decimals), minimum $1
     */
    function placeBet(
        uint256 marketId,
        bool    isYes,
        uint256 amount
    ) external onlyAgent marketExists(marketId) nonReentrant {
        Market storage market = markets[marketId];
        require(market.status == MarketStatus.Open,  "Presaga: market not open");
        require(block.timestamp < market.expiresAt,  "Presaga: market expired");
        require(amount >= MIN_BET,                   "Presaga: below minimum bet");

        uint256 protocolFee = (amount * PROTOCOL_FEE_BPS) / 10000;
        uint256 netAmount   = amount - protocolFee;

        usdt.safeTransferFrom(msg.sender, address(this), amount);

        market.protocolFeePool += protocolFee;

        Position storage pos = positions[marketId][msg.sender];
        if (isYes) {
            market.totalYes += netAmount;
            pos.yesAmount   += netAmount;
        } else {
            market.totalNo  += netAmount;
            pos.noAmount    += netAmount;
        }

        agents[msg.sender].totalPredictions++;

        emit BetPlaced(marketId, msg.sender, isYes, amount);
    }

    // ── Resolution ─────────────────────────────────────────────

    /**
     * @notice Resolve a market. Owner only — called by automated backend.
     * @param marketId The market to resolve
     * @param outcome  Yes or No
     */
    function resolveMarket(
        uint256 marketId,
        Outcome outcome
    ) external onlyOwner marketExists(marketId) nonReentrant {
        Market storage market = markets[marketId];
        require(market.status == MarketStatus.Open,             "Presaga: not open");
        require(block.timestamp >= market.expiresAt,            "Presaga: not expired yet");
        require(outcome == Outcome.Yes || outcome == Outcome.No, "Presaga: invalid outcome");

        market.status  = MarketStatus.Resolved;
        market.outcome = outcome;

        // Flush protocol fees
        if (market.protocolFeePool > 0) {
            uint256 fees = market.protocolFeePool;
            market.protocolFeePool = 0;
            usdt.safeTransfer(owner(), fees);
        }

        emit MarketResolved(marketId, outcome);
    }

    /**
     * @notice Cancel a market and allow bettors to claim refunds.
     * @param marketId The market to cancel
     * @param reason   Reason for cancellation
     */
    function cancelMarket(
        uint256 marketId,
        string calldata reason
    ) external onlyOwner marketExists(marketId) {
        Market storage market = markets[marketId];
        require(market.status == MarketStatus.Open, "Presaga: not open");
        market.status = MarketStatus.Cancelled;

        // Refund protocol fees back to pool so bettors get full refunds
        // (fees stay in contract, claimRefund handles individual refunds)

        emit MarketCancelled(marketId, reason);
    }

    // ── Claim Winnings ─────────────────────────────────────────

    /**
     * @notice Claim winnings from a resolved market.
     */
    function claimWinnings(
        uint256 marketId
    ) external onlyAgent marketExists(marketId) nonReentrant {
        Market storage market = markets[marketId];
        require(market.status == MarketStatus.Resolved, "Presaga: not resolved");

        Position storage pos = positions[marketId][msg.sender];
        require(!pos.claimed,                           "Presaga: already claimed");
        require(pos.yesAmount > 0 || pos.noAmount > 0,  "Presaga: no position");
        pos.claimed = true;

        uint256 totalPool = market.totalYes + market.totalNo;
        uint256 payout    = 0;
        bool    correct   = false;

        if (market.outcome == Outcome.Yes && pos.yesAmount > 0) {
            payout  = (pos.yesAmount * totalPool) / market.totalYes;
            correct = true;
        } else if (market.outcome == Outcome.No && pos.noAmount > 0) {
            payout  = (pos.noAmount * totalPool) / market.totalNo;
            correct = true;
        }

        Agent storage agent = agents[msg.sender];
        agent.totalPredictions++;

        if (correct) {
            agent.correctPredictions++;
            _updateReputation(msg.sender, REP_CORRECT_BET, "correct prediction");
            usdt.safeTransfer(msg.sender, payout);
            emit WinningsClaimed(marketId, msg.sender, payout);
        } else {
            _slashReputation(msg.sender, REP_WRONG_BET, "wrong prediction");
        }
    }

    /**
     * @notice Claim a refund from a cancelled market.
     */
    function claimRefund(
        uint256 marketId
    ) external onlyAgent marketExists(marketId) nonReentrant {
        Market storage market = markets[marketId];
        require(market.status == MarketStatus.Cancelled, "Presaga: not cancelled");

        Position storage pos = positions[marketId][msg.sender];
        require(!pos.claimed,                            "Presaga: already claimed");
        require(pos.yesAmount > 0 || pos.noAmount > 0,   "Presaga: no position");
        pos.claimed = true;

        uint256 refund = pos.yesAmount + pos.noAmount;
        usdt.safeTransfer(msg.sender, refund);
    }

    // ── Agent-as-a-Service ─────────────────────────────────────

    /**
     * @notice Hire an agent to bet on your behalf.
     *         Human pays: (agent.feePerDay * days_) + betAmount upfront.
     * @param agentAddress The agent to hire
     * @param marketId     The market to bet on
     * @param isYes        Direction the agent should bet
     * @param betAmount    USDT to bet (minimum $1)
     * @param days_        Number of days to hire the agent for
     */
    function hireAgent(
        address agentAddress,
        uint256 marketId,
        bool    isYes,
        uint256 betAmount,
        uint256 days_
    ) external marketExists(marketId) nonReentrant {
        require(agents[agentAddress].registered,           "Presaga: agent not registered");
        require(agentAddress != msg.sender,                "Presaga: cannot hire yourself");
        require(betAmount >= MIN_BET,                      "Presaga: below minimum bet");
        require(days_ > 0,                                 "Presaga: days must be > 0");

        Market storage market = markets[marketId];
        require(market.status == MarketStatus.Open,        "Presaga: market not open");
        require(block.timestamp < market.expiresAt,        "Presaga: market expired");

        Agent storage agent = agents[agentAddress];
        uint256 hireFee     = agent.feePerDay * days_;
        uint256 totalCost   = hireFee + betAmount;

        usdt.safeTransferFrom(msg.sender, address(this), totalCost);

        uint256 hireId = hireCount++;
        hires[hireId] = Hire({
            id:        hireId,
            human:     msg.sender,
            agent:     agentAddress,
            marketId:  marketId,
            isYes:     isYes,
            betAmount: betAmount,
            hireFee:   hireFee,
            days_:     days_,
            createdAt: block.timestamp,
            status:    HireStatus.Pending
        });

        emit AgentHired(hireId, msg.sender, agentAddress, marketId, days_);
    }

    /**
     * @notice Agent executes the hire by placing the bet on-chain.
     *         Must be called within EXECUTE_WINDOW (1 hour) of hire creation.
     * @param hireId The hire to execute
     */
    function executeHire(uint256 hireId) external onlyAgent hireExists(hireId) nonReentrant {
        Hire storage hire = hires[hireId];
        require(hire.agent == msg.sender,              "Presaga: not your hire");
        require(hire.status == HireStatus.Pending,     "Presaga: hire not pending");
        require(
            block.timestamp <= hire.createdAt + EXECUTE_WINDOW,
            "Presaga: execute window expired"
        );

        Market storage market = markets[hire.marketId];
        require(market.status == MarketStatus.Open,    "Presaga: market not open");
        require(block.timestamp < market.expiresAt,    "Presaga: market expired");

        hire.status = HireStatus.Executed;

        // Pay hire fee to agent immediately
        usdt.safeTransfer(hire.agent, hire.hireFee);

        // Place bet on behalf of human
        uint256 protocolFee = (hire.betAmount * PROTOCOL_FEE_BPS) / 10000;
        uint256 netAmount   = hire.betAmount - protocolFee;

        market.protocolFeePool += protocolFee;

        Position storage pos = positions[hire.marketId][hire.agent];
        if (hire.isYes) {
            market.totalYes += netAmount;
            pos.yesAmount   += netAmount;
        } else {
            market.totalNo  += netAmount;
            pos.noAmount    += netAmount;
        }

        agents[hire.agent].totalHires++;

        emit HireExecuted(hireId, msg.sender);
    }

    /**
     * @notice Settle a hire after market resolution.
     *         Anyone can call this — it pays out the human and optionally the agent.
     * @param hireId The hire to settle
     */
    function settleHire(uint256 hireId) external hireExists(hireId) nonReentrant {
        Hire storage hire = hires[hireId];
        require(hire.status == HireStatus.Executed,    "Presaga: hire not executed");

        Market storage market = markets[hire.marketId];
        require(market.status == MarketStatus.Resolved, "Presaga: market not resolved");

        hire.status = HireStatus.Settled;

        Position storage pos = positions[hire.marketId][hire.agent];
        require(!pos.claimed, "Presaga: position already claimed");
        pos.claimed = true;

        uint256 totalPool = market.totalYes + market.totalNo;
        uint256 payout    = 0;
        bool    correct   = false;

        if (market.outcome == Outcome.Yes && pos.yesAmount > 0) {
            payout  = (pos.yesAmount * totalPool) / market.totalYes;
            correct = true;
        } else if (market.outcome == Outcome.No && pos.noAmount > 0) {
            payout  = (pos.noAmount * totalPool) / market.totalNo;
            correct = true;
        }

        Agent storage agent = agents[hire.agent];

        if (correct) {
            agent.correctHires++;
            _updateReputation(hire.agent, REP_CORRECT_HIRE, "correct hire");

            uint256 agentBonus  = (payout * AGENT_BONUS_BPS) / 10000;
            uint256 humanPayout = payout - agentBonus;

            usdt.safeTransfer(hire.human, humanPayout);
            usdt.safeTransfer(hire.agent, agentBonus);

            emit HireSettled(hireId, humanPayout, agentBonus);
        } else {
            _slashReputation(hire.agent, REP_WRONG_HIRE, "wrong hire");
            // Human gets nothing back — they paid the hire fee for the service
            emit HireSettled(hireId, 0, 0);
        }
    }

    /**
     * @notice Refund a hire if the agent failed to execute within the window.
     *         Human gets betAmount back. Hire fee is forfeited (agent never executed).
     * @param hireId The hire to refund
     */
    function refundHire(uint256 hireId) external hireExists(hireId) nonReentrant {
        Hire storage hire = hires[hireId];
        require(hire.human == msg.sender,              "Presaga: not your hire");
        require(hire.status == HireStatus.Pending,     "Presaga: hire not pending");
        require(
            block.timestamp > hire.createdAt + EXECUTE_WINDOW,
            "Presaga: window not expired yet"
        );

        hire.status = HireStatus.Refunded;

        // Refund full amount (hireFee + betAmount) since agent never executed
        uint256 refund = hire.hireFee + hire.betAmount;
        usdt.safeTransfer(hire.human, refund);

        emit HireRefunded(hireId, hire.human, refund);
    }

    // ── Reputation ─────────────────────────────────────────────

    function _updateReputation(address wallet, uint256 amount, string memory reason) internal {
        Agent storage agent = agents[wallet];
        uint256 oldRep      = agent.reputation;
        agent.reputation   += amount;
        emit ReputationChanged(wallet, oldRep, agent.reputation, reason);
    }

    function _slashReputation(address wallet, uint256 amount, string memory reason) internal {
        Agent storage agent = agents[wallet];
        uint256 oldRep      = agent.reputation;
        agent.reputation    = agent.reputation > amount ? agent.reputation - amount : 1;
        emit ReputationChanged(wallet, oldRep, agent.reputation, reason);
    }

    // ── Views ──────────────────────────────────────────────────

    function getMarket(uint256 marketId) external view returns (Market memory) {
        return markets[marketId];
    }

    function getAgent(address wallet) external view returns (Agent memory) {
        return agents[wallet];
    }

    function getPosition(uint256 marketId, address wallet) external view returns (Position memory) {
        return positions[marketId][wallet];
    }

    function getHire(uint256 hireId) external view returns (Hire memory) {
        return hires[hireId];
    }

    function getAgentTier(address wallet) external view returns (string memory) {
        uint256 rep = agents[wallet].reputation;
        if (rep >= TIER_PLATINUM) return "Platinum";
        if (rep >= TIER_GOLD)     return "Gold";
        if (rep >= TIER_SILVER)   return "Silver";
        return "Bronze";
    }

    /**
     * @notice Returns agent win rate in basis points (e.g. 7500 = 75.00%)
     */
    function getAgentWinRate(address wallet) external view returns (uint256) {
        Agent storage a = agents[wallet];
        if (a.totalPredictions == 0) return 0;
        return (a.correctPredictions * 10000) / a.totalPredictions;
    }

    /**
     * @notice Returns agent hire win rate in basis points (e.g. 8000 = 80.00%)
     */
    function getAgentHireWinRate(address wallet) external view returns (uint256) {
        Agent storage a = agents[wallet];
        if (a.totalHires == 0) return 0;
        return (a.correctHires * 10000) / a.totalHires;
    }

    function getOpenMarkets() external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < marketCount; i++) {
            if (markets[i].status == MarketStatus.Open && block.timestamp < markets[i].expiresAt)
                count++;
        }
        uint256[] memory ids = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < marketCount; i++) {
            if (markets[i].status == MarketStatus.Open && block.timestamp < markets[i].expiresAt)
                ids[idx++] = i;
        }
        return ids;
    }

    // ── Admin ──────────────────────────────────────────────────

    /**
     * @notice Withdraw any stuck USDT (emergency only).
     */
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        usdt.safeTransfer(owner(), amount);
    }
}

