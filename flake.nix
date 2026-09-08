{
  description = "AnkerScale local BLE recorder for macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    moonbit-overlay = {
      url = "github:moonbit-community/moonbit-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, moonbit-overlay, ... }:
    let
      pkgs = import nixpkgs {
        system = "aarch64-darwin";
        overlays = [ moonbit-overlay.overlays.default ];
      };
      moonbit = pkgs.moonbit-bin.moonbit.latest;
      ankerscale = pkgs.stdenv.mkDerivation {
        pname = "ankerscale";
        version = "0.1.0";
        src = pkgs.lib.cleanSource ./.;
        nativeBuildInputs = [
          moonbit
          pkgs.clang
          pkgs.makeWrapper
        ];
        buildInputs = [ pkgs.sqlite ];
        MOONBIT_NEW_NATIVE = "0";
        buildPhase = ''
          runHook preBuild
          moon build --release --deny-warn --quiet
          runHook postBuild
        '';
        doCheck = true;
        checkPhase = ''
          runHook preCheck
          moon test --release --deny-warn --quiet
          runHook postCheck
        '';
        installPhase = ''
          runHook preInstall
          app="$out/Applications/AnkerScale.app"
          mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchAgents" "$out/bin"
          install -m755 _build/native/release/build/cmd/main/main.exe "$app/Contents/MacOS/ankerscale"
          install -m644 resources/Info.plist "$app/Contents/Info.plist"
          install -m644 resources/com.ph0ryn.AnkerScale.collector.plist "$app/Contents/Library/LaunchAgents/"
          makeWrapper "$app/Contents/MacOS/ankerscale" "$out/bin/ankerscale"
          runHook postInstall
        '';
        postFixup = ''
          /usr/bin/codesign --force --sign - --timestamp=none "$out/Applications/AnkerScale.app"
          /usr/bin/codesign --verify --strict "$out/Applications/AnkerScale.app"
        '';
        meta = {
          description = "Local BLE scale recorder and CLI for macOS";
          license = pkgs.lib.licenses.asl20;
          platforms = [ "aarch64-darwin" ];
          mainProgram = "ankerscale";
        };
      };
    in
    {
      packages.aarch64-darwin.default = ankerscale;
      checks.aarch64-darwin.default = ankerscale;
      apps.aarch64-darwin.default = {
        type = "app";
        program = "${ankerscale}/bin/ankerscale";
      };
      devShells.aarch64-darwin.default = pkgs.mkShell {
        packages = [
          moonbit
          pkgs.clang
        ];
        buildInputs = [ pkgs.sqlite ];
        MOONBIT_NEW_NATIVE = "0";
      };
    };
}
