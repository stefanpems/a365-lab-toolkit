using System.Reflection;
using System.Security.Cryptography;
using Microsoft.Agents.A365.DevTools.Cli.Constants;
using Microsoft.Agents.A365.DevTools.Cli.Services;
using Microsoft.Extensions.Logging.Abstractions;

if (args is ["--pipe-check"])
{
    Console.WriteLine(Console.ReadLine() == "y" ? "stdin-forwarded" : "stdin-missing");
    return;
}
if (args is ["--exit-check"])
{
    Environment.ExitCode = 7;
    return;
}

var original = Environment.GetEnvironmentVariable(SessionAuthenticationProfile.DirectoryVariable);
var directory = Path.Combine(Path.GetTempPath(), "a365-profile-check-" + Guid.NewGuid().ToString("N"));
var shared = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AuthenticationConstants.ApplicationName);
var passed = 0;
void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException("FAIL: " + message);
    passed++;
    Console.WriteLine("PASS: " + message);
}
void Reject(Action action, string message)
{
    try { action(); }
    catch (InvalidOperationException) { Check(true, message); return; }
    throw new InvalidOperationException("FAIL: " + message);
}
try
{
    Environment.SetEnvironmentVariable(SessionAuthenticationProfile.DirectoryVariable, null);
    Check(SessionAuthenticationProfile.CacheDirectory == shared, "Unconfigured path calculation preserves the official default without opening it.");
    Reject(SessionAuthenticationProfile.RequireSession, "Session-only CLI refuses an unset profile.");
    var azure = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".azure");
    foreach (var invalid in new[] { "relative-profile", shared, Path.Combine(shared, "nested"), azure, Path.Combine(azure, "nested"),
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Path.GetPathRoot(directory)! })
    {
        Environment.SetEnvironmentVariable(SessionAuthenticationProfile.DirectoryVariable, invalid);
        Reject(() => _ = SessionAuthenticationProfile.RootDirectory, "Relative, root, home and shared-default profiles are rejected.");
    }
    Environment.SetEnvironmentVariable(SessionAuthenticationProfile.DirectoryVariable, directory);
    SessionAuthenticationProfile.RequireSession();
    Check(SessionAuthenticationProfile.CacheDirectory == Path.Combine(directory, "auth"), "Token cache belongs only to the session.");
    Check(ConfigService.GetGlobalConfigDirectory() == Path.Combine(directory, "config"), "CLI configuration and logs belong only to the session.");
    Directory.CreateDirectory(SessionAuthenticationProfile.CacheDirectory);
    var legacy = Path.Combine(SessionAuthenticationProfile.CacheDirectory, "auth-token.json");
    File.WriteAllText(legacy, "private-fixture");
    var authentication = new ProbeAuthentication();
    Check(!File.Exists(legacy), "Legacy cleanup is confined to the private profile.");
    if (OperatingSystem.IsWindows())
    {
        var plain = new byte[] { 1, 2, 3 };
        var encrypted = ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser);
        Check(ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser).SequenceEqual(plain),
            "The Windows DPAPI runtime encrypts and decrypts private cache material.");
    }
    Check(MsalBrowserCredential.MsalCacheFilePath.StartsWith(directory + Path.DirectorySeparatorChar), "Every MSAL caller shares the private cache location.");
    Reject(authentication.DeviceCode, "AuthenticationService never starts device-code authentication in session mode.");
    var credential = new MsalBrowserCredential(Guid.NewGuid().ToString(), Guid.NewGuid().ToString());
    Check(typeof(MsalBrowserCredential).GetField("_useWam", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(credential) is false,
        "Windows broker is disabled even for a caller requesting the native default.");
    var deviceFallback = typeof(MsalBrowserCredential).GetMethod("AcquireTokenWithDeviceCodeFallbackAsync", BindingFlags.NonPublic | BindingFlags.Instance)!;
    try
    {
        await (Task<Azure.Core.AccessToken>)deviceFallback.Invoke(credential, [new[] { "scope" }, CancellationToken.None])!;
        throw new Exception("FAIL: Device-code fallback was started.");
    }
    catch (InvalidOperationException)
    {
        Check(true, "MSAL device-code fallback fails before account lookup or network access.");
    }
    Console.WriteLine($"{passed} private CLI profile checks passed.");
}
finally
{
    Environment.SetEnvironmentVariable(SessionAuthenticationProfile.DirectoryVariable, original);
    if (Directory.Exists(directory)) Directory.Delete(directory, true);
}

sealed class ProbeAuthentication() : AuthenticationService(NullLogger<AuthenticationService>.Instance)
{
    public void DeviceCode() => CreateDeviceCodeCredential(Guid.NewGuid().ToString(), Guid.NewGuid().ToString());
}
