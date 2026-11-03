using System.CommandLine;
using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.Agents.A365.DevTools.Cli.Commands;
using Microsoft.Agents.A365.DevTools.Cli.Models;
using Microsoft.Agents.A365.DevTools.Cli.Services;

public static class RegistrationChecks
{
    private const string Tenant = "11111111-1111-1111-1111-111111111111";
    private const string User = "22222222-2222-2222-2222-222222222222";
    private const string Account = "admin@example.test";
    private const string Audience = "ea9ffc3e-8a23-4a7d-836d-234d7c7565c1";
    private static int passed;

    public static async Task<int> RunAsync()
    {
        var credentials = new RegistrationCredentials(Tenant, Account,
            Token("https://graph.microsoft.com"), Token(Audience));
        credentials.Validate();
        Check(true, "Matching private token context is accepted.");
        Reject(() => (credentials with { TenantId = Guid.NewGuid().ToString() }).Validate(), "Wrong tenant is rejected.");
        Reject(() => (credentials with { LoginHint = "other@example.test" }).Validate(), "Wrong account is rejected.");
        Reject(() => (credentials with { GraphToken = Token(Audience) }).Validate(), "Wrong Graph audience is rejected.");
        Reject(() => (credentials with { GatewayToken = Token("https://graph.microsoft.com") }).Validate(), "Wrong gateway audience is rejected.");
        Reject(() => (credentials with { GatewayToken = Token(Audience, oid: Guid.NewGuid().ToString()) }).Validate(), "Different token users are rejected.");
        Reject(() => (credentials with { GraphToken = Token("https://graph.microsoft.com", expired: true) }).Validate(), "Expired Graph token is rejected.");
        Reject(() => (credentials with { GatewayToken = Token(Audience, expired: true) }).Validate(), "Expired gateway token is rejected.");
        Reject(() => (credentials with { GatewayToken = "not-a-jwt" }).Validate(), "Malformed token is rejected.");
        Check(!credentials.ToString().Contains(credentials.GraphToken), "Credential formatting redacts tokens.");
        var authentication = new IsolatedAuthentication(credentials);
        Check(await authentication.GetAccessTokenAsync("https://graph.microsoft.com", Tenant) == credentials.GraphToken,
            "Graph requests use the supplied private token.");
        Reject(() => authentication.GetAccessTokenAsync("https://unknown.example.test"), "Unknown audience cannot trigger another authentication flow.");
        Reject(() => authentication.GetAccessTokenAsync("https://graph.microsoft.com", Guid.NewGuid().ToString()), "Cross-tenant requests fail before I/O.");
        Reject(() => authentication.GetAccessTokenAsync("https://graph.microsoft.com", forceRefresh: true), "Refresh never falls back to a shared cache.");
        Reject(() => authentication.ClearTokenCacheAsync(), "Shared caches cannot be cleared.");

        var directory = Path.Combine(Path.GetTempPath(), "a365-registration-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var receipt = Path.Combine(directory, "receipt.json");
        var payloadPath = Path.Combine(directory, "dry-run.json");
        try
        {
            File.WriteAllText(payloadPath, JsonSerializer.Serialize(new
            {
                serverName = "ext_Test", serverUrl = "https://example.test/mcp", authType = "NoAuth",
                description = "Offline registration fixture.", publisherName = "Test",
                tools = new[] { new { name = "test_tool", description = "Offline test tool." } }
            }));
            var gatewayTrap = new ReplyHandler(HttpStatusCode.InternalServerError, "");
            var graphTrap = new ReplyHandler(HttpStatusCode.InternalServerError, "");
            using (var transport = new RegistrationTransport("private-test-token", receipt, gatewayTrap))
            {
                var executor = new CommandExecutor(new RegistrationLogger<CommandExecutor>());
                var graph = new GraphApiService(new RegistrationLogger<GraphApiService>(), executor,
                    authentication, handler: graphTrap, loginHintResolver: () => Task.FromResult<string?>(Account));
                var command = new RootCommand();
                command.AddCommand(DevelopMcpCommand.CreateCommand(new RegistrationLogger<RegistrationTransport>(), transport, null, graph));
                var code = await command.InvokeAsync(["develop-mcp", "register-external-mcp-server", "-f", payloadPath, "--dry-run"]);
                Check(code == 0 && gatewayTrap.Calls == 0 && graphTrap.Calls == 0 && !File.Exists(receipt),
                    "Official dry run creates no Entra apps, submits no request and writes no receipt.");
            }
            foreach (var doubleSerialized in new[] { false, true })
            {
                var json = JsonSerializer.Serialize(new AddMcpServerResponse { Status = "Success" });
                if (doubleSerialized) json = JsonSerializer.Serialize(json);
                var handler = new ReplyHandler(HttpStatusCode.OK, json);
                using var transport = new RegistrationTransport("private-test-token", receipt, handler);
                await transport.AddMcpServerAsync(new AddMcpServerRequest { ServerName = "ext_Test" }, "environment-test");
                Check(transport.Submitted && File.Exists(receipt), "Only gateway success produces a submission receipt.");
                Check(handler.Calls == 1 && handler.ValidRequest, "Canonical endpoint, bearer token, environment and JSON request are preserved.");
                var text = File.ReadAllText(receipt);
                Check(!text.Contains("private-test-token") && text.Contains("ext_Test"), "Receipt records the server without token material.");
                File.Delete(receipt);
            }
            foreach (var reply in new[]
            {
                (HttpStatusCode.Forbidden, """{"error":"private-test-token"}"""),
                (HttpStatusCode.OK, ""),
                (HttpStatusCode.OK, "not-json"),
                (HttpStatusCode.OK, "null"),
                (HttpStatusCode.OK, """{"status":"Failed","message":"private-test-token"}""")
            })
            {
                var handler = new ReplyHandler(reply.Item1, reply.Item2);
                using var transport = new RegistrationTransport("private-test-token", receipt, handler);
                try
                {
                    await transport.AddMcpServerAsync(new AddMcpServerRequest { ServerName = "ext_Test" });
                    throw new Exception("FAIL: Invalid gateway response was accepted.");
                }
                catch (Exception exception) when (exception is HttpRequestException or JsonException or InvalidOperationException)
                {
                    Check(!transport.Submitted && !File.Exists(receipt), "Rejected, empty or malformed replies never report successful submission.");
                    Check(!exception.Message.Contains("private-test-token"), "Failure diagnostics do not echo private response material.");
                }
            }
        }
        finally
        {
            if (File.Exists(receipt)) File.Delete(receipt);
            if (File.Exists(payloadPath)) File.Delete(payloadPath);
            Directory.Delete(directory);
        }
        Console.WriteLine($"{passed} isolated registration checks passed.");
        return 0;
    }

    private static string Token(string audience, string oid = User, bool expired = false)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(new
        {
            aud = audience, tid = Tenant, oid, upn = Account,
            exp = DateTimeOffset.UtcNow.AddMinutes(expired ? -5 : 20).ToUnixTimeSeconds()
        });
        return "test." + Convert.ToBase64String(payload).TrimEnd('=').Replace('+', '-').Replace('/', '_') + ".test";
    }

    private static void Reject(Action action, string message)
    {
        try { action(); }
        catch (InvalidOperationException) { Check(true, message); return; }
        throw new Exception("FAIL: " + message);
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception("FAIL: " + message);
        passed++;
        Console.WriteLine("PASS: " + message);
    }

    private sealed class ReplyHandler(HttpStatusCode status, string body) : HttpMessageHandler
    {
        public int Calls { get; private set; }
        public bool ValidRequest { get; private set; }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++;
            var content = await request.Content!.ReadAsStringAsync(cancellationToken);
            ValidRequest = request.Method == HttpMethod.Post &&
                request.RequestUri?.AbsoluteUri == "https://agent365.svc.cloud.microsoft/agents/externalMcpServers/add" &&
                request.Headers.Authorization?.Scheme == "Bearer" &&
                request.Headers.Authorization?.Parameter == "private-test-token" &&
                request.Headers.TryGetValues("x-ms-environment-id", out var values) && values.Single() == "environment-test" &&
                content.Contains("ext_Test") && request.Content.Headers.ContentType?.MediaType == "application/json";
            return new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }
    }
}
