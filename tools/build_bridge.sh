#!/usr/bin/env bash
# Builds HaloBridge.exe (self-contained, single file, win-x64) from Linux or Windows with the .NET 8 SDK.
# Reclaimer is fetched at a pinned commit and patched to build on .NET 8 without WPF (we only read geometry).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECLAIMER_COMMIT=36224d7a4581f2a1f255099bf706aa56be9f6e21
R="$ROOT/build/reclaimer"
if [ ! -d "$R/.git" ]; then
  git clone -q https://github.com/Gravemind2401/Reclaimer "$R"
fi
git -C "$R" fetch -q --depth 1 origin "$RECLAIMER_COMMIT" || true
git -C "$R" checkout -q -f "$RECLAIMER_COMMIT"
git -C "$R" clean -qfd
# --- .NET 8 / no-WPF patches (see design/MODLOG.md) ---
sed -i 's/net9.0-windows/net8.0-windows/' "$R"/Reclaimer.Core/Reclaimer.Core.csproj "$R"/Reclaimer.Blam/Reclaimer.Blam.csproj
sed -i 's#<UseWPF>true</UseWPF>#<EnableWindowsTargeting>true</EnableWindowsTargeting>#' "$R"/Reclaimer.Core/Reclaimer.Core.csproj
sed -i 's#<Compile Remove="Geometry\\Vectors\\NormalisedVectors.cs" />#<Compile Remove="Geometry\\Vectors\\NormalisedVectors.cs" /><Compile Remove="Drawing\\DdsConvert.cs" /><Compile Remove="Drawing\\DdsOutputArgs.cs" />#' "$R"/Reclaimer.Core/Reclaimer.Core.csproj
sed -i 's#<SignAssembly>false</SignAssembly>#<SignAssembly>false</SignAssembly><EnableWindowsTargeting>true</EnableWindowsTargeting>#' "$R"/Reclaimer.Blam/Reclaimer.Blam.csproj
# XCompress (Xbox 360 maps only) is Microsoft's and must not ship
python3 - "$R/Reclaimer.Blam/Reclaimer.Blam.csproj" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'<ContentWithTargetPath Include="Resources\\xcompress(32|64)\.dll">.*?</ContentWithTargetPath>', '', s, flags=re.S)
open(p,'w').write(s)
PY
sed -i 's#dds.WriteToStream(ms, System.Drawing.Imaging.ImageFormat.Png);#dds.WriteToStream(ms);#' "$R"/Reclaimer.Core/Geometry/Utilities/SceneWriter.cs
sed -i 's/params IEnumerable<ModuleItem>/params ModuleItem[]/' "$R"/Reclaimer.Blam/Blam/Halo5/ModuleItemGroup.cs
sed -i 's/params IEnumerable<int> shaderIndexes/params int[] shaderIndexes/' "$R"/Reclaimer.Blam/Saber3D/Halo1X/Geometry/CeaModelBase.cs
printf '// net8 shim for System.Threading.Lock; lock() works on any object.\nnamespace System.Threading { internal sealed class Lock { } }\n' > "$R"/Reclaimer.Blam/LockShim.cs
python3 "$ROOT/tools/sheets.py" gen
export EnableWindowsTargeting=true
# Layout that ships no unsigned .exe (Windows Defender quarantined HaloBridge.exe in 0.3/0.4):
#   bridge/dotnet.exe                                  Microsoft-signed .NET host  (nuget runtime.win-x64.Microsoft.NETCore.DotNetHost)
#   bridge/host/fxr/8.0.31/hostfxr.dll                 Microsoft-signed            (nuget runtime.win-x64.Microsoft.NETCore.DotNetHostResolver)
#   bridge/shared/Microsoft.NETCore.App/8.0.31/        .NET 8 runtime (MIT)        (nuget Microsoft.NETCore.App.Runtime.win-x64)
#   bridge/app/HaloBridge.dll + Reclaimer DLLs         framework-dependent, run as: dotnet.exe app/HaloBridge.dll
RT=8.0.31
NUGET="$ROOT/build/nuget"; mkdir -p "$NUGET"
nupkg() { # id sha
  local f="$NUGET/$1.$RT.nupkg"
  [ -f "$f" ] || curl -sSfL -o "$f" "https://api.nuget.org/v3-flatcontainer/$1/$RT/$1.$RT.nupkg"
  echo "$2  $f" | sha256sum -c --quiet
  rm -rf "$NUGET/$1"; mkdir -p "$NUGET/$1"; unzip -q -o "$f" -d "$NUGET/$1"
}
nupkg runtime.win-x64.microsoft.netcore.dotnethost 1ac1b92f27385829403b4161b1778c0fa8382734c1f5cfc79b78e95515a1a859
nupkg runtime.win-x64.microsoft.netcore.dotnethostresolver 1f185805daa55b228b2408d5edc27641603d024162ac62523573f6153bb0ec51
nupkg microsoft.netcore.app.runtime.win-x64 1504ead20c9a25e4c47ece56b6cd407697ea0cde0148e07e71bebc1e2d841c2f
B="$ROOT/build/bridge"; rm -rf "$B"; mkdir -p "$B/app" "$B/host/fxr/$RT" "$B/shared/Microsoft.NETCore.App/$RT"
dotnet publish "$ROOT/bridge/HaloBridge/HaloBridge.csproj" -c Release -r win-x64 --self-contained false -o "$B/app"
cp "$NUGET/runtime.win-x64.microsoft.netcore.dotnethost/runtimes/win-x64/native/dotnet.exe" "$B/"
cp "$NUGET/runtime.win-x64.microsoft.netcore.dotnethostresolver/runtimes/win-x64/native/hostfxr.dll" "$B/host/fxr/$RT/"
cp "$NUGET/microsoft.netcore.app.runtime.win-x64/runtimes/win-x64/lib/net8.0/"*.dll "$NUGET/microsoft.netcore.app.runtime.win-x64/runtimes/win-x64/lib/net8.0/"*.json "$B/shared/Microsoft.NETCore.App/$RT/"
cp "$NUGET/microsoft.netcore.app.runtime.win-x64/runtimes/win-x64/native/"* "$B/shared/Microsoft.NETCore.App/$RT/"
cp "$NUGET/microsoft.netcore.app.runtime.win-x64/LICENSE.TXT" "$B/dotnet-LICENSE.txt" 2>/dev/null || true
cp "$NUGET/microsoft.netcore.app.runtime.win-x64/THIRD-PARTY-NOTICES.TXT" "$B/dotnet-THIRD-PARTY-NOTICES.txt" 2>/dev/null || true
ls -la "$B" "$B/app"
