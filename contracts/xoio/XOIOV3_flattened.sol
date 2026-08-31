// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============ FLATTENED SOURCE (Polygonscan 驗證用) ============
// 合約: XOIOV3 — Chainlink VRF 單雙遊戲
// 包含: @chainlink/contracts VRF v2.5 + @openzeppelin/contracts IERC20

interface IOwnable {
  function owner() external returns (address);

  function transferOwnership(
    address recipient
  ) external;

  function acceptOwnership() external;
}

/// @title The ConfirmedOwner contract
/// @notice A contract with helpers for basic contract ownership.
contract ConfirmedOwnerWithProposal is IOwnable {
  address private s_owner;
  address private s_pendingOwner;

  event OwnershipTransferRequested(address indexed from, address indexed to);
  event OwnershipTransferred(address indexed from, address indexed to);

  constructor(address newOwner, address pendingOwner) {
    // solhint-disable-next-line gas-custom-errors
    require(newOwner != address(0), "Cannot set owner to zero");

    s_owner = newOwner;
    if (pendingOwner != address(0)) {
      _transferOwnership(pendingOwner);
    }
  }

  /// @notice Allows an owner to begin transferring ownership to a new address.
  function transferOwnership(
    address to
  ) public override onlyOwner {
    _transferOwnership(to);
  }

  /// @notice Allows an ownership transfer to be completed by the recipient.
  function acceptOwnership() external override {
    // solhint-disable-next-line gas-custom-errors
    require(msg.sender == s_pendingOwner, "Must be proposed owner");

    address oldOwner = s_owner;
    s_owner = msg.sender;
    s_pendingOwner = address(0);

    emit OwnershipTransferred(oldOwner, msg.sender);
  }

  /// @notice Get the current owner
  function owner() public view override returns (address) {
    return s_owner;
  }

  /// @notice validate, transfer ownership, and emit relevant events
  function _transferOwnership(
    address to
  ) private {
    // solhint-disable-next-line gas-custom-errors
    require(to != msg.sender, "Cannot transfer to self");

    s_pendingOwner = to;

    emit OwnershipTransferRequested(s_owner, to);
  }

  /// @notice validate access
  function _validateOwnership() internal view {
    // solhint-disable-next-line gas-custom-errors
    require(msg.sender == s_owner, "Only callable by owner");
  }

  /// @notice Reverts if called by anyone other than the contract owner.
  modifier onlyOwner() {
    _validateOwnership();
    _;
  }
}

/// @title The ConfirmedOwner contract
/// @notice A contract with helpers for basic contract ownership.
contract ConfirmedOwner is ConfirmedOwnerWithProposal {
  constructor(
    address newOwner
  ) ConfirmedOwnerWithProposal(newOwner, address(0)) {}
}

// End consumer library.
library VRFV2PlusClient {
  // extraArgs will evolve to support new features
  bytes4 public constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));

  struct ExtraArgsV1 {
    bool nativePayment;
  }

  struct RandomWordsRequest {
    bytes32 keyHash;
    uint256 subId;
    uint16 requestConfirmations;
    uint32 callbackGasLimit;
    uint32 numWords;
    bytes extraArgs;
  }

  function _argsToBytes(
    ExtraArgsV1 memory extraArgs
  ) internal pure returns (bytes memory bts) {
    return abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, extraArgs);
  }
}

/// @notice The IVRFSubscriptionV2Plus interface defines the subscription
/// @notice related methods implemented by the V2Plus coordinator.
interface IVRFSubscriptionV2Plus {
  /**
   * @notice Add a consumer to a VRF subscription.
   * @param subId - ID of the subscription
   * @param consumer - New consumer which can use the subscription
   */
  function addConsumer(uint256 subId, address consumer) external;

  /**
   * @notice Remove a consumer from a VRF subscription.
   * @param subId - ID of the subscription
   * @param consumer - Consumer to remove from the subscription
   */
  function removeConsumer(uint256 subId, address consumer) external;

  /**
   * @notice Cancel a subscription
   * @param subId - ID of the subscription
   * @param to - Where to send the remaining LINK to
   */
  function cancelSubscription(uint256 subId, address to) external;

