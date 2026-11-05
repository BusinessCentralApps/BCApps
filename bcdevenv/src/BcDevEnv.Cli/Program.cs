using BcDevEnv.Cli.Cli;
using BcDevEnv.Cli.Commands;
using BcDevEnv.Cli.Infra;

// bcdevenv - .NET 10 CLI entrypoint. Dispatches to a command handler.
// The BC management operations are driven in-process via the PowerShell SDK
// (see NavRunspace); SQL steps go directly through ADO.NET. No .ps1 scripts.

if (args.Length == 0)
{
    Console.WriteLine(HelpText.Root);
    return 1;
}

var command = args[0].ToLowerInvariant();
var rest = args.Skip(1).ToList();

if (command is "help" or "-h" or "--help")
{
    Console.WriteLine(HelpText.For(rest.FirstOrDefault()));
    return 0;
}

// Switch flags (take no value) recognised across commands.
var switches = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
{
    "push", "detach", "purge-image", "verbose", "allow-failures", "allow-empty", "evaluation-company",
};

var parsed = ParsedArgs.Parse(rest, switches);
if (parsed.Flag("verbose")) Log.VerboseEnabled = true;

try
{
    return command switch
    {
        "create-env" => CreateEnvCommand.Run(parsed),
        "verify" => VerifyCommand.Run(parsed),
        "install-app" => InstallAppCommand.Run(parsed),
        "run-tests" => RunTestsCommand.Run(parsed),
        "build-image" => BuildImageCommand.Run(parsed),
        "provision" => ProvisionCommand.Run(parsed),
        "serve" => ServeCommand.Run(parsed),
        "start" => LifecycleCommands.Start(parsed),
        "stop" => LifecycleCommands.Stop(parsed),
        "remove" => LifecycleCommands.Remove(parsed),
        "list" => LifecycleCommands.List(parsed),
        _ => Unknown(command),
    };
}
catch (BcDevEnvException ex)
{
    Log.Error(ex.Message);
    return 1;
}
catch (Exception ex)
{
    Log.Error(ex.ToString());
    return 2;
}

static int Unknown(string command)
{
    Log.Error($"Unknown command '{command}'.");
    Console.WriteLine(HelpText.Root);
    return 1;
}
