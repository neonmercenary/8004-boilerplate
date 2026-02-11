# @version ^0.4.0
# SPDX-License-Identifier: MIT

import IERC721 as IERC721
import IIdentityRegistry as IIdentityRegistry

interface ERC1271:
    def isValidSignature(_hash: bytes32, _signature: Bytes[65]) -> bytes4: view

implements: IERC721
implements: IIdentityRegistry

# --- State ---
name: public(String[64])
symbol: public(String[32])

balances: HashMap[address, uint256]
owners: HashMap[uint256, address]
tokenApprovals: HashMap[uint256, address]
operatorApprovals: HashMap[address, HashMap[address, bool]]
tokenURIs: HashMap[uint256, String[128]]

_nextAgentId: uint256
metadata: HashMap[uint256, HashMap[String[64], Bytes[256]]]
agentWallets: HashMap[uint256, address]

AGENT_WALLET_KEY: constant(String[64]) = "agentWallet"
DOMAIN_SEPARATOR: public(bytes32)
WALLET_TYPEHASH: constant(bytes32) = keccak256("SetAgentWallet(uint256 agentId,address newWallet,uint256 deadline)")
ZERO: constant(address) = empty(address)

# --- Events ---
event ApprovalForAll:
    owner: indexed(address)
    operator: indexed(address)
    approved: bool

event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    tokenId: indexed(uint256)

event Approval:
    owner: indexed(address)
    approved: indexed(address)
    tokenId: indexed(uint256)

event Registered:
    agentId: indexed(uint256)
    agentURI: String[128]
    owner: indexed(address)

event MetadataSet:
    agentId: indexed(uint256)
    indexedMetadataKey: indexed(String[64])
    metadataKey: String[64]
    metadataValue: Bytes[256]

event AgentWalletSet:
    agentId: indexed(uint256)
    wallet: indexed(address)

event AgentWalletUnset:
    agentId: indexed(uint256)

@deploy
def __init__():
    self.name = "ERC8004 Agent Identity"
    self.symbol = "AGENT"
    self._nextAgentId = 1
    
    self.DOMAIN_SEPARATOR = keccak256(
        concat(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("ERC8004 Identity Registry"),
            keccak256("1"),
            convert(chain.id, bytes32),
            convert(self, bytes32)
        )
    )

# --- Your ERC-721 Logic ---

@external
@view
def balanceOf(owner: address) -> uint256:
    return self.balances[owner]

@external
@view
def ownerOf(tokenId: uint256) -> address:
    return self.owners[tokenId]

@external
def approve(to: address, tokenId: uint256):
    owner: address = self.owners[tokenId]
    assert msg.sender == owner or self.operatorApprovals[owner][msg.sender], "Not authorized"
    self.tokenApprovals[tokenId] = to
    log Approval(owner, to, tokenId)

@external
@view
def getApproved(tokenId: uint256) -> address:
    return self.tokenApprovals[tokenId]

@external
def setApprovalForAll(operator: address, approved: bool):
    self.operatorApprovals[msg.sender][operator] = approved
    log ApprovalForAll(msg.sender, operator, approved)

@external
@view
def isApprovedForAll(owner: address, operator: address) -> bool:
    return self.operatorApprovals[owner][operator]

@external
def transferFrom(frm: address, to: address, tokenId: uint256):
    owner: address = self.owners[tokenId]
    assert owner == frm, "Not owner"
    assert to != ZERO, "Cannot transfer to zero"
    assert msg.sender == owner or msg.sender == self.tokenApprovals[tokenId] or self.operatorApprovals[owner][msg.sender], "Not authorized"

    # Reset approvals and unbind wallet
    self.tokenApprovals[tokenId] = ZERO
    self.agentWallets[tokenId] = ZERO 
    
    # Update state
    self.balances[frm] -= 1
    self.balances[to] += 1
    self.owners[tokenId] = to
    
    log AgentWalletUnset(tokenId)
    log Transfer(frm, to, tokenId)

@internal
def _mint(to: address, tokenId: uint256):
    assert self.owners[tokenId] == ZERO, "Already minted"
    self.owners[tokenId] = to
    self.balances[to] += 1
    log Transfer(ZERO, to, tokenId)

@internal
def _burn(tokenId: uint256):
    owner: address = self.owners[tokenId]
    assert owner != ZERO, "Not minted"
    self.balances[owner] -= 1
    self.owners[tokenId] = ZERO
    self.tokenApprovals[tokenId] = ZERO
    log Transfer(owner, ZERO, tokenId)

@external
@view
def tokenURI(tokenId: uint256) -> String[128]:
    return self.tokenURIs[tokenId]

@view
@external
def supportsInterface(interfaceId: bytes4) -> bool:
    return interfaceId == 0x80ac58cd or interfaceId == 0x01ffc9a7

