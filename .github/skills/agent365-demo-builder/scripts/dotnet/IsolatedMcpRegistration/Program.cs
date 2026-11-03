using System.CommandLine;
using System.Text;
using System.Text.Json;
using Microsoft.Agents.A365.DevTools.Cli.Commands;
using Microsoft.Agents.A365.DevTools.Cli.Models;
using Microsoft.Agents.A365.DevTools.Cli.Services;
using Microsoft.Agents.A365.DevTools.Cli.Services.Helpers;
using Microsoft.Agents.A365.DevTools.Cli.Services.Internal;
using Microsoft.Extensions.Logging;

if (args is ["--self-test"])
    return await RegistrationChecks.RunAsync();

if (args.Length is < 1 or > 2 || !File.Exists(args[0]) ||
    (args.Length == 2 && args[1] != "--dry-run"))
    throw new ArgumentException("Supply one existing MCP registration payload and optionally --dry-run.");

var dryRun = args.Length == 2;
var payloadPath = Path.GetFullPath(args[0]);
var receiptPath = payloadPath + ".receipt.json";
if (!dryRun && File.Exists(receiptPath))
    throw new InvalidOperationException("A gateway submission receipt already exists. Reconcile it before any retry.");
var credentials = JsonSerializer.Deserialize<RegistrationCredentials>(
    Console.ReadLine() ?? throw new InvalidOperationException("Credentials must arrive through standard input."))
    ?? throw new InvalidOperationException("Invalid registration credential bundle.");
credentials.Validate();
Console.SetIn(new StringReader("y\n"));

var authentication = new IsolatedAuthentication(credentials);
using var transport = new RegistrationTransport(credentials.GatewayToken, receiptPath);
var executor = new CommandExecutor(new RegistrationLogger<CommandExecutor>());
var graph = new GraphApiService(new RegistrationLogger<GraphApiService>(), executor, authentication,
    loginHintResolver: () => Task.FromResult<string?>(credentials.LoginHint));
var root = new RootCommand();
root.AddCommand(DevelopMcpCommand.CreateCommand(new RegistrationLogger<Program>(), transport, null, graph));
var commandArgs = new List<string> { "develop-mcp", "register-external-mcp-server", "-f", payloadPath };
if (dryRun) commandArgs.Add("--dry-run");
var exitCode = await root.InvokeAsync(commandArgs.ToArray());
if (!dryRun && exitCode == 0 && !transport.Submitted)
    throw new InvalidOperationException("The official executor did not submit a successful gateway registration.");
return exitCode;

