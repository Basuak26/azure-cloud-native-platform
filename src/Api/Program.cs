using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);

// 1. Configuration & Key Vault Integration
var keyVaultUri = builder.Configuration["KeyVaultUri"];
if (!string.IsNullOrEmpty(keyVaultUri))
{
    // Uses Managed Identity for secure access, no secrets in code
    builder.Configuration.AddAzureKeyVault(
        new Uri(keyVaultUri),
        new DefaultAzureCredential());
}

// 2. Observability: Application Insights
builder.Services.AddApplicationInsightsTelemetry();

// 3. Health Checks (Liveness and Readiness)
builder.Services.AddHealthChecks()
    .AddCheck("live", () => HealthCheckResult.Healthy("System is live"))
    .AddCheck("ready", () => HealthCheckResult.Healthy("System is ready to accept traffic"));

// 4. Service Bus Client via Dependency Injection
builder.Services.AddSingleton(sp =>
{
    var config = sp.GetRequiredService<IConfiguration>();
    var sbConn = config["ServiceBusConnection"];
    if (string.IsNullOrEmpty(sbConn))
        throw new ArgumentNullException(nameof(sbConn));
    
    return new ServiceBusClient(sbConn);
});


builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

var app = builder.Build();

app.UseSwagger();
app.UseSwaggerUI();

// Endpoints
app.MapHealthChecks("/health/live", new HealthCheckOptions { Predicate = check => check.Name == "live" });
app.MapHealthChecks("/health/ready", new HealthCheckOptions { Predicate = check => check.Name == "ready" });

app.MapGet("/api/work", () =>
{
    // In a full production system, this would query Azure Cosmos DB or SQL DB
    // where the background worker saves processed items.
    return Results.Ok(new[]
    {
        new { Id = Guid.NewGuid().ToString(), Status = "Processed", Timestamp = DateTime.UtcNow }
    });
})
.WithName("GetWorkItems")
.WithOpenApi();

app.MapPost("/api/work", async (WorkRequest req, ServiceBusClient client, IConfiguration config, ILogger<Program> logger) =>
{
    try
    {
        var queueName = config["QueueName"] ?? "workqueue";
        var sender = client.CreateSender(queueName);
        
        var messagePayload = JsonSerializer.Serialize(req);
        var message = new ServiceBusMessage(messagePayload);
        
        await sender.SendMessageAsync(message);
        logger.LogInformation("Successfully enqueued work item {Id}", req.Id);
        
        return Results.Accepted($"/api/work/{req.Id}", req);
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Error enqueuing work item");
        return Results.Problem("Failed to enqueue work item");
    }
})
.WithName("SubmitWorkItem")
.WithOpenApi();

app.Run();

public record WorkRequest(string Id, string Data);
