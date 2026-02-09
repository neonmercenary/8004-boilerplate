# @version ^0.4.0
# SPDX-License-Identifier: MIT

# --- Interfaces ---
interface IIdentityRegistry:
    def getAgentWallet(agentId: uint256) -> address: view

# --- Structs ---
struct FeedbackEntry:
    _value: int128
    valueDecimals: uint8
    tag1: String[64]
    tag2: String[64]
    isRevoked: bool

# --- Events ---
event NewFeedback:
    agentId: uint256
    clientAddress: indexed(address)
    feedbackIndex: uint64
    _value: int128
    valueDecimals: uint8
    indexedTag1: indexed(String[64])
    tag1: String[64]
    tag2: String[64]
    endpoint: String[128]
    feedbackURI: String[128]
    feedbackHash: bytes32

event FeedbackRevoked:
    agentId: uint256
    clientAddress: indexed(address)
    feedbackIndex: indexed(uint64)

event ResponseAppended:
    agentId: uint256
    clientAddress: indexed(address)
    feedbackIndex: uint64
    responder: indexed(address)
    responseURI: String[128]
    responseHash: bytes32

# --- State ---
identityRegistry: public(address)

# Nested mappings are explicitly defined
feedback: HashMap[uint256, HashMap[address, HashMap[uint64, FeedbackEntry]]]
lastIndex: HashMap[uint256, HashMap[address, uint64]]
clients: HashMap[uint256, DynArray[address, 100]]
isClient: HashMap[uint256, HashMap[address, bool]]
# Response tracking: agent -> client -> index -> responder -> count
responses: HashMap[uint256, HashMap[address, HashMap[uint64, HashMap[address, uint64]]]]

# --- Constructor ---
@deploy
def __init__(_identityRegistry: address):
    self.identityRegistry = _identityRegistry

# --- Logic ---
@external
def giveFeedback(
    agentId: uint256,
    _value: int128,
    valueDecimals: uint8,
    tag1: String[64],
    tag2: String[64],
    endpoint: String[128],
    feedbackURI: String[128],
    feedbackHash: bytes32
):
    assert valueDecimals <= 18, "Decimals too high"

    # Direct call: if this reverts, the feedback submission fails.
    # This is actually safer for data integrity.
    wallet: address = staticcall IIdentityRegistry(self.identityRegistry).getAgentWallet(agentId)
    assert wallet != msg.sender, "Cannot give self-feedback"

    if not self.isClient[agentId][msg.sender]:
        self.clients[agentId].append(msg.sender)
        self.isClient[agentId][msg.sender] = True

    self.lastIndex[agentId][msg.sender] += 1
    feedbackIndex: uint64 = self.lastIndex[agentId][msg.sender]

    # Writing to storage
    self.feedback[agentId][msg.sender][feedbackIndex] = FeedbackEntry(
        _value=_value,
        valueDecimals=valueDecimals,
        tag1=tag1,
        tag2=tag2,
        isRevoked=False
    )

    log NewFeedback(agentId, msg.sender, feedbackIndex, _value, valueDecimals, tag1, tag1, tag2, endpoint, feedbackURI, feedbackHash)

@external
def revokeFeedback(agentId: uint256, feedbackIndex: uint64):
    entry: FeedbackEntry = self.feedback[agentId][msg.sender][feedbackIndex]
    assert entry.valueDecimals > 0 or entry._value != 0, "Feedback does not exist"
    assert not entry.isRevoked, "Already revoked"

    # In Vyper, you modify the memory copy and write it back
    entry.isRevoked = True
    self.feedback[agentId][msg.sender][feedbackIndex] = entry
    
    log FeedbackRevoked(agentId, msg.sender, feedbackIndex)

@external
def appendResponse(
    agentId: uint256, 
    clientAddress: address, 
    feedbackIndex: uint64, 
    responseURI: String[128], 
    responseHash: bytes32
):
    entry: FeedbackEntry = self.feedback[agentId][clientAddress][feedbackIndex]
    assert entry.valueDecimals > 0 or entry._value != 0, "Feedback does not exist"

    self.responses[agentId][clientAddress][feedbackIndex][msg.sender] += 1
    
    log ResponseAppended(agentId, clientAddress, feedbackIndex, msg.sender, responseURI, responseHash)

@external
@view
def getSummary(
    agentId: uint256, 
    clientAddresses: DynArray[address, 100], 
    tag1: String[64], 
    tag2: String[64]
) -> (uint64, int128, uint8):
    
    summaryValueDecimals: uint8 = 18
    total: int256 = 0
    count: uint256 = 0

    clientsList: DynArray[address, 100] = clientAddresses
    if len(clientAddresses) == 0:
        clientsList = self.clients[agentId]

    for client: address in clientsList:
        lastIdx: uint64 = self.lastIndex[agentId][client]
        
        for j: uint256 in range(1, 101): 
            if j > convert(lastIdx, uint256):
                break
                
            entry: FeedbackEntry = self.feedback[agentId][client][convert(j, uint64)]
            
            if entry.isRevoked:
                continue
            
            if len(tag1) > 0 and keccak256(entry.tag1) != keccak256(tag1):
                continue
            if len(tag2) > 0 and keccak256(entry.tag2) != keccak256(tag2):
                continue

            exponent: uint256 = 18 - convert(entry.valueDecimals, uint256)
            multiplier: int256 = convert(10 ** exponent, int256)
            
            normalizedValue: int256 = convert(entry._value, int256) * multiplier
            total += normalizedValue
            count += 1

    summaryValue: int128 = 0
    if count > 0:
        # Integer division (floor) is // in 0.4.x
        avg: int256 = total // convert(count, int256)
        summaryValue = convert(avg, int128)

    return convert(count, uint64), summaryValue, summaryValueDecimals
    
@external
@view
def readFeedback(agentId: uint256, clientAddress: address, feedbackIndex: uint64) -> (int128, uint8, String[64], String[64], bool):
    entry: FeedbackEntry = self.feedback[agentId][clientAddress][feedbackIndex]
    return entry._value, entry.valueDecimals, entry.tag1, entry.tag2, entry.isRevoked

@external
@view
def getClients(agentId: uint256) -> DynArray[address, 100]:
    return self.clients[agentId]


@external
@view
def getResponseCount(agentId: uint256, clientAddress: address, feedbackIndex: uint64, responder: address) -> uint64:
    """
    @notice Get the number of responses a given responder has appended to a specific feedback entry
    @param agentId The agent identifier
    @param clientAddress The client who gave the feedback
    @param feedbackIndex The feedback index
    @param responder The address of the responder
    @return count The number of responses
    """
    return self.responses[agentId][clientAddress][feedbackIndex][responder]
