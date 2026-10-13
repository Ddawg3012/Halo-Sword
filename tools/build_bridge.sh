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
dotnet publish "$ROOT/bridge/HaloBridge/HaloBridge.csproj" -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -o "$ROOT/build/bridge"
ls -la "$ROOT/build/bridge"
