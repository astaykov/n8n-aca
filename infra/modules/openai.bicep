@description('Azure region for all resources')
param location string

@description('Unique suffix for resource names')
param resourceToken string

@description('Name for the Azure OpenAI model deployment. Must match the deployment name referenced in n8n workflow nodes.')
param deploymentName string = 'gpt-5.4'

@description('Azure OpenAI model to deploy (e.g. gpt-4o, gpt-4o-mini)')
param modelName string = 'gpt-4o'

@description('Version of the model to deploy')
param modelVersion string = '2024-11-20'

@description('Tokens-per-minute capacity (in thousands). 10 = 10K TPM.')
param tpmCapacity int = 10

@description('Deployment SKU. Use Standard for most regions; GlobalStandard for US regions with higher quota.')
param deploymentSku string = 'Standard'

@description('Tags to apply to all resources')
param tags object = {}

resource openAi 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: 'oai-${resourceToken}'
  location: location
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  tags: tags
  properties: {
    // Custom subdomain required for Azure OpenAI — must match resource name
    customSubDomainName: 'oai-${resourceToken}'
    publicNetworkAccess: 'Enabled'
  }
}

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openAi
  name: deploymentName
  sku: {
    name: deploymentSku
    capacity: tpmCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}

// Resource name (subdomain) is what n8n azureOpenAiApi credential expects
output resourceName string = openAi.name
output endpoint string = openAi.properties.endpoint
// API key is stored only in azd env (.azure/<env>/.env, gitignored) — never committed to source control
#disable-next-line outputs-should-not-contain-secrets
output apiKey string = openAi.listKeys().key1
output deploymentName string = modelDeployment.name
