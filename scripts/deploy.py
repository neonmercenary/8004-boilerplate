import os
from ape import accounts, project, networks

# For deploying your own global registries and TaskAgent logic (instead of using the official ones on whatever chain you're on), you can use this script. 
# It deploys new instances of the Identity, Reputation, and Validation registries, as well as a custom TaskAgent that points to them.


def main():
    # Load your dev account (make sure you've ran 'ape accounts import dev')
    deployer = accounts.load(os.getenv("AGENT_ACCOUNT_ALIAS"))  
    
    print(f"Deploying from: {deployer.address}")
    print(f"Network: {networks.active_provider.name}")

    # 1. Deploy Identity Registry
    # Assuming your contract names match these
    identity = deployer.deploy(project.IdentityRegistry)
    print(f"IdentityRegistry deployed to: {identity.address}")

    # 2. Deploy Reputation Registry
    reputation = deployer.deploy(project.ReputationRegistry, identity.address)  # Pass IdentityRegistry address if needed in __init__
    print(f"ReputationRegistry deployed to: {reputation.address}")

    # 3. Deploy Validation Registry (This should be left blank since its address is not required for the TaskAgent constructor, but you can deploy your own if you want to manage validations yourself instead of using a shared TEE provider)
    validation = deployer.deploy(project.ValidationRegistry, identity.address)
    print(f"ValidationRegistry deployed to: {validation.address}")

    # 4. Deploy TaskAgent
    # Passing the three registry addresses as required by your TaskAgent __init__
    agent = deployer.deploy(
        project.TaskAgent,
        identity.address,
        reputation.address,
        validation.address,
        max_fee=35,
        max_priority_fee=10  # Example max priority fee, adjust as needed
    )
    print(f"TaskAgent deployed to: {agent.address}")

    # Optional: Initial Agent Registration
    agent.registerAgent(
        "AvalancheAI", 
        "A decentralized task agent demo", 
        "ipfs://my-agent-metadata",
        sender=deployer
    )
    
    print("Deployment and Registration Complete!")