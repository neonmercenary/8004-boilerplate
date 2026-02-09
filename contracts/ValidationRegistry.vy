# @version ^0.4.0
# SPDX-License-Identifier: MIT

# --- Interfaces ---
interface IIdentityRegistry:
    # Use 'view' label instead of 'external' in 0.4.x
    def isAuthorized(agentId: uint256, caller: address) -> bool: view

# --- Structs ---
struct ValidationStatus:
    validatorAddress: address
    agentId: uint256
    response: uint8
    responseHash: bytes32
    tag: String[64]
    lastUpdate: uint256
    isComplete: bool

# --- Events (KWARGS Required) ---
event ValidationRequest:
    validatorAddress: indexed(address)
    agentId: uint256
    requestURI: String[128]
    requestHash: bytes32

event ValidationResponse:
    validatorAddress: indexed(address)
    agentId: uint256
    requestHash: bytes32
    response: uint8
    responseURI: String[128]
    responseHash: bytes32
    tag: String[64]

# --- State ---
identityRegistry: public(address)
owner: public(address)

_validations: HashMap[bytes32, ValidationStatus]
_agentValidations: HashMap[uint256, DynArray[bytes32, 1000]]
_validatorRequests: HashMap[address, DynArray[bytes32, 1000]]

# --- Constructor ---
@deploy
def __init__(_identityRegistry: address):
    self.identityRegistry = _identityRegistry
    self.owner = msg.sender

# --- Functions ---

@external
@view
def getIdentityRegistry() -> address:
    return self.identityRegistry

@external
def validationRequest(
    validatorAddress: address, 
    agentId: uint256, 
    requestURI: String[128], 
    requestHash: bytes32
):
    # staticcall is mandatory for view functions in 0.4.x
    assert staticcall IIdentityRegistry(self.identityRegistry).isAuthorized(agentId, msg.sender), "Not authorized"
    assert self._validations[requestHash].lastUpdate == 0, "Request already exists"

    self._validations[requestHash] = ValidationStatus(
        validatorAddress=validatorAddress,
        agentId=agentId,
        response=0,
        responseHash=empty(bytes32),
        tag="",
        lastUpdate=block.timestamp,
        isComplete=False
    )
    
    self._agentValidations[agentId].append(requestHash)
    self._validatorRequests[validatorAddress].append(requestHash)

    # Log using positional args (Vyper 0.4.x expects positional logs)
    log ValidationRequest(validatorAddress, agentId, requestURI, requestHash)

@external
def validationResponse(
    requestHash: bytes32, 
    response: uint8, 
    responseURI: String[128], 
    responseHash: bytes32, 
    tag: String[64]
):
    status: ValidationStatus = self._validations[requestHash]
    assert status.lastUpdate > 0, "Request does not exist"
    assert status.validatorAddress == msg.sender, "Not the designated validator"
    assert response <= 100, "Response must be 0-100"

    status.response = response
    status.responseHash = responseHash
    status.tag = tag
    status.lastUpdate = block.timestamp
    status.isComplete = True
    
    # Commit local memory struct back to storage
    self._validations[requestHash] = status

    log ValidationResponse(msg.sender, status.agentId, requestHash, response, responseURI, responseHash, tag)

@external
@view
def getSummary(
    agentId: uint256, 
    validatorAddresses: DynArray[address, 100], 
    tag: String[64]
) -> (uint64, uint8):
    hashes: DynArray[bytes32, 1000] = self._agentValidations[agentId]
    total: uint256 = 0
    count: uint256 = 0 # Using uint256 internally for math gas efficiency

    val_len: uint256 = len(validatorAddresses)
    tag_len: uint256 = len(tag)

    for h: bytes32 in hashes:
        status: ValidationStatus = self._validations[h]
        if not status.isComplete:
            continue

        if val_len > 0:
            found: bool = False
            for v: address in validatorAddresses:
                if status.validatorAddress == v:
                    found = True
                    break
            if not found:
                continue

        if tag_len > 0:
            if keccak256(status.tag) != keccak256(tag):
                continue

        total += convert(status.response, uint256)
        count += 1

    averageResponse: uint8 = 0
    if count > 0:
        # Use // for Floor Division in Vyper 0.4.0
        averageResponse = convert(total // count, uint8)

    return convert(count, uint64), averageResponse

@external
@view
def getAgentValidations(agentId: uint256) -> DynArray[bytes32, 1000]:
    return self._agentValidations[agentId]

@external
@view
def getValidatorRequests(validatorAddress: address) -> DynArray[bytes32, 1000]:
    return self._validatorRequests[validatorAddress]

@external
@view
def isValidationComplete(requestHash: bytes32) -> bool:
    return self._validations[requestHash].isComplete