import pytest
from ape import networks, accounts, project
from eth_utils import keccak

# --- FIXTURES ---

@pytest.fixture(scope="session")
def owner(accounts):
    return accounts[0]

@pytest.fixture(scope="session")
def user1(accounts):
    return accounts[1]

@pytest.fixture(scope="session")
def registries(owner):
    # Deploying registries locally for the test session
    identity = owner.deploy(project.IdentityRegistry)
    reputation = owner.deploy(project.ReputationRegistry, identity.address)
    validation = owner.deploy(project.ValidationRegistry, identity.address)
    return identity, reputation, validation

@pytest.fixture
def task_agent(owner, registries):
    identity, reputation, validation = registries
    return owner.deploy(
        project.TaskAgent,
        identity.address,
        reputation.address,
        validation.address
    )

# --- TESTS ---

def test_task_request_with_payment(task_agent, owner, user1):
    """Ported from Hardhat: Should request a task with payment"""
    # 1. Setup Agent
    task_agent.registerAgent("TaskAgent", "Demo", "ipfs://uri", sender=owner)
    
    # 2. Prepare Task (mimicking ethers.keccak256(toUtf8Bytes("test")))
    input_hash = keccak(text="test input")
    payment = "0.001 ether" 

    # 3. Act
    receipt = task_agent.requestTask(
        0, "ipfs://input", input_hash, 
        value=payment, 
        sender=user1
    )

    # 4. Assert
    # In Ape, you check events directly from the receipt
    assert len(receipt.events.filter(task_agent.TaskRequested)) == 1
    
    task = task_agent.getTask(1)
    assert task.requester == user1.address
    assert task.status == 0  # Pending
    assert task.payment == 10**15 # 0.001 ETH in wei


def test_register_agent_and_events(task_agent, owner):
    receipt = task_agent.registerAgent("TaskAgent", "Demo", "ipfs://uri", sender=owner)
    # Agent registered and state updated
    assert task_agent.isRegistered() is True
    assert int(task_agent.agentId()) > 0
    # Event emitted
    assert len(receipt.events.filter(task_agent.AgentRegistered)) == 1


def test_start_complete_withdraw(task_agent, owner, user1):
    # register
    task_agent.registerAgent("TaskAgent", "Demo", "ipfs://uri", sender=owner)

    # user requests task
    input_hash = keccak(text="some input")
    payment = "0.001 ether"
    req_receipt = task_agent.requestTask(0, "ipfs://input", input_hash, value=payment, sender=user1)
    # Ensure TaskRequested emitted
    assert len(req_receipt.events.filter(task_agent.TaskRequested)) == 1

    # Start task as owner
    start_receipt = task_agent.startTask(1, sender=owner)
    assert len(start_receipt.events.filter(task_agent.TaskStarted)) == 1
    t = task_agent.getTask(1)
    assert t.status == 1  # In progress

    # Complete task
    complete_receipt = task_agent.completeTask(1, "ipfs://out", keccak(text="out"), sender=owner)
    assert len(complete_receipt.events.filter(task_agent.TaskCompleted)) == 1
    t = task_agent.getTask(1)
    assert t.status == 2  # Completed

    # Withdraw funds as owner clears contract balance
    # Balance should be > 0 before withdraw
    assert task_agent.balance > 0
    task_agent.withdraw(sender=owner)
    assert task_agent.balance == 0


def test_cancel_task_refund(task_agent, owner, user1):
    task_agent.registerAgent("TaskAgent", "Demo", "ipfs://uri", sender=owner)
    input_hash = keccak(text="cancel")
    task_agent.requestTask(0, "ipfs://in", input_hash, value="0.001 ether", sender=user1)

    cancel_receipt = task_agent.cancelTask(1, sender=user1)
    assert len(cancel_receipt.events.filter(task_agent.TaskCancelled)) == 1
    t = task_agent.getTask(1)
    assert t.status == 4  # Cancelled


def test_give_feedback_records_in_reputation(task_agent, owner, user1, registries):
    identity, reputation, validation = registries
    # Register agent and request+complete a task
    task_agent.registerAgent("TaskAgent", "Demo", "ipfs://uri", sender=owner)
    input_hash = keccak(text="feedback")
    task_agent.requestTask(0, "ipfs://in", input_hash, value="0.001 ether", sender=user1)
    task_agent.startTask(1, sender=owner)
    task_agent.completeTask(1, "ipfs://out", keccak(text="out"), sender=owner)

    # Give feedback as requester
    rating = 5
    fb_receipt = task_agent.giveFeedback(1, rating, "Great", sender=user1)
    # Check reputation contract stored the feedback
    # readFeedback(agentId, clientAddress, feedbackIndex) -> (_value, valueDecimals, tag1, tag2, isRevoked)
    agent_id = int(task_agent.agentId())
    # The ReputationRegistry records the caller as the client; since TaskAgent
    # makes an external call, `msg.sender` at the reputation contract is the
    # TaskAgent contract address. Verify the feedback is stored under that.
    entry = reputation.readFeedback(agent_id, task_agent.address, 1)
    assert int(entry[0]) == rating