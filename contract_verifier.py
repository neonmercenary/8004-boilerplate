# Verifying your contract on Etherscan requires a specific JSON format. This script reads the compiled output from ApeWorX and transforms it into the required format for Etherscan verification.


import json

# Read your compiled output
with open('.build/__local__.json', 'r') as f:
    build_data = json.load(f)

# Extract the specific contract data
contract_name = "TaskAgent"  # Change this to your actual contract name if different
contract_data = build_data.get(contract_name, {})

# Standard JSON format for Etherscan
standard_json = {
    "language": "Vyper",
    "sources": {
        f"{contract_name}.vy": {
            "content": open(f"contracts/{contract_name}.vy").read()
        }
    },
    "settings": {
        "evmVersion": "shanghai",  # or your target version
        "outputSelection": {
            "*": ["evm.bytecode", "evm.deployedBytecode", "abi"]
        }
    }
}

# Save for upload
with open(f'verified_json_for_{contract_name}.json', 'w') as f:
    json.dump(standard_json, f, indent=2)