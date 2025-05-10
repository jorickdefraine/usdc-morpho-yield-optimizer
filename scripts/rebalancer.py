import os
from web3 import Web3
from eth_account import Account
from get_vault_with_highest_daily_apy import get_vault_with_highest_daily_apy
from dotenv import load_dotenv

# Load environment variables
load_dotenv()
RPC_URL = os.getenv("RPC_URL", "https://mainnet.base.org")
PRIVATE_KEY = os.getenv("PRIVATE_KEY")
CONTRACT_ADDRESS = os.getenv("CONTRACT_ADDRESS")

ABI = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "_asset",
        "type": "address",
        "internalType": "contract IERC20"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "allowance",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "spender",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "approve",
    "inputs": [
      {
        "name": "spender",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "asset",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "balanceOf",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "convertToAssets",
    "inputs": [
      {
        "name": "shares",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "convertToShares",
    "inputs": [
      {
        "name": "assets",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "decimals",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint8",
        "internalType": "uint8"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "decreaseAllowance",
    "inputs": [
      {
        "name": "spender",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "subtractedValue",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "deployToMorpho",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "deposit",
    "inputs": [
      {
        "name": "assets",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "receiver",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "shares",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "increaseAllowance",
    "inputs": [
      {
        "name": "spender",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "addedValue",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "maxDeposit",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "maxMint",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "maxRedeem",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "maxWithdraw",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "mint",
    "inputs": [
      {
        "name": "shares",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "receiver",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "morphoVault",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IERC4626"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "name",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "owner",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "previewDeposit",
    "inputs": [
      {
        "name": "assets",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "previewMint",
    "inputs": [
      {
        "name": "shares",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "previewRedeem",
    "inputs": [
      {
        "name": "shares",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "previewWithdraw",
    "inputs": [
      {
        "name": "assets",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "redeem",
    "inputs": [
      {
        "name": "shares",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "receiver",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "renounceOwnership",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setMorphoVault",
    "inputs": [
      {
        "name": "vault",
        "type": "address",
        "internalType": "contract IERC4626"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "symbol",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "totalAssets",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "totalSupply",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "transfer",
    "inputs": [
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "transferFrom",
    "inputs": [
      {
        "name": "from",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "transferOwnership",
    "inputs": [
      {
        "name": "newOwner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "withdraw",
    "inputs": [
      {
        "name": "assets",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "receiver",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "shares",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "withdrawFromMorpho",
    "inputs": [
      {
        "name": "shares",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "Approval",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      },
      {
        "name": "spender",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      },
      {
        "name": "value",
        "type": "uint256",
        "indexed": False,
        "internalType": "uint256"
      }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "AssetsDeployed",
    "inputs": [
      {
        "name": "assets",
        "type": "uint256",
        "indexed": False,
        "internalType": "uint256"
      }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "AssetsWithdrawn",
    "inputs": [
      {
        "name": "assetsReceived",
        "type": "uint256",
        "indexed": False,
        "internalType": "uint256"
      },
      {
        "name": "sharesBurned",
        "type": "uint256",
        "indexed": False,
        "internalType": "uint256"
      }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "Deposit",
    "inputs": [
      {
        "name": "sender",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      },
      {
        "name": "owner",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      },
      {
        "name": "assets",
        "type": "uint256",
        "indexed": False,
        "internalType": "uint256"
      },
      {
        "name": "shares",
        "type": "uint256",
        "indexed": False,
        "internalType": "uint256"
      }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "MorphoVaultUpdated",
    "inputs": [
      {
        "name": "vault",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "OwnershipTransferred",
    "inputs": [
      {
        "name": "previousOwner",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      },
      {
        "name": "newOwner",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "Transfer",
    "inputs": [
      {
        "name": "from",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      },
      {
        "name": "to",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      },
      {
        "name": "value",
        "type": "uint256",
        "indexed": False,
        "internalType": "uint256"
      }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "VaultDeposit",
    "inputs": [
      {
        "name": "caller",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      },
      {
        "name": "receiver",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      },
      {
        "name": "assets",
        "type": "uint256",
        "indexed": False,
        "internalType": "uint256"
      },
      {
        "name": "shares",
        "type": "uint256",
        "indexed": False,
        "internalType": "uint256"
      }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "VaultWithdraw",
    "inputs": [
      {
        "name": "caller",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      },
      {
        "name": "receiver",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      },
      {
        "name": "owner",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      },
      {
        "name": "assets",
        "type": "uint256",
        "indexed": False,
        "internalType": "uint256"
      },
      {
        "name": "shares",
        "type": "uint256",
        "indexed": False,
        "internalType": "uint256"
      }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "Withdraw",
    "inputs": [
      {
        "name": "sender",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      },
      {
        "name": "receiver",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      },
      {
        "name": "owner",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      },
      {
        "name": "assets",
        "type": "uint256",
        "indexed": False,
        "internalType": "uint256"
      },
      {
        "name": "shares",
        "type": "uint256",
        "indexed": False,
        "internalType": "uint256"
      }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "WithdrawalFailed",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": True,
        "internalType": "address"
      },
      {
        "name": "requested",
        "type": "uint256",
        "indexed": False,
        "internalType": "uint256"
      },
      {
        "name": "available",
        "type": "uint256",
        "indexed": False,
        "internalType": "uint256"
      }
    ],
    "anonymous": False
  }
]

# Initialize Web3 with Base compatibility
w3 = Web3(Web3.HTTPProvider(RPC_URL))

# Handle POA middleware for Base (new Web3.py versions)
#try:
from web3.middleware import geth_poa_middleware
w3.middleware_onion.inject(geth_poa_middleware, layer=0)
#except ImportError:
    # Fallback for newer Web3.py versions that handle Base natively
#    if 'base' in RPC_URL:
#        w3.eth.chain_id = 8453  # Explicitly set Base chain ID

assert w3.is_connected(), "Failed to connect to RPC"

# Contract ABI - REPLACE WITH YOUR ACTUAL ABI
ABI = [
    {
        "inputs": [{"internalType": "uint256", "name": "shares", "type": "uint256"}],
        "name": "withdrawFromMorpho",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "deployToMorpho",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "totalAssets",
        "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [{"internalType": "address", "name": "account", "type": "address"}],
        "name": "balanceOf",
        "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function"
    }
]

contract = w3.eth.contract(address=CONTRACT_ADDRESS, abi=ABI)

def get_share_balance():
    """Get current shares in Morpho"""
    return contract.functions.balanceOf(contract.address).call()

def safe_withdraw():
    try:
        shares = get_share_balance()
        if shares == 0:
            print("No shares to withdraw")
            return None
        
        # Withdraw 95% to avoid edge cases
        shares_to_withdraw = int(shares * 0.95)
        
        tx = contract.functions.withdrawFromMorpho(shares_to_withdraw).build_transaction({
            'chainId': 8453,
            'gas': 300000,
            'maxFeePerGas': w3.to_wei('0.1', 'gwei'),
            'maxPriorityFeePerGas': w3.to_wei('0.05', 'gwei'),
            'nonce': w3.eth.get_transaction_count(Account.from_key(PRIVATE_KEY).address),
        })
        
        signed = Account.from_key(PRIVATE_KEY).sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
        print(f"Withdrew {shares_to_withdraw/1e6:.2f} shares (95% of balance)")
        return tx_hash
    except Exception as e:
        print(f"Withdrawal failed: {e}")
        return None

def deploy_assets():
    """Deploy available USDC to Morpho"""
    try:
        usdc_balance = contract.functions.totalAssets().call() - contract.functions.balanceOf(contract.address).call()
        if usdc_balance < 10000:  # Skip if < 0.01 USDC
            print(f"Only {usdc_balance/1e6:.4f} USDC available - skipping deploy")
            return None
            
        tx = contract.functions.deployToMorpho().build_transaction({
            'chainId': 8453,
            'gas': 400000,
            'maxFeePerGas': w3.to_wei('0.1', 'gwei'),
            'maxPriorityFeePerGas': w3.to_wei('0.05', 'gwei'),
            'nonce': w3.eth.get_transaction_count(Account.from_key(PRIVATE_KEY).address),
        })
        
        signed = Account.from_key(PRIVATE_KEY).sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
        print(f"Deployed {usdc_balance/1e6:.2f} USDC to Morpho")
        return tx_hash
    except Exception as e:
        print(f"Deployment failed: {e}")
        return None

def set_new_market(new_market_address):
    """Update Morpho vault address if different"""
    current_market = contract.functions.morphoVault().call()
    if new_market_address.lower() == current_market.lower():
        print("Market address unchanged")
        return None
        
    try:
        tx = contract.functions.setMorphoVault(new_market_address).build_transaction({
            'chainId': 8453,
            'gas': 250000,
            'maxFeePerGas': w3.to_wei('0.1', 'gwei'),
            'maxPriorityFeePerGas': w3.to_wei('0.05', 'gwei'),
            'nonce': w3.eth.get_transaction_count(Account.from_key(PRIVATE_KEY).address),
        })
        
        signed = Account.from_key(PRIVATE_KEY).sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
        print(f"Updated Morpho market to {new_market_address}")
        return tx_hash
    except Exception as e:
        print(f"Market update failed: {e}")
        return None

def rebalance(new_market_address=None):
    if new_market_address:
        if market_tx := set_new_market(new_market_address):
            w3.eth.wait_for_transaction_receipt(market_tx)
    
    # 1. Withdraw from current market
    if withdraw_tx := safe_withdraw():
        w3.eth.wait_for_transaction_receipt(withdraw_tx)
    
    # 2. Deploy to new market
    deploy_assets()

if __name__ == "__main__":
    try:
        new_market = get_vault_with_highest_daily_apy()
        print(f"Optimal market: {new_market}")
        rebalance(new_market)
    except Exception as e:
        print(f"Rebalance failed: {e}")