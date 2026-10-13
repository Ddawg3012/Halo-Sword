using System.Diagnostics;
using System.Text;

namespace HaloBridge;

/// Melty starts this instead of the game:
///   HaloBridge.exe --game "{game}" --halo "{game:halo-mcc}" [--extract-only] [--test]
/// 1. reads the Elite and Brute models and the announcer lines from the player's own MCC (cached in runtime/),
/// 2. starts Half Sword,
/// 3. tails runtime/events.log written by the Lua mod and plays the matching announcer line,
/// 4. exits when Half Sword exits.
public static class Program
{
    const string Version = "0.2.0";
    const string GameProcess = "HalfSwordUE5-Win64-Shipping";

    static StreamWriter logFile;
    static readonly object logLock = new();

    static void Log(string s)
    {
        var line = $"{DateTime.Now:HH:mm:ss.fff} {s}";
        lock (logLock)
        {
            Console.WriteLine(line);
            logFile?.WriteLine(line);
            logFile?.Flush();
        }
    }

    public static int Main(string[] args)
    {
        string game = null, halo = null;
        bool extractOnly = false, test = Environment.GetEnvironmentVariable("HALOSWORD_TEST") == "1";
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--game": game = args[++i]; break;
                case "--halo": halo = args[++i]; break;
                case "--extract-only": extractOnly = true; break;
                case "--test": test = true; break;
            }
        }

        var bridgeDir = AppContext.BaseDirectory;
        var modDir = Path.GetFullPath(Path.Combine(bridgeDir, ".."));
        var runtime = Path.Combine(modDir, "runtime");
        Directory.CreateDirectory(runtime);
        logFile = new StreamWriter(Path.Combine(runtime, "bridge.log"), false, Encoding.UTF8);
        Log($"HaloBridge {Version}: game={game} halo={halo} test={test}");

        var haloOk = true;
        var status = new StringBuilder();
        if (string.IsNullOrEmpty(halo) || !Directory.Exists(halo))
        {
            Log("Halo: The Master Chief Collection folder was not given or does not exist");
            haloOk = false;
        }

        if (haloOk)
        {
            foreach (var opp in Sheets.Opponents)
            {
                var outFile = Path.Combine(runtime, "models", opp.Id + ".lua");
                var mapFile = Path.Combine(halo, opp.HaloMap.Replace('/', Path.DirectorySeparatorChar));
                var key = File.Exists(mapFile) ? $"{Version}|{new FileInfo(mapFile).Length}|{File.GetLastWriteTimeUtc(mapFile):O}" : "missing";
                var keyFile = outFile + ".key";
                if (File.Exists(outFile) && File.Exists(keyFile) && File.ReadAllText(keyFile) == key)
                {
                    Log($"{opp.Id}: cached model is current");
                    continue;
                }
                try
                {
                    HaloModels.Export(opp, halo, outFile, Log);
                    File.WriteAllText(keyFile, key);
                }
                catch (Exception e)
                {
                    Log($"{opp.Id}: model export failed: {e}");
                    status.AppendLine($"  model_error_{opp.Id} = [[{e.Message}]],");
                }
            }
        }

        using var announcer = new Announcer(Log);
        if (haloOk)
        {
            try { announcer.Prepare(halo, runtime, Path.Combine(bridgeDir, "vgmstream", "vgmstream-cli.exe")); }
            catch (Exception e) { Log("announcer: " + e); }
        }

        File.WriteAllText(Path.Combine(runtime, "config.lua"),
            $"return {{\n  bridge_version = \"{Version}\",\n  halo_ok = {(haloOk ? "true" : "false")},\n  test = {(test ? "true" : "false")},\n{status}}}\n");

        if (extractOnly) { Log("extract-only: done"); return 0; }

        var eventsPath = Path.Combine(runtime, "events.log");
        File.WriteAllText(eventsPath, "");

        var exe = new[]
        {
            Path.Combine(game ?? "", "HalfSwordUE5.exe"),
            Path.Combine(game ?? "", "HalfSwordUE5", "Binaries", "Win64", GameProcess + ".exe"),
        }.FirstOrDefault(File.Exists);
        if (exe == null && Process.GetProcessesByName(GameProcess).Length == 0)
        {
            Log($"Half Sword executable not found under {game}");
            return 2;
        }
        if (Process.GetProcessesByName(GameProcess).Length == 0)
        {
            Log("starting " + exe);
            Process.Start(new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(exe)! });
        }

        Process gameProc = null;
        for (var i = 0; i < 180 && gameProc == null; i++)
        {
            gameProc = Process.GetProcessesByName(GameProcess).FirstOrDefault();
            if (gameProc == null) Thread.Sleep(500);
        }
        if (gameProc == null) { Log("Half Sword did not start within 90 s"); return 3; }
        Log($"Half Sword running (pid {gameProc.Id}); listening for gauntlet events");

        using var fs = new FileStream(eventsPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(fs, Encoding.UTF8);
        var pending = new StringBuilder();
        while (!gameProc.HasExited)
        {
            if (fs.Length < fs.Position) { fs.Position = 0; reader.DiscardBufferedData(); } // file was truncated
            var chunk = reader.ReadToEnd();
            if (chunk.Length > 0)
            {
                pending.Append(chunk);
                var text = pending.ToString();
                var lastNl = text.LastIndexOf('\n');
                if (lastNl >= 0)
                {
                    foreach (var line in text[..lastNl].Split('\n'))
                    {
                        var parts = line.Trim().Split(' ');
                        if (parts.Length < 2) continue;
                        var ev = parts[1];
                        Log("event " + line.Trim());
                        if (ev == Sheets.Event_READY) Log("mod reports ready");
                        announcer.OnEvent(ev);
                    }
                    pending.Clear().Append(text[(lastNl + 1)..]);
                }
            }
            Thread.Sleep(100);
        }
        Log("Half Sword exited");
        return 0;
    }
}
