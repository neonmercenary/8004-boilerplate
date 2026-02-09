# @version ^0.4.0
# SPDX-License-Identifier: MIT

struct MetadataEntry:
    key: String[64]
    value: Bytes[256]

# --- Interfaces ---
interface IIdentityRegistry:
    def register_with_meta(agentURI: String[128], metadata: DynArray[MetadataEntry, 10]) -> uint256: nonpayable
    def setAgentURI(agentId: uint256, newURI: String[128]): nonpayable

interface IReputationRegistry:
    def giveFeedback(agentId: uint256, _value: int128, valueDecimals: uint8, tag1: String[64], tag2: String[64], endpoint: String[128], feedbackURI: String[128], feedbackHash: bytes32): nonpayable
    def revokeFeedback(agentId: uint256, feedbackIndex: uint64): nonpayable
    def readFeedback(agentId: uint256, clientAddress: address, feedbackIndex: uint64) -> (int128, uint8, String[64], String[64], bool): view
    def getSummary(agentId: uint256, clientAddresses: DynArray[address, 100], tag1: String[64], tag2: String[64]) -> (uint64, int128, uint8): view

interface IValidationRegistry:
    def validationRequest(validatorAddress: address, agentId: uint256, requestURI: String[128], requestHash: bytes32): nonpayable
    def getSummary(agentId: uint256, validators: DynArray[address, 100], tag: String[64]) -> (uint64, uint8): view



# --- Structs ---
struct Task:
    taskId: uint256
    agentId: uint256
    requester: address
    taskType: uint8
    status: uint8
    inputURI: String[128]
    inputHash: bytes32
    outputURI: String[128]
    outputHash: bytes32
    payment: uint256
    createdAt: uint256
    completedAt: uint256

# --- Events (KWARGS Required) ---
event FeedbackProvided:
    taskId: indexed(uint256)
    agentId: indexed(uint256)
    rating: int128
    tag: String[64]

event ValidationRequested:
    agentId: indexed(uint256)
    validator: indexed(address)
    requestURI: String[128]

event AgentRegistered:
    agentId: indexed(uint256)
    name: String[64]
    uri: String[128]
    
event AgentUpdated:
    agentId: indexed(uint256)
    newURI: String[128]

event TaskRequested:
    taskId: indexed(uint256)
    requester: indexed(address)
    taskType: uint8
    payment: uint256

event TaskStarted:
    taskId: indexed(uint256)

event TaskCompleted:
    taskId: indexed(uint256)
    outputURI: String[128]
    outputHash: bytes32

event TaskDisputed:
    taskId: indexed(uint256)
    disputer: indexed(address)

event TaskCancelled:
    taskId: indexed(uint256)

event PaymentWithdrawn:
    owner: indexed(address)
    amount: uint256

event PaymentReceived:
    sender: indexed(address)
    amount: uint256

# --- State ---
identityRegistry: public(address)
reputationRegistry: public(address)
validationRegistry: public(address)
owner: public(address)

agentId: public(uint256)
isRegistered: public(bool)

_nextTaskId: uint256
tasks: public(HashMap[uint256, Task])
taskIds: public(DynArray[uint256, 1000])
taskPrices: public(HashMap[uint8, uint256])

agentName: public(String[64])
agentDescription: public(String[128])
agentURI: public(String[128])

# --- Constants (Replacing Enums) ---
STATUS_PENDING: constant(uint8) = 0
STATUS_IN_PROGRESS: constant(uint8) = 1
STATUS_COMPLETED: constant(uint8) = 2
STATUS_DISPUTED: constant(uint8) = 3
STATUS_CANCELLED: constant(uint8) = 4
STATUS_CLOSED: constant(uint8) = 5

# Task Type
TYPE_SUMMARIZATION: constant(uint8) = 0
TYPE_CODE_REVIEW: constant(uint8) = 1
TYPE_DATA_ANALYSIS: constant(uint8) = 2
TYPE_TRANSLATION: constant(uint8) = 3
TYPE_CUSTOM: constant(uint8) = 4

# ==============================================
# interal functions
# ==============================================
@internal
@pure
def _get_tag(task_type: uint8) -> String[64]:
    if task_type == 0:
        return "summarization"
    if task_type == 1:
        return "code-review"
    if task_type == 2:
        return "data-analysis"
    if task_type == 3:
        return "translation"
    return "custom"