public sealed record RegistrationCredentials(
    string TenantId, string LoginHint, string GraphToken, string GatewayToken)
{
    public override string ToString() => "Registration credentials (private tokens redacted)";

    public void Validate()
    {
        if (!Guid.TryParse(TenantId, out _) || string.IsNullOrWhiteSpace(LoginHint) ||
            string.IsNullOrWhiteSpace(GraphToken) || string.IsNullOrWhiteSpace(GatewayToken))
            throw new InvalidOperationException("The isolated credential bundle is incomplete.");
        using var graph = ReadClaims(GraphToken);
        using var gateway = ReadClaims(GatewayToken);
        ValidateClaims(graph.RootElement, ["https://graph.microsoft.com", "00000003-0000-0000-c000-000000000000"]);
        ValidateClaims(gateway.RootElement, ["ea9ffc3e-8a23-4a7d-836d-234d7c7565c1"]);
        if (graph.RootElement.GetProperty("oid").GetString() != gateway.RootElement.GetProperty("oid").GetString())
            throw new InvalidOperationException("Graph and gateway tokens belong to different users.");
    }

    private static JsonDocument ReadClaims(string token)
    {
        var parts = token.Split('.');
        if (parts.Length != 3) throw new InvalidOperationException("Expected a JWT access token.");
        var payload = parts[1].Replace('-', '+').Replace('_', '/');
        payload = payload.PadRight((payload.Length + 3) / 4 * 4, '=');
        return JsonDocument.Parse(Convert.FromBase64String(payload));
    }

    private void ValidateClaims(JsonElement claims, string[] audiences)
    {
        var account = claims.TryGetProperty("preferred_username", out var preferred) ? preferred.GetString()
            : claims.TryGetProperty("upn", out var upn) ? upn.GetString() : null;
        if (!string.Equals(claims.GetProperty("tid").GetString(), TenantId, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(account, LoginHint, StringComparison.OrdinalIgnoreCase) ||
            !audiences.Contains(claims.GetProperty("aud").GetString()) ||
            claims.GetProperty("exp").GetInt64() <= DateTimeOffset.UtcNow.AddMinutes(2).ToUnixTimeSeconds())
            throw new InvalidOperationException("Token tenant, account, audience or expiration does not match the lab.");
    }
}

public sealed class IsolatedAuthentication(RegistrationCredentials credentials) : IAuthenticationService
{
    public Task<string> GetAccessTokenAsync(
        string resourceUrl, string? tenantId = null, bool forceRefresh = false,
        string? clientId = null, IEnumerable<string>? scopes = null,
        bool useInteractiveBrowser = true, string? userId = null, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        if (tenantId is not null && !string.Equals(tenantId, credentials.TenantId, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The official executor requested a different tenant.");
        if (forceRefresh)
            throw new InvalidOperationException("Token refresh is required; refresh only the lab-private session and retry.");
        return Task.FromResult(resourceUrl.TrimEnd('/') switch
        {
            "https://graph.microsoft.com" or "00000003-0000-0000-c000-000000000000" => credentials.GraphToken,
            "ea9ffc3e-8a23-4a7d-836d-234d7c7565c1" => credentials.GatewayToken,
            _ => throw new InvalidOperationException("The official executor requested an unsupported token audience.")
        });
    }

    public Task<string?> ResolveLoginHintFromCacheAsync() => Task.FromResult<string?>(credentials.LoginHint);

    public Task ClearTokenCacheAsync() =>
        throw new InvalidOperationException("This host never clears a shared cache. Refresh the lab-private tokens explicitly.");
}

public sealed class RegistrationTransport : IAgent365ToolingService, IDisposable
{
    private readonly HttpClient client;
    private readonly string receiptPath;
    private readonly string correlationId = Guid.NewGuid().ToString();
    public string Environment => "prod";
    public bool Submitted { get; private set; }

    public RegistrationTransport(string gatewayToken, string receiptPath, HttpMessageHandler? handler = null)
    {
        client = HttpClientFactory.CreateAuthenticatedClient(gatewayToken, correlationId: correlationId, handler: handler);
        this.receiptPath = receiptPath;
    }

    public Task LogRegisterUsageAsync(string serverName, string authType, int toolCount,
        CancellationToken cancellationToken = default)
    {
        Console.WriteLine("Registration usage telemetry is not sent by the isolated transport.");
        return Task.CompletedTask;
    }

    public async Task<AddMcpServerResponse?> AddMcpServerAsync(
        AddMcpServerRequest request, string? environmentId = null, CancellationToken cancellationToken = default)
    {
        if (!string.IsNullOrWhiteSpace(environmentId))
            client.DefaultRequestHeaders.Add("x-ms-environment-id", environmentId);
        using var content = new StringContent(JsonSerializer.Serialize(request), Encoding.UTF8, "application/json");
        using var response = await client.PostAsync(
            "https://agent365.svc.cloud.microsoft/agents/externalMcpServers/add", content, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
            throw new HttpRequestException($"MCP gateway registration failed with HTTP {(int)response.StatusCode} (correlation {correlationId}).");
        using var document = JsonDocument.Parse(body);
        if (document.RootElement.ValueKind == JsonValueKind.String)
            body = document.RootElement.GetString() ?? throw new InvalidOperationException("Empty gateway response.");
        var result = JsonSerializer.Deserialize<AddMcpServerResponse>(body)
            ?? throw new InvalidOperationException("The gateway returned no registration result.");
        if (!result.IsSuccess)
            throw new InvalidOperationException($"The gateway rejected registration (correlation {correlationId}).");
        File.WriteAllText(receiptPath, JsonSerializer.Serialize(new
        {
            serverName = request.ServerName, status = result.Status,
            submittedAt = DateTimeOffset.UtcNow, correlationId
        }));
        Submitted = true;
        return result;
    }

    public Task<DataverseEnvironmentsResponse?> ListEnvironmentsAsync(CancellationToken cancellationToken = default) =>
        throw new NotSupportedException("Environment discovery is outside this registration host.");
    public Task<DataverseMcpServersResponse?> ListServersAsync(string environmentId, CancellationToken cancellationToken = default) =>
        throw new NotSupportedException("Server discovery is outside this registration host.");
    public Task<PublishMcpServerResponse?> PublishServerAsync(string environmentId, string serverName, PublishMcpServerRequest request,
        CancellationToken cancellationToken = default) => throw new NotSupportedException("Publishing requires the separate approval gate.");
    public Task<bool> UnpublishServerAsync(string environmentId, string serverName, CancellationToken cancellationToken = default) =>
        throw new NotSupportedException("Unpublishing is outside this registration host.");
    public Task LogEvaluateUsageAsync(CancellationToken cancellationToken = default) =>
        throw new NotSupportedException("Evaluation is outside this registration host.");
    public Task<ProvisionIdentityResponse?> ProvisionIdentityAsync(string serverName, CancellationToken cancellationToken = default) =>
        throw new NotSupportedException("Identity provisioning is outside this registration host.");
    public Task<CleanupMcpServerResponse?> DeleteMcpServerAsync(string serverName, bool force = false,
        CancellationToken cancellationToken = default) => throw new NotSupportedException("Deletion is outside this registration host.");
    public void Dispose() => client.Dispose();
}

public sealed class RegistrationLogger<T> : ILogger<T>
{
    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
    public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Information;
    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
        Func<TState, Exception?, string> formatter)
    {
        if (IsEnabled(logLevel)) Console.Error.WriteLine($"{logLevel}: {formatter(state, exception)}");
    }
}
