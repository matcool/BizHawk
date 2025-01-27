{ pkgs ? import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/23.05.tar.gz") {}
, lib ? pkgs.lib
, stdenv ? pkgs.stdenvNoCC
# infrastructure
, buildDotnetModule ? pkgs.buildDotnetModule
, dpkg ? pkgs.dpkg
, fetchFromGitHub ? pkgs.fetchFromGitHub
, fetchFromGitLab ? pkgs.fetchFromGitLab
, fetchpatch ? pkgs.fetchpatch
, fetchzip ? pkgs.fetchzip
, makeDesktopItem ? pkgs.makeDesktopItem
, mkNugetDeps ? pkgs.mkNugetDeps
, runCommand ? pkgs.runCommand
, symlinkJoin ? pkgs.symlinkJoin
, writeShellScript ? pkgs.writeShellScript
, writeShellScriptBin ? pkgs.writeShellScriptBin
, writeText ? pkgs.writeText
# source
, hawkSourceInfoDevBuild ? let # called "dev build", but you could pass whatever branch and commit you want here
	version = "2.9.2-local"; # used in default value of `BIZHAWK_DATA_HOME`, which distinguishes parallel installs' config and other data
in {
	inherit version;
	src = builtins.path { path = ./.; name = "BizHawk-${version}"; }; # source derivation; did have filter here for speed, but it wasn't faster and it wasn't correct and it couldn't be made correct and I'm mad
}
# makedeps
, dotnet-sdk_6 ? pkgs.dotnet-sdk_6
, dotnet-sdk_5 ? let result = builtins.tryEval pkgs.dotnet-sdk_5; in if result.success
	then result.value
	else (import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/5234f4ce9340fffb705b908fff4896faeddb8a12^.tar.gz") {}).dotnet-sdk_5
, git ? pkgs.gitMinimal # only when building from-CWD (`-local`)
# rundeps
, coreutils ? pkgs.coreutils
, lua ? pkgs.lua54Packages.lua
, mono ? null
, nixGLChannel ? (pkgs.nixgl or import (fetchTarball "https://github.com/guibou/nixGL/archive/489d6b095ab9d289fe11af0219a9ff00fe87c7c5.tar.gz") {})
, nixGL ? nixGLChannel.auto.nixGLDefault
#, nixVulkan ? nixGLChannel.auto.nixVulkanNvidia
, openal ? pkgs.openal
, SDL2 ? pkgs.SDL2
, udev ? pkgs.udev
, zstd ? pkgs.zstd
# other parameters
, buildConfig ? "Release" # "Debug"/"Release"
, debugPInvokes ? false # forwarded to Dist/launch-scripts.nix
, debugDotnetHostCrashes ? false # forwarded to Dist/launch-scripts.nix
, doCheck ? true # runs `Dist/BuildTest${buildConfig}.sh`
, emuhawkBuildFlavour ? "NixHawk"
, extraDefines ? "" # added to `<DefineConstants/>`, so ';'-separated
, extraDotnetBuildFlags ? "" # currently passed to EVERY `dotnet build` and `dotnet test` invocation (and does not replace the flags for parallel compilation added by default)
, forNixOS ? true
, initConfig ? {} # forwarded to Dist/launch-scripts.nix (see docs there)
}: let
	isVersionAtLeast = lib.flip lib.versionAtLeast; # I stand by this being the more useful param order w.r.t. currying
	replaceDotWithUnderscore = s: lib.replaceStrings [ "." ] [ "_" ] s;
	/** you can't actually make hard links in the sandbox, so this just copies, and we'll rely on Nix' automatic deduping */
	hardLinkJoin =
		{ name
		, paths
		, preferLocalBuild ? true
		, allowSubstitutes ? false
		, __contentAddressed ? false
		}: runCommand name {
			inherit __contentAddressed allowSubstitutes paths preferLocalBuild;
			passAsFile = [ "paths" ];
		} ''
			mkdir -p $out
			for d in $(cat $pathsPath); do
				cd "$d"
				find . -type d -exec mkdir -p "$out/{}" \;
				for f in $(find . -type f); do cp -T "$(realpath "$f")" "$out/$f"; done
			done
		'';
	inherit (import Dist/historical.nix {
		inherit lib
			isVersionAtLeast replaceDotWithUnderscore
			fetchFromGitHub fetchFromGitLab mkNugetDeps
			dotnet-sdk_5 dotnet-sdk_6;
	}) depsForHistoricalRelease populateHawkSourceInfo releaseArtifactInfos releaseFrags releaseTagSourceInfos;
	launchScriptsFor = bizhawkAssemblies: isManualLocalBuild: import Dist/launch-scripts.nix {
		inherit lib
			writeShellScript writeText
			bizhawkAssemblies nixGL
			debugPInvokes debugDotnetHostCrashes initConfig isManualLocalBuild;
		mkfifo = coreutils;
		mktemp = coreutils;
	};
	pp = import Dist/packages.nix {
		inherit lib stdenv
			populateHawkSourceInfo replaceDotWithUnderscore
			buildDotnetModule fetchpatch fetchzip hardLinkJoin launchScriptsFor makeDesktopItem
				releaseTagSourceInfos runCommand symlinkJoin writeShellScriptBin
			git
			lua openal SDL2 udev zstd
			buildConfig doCheck emuhawkBuildFlavour extraDefines extraDotnetBuildFlags;
		mono = if mono != null
			then mono # allow older Mono if set explicitly
			else if isVersionAtLeast "6.12.0.151" pkgs.mono.version
				then pkgs.mono
				else lib.trace "provided Mono too old, using Mono from Nixpkgs 23.05"
					(import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/23.05.tar.gz") {}).mono;
		monoBasic = fetchzip {
			url = "https://download.mono-project.com/repo/debian/pool/main/m/mono-basic/libmono-microsoft-visualbasic10.0-cil_4.7-0xamarin3+debian9b1_all.deb";
			nativeBuildInputs = [ dpkg ];
			hash = "sha256-2m1FwpDxzqVXR6GUB3oFuTqIXCde/msb+tg8v6lIN6s=";
			# tried and failed building from source, following https://aur.archlinux.org/cgit/aur.git/tree/PKGBUILD?h=mono-basic
		};
	};
	emuhawk-local = pp.buildEmuHawkInstallableFor {
		inherit forNixOS;
		hawkSourceInfo = hawkSourceInfoDevBuild;
	};
	asmsFromReleaseArtifacts = lib.mapAttrs (_: pp.splitReleaseArtifact) releaseArtifactInfos;
	# the asms for from-CWD and latest release from-source are exposed below as `bizhawkAssemblies` and `bizhawkAssemblies-latest`, respectively
	# apart from that, no `asmsFromSource`, since if you're only after the assets you might as well use the release artifact
	releasesEmuHawkInstallables = lib.pipe releaseFrags [
		(builtins.map (versionFrag: [
			({
				name = "emuhawk-${versionFrag}";
				value = pp.buildEmuHawkInstallableFor {
					inherit forNixOS;
					hawkSourceInfo = releaseTagSourceInfos."info-${versionFrag}";
				};
			})
			({
				name = "emuhawk-${versionFrag}-bin";
				value = pp.buildEmuHawkInstallableFor {
					inherit forNixOS;
					bizhawkAssemblies = asmsFromReleaseArtifacts."bizhawkAssemblies-${versionFrag}-bin";
				};
			})
		]))
		lib.concatLists
		lib.listToAttrs
		(lib.filterAttrs (name: value: lib.hasSuffix "-bin" name
			|| isVersionAtLeast "2.6" value.hawkSourceInfo.version))
	];
	latestVersionFrag = lib.head releaseFrags;
	combined = pp // asmsFromReleaseArtifacts // releasesEmuHawkInstallables // {
		inherit depsForHistoricalRelease releaseTagSourceInfos;
		bizhawkAssemblies = pp.buildAssembliesFor hawkSourceInfoDevBuild;
		"bizhawkAssemblies-${latestVersionFrag}" = pp.buildAssembliesFor releaseTagSourceInfos."info-${latestVersionFrag}";
		discohawk = pp.buildDiscoHawkInstallableFor { hawkSourceInfo = hawkSourceInfoDevBuild; };
		"discohawk-${latestVersionFrag}" = pp.buildDiscoHawkInstallableFor {
			hawkSourceInfo = releaseTagSourceInfos."info-${latestVersionFrag}";
		};
		"discohawk-${latestVersionFrag}-bin" = pp.buildDiscoHawkInstallableFor {
			bizhawkAssemblies = asmsFromReleaseArtifacts."bizhawkAssemblies-${latestVersionFrag}-bin";
		};
		emuhawk = emuhawk-local;
		launchScriptsForLocalBuild = launchScriptsFor emuhawk-local.assemblies true;
	};
in combined // lib.listToAttrs (lib.concatLists (builtins.map
	(f: [
		{ name = f "latest-bin"; value = combined.${f "${latestVersionFrag}-bin"}; }
		{ name = f "latest"; value = combined.${f latestVersionFrag}; }
	])
	[ (s: "bizhawkAssemblies-${s}") (s: "emuhawk-${s}") (s: "discohawk-${s}") ]))
