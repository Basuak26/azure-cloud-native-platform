using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Worker;

var builder = Host.CreateApplicationBuilder(args);

// 1. Configuration & Key Vault Integration
var keyVaultUri = builder.Configuration["KeyVaultUri"];
if (!string.IsNullOrEmpty(keyVaultUri))
{
    builder.Configuration.AddAzureKeyVault(
        new Uri(keyVaultUri),
        new DefaultAzureCredential());
}

// 2. Application Insights
builder.Services.AddApplicationInsightsTelemetryWorkerService();

// 3. Service Bus Client via Dependency Injection
builder.Services.AddSingleton(sp =>
{
    var config = sp.GetRequiredService<IConfiguration>();
    var sbConn = config["ServiceBusConnection"];
    if (string.IsNullOrEmpty(sbConn))
        throw new ArgumentNullException(nameof(sbConn));
    
    return new ServiceBusClient(sbConn);
});


// 4. Register Background Service
builder.Services.AddHostedService<WorkProcessor>();

var host = builder.Build();
host.Run();