  /**
   * @notice Accept subscription owner transfer.
   * @param subId - ID of the subscription
   * @dev will revert if original owner of subId has
   * not requested that msg.sender become the new owner.
   */
  function acceptSubscriptionOwnerTransfer(
    uint256 subId
  ) external;

  /**
   * @notice Request subscription owner transfer.
   * @param subId - ID of the subscription
   * @param newOwner - proposed new owner of the subscription
   */
  function requestSubscriptionOwnerTransfer(uint256 subId, address newOwner) external;

  /**
   * @notice Create a VRF subscription.
   * @return subId - A unique subscription id.
   * @dev You can manage the consumer set dynamically with addConsumer/removeConsumer.
   * @dev Note to fund the subscription with LINK, use transferAndCall. For example
   * @dev  LINKTOKEN.transferAndCall(
   * @dev    address(COORDINATOR),
   * @dev    amount,
   * @dev    abi.encode(subId));
   * @dev Note to fund the subscription with Native, use fundSubscriptionWithNative. Be sure
   * @dev  to send Native with the call, for example:
   * @dev COORDINATOR.fundSubscriptionWithNative{value: amount}(subId);
   */
  function createSubscription() external returns (uint256 subId);

  /**
   * @notice Get a VRF subscription.
   * @param subId - ID of the subscription
   * @return balance - LINK balance of the subscription in juels.
   * @return nativeBalance - native balance of the subscription in wei.
   * @return reqCount - Requests count of subscription.
   * @return owner - owner of the subscription.
   * @return consumers - list of consumer address which are able to use this subscription.
   */
  function getSubscription(
    uint256 subId
  )
    external
    view
    returns (uint96 balance, uint96 nativeBalance, uint64 reqCount, address owner, address[] memory consumers);

  /*
   * @notice Check to see if there exists a request commitment consumers
   * for all consumers and keyhashes for a given sub.
   * @param subId - ID of the subscription
   * @return true if there exists at least one unfulfilled request for the subscription, false
   * otherwise.
   */
  function pendingRequestExists(
    uint256 subId
  ) external view returns (bool);

  /**
   * @notice Paginate through all active VRF subscriptions.
   * @param startIndex index of the subscription to start from
   * @param maxCount maximum number of subscriptions to return, 0 to return all
   * @dev the order of IDs in the list is **not guaranteed**, therefore, if making successive calls, one
   * @dev should consider keeping the blockheight constant to ensure a holistic picture of the contract state
   */
  function getActiveSubscriptionIds(uint256 startIndex, uint256 maxCount) external view returns (uint256[] memory);

  /**
   * @notice Fund a subscription with native.
   * @param subId - ID of the subscription
   * @notice This method expects msg.value to be greater than or equal to 0.
   */
  function fundSubscriptionWithNative(
    uint256 subId
  ) external payable;
}

// Interface that enables consumers of VRFCoordinatorV2Plus to be future-proof for upgrades
// This interface is supported by subsequent versions of VRFCoordinatorV2Plus
interface IVRFCoordinatorV2Plus is IVRFSubscriptionV2Plus {
  /**
   * @notice Request a set of random words.
   * @param req - a struct containing following fields for randomness request:
   * keyHash - Corresponds to a particular oracle job which uses
   * that key for generating the VRF proof. Different keyHash's have different gas price
   * ceilings, so you can select a specific one to bound your maximum per request cost.
   * subId  - The ID of the VRF subscription. Must be funded
   * with the minimum subscription balance required for the selected keyHash.
   * requestConfirmations - How many blocks you'd like the
   * oracle to wait before responding to the request. See SECURITY CONSIDERATIONS
   * for why you may want to request more. The acceptable range is
   * [minimumRequestBlockConfirmations, 200].
   * callbackGasLimit - How much gas you'd like to receive in your
   * fulfillRandomWords callback. Note that gasleft() inside fulfillRandomWords
   * may be slightly less than this amount because of gas used calling the function
   * (argument decoding etc.), so you may need to request slightly more than you expect
   * to have inside fulfillRandomWords. The acceptable range is
   * [0, maxGasLimit]
   * numWords - The number of uint256 random values you'd like to receive
   * in your fulfillRandomWords callback. Note these numbers are expanded in a
   * secure way by the VRFCoordinator from a single random value supplied by the oracle.
   * extraArgs - abi-encoded extra args
   * @return requestId - A unique identifier of the request. Can be used to match
   * a request to a response in fulfillRandomWords.
   */
  function requestRandomWords(
    VRFV2PlusClient.RandomWordsRequest calldata req
  ) external returns (uint256 requestId);
}

