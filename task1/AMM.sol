// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interface.sol";
import "./utils.sol";
import "./XiaoNaoFu.sol";

abstract contract IRewardDistributionRecipient is Ownable {
    address public rewardDistribution;

    function notifyRewardAmount(uint256 reward) external virtual;

    modifier onlyRewardDistribution() {
        require(
            _msgSender() == rewardDistribution,
            'Caller is not reward distribution'
        );
        _;
    }

    function setRewardDistribution(address _rewardDistribution)
        external
        virtual
        onlyOwner
    {
        rewardDistribution = _rewardDistribution;
    }
}


/**
 * @title LP质押合约
 */
contract LPTokenWrapper {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;
    /// @notice GoCash LP Token合约地址
    IBEP20 public lpt;

    /// @dev 质押总量
    uint256 private _totalSupply;
    /// @dev 余额映射
    mapping(address => uint256) private _balances;

    /**
     * @dev 返回总量
     * @return 总量
     */
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev 返回账户余额
     * @param account 账户地址
     * @return 余额
     */
    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev 把shushi抵押到Boardroom
     * @param amount 质押数量
     */
    function stake(uint256 amount) public virtual {
        // 总量增加
        _totalSupply = _totalSupply.add(amount);
        // 余额映射增加
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        // 将LPToken发送到当前合约
        lpt.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @dev 赎回LPToken
     * @param amount 赎回数量
     */
    function withdraw(uint256 amount) public virtual {
        // 用户的总质押数量
        uint256 directorShare = _balances[msg.sender];
        // 确认总质押数量大于取款数额
        require(directorShare >= amount, 'withdraw request greater than staked amount');
        // 总量减少
        _totalSupply = _totalSupply.sub(amount);
        // 余额减少
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        // 将LPToken发送给用户
        lpt.safeTransfer(msg.sender, amount);
    }
}


/**
 * @title LP Token矿池合约
 * @notice 周期30天
 */
contract LPTokenPool is LPTokenWrapper, IRewardDistributionRecipient {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    IBEP20 public token;
    /// @notice 时间周期 = 30天
    uint256 public DURATION = 30 days;
    /// @notice 开始时间
    uint256 public starttime; // starttime TBD
    /// @notice 结束时间
    uint256 public periodFinish = 0;
    /// @notice 每秒奖励数量
    uint256 public rewardRate = 0;
    /// @notice 最后更新时间
    uint256 public lastUpdateTime;
    /// @notice 储存奖励数量
    uint256 public rewardPerTokenStored;
    /// @notice 每个质押Token支付用户的奖励
    mapping(address => uint256) public userRewardPerTokenPaid;
    /// @notice 用户未发放的奖励数量
    mapping(address => uint256) public rewards;

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);

    /**
     * @dev 构造函数
     * @param token_ token地址
     * @param lptoken_ LPtoken地址
     * @param starttime_ 开始时间
     */
    constructor(address token_, address lptoken_, uint256 starttime_) public {
        token = IBEP20(token_);
        lpt = IBEP20(lptoken_);
        starttime = starttime_;
    }

    /**
     * @dev 检查开始时间
     */
    modifier checkStart() {
        require(block.timestamp >= starttime, 'LPTokenSharePool: not start');
        _;
    }

    /**
     * @dev 更新奖励
     * @param account 用户地址
     */
    modifier updateReward(address account) {
        // 已奖励数量 = 每个质押Token的奖励
        rewardPerTokenStored = rewardPerToken();
        // 最后更新时间 = min(当前时间,最后时间)
        lastUpdateTime = lastTimeRewardApplicable();
        // 如果用户地址!=0地址
        if (account != address(0)) {
            // 用户未发放的奖励数量 = 赚取用户奖励
            rewards[account] = earned(account);
            // 每个质押Token支付用户的奖励 = 已奖励数量
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /**
     * @dev 返回奖励的最后期限
     * @return 最后期限
     * @notice 如果没有到达结束时间,返回当前时间
     */
    function lastTimeRewardApplicable() public view returns (uint256) {
        // 最小值(当前时间,结束时间)
        return Math.min(block.timestamp, periodFinish);
    }

    /**
     * @dev 每个质押Token的奖励
     * @return 奖励数量
     */
    function rewardPerToken() public view returns (uint256) {
        // 返回0
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        // 已奖励数量 + (min(当前时间,最后时间) - 最后更新时间) * 每秒奖励 * 1e18 / 质押总量
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable()
                    .sub(lastUpdateTime)
                    .mul(rewardRate)
                    .mul(1e18)
                    .div(totalSupply())
            );
    }

    /**
     * @dev 用户已奖励的数量
     * @param account 用户地址
     */
    function earned(address account) public view returns (uint256) {
        // 用户的质押数量 * (每个质押Token的奖励 - 每个质押Token支付用户的奖励) / 1e18 + 用户未发放的奖励数量
        return
            balanceOf(account)
                .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
                .div(1e18)
                .add(rewards[account]);
    }

    /**
     * @dev 质押指定数量的token
     * @param amount 质押数量
     */
    // stake visibility is public as overriding LPTokenWrapper's stake() function
    function stake(
        uint256 amount
    ) public override updateReward(msg.sender) checkStart {
        // 确认数量>0
        require(amount > 0, 'HUSDGOCLPTokenSharePool: Cannot stake 0');
        // 上级质押
        super.stake(amount);
        // 触发质押事件
        emit Staked(msg.sender, amount);
    }

    /**
     * @dev 提款指定数额的质押token
     * @param amount 质押数量
     */
    function withdraw(
        uint256 amount
    ) public override updateReward(msg.sender) checkStart {
        // 确认数量>0
        require(amount > 0, 'HUSDGOCLPTokenSharePool: Cannot withdraw 0');
        // 上级提款
        super.withdraw(amount);
        // 触发提款事件
        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @dev 退出
     */
    function exit() external {
        // 提走用户质押的全部数量
        withdraw(balanceOf(msg.sender));
        // 获取奖励
        getReward();
    }

    /**
     * @dev 获取奖励
     */
    function getReward() public updateReward(msg.sender) checkStart {
        // 奖励数量 = 用户已奖励的数量
        uint256 reward = earned(msg.sender);
        // 如果奖励数量>0
        if (reward > 0) {
            // 用户未发放的奖励数量 = 0
            rewards[msg.sender] = 0;
            // 发送奖励
            token.safeTransfer(msg.sender, reward);
            // 触发支付奖励事件
            emit RewardPaid(msg.sender, reward);
        }
    }

    /**
     * @dev 通知奖励数量
     * @param reward 奖励数量
     */
    function notifyRewardAmount(
        uint256 reward
    ) external override onlyRewardDistribution updateReward(address(0)) {
        // 如果当前时间>开始时间
        if (block.timestamp > starttime) {
            // 如果当前时间 >= 结束时间
            if (block.timestamp >= periodFinish) {
                // 每秒奖励 = 奖励数量 / 30天
                rewardRate = reward.div(DURATION);
            } else {
                // 剩余时间 = 结束时间 - 当前时间
                uint256 remaining = periodFinish.sub(block.timestamp);
                // 剩余奖励数量 = 剩余时间 * 每秒奖励 (第一次执行为0)
                uint256 leftover = remaining.mul(rewardRate);
                // 每秒奖励 = (奖励数量 + 剩余奖励数量) / 30天
                rewardRate = reward.add(leftover).div(DURATION);
            }
            //最后更新时间 = 当前时间
            lastUpdateTime = block.timestamp;
            // 结束时间 = 当前时间 + 30天
            periodFinish = block.timestamp.add(DURATION);
            // 触发奖励增加事件
            emit RewardAdded(reward);
        } else {
            // 每秒奖励 = 奖励数量 / 30天
            rewardRate = reward.div(DURATION);
            // 最后更新时间 = 开始时间
            lastUpdateTime = starttime;
            // 结束时间 = 开始时间 + 30天
            periodFinish = starttime.add(DURATION);
            // 触发奖励增加事件
            emit RewardAdded(reward);
        }
    }
}