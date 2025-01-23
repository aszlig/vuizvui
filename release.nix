{ vuizvuiSrc ? null
, nixpkgsSrc ? <nixpkgs>
, supportedSystems ? [ "i686-linux" "x86_64-linux" ]
}:

let
  nixpkgsRevCount = nixpkgsSrc.revCount or 12345;
  nixpkgsShortRev = nixpkgsSrc.shortRev or "abcdefg";
  nixpkgsVersion = "pre${toString nixpkgsRevCount}.${nixpkgsShortRev}-vuizvui";

  nixpkgs = nixpkgsSrc;

  vuizvuiRevCount = vuizvuiSrc.revCount or 12345;
  vuizvuiShortRev = vuizvuiSrc.shortRev or "abcdefg";
  vuizvuiVersion = "pre${toString vuizvuiRevCount}.${vuizvuiShortRev}";

  # version of the nixos-unstable channel to get programs.sqlite from.
  # Use pkgs.sternenseemann.vuizvui-update-programs-sqlite to update.
  programsSqliteVersion = "25.05beta729683.88195a94f390";
  programsSqliteSha256 = "19l2ak33f9dai7wpamg6gnkhs3948mxmpds2fm626d0lcglf584c";
  programsSqlite = pkgsUpstream.fetchurl {
    name = "programs.sqlite-${programsSqliteVersion}";
    url = "https://releases.nixos.org/nixos/unstable/nixos-${programsSqliteVersion}/nixexprs.tar.xz";
    sha256 = programsSqliteSha256;
    downloadToTemp = true;
    postFetch = ''
      tar -xOJf $downloadedFile nixos-${programsSqliteVersion}/programs.sqlite > "$out"
    '';
  };

  vuizvui = let
    patchedVuizvui = (import nixpkgs {}).stdenv.mkDerivation {
      name = "vuizvui-${vuizvuiVersion}";
      inherit nixpkgsVersion;
      src = vuizvuiSrc;
      phases = [ "unpackPhase" "installPhase" ];
      installPhase = ''
        cp -r --no-preserve=ownership "${nixpkgs}/" nixpkgs
        chmod -R u+w nixpkgs
        # since we fetch nixpkgsSrc using git, we don't get programs.sqlite
        # for programs.command-not-found which is normally included in the
        # channel. Building this ourselves is not desireable as it requires
        # to build and index the whole of nixpkgs. Therefore we just inject
        # it from a nixos channel (which possibly is a different version).
        cp --no-preserve=ownership "${programsSqlite}" nixpkgs/programs.sqlite
        echo -n "$nixpkgsVersion" > nixpkgs/.version-suffix
        echo "echo '$nixpkgsVersion'" \
          > nixpkgs/nixos/modules/installer/tools/get-version-suffix
        echo -n ${nixpkgs.rev or nixpkgsShortRev} > nixpkgs/.git-revision
        echo './nixpkgs' > nixpkgs-path.nix
        cp -r . "$out"
      '';
    };
  in if vuizvuiSrc == null then ./. else patchedVuizvui;

  system = "x86_64-linux";
  pkgsUpstream = import nixpkgs { inherit system; };
  root = import vuizvui { inherit system; };

  mpath = if vuizvuiSrc == null then ./machines else "${vuizvui}/machines";

  allMachines = with pkgsUpstream.lib; let
    wrapPkgs = machine: machine.__withPkgsPath nixpkgs;
    condition = m: !(m ? __withPkgsPath);
  in mapAttrsRecursiveCond condition (const wrapPkgs) (import mpath);

  allTests = with import ./lib; getVuizvuiTests ({
    inherit system nixpkgs;
    excludeVuizvuiGames = true;
  } // pkgsUpstream.lib.optionalAttrs (vuizvuiSrc != null) {
    vuizvuiTests = "${vuizvui}/tests";
  });

  pkgs = with pkgsUpstream.lib; let
    noGames = flip removeAttrs [ "games" ];
    releaseLib = import "${nixpkgs}/pkgs/top-level/release-lib.nix" {
      inherit supportedSystems;
      packageSet = attrs: noGames (import vuizvui attrs).pkgs;
      nixpkgsArgs.config = {
        allowUnfree = false;
        inHydra = true;
        allowBroken = true;
      };
    };

    packagePlatforms = mapAttrs (name: value: let
      brokenOr = if value.meta.broken or false then const [] else id;
      platforms = value.meta.hydraPlatforms or (value.meta.platforms or []);
      isRecursive = value.recurseForDerivations or false
                 || value.recurseForRelease or false;
      result = if isDerivation value then brokenOr platforms
               else if isRecursive then packagePlatforms value
               else [];
      tried = builtins.tryEval result;
    in if tried.success then tried.value else []);

  in with releaseLib; mapTestOn (packagePlatforms releaseLib.pkgs);

