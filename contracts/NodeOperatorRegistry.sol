// SPDX-FileCopyrightText: 2021 Shardlabs
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.7;

import "hardhat/console.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./storages/NodeOperatorStorage.sol";
import "./interfaces/INodeOperatorRegistry.sol";
import "./interfaces/IValidatorFactory.sol";
import "./interfaces/IValidator.sol";
import "./lib/Operator.sol";

/// @title NodeOperatorRegistry
/// @author 2021 Shardlabs.
/// @notice NodeOperatorRegistry is the main contract that manage validators
/// @dev NodeOperatorRegistry is the main contract that manage validators
contract NodeOperatorRegistry is
    INodeOperatorRegistry,
    NodeOperatorStorage,
    Initializable,
    AccessControl,
    UUPSUpgradeable
{
    // ====================================================================
    // =========================== MODIFIERS ==============================
    // ====================================================================

    /// @notice Check if the PublicKey is valid.
    /// @param _pubkey publick key used in the heimdall node.
    modifier isValidPublickey(bytes memory _pubkey) {
        require(_pubkey.length == 64, "Invalid Public Key");
        _;
    }

    /// @notice Check if the msg.sender has permission.
    /// @param _role role needed to call function.
    modifier userHasRole(bytes32 _role) {
        require(hasRole(_role, msg.sender), "Permission not found");
        _;
    }

    // ====================================================================
    // =========================== FUNCTIONS ==============================
    // ====================================================================

    /// @notice Initialize the NodeOperator contract.
    function initialize(
        address _validatorFactory,
        address _lido,
        address _stakeManager,
        address _polygonERC20
    ) public initializer {
        state.validatorFactory = _validatorFactory;
        state.lido = _lido;
        state.stakeManager = _stakeManager;
        state.polygonERC20 = _polygonERC20;

        // Set ACL roles
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(ADD_OPERATOR_ROLE, msg.sender);
        _setupRole(REMOVE_OPERATOR_ROLE, msg.sender);
        _setupRole(EXIT_OPERATOR_ROLE, msg.sender);
    }

    /// @notice Add a new node operator to the system.
    /// @dev Add a new operator
    /// @param _name the node operator name.
    /// @param _rewardAddress public address used for ACL and receive rewards.
    /// @param _signerPubkey public key used on heimdall len 64 bytes.
    function addOperator(
        string memory _name,
        address _rewardAddress,
        bytes memory _signerPubkey
    )
        public
        override
        isValidPublickey(_signerPubkey)
        userHasRole(ADD_OPERATOR_ROLE)
    {
        uint256 operatorId = state.totalNodeOpearator + 1;

        // deploy validator contract.
        address validatorContract = IValidatorFactory(state.validatorFactory)
            .create();

        // add the validator.
        operators[operatorId] = Operator.NodeOperator({
            status: Operator.NodeOperatorStatus.ACTIVE,
            name: _name,
            rewardAddress: _rewardAddress,
            validatorId: 0,
            signerPubkey: _signerPubkey,
            validatorContract: validatorContract,
            validatorShare: address(0)
        });

        // update global state.
        operatorIds.push(operatorId);
        state.totalNodeOpearator++;
        state.totalActiveNodeOpearator++;

        // map user _rewardAddress with the operatorId.
        operatorOwners[_rewardAddress] = operatorId;

        // emit NewOperator event.
        emit NewOperator(
            operatorId,
            _name,
            _signerPubkey,
            Operator.NodeOperatorStatus.ACTIVE
        );
    }

    function removeOperator(uint256 _operatorId)
        public
        override
        userHasRole(REMOVE_OPERATOR_ROLE)
    {
        Operator.NodeOperator storage op = operators[_operatorId];
        require(
            op.status == Operator.NodeOperatorStatus.EXIT,
            "Node Operator state not exit"
        );

        state.totalNodeOpearator--;
        state.totalActiveNodeOpearator--;

        // update the operatorIds array by removing the actual deleted operator
        for (uint256 i = 0; i < operatorIds.length - 1; i++) {
            if (_operatorId == operatorIds[i]) {
                operatorIds[i] = operatorIds[operatorIds.length - 1];
                break;
            }
        }
        delete operatorIds[operatorIds.length - 1];
        operatorIds.pop();

        // delete operator and owner mappings from operators and operatorOwners;
        delete operatorOwners[op.rewardAddress];
        delete operators[_operatorId];

        emit RemoveOperator(_operatorId);
    }

    /// @notice Implement _authorizeUpgrade from UUPSUpgradeable contract to make the contract upgradable.
    /// @param newImplementation new contract implementation address.
    function _authorizeUpgrade(address newImplementation) internal override {}

    /// @notice Get the validator factory address
    /// @return Returns the validator factory address.
    function getValidatorFactory() external view override returns (address) {
        return state.validatorFactory;
    }

    /// @notice Get the all operator ids availablein the system.
    /// @return Return a list of operator Ids.
    function getOperators() external view override returns (uint256[] memory) {
        return operatorIds;
    }

    /// @notice Get the stake manager contract address.
    /// @return Returns the stake manager contract address.
    function getStakeManager() external view override returns (address) {
        return state.stakeManager;
    }

    /// @notice Get the polygon erc20 token (matic) contract address.
    /// @return Returns polygon erc20 token (matic) contract address.
    function getPolygonERC20() external view override returns (address) {
        return state.polygonERC20;
    }

    /// @notice Get the lido contract address.
    /// @return Returns lido contract address.
    function getLido() external view override returns (address) {
        return state.lido;
    }

    /// @notice Get the contract state.
    /// @return Returns the contract state.
    function getState()
        public
        view
        returns (Operator.NodeOperatorState memory)
    {
        return state;
    }

    /// @notice Allows to get a node operator by _operatorId.
    /// @param _operatorId the id of the operator.
    /// @param _full if true return the name of the operator else set to empty string.
    /// @return Returns node operator.
    function getNodeOperator(uint256 _operatorId, bool _full)
        external
        view
        override
        returns (Operator.NodeOperator memory)
    {
        Operator.NodeOperator memory opts = operators[_operatorId];
        if (!_full) {
            opts.name = "";
            return opts;
        }
        return opts;
    }

    /// @notice Get the contract version.
    /// @return Returns the contract version.
    function version() external view virtual override returns (string memory) {
        return "1.0.0";
    }

    // ====================================================================
    // ========================= VALIDATOR API ============================
    // ====================================================================

    /// @notice Allows to stake a validator on the Polygon stakeManager contract.
    /// @dev Stake a validator on the Polygon stakeManager contract.
    /// @param _amount amount to stake.
    /// @param _heimdallFee herimdall fees.
    function stake(uint256 _amount, uint256 _heimdallFee) external override {
        require(
            _amount >= (10**18) || _heimdallFee >= (10**18),
            "Amount or HeimdallFees not enough"
        );

        uint256 id = operatorOwners[msg.sender];
        require(id != 0, "Operator not exists");

        Operator.NodeOperator storage op = operators[id];
        require(
            op.status == Operator.NodeOperatorStatus.ACTIVE,
            "The Operator status is not active"
        );

        // stake a validator
        IValidator(op.validatorContract).stake(
            msg.sender,
            _amount,
            _heimdallFee,
            true,
            op.signerPubkey
        );

        IStakeManager stakeManager = IStakeManager(state.stakeManager);

        op.validatorId = stakeManager.getValidatorId(op.rewardAddress);
        op.validatorShare = stakeManager.getValidatorContract(op.validatorId);
        op.status = Operator.NodeOperatorStatus.STAKED;

        state.totalActiveNodeOpearator--;
        state.totalStakedNodeOpearator++;

        emit StakeOperator(id);
    }

    /// @notice Unstake a validator from the Polygon stakeManager contract.
    /// @dev Unstake a validator from the Polygon stakeManager contract by passing the validatorId
    function unstake() external override {
        uint256 id = operatorOwners[msg.sender];
        require(id != 0, "Operator not exists");

        Operator.NodeOperator storage op = operators[id];
        require(
            op.status == Operator.NodeOperatorStatus.STAKED,
            "The operator status is not staked"
        );
        IValidator(op.validatorContract).unstake(op.validatorId);

        op.status = Operator.NodeOperatorStatus.UNSTAKED;
        state.totalStakedNodeOpearator--;
        state.totalUnstakedNodeOpearator++;

        emit UnstakeOperator(id);
    }

    /// @notice Allows to top up heimdall fees.
    /// @param _heimdallFee amount
    function topUpForFee(uint256 _heimdallFee) external override {
        require(_heimdallFee > 0, "HeimdallFee is ZERO");

        uint256 id = operatorOwners[msg.sender];
        require(id != 0, "Operator not exists");

        Operator.NodeOperator storage op = operators[id];
        require(
            op.status == Operator.NodeOperatorStatus.STAKED,
            "The operator status is not staked"
        );
        IValidator(op.validatorContract).topUpForFee(msg.sender, _heimdallFee);

        emit TopUpHeimdallFees(id, _heimdallFee);
    }

    function unstakeClaim() external override {
        uint256 validatorId = operatorOwners[msg.sender];
        require(validatorId != 0, "Operator not exists");

        Operator.NodeOperator storage no = operators[validatorId];

        require(
            no.status == Operator.NodeOperatorStatus.UNSTAKED,
            "Operator status not UNSTAKED"
        );

        (uint256 amount, uint256 rewards) = IValidator(no.validatorContract)
            .unstakeClaim(msg.sender, validatorId);

        // check if the validator contract has still rewards buffred if not set status to EXIT.
        if (rewards == 0) {
            no.status = Operator.NodeOperatorStatus.EXIT;
            state.totalUnstakedNodeOpearator--;
            state.totalExitNodeOpearator++;
        }

        emit ClaimUnstake(validatorId, msg.sender, amount);
    }

    /// @notice Get validator id by user address.
    /// @param _validatorId validatorId.
    /// @return Returns the validator total staked.
    function validatorStake(uint256 _validatorId)
        external
        view
        override
        returns (uint256)
    {
        return IStakeManager(state.stakeManager).validatorStake(_validatorId);
    }

    /// @notice Get validator total stake.
    /// @param _user user address.
    /// @return Returns the validatorId of an address.
    function getValidatorId(address _user)
        external
        view
        override
        returns (uint256)
    {
        return IStakeManager(state.stakeManager).getValidatorId(_user);
    }

    /// @notice Get validatorShare contract address.
    /// @dev Get validatorShare contract address.
    /// @param _validatorId Validator Id
    /// @return Returns the address of the validatorShare contract.
    function getValidatorContract(uint256 _validatorId)
        external
        view
        override
        returns (address)
    {
        return
            IStakeManager(state.stakeManager).getValidatorContract(
                _validatorId
            );
    }

    /// @notice Allows to withdraw rewards from the validator.
    /// @dev Allows to withdraw rewards from the validator using the _validatorId. Only the
    /// owner can request withdraw in this the owner is this contract. This  functions is called
    /// by a lido contract.
    function withdrawRewards()
        external
        override
        returns (uint256[] memory, address[] memory)
    {
        require(msg.sender == state.lido, "Caller is not the lido contract");
        uint256[] memory shares = new uint256[](state.totalStakedNodeOpearator);
        address[] memory recipient = new address[](
            state.totalStakedNodeOpearator
        );
        uint256 index = 0;
        uint256 totalRewards = 0;

        // withdraw validator rewards
        for (uint256 idx = 0; idx < operatorIds.length; idx++) {
            Operator.NodeOperator memory op = operators[operatorIds[idx]];
            if (op.status == Operator.NodeOperatorStatus.STAKED) {
                uint256 rewards = IValidator(op.validatorContract)
                    .withdrawRewards(op.validatorId);

                recipient[index] = op.rewardAddress;
                shares[index] = rewards;
                totalRewards += rewards;
                index++;
            }
        }

        // calculate validators share
        for (uint256 idx = 0; idx < shares.length; idx++) {
            uint256 share = (shares[idx] * 100) / totalRewards;
            shares[idx] = share;
        }

        emit WithdrawRewards();

        return (shares, recipient);
    }

    function exitNodeOperator(uint256 _operatorId)
        external
        override
        userHasRole(EXIT_OPERATOR_ROLE)
    {
        Operator.NodeOperator storage no = operators[_operatorId];
        require(no.status == Operator.NodeOperatorStatus.ACTIVE, "Operator status not active");
        no.status = Operator.NodeOperatorStatus.EXIT;
    }
}
