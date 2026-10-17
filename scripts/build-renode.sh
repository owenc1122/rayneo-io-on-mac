#!/bin/sh
# Builds Renode 1.17.0+20261016 (commit d0c70ee3f, the build get-renode.sh downloads) from source with the
# tlib patches in renode-patches/, for macOS arm64. Result: .local/renode-build/renode, which emulate.sh,
# check-models.sh and the app (from a development checkout) use in place of .local/renode/Renode.app.
#
# The patches only make tlib and the time/hook plumbing faster (see each patch); guest-visible behaviour is
# unchanged.
# Needs git, curl and Xcode command line tools (clang). Downloads the .NET 8 SDK and CMake into .local/tools
# when they are not on PATH. A first run fetches ~1 GB of sources and takes ~10 minutes.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd -P)   # physical path: MSBuild must see the tree under one name (.local may be a symlink)
renode_commit=d0c70ee3fd0323afcae1c0bda89f4ed79140fe07
resources_commit=14b80cde0a136b684f316eb7f6a31aeaae0684bf   # renode-resources master when d0c70ee3f was built
src=${RENODE_SRC:-$root/.local/renode-src/renode}
mkdir -p "$(dirname "$src")" && src=$(cd "$(dirname "$src")" && pwd -P)/$(basename "$src")
tools=$root/.local/tools
mkdir -p "$tools"

# Toolchain: .NET 8 SDK and CMake (local copies unless already installed).
if command -v dotnet > /dev/null 2>&1 && dotnet --list-sdks 2>/dev/null | grep -q '^8\.'; then
    dotnet_root=$(dirname "$(command -v dotnet)")
else
    dotnet_root=$tools/dotnet
    if ! "$dotnet_root/dotnet" --list-sdks 2>/dev/null | grep -q '^8\.'; then
        curl -fsSL -o "$tools/dotnet-install.sh" https://dot.net/v1/dotnet-install.sh
        bash "$tools/dotnet-install.sh" --channel 8.0 --install-dir "$dotnet_root" > "$tools/dotnet-install.log"
    fi
fi
if command -v cmake > /dev/null 2>&1; then
    cmake_bin=$(dirname "$(command -v cmake)")
else
    cmake_bin=$tools/cmake-3.30.5-macos-universal/CMake.app/Contents/bin
    if [ ! -x "$cmake_bin/cmake" ]; then
        curl -fsSL -o "$tools/cmake.tgz" https://github.com/Kitware/CMake/releases/download/v3.30.5/cmake-3.30.5-macos-universal.tar.gz
        tar xzf "$tools/cmake.tgz" -C "$tools" && rm "$tools/cmake.tgz"
    fi
fi
export PATH="$dotnet_root:$cmake_bin:$PATH" DOTNET_ROOT="$dotnet_root" DOTNET_CLI_TELEMETRY_OPTOUT=1

# Sources at the pinned commits.
if [ ! -d "$src/.git" ]; then
    git clone https://github.com/renode/renode.git "$src"
fi
git -C "$src" fetch -q origin "$renode_commit" 2>/dev/null || true
git -C "$src" checkout -q "$renode_commit"
git -C "$src" submodule update --init --recursive -q
if [ ! -d "$src/lib/resources/.git" ]; then
    git clone -q https://github.com/renode/renode-resources.git "$src/lib/resources"
fi
git -C "$src/lib/resources" checkout -q "$resources_commit"

# Patches: reset tlib and the C# infrastructure to the pinned state, then apply ours in order
# (NNNN-tlib-*.patch to tlib, NNNN-infrastructure-*.patch to src/Infrastructure).
infra=$src/src/Infrastructure
tlib=$infra/src/Emulator/Cores/tlib
git -C "$tlib" checkout -q -- .
git -C "$infra" checkout -q -- .
for p in "$root"/renode-patches/*.patch; do
    case "$(basename "$p")" in
        *-tlib-*) git -C "$tlib" apply "$p" ;;
        *-infrastructure-*) git -C "$infra" apply "$p" ;;
        *) echo "Unknown patch target: $p" >&2; exit 1 ;;
    esac
done

(cd "$src" && ./build.sh --no-gui --skip-fetch)

mkdir -p .local/renode-build
cat > .local/renode-build/renode <<EOF
#!/bin/sh
# Renode built from source by scripts/build-renode.sh (commit $renode_commit + renode-patches/).
export DOTNET_ROOT="$dotnet_root" PATH="$dotnet_root:\$PATH"
exec "$src/renode" "\$@"
EOF
chmod +x .local/renode-build/renode
.local/renode-build/renode --version > /dev/null || { echo "The build does not start" >&2; exit 1; }
.local/renode-build/renode --version | tail -1
