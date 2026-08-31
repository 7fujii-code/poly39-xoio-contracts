// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title XOIO v3 — Decentralized Betting Game (Chainlink VRF)
 * @notice 玩法:
 *   - 單 / 雙 (choice 0/1):2 倍賠率;尾數 a-f 平局退 95%,0-9 判斷奇偶
 *   - 猜單一數字 (choice 2-11,對應 0-9):中獎 15 倍;出 a-f 或其它數字皆輸
 *   - 猜單一字母 (choice 12-17,對應 a-f):中獎 15 倍;出數字或其它字母皆輸
 *   - 單注上限 50 USDT,支援一次送出多注 (buyMultipleBets)
 * @dev Owner 使用 Chainlink ConfirmedOwner(由 VRFConsumerBaseV2Plus 內建)
 */
contract XOIOV3 is VRFConsumerBaseV2Plus {
    // ============ 常數 ============
    address public constant USDT_ADDRESS = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F; // Polygon 主網 USDT
    uint256 public constant BASIS = 10000;

    uint256 public constant MIN_CHOICE = 0;
    uint256 public constant MAX_CHOICE = 17;          // 0-1 單雙,2-11 數字,12-17 字母
    uint256 public constant MAX_BATCH = 20;           // 單次最多 20 注

    // ============ 遊戲參數(owner 可調)============
    uint256 public minBet = 1_000_000;   // 1 USDT (6 decimals)
    uint256 public maxBet = 50_000_000;  // 50 USDT 單注上限
    uint256 public tieFeeBps = 500;      // 平局手續費 5%(單雙專用)
    uint256 public evenOddPayoutBps = 20000;   // 單雙 2 倍
    uint256 public singlePayoutBps = 150000;   // 單一數字/字母 15 倍
    bool public paused;

    // ============ 安全限制(owner 可調,0 = 關閉)============
    uint256 public maxPoolBalance;   // 池子上限(0 = 不限制)
    uint256 public cooldownSeconds;  // 同地址下注間隔(0 = 不限制)
    uint256 public dailyPerPlayerLimit; // 單玩家每日下注上限(0 = 不限制)

    // ============ Chainlink VRF v2.5 ============
    uint256 public subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 1_500_000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 1;

    // ============ 狀態 ============
    struct Bet {
        address player;
        uint256 amount;
        uint8 choice;
        bool settled;
    }
    mapping(uint256 => Bet[]) public bets; // requestId => bets(單注或批次)
    mapping(address => uint256) public lastBetAt;  // 冷卻用
    mapping(address => uint256) public dailyVolume; // 單玩家當日累計
    mapping(address => uint256) public dailyDay;    // 單玩家最後下注日

    // ============ 事件 ============
    event BetPlaced(address indexed player, uint256 amount, uint8 choice, uint256 requestId, uint256 index);
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

    // ============ 下注(單注)============
    function bet(uint256 amount, uint8 choice) external {
        uint256[] memory amounts = new uint256[](1);
        uint8[] memory choices = new uint8[](1);
        amounts[0] = amount;
        choices[0] = choice;
        _placeBets(amounts, choices);
    }

    // ============ 下注(多注一次買單)============
    function buyMultipleBets(uint256[] calldata amounts, uint8[] calldata choices) external {
        require(amounts.length == choices.length, "Length mismatch");
        require(amounts.length > 0 && amounts.length <= MAX_BATCH, "Batch size");
        _placeBets(amounts, choices);
    }

    function _placeBets(uint256[] memory amounts, uint8[] memory choices) internal {
        require(!paused, "Game is paused");
        require(choices.length <= MAX_BATCH, "Batch size");
        require(msg.sender == tx.origin, "Only EOA");

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            require(choices[i] >= MIN_CHOICE && choices[i] <= MAX_CHOICE, "Invalid choice");
            require(amounts[i] >= minBet && amounts[i] <= maxBet, "Bet out of bounds");
            totalAmount += amounts[i];
        }

        // 冷卻(以整個批次計一次)
        if (cooldownSeconds > 0) {
            require(block.timestamp - lastBetAt[msg.sender] >= cooldownSeconds, "Cooldown active");
        }

        // 單玩家每日上限
        if (dailyPerPlayerLimit > 0) {
            _checkDailyLimit(msg.sender, totalAmount);
        }

        // 池子上限:收注後池子不得超過上限
        if (maxPoolBalance > 0) {
            uint256 pool = IERC20(USDT_ADDRESS).balanceOf(address(this));
            require(pool + totalAmount <= maxPoolBalance, "Pool cap exceeded");
        }

        // 收 USDT
        require(IERC20(USDT_ADDRESS).transferFrom(msg.sender, address(this), totalAmount), "Transfer failed");

        // 更新限制狀態
        lastBetAt[msg.sender] = block.timestamp;
        if (dailyPerPlayerLimit > 0) {
            dailyVolume[msg.sender] += totalAmount;
        }

        // 請求 Chainlink VRF(每個 bet 一個 random word)
        uint32 words = uint32(amounts.length);
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: words,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        Bet[] storage batch = bets[requestId];
        for (uint256 i = 0; i < amounts.length; i++) {
            batch.push(Bet({
                player: msg.sender,
                amount: amounts[i],
                choice: choices[i],
                settled: false
            }));
            emit BetPlaced(msg.sender, amounts[i], choices[i], requestId, i);
        }
    }

    // ============ 開獎(Chainlink 回調,只有 coordinator 能呼叫)============
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        Bet[] storage batch = bets[requestId];
        require(batch.length > 0, "Unknown request");
        require(batch.length == randomWords.length, "Word count mismatch");

        for (uint256 i = 0; i < batch.length; i++) {
            Bet storage betRecord = batch[i];
            require(!betRecord.settled, "Already settled");
            betRecord.settled = true;

            uint256 random = randomWords[i];
            bytes32 fullHash = bytes32(random);
            uint8 lastChar = uint8(random % 16); // 0..15
            uint8 choice = betRecord.choice;

            if (choice <= 1) {
                // ===== 單 / 雙 =====
                if (lastChar >= 10) {
                    // a-f 平局:退還 95%,5% 手續費留在池中
                    uint256 refund = betRecord.amount * (BASIS - tieFeeBps) / BASIS;
                    require(IERC20(USDT_ADDRESS).transfer(betRecord.player, refund), "TIE refund failed");
                    emit GameResult(betRecord.player, betRecord.amount, choice, fullHash, lastChar, "TIE", refund);
                    continue;
                }

                bool isEven = (lastChar % 2) == 0; // 0,2,4,6,8
                bool win = (choice == 0 && isEven) || (choice == 1 && !isEven);
                if (win) {
                    uint256 payout = betRecord.amount * evenOddPayoutBps / BASIS;
                    require(IERC20(USDT_ADDRESS).balanceOf(address(this)) >= payout, "Insufficient liquidity");
                    require(IERC20(USDT_ADDRESS).transfer(betRecord.player, payout), "WIN transfer failed");
                    emit GameResult(betRecord.player, betRecord.amount, choice, fullHash, lastChar, "WIN", payout);
                } else {
                    emit GameResult(betRecord.player, betRecord.amount, choice, fullHash, lastChar, "LOSE", 0);
                }
            } else {
                // ===== 猜單一數字 (2-11 → 0-9) / 猜單一字母 (12-17 → a-f) =====
                // 目標尾數 = choice - 2(數字與字母通用)
                if (lastChar == (choice - 2)) {
                    uint256 payout = betRecord.amount * singlePayoutBps / BASIS;
                    require(IERC20(USDT_ADDRESS).balanceOf(address(this)) >= payout, "Insufficient liquidity");
                    require(IERC20(USDT_ADDRESS).transfer(betRecord.player, payout), "WIN transfer failed");
                    emit GameResult(betRecord.player, betRecord.amount, choice, fullHash, lastChar, "WIN", payout);
                } else {
                    // 沒中:本金進入獎池(含出字母對數字、出數字對字母)
                    emit GameResult(betRecord.player, betRecord.amount, choice, fullHash, lastChar, "LOSE", 0);
                }
            }
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

    function setPayouts(uint256 _evenOddBps, uint256 _singleBps) external onlyOwner {
        require(_evenOddBps > BASIS && _singleBps > BASIS, "Payout too low");
        evenOddPayoutBps = _evenOddBps;
        singlePayoutBps = _singleBps;
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

    function getPayouts() external view returns (uint256 evenOddBps, uint256 singleBps) {
        return (evenOddPayoutBps, singlePayoutBps);
    }

    function getPoolBalance() external view returns (uint256) {
        return IERC20(USDT_ADDRESS).balanceOf(address(this));
    }

    function isPaused() external view returns (bool) {
        return paused;
    }

    function getBatchCount(uint256 requestId) external view returns (uint256) {
        return bets[requestId].length;
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
