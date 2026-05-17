using Azure.Messaging.ServiceBus;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Configuration;

namespace Worker;

public class WorkProcessor : BackgroundService
{
    private readonly ServiceBusClient _client;
    private readonly IConfiguration _config;
    private readonly ILogger<WorkProcessor> _logger;
    private ServiceBusProcessor? _processor;

    public WorkProcessor(ServiceBusClient client, IConfiguration config, ILogger<WorkProcessor> logger)
    {
        _client = client;
        _config = config;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var queueName = _config["QueueName"] ?? "workqueue";
        
        var options = new ServiceBusProcessorOptions
        {
            AutoCompleteMessages = false,
            MaxConcurrentCalls = 10
        };

        _processor = _client.CreateProcessor(queueName, options);

        _processor.ProcessMessageAsync += MessageHandler;
        _processor.ProcessErrorAsync += ErrorHandler;

        await _processor.StartProcessingAsync(stoppingToken);
        _logger.LogInformation("WorkProcessor started listening on queue {QueueName}", queueName);

        // Wait indefinitely until cancellation is requested
        while (!stoppingToken.IsCancellationRequested)
        {
            await Task.Delay(1000, stoppingToken);
        }
    }

    private async Task MessageHandler(ProcessMessageEventArgs args)
    {
        var messageBody = args.Message.Body.ToString();
        _logger.LogInformation("Received message: {MessageId}. Body: {Body}", args.Message.MessageId, messageBody);

        try
        {
            // Simulate processing work
            await Task.Delay(500, args.CancellationToken);

            // Complete the message
            await args.CompleteMessageAsync(args.Message, args.CancellationToken);
            _logger.LogInformation("Successfully processed message: {MessageId}", args.Message.MessageId);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error processing message: {MessageId}. Dead-lettering.", args.Message.MessageId);
            // Dead-letter on failure to trigger dead-letter queue strategy
            await args.DeadLetterMessageAsync(args.Message, "ProcessingError", ex.Message, args.CancellationToken);
        }
    }

    private Task ErrorHandler(ProcessErrorEventArgs args)
    {
        _logger.LogError(args.Exception, "Service Bus error occurred on source: {ErrorSource}", args.ErrorSource);
        return Task.CompletedTask;
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        _logger.LogInformation("Stopping WorkProcessor...");
        if (_processor != null)
        {
            await _processor.StopProcessingAsync(cancellationToken);
            await _processor.DisposeAsync();
        }
        await base.StopAsync(cancellationToken);
    }
}