# --- Registry Implementations ---

@view
@external
def getMetadata(agentId: uint256, metadataKey: String[64]) -> Bytes[256]:
    if keccak256(metadataKey) == keccak256(AGENT_WALLET_KEY):
    # Concat the address into a bytes representation
        return concat(convert(self.agentWallets[agentId], bytes20), b"")
    return self.metadata[agentId][metadataKey]

@external
def setAgentURI(agentId: uint256, newURI: String[128]):
    assert self._isAuthorized(agentId, msg.sender), "Not authorized"
    self.tokenURIs[agentId] = newURI

@external
def setMetadata(agentId: uint256, metadataKey: String[64], metadataValue: Bytes[256]):
    assert self._isAuthorized(agentId, msg.sender), "Not authorized"
    assert keccak256(metadataKey) != keccak256(AGENT_WALLET_KEY), "Cannot set reserved key"
    
    self.metadata[agentId][metadataKey] = metadataValue
    log MetadataSet(agentId, metadataKey, metadataKey, metadataValue)

@external
def setAgentWallet(agentId: uint256, newWallet: address, deadline: uint256, signature: Bytes[65]):
    assert self._isAuthorized(agentId, msg.sender), "Not authorized"
    assert deadline >= block.timestamp, "Deadline expired"
    
    # Build struct hash (No self. for constants)
    struct_hash: bytes32 = keccak256(concat(
        WALLET_TYPEHASH, 
        convert(agentId, bytes32), 
        convert(newWallet, bytes32), 
        convert(deadline, bytes32)
    ))
    digest: bytes32 = keccak256(concat(b"\x19\x01", self.DOMAIN_SEPARATOR, struct_hash))
    
    # Signature splitting
    r: bytes32 = extract32(signature, 0)
    s: bytes32 = extract32(signature, 32)
    v: uint256 = convert(slice(signature, 64, 1), uint256)
    
    # Attempt EOA recovery
    recovered: address = ecrecover(digest, v, r, s)
    
    if recovered != newWallet:
        # ERC-1271 fallback for smart contract wallets
        # Magic value 0x1626ba7e = isValidSignature(bytes32,bytes)
        magic: bytes4 = staticcall ERC1271(newWallet).isValidSignature(digest, signature)
        assert magic == 0x1626ba7e, "Invalid signature"
    
    self.agentWallets[agentId] = newWallet
    log AgentWalletSet(agentId, newWallet)


    
@external
def unsetAgentWallet(agentId: uint256):
    assert self._isAuthorized(agentId, msg.sender), "Not authorized"
    self.agentWallets[agentId] = ZERO
    log AgentWalletUnset(agentId)

@external
def register_with_meta(agentURI: String[128], metadataEntries: DynArray[IIdentityRegistry.MetadataEntry, 10]) -> uint256:
    agentId: uint256 = self._nextAgentId
    self._nextAgentId += 1
    
    self.owners[agentId] = msg.sender
    self.balances[msg.sender] += 1
    self.tokenURIs[agentId] = agentURI
    
    for entry: IIdentityRegistry.MetadataEntry in metadataEntries:
        assert keccak256(entry.key) != keccak256(AGENT_WALLET_KEY), "Cannot set reserved key"
        self.metadata[agentId][entry.key] = entry.value
        log MetadataSet(agentId, entry.key, entry.key, entry.value)
    
    log Transfer(ZERO, msg.sender, agentId)
    log Registered(agentId, agentURI, msg.sender)
    return agentId

@external
def register_with_uri(agentURI: String[128]) -> uint256:
    agentId: uint256 = self._nextAgentId
    self._nextAgentId += 1
    self.owners[agentId] = msg.sender
    self.balances[msg.sender] += 1
    self.tokenURIs[agentId] = agentURI
    log Transfer(ZERO, msg.sender, agentId)
    log Registered(agentId, agentURI, msg.sender)
    return agentId

@external
def register() -> uint256:
    agentId: uint256 = self._nextAgentId
    self._nextAgentId += 1
    self.owners[agentId] = msg.sender
    self.balances[msg.sender] += 1
    log Transfer(ZERO, msg.sender, agentId)
    log Registered(agentId, "", msg.sender)
    return agentId

@view
@internal
def _isAuthorized(agentId: uint256, caller: address) -> bool:
    owner: address = self.owners[agentId]
    return (caller == owner) or (self.tokenApprovals[agentId] == caller) or (self.operatorApprovals[owner][caller])

@view
@external
def isAuthorized(agentId: uint256, caller: address) -> bool:
    return self._isAuthorized(agentId, caller)

@view
@external
def getAgentWallet(agentId: uint256) -> address:
    return self.agentWallets[agentId]

@view
@external
def totalAgents() -> uint256:
    return self._nextAgentId - 1