@deploy
def __init__(_identityRegistry: address, _reputationRegistry: address, _validationRegistry: address):
    self.identityRegistry = _identityRegistry
    self.reputationRegistry = _reputationRegistry
    self.validationRegistry = _validationRegistry
    self.owner = msg.sender
    self._nextTaskId = 1

    # Using as_wei_value per your draft
    self.taskPrices[TYPE_SUMMARIZATION] = as_wei_value(0.001, "ether")
    self.taskPrices[TYPE_CODE_REVIEW] = as_wei_value(0.005, "ether")
    self.taskPrices[TYPE_DATA_ANALYSIS] = as_wei_value(0.003, "ether")
    self.taskPrices[TYPE_TRANSLATION] = as_wei_value(0.002, "ether")
    self.taskPrices[TYPE_CUSTOM] = as_wei_value(0.01, "ether")


@external
def registerAgent(_name: String[64], _description: String[128], _agentURI: String[128]):
    assert msg.sender == self.owner, "Only owner"
    assert not self.isRegistered, "Already registered"

    self.agentName = _name
    self.agentDescription = _description
    self.agentURI = _agentURI

    # Simplified tuple metadata
    meta: DynArray[MetadataEntry, 10] = [
        MetadataEntry(key="name", value=convert(_name, Bytes[256])),
        MetadataEntry(key="description", value=convert(_description, Bytes[256]))
    ]

    self.agentId = extcall IIdentityRegistry(self.identityRegistry).register_with_meta(_agentURI, meta)
    self.isRegistered = True

    log AgentRegistered(self.agentId, _name, _agentURI)

@external
@payable
@nonreentrant
def requestTask(taskType: uint8, inputURI: String[128], inputHash: bytes32) -> uint256:
    assert self.isRegistered, "Agent not registered"
    assert msg.value >= self.taskPrices[taskType], "Insufficient payment"

    t_id: uint256 = self._nextTaskId
    self._nextTaskId += 1

    self.tasks[t_id] = Task(
        taskId=t_id,
        agentId=self.agentId,
        requester=msg.sender,
        taskType=taskType,
        status=0,  # Pending
        inputURI=inputURI,
        inputHash=inputHash,
        outputURI="",
        outputHash=empty(bytes32),
        payment=msg.value,
        createdAt=block.timestamp,
        completedAt=0
    )
    self.taskIds.append(t_id)

    log TaskRequested(t_id, msg.sender, taskType, msg.value)
    return t_id


@external
def startTask(taskId: uint256):
    assert msg.sender == self.owner, "Only owner"
    task: Task = self.tasks[taskId]
    
    # Using the constants for readability
    assert task.status == STATUS_PENDING, "Task not pending"
    
    task.status = STATUS_IN_PROGRESS
    self.tasks[taskId] = task
    
    log TaskStarted(taskId)

@external
def completeTask(taskId: uint256, outputURI: String[128], outputHash: bytes32):
    assert msg.sender == self.owner, "Only owner"
    task: Task = self.tasks[taskId]
    assert task.status == STATUS_IN_PROGRESS, "Task not in progress"

    task.status = STATUS_COMPLETED
    task.outputURI = outputURI
    task.outputHash = outputHash
    task.completedAt = block.timestamp
    
    self.tasks[taskId] = task
    log TaskCompleted(taskId, outputURI, outputHash)



@external
@nonreentrant
def withdraw():
    assert msg.sender == self.owner, "Only owner"
    val: uint256 = self.balance
    assert val > 0, "No balance"
    send(self.owner, val)
    log PaymentWithdrawn(self.owner, val)



@external
def disputeTask(taskId: uint256):
    task: Task = self.tasks[taskId]
    assert task.requester == msg.sender, "Not the requester"
    assert task.status == STATUS_COMPLETED, "Task not completed"
    # 7 days in seconds = 604800
    assert block.timestamp <= task.completedAt + 604800, "Dispute period expired"

    task.status = STATUS_DISPUTED
    self.tasks[taskId] = task
    
    log TaskDisputed(taskId, msg.sender)

