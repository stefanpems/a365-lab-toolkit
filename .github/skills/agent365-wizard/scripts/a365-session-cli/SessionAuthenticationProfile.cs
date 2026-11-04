using System.Diagnostics;
using Microsoft.Agents.A365.DevTools.Cli.Constants;

namespace Microsoft.Agents.A365.DevTools.Cli.Services;

public static class SessionAuthenticationProfile
{
    public const string DirectoryVariable = "A365_SESSION_CONFIG_DIR";
    public static bool Enabled => !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(DirectoryVariable));

    public static string RootDirectory
    {
        get
        {
            var path = Environment.GetEnvironmentVariable(DirectoryVariable);
            if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
                throw new InvalidOperationException("Set A365_SESSION_CONFIG_DIR to an absolute, dedicated session directory.");
            var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
            var shared = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                AuthenticationConstants.ApplicationName);
            foreach (var forbidden in new[]
            {
                Path.GetPathRoot(full), Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), shared
            })
            {
                if (string.Equals(full, Path.TrimEndingDirectorySeparator(forbidden!), StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("The session profile cannot be a shared default, home or root directory.");
            }
            if (full.StartsWith(shared + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The session profile cannot be inside the shared default authentication store.");
            var azure = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".azure");
            if (string.Equals(full, azure, StringComparison.OrdinalIgnoreCase) ||
                full.StartsWith(azure + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The session profile cannot be inside the shared default Azure store.");
            return full;
        }
    }

    public static string CacheDirectory => Enabled
        ? Path.Combine(RootDirectory, "auth")
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AuthenticationConstants.ApplicationName);

    public static void RequireSession()
    {
        if (!Enabled) throw new InvalidOperationException("This session-only CLI refuses to run without A365_SESSION_CONFIG_DIR.");
        _ = RootDirectory;
    }

    public static void RejectDeviceCode()
    {
        if (Enabled)
            throw new InvalidOperationException("Device-code authentication is disabled for this session. Complete interactive browser authentication instead.");
    }

    public static Task OpenBrowserAsync(Uri uri)
    {
        RequireSession();
        var executable = Environment.GetEnvironmentVariable("A365_BROWSER_EXECUTABLE");
        var profile = Environment.GetEnvironmentVariable("A365_BROWSER_PROFILE");
        if (string.IsNullOrWhiteSpace(executable) || !File.Exists(executable) || string.IsNullOrWhiteSpace(profile))
            throw new InvalidOperationException("Set A365_BROWSER_EXECUTABLE and A365_BROWSER_PROFILE for the existing external Edge work profile.");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false };
        start.ArgumentList.Add("--profile-directory=" + profile);
        start.ArgumentList.Add(uri.AbsoluteUri);
        using var process = Process.Start(start)
            ?? throw new InvalidOperationException("Could not launch the configured external Edge profile.");
        return Task.CompletedTask;
    }
}
