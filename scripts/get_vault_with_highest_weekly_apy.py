import requests

# GraphQL endpoint
url = "https://blue-api.morpho.org/graphql"

# GraphQL query
query = """
query {
  vaults(
    where: {
      chainId_in: [1],
      whitelisted: true, 
      assetSymbol_in: ["USDC"], 
      totalAssetsUsd_gte: 10000000
    }
  ) {
    items {
      address
      symbol
      name
      weeklyApys {
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

def get_vault_with_highest_weekly_apy(vaults):
    # Extract first weekly net APY and filter out missing data
    valid_vaults = [
        {
            **v,
            "weeklyNetApy": v["weeklyApys"]["netApy"] if v["weeklyApys"] else None
        }
        for v in vaults if v["weeklyApys"]
    ]

    # Sort and return top vault
    top = max(valid_vaults, key=lambda v: v["weeklyNetApy"], default=None)
    return top

if __name__ == "__main__":
    vaults = fetch_vaults()
    top_vault = get_vault_with_highest_weekly_apy(vaults)
    print(top_vault)