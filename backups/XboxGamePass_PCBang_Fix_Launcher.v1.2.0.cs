using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;

[assembly: AssemblyTitle("XboxGamePass_PCBang_Fix")]
[assembly: AssemblyDescription("Repairs blocked Windows Update services and refreshes root certificates")]
[assembly: AssemblyCompany("")]
[assembly: AssemblyProduct("XboxGamePass_PCBang_Fix")]
[assembly: AssemblyCopyright("")]
[assembly: AssemblyTrademark("")]
[assembly: AssemblyVersion("1.2.0.0")]
[assembly: AssemblyFileVersion("1.2.0.0")]

internal static class Program
{
    private const string ScriptFileName = "XboxGamePass_PCBang_Fix.ps1";

    private static int Main(string[] args)
    {
        try
        {
            if (!IsAdministrator())
            {
                return RelaunchElevated(args);
            }

            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string scriptPath = ResolveScriptPath(baseDir);

            string powershellPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershellPath))
            {
                powershellPath = "powershell.exe";
            }

            var psi = new ProcessStartInfo
            {
                FileName = powershellPath,
                Arguments = BuildPowerShellArguments(scriptPath, args),
                WorkingDirectory = baseDir,
                UseShellExecute = false
            };

            using (Process child = Process.Start(psi))
            {
                child.WaitForExit();
                return child.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Unexpected launcher error:");
            Console.Error.WriteLine(ex.Message);
            Pause();
            return 99;
        }
    }

    private static string ResolveScriptPath(string baseDir)
    {
        string adjacentScriptPath = Path.Combine(baseDir, ScriptFileName);
        if (File.Exists(adjacentScriptPath))
        {
            return adjacentScriptPath;
        }

        string resourceName = FindEmbeddedScriptResource();
        if (resourceName == null)
        {
            throw new FileNotFoundException("Missing script: " + adjacentScriptPath);
        }

        string extractDir = Path.Combine(Path.GetTempPath(), "XboxGamePass_PCBang_Fix");
        Directory.CreateDirectory(extractDir);

        string extractedScriptPath = Path.Combine(extractDir, ScriptFileName);
        using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName))
        using (FileStream output = File.Create(extractedScriptPath))
        {
            input.CopyTo(output);
        }

        return extractedScriptPath;
    }

    private static string FindEmbeddedScriptResource()
    {
        string[] resourceNames = Assembly.GetExecutingAssembly().GetManifestResourceNames();
        foreach (string resourceName in resourceNames)
        {
            if (resourceName.EndsWith(ScriptFileName, StringComparison.OrdinalIgnoreCase))
            {
                return resourceName;
            }
        }

        return null;
    }

    private static bool IsAdministrator()
    {
        using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
        {
            var principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
    }

    private static int RelaunchElevated(string[] args)
    {
        string selfPath = Process.GetCurrentProcess().MainModule.FileName;
        var psi = new ProcessStartInfo
        {
            FileName = selfPath,
            Arguments = JoinQuoted(args),
            WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory,
            UseShellExecute = true,
            Verb = "runas"
        };

        try
        {
            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Administrator elevation is required.");
            Console.Error.WriteLine(ex.Message);
            Pause();
            return 1;
        }
    }

    private static string JoinQuoted(string[] args)
    {
        if (args == null || args.Length == 0)
        {
            return string.Empty;
        }

        string[] quoted = new string[args.Length];
        for (int i = 0; i < args.Length; i++)
        {
            quoted[i] = Quote(args[i]);
        }

        return string.Join(" ", quoted);
    }

    private static string BuildPowerShellArguments(string scriptPath, string[] args)
    {
        string scriptArguments = JoinQuoted(args);
        string command = "-NoProfile -ExecutionPolicy Bypass -File " + Quote(scriptPath);
        if (!string.IsNullOrEmpty(scriptArguments))
        {
            command += " " + scriptArguments;
        }

        return command;
    }

    private static string Quote(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "\"\"";
        }

        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static void Pause()
    {
        Console.WriteLine("Press Enter to exit.");
        Console.ReadLine();
    }
}
