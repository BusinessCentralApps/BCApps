using BcDevEnv.Cli.Cli;
using BcDevEnv.Cli.Infra;

namespace BcDevEnv.Cli.Commands;

/// <summary>Container lifecycle (start/stop/remove) and listing, via the docker CLI.</summary>
public static class LifecycleCommands
{
    public static int Start(ParsedArgs a)
    {
        Docker.RequireWindowsContainers();
        var image = a.Require("image");
        var name = a.GetOr("name", "bcdevenv");
        // Host port for client services -> container 7046. Must not be 7048/7049, which are mapped
        // straight through below; defaulting to 7049 would collide ("port already exists").
        var port = a.GetOr("port", "7046");

        var args = new List<string> { "run" };
        if (a.Flag("detach")) args.Add("-d");
        args.AddRange(new[] { "--name", name, "-e", "ACCEPT_EULA=Y" });
        args.AddRange(new[] { "-p", $"{port}:7046" });   // client services
        args.AddRange(new[] { "-p", "7048:7048" });      // OData/API
        args.AddRange(new[] { "-p", "7049:7049" });      // developer services
        args.Add(image);

        Log.Info($"Starting container '{name}' from '{image}' (client services on host port {port})...");
        return ProcessRunner.Run("docker", args);
    }

    public static int Stop(ParsedArgs a)
    {
        var name = a.GetOr("name", "bcdevenv");
        Log.Info($"Stopping container '{name}'...");
        return ProcessRunner.Run("docker", new[] { "stop", name });
    }

    public static int Remove(ParsedArgs a)
    {
        var name = a.GetOr("name", "bcdevenv");
        string? image = null;
        if (a.Flag("purge-image"))
        {
            var (code, stdout, _) = ProcessRunner.Capture("docker",
                new[] { "inspect", "--format", "{{.Config.Image}}", name });
            if (code == 0) image = stdout.Trim();
        }
        Log.Info($"Removing container '{name}'...");
        ProcessRunner.Run("docker", new[] { "rm", "-f", name });
        if (!string.IsNullOrWhiteSpace(image))
        {
            Log.Info($"Removing image '{image}'...");
            ProcessRunner.Run("docker", new[] { "rmi", image });
        }
        return 0;
    }

    public static int List(ParsedArgs a)
    {
        Console.WriteLine("Environments:");
        var home = Paths.Home;
        if (Directory.Exists(home))
        {
            foreach (var dir in Directory.GetDirectories(home))
            {
                var manifestPath = Path.Combine(dir, "manifest.json");
                if (!File.Exists(manifestPath)) continue;
                try
                {
                    var m = EnvManifest.Load(dir);
                    var apps = m.AppFiles.Count;
                    Console.WriteLine($"  {m.Name,-28} platform={m.PlatformVersion,-14} country={m.Country,-4} apps={apps}");
                }
                catch { Console.WriteLine($"  {Path.GetFileName(dir)} (unreadable manifest)"); }
            }
        }
        else
        {
            Console.WriteLine($"  (none - {home} does not exist)");
        }

        Console.WriteLine();
        Console.WriteLine("Images:");
        var (code, images, _) = ProcessRunner.Capture("docker",
            new[] { "images", "--filter", "reference=*bcdevenv*", "--format", "  {{.Repository}}:{{.Tag}}  ({{.Size}})" });
        Console.WriteLine(code == 0 && images.Trim().Length > 0 ? images.TrimEnd() : "  (docker unavailable or none)");
        return 0;
    }
}