/// @notice The IVRFMigratableConsumerV2Plus interface defines the
/// @notice method required to be implemented by all V2Plus consumers.
/// @dev This interface is designed to be used in VRFConsumerBaseV2Plus.
interface IVRFMigratableConsumerV2Plus {
  event CoordinatorSet(address vrfCoordinator);

  /// @notice Sets the VRF Coordinator address
  /// @notice This method should only be callable by the coordinator or contract owner
  function setCoordinator(
    address vrfCoordinator
  ) external;
}

/**
 *
 * @notice Interface for contracts using VRF randomness
 * *****************************************************************************
 * @dev PURPOSE
 *
 * @dev Reggie the Random Oracle (not his real job) wants to provide randomness
 * @dev to Vera the verifier in such a way that Vera can be sure he's not
 * @dev making his output up to suit himself. Reggie provides Vera a public key
 * @dev to which he knows the secret key. Each time Vera provides a seed to
 * @dev Reggie, he gives back a value which is computed completely
 * @dev deterministically from the seed and the secret key.
 *
 * @dev Reggie provides a proof by which Vera can verify that the output was
 * @dev correctly computed once Reggie tells it to her, but without that proof,
 * @dev the output is indistinguishable to her from a uniform random sample
 * @dev from the output space.
 *
 * @dev The purpose of this contract is to make it easy for unrelated contracts
 * @dev to talk to Vera the verifier about the work Reggie is doing, to provide
 * @dev simple access to a verifiable source of randomness. It ensures 2 things:
 * @dev 1. The fulfillment came from the VRFCoordinatorV2Plus.
 * @dev 2. The consumer contract implements fulfillRandomWords.
 * *****************************************************************************
 * @dev USAGE
 *
 * @dev Calling contracts must inherit from VRFConsumerBaseV2Plus, and can
 * @dev initialize VRFConsumerBaseV2Plus's attributes in their constructor as
 * @dev shown:
 *
 * @dev   contract VRFConsumerV2Plus is VRFConsumerBaseV2Plus {
 * @dev     constructor(<other arguments>, address _vrfCoordinator, address _subOwner)
 * @dev       VRFConsumerBaseV2Plus(_vrfCoordinator, _subOwner) public {
 * @dev         <initialization with other arguments goes here>
 * @dev       }
 * @dev   }
 *
 * @dev The oracle will have given you an ID for the VRF keypair they have
 * @dev committed to (let's call it keyHash). Create a subscription, fund it
 * @dev and your consumer contract as a consumer of it (see VRFCoordinatorInterface
 * @dev subscription management functions).
 * @dev Call requestRandomWords(keyHash, subId, minimumRequestConfirmations,
 * @dev callbackGasLimit, numWords, extraArgs),
 * @dev see (IVRFCoordinatorV2Plus for a description of the arguments).
 *
 * @dev Once the VRFCoordinatorV2Plus has received and validated the oracle's response
 * @dev to your request, it will call your contract's fulfillRandomWords method.
 *
 * @dev The randomness argument to fulfillRandomWords is a set of random words
 * @dev generated from your requestId and the blockHash of the request.
 *
 * @dev If your contract could have concurrent requests open, you can use the
 * @dev requestId returned from requestRandomWords to track which response is associated
 * @dev with which randomness request.
 * @dev See "SECURITY CONSIDERATIONS" for principles to keep in mind,
 * @dev if your contract could have multiple requests in flight simultaneously.
 *
 * @dev Colliding `requestId`s are cryptographically impossible as long as seeds
 * @dev differ.
 *
 * *****************************************************************************
 * @dev SECURITY CONSIDERATIONS
 *
 * @dev A method with the ability to call your fulfillRandomness method directly
 * @dev could spoof a VRF response with any random value, so it's critical that
 * @dev it cannot be directly called by anything other than this base contract
 * @dev (specifically, by the VRFConsumerBaseV2Plus.rawFulfillRandomness method).
 *
 * @dev For your users to trust that your contract's random behavior is free
 * @dev from malicious interference, it's best if you can write it so that all
 * @dev behaviors implied by a VRF response are executed *during* your
 * @dev fulfillRandomness method. If your contract must store the response (or
 * @dev anything derived from it) and use it later, you must ensure that any
 * @dev user-significant behavior which depends on that stored value cannot be
 * @dev manipulated by a subsequent VRF request.
 *
 * @dev Similarly, both miners and the VRF oracle itself have some influence
 * @dev over the order in which VRF responses appear on the blockchain, so if
 * @dev your contract could have multiple VRF requests in flight simultaneously,
 * @dev you must ensure that the order in which the VRF responses arrive cannot
 * @dev be used to manipulate your contract's user-significant behavior.
 *
 * @dev Since the block hash of the block which contains the requestRandomness
 * @dev call is mixed into the input to the VRF *last*, a sufficiently powerful
 * @dev miner could, in principle, fork the blockchain to evict the block
 * @dev containing the request, forcing the request to be included in a
 * @dev different block with a different hash, and therefore a different input
 * @dev to the VRF. However, such an attack would incur a substantial economic
 * @dev cost. This cost scales with the number of blocks the VRF oracle waits
 * @dev until it calls responds to a request. It is for this reason that
 * @dev that you can signal to an oracle you'd like them to wait longer before
 * @dev responding to the request (however this is not enforced in the contract
 * @dev and so remains effective only in the case of unmodified oracle software).
 */
