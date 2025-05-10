import requests

# GraphQL endpoint
url = "https://blue-api.morpho.org/graphql"

# GraphQL query
query = """
query {
  vaults(
    where: {
      chainId_in: [8453],
      whitelisted: true, 
      assetSymbol_in: ["USDC"], 
      totalAssetsUsd_gte: 1000000
    }
  ) {
    items {
      address
      symbol
      name
      dailyApys {
        netApy
      }
    }
  }
}
"""

def fetch_vaults():
    response = requests.post(
        url,
        json={'query': query},
        headers={"Content-Type": "application/json"}
    )
    response.raise_for_status()
    
    data = response.json()
    return data["data"]["vaults"]["items"]

def get_vault_with_highest_daily_apy(vaults):
    valid_vaults = [
        {
            **v,
            "dailyNetApy": v["dailyApys"]["netApy"] if v["dailyApys"] else None
        }
        for v in vaults if v["dailyApys"]
    ]

    top = max(valid_vaults, key=lambda v: v["dailyNetApy"], default=None)
    return top

if __name__ == "__main__":
    vaults = fetch_vaults()
    top_vault = get_vault_with_highest_daily_apy(vaults)
    print(top_vault)