// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title XOIO v2 — Decentralized Odd/Even Game (Chainlink VRF)
 * @notice 單雙遊戲,使用 Chainlink VRF v2.5 提供不可預測的隨機數
 * @dev 下注 1–100 USDT(Polygon 主網 USDT),玩法與 v1 相同:
 *      - 隨機數最後一碼 0–9:判斷單雙,贏家獲得 2 倍(本金+利潤)
 *      - 最後一碼 a–f:平局,扣除 5% 手續費,其餘退還
 * @dev Owner 使用 Chainlink ConfirmedOwner(由 VRFConsumerBaseV2Plus 內建)
 */
contract XOIOV2 is VRFConsumerBaseV2Plus {
    // ============ 常數 ============
    address public constant USDT_ADDRESS = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F; // Polygon 主網 USDT
    uint256 public constant BASIS = 10000;

    // ============ 遊戲參數(owner 可調)============
    uint256 public minBet = 1_000_000;   // 1 USDT (6 decimals)
    uint256 public maxBet = 100_000_000; // 100 USDT
    uint256 public tieFeeBps = 500;      // 平局手續費 5%
    bool public paused;

    // ============ 安全限制(owner 可調,0 = 關閉)============
    uint256 public maxPoolBalance;   // 池子上限(0 = 不限制)
    uint256 public cooldownSeconds;  // 同地址下注間隔(0 = 不限制)
    uint256 public dailyPerPlayerLimit; // 單玩家每日下注上限(0 = 不限制)

    // ============ Chainlink VRF v2.5 ============
    uint256 public subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 300_000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 1;

    // ============ 狀態 ============
    struct Bet {
        address player;
        uint256 amount;
        uint8 choice; // 0 = 雙 EVEN, 1 = 單 ODD
        bool settled;
    }
    mapping(uint256 => Bet) public bets; // requestId => Bet
    mapping(address => uint256) public lastBetAt;  // 冷卻用
    mapping(address => uint256) public dailyVolume; // 單玩家當日累計
    mapping(address => uint256) public dailyDay;    // 單玩家最後下注日

    // ============ 事件 ============
    event BetPlaced(address indexed player, uint256 amount, uint8 choice, uint256 requestId);
    event GameResult(
        address indexed player,
        uint256 betAmount,
        uint8 choice,
        bytes32 fullHash,
        uint8 lastChar,
        string result, // "WIN" / "LOSE" / "TIE"
        uint256 payout
    );

    // ============ 建構子 ============
    constructor(
        address coordinator,       // VRF v2.5 Coordinator 地址
        uint256 _subscriptionId,   // Chainlink Subscription ID
        bytes32 _keyHash,          // gas lane keyHash
        uint32 _callbackGasLimit   // 回調 gas 上限
    ) VRFConsumerBaseV2Plus(coordinator) {
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        if (_callbackGasLimit > 0) callbackGasLimit = _callbackGasLimit;
    }

    // ============ 下注 ============
    function bet(uint256 amount, uint8 choice) external {
        require(!paused, "Game is paused");
        require(choice == 0 || choice == 1, "Invalid choice");
        require(amount >= minBet && amount <= maxBet, "Bet out of bounds");
        require(msg.sender == tx.origin, "Only EOA");

        // 冷卻
        if (cooldownSeconds > 0) {
            require(block.timestamp - lastBetAt[msg.sender] >= cooldownSeconds, "Cooldown active");
        }

        // 單玩家每日上限
        if (dailyPerPlayerLimit > 0) {
            _checkDailyLimit(msg.sender, amount);
        }

        // 池子上限:收注後池子不得超過上限
        if (maxPoolBalance > 0) {
            uint256 pool = IERC20(USDT_ADDRESS).balanceOf(address(this));
            require(pool + amount <= maxPoolBalance, "Pool cap exceeded");
        }

        // 收 USDT
        require(IERC20(USDT_ADDRESS).transferFrom(msg.sender, address(this), amount), "Transfer failed");

        // 更新限制狀態
        lastBetAt[msg.sender] = block.timestamp;
        if (dailyPerPlayerLimit > 0) {
            dailyVolume[msg.sender] += amount;
        }

        // 請求 Chainlink VRF(費用從 subscription 扣,玩家不需付 LINK)
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        bets[requestId] = Bet({player: msg.sender, amount: amount, choice: choice, settled: false});
        emit BetPlaced(msg.sender, amount, choice, requestId);
    }

    // ============ 開獎(Chainlink 回調,只有 coordinator 能呼叫)============
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        Bet storage betRecord = bets[requestId];
        require(betRecord.amount > 0, "Unknown request");
        require(!betRecord.settled, "Already settled");
        betRecord.settled = true;

        uint256 random = randomWords[0];
        bytes32 fullHash = bytes32(random);
        uint8 lastChar = uint8(random % 16); // 0..15
        uint8 choice = betRecord.choice;

        if (lastChar >= 10) {
            // 平局:退還 95%,5% 手續費留在池中
            uint256 refund = betRecord.amount * (BASIS - tieFeeBps) / BASIS;
            require(IERC20(USDT_ADDRESS).transfer(betRecord.player, refund), "TIE refund failed");
            emit GameResult(betRecord.player, betRecord.amount, choice, fullHash, lastChar, "TIE", refund);
            return;
        }

        bool isEven = (lastChar % 2) == 0; // 0,2,4,6,8
        bool win = (choice == 0 && isEven) || (choice == 1 && !isEven);
        if (win) {
            uint256 payout = betRecord.amount * 2;
            require(IERC20(USDT_ADDRESS).balanceOf(address(this)) >= payout, "Insufficient liquidity");
            require(IERC20(USDT_ADDRESS).transfer(betRecord.player, payout), "WIN transfer failed");
            emit GameResult(betRecord.player, betRecord.amount, choice, fullHash, lastChar, "WIN", payout);
        } else {
            // 輸:本金進入獎池
            emit GameResult(betRecord.player, betRecord.amount, choice, fullHash, lastChar, "LOSE", 0);
        }
    }

    // ============ Owner 管理 ============
    function setBetLimits(uint256 _min, uint256 _max) external onlyOwner {
        require(_min > 0 && _min <= _max, "Invalid limits");
        minBet = _min;
        maxBet = _max;
    }

    function setTieFeeBps(uint256 _bps) external onlyOwner {
        require(_bps < BASIS, "Fee too high");
        tieFeeBps = _bps;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function setMaxPoolBalance(uint256 _value) external onlyOwner {
        maxPoolBalance = _value;
    }

    function setCooldownSeconds(uint256 _seconds) external onlyOwner {
        cooldownSeconds = _seconds;
    }

    function setDailyPerPlayerLimit(uint256 _value) external onlyOwner {
        dailyPerPlayerLimit = _value;
    }

    function setVrfConfig(uint256 _subscriptionId, bytes32 _keyHash, uint32 _callbackGasLimit) external onlyOwner {
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        if (_callbackGasLimit > 0) callbackGasLimit = _callbackGasLimit;
    }

    function withdrawUSDT(uint256 amount) external onlyOwner {
        require(IERC20(USDT_ADDRESS).transfer(owner(), amount), "Withdraw failed");
    }

    function withdrawAllUSDT() external onlyOwner {
        uint256 bal = IERC20(USDT_ADDRESS).balanceOf(address(this));
        require(IERC20(USDT_ADDRESS).transfer(owner(), bal), "Withdraw failed");
    }

    // ============ View ============
    function getGameInfo() external view returns (
        uint256 currentMinBet,
        uint256 currentMaxBet,
        uint256 currentFee,
        uint256 poolBalance,
        bool pausedState
    ) {
        return (minBet, maxBet, tieFeeBps, IERC20(USDT_ADDRESS).balanceOf(address(this)), paused);
    }

    function getPoolBalance() external view returns (uint256) {
        return IERC20(USDT_ADDRESS).balanceOf(address(this));
    }

    function isPaused() external view returns (bool) {
        return paused;
    }

    // ============ Internal ============
    function _checkDailyLimit(address player, uint256 amount) internal {
        uint256 day = block.timestamp / 86400;
        if (dailyDay[player] != day) {
            dailyDay[player] = day;
            dailyVolume[player] = 0;
        }
        require(dailyVolume[player] + amount <= dailyPerPlayerLimit, "Daily limit exceeded");
    }
}
