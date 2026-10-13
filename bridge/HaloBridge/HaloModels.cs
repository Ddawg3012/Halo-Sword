using System.Globalization;
using System.Numerics;
using System.Text;
using Reclaimer.Blam.Common;
using Reclaimer.Geometry;

namespace HaloBridge;

/// Reads an opponent's render_model from the player's own Halo 3 cache file and writes it as a Lua table the
/// gauntlet mod loads: one piece per mapped Halo node, vertices in the model's rest pose (UE axes, cm).
/// Nothing read here leaves the player's PC; the output lives in Mods/HaloSword/runtime.
public static class HaloModels
{
    const float CmPerWorldUnit = 304.8f; // Halo 3: 1 world unit = 10 ft
    const int VertexBudgetPerPiece = 900;

    public static void Export(OpponentRow opp, string mccDir, string outFile, Action<string> log)
    {
        var mapPath = Path.Combine(mccDir, opp.HaloMap.Replace('/', Path.DirectorySeparatorChar));
        if (!File.Exists(mapPath))
            throw new FileNotFoundException($"Halo 3 map not found: {mapPath}. Is Halo 3 installed in the Master Chief Collection?");

        var cache = CacheFactory.ReadCacheFile(mapPath);
        log($"{opp.Id}: opened {mapPath} ({cache.CacheType}, build {cache.BuildString})");

        var models = cache.TagIndex.Where(t => t.ClassCode == "mode").ToList();
        foreach (var t in models.Where(t => t.TagName.Contains("elite", StringComparison.OrdinalIgnoreCase) || t.TagName.Contains("brute", StringComparison.OrdinalIgnoreCase)))
            log($"  render_model seen: {t.TagName}");

        IIndexItem tag = null;
        foreach (var cand in opp.HaloModelCandidates)
        {
            tag = models.FirstOrDefault(t => string.Equals(t.TagName, cand, StringComparison.OrdinalIgnoreCase));
            if (tag != null) break;
        }
        if (tag == null)
            throw new InvalidDataException($"{opp.Id}: none of [{string.Join(", ", opp.HaloModelCandidates)}] is in {opp.HaloMap}");

        if (!ContentFactory.TryGetGeometryContent(tag, out var provider))
            throw new InvalidDataException($"{opp.Id}: {tag.TagName} has no geometry Reclaimer can read");
        var model = provider.GetContent().EnumerateModels().First();
        log($"{opp.Id}: {tag.TagName}: {model.Bones.Count} nodes, {model.Regions.Count} regions, {model.Meshes.Count} meshes");

        var nodeNames = model.Bones.Select(b => b.Name).ToList();
        var nodePos = Enumerable.Range(0, model.Bones.Count).Select(i => ToUe(model.GetBoneWorldTransform(i).Translation)).ToList();

        // Each Halo node rides on its nearest ancestor that the bone_map sheet lists.
        var mapped = Sheets.Bones.Where(b => b.Skeleton == opp.Skeleton).ToDictionary(b => b.HaloNode, StringComparer.OrdinalIgnoreCase);
        int Owner(int node)
        {
            for (var n = node; n >= 0; n = model.Bones[n].ParentIndex)
                if (mapped.ContainsKey(model.Bones[n].Name)) return n;
            return -1;
        }
        var missing = mapped.Keys.Where(k => !nodeNames.Contains(k, StringComparer.OrdinalIgnoreCase)).ToList();
        if (missing.Count > 0) log($"{opp.Id}: bone_map nodes not in this model: {string.Join(", ", missing)}");
        log($"{opp.Id}: nodes: {string.Join(", ", nodeNames)}");

        var pieces = new Dictionary<int, Piece>();
        foreach (var region in model.Regions)
        {
            var perm = region.Permutations.FirstOrDefault(p => p.Name == opp.RegionPermutation) ?? region.Permutations.FirstOrDefault();
            if (perm == null) continue;
            var permXf = perm.GetFinalTransform();
            foreach (var mi in perm.MeshIndices)
            {
                var mesh = model.Meshes.ElementAtOrDefault(mi);
                if (mesh?.VertexBuffer == null || !mesh.VertexBuffer.HasPositions) continue;
                var pos = mesh.GetPositions().ToList();
                if (mesh.IsCompressed)
                {
                    var expand = mesh.PositionBounds.CreateExpansionMatrix();
                    pos = pos.Select(p => Vector3.Transform(p, expand)).ToList();
                }
                pos = pos.Select(p => Vector3.Transform(p, permXf)).ToList();
                var bi = mesh.GetBlendIndices()?.ToList();
                var bw = mesh.GetBlendWeights()?.ToList();

                int NodeOf(int v)
                {
                    if (mesh.BoneIndex.HasValue) return mesh.BoneIndex.Value;
                    if (bi == null) return 0;
                    var idx = bi[v];
                    if (bw == null) return (int)idx.X;
                    var w = bw[v];
                    var best = (int)idx.X; var bestW = w.X;
                    if (w.Y > bestW) { best = (int)idx.Y; bestW = w.Y; }
                    if (w.Z > bestW) { best = (int)idx.Z; bestW = w.Z; }
                    if (w.W > bestW) { best = (int)idx.W; }
                    return best;
                }

                foreach (var seg in mesh.Segments)
                {
                    var tri = mesh.GetTriangleIndicies(seg).ToList();
                    for (var i = 0; i + 2 < tri.Count; i += 3)
                    {
                        int a = tri[i], b = tri[i + 1], c = tri[i + 2];
                        if (a == b || b == c || a == c) continue;
                        // a triangle belongs to the piece that owns most of its corners (first corner on a tie)
                        var oa = Owner(NodeOf(a)); var ob = Owner(NodeOf(b)); var oc = Owner(NodeOf(c));
                        var owner = (ob == oc && ob != oa) ? ob : oa;
                        if (owner < 0) continue;
                        if (!pieces.TryGetValue(owner, out var piece)) pieces[owner] = piece = new Piece(model.Bones[owner].Name);
                        // UE is left-handed: mirroring Y flips winding, so emit a, c, b
                        piece.AddTri(ToUe(pos[a]), ToUe(pos[c]), ToUe(pos[b]));
                    }
                }
            }
        }

        foreach (var p in pieces.Values) p.Decimate(VertexBudgetPerPiece);

        var minZ = pieces.Values.SelectMany(p => p.Verts).DefaultIfEmpty().Min(v => v.Z);
        var maxZ = pieces.Values.SelectMany(p => p.Verts).DefaultIfEmpty().Max(v => v.Z);
        var pelvis = nodeNames.FindIndex(n => n.Equals("pelvis", StringComparison.OrdinalIgnoreCase));

        var sb = new StringBuilder();
        var inv = CultureInfo.InvariantCulture;
        string F(float f) => f.ToString("0.###", inv);
        sb.AppendLine($"-- Generated on this PC by HaloBridge from {opp.HaloMap} ({tag.TagName}). Halo 3 content from your own MCC; do not share.");
        sb.AppendLine("return {");
        sb.AppendLine($"  id = \"{opp.Id}\", tag = [[{tag.TagName}]], min_z = {F(minZ)}, max_z = {F(maxZ)},");
        sb.AppendLine($"  pelvis_z = {(pelvis >= 0 ? F(nodePos[pelvis].Z) : "nil")},");
        sb.AppendLine($"  tint = {{ {F(opp.TintRgb[0])}, {F(opp.TintRgb[1])}, {F(opp.TintRgb[2])} }},");
        sb.AppendLine("  nodes = {");
        for (var i = 0; i < nodeNames.Count; i++)
            sb.AppendLine($"    [\"{nodeNames[i]}\"] = {{ {F(nodePos[i].X)}, {F(nodePos[i].Y)}, {F(nodePos[i].Z)} }},");
        sb.AppendLine("  },");
        sb.AppendLine("  pieces = {");
        var total = 0;
        foreach (var (node, p) in pieces.OrderBy(k => k.Key))
        {
            total += p.Verts.Count;
            sb.Append($"    {{ node = \"{p.Node}\", verts = {{");
            foreach (var v in p.Verts) sb.Append($"{F(v.X)},{F(v.Y)},{F(v.Z)},");
            sb.Append("}, tris = {");
            foreach (var t in p.Tris) sb.Append($"{t},");
            sb.AppendLine("} },");
        }
        sb.AppendLine("  },");
        sb.AppendLine("}");
        Directory.CreateDirectory(Path.GetDirectoryName(outFile)!);
        File.WriteAllText(outFile + ".tmp", sb.ToString());
        File.Move(outFile + ".tmp", outFile, true);
        log($"{opp.Id}: wrote {pieces.Count} pieces, {total} vertices -> {outFile}");
    }