abstract contract VRFConsumerBaseV2Plus is IVRFMigratableConsumerV2Plus, ConfirmedOwner {
  error OnlyCoordinatorCanFulfill(address have, address want);
  error OnlyOwnerOrCoordinator(address have, address owner, address coordinator);
  error ZeroAddress();

  // s_vrfCoordinator should be used by consumers to make requests to vrfCoordinator
  // so that coordinator reference is updated after migration
  IVRFCoordinatorV2Plus public s_vrfCoordinator;

  /**
   * @param _vrfCoordinator address of VRFCoordinator contract
   */
  constructor(
    address _vrfCoordinator
  ) ConfirmedOwner(msg.sender) {
    if (_vrfCoordinator == address(0)) {
      revert ZeroAddress();
    }
    s_vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinator);
  }

  /**
   * @notice fulfillRandomness handles the VRF response. Your contract must
   * @notice implement it. See "SECURITY CONSIDERATIONS" above for important
   * @notice principles to keep in mind when implementing your fulfillRandomness
   * @notice method.
   *
   * @dev VRFConsumerBaseV2Plus expects its subcontracts to have a method with this
   * @dev signature, and will call it once it has verified the proof
   * @dev associated with the randomness. (It is triggered via a call to
   * @dev rawFulfillRandomness, below.)
   *
   * @param requestId The Id initially returned by requestRandomness
   * @param randomWords the VRF output expanded to the requested number of words
   */
  // solhint-disable-next-line chainlink-solidity/prefix-internal-functions-with-underscore
  function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal virtual;

  // rawFulfillRandomness is called by VRFCoordinator when it receives a valid VRF
  // proof. rawFulfillRandomness then calls fulfillRandomness, after validating
  // the origin of the call
  function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
    if (msg.sender != address(s_vrfCoordinator)) {
      revert OnlyCoordinatorCanFulfill(msg.sender, address(s_vrfCoordinator));
    }
    fulfillRandomWords(requestId, randomWords);
  }

  /**
   * @inheritdoc IVRFMigratableConsumerV2Plus
   */
  function setCoordinator(
    address _vrfCoordinator
  ) external override onlyOwnerOrCoordinator {
    if (_vrfCoordinator == address(0)) {
      revert ZeroAddress();
    }
    s_vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinator);

    emit CoordinatorSet(_vrfCoordinator);
  }

  modifier onlyOwnerOrCoordinator() {
    if (msg.sender != owner() && msg.sender != address(s_vrfCoordinator)) {
      revert OnlyOwnerOrCoordinator(msg.sender, owner(), address(s_vrfCoordinator));
    }
    _;
  }
}

// OpenZeppelin Contracts (last updated v5.4.0) (token/ERC20/IERC20.sol)

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

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
