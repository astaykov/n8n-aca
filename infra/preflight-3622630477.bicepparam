using 'main.bicep'

param cpuCores = '1'

param entraTenantId = '06a05be1-33df-4feb-9009-95c7a27a7a49'

param fileShareName = 'n8ndata'

param location = 'northeurope'

param memorySize = '2Gi'

param n8nImage = 'docker.n8n.io/n8nio/n8n:latest'

param openAiDeploymentName = 'gpt-4o'

param openAiDeploymentSku = 'GlobalStandard'

param openAiLocation = 'eastus2'

param openAiModelName = 'gpt-4o'

param openAiModelVersion = '2024-11-20'

param openAiResourceGroupName = 'rg-n8n-openai-8'

param openAiTpmCapacity = 50

param resourceGroupName = 'rg-n8n-test-11'