in with pkgsUpstream.lib; with builtins; {

  machines = let
    # We need to expose all the real builds within vuizvui.lazyPackages to make
    # sure they don't get garbage collected on the Hydra instance.
    wrapLazy = machine: pkgsUpstream.runCommandLocal machine.build.name {
      fakeRuntimeDeps = machine.eval.config.vuizvui.lazyPackages;
      product = machine.build;
    } ''
      mkdir -p "$out/nix-support"
      echo "$product" > "$out/nix-support/fake-runtime-dependencies"
      for i in $fakeRuntimeDeps; do
        echo "$i" >> "$out/nix-support/fake-runtime-dependencies"
      done
    '';
  in mapAttrsRecursiveCond (m: !(m ? eval)) (const wrapLazy) allMachines;

  isoImages = let
    buildIso = attrs: let
      name = attrs.iso.config.networking.hostName;
      cond = attrs.iso.config.vuizvui.createISO;
    in if !cond then {} else pkgsUpstream.runCommandLocal "vuizvui-iso-${name}" {
      meta.description = "Live CD/USB stick of ${name}";
      iso = attrs.iso.config.system.build.isoImage;
      passthru.config = attrs.iso.config;
    } ''
      mkdir -p "$out/nix-support"
      echo "file iso" $iso/iso/*.iso* \
        >> "$out/nix-support/hydra-build-products"
    '';
  in mapAttrsRecursiveCond (m: !(m ? iso)) (const buildIso) allMachines;

  tests = let
    machineList = collect (m: m ? eval) allMachines;
    activatedTests = unique (concatMap (machine:
      machine.eval.config.vuizvui.requiresTests
    ) machineList);
    mkTest = path: setAttrByPath path (getAttrFromPath path allTests);
  in fold recursiveUpdate {} (map mkTest activatedTests) // {
    inherit (allTests) vuizvui;
  };

  inherit pkgs;

  channels = let
    mkChannel = attrs: root.pkgs.mkChannel (rec {
      name = "vuizvui-channel-${attrs.name or "generic"}-${vuizvuiVersion}";
      src = vuizvui;
      patchPhase = ''
        touch .update-on-nixos-rebuild
      '';
    } // removeAttrs attrs [ "name" ]);

    gatherTests = active: map (path: getAttrFromPath path allTests) active;

  in {
    generic = mkChannel {
      constituents = concatMap (collect isDerivation) [
        allTests.vuizvui pkgs
      ];
    };

    machines = mapAttrsRecursiveCond (m: !(m ? eval)) (path: attrs: mkChannel {
      name = "machine-${last path}";
      constituents = singleton attrs.eval.config.system.build.toplevel
                  ++ gatherTests attrs.eval.config.vuizvui.requiresTests;
    }) allMachines;
  };

  manual = let
    modules = import "${nixpkgs}/nixos/lib/eval-config.nix" {
      modules = import "${vuizvui}/modules/module-list.nix";
      check = false;
      inherit system;
    };

    patchedDocbookXSL = overrideDerivation pkgsUpstream.docbook_xsl_ns (drv: {
      # Don't chunk off <preface/>
      postPatch = (drv.postPatch or "") + ''
        sed -i -e '
          /<xsl:when.*preface/d
          /<xsl:for-each/s!|//d:preface \+!!g
          /<xsl:variable/s!|[a-z]\+::d:preface\[1\] \+!!g
        ' xhtml/chunk-common.xsl

        sed -i -e '
          /<xsl:when.*preface/,/<\/xsl:when>/d
          /<xsl:template/s!|d:preface!!g
        ' xhtml/chunk-code.xsl
      '';
    });

    isVuizvui = opt: head (splitString "." opt.name) == "vuizvui";
    filterDoc = filter (opt: isVuizvui opt && opt.visible && !opt.internal);
    optionsXML = toXML (filterDoc (optionAttrSetToDocList modules.options));
    optionsFile = toFile "options.xml" (unsafeDiscardStringContext optionsXML);

    mkXsltFlags = flags: let
      mkParam = flag: valFun: opt: val: [ "--${flag}" opt (valFun val) ];
      mkStrParam = mkParam "stringparam" id;
      mkBoolParam = mkParam "param" (b: if b then "1" else "0");
      mkFlag = path: value: let
        opt = concatStringsSep "." path;
      in if isString value then mkStrParam opt value
         else if isBool value then mkBoolParam opt value
         else throw "Invalid value for '${opt}': ${toString value}";
      result = collect isList (mapAttrsRecursive mkFlag flags);
    in concatMapStringsSep " " escapeShellArg (concatLists result);

    xsltFlags = mkXsltFlags {
      section.autolabel = true;
      section.label.includes.component.label = true;
      html.stylesheet = "style.css overrides.css highlightjs/mono-blue.css";
      html.script = "highlightjs/highlight.pack.js highlightjs/loader.js";
      xref."with".number.and.title = true;
      admon.style = "";
    };

    xsltPath = pkgsUpstream.fetchFromGitHub {
      name = "make-options-doc-xslt";
      owner = "NixOS";
      repo = "nixpkgs";
      # Latest commit before https://github.com/NixOS/nixpkgs/pull/212289
      # (df09c21fb262ed07f01099625ef9310a8a8392ae~1)
      rev = "45a5c01a26e8fc5752a2bc969977ffc5e9cadac6";
      sha256 = "1vq432z3nw16a7g25s3fin491cybc8clibhpmc65q5hwb86zpaxb";
      postFetch = ''
        mv "$out" "nixpkgs"
        mv nixpkgs/nixos/lib/make-options-doc "$out"
      '';
    };

  in pkgsUpstream.stdenv.mkDerivation {
    name = "vuizvui-options";

    nativeBuildInputs = singleton pkgsUpstream.libxslt;

    buildCommand = ''
      cp -r "${./doc}" doc
      chmod -R +w doc
      xsltproc -o intermediate.xml \
        "${xsltPath}/options-to-docbook.xsl" \
        ${optionsFile}
      xsltproc -o doc/options-db.xml \
        "${xsltPath}/postprocess-option-descriptions.xsl" \
        intermediate.xml

      dest="$out/share/doc/vuizvui"
      mkdir -p "$dest"

      xsltproc -o "$dest/" ${xsltFlags} -nonet -xinclude \
        ${patchedDocbookXSL}/xml/xsl/docbook/xhtml/chunk.xsl \
        doc/index.xml

      cp "${nixpkgs}/doc/style.css" "$dest/style.css"
      cp "${nixpkgs}/doc/overrides.css" "$dest/overrides.css"
      cp -r ${pkgsUpstream.documentation-highlighter} "$dest/highlightjs"

      mkdir -p "$out/nix-support"
      echo "doc manual $dest" > "$out/nix-support/hydra-build-products"
    '';
  };
}