@external
@nonreentrant
def cancelTask(taskId: uint256):
    task: Task = self.tasks[taskId]
    assert task.requester == msg.sender, "Not the requester"
    assert task.status == STATUS_PENDING, "Task not pending"

    task.status = STATUS_CANCELLED
    self.tasks[taskId] = task

    # Refund payment using send() for Vyper 0.4.x
    send(msg.sender, task.payment)
    
    log TaskCancelled(taskId)

@external
def giveFeedback(
    taskId: uint256, 
    rating: int128, 
    comment: String[64]
):
    task: Task = self.tasks[taskId]
    assert task.requester == msg.sender, "Not the requester"
    assert task.status != STATUS_CLOSED, "Task already closed"
    assert task.status == STATUS_COMPLETED, "Task not completed"

    tag1: String[64] = self._get_tag(task.taskType)

    # Call external Reputation Registry
    extcall IReputationRegistry(self.reputationRegistry).giveFeedback(
        self.agentId,
        rating,
        0,              # 0 decimals for whole ratings
        tag1,
        comment,
        "",             # endpoint
        "",             # feedbackURI
        empty(bytes32)  # feedbackHash
    )
    
    # Log the feedback locally
    log FeedbackProvided(taskId, self.agentId, rating, tag1)
    task.status = STATUS_CLOSED
    self.tasks[taskId] = task   # Update status to closed after feedback is given

@external
def requestValidation(
    validator: address, 
    requestURI: String[128], 
    requestHash: bytes32
):
    assert msg.sender == self.owner, "Only owner"
    assert self.isRegistered, "Agent not registered"
    
    # 1. Perform the external call
    extcall IValidationRegistry(self.validationRegistry).validationRequest(
        validator, 
        self.agentId, 
        requestURI, 
        requestHash
    )
    
    # 2. Log it (KWARGS Required)
    log ValidationRequested(self.agentId, validator, requestURI)

# --- Admin Functions ---

@external
def setTaskPrice(taskType: uint8, price: uint256):
    assert msg.sender == self.owner, "Only owner"
    # Ensure we stay within our defined 0-4 range
    assert taskType <= 4, "Invalid task type"
    self.taskPrices[taskType] = price


# --- Function ---
@external
def updateAgentURI(newURI: String[128]):
    assert msg.sender == self.owner, "Only owner"
    assert self.isRegistered, "Agent not registered"
    
    self.agentURI = newURI
    
    # External state-changing call
    extcall IIdentityRegistry(self.identityRegistry).setAgentURI(self.agentId, newURI)
    
    # Log the change with Kwargs
    log AgentUpdated(self.agentId, newURI)


# --- View Functions ---
@external
@view
def getTask(taskId: uint256) -> Task:
    return self.tasks[taskId]

@external
@view
def getAllTaskIds() -> DynArray[uint256, 1000]:
    return self.taskIds

@external
@view
def getTasksByStatus(status: uint8) -> DynArray[uint256, 1000]:
    result: DynArray[uint256, 1000] = []
    # We iterate through the existing taskIds array
    for t_id: uint256 in self.taskIds:
        if self.tasks[t_id].status == status:
            result.append(t_id)
    return result

@external
@view
def getReputationSummary() -> (uint64, int128):
    # Vyper 0.4.x requires explicit staticcall for external views
    # Also requires a defined capacity for the DynArray argument
    empty_list: DynArray[address, 100] = []
    
    feedbackCount: uint64 = 0
    averageRating: int128 = 0
    decimals: uint8 = 0
    
    (feedbackCount, averageRating, decimals) = staticcall IReputationRegistry(self.reputationRegistry).getSummary(
        self.agentId, 
        empty_list, 
        "", 
        ""
    )
    return feedbackCount, averageRating

@external
@view
def getValidationSummary() -> (uint64, uint8):
    empty_list: DynArray[address, 100] = []
    
    validationCount: uint64 = 0
    averageScore: uint8 = 0
    
    (validationCount, averageScore) = staticcall IValidationRegistry(self.validationRegistry).getSummary(
        self.agentId, 
        empty_list, 
        ""
    )
    return validationCount, averageScore

@external
@view
def getTotalTasks() -> uint256:
    return len(self.taskIds)

# --- Default Receive ---

@external
@payable
def __default__():
    # Allows the contract to receive AVAX
    log PaymentReceived(msg.sender, msg.value)
    pass