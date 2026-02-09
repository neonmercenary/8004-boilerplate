import os
from ape import accounts, project, networks, Contract
from dotenv import load_dotenv

load_dotenv()

# --- OFFICIAL FUJI ADDRESSES (Do not change) ---
REGISTRIES = {
    "identity": "0x8004A818BFB912233c491871b3d84c89A494BD9e",
    "reputation": "0x8004B663056A597Dffe9eCcC1965A193B7388713",
    "validation": None  # You might deploy a custom one or use a shared TEE provider later
}

def main():
    # 1. Load Deployer
    deployer = accounts.load(os.getenv("AGENT_ACCOUNT_ALIAS"))
    print(f"🚀 Operator: {deployer.address} on {networks.active_provider.name}")

    # 2. Attach to Official Registries
    # We use the existing project interfaces but point to the official addresses
    identity_registry = project.IdentityRegistry.at(REGISTRIES["identity"])
    reputation_registry = project.ReputationRegistry.at(REGISTRIES["reputation"])
    
    print(f"🔗 Connected to Identity Registry: {identity_registry.address}")

    # 3. Register your Global Agent Identity
    # This mints your Agent ID NFT on the official registry.
    metadata_uri = "ipfs://YOUR_ACTUAL_METADATA_CID" # You need to upload your JSON first!
    
    # 3. Register your Global Agent Identity
    print("📝 Minting Agent Identity NFT...")
    # register() takes NO arguments in the official Fuji implementation
    receipt = identity_registry.register(sender=deployer)
    
    # Extract the Agent ID from the Transfer event
    # For ERC-721, the last log of a 'register' call is usually the mint Transfer
    agent_id = receipt.events.filter(identity_registry.Transfer)[0].tokenId
    print(f"🆔 Success! Your Global Agent ID is: {agent_id}")

    # 4. Set the Metadata URI
    print(f"🔗 Attaching metadata: {metadata_uri}")
    identity_registry.setTokenURI(agent_id, metadata_uri, sender=deployer)
    print("✅ Metadata URI successfully linked on-chain.")
    
    # Extract the Agent ID from the Transfer event (Identity is an ERC-721)
    agent_id = receipt.events.filter(identity_registry.Transfer)[0].tokenId
    print(f"🆔 Success! Your Global Agent ID is: {agent_id}")

    # 4. Deploy your Custom TaskAgent (Escrow/Logic)
    # We pass the official registry addresses so your contract can verify users
    print("🛠️ Deploying Custom TaskAgent logic...")
    task_agent = deployer.deploy(
        project.TaskAgent,
        identity_registry.address,
        reputation_registry.address,
        REGISTRIES["validation"] or "0x0000000000000000000000000000000000000000", # Use zero address if null
        agent_id, # Most ERC-8004 TaskAgents need to know which Agent ID they represent
        max_fee=35,
        max_priority_fee=10
    )
    
    print(f"✅ TaskAgent deployed to: {task_agent.address}")
    print("\n--- NEXT STEPS ---")
    print(f"1. Update .env with TASK_AGENT_ADDRESS={task_agent.address}")
    print(f"2. Update .env with AGENT_ID={agent_id}")