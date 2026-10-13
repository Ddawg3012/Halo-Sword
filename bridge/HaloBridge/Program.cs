using System.Diagnostics;
using System.Text;

namespace HaloBridge;

/// Melty starts this next to Half Sword (recipe.together; Melty itself starts the game), through Microsoft's
/// signed .NET host so no unsigned .exe ships (Defender quarantined the old HaloBridge.exe):
///   bridge/dotnet.exe bridge/app/HaloBridge.dll --halo "{game:halo-mcc}" [--extract-only] [--test]
/// It never blocks the game. While Half Sword starts it:
/// 1. reads the Elite and Brute models and the announcer lines from the player's own MCC into
///    %LOCALAPPDATA%\HaloSword\runtime (cached; the Lua mod picks the models up as soon as they appear),
/// 2. tails runtime/events.log written by the Lua mod and plays the matching announcer line,
/// 3. exits when Half Sword exits (or if Half Sword never starts).
public static class Program
{
    const string Version = "0.7.0";
    const string GameProcess = "HalfSwordUE5-Win64-Shipping";

    static StreamWriter logFile;
    static readonly object logLock = new();

    static void Log(string s)
    {
        var line = $"{DateTime.Now:HH:mm:ss.fff} {s}";
        lock (logLock)
        {
            Console.WriteLine(line);
            try { logFile?.WriteLine(line); logFile?.Flush(); } catch { }
        }
    }

    public static string RuntimeDir()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(local, "HaloSword", "runtime");
    }

    public static int Main(string[] args)
    {
        string halo = null;
        bool extractOnly = false, test = Environment.GetEnvironmentVariable("HALOSWORD_TEST") == "1";
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--halo": halo = args[++i]; break;
                case "--game": i++; break; // accepted for older recipes; Melty starts the game itself
                case "--extract-only": extractOnly = true; break;
                case "--test": test = true; break;
            }
        }

        var runtime = RuntimeDir();
        Directory.CreateDirectory(runtime);
        try { logFile = new StreamWriter(Path.Combine(runtime, "bridge.log"), false, Encoding.UTF8); } catch { }
        Log($"HaloBridge {Version}: halo={halo} test={test} runtime={runtime}");

        var haloOk = !string.IsNullOrEmpty(halo) && Directory.Exists(halo);
        if (!haloOk) Log("Halo: The Master Chief Collection folder was not given or does not exist");
        else
        {
            var games = new[] { "halo1", "halo2", "halo3", "halo3odst", "haloreach", "halo4" }.Where(g => Directory.Exists(Path.Combine(halo, g)));
            Log("MCC games installed: " + string.Join(", ", games) + (Directory.Exists(Path.Combine(halo, "halo3")) ? "" : "  <- Halo 3 is missing: in Steam, MCC > Properties > DLC > tick Halo 3"));
        }
        WriteConfig(runtime, haloOk ? "reading" : "missing", test, "");

        using var announcer = new Announcer(Log);
        var extraction = Task.Run(() => Extract(halo, haloOk, runtime, announcer, test));

        if (extractOnly) { extraction.Wait(); Log("extract-only: done"); return 0; }

        try { return Listen(runtime, announcer); }
        catch (Exception e) { Log("listener stopped: " + e); return 1; }
    }

    static void WriteConfig(string runtime, string halo, bool test, string errors)
    {
        var text = $"return {{\n  bridge_version = \"{Version}\",\n  halo = \"{halo}\",\n  halo_ok = {(halo == "ready" ? "true" : "false")},\n  test = {(test ? "true" : "false")},\n{errors}}}\n";
        var path = Path.Combine(runtime, "config.lua");
        File.WriteAllText(path + ".tmp", text);
        File.Move(path + ".tmp", path, true);
    }

    static void Extract(string halo, bool haloOk, string runtime, Announcer announcer, bool test)
    {
        if (!haloOk) return;
        var errors = new StringBuilder();
        foreach (var opp in Sheets.Opponents)
        {
            var outFile = Path.Combine(runtime, "models", opp.Id + ".lua");
            try
            {
                var mapFile = Path.Combine(halo, opp.HaloMap.Replace('/', Path.DirectorySeparatorChar));
                var key = File.Exists(mapFile) ? $"{Version}|{new FileInfo(mapFile).Length}|{File.GetLastWriteTimeUtc(mapFile):O}" : "missing";
                var keyFile = outFile + ".key";
                if (File.Exists(outFile) && File.Exists(keyFile) && File.ReadAllText(keyFile) == key)
                {
                    Log($"{opp.Id}: cached model is current");
                    continue;
                }
                var sw = Stopwatch.StartNew();
                HaloModels.Export(opp, halo, outFile, Log);
                File.WriteAllText(keyFile, key);
                Log($"{opp.Id}: model read in {sw.Elapsed.TotalSeconds:0.0} s");
            }
            catch (Exception e)
            {
                Log($"{opp.Id}: model export failed: {e}");
                errors.AppendLine($"  model_error_{opp.Id} = [[{e.Message}]],");
            }
        }
        try
        {
            var sw = Stopwatch.StartNew();
            // layout: bridge/dotnet.exe (Microsoft-signed host), bridge/app/HaloBridge.dll, bridge/vgmstream/
            var vgm = new[] { Path.Combine(AppContext.BaseDirectory, "..", "vgmstream", "vgmstream-cli.exe"),
                              Path.Combine(AppContext.BaseDirectory, "vgmstream", "vgmstream-cli.exe") }.FirstOrDefault(File.Exists)
                      ?? Path.Combine(AppContext.BaseDirectory, "..", "vgmstream", "vgmstream-cli.exe");
            announcer.Prepare(halo, runtime, Path.GetFullPath(vgm));
            Log($"announcer ready in {sw.Elapsed.TotalSeconds:0.0} s");
        }
        catch (Exception e)
        {
            Log("announcer: " + e);
            errors.AppendLine($"  announcer_error = [[{e.Message}]],");
        }
        WriteConfig(runtime, "ready", test, errors.ToString());
    }

    static int Listen(string runtime, Announcer announcer)
    {
        var eventsPath = Path.Combine(runtime, "events.log");
        if (!File.Exists(eventsPath)) File.WriteAllText(eventsPath, "");

        // Melty starts Half Sword right after this program; wait for it (Steam may relaunch it first).
        Process gameProc = null;
        var waited = Stopwatch.StartNew();
        while (gameProc == null && waited.Elapsed < TimeSpan.FromMinutes(5))
        {
            gameProc = Process.GetProcessesByName(GameProcess).FirstOrDefault();
            if (gameProc == null) Thread.Sleep(1000);
        }
        if (gameProc == null) { Log("Half Sword did not start within 5 minutes; exiting"); return 3; }
        Log($"Half Sword running (pid {gameProc.Id}); listening for gauntlet events");

        using var fs = new FileStream(eventsPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        fs.Seek(0, SeekOrigin.End);
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
