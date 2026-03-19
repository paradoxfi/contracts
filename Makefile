include .env

export $(shell sed 's/=.*//' .env)

remove:
	rm -rf .gitmodules && rm -rf .git/modules && rm -rf lib && touch .gitmodules 

install:
	forge install foundry-rs/forge-std --no-commit && forge install uniswap/v4-periphery --no-commit

build:
	forge build

clean:
	forge clean

update:
	forge update

test:
	forge test

mine-hook-addr:
	forge script script/MineAddress.s.sol:SuperHookAddressMiner

test-deploy-tokens:
	forge script script/01_DeployTokens.s.sol:DeployTokens --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY)

deploy-tokens:
	forge script script/01_DeployTokens.s.sol:DeployTokens --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY) --verify --broadcast

test-deploy-core:
	forge script script/02_DeployCore.s.sol:DeployCore --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY)

test-deploy-paradox:
	forge script script/03_DeployParadoxFi.s.sol:DeployParadoxFi --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY)

deploy-paradox:
	forge script script/03_DeployParadoxFi.s.sol:DeployParadoxFi --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY) --verify --broadcast

test-create-pool:
	forge script script/04_CreatePool.s.sol:CreatePool --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY)

create-pool:
	forge script script/04_CreatePool.s.sol:CreatePool --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY) --verify --broadcast

test-demo:
	forge script script/05_DemoParadoxFi.s.sol:Demo --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY)

demo:
	forge script script/05_DemoParadoxFi.s.sol:Demo --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY) --verify --broadcast

redeem-simulation:
	forge script script/06_RedeemSimulation.s.sol:RedeemSimulation --rpc-url $(RPC_URL) --sender $(SENDER)