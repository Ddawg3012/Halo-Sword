using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace HaloBridge;

/// Halo 3's multiplayer announcer, taken from the player's own MCC FMOD banks.
/// halo3/fmod/pc/<bank>.fsb holds the samples; <bank>.fsb.info holds one 280-byte record per sample, in the same
/// order, with the original source path at +24 (universal-modder field note "halo-3-mcc"). vgmstream decodes
/// sample N as subsong N+1.
public sealed class Announcer : IDisposable
{
    const int RecordSize = 280;
    const int PathOffset = 24;

    readonly ConcurrentDictionary<string, string> wavByEvent = new(StringComparer.Ordinal);
    readonly BlockingCollection<string> queue = new();
    readonly Thread player;
    readonly Action<string> log;

    public Announcer(Action<string> log)
    {
        this.log = log;
        player = new Thread(PlayLoop) { IsBackground = true, Name = "announcer" };
        player.Start();
    }

    public sealed record Sample(string Bank, int Index, string SourcePath);

    public static List<Sample> ReadIndex(string fmodDir, Action<string> log)
    {
        var all = new List<Sample>();
        foreach (var info in Directory.EnumerateFiles(fmodDir, "*.fsb.info", SearchOption.AllDirectories))
        {
            var bank = info[..^".info".Length];
            if (!File.Exists(bank)) continue;
            var bytes = File.ReadAllBytes(info);
            var baseOffset = bytes.Length % RecordSize; // a header, if any, sits before the records
            var count = (bytes.Length - baseOffset) / RecordSize;
            for (var i = 0; i < count; i++)
            {
                var start = baseOffset + i * RecordSize + PathOffset;
                var end = start;
                while (end < baseOffset + (i + 1) * RecordSize && bytes[end] != 0) end++;
                var path = Encoding.ASCII.GetString(bytes, start, end - start).ToLowerInvariant();
                all.Add(new Sample(bank, i, path));
            }
            log($"announcer: {Path.GetFileName(info)}: {count} samples (header {baseOffset} bytes)");
        }
        return all;
    }

    /// Finds each announcer row's sample and decodes it to runtime/sounds/<id>.wav (kept between launches).
    public void Prepare(string mccDir, string runtimeDir, string vgmstreamExe)
    {
        var fmodDir = Path.Combine(mccDir, "halo3", "fmod", "pc");
        if (!Directory.Exists(fmodDir)) { log($"announcer: {fmodDir} not found, no announcer"); return; }
        var soundsDir = Path.Combine(runtimeDir, "sounds");
        Directory.CreateDirectory(soundsDir);

        List<Sample> index = null;
        foreach (var row in Sheets.Announcer)
        {
            var wav = Path.Combine(soundsDir, row.Id + ".wav");
            if (!File.Exists(wav))
            {
                index ??= ReadIndex(fmodDir, log);
                if (index.Count > 0 && !File.Exists(Path.Combine(runtimeDir, "halo3_dialog_index.txt")))
                    File.WriteAllLines(Path.Combine(runtimeDir, "halo3_dialog_index.txt"),
                        index.Where(s => s.SourcePath.Contains("dialog\\multiplayer")).Select(s => $"{Path.GetFileName(s.Bank)}#{s.Index}\t{s.SourcePath}"));
                var hit = row.Match.Select(m => index.FirstOrDefault(s => s.SourcePath.Contains(m))).FirstOrDefault(s => s != null);
                if (hit == null) { log($"announcer: {row.Id}: no sample matches [{string.Join(", ", row.Match)}]"); continue; }
                if (!Decode(vgmstreamExe, hit, wav)) continue;
                log($"announcer: {row.Id} <- {Path.GetFileName(hit.Bank)}#{hit.Index} {hit.SourcePath}");
            }
            wavByEvent[row.Event] = wav;
        }
    }

    bool Decode(string vgmstreamExe, Sample s, string wav)
    {
        var psi = new ProcessStartInfo(vgmstreamExe)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = Path.GetDirectoryName(vgmstreamExe)!,
        };
        foreach (var a in new[] { "-s", (s.Index + 1).ToString(), "-o", wav + ".tmp.wav", s.Bank }) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        var stdout = p.StandardOutput.ReadToEndAsync();
        var stderr = p.StandardError.ReadToEndAsync();
        if (!p.WaitForExit(60_000)) { p.Kill(); log("announcer: vgmstream timed out"); return false; }
        if (p.ExitCode != 0 || !File.Exists(wav + ".tmp.wav"))
        {
            log($"announcer: vgmstream failed ({p.ExitCode}): {stderr.Result.Trim()} {stdout.Result.Trim()}");
            return false;
        }
        File.Move(wav + ".tmp.wav", wav, true);
        return true;
    }

    public void OnEvent(string ev)
    {
        if (wavByEvent.TryGetValue(ev, out var wav)) queue.Add(wav);
    }

    void PlayLoop()
    {
        foreach (var wav in queue.GetConsumingEnumerable())
        {
            try { PlaySound(wav, IntPtr.Zero, SND_FILENAME | SND_NODEFAULT | SND_SYNC); }
            catch (Exception e) { log("announcer: play failed: " + e.Message); }
        }
    }

    public void Dispose() => queue.CompleteAdding();

    const uint SND_SYNC = 0x0000, SND_NODEFAULT = 0x0002, SND_FILENAME = 0x00020000;

    [DllImport("winmm.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool PlaySound(string pszSound, IntPtr hmod, uint fdwSound);
}