    // Halo: X forward, Y left, Z up, world units. UE: X forward, Y right, Z up, cm.
    static Vector3 ToUe(Vector3 h) => new(h.X * CmPerWorldUnit, -h.Y * CmPerWorldUnit, h.Z * CmPerWorldUnit);

    sealed class Piece(string node)
    {
        public string Node { get; } = node;
        public List<Vector3> Verts { get; private set; } = new();
        public List<int> Tris { get; private set; } = new();
        readonly Dictionary<Vector3, int> lookup = new();

        int Vert(Vector3 v)
        {
            if (!lookup.TryGetValue(v, out var i)) { i = Verts.Count; Verts.Add(v); lookup[v] = i; }
            return i;
        }

        public void AddTri(Vector3 a, Vector3 b, Vector3 c)
        {
            Tris.Add(Vert(a)); Tris.Add(Vert(b)); Tris.Add(Vert(c));
        }

        /// Vertex clustering on a grid, growing the cell until the piece fits the budget.
        public void Decimate(int budget)
        {
            var cell = 0.5f;
            while (Verts.Count > budget && cell < 50f)
            {
                var cluster = new Dictionary<(int, int, int), int>();
                var sums = new List<(Vector3 sum, int n)>();
                var remap = new int[Verts.Count];
                for (var i = 0; i < Verts.Count; i++)
                {
                    var v = Verts[i];
                    var key = ((int)MathF.Floor(v.X / cell), (int)MathF.Floor(v.Y / cell), (int)MathF.Floor(v.Z / cell));
                    if (!cluster.TryGetValue(key, out var ci)) { ci = sums.Count; sums.Add((Vector3.Zero, 0)); cluster[key] = ci; }
                    sums[ci] = (sums[ci].sum + v, sums[ci].n + 1);
                    remap[i] = ci;
                }
                if (sums.Count <= budget)
                {
                    var newTris = new List<int>();
                    for (var t = 0; t + 2 < Tris.Count; t += 3)
                    {
                        int a = remap[Tris[t]], b = remap[Tris[t + 1]], c = remap[Tris[t + 2]];
                        if (a != b && b != c && a != c) { newTris.Add(a); newTris.Add(b); newTris.Add(c); }
                    }
                    Verts = sums.Select(s => s.sum / s.n).ToList();
                    Tris = newTris;
                    return;
                }
                cell *= 1.5f;
            }
        }
    }
}
