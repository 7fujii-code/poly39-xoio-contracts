// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

// ========== IERC20 Interface (Polygon 版本) ==========
interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// ========== ✅ V6 Polygon 主網部署版：最大投注1000，Gas緩衝1500000 ==========
contract Poly39V6_Polygon {
    // ========== ✅ 120分鐘時間系統 ==========
    uint256 public immutable DEPLOYMENT_TIMESTAMP;
    uint256 public constant ROUND_DURATION = 120 minutes;
    uint256 public constant BETTING_DURATION = 90 minutes;
    uint256 public constant DRAW_BUFFER = 5 minutes;
    uint256 public constant PROCESSING_DURATION = 25 minutes;
    
    // ========== ✅ 費用配置 ==========
    uint256 public constant TICKET_PRICE = 5 * 10**6;
    uint256 public constant THIRD_PRIZE = 250 * 10**6;
    uint256 public constant FOURTH_PRIZE = 10 * 10**6;
    
    // ========== ✅ 獎金分配比例 ==========
    uint256 public constant FIRST_PRIZE_PERCENT = 60;   // 一等奖 60%
    uint256 public constant SECOND_PRIZE_PERCENT = 10;  // 二等奖 10%
    
    // ========== ✅ 限制配置 ==========
    uint256 public constant MAX_POOL_SIZE = 1000000 * 10**6;
    uint256 public constant MAX_TICKETS_PER_PLAYER = 1000;      // ✅ 修改點1：從10000降為1000
    uint256 public constant MAX_BATCH_PURCHASE = 60;
    uint256 public constant MIN_NUMBER = 1;
    uint256 public constant MAX_NUMBER = 39;
    uint256 public constant NUMBERS_TO_DRAW = 5;
    
    // ========== ✅ 安全配置 ==========
    uint256 public constant MAX_RETRY_ATTEMPTS = 3;
    uint256 public constant MAX_AUTO_PROCESS_INTERVAL = 5 seconds;
    
    // ========== ✅ 1000注處理能力配置 ==========
    uint256 public constant GAS_BUFFER_FOR_DISTRIBUTION = 1500000;   // ✅ 修改點2：從500000升為1500000
    uint256 public constant OPTIMAL_BATCH_SIZE = 50;               
    
    // ========== ✅ 獎品等級常量 ==========
    uint8 constant PRIZE_LEVEL_NONE = 0;
    uint8 constant PRIZE_LEVEL_FIRST = 1;
    uint8 constant PRIZE_LEVEL_SECOND = 2;
    uint8 constant PRIZE_LEVEL_THIRD = 3;
    uint8 constant PRIZE_LEVEL_FOURTH = 4;
    
    // ========== ✅ 結構體定義 ==========
    struct RoundTime {
        uint256 startTime;
        uint256 bettingEndTime;
        uint256 drawTime;
        uint256 processingEndTime;
        uint256 drawBlockNumber;
        bool bettingClosed;
        bool drawExecuted;
        bool processingCompleted;
    }
    
    struct RoundData {
        // 🛡️ V5.8 簡化會計
        uint256 prizePool;              // 本期總收入（上期滾存 + 本期銷售），歷史記錄不變
        uint256 totalDistributed;       // 已發放總金額
        uint256 rolloverAmount;         // 滾存金額（等於合約當前餘額）
        
        uint256 totalTickets;           // 總票數
        uint256[5] winningNumbers;      // 中獎號碼
        uint256[4] winnerCounts;        // 各等級中獎人數
        uint256[4] prizeAmounts;        // 各等級預算金額
        uint256[4] distributed;         // 各等級已發放金額
        
        bool distributionDataReady;     // 數據是否計算完成
        bool thirdPrizeCapped;          // 三等獎是否觸發上限
        bool fourthPrizeCapped;         // 四等獎是否觸發上限
        bool finalized;                 // 回合是否已結算
        bool rolloverTransferred;       // 滾存是否已轉移
        bool managementFeeTaken;        // 管理費是否已提取
    }
    
    struct Ticket {
        address player;
        uint64 numbersBitmap;
        uint32 roundId;
        uint8 prizeLevel;
        bool claimed;
    }
    
    struct PrizeStats {
        uint256 firstWinners;
        uint256 secondWinners;
        uint256 thirdWinners;
        uint256 fourthWinners;
        uint256 firstPrize;
        uint256 secondPrize;
        uint256 thirdPrize;
        uint256 fourthPrize;
        uint256 firstDistributed;
        uint256 secondDistributed;
        uint256 thirdDistributed;
        uint256 fourthDistributed;
        uint256 rolloverAmount;
        bool thirdCapped;
        bool fourthCapped;
    }
    
    // ========== ✅ 狀態變數 ==========
    IERC20 public immutable usdtToken;
    address public owner;
    uint256 public currentRoundId;
    bool private _drawInProgress;
    bool private _distributionInProgress;
    bool public isPaused;
    uint256 private _randomNonce;
    
    // ========== ✅ 存儲映射 ==========
    mapping(uint256 => RoundTime) public roundTimes;
    mapping(uint256 => RoundData) public rounds;
    mapping(uint256 => Ticket) public tickets;
    mapping(uint256 => uint256[]) public roundTickets;
    mapping(address => mapping(uint256 => uint256)) public playerRoundTicketCount;
    mapping(uint256 => uint256) public lastProcessedIndex;
    
    // ✅ 防重放保護（保留）
    mapping(bytes32 => bool) private _distributionHashes;
    
    // ✅ 自動處理頻率限制
    mapping(uint256 => uint256) public lastAutoProcessTime;
    
    uint256 private _nextTicketId = 1;
    
    // ========== ✅ 事件定義 ==========
    event RoundStarted(uint256 indexed roundId, uint256 startTime);
    event TicketPurchased(address indexed player, uint256 ticketId, uint256 roundId);
    event BatchPurchased(address indexed player, uint256 startId, uint256 count, uint256 amount);
    event DrawExecuted(uint256 indexed roundId, uint256[5] winningNumbers);
    event DrawDataReady(uint256 indexed roundId);
    event PrizeAutoDistributed(uint256 indexed roundId, address player, uint256 ticketId, uint256 amount, uint8 prizeLevel);
    event PrizeDistributionCompleted(uint256 indexed roundId, uint256 totalDistributed, uint256 failedCount);
    event AutoProcessTriggered(address indexed trigger, uint256 roundId, uint256 timestamp);
    event RoundAutoFinalized(uint256 indexed roundId, uint256 timestamp);
    event BettingClosed(uint256 indexed roundId, uint256 timestamp);
    event RandomNumbersGenerated(uint256 indexed roundId, bytes32 seed, uint256[5] numbers);
    event PrizeCalculationComplete(
        uint256 indexed roundId,
        uint256 fullPrizePool,
        uint256 firstPrize,
        uint256 secondPrize,
        uint256 thirdPrize,
        uint256 fourthPrize
    );
    event RolloverTransferred(uint256 indexed fromRoundId, uint256 indexed toRoundId, uint256 amount);
    event FundsSafetyChecked(uint256 timestamp, uint256 totalPrizePools, uint256 contractBalance, bool isSafe);
    event BugFixApplied(string description, uint256 roundId, uint256 timestamp);
    event DistributionHashUsed(bytes32 indexed hash, uint256 roundId, uint256 ticketId);
    event RoundFinalized(uint256 indexed roundId, uint256 rolloverAmount, uint256 timestamp);
    
    // ========== ✅ V5.9 新增事件 ==========
    event V59UpgradeApplied(uint256 timestamp, string description);
    event SimpleRolloverCalculated(uint256 indexed roundId, uint256 balance, uint256 rollover);
    event RolloverAddedToNextRound(uint256 indexed toRoundId, uint256 existingPool, uint256 rolloverAdded, uint256 newPool);
    
    // ========== 【新增】管理費事件 ==========
    event ManagementFeeTaken(uint256 indexed roundId, uint256 feeAmount, uint256 remainingBalance);
    
    // ========== 修改器 ==========
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    modifier whenNotPaused() {
        require(!isPaused, "Contract is paused");
        _;
    }
    
    modifier whenPaused() {
        require(isPaused, "Contract is not paused");
        _;
    }
    
    modifier onlyDuringBettingPeriod() {
        require(isBettingPeriod(), "Not in betting period");
        _;
    }
    
    modifier autoProcess() {
        _autoCheckAndProcess();
        _;
    }
    
    // ========== Constructor ==========
    constructor(address _usdtAddress) {
        require(_usdtAddress != address(0), "Invalid USDT address");
        owner = msg.sender;
        usdtToken = IERC20(_usdtAddress);
        isPaused = false;
        _randomNonce = 0;
        
        DEPLOYMENT_TIMESTAMP = block.timestamp;
        _initializeFirstRound();
        
        // 標記Polygon主網部署版本
        emit V59UpgradeApplied(block.timestamp, "V6 Polygon Mainnet - Max Tickets 1000, Gas Buffer 1500000");
    }
    
    // ========== ✅ 時間系統函數（保持不變）==========
    function getCurrentRound(uint256 timestamp) public view returns (uint256) {
        if (timestamp < DEPLOYMENT_TIMESTAMP) return 0;
        uint256 secondsSinceDeploy = timestamp - DEPLOYMENT_TIMESTAMP;
        uint256 slotsPassed = secondsSinceDeploy / ROUND_DURATION;
        return slotsPassed + 1;
    }
    
    function getRoundSchedule(uint256 roundId) public view returns (
        uint256 startTime,
        uint256 bettingEndTime,
        uint256 drawTime,
        uint256 processingEndTime
    ) {
        require(roundId > 0, "Invalid round ID");
        
        startTime = DEPLOYMENT_TIMESTAMP + (roundId - 1) * ROUND_DURATION;
        bettingEndTime = startTime + BETTING_DURATION;
        drawTime = bettingEndTime + DRAW_BUFFER;
        processingEndTime = drawTime + PROCESSING_DURATION;
        
        uint256 nextRoundStart = startTime + ROUND_DURATION;
        if (processingEndTime > nextRoundStart) {
            processingEndTime = nextRoundStart;
        }
    }
    
    function isBettingPeriod() public view returns (bool) {
        if (currentRoundId == 0) return false;
        
        RoundTime storage round = roundTimes[currentRoundId];
        uint256 now_ = block.timestamp;
        
        return (now_ >= round.startTime && 
                now_ < round.bettingEndTime &&
                !round.bettingClosed);
    }
    
    function _initializeFirstRound() internal {
        uint256 currentRound = getCurrentRound(block.timestamp);
        require(currentRound > 0, "Invalid round calculation");
        currentRoundId = currentRound;
        _setupRoundTime(currentRound);
        emit RoundStarted(currentRound, block.timestamp);
    }
    
    function _setupRoundTime(uint256 roundId) internal {
        (uint256 startTime, uint256 bettingEndTime, uint256 drawTime, uint256 processingEndTime) = 
            getRoundSchedule(roundId);
        
        roundTimes[roundId] = RoundTime({
            startTime: startTime,
            bettingEndTime: bettingEndTime,
            drawTime: drawTime,
            processingEndTime: processingEndTime,
            drawBlockNumber: 0,
            bettingClosed: false,
            drawExecuted: false,
            processingCompleted: false
        });
        
        // 初始化會計變數（如果尚未初始化）
        if (rounds[roundId].prizePool == 0) {
            rounds[roundId].prizePool = 0;
            rounds[roundId].totalDistributed = 0;
            rounds[roundId].rolloverAmount = 0;
            rounds[roundId].managementFeeTaken = false;
        }
    }
    
    // ========== ✅ 防重放機制（保持不變）==========
    function _getDistributionHash(
        uint256 roundId,
        uint256 ticketId,
        address player,
        uint8 prizeLevel
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            "DISTRIBUTION_V5_5",
            roundId,
            ticketId,
            player,
            prizeLevel
        ));
    }
    
    // ========== ✅ V5.8：核心修復 - 簡化最終確定回合 ==========
    /**
     * @notice V5.8 核心修復：滾存計算改為「餘額結算」
     * @dev 邏輯：合約裡現在剩多少錢，這些錢就全部滾存到下一期
     *      prizePool 保持為本期總收入歷史記錄，不修改
     *      滾存 = 合約當前餘額
     */
    function _finalizeRound(uint256 roundId) internal {
        RoundData storage rd = rounds[roundId];
        if (rd.finalized) return;

        // 【新增】提取管理費（在最終結算時）
        _takeManagementFee(roundId);

        // 1. 獲取合約當前真實餘額（已扣除管理費和已發放的獎金）
        uint256 currentBalance = usdtToken.balanceOf(address(this));
        
        // 2. 設定滾存 = 當前餘額
        // 包含：未領取獎金 + 外部捐款 + 真正滾存
        rd.rolloverAmount = currentBalance;
        
        // 🚫 重要：不修改 prizePool！
        // prizePool 是本期總收入的歷史記錄，應保持不變
        // 例：prizePool = 600U（總收入），totalDistributed = 400U
        //     currentBalance = 200U，rolloverAmount = 200U
        //     prizePool 保持 600U 作為歷史記錄

        // 3. 標記完成
        rd.finalized = true;
        
        emit SimpleRolloverCalculated(roundId, currentBalance, currentBalance);
        emit RoundFinalized(roundId, currentBalance, block.timestamp);
        emit BugFixApplied("V5.8 Balance-based rollover - Fixed rollover calculation bug", roundId, block.timestamp);
    }
    
    // ========== 【新增】提取管理費函數 ==========
    /**
     * @notice 提取回合結束後剩餘資金的1%作為管理費
     * @dev 在回合最終結算時執行，只執行一次
     */
    function _takeManagementFee(uint256 roundId) internal {
        RoundData storage rd = rounds[roundId];
        
        // 確保只執行一次
        if (rd.managementFeeTaken) {
            return;
        }
        
        // 獲取當前合約餘額（獎金發放後剩餘的）
        uint256 remainingBalance = usdtToken.balanceOf(address(this));
        
        // 只有當餘額大於0時才提取管理費
        if (remainingBalance > 0) {
            // 計算1%管理費
            uint256 feeAmount = remainingBalance / 100;
            
            // 確保管理費大於0
            if (feeAmount > 0) {
                // 使用萬能轉帳函數
                _safeTransfer(owner, feeAmount);
                
                // 標記已提取
                rd.managementFeeTaken = true;
                
                emit ManagementFeeTaken(roundId, feeAmount, remainingBalance);
            }
        }
    }
    
    // ========== 【新增】萬能轉帳函數 ==========
    /**
     * @notice 【萬能轉帳函數】解決所有 Transfer failed 問題
     * @dev 直接使用函數選擇器 0xa9059cbb (transfer)
     */
    function _safeTransfer(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, bytes memory data) = address(usdtToken).call(
            abi.encodeWithSelector(0xa9059cbb, to, amount)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Transfer failed: Low-level call"
        );
    }
    
    // ========== ✅ V5.9 關鍵修復：滾存轉移（修正累加問題）==========
    /**
     * @notice 將上一回合的滾存金額添加到下一回合的 prizePool
     * @dev V5.9 關鍵修正：必須把滾存金額累加到下一回合的帳本上
     *      滾存金額應該加到下一回合的 prizePool，而不是覆蓋它
     */
    function _transferRolloverToNextRound(uint256 fromRoundId, uint256 toRoundId) internal {
        require(fromRoundId > 0 && toRoundId > fromRoundId, "Invalid round IDs");
        RoundData storage fromRd = rounds[fromRoundId];
        RoundData storage toRd = rounds[toRoundId];
        
        require(fromRd.finalized, "Source round not finalized");
        require(!fromRd.rolloverTransferred, "Already transferred");
        
        uint256 totalToTransfer = fromRd.rolloverAmount;
        
        // 標記為已轉移
        fromRd.rolloverTransferred = true;

        if (totalToTransfer == 0) {
            return;
        }
        
        // ✅ V5.9 關鍵修復：滾存金額需要累加到下一回合的 prizePool
        // 下一回合的 prizePool = 已有的 prizePool + 滾存金額
        // 注意：不能覆蓋下一回合可能已經有的資金（玩家投注等）
        uint256 existingPool = toRd.prizePool;
        uint256 newPrizePool = existingPool + totalToTransfer;
        
        require(newPrizePool <= MAX_POOL_SIZE, "Next round pool would exceed limit");
        
        toRd.prizePool = newPrizePool;
        
        emit RolloverTransferred(fromRoundId, toRoundId, totalToTransfer);
        emit RolloverAddedToNextRound(toRoundId, existingPool, totalToTransfer, newPrizePool);
        emit BugFixApplied("V5.9 Fixed: Rollover amount ADDED to next round's prizePool (not overwritten)", toRoundId, block.timestamp);
    }
    
    // ========== ✅ V5.8：修正資金安全檢查 ==========
    /**
     * @notice V5.8 修正版：只檢查當前淨資產，不再累加歷史數據
     * @dev 解決原版「6410U」顯示錯誤的問題
     *      邏輯：比較當前回合的理論需求和實際餘額
     *      totalRequired = prizePool - totalDistributed
     */
    function checkFundSafety() public returns (
        bool isSafe,
        uint256 totalRequired, 
        uint256 contractBalance,
        uint256 difference
    ) {
        // 1. 獲取合約當前餘額
        contractBalance = usdtToken.balanceOf(address(this));
        
        // 2. 計算帳面應有資金
        // 理論需求 = 總收入 - 已發放
        RoundData storage currentRd = rounds[currentRoundId];
        
        if (currentRd.prizePool > currentRd.totalDistributed) {
            totalRequired = currentRd.prizePool - currentRd.totalDistributed;
        } else {
            totalRequired = 0;
        }
        
        // 3. 比對
        if (contractBalance >= totalRequired) {
            // 如果 餘額 > 帳面，說明有「額外資金」（未領獎金、捐款等）
            // 在 V5.8 邏輯下這是正常現象
            isSafe = true;
            difference = contractBalance - totalRequired; 
        } else {
            // 如果 餘額 < 帳面，說明錢不見了（這才是真的危險）
            isSafe = false;
            difference = totalRequired - contractBalance;
        }
        
        emit FundsSafetyChecked(block.timestamp, totalRequired, contractBalance, isSafe);
        return (isSafe, totalRequired, contractBalance, difference);
    }
    
    // ========== ✅ V5.5：獎金上限計算（保持原有邏輯）==========
    function _calculateActualPrizePerWinner(uint256 roundId, uint8 prizeLevel) 
        internal 
        view 
        returns (uint256) 
    {
        RoundData storage rd = rounds[roundId];
        uint8 levelIndex = prizeLevel - 1;
        
        if (rd.winnerCounts[levelIndex] == 0) return 0;
        
        // 三等獎和四等獎的特殊處理
        if (prizeLevel == PRIZE_LEVEL_THIRD) {
            if (rd.thirdPrizeCapped) {
                // 觸發上限：平分可用預算
                return rd.prizeAmounts[2] / rd.winnerCounts[2];
            } else {
                // 正常：固定250U
                return THIRD_PRIZE;
            }
        } else if (prizeLevel == PRIZE_LEVEL_FOURTH) {
            if (rd.fourthPrizeCapped) {
                // 觸發上限：平分可用預算
                return rd.prizeAmounts[3] / rd.winnerCounts[3];
            } else {
                // 正常：固定10U
                return FOURTH_PRIZE;
            }
        } else {
            // 一等獎和二等獎：平分預算
            return rd.prizeAmounts[levelIndex] / rd.winnerCounts[levelIndex];
        }
    }
    
    // ========== ✅ V5.5：簡化獎金發放函數（保持不變）==========
    function _executeDistribution(uint256 roundId, uint256 ticketId) 
        internal 
        returns (bool) 
    {
        Ticket storage ticket = tickets[ticketId];
        
        // 🛡️ 雙重防重放檢查
        bytes32 hash = _getDistributionHash(roundId, ticketId, ticket.player, ticket.prizeLevel);
        if (_distributionHashes[hash] || ticket.claimed) {
            return false;
        }
        
        // 計算獎金額（包含上限邏輯）
        uint256 amountToPay = _calculateActualPrizePerWinner(roundId, ticket.prizeLevel);
        if (amountToPay == 0) return false;
        
        // 檢查合約餘額
        if (usdtToken.balanceOf(address(this)) < amountToPay) {
            return false;
        }
        
        // 🛡️ 原子操作：先標記所有狀態
        _distributionHashes[hash] = true;
        ticket.claimed = true;
        
        // ✅ 使用低級調用，手動檢查是否成功
        // 1. 編碼函數調用數據
        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, ticket.player, amountToPay);
        
        // 2. 發起調用 (不依賴 interface 的返回值定義)
        (bool success, bytes memory returndata) = address(usdtToken).call(data);
        
        // 3. 雙重驗證：
        //    條件一：調用本身沒有報錯 (success 為真)
        //    條件二：如果對方有返回值，返回值解碼後必須為 true；如果對方沒返回值(長度0)，也算成功。
        bool transferSuccess = success && (returndata.length == 0 || abi.decode(returndata, (bool)));
        
        if (transferSuccess) {
            uint8 levelIndex = ticket.prizeLevel - 1;
            rounds[roundId].totalDistributed += amountToPay;
            rounds[roundId].distributed[levelIndex] += amountToPay;
            emit PrizeAutoDistributed(roundId, ticket.player, ticketId, amountToPay, ticket.prizeLevel);
            emit DistributionHashUsed(hash, roundId, ticketId);
            return true;
        } else {
            // 失敗：回滾狀態
            _distributionHashes[hash] = false;
            ticket.claimed = false;
            return false;
        }
    }
    
    // ========== ✅ V5.5：保留原有的獎金計算邏輯（保持不變）==========
    function _calculateAndUpdatePrizes(uint256 roundId) internal {
        RoundData storage rd = rounds[roundId];
        require(rd.winningNumbers[0] != 0, "Winning numbers not set");
        
        // 檢查是否有得獎者
        uint256 totalWinners = rd.winnerCounts[0] + rd.winnerCounts[1] + 
                              rd.winnerCounts[2] + rd.winnerCounts[3];
        
        // ✅ V5.5：無人中獎時，設置預算為0
        if (totalWinners == 0) {
            for (uint8 i = 0; i < 4; i++) {
                rd.prizeAmounts[i] = 0;
            }
            rd.distributionDataReady = true;
            return;
        }
        
        // ✅ V5.5：使用簡化後的 prizePool（包含所有資金）
        uint256 fullPrizePool = rd.prizePool;
        
        // 1. 計算固定獎金上限
        uint256 maxThird = fullPrizePool * 50 / 100;
        uint256 maxFourth = fullPrizePool * 30 / 100;
        
        // 2. 計算需要的固定獎金
        uint256 thirdNeeded = rd.winnerCounts[2] * THIRD_PRIZE;
        uint256 fourthNeeded = rd.winnerCounts[3] * FOURTH_PRIZE;
        
        // 3. 應用上限並標記
        uint256 actualThird = thirdNeeded;
        uint256 actualFourth = fourthNeeded;
        
        rd.thirdPrizeCapped = false;
        rd.fourthPrizeCapped = false;
        
        if (thirdNeeded > maxThird) {
            rd.thirdPrizeCapped = true;
            actualThird = maxThird;
        }
        
        if (fourthNeeded > maxFourth) {
            rd.fourthPrizeCapped = true;
            actualFourth = maxFourth;
        }
        
        require(actualThird + actualFourth <= fullPrizePool, "Fixed prizes exceed pool");
        
        // 4. 計算可用於百分比分配的資金
        uint256 availableForPercent = fullPrizePool - actualThird - actualFourth;
        
        // 5. 計算一、二等獎預算
        uint256 firstPrize = availableForPercent * FIRST_PRIZE_PERCENT / 100;
        uint256 secondPrize = availableForPercent * SECOND_PRIZE_PERCENT / 100;
        
        // 6. 安全檢查：總預算不超過獎池
        uint256 totalBudget = firstPrize + secondPrize + actualThird + actualFourth;
        require(totalBudget <= fullPrizePool, "Total budget exceeds prize pool");
        
        // 7. 設置預算（僅用於計算每人獎金，不影響實際資金）
        rd.prizeAmounts[0] = firstPrize;
        rd.prizeAmounts[1] = secondPrize;
        rd.prizeAmounts[2] = actualThird;
        rd.prizeAmounts[3] = actualFourth;
        
        rd.distributionDataReady = true;
        
        emit PrizeCalculationComplete(
            roundId,
            fullPrizePool,
            firstPrize,
            secondPrize,
            actualThird,
            actualFourth
        );
    }
    
    // ========== ✅ V5.5：批次分發獎金（修改 Gas 檢查邏輯）==========
    function _executeBatchDistribution(uint256 roundId, uint256 batchSize) 
        internal 
        returns (uint256 distributed, uint256 failed) 
    {
        uint256[] storage batchTickets = roundTickets[roundId];
        uint256 startIndex = lastProcessedIndex[roundId];
        
        uint256 remaining = batchTickets.length - startIndex;
        uint256 actualSize = batchSize > remaining ? remaining : batchSize;
        
        // ✅ 修改點1：使用優化的 Gas 緩衝
        uint256 GAS_BUFFER = GAS_BUFFER_FOR_DISTRIBUTION; // 1,500,000 Gas
        
        for (uint256 i = 0; i < actualSize; i++) {
            // ✅ 修改點2：每10票檢查一次（原為每票檢查）
            if (i % 10 == 0 && gasleft() < GAS_BUFFER) {
                lastProcessedIndex[roundId] = startIndex + i;
                return (distributed, failed);
            }
            
            uint256 tid = batchTickets[startIndex + i];
            Ticket storage ticket = tickets[tid];
            
            // 🛡️ 硬核過濾：如果無獎或已領獎，直接跳過
            if (ticket.prizeLevel == 0 || ticket.claimed) {
                continue;
            }
            
            bool success = _executeDistribution(roundId, tid);
            
            if (success) {
                distributed++;
            } else {
                failed++;
            }
        }
        
        lastProcessedIndex[roundId] = startIndex + actualSize;
        
        // 檢查是否全部分發完成
        if (lastProcessedIndex[roundId] >= batchTickets.length) {
            _finalizeRound(roundId);
        }
        
        return (distributed, failed);
    }
    
    // ========== ✅ V5.5：處理分發批次（保持不變）==========
    function _processDistributionBatch(uint256 roundId) internal returns (bool) {
        RoundData storage rd = rounds[roundId];
        
        if (rd.finalized) {
            return true;
        }
        
        // 每次處理一批（使用優化的批次大小）
        (, uint256 failed) = _executeBatchDistribution(roundId, OPTIMAL_BATCH_SIZE);
        
        // 檢查是否完成
        uint256[] storage allTickets = roundTickets[roundId];
        bool completed = (lastProcessedIndex[roundId] >= allTickets.length) && rd.finalized;
        
        if (completed) {
            emit PrizeDistributionCompleted(roundId, rd.totalDistributed, failed);
        }
        
        return completed;
    }
    
    // ========== ✅ 安全的自動處理系統（修改處理間隔和批次大小）==========
    function _autoCheckAndProcess() internal {
        if (currentRoundId == 0) return;
        
        // ✅ 修改點1：處理間隔從15秒改為5秒
        if (block.timestamp < lastAutoProcessTime[currentRoundId] + MAX_AUTO_PROCESS_INTERVAL) {
            return;
        }
        lastAutoProcessTime[currentRoundId] = block.timestamp;
        
        RoundTime storage rt = roundTimes[currentRoundId];
        RoundData storage rd = rounds[currentRoundId];
        
        // 自動關閉投注
        if (!rt.bettingClosed && block.timestamp >= rt.bettingEndTime) {
            rt.bettingClosed = true;
            emit BettingClosed(currentRoundId, block.timestamp);
        }
        
        // 自動開獎
        if (!rt.drawExecuted && !_drawInProgress && block.timestamp >= rt.drawTime) {
            _executeDraw(currentRoundId);
        }
        
        // 自動分發（防止重複觸發）
        if (rt.drawExecuted && !rd.finalized && rd.distributionDataReady && !_distributionInProgress) {
            _distributionInProgress = true;
            
            // ✅ 修改點2：使用優化的批次大小
            _processDistributionBatch(currentRoundId);
            
            _distributionInProgress = false;
        }
        
        // 自動回合切換
        uint256 calculatedRound = getCurrentRound(block.timestamp);
        if (calculatedRound > currentRoundId) {
            _handleRoundTransition(calculatedRound);
        }
        
        emit AutoProcessTriggered(msg.sender, currentRoundId, block.timestamp);
    }
    
    // ========== ✅ 新增：判斷回合是否需要處理（保持不變）==========
    function _shouldProcessRound(uint256 roundId) internal view returns (bool) {
        RoundTime storage rt = roundTimes[roundId];
        
        // 如果回合還沒設置時間，不需要處理
        if (rt.startTime == 0) {
            return false;
        }
        
        // 只有當回合已經過了投注期才需要處理
        return block.timestamp >= rt.bettingEndTime;
    }
    
    // ========== ✅ 新增：立即處理單個回合並轉移滾存（保持不變）==========
    function _processSingleRoundImmediate(uint256 roundId, uint256 targetRoundId) internal {
        RoundTime storage rt = roundTimes[roundId];
        RoundData storage rd = rounds[roundId];
        
        // 確保時間設置
        if (rt.startTime == 0) {
            _setupRoundTime(roundId);
        }
        
        // 補開獎（如果需要）
        if (block.timestamp >= rt.bettingEndTime && !rt.drawExecuted && !rd.finalized) {
            _executeDraw(roundId);
        }
        
        // 補結算（如果需要）
        if (rt.drawExecuted && !rd.finalized) {
            _finalizeRound(roundId);
        }
        
        // 立即轉移到目標回合
        if (rd.finalized && !rd.rolloverTransferred) {
            _transferRolloverToNextRound(roundId, targetRoundId);
        }
    }
    
    // ========== ✅ V5.5：Gas 安全的回合切換（保持不變）==========
    function _handleRoundTransition(uint256 newRoundId) internal {
        require(newRoundId > currentRoundId, "New round must be later");
        
        // Gas保護：限制最大處理跳過的回合數
        uint256 maxRoundsToProcess = 10;
        uint256 roundsProcessed = 0;

        // 1. 處理並轉移「當前回合」的資金
        if (currentRoundId > 0) {
            _processSingleRoundImmediate(currentRoundId, newRoundId);
            roundsProcessed++;
        }
        
        // 2. 處理「跳過的中間回合」
        for (uint256 i = currentRoundId + 1; 
             i < newRoundId && roundsProcessed < maxRoundsToProcess; 
             i++) 
        {
            if (_shouldProcessRound(i)) {
                _processSingleRoundImmediate(i, newRoundId);
                roundsProcessed++;
            } else {
                // 如果該回合還沒開始，只需初始化時間
                if (roundTimes[i].startTime == 0) {
                    _setupRoundTime(i);
                }
            }
        }
        
        // 3. 切換到新回合
        currentRoundId = newRoundId;
        _setupRoundTime(newRoundId);
        emit RoundStarted(newRoundId, block.timestamp);
    }
    
    // ========== 開獎相關函數（保持不變）==========
    function _executeDraw(uint256 roundId) internal {
        require(!roundTimes[roundId].drawExecuted, "Already drawn");
        require(!_drawInProgress, "Draw in progress");
        
        _drawInProgress = true;
        
        if (!roundTimes[roundId].bettingClosed) {
            roundTimes[roundId].bettingClosed = true;
            emit BettingClosed(roundId, block.timestamp);
        }
        
        // 生成中獎號碼
        uint256[5] memory winningNumbers = _generateWinningNumbers();
        rounds[roundId].winningNumbers = winningNumbers;
        
        // 計算獲獎者
        _calculateWinners(roundId, winningNumbers);
        
        // 計算獎金
        _calculateAndUpdatePrizes(roundId);
        
        // 更新狀態
        roundTimes[roundId].drawExecuted = true;
        roundTimes[roundId].drawBlockNumber = block.number;
        rounds[roundId].distributionDataReady = true;
        
        emit DrawExecuted(roundId, winningNumbers);
        emit DrawDataReady(roundId);
        
        _drawInProgress = false;
    }
    
    function _generateWinningNumbers() internal returns (uint256[5] memory) {
        _randomNonce++;
        
        bytes32 randomSeed = keccak256(abi.encodePacked(
            blockhash(block.number - 3),
            blockhash(block.number - 7),
            blockhash(block.number - 13),
            uint256(blockhash(block.number - 1)) & 0xFFFF,
            currentRoundId,
            _randomNonce
        ));
        
        uint256[5] memory numbers;
        bool[39] memory used;
        
        for (uint256 i = 0; i < NUMBERS_TO_DRAW; i++) {
            uint256 random = uint256(keccak256(abi.encodePacked(randomSeed, i)));
            uint256 remaining = MAX_NUMBER - MIN_NUMBER + 1 - i;
            uint256 index = random % remaining;
            
            uint256 count = 0;
            for (uint256 j = MIN_NUMBER; j <= MAX_NUMBER; j++) {
                if (!used[j - MIN_NUMBER]) {
                    if (count == index) {
                        numbers[i] = j;
                        used[j - MIN_NUMBER] = true;
                        break;
                    }
                    count++;
                }
            }
        }
        
        _sortNumbers(numbers);
        emit RandomNumbersGenerated(currentRoundId, randomSeed, numbers);
        
        return numbers;
    }
    
    function _sortNumbers(uint256[5] memory numbers) internal pure {
        for (uint256 i = 0; i < NUMBERS_TO_DRAW - 1; i++) {
            for (uint256 j = i + 1; j < NUMBERS_TO_DRAW; j++) {
                if (numbers[i] > numbers[j]) {
                    (numbers[i], numbers[j]) = (numbers[j], numbers[i]);
                }
            }
        }
    }
    
    function _calculateWinners(uint256 roundId, uint256[5] memory winningNumbers) internal {
        uint256[] storage ticketIds = roundTickets[roundId];
        uint64 winningBitmap = 0;
        
        for (uint256 i = 0; i < 5; i++) {
            winningBitmap |= uint64(1) << uint8(winningNumbers[i] - 1);
        }
        
        for (uint256 i = 0; i < ticketIds.length; i++) {
            uint256 ticketId = ticketIds[i];
            Ticket storage ticket = tickets[ticketId];
            uint64 matched = ticket.numbersBitmap & winningBitmap;
            uint8 matches = 0;
            
            while (matched != 0) {
                matched &= matched - 1;
                matches++;
            }
            
            if (matches == 5) {
                rounds[roundId].winnerCounts[0]++;
                ticket.prizeLevel = PRIZE_LEVEL_FIRST;
            } else if (matches == 4) {
                rounds[roundId].winnerCounts[1]++;
                ticket.prizeLevel = PRIZE_LEVEL_SECOND;
            } else if (matches == 3) {
                rounds[roundId].winnerCounts[2]++;
                ticket.prizeLevel = PRIZE_LEVEL_THIRD;
            } else if (matches == 2) {
                rounds[roundId].winnerCounts[3]++;
                ticket.prizeLevel = PRIZE_LEVEL_FOURTH;
            }
        }
    }
    
    // ========== 公開購買函數（保持不變）==========
    function buyTicket(uint8[5] calldata numbers) 
        external 
        whenNotPaused 
        onlyDuringBettingPeriod
        autoProcess
    {
        _validateNumbers(numbers);
        _processSingleTicketPurchase(msg.sender, numbers);
    }
    
    function buyMultipleTickets(uint8[5][] calldata numbersList) 
        external 
        whenNotPaused 
        onlyDuringBettingPeriod
        autoProcess
    {
        uint256 count = numbersList.length;
        require(count > 0 && count <= MAX_BATCH_PURCHASE, "Invalid count");
        
        uint256 currentCount = playerRoundTicketCount[msg.sender][currentRoundId];
        require(currentCount + count <= MAX_TICKETS_PER_PLAYER, "Exceeds max tickets");  // ✅ 自動使用新設定的1000上限
        
        uint256 totalAmount = TICKET_PRICE * count;
        uint256 newPrizePool = rounds[currentRoundId].prizePool + totalAmount;
        require(newPrizePool <= MAX_POOL_SIZE, "Pool limit reached");
        
        // ✅ 使用低級調用，手動檢查是否成功
        // 1. 編碼函數調用數據
        bytes memory data = abi.encodeWithSelector(
            IERC20.transferFrom.selector, 
            msg.sender, 
            address(this), 
            totalAmount
        );
        
        // 2. 發起調用 (不依賴 interface 的返回值定義)
        (bool success, bytes memory returndata) = address(usdtToken).call(data);
        
        // 3. 雙重驗證：
        //    條件一：調用本身沒有報錯 (success 為真)
        //    條件二：如果對方有返回值，返回值解碼後必須為 true；如果對方沒返回值(長度0)，也算成功。
        require(
            success && (returndata.length == 0 || abi.decode(returndata, (bool))), 
            "Transfer failed: Low-level call"
        );
        
        rounds[currentRoundId].prizePool = newPrizePool;
        
        uint256 firstTicketId = _nextTicketId;
        for (uint256 i = 0; i < count; i++) {
            _validateNumbers(numbersList[i]);
            _createSingleTicket(msg.sender, numbersList[i], currentRoundId);
        }
        
        playerRoundTicketCount[msg.sender][currentRoundId] += count;
        rounds[currentRoundId].totalTickets += count;
        
        emit BatchPurchased(msg.sender, firstTicketId, count, totalAmount);
    }
    
    // ========== 輔助函數（保持不變）==========
    function _validateNumbers(uint8[5] memory numbers) internal pure {
        uint64 bitmap = 0;
        for (uint256 i = 0; i < 5; i++) {
            require(numbers[i] >= MIN_NUMBER && numbers[i] <= MAX_NUMBER, "Invalid number");
            uint64 bit = uint64(1) << uint8(numbers[i] - 1);
            require((bitmap & bit) == 0, "Duplicate number");
            bitmap |= bit;
        }
    }
    
    function _processSingleTicketPurchase(address player, uint8[5] memory numbers) internal {
        require(playerRoundTicketCount[player][currentRoundId] + 1 <= MAX_TICKETS_PER_PLAYER, "Exceeds max tickets");  // ✅ 自動使用新設定的1000上限
        
        uint256 totalAmount = TICKET_PRICE;
        uint256 newPrizePool = rounds[currentRoundId].prizePool + totalAmount;
        require(newPrizePool <= MAX_POOL_SIZE, "Pool limit reached");
        
        // ✅ 使用低級調用，手動檢查是否成功
        // 1. 編碼函數調用數據
        bytes memory data = abi.encodeWithSelector(
            IERC20.transferFrom.selector, 
            player, 
            address(this), 
            totalAmount
        );
        
        // 2. 發起調用 (不依賴 interface 的返回值定義)
        (bool success, bytes memory returndata) = address(usdtToken).call(data);
        
        // 3. 雙重驗證：
        //    條件一：調用本身沒有報錯 (success 為真)
        //    條件二：如果對方有返回值，返回值解碼後必須為 true；如果對方沒返回值(長度0)，也算成功。
        require(
            success && (returndata.length == 0 || abi.decode(returndata, (bool))), 
            "Transfer failed: Low-level call"
        );
        
        rounds[currentRoundId].prizePool = newPrizePool;
        
        _createSingleTicket(player, numbers, currentRoundId);
        playerRoundTicketCount[player][currentRoundId] += 1;
        rounds[currentRoundId].totalTickets += 1;
    }
    
    function _createSingleTicket(address player, uint8[5] memory numbers, uint256 roundId) internal {
        uint64 bitmap = 0;
        for (uint256 i = 0; i < 5; i++) {
            bitmap |= uint64(1) << uint8(numbers[i] - 1);
        }
        
        uint256 ticketId = _nextTicketId;
        _nextTicketId = _nextTicketId + 1;
        
        tickets[ticketId] = Ticket({
            player: player,
            numbersBitmap: bitmap,
            roundId: uint32(roundId),
            prizeLevel: PRIZE_LEVEL_NONE,
            claimed: false
        });
        roundTickets[roundId].push(ticketId);
        emit TicketPurchased(player, ticketId, roundId);
    }
    
    // ========== 管理功能（保持不變）==========
    function pause() external onlyOwner whenNotPaused {
        isPaused = true;
    }
    
    function unpause() external onlyOwner whenPaused {
        isPaused = false;
    }
    
    function manualExecuteDraw() external onlyOwner whenNotPaused autoProcess {
        require(canDraw(currentRoundId), "Draw not allowed yet");
        _executeDraw(currentRoundId);
    }
    
    function continueDistribution(uint256 roundId) external onlyOwner whenNotPaused autoProcess {
        require(!_distributionInProgress, "Distribution in progress");
        require(roundTimes[roundId].drawExecuted, "Draw not executed");
        require(!rounds[roundId].finalized, "Already finalized");
        require(block.timestamp < roundTimes[roundId].processingEndTime, "Processing period ended");
        
        _distributionInProgress = true;
        bool completed = _processDistributionBatch(roundId);
        _distributionInProgress = false;
        
        if (completed) {
            emit PrizeDistributionCompleted(roundId, rounds[roundId].totalDistributed, 0);
        }
    }
    
    function injectFunds(uint256 amount) external onlyOwner whenNotPaused {
        require(amount > 0, "Zero amount");
        
        // 🛡️ 只能在投注期間注入
        RoundTime storage rt = roundTimes[currentRoundId];
        require(
            block.timestamp >= rt.startTime && 
            block.timestamp < rt.bettingEndTime &&
            !rt.bettingClosed,
            "Funds can only be injected during active betting period"
        );
        
        // ✅ 使用低級調用，手動檢查是否成功
        // 1. 編碼函數調用數據
        bytes memory data = abi.encodeWithSelector(
            IERC20.transferFrom.selector, 
            msg.sender, 
            address(this), 
            amount
        );
        
        // 2. 發起調用 (不依賴 interface 的返回值定義)
        (bool success, bytes memory returndata) = address(usdtToken).call(data);
        
        // 3. 雙重驗證：
        //    條件一：調用本身沒有報錯 (success 為真)
        //    條件二：如果對方有返回值，返回值解碼後必須為 true；如果對方沒返回值(長度0)，也算成功。
        require(
            success && (returndata.length == 0 || abi.decode(returndata, (bool))), 
            "Transfer failed: Low-level call"
        );
        
        uint256 newPrizePool = rounds[currentRoundId].prizePool + amount;
        require(newPrizePool <= MAX_POOL_SIZE, "Pool limit reached");
        
        rounds[currentRoundId].prizePool = newPrizePool;
    }
    
    function withdrawExcessFunds(uint256 amount) external onlyOwner {
        (bool isSafe, uint256 totalPrizePools, uint256 contractBalance, ) = checkFundSafety();
        require(isSafe, "Funds not safe");
        
        uint256 excess = contractBalance - totalPrizePools;
        require(amount <= excess, "Amount exceeds excess funds");
        
        // ✅ 使用低級調用，手動檢查是否成功
        // 1. 編碼函數調用數據
        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, amount);
        
        // 2. 發起調用 (不依賴 interface 的返回值定義)
        (bool success, bytes memory returndata) = address(usdtToken).call(data);
        
        // 3. 雙重驗證：
        //    條件一：調用本身沒有報錯 (success 為真)
        //    條件二：如果對方有返回值，返回值解碼後必須為 true；如果對方沒返回值(長度0)，也算成功。
        require(
            success && (returndata.length == 0 || abi.decode(returndata, (bool))), 
            "Transfer failed: Low-level call"
        );
    }
    
    function manualTransitionToNextRound() external onlyOwner autoProcess {
        uint256 nextRoundId = currentRoundId + 1;
        _handleRoundTransition(nextRoundId);
    }
    
    function forceDrawNumbers(uint256 roundId) external onlyOwner autoProcess {
        RoundTime storage rt = roundTimes[roundId];
        require(!rt.drawExecuted, "Numbers already drawn");
        require(!_drawInProgress, "Draw in progress");
        
        _executeDraw(roundId);
    }
    
    // ========== 視圖函數（保持不變）==========
    function canDraw(uint256 roundId) public view returns (bool) {
        if (roundId == 0) return false;
        
        RoundTime storage rt = roundTimes[roundId];
        return (!rt.drawExecuted && block.timestamp >= rt.drawTime);
    }
    
    function getCurrentPhase() public view returns (string memory phase, uint256 timeRemaining) {
        if (currentRoundId == 0) {
            return ("NOT_STARTED", 0);
        }
        
        RoundTime storage rt = roundTimes[currentRoundId];
        uint256 now_ = block.timestamp;
        
        if (isBettingPeriod()) {
            phase = "BETTING";
            timeRemaining = rt.bettingEndTime > now_ ? rt.bettingEndTime - now_ : 0;
        } else if (now_ < rt.drawTime) {
            phase = "DRAW_PENDING";
            timeRemaining = rt.drawTime > now_ ? rt.drawTime - now_ : 0;
        } else if (now_ < rt.processingEndTime) {
            phase = "PROCESSING";
            timeRemaining = rt.processingEndTime > now_ ? rt.processingEndTime - now_ : 0;
        } else {
            phase = "COMPLETED";
            timeRemaining = 0;
        }
    }
    
    function getNextDrawTime() public view returns (uint256 nextDrawTime) {
        if (currentRoundId == 0) {
            (, , nextDrawTime, ) = getRoundSchedule(1);
        } else {
            RoundTime storage rt = roundTimes[currentRoundId];
            
            if (rt.drawExecuted || block.timestamp >= rt.processingEndTime) {
                (, , nextDrawTime, ) = getRoundSchedule(currentRoundId + 1);
            } else if (block.timestamp >= rt.drawTime) {
                return block.timestamp;
            } else {
                return rt.drawTime;
            }
        }
    }
    
    function checkFundsIntegrity(uint256 roundId) public view returns (
        bool consistent,
        string memory message
    ) {
        RoundData storage rd = rounds[roundId];
        
        // ✅ V5.8 驗證：對於已結算回合，rolloverAmount 應該等於合約餘額
        if (rd.finalized) {
            uint256 actualBalance = usdtToken.balanceOf(address(this));
            // 允許1U的誤差
            consistent = (actualBalance + 10**6 >= rd.rolloverAmount) && 
                         (actualBalance <= rd.rolloverAmount + 10**6);
        } else {
            // 未結算回合：使用 prizePool 作為資金來源
            uint256 expectedBalance = rd.prizePool;
            uint256 actualBalance = usdtToken.balanceOf(address(this));
            
            // 允許1U的誤差
            consistent = (actualBalance + 10**6 >= expectedBalance) && 
                         (actualBalance <= expectedBalance + 10**6);
        }
        
        if (!consistent) {
            message = "Funds mismatch detected";
        } else {
            message = "Funds are consistent";
        }
    }
    
    function healthCheck() external returns (
        bool isHealthy,
        string memory message,
        uint256 delayedRounds,
        uint256 nextDrawIn
    ) {
        uint256 currentRound = getCurrentRound(block.timestamp);
        delayedRounds = 0;
        
        for (uint256 roundId = 1; roundId <= currentRound; roundId++) {
            RoundTime storage rt = roundTimes[roundId];
            (, , uint256 drawTime, ) = getRoundSchedule(roundId);
            
            if (block.timestamp >= drawTime && !rt.drawExecuted) {
                delayedRounds++;
            }
        }
        
        if (currentRoundId > 0) {
            (, , uint256 nextDraw, ) = getRoundSchedule(currentRoundId);
            nextDrawIn = nextDraw > block.timestamp ? nextDraw - block.timestamp : 0;
        } else {
            nextDrawIn = 0;
        }
        
        bool fundsSafe;
        try this.checkFundSafety() {
            fundsSafe = true;
        } catch {
            fundsSafe = false;
        }
        
        if (delayedRounds == 0 && fundsSafe) {
            return (true, "System is healthy", 0, nextDrawIn);
        } else if (delayedRounds == 1) {
            return (false, "One round is delayed", 1, nextDrawIn);
        } else if (!fundsSafe) {
            return (false, "Fund safety check failed", delayedRounds, nextDrawIn);
        } else {
            return (false, "Multiple rounds delayed", delayedRounds, nextDrawIn);
        }
    }
    
    function getRoundInfo(uint256 roundId) external view returns (
        uint256 startTime,
        uint256 bettingEndTime,
        uint256 drawTime,
        uint256 processingEndTime,
        uint256 totalTickets,
        uint256 prizePool,
        bool numbersDrawn,
        uint256[5] memory winningNumbers
    ) {
        require(roundId > 0, "Invalid round ID");
        
        RoundTime storage rt = roundTimes[roundId];
        RoundData storage rd = rounds[roundId];
        
        startTime = rt.startTime;
        bettingEndTime = rt.bettingEndTime;
        drawTime = rt.drawTime;
        processingEndTime = rt.processingEndTime;
        totalTickets = rd.totalTickets;
        prizePool = rd.prizePool;
        numbersDrawn = rt.drawExecuted;
        winningNumbers = rd.winningNumbers;
    }
    
    function getRoundPrizeStats(uint256 roundId) 
        external 
        view 
        returns (PrizeStats memory stats)
    {
        require(roundId > 0, "Invalid round ID");
        RoundData storage rd = rounds[roundId];
        
        stats = PrizeStats({
            firstWinners: rd.winnerCounts[0],
            secondWinners: rd.winnerCounts[1],
            thirdWinners: rd.winnerCounts[2],
            fourthWinners: rd.winnerCounts[3],
            firstPrize: rd.prizeAmounts[0],
            secondPrize: rd.prizeAmounts[1],
            thirdPrize: rd.prizeAmounts[2],
            fourthPrize: rd.prizeAmounts[3],
            firstDistributed: rd.distributed[0],
            secondDistributed: rd.distributed[1],
            thirdDistributed: rd.distributed[2],
            fourthDistributed: rd.distributed[3],
            rolloverAmount: rd.rolloverAmount,
            thirdCapped: rd.thirdPrizeCapped,
            fourthCapped: rd.fourthPrizeCapped
        });
        
        return stats;
    }
    
    function getTicketInfo(uint256 ticketId) external view returns (
        address player,
        uint256 roundId,
        uint8[5] memory numbers,
        uint8 prizeLevel,
        bool claimed
    ) {
        Ticket storage ticket = tickets[ticketId];
        require(ticket.player != address(0), "Ticket does not exist");
        
        player = ticket.player;
        roundId = ticket.roundId;
        prizeLevel = ticket.prizeLevel;
        claimed = ticket.claimed;
        
        uint64 bitmap = ticket.numbersBitmap;
        uint8 index = 0;
        for (uint8 i = 1; i <= 39; i++) {
            if ((bitmap & (uint64(1) << (i - 1))) != 0) {
                numbers[index] = i;
                index++;
                if (index >= 5) break;
            }
        }
    }
    
    function getRoundWinningNumbers(uint256 roundId) public view returns (uint256[5] memory) {
        require(rounds[roundId].winningNumbers[0] != 0, "Numbers not drawn yet");
        return rounds[roundId].winningNumbers;
    }
    
    function getPlayerTickets(address player, uint256 roundId) external view returns (uint256[] memory) {
        uint256[] memory playerTickets = new uint256[](playerRoundTicketCount[player][roundId]);
        uint256 count = 0;
        
        uint256[] storage allTickets = roundTickets[roundId];
        for (uint256 i = 0; i < allTickets.length; i++) {
            if (tickets[allTickets[i]].player == player) {
                playerTickets[count] = allTickets[i];
                count++;
            }
        }
        
        return playerTickets;
    }
    
    function triggerAutoProcess() external whenNotPaused {
        _autoCheckAndProcess();
    }
    
    function getCurrentTimestamp() external view returns (uint256) {
        return block.timestamp;
    }
    
    function getDeploymentTime() external view returns (uint256) {
        return DEPLOYMENT_TIMESTAMP;
    }
    
    function getFixedPrizeAmount(uint8 prizeLevel) public pure returns (uint256) {
        if (prizeLevel == PRIZE_LEVEL_THIRD) {
            return THIRD_PRIZE;
        } else if (prizeLevel == PRIZE_LEVEL_FOURTH) {
            return FOURTH_PRIZE;
        }
        return 0;
    }
    
    // ========== ✅ V5.5：檢查分發hash（保持不變）==========
    function checkDistributionHash(
        uint256 roundId,
        uint256 ticketId,
        address player,
        uint8 prizeLevel
    ) public view returns (bool distributed) {
        bytes32 hash = _getDistributionHash(roundId, ticketId, player, prizeLevel);
        return _distributionHashes[hash];
    }
    
    // ========== ✅ V5.8：資金一致性驗證（更新註釋）==========
    function verifyFundsConsistency(uint256 roundId) public view returns (bool) {
        RoundData storage rd = rounds[roundId];
        
        if (rd.finalized) {
            // ✅ V5.8：已結算回合：rolloverAmount 應等於合約餘額
            uint256 actualBalance = usdtToken.balanceOf(address(this));
            return (actualBalance == rd.rolloverAmount);
        } else {
            // 未結算回合：使用 prizePool 作為總資金
            return true;
        }
    }
    
    // ========== 接收ETH/MATIC（保持不變）==========
    receive() external payable {}
}