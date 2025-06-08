{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    utils.url = "github:numtide/flake-utils";
    my-utils = { url = "github:nmrshll/nix-utils"; inputs.nixpkgs.follows = "nixpkgs"; inputs.utils.follows = "utils"; };

    rust-overlay = { url = "github:oxalica/rust-overlay"; inputs.nixpkgs.follows = "nixpkgs"; };
    crane = { url = "github:ipetkov/crane"; };
  };

  outputs = { self, nixpkgs, utils, rust-overlay, my-utils, crane }:
    with builtins; utils.lib.eachDefaultSystem (system:
      let
        dbg = obj: trace (toJSON obj) obj;

        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };
        inherit (pkgs) lib;

        customRust = pkgs.rust-bin.stable."1.87.0".default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
          targets = [ ];
        };
        craneLib = crane.mkLib pkgs;

        buildInputs = [
          customRust
        ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
          # pkgs.apple-sdk_15
          # pkgs.libiconv
        ];
        devInputs = with pkgs; [
          cargo-nextest
        ];

        src = craneLib.cleanCargoSource ./.;
        commonArgs = { inherit src buildInputs; strictDeps = true; };
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;
        perCrateArgs = pname: {
          inherit pname cargoArtifacts;
          version = (craneLib.crateNameFromCargoToml { inherit src; }).version;
          cargoExtraArgs = "-p ${pname}";
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [ (craneLib.fileset.commonCargoSources ./crates/${pname}) ./Cargo.toml ./Cargo.lock ];
          };
          doCheck = false; # we disable tests since we'll run them all via cargo-nextest
        };

        crates = {
          new = craneLib.buildPackage (perCrateArgs "new");
        };
        tests = {
          clippy = craneLib.cargoClippy (commonArgs // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          });
        };

        env = {
          RUST_BACKTRACE = "1";
        };

        wd = "$(git rev-parse --show-toplevel)";
        scripts = mapAttrs (name: txt: pkgs.writeScriptBin name txt) {
          # run = ''cargo run $(packages) $@ '';
          run = ''cargo run $@ '';
          # utest = ''cargo nextest run --workspace --nocapture -- $SINGLE_TEST '';
          utest = ''set -x; cargo nextest run $(packages) --nocapture "$@" -- $SINGLE_TEST '';
          check = ''nix flake check'';

          prun = ''cargo run -p $@ '';
          build = ''nix build . --show-trace '';
          packages = ''if [ -n "$CRATE" ]; then echo "-p $CRATE"; else echo "--workspace"; fi '';
          ptest = ''package="$1"; shift; cargo nextest run -p "$package" --nocapture "$@" -- "$SINGLE_TEST" '';
        };

      in
      {
        packages = crates // { default = crates.new; };
        checks = tests;
        devShells.default = with pkgs; mkShell {
          inherit env;
          buildInputs = buildInputs ++ devInputs ++ (attrValues scripts);
          shellHook = "
              ${my-utils.binaries.${system}.configure-vscode};
              dotenv
            ";
        };
      }
    );
}




