// Fetches the Azure OpenAI API key via listKeys() in a dedicated module so that
// main.bicep can declare an explicit dependsOn on the openai module (account + model
// deployment). This guarantees the account's provisioningState is fully terminal before
// listKeys() is invoked, avoiding the RequestConflict 409 race condition that occurs
// when listKeys() is evaluated inside the openai module immediately after the model
// deployment settles.
param openAiName string

resource openAi 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: openAiName
}

#disable-next-line outputs-should-not-contain-secrets
output apiKey string = openAi.listKeys().key1
