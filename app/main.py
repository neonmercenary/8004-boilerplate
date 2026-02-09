import asyncio
import os, json, requests
from contextlib import asynccontextmanager
from dotenv import load_dotenv
from ape import networks, Contract
from fastapi import FastAPI, BackgroundTasks, HTTPException, Request
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel

# Ape Framework Imports
from ape import networks, accounts, Contract, project

# Load environment variables
load_dotenv()

# --- CONFIGURATION ---
CONTRACT_ADDRESS = os.getenv("TASK_AGENT_ADDRESS")
AGENT_ALIAS = os.getenv("AGENT_ACCOUNT_ALIAS")
AGENT_PASSWORD = os.getenv("AGENT_PASS")    # This is not secure for production! Consider using a vault or secure secrets manager.
NETWORK_STRING = "avalanche:fuji:alchemy" # Matches your ape-config.yaml
STATE_FILE = "state.json"
IDENTITY_REGISTRY = os.getenv("IDENTITY_REGISTRY_ADDRESS") or "0x1aB8e9c3b1C2e5D7F4A9E6B8C3D2f5A6E7F8g9h0" # Replace with actual address after deployment
ROUTESCAN_API = "https://api.routescan.io/v2/network/testnet/evm/43113/etherscan/api"   # Routescan V2 API for Fuji


# --- SCHEMAS ---
class AgentStatus(BaseModel):
    address: str
    contract: str
    is_active: bool

# Initialize templates (make sure your folder is actually named 'frontend')
templates = Jinja2Templates(directory="frontend")



def load_state():
    try:
        with open(STATE_FILE, "r") as f:
            return json.load(f)
    except FileNotFoundError:
        return {"last_synced_block": 0}

def save_state(block_num):
    with open(STATE_FILE, "w") as f:
        json.dump({"last_synced_block": block_num}, f)

# --- WORKER LOGIC ---
async def surgical_blockchain_worker(app: FastAPI):
    print("🕵️ Surgical Worker Online: Monitoring via Routescan...")
    
    state = load_state()
    # If state is 0, start from current block to avoid massive backlogs
    last_processed_block = state["last_synced_block"] or networks.active_provider.get_block("latest").number

    while True:
        try:
            params = {
                "module": "account",
                "action": "txlist",
                "address": CONTRACT_ADDRESS,
                "startblock": last_processed_block + 1,
                "endblock": 99999999,
                "sort": "asc",
                "apikey": "any-string-works"
            }

            response = requests.get(ROUTESCAN_API, params=params)
            data = response.json()

            if data.get("status") == "1":
                tx_list = data.get("result", [])
                for tx in tx_list:
                    tx_hash = tx['hash']
                    receipt = networks.active_provider.get_receipt(tx_hash)
                    
                    if receipt.status == 1:
                        # Scan receipt for events decoded by Ape
                        for event in receipt.events:
                            if event.event_name == "TaskRequested":
                                args = event.event_arguments
                                task_id = args.get("taskId") or args.get("task_id")
                                print(f"🎯 Task Detected: {task_id} (TX: {tx_hash})")
                                asyncio.create_task(process_task(app, task_id))
                    
                    last_processed_block = int(tx['blockNumber'])
                    save_state(last_processed_block)
            
        except Exception as e:
            print(f"❌ Worker Error: {e}")

        await asyncio.sleep(30) # Longer sleep since we are fetching history



async def process_task(app, task_id: int):
    try:
        # Ensure task_id is an int
        t_id = int(task_id)
        print(f"🛠️ Starting Task #{t_id}...")
        
        # 1. On-chain start
        app.state.contract.startTask(t_id, sender=app.state.agent)
        
        # 2. AI Logic
        await asyncio.sleep(2) # Simulate processing
        
        # 3. On-chain completion
        print(f"✅ Completing Task #{t_id}...")
        receipt = app.state.contract.completeTask(
            t_id, 
            f"ipfs://result-{t_id}", 
            os.urandom(32), 
            sender=app.state.agent
        )
        print(f"🔗 Transaction Confirmed: {receipt.txn_hash}")
        
    except Exception as e:
        print(f"❌ Failed to process Task #{task_id}: {e}")

@asynccontextmanager
async def lifespan(app: FastAPI):
    with networks.parse_network_choice(NETWORK_STRING) as provider:
        # Load Agent
        app.state.agent = accounts.load(AGENT_ALIAS)
        app.state.agent.set_autosign(True, passphrase=AGENT_PASSWORD)
        
        # Load Contracts
        app.state.contract = Contract(CONTRACT_ADDRESS)
        # MUST load registry for whoami route to work
        app.state.registry = project.IdentityRegistry.at(IDENTITY_REGISTRY)
        
        worker_task = asyncio.create_task(surgical_blockchain_worker(app))
        print(f"🚀 Agent '{AGENT_ALIAS}' is live on {CONTRACT_ADDRESS}")
        yield
        worker_task.cancel()

# --- APP INIT ---
app = FastAPI(lifespan=lifespan)


if os.path.exists("static"):
    app.mount("/ui", StaticFiles(directory="static"), name="static")

# -- HEELPERS --
import urllib.parse

def clean_input(input_uri: str):
    if input_uri.startswith("data:"):
        # Splits 'data:text/plain,Hello%20AI' and gets 'Hello AI'
        return urllib.parse.unquote(input_uri.split(",")[-1])
    return input_uri


# --- ROUTES ---
@app.get("/")
async def serve_ui(request: Request):
    """Serves the ERC-8004 Dashboard."""
    return templates.TemplateResponse(
        "index.html", 
        {
            "request": request, 
            "contract_address": str(app.state.contract.address)
        }
    )

@app.get("/status", response_model=AgentStatus)
async def get_status():
    """Returns the current on-chain status of the agent."""
    return {
        "address": str(app.state.agent.address),
        "contract": str(app.state.contract.address),
        "is_active": True
    }

@app.get("/whoami")
async def who_am_i():
    agent_id = os.getenv("AGENT_ID")
    # You can even query the registry to prove you own the NFT
    owner = app.state.registry.ownerOf(agent_id)
    return {
        "agent_id": agent_id,
        "on_chain_owner": owner,
        "is_verified": owner == str(app.state.agent.address)
    }

@app.post("/manual-complete/{task_id}")
async def force_complete(task_id: int, background_tasks: BackgroundTasks):
    """Manual override to trigger a task completion via API."""
    background_tasks.add_task(process_task, app, task_id)
    return {"message": f"Task {task_id} processing queued."}