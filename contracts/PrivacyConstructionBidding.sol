// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TFHE, euint32, euint64, ebool } from "fhevm/lib/TFHE.sol";
import { SepoliaZamaFHEVMConfig } from "fhevm/config/ZamaFHEVMConfig.sol";
import { Gateway } from "fhevm/gateway/lib/Gateway.sol";

contract PrivacyConstructionBidding is SepoliaZamaFHEVMConfig {

    address public owner;
    uint32 public projectCounter;
    uint32 public currentEvaluationProject;

    struct Project {
        string name;
        string description;
        uint256 budget;
        uint256 deadline;
        address creator;
        bool isActive;
        bool biddingClosed;
        uint256 biddingEndTime;
        address[] bidders;
        address winningBidder;
        uint256 winningAmount;
        uint256 creationTime;
    }

    struct PrivateBid {
        euint64 encryptedAmount;
        euint32 encryptedCompletionTime;
        string publicProposal;
        bool submitted;
        uint256 timestamp;
        address bidder;
    }

    mapping(uint32 => Project) public projects;
    mapping(uint32 => mapping(address => PrivateBid)) public projectBids;
    mapping(address => bool) public authorizedContractors;

    event ProjectCreated(uint32 indexed projectId, string name, address creator, uint256 budget);
    event BidSubmitted(uint32 indexed projectId, address indexed bidder);
    event BiddingClosed(uint32 indexed projectId);
    event WinnerSelected(uint32 indexed projectId, address indexed winner, uint256 amount);
    event ContractorAuthorized(address contractor);
    event ContractorRevoked(address contractor);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    modifier onlyAuthorizedContractor() {
        require(authorizedContractors[msg.sender], "Not an authorized contractor");
        _;
    }

    modifier projectExists(uint32 _projectId) {
        require(_projectId > 0 && _projectId <= projectCounter, "Project does not exist");
        _;
    }

    modifier biddingActive(uint32 _projectId) {
        require(projects[_projectId].isActive, "Project not active");
        require(!projects[_projectId].biddingClosed, "Bidding already closed");
        require(block.timestamp < projects[_projectId].biddingEndTime, "Bidding period ended");
        _;
    }

    constructor() {
        owner = msg.sender;
        projectCounter = 0;
    }

    function authorizeContractor(address _contractor) external onlyOwner {
        authorizedContractors[_contractor] = true;
        emit ContractorAuthorized(_contractor);
    }

    function revokeContractor(address _contractor) external onlyOwner {
        authorizedContractors[_contractor] = false;
        emit ContractorRevoked(_contractor);
    }

    function createProject(
        string memory _name,
        string memory _description,
        uint256 _budget,
        uint256 _deadline,
        uint256 _biddingDuration
    ) external returns (uint32) {
        require(_budget > 0, "Budget must be positive");
        require(_deadline > block.timestamp, "Deadline must be in the future");
        require(_biddingDuration > 0, "Bidding duration must be positive");

        projectCounter++;

        projects[projectCounter] = Project({
            name: _name,
            description: _description,
            budget: _budget,
            deadline: _deadline,
            creator: msg.sender,
            isActive: true,
            biddingClosed: false,
            biddingEndTime: block.timestamp + _biddingDuration,
            bidders: new address[](0),
            winningBidder: address(0),
            winningAmount: 0,
            creationTime: block.timestamp
        });

        emit ProjectCreated(projectCounter, _name, msg.sender, _budget);
        return projectCounter;
    }

    function submitBid(
        uint32 _projectId,
        uint64 _bidAmount,
        uint32 _completionTimeInDays,
        string memory _publicProposal
    ) external
        onlyAuthorizedContractor
        projectExists(_projectId)
        biddingActive(_projectId)
    {
        require(_bidAmount > 0, "Bid amount must be positive");
        require(_completionTimeInDays > 0, "Completion time must be positive");
        require(!projectBids[_projectId][msg.sender].submitted, "Bid already submitted");

        euint64 encryptedAmount = TFHE.asEuint64(_bidAmount);
        euint32 encryptedTime = TFHE.asEuint32(_completionTimeInDays);

        projectBids[_projectId][msg.sender] = PrivateBid({
            encryptedAmount: encryptedAmount,
            encryptedCompletionTime: encryptedTime,
            publicProposal: _publicProposal,
            submitted: true,
            timestamp: block.timestamp,
            bidder: msg.sender
        });

        projects[_projectId].bidders.push(msg.sender);

        TFHE.allowThis(encryptedAmount);
        TFHE.allowThis(encryptedTime);
        TFHE.allow(encryptedAmount, msg.sender);
        TFHE.allow(encryptedTime, msg.sender);
        TFHE.allow(encryptedAmount, projects[_projectId].creator);
        TFHE.allow(encryptedTime, projects[_projectId].creator);

        emit BidSubmitted(_projectId, msg.sender);
    }

    function closeBidding(uint32 _projectId) external projectExists(_projectId) {
        Project storage project = projects[_projectId];
        require(
            msg.sender == project.creator ||
            msg.sender == owner ||
            block.timestamp >= project.biddingEndTime,
            "Not authorized to close bidding"
        );
        require(!project.biddingClosed, "Bidding already closed");

        project.biddingClosed = true;
        emit BiddingClosed(_projectId);
    }

    function evaluateBids(uint32 _projectId) external projectExists(_projectId) {
        Project storage project = projects[_projectId];
        require(msg.sender == project.creator, "Only project creator can evaluate");
        require(project.biddingClosed, "Bidding must be closed first");
        require(project.winningBidder == address(0), "Winner already selected");
        require(project.bidders.length > 0, "No bids submitted");

        currentEvaluationProject = _projectId;
        uint256[] memory ctsHandles = new uint256[](project.bidders.length * 2);
        uint256 index = 0;

        for (uint i = 0; i < project.bidders.length; i++) {
            address bidder = project.bidders[i];
            PrivateBid storage bid = projectBids[_projectId][bidder];
            ctsHandles[index++] = Gateway.toUint256(bid.encryptedAmount);
            ctsHandles[index++] = Gateway.toUint256(bid.encryptedCompletionTime);
        }

        Gateway.requestDecryption(ctsHandles, this.processEvaluation.selector, 0, block.timestamp + 100, false);
    }

    function processEvaluation(
        uint256, // requestId - unused
        uint256[] calldata decryptedValues,
        bytes[] calldata // signatures - unused
    ) external {
        require(msg.sender == Gateway.gatewayContractAddress(), "Only gateway can call this function");
        Project storage project = projects[currentEvaluationProject];

        uint256 bestScore = 0;
        address bestBidder = address(0);
        uint256 bestAmount = 0;

        for (uint i = 0; i < project.bidders.length; i++) {
            address bidder = project.bidders[i];
            uint256 bidAmount = decryptedValues[i * 2];
            uint256 completionTime = decryptedValues[i * 2 + 1];

            if (bidAmount <= project.budget) {
                uint256 score = calculateBidScore(bidAmount, completionTime, project.budget, project.deadline);

                if (score > bestScore) {
                    bestScore = score;
                    bestBidder = bidder;
                    bestAmount = bidAmount;
                }
            }
        }

        if (bestBidder != address(0)) {
            project.winningBidder = bestBidder;
            project.winningAmount = bestAmount;
            project.isActive = false;

            emit WinnerSelected(currentEvaluationProject, bestBidder, bestAmount);
        }
    }

    function calculateBidScore(
        uint256 _bidAmount,
        uint256 _completionTime,
        uint256 _maxBudget,
        uint256 _deadline
    ) internal view returns (uint256) {
        uint256 budgetScore = ((_maxBudget - _bidAmount) * 70) / _maxBudget;

        uint256 maxDays = (_deadline - block.timestamp) / 86400;
        uint256 timeScore = 0;
        if (_completionTime <= maxDays) {
            timeScore = ((maxDays - _completionTime) * 30) / maxDays;
        }

        return budgetScore + timeScore;
    }

    function getProjectInfo(uint32 _projectId) external view projectExists(_projectId) returns (
        string memory name,
        string memory description,
        uint256 budget,
        uint256 deadline,
        address creator,
        bool isActive,
        bool biddingClosed,
        uint256 biddingEndTime,
        uint256 bidderCount,
        address winningBidder,
        uint256 winningAmount
    ) {
        Project storage project = projects[_projectId];
        return (
            project.name,
            project.description,
            project.budget,
            project.deadline,
            project.creator,
            project.isActive,
            project.biddingClosed,
            project.biddingEndTime,
            project.bidders.length,
            project.winningBidder,
            project.winningAmount
        );
    }

    function getBidStatus(uint32 _projectId, address _bidder) external view projectExists(_projectId) returns (
        bool submitted,
        string memory publicProposal,
        uint256 timestamp
    ) {
        PrivateBid storage bid = projectBids[_projectId][_bidder];
        return (
            bid.submitted,
            bid.publicProposal,
            bid.timestamp
        );
    }

    function getProjectBidders(uint32 _projectId) external view projectExists(_projectId) returns (
        address[] memory
    ) {
        return projects[_projectId].bidders;
    }

    function isContractorAuthorized(address _contractor) external view returns (bool) {
        return authorizedContractors[_contractor];
    }

    function getCurrentTime() external view returns (uint256) {
        return block.timestamp;
    }
}