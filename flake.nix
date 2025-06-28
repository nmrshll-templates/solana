{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    utils.url = "github:numtide/flake-utils";
    my-utils = { url = "github:nmrshll/nix-utils"; inputs.nixpkgs.follows = "nixpkgs"; inputs.utils.follows = "utils"; };

    rust-overlay = { url = "github:oxalica/rust-overlay"; inputs.nixpkgs.follows = "nixpkgs"; };
    crane = { url = "github:ipetkov/crane"; };
  };

  # largely forked from https://github.com/arijoon/solana-nix
  outputs = { self, nixpkgs, utils, rust-overlay, my-utils, crane, ... }:
    with builtins; utils.lib.eachDefaultSystem (system:
      let
        dbg = obj: trace (toJSON obj) obj;

        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };
        inherit (pkgs) lib stdenv callPackage;

        srcs = {
          agave = { version }:
            let
              sha256 = {
                "2.3.0" = "sha256-JrK8U0yYq2IS2luC1nbSM0nOC0XZLYKgtv7GBEPtCns=";
                "2.2.3" = "sha256-nRCamrwzoPX0cAEcP6p0t0t9Q41RjM6okupOPkJH5lQ=";
              }.${version};
            in
            pkgs.fetchFromGitHub { inherit sha256; owner = "anza-xyz"; repo = "agave"; rev = "v${version}"; fetchSubmodules = true; };


          solana-platform-tools =
            let
              mapSystemStr = { x86_64-linux = "linux-x86_64"; aarch64-linux = "linux-aarch64"; x86_64-darwin = "osx-x86_64"; aarch64-darwin = "osx-aarch64"; x86_64-windows = "windows-x86_64"; };
              perVersionHash = {
                x86_64-linux."1.45" = "sha256-QGm7mOd3UnssYhPt8RSSRiS5LiddkXuDtWuakpak0Y0=";
                aarch64-linux."1.45" = "sha256-UzOekFBdjtHJzzytmkQETd6Mrb+cdAsbZBA0kzc75Ws=";
                x86_64-darwin."1.45" = "sha256-EE7nVJ+8a/snx4ea7U+zexU/vTMX16WoU5Kbv5t2vN8=";
                aarch64-darwin."1.45" = "sha256-aJjYD4vhsLcBMAC8hXrecrMvyzbkas9VNF9nnNxtbiE=";
                x86_64-windows."1.45" = "sha256-7D7NN2tClnQ/UAwKUZEZqNVQxcKWguU3Fs1pgsC5CIk=";
              }.${system};
            in
            mapAttrs (version: hash: { sysStr = mapSystemStr.${system}; inherit hash version; }) perVersionHash;
        };


        ownPkgs = {
          rust = pkgs.rust-bin.stable."1.87.0".default.override {
            extensions = [ "rust-src" "rust-analyzer" ];
            targets = [ ];
          };

          spl-token = { pkgs, version ? "5.1.0" }:
            let
              # version = "5.1.0";
              pname = "spl-token";
              srcHash = "sha256-XqQgTbiiLKHSTInxdRh1SYgtwxcyr9Q9XJPx9+tDRwc=";
              cargoHash = "sha256-e07bJvN0+Hhd8qzhr91Ft8JjzIdkxNNkaRofj01oM2c=";
            in
            pkgs.rustPlatform.buildRustPackage {
              src = pkgs.fetchFromGitHub {
                owner = "solana-program";
                repo = "token-2022";
                rev = "cli@v${version}";
                hash = srcHash;
              };

              useFetchCargoVendor = true;
              inherit pname version cargoHash;

              nativeBuildInputs = [
                pkgs.pkg-config
                pkgs.protobuf
                pkgs.rustPlatform.bindgenHook
              ];

              buildInputs = [
                pkgs.openssl
                pkgs.rocksdb_8_11
                pkgs.snappy
              ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.udev ];

              # don't make me do this
              doCheck = false;

              # avoid building rocksdb from source
              # https://github.com/rust-rocksdb/rust-rocksdb/blob/master/librocksdb-sys/build.rs
              ROCKSDB_LIB_DIR = "${pkgs.rocksdb_8_11}/lib";
              SNAPPY_LIB_DIR = "${pkgs.snappy}/lib";

              # https://docs.rs/openssl/latest/openssl/#manual
              OPENSSL_NO_VENDOR = 1;
              OPENSSL_STATIC = 1;
            };

          solana-platform-tools = { pkgs, version ? "1.45" }:
            let
              source = srcs.solana-platform-tools.${version};
              agaveSrc = srcs.agave { version = "2.2.3"; };
            in
            stdenv.mkDerivation {
              inherit version;
              pname = "solana-platform-tools";
              src = pkgs.fetchzip {
                url = "https://github.com/anza-xyz/platform-tools/releases/download/v${version}/platform-tools-${source.sysStr}.tar.bz2";
                hash = source.hash;
                stripRoot = false;
              };

              doCheck = false;
              # https://github.com/NixOS/nixpkgs/issues/380196#issuecomment-2646189651
              dontCheckForBrokenSymlinks = true;

              nativeBuildInputs = lib.optionals stdenv.isLinux [ autoPatchelfHook ];
              buildInputs = [
                pkgs.libedit # Auto patching
                pkgs.zlib
                pkgs.stdenv.cc.cc
                pkgs.libclang.lib
                pkgs.xz
                pkgs.python310
              ] ++ lib.optionals stdenv.isLinux [ udev ];

              installPhase = ''
                platformtools=$out/bin/platform-tools-sdk/sbf/dependencies/platform-tools
                mkdir -p $platformtools
                cp -r $src/llvm $platformtools
                cp -r $src/rust $platformtools
                chmod 0755 -R $out
                touch $platformtools-${version}.md

                # Criterion is also needed
                criterion=$out/bin/platform-tools-sdk/sbf/dependencies/criterion
                mkdir $criterion
                ln -s ${pkgs.criterion.dev}/include $criterion/include
                ln -s ${pkgs.criterion}/lib $criterion/lib
                ln -s ${pkgs.criterion}/share $criterion/share
                touch $criterion-v${pkgs.criterion.version}.md

                cp -ar ${agaveSrc}/platform-tools-sdk/sbf/* $out/bin/platform-tools-sdk/sbf/
              '';

              # A bit ugly, but liblldb.so uses libedit.so.2 and nix provides libedit.so
              postFixup = lib.optionals stdenv.isLinux ''
                patchelf --replace-needed libedit.so.2 libedit.so $out/bin/platform-tools-sdk/sbf/dependencies/platform-tools/llvm/lib/liblldb.so.18.1.7-rust-dev
              '';

              # We need to preserve metadata in .rlib, which might get stripped on macOS. See https://github.com/NixOS/nixpkgs/issues/218712
              stripExclude = [ "*.rlib" ];
            };

          cargo-build-sbf = { pkgs, version ? "2.3.0" }:
            let
              platform-tools = pkgs.callPackage ownPkgs.solana-platform-tools { };
              srcPatched = dbg (stdenv.mkDerivation {
                name = "cargo-build-sbf-patched";
                src = srcs.agave { inherit version; };
                phases = [
                  "unpackPhase"
                  "patchPhase"
                  "installPhase"
                ];
                patches = [ ./cargo-build-sbf-main.patch ];
                installPhase = ''
                  runHook preInstall
                  mkdir -p $out
                  cp -r ./* $out/
                  runHook postInstall
                '';
              });
              commonArgs = rec {
                pname = "cargo-build-sbf";
                inherit version;
                src = srcPatched;

                strictDeps = true;
                cargoExtraArgs = "--bin=${pname}";

                doCheck = false;
                nativeBuildInputs = [
                  pkgs.protobuf
                  pkgs.pkg-config
                ];
                buildInputs = [
                  pkgs.openssl
                  pkgs.rustPlatform.bindgenHook
                  pkgs.makeWrapper
                ]
                ++ lib.optionals stdenv.isLinux [ pkgs.udev ]
                ++ lib.optionals stdenv.isDarwin [ pkgs.libcxx /*IOKit Security AppKit System Libsystem*/ ];

                # https://crane.dev/faq/rebuilds-bindgen.html?highlight=bindgen#i-see-the-bindgen-crate-constantly-rebuilding
                NIX_OUTPATH_USED_AS_RANDOM_SEED = "aaaaaaaaaa";

                # Used by build.rs in the rocksdb-sys crate
                ROCKSDB_LIB_DIR = "${pkgs.rocksdb_8_11}/lib";
                ROCKSDB_INCLUDE_DIR = "${pkgs.rocksdb_8_11}/include";

                # For darwin systems
                CPPFLAGS = lib.optionals stdenv.isDarwin "-isystem ${lib.getDev pkgs.libcxx}/include/c++/v1";
                LDFLAGS = lib.optionals stdenv.isDarwin "-L${lib.getLib pkgs.libcxx}/lib";

                # If set, always finds OpenSSL in the system, even if the vendored feature is enabled.
                OPENSSL_NO_VENDOR = 1;
              };
              cargoArtifacts = craneLib.buildDepsOnly (
                commonArgs
                // {
                  # inherit cargoVendorDir;
                  # specify dummySrc manually to avoid errors when parsing the manifests for target-less crates
                  # such as client-test. The sources rarely change in this context so it shouldn't matter much
                  # TODO: use proper (custom) dummySrc
                  dummySrc = srcPatched;
                }
              );
            in
            craneLib.buildPackage (
              commonArgs
              // {
                inherit cargoArtifacts;

                postInstall = ''
                  # original from solana-cli:
                  # rust=${platform-tools}/bin/platform-tools-sdk/sbf/dependencies/platform-tools/rust/bin
                  # sbfsdkdir=${platform-tools}/bin/platform-tools-sdk/sbf
                  # wrapProgram $out/bin/cargo-build-sbf \
                  #     --prefix PATH : "$rust" \
                  #     --set SBF_SDK_PATH "$sbfsdkdir" \
                  #     --append-flags --no-rustup-override \
                  #     --append-flags --skip-tools-install

                  # Wrap cargo-build-sbf to use our platform tools
                  wrapProgram $out/bin/cargo-build-sbf \
                    --set SBF_SDK_PATH "${platform-tools}/bin/platform-tools-sdk/sbf" \
                    --set RUSTC "${platform-tools}/bin/platform-tools-sdk/sbf/dependencies/platform-tools/rust/bin/rustc" \
                    --append-flags --no-rustup-override \
                    --append-flags --skip-tools-install
                '';

              }
            );

          solana-cli = { pkgs, version ? "2.2.3" }:
            let
              # version = srcs.agave.version; # TODO inline source, use version arg
              src = srcs.agave { version = "2.2.3"; };
              platform-tools = pkgs.callPackage ownPkgs.solana-platform-tools { };

              solanaPkgs = [ "agave-install" "agave-install-init" "agave-ledger-tool" "agave-validator" "agave-watchtower" "cargo-build-sbf" "cargo-test-sbf" "rbpf-cli" "solana" "solana-bench-tps" "solana-faucet" "solana-gossip" "solana-keygen" "solana-log-analyzer" "solana-net-shaper" "solana-dos" "solana-stake-accounts" "solana-test-validator" "solana-tokens" "solana-genesis" ];

              commonArgs = {
                pname = "solana-cli";
                inherit src version;

                strictDeps = true;
                cargoExtraArgs = lib.concatMapStringsSep " " (n: "--bin=${n}") solanaPkgs;

                # Even tho the tests work, a shit ton of them try to connect to a local RPC
                # or access internet in other ways, eventually failing due to Nix sandbox.
                # Maybe we could restrict the check to the tests that don't require an RPC,
                # but judging by the quantity of tests, that seems like a lengthty work
                doCheck = false;

                nativeBuildInputs = [
                  pkgs.protobuf
                  pkgs.pkg-config
                ];
                buildInputs = [
                  pkgs.openssl
                  pkgs.rustPlatform.bindgenHook
                  pkgs.makeWrapper
                ]
                ++ lib.optionals stdenv.isLinux [ pkgs.udev ]
                ++ lib.optionals stdenv.isDarwin [ pkgs.libcxx /*IOKit Security AppKit System Libsystem*/ ];

                # https://crane.dev/faq/rebuilds-bindgen.html?highlight=bindgen#i-see-the-bindgen-crate-constantly-rebuilding
                NIX_OUTPATH_USED_AS_RANDOM_SEED = "aaaaaaaaaa";

                # Used by build.rs in the rocksdb-sys crate
                ROCKSDB_LIB_DIR = "${pkgs.rocksdb_8_11}/lib";
                ROCKSDB_INCLUDE_DIR = "${pkgs.rocksdb_8_11}/include";

                # For darwin systems
                CPPFLAGS = lib.optionals stdenv.isDarwin "-isystem ${lib.getDev pkgs.libcxx}/include/c++/v1";
                LDFLAGS = lib.optionals stdenv.isDarwin "-L${lib.getLib pkgs.libcxx}/lib";

                # If set, always finds OpenSSL in the system, even if the vendored feature is enabled.
                OPENSSL_NO_VENDOR = 1;
              };

              cargoArtifacts = craneLib.buildDepsOnly (
                commonArgs
                // {
                  # inherit cargoVendorDir;
                  # specify dummySrc manually to avoid errors when parsing the manifests for target-less crates
                  # such as client-test. The sources rarely change in this context so it shouldn't matter much
                  # TODO: use proper (custom) dummySrc
                  dummySrc = src;
                }
              );
            in
            craneLib.buildPackage (
              commonArgs
              // {
                inherit cargoArtifacts;

                postInstall = ''
                  mkdir -p $out/bin/platform-tools-sdk/sbf
                  cp -a ./platform-tools-sdk/sbf/* $out/bin/platform-tools-sdk/sbf/

                  rust=${platform-tools}/bin/platform-tools-sdk/sbf/dependencies/platform-tools/rust/bin
                  sbfsdkdir=${platform-tools}/bin/platform-tools-sdk/sbf
                  wrapProgram $out/bin/cargo-build-sbf \
                    --prefix PATH : "$rust" \
                    --set SBF_SDK_PATH "$sbfsdkdir" \
                    --append-flags --no-rustup-override \
                    --append-flags --skip-tools-install
                '';

                passthru.updateScript = nix-update-script { };
              }
            );


          anchor-cli = { pkgs, version ? "0.31.1" }:
            let
              pname = "anchor-cli";
              # version = "0.31.1";

              versionsDeps."0.31.1" = {
                hash = "sha256-c+UybdZCFL40TNvxn0PHR1ch7VPhhJFDSIScetRpS3o=";
                # Unfortunately dependency on nightly compiler seems to be common in rust projects
                rust-nightly = pkgs.rust-bin.nightly."2025-04-21".minimal;
                rust = pkgs.rust-bin.stable."1.85.0".default;
                platform-tools = pkgs.callPackage ownPkgs.solana-platform-tools { version = "1.45"; };
                patches = [ (fetchurl { url = "https://raw.githubusercontent.com/arijoon/solana-nix/87bea8cac979d14c758c24d2b9178c44a6e95b39/patches/anchor-cli/0.31.1.patch"; sha256 = "sha256:0w07q4cszg54pf5511qxy9fmj1ywqbmqszjl1hsb56dq3xrpax87"; }) ];
              };
              versionDeps = versionsDeps.${version};

              craneLib = (crane.mkLib pkgs).overrideToolchain versionDeps.rust;

              originalSrc = pkgs.fetchFromGitHub {
                owner = "coral-xyz";
                repo = "anchor";
                rev = "v${version}";
                hash = versionDeps.hash;
              };

              src = stdenv.mkDerivation {
                name = "anchor-cli-patched";
                src = originalSrc;

                # Apply the patch
                phases = [
                  "unpackPhase"
                  "patchPhase"
                  "installPhase"
                ];
                patches = versionDeps.patches;

                # Install the patched source as an output
                installPhase = ''
                  runHook preInstall
                  mkdir -p $out
                  cp -r ./* $out/
                  runHook postInstall
                '';
              };

              commonArgs = {
                inherit pname version src;

                strictDeps = true;
                doCheck = false;

                nativeBuildInputs = [
                  pkgs.protobuf
                  pkgs.pkg-config
                  pkgs.makeWrapper
                ];
                buildInputs = [ ]
                  ++ lib.optionals stdenv.isLinux [ pkgs.udev ]
                  ++ lib.optional stdenv.isDarwin [ pkgs.darwin.apple_sdk.frameworks.CoreFoundation ];
              };

              # cargoArtifacts = craneLib.buildDepsOnly commonArgs;
            in
            craneLib.buildPackage (
              commonArgs
              // {
                # inherit cargoArtifacts;

                # Ensure anchor has access to Solana's cargo and rust binaries
                postInstall =
                  let
                    # Due to th way anchor is calling cargo if its not wrapped
                    # with its own toolchain, it'll access solana rust compiler instead
                    # hence the nightly entry points must be wrapped with the nightly bins
                    # to guarantee correct usage
                    # In this case we've limited the nightly bin access to `cargo`
                    cargo-nightly = pkgs.runCommand "cargo-nightly"
                      {
                        nativeBuildInputs = [ pkgs.makeWrapper ];
                      } ''
                      mkdir -p $out/bin

                      ln -s ${versionDeps.rust-nightly}/bin/cargo $out/bin/cargo

                      # Wrap cargo nightly so it uses the nightly toolchain only
                      wrapProgram $out/bin/cargo \
                        --prefix PATH : "${versionDeps.rust-nightly}/bin"
                    ''
                    ;
                  in
                  ''
                    rust=${versionDeps.platform-tools}/bin/platform-tools-sdk/sbf/dependencies/platform-tools/rust/bin
                    wrapProgram $out/bin/anchor \
                      --prefix PATH : "$rust" ${if versionDeps ? rust-nightly then "--set RUST_NIGHTLY_BIN \"${cargo-nightly}/bin\"" else ""}
                  '';

                cargoExtraArgs = "-p ${pname}";

                meta = { mainProgram = "anchor"; description = "Anchor cli"; };

                # passthru = {
                #   otherVersions = builtins.attrNames versionsDeps;
                # };
              }
            );
        };

        buildInputs = [
          ownPkgs.rust
        ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
          # pkgs.apple-sdk_15
          # pkgs.libiconv
        ];
        devInputs = [
          # pkgs.solana-cli
          # pkgs.anchor
          pkgs.nodejs_24
          pkgs.yarn
          pkgs.cargo-nextest
          (callPackage ownPkgs.spl-token { })
          (callPackage ownPkgs.solana-cli { })
          # ownPkgs.solana-platform-tools
          (callPackage ownPkgs.anchor-cli { })
          (callPackage ownPkgs.cargo-build-sbf { })
        ];

        craneLib = crane.mkLib pkgs;
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
          WD = getEnv "PWD";
          RUST_BACKTRACE = "1";
          KEYS_DIR = "${env.WD}/.cache/keys";
          KEY = "${env.KEYS_DIR}/main.json";
          # ANCHOR_PROJECT = "${wd}/my-project";
          IDL_DIR = "${env.WD}/.cache/idl";
        };

        wd = "$(git rev-parse --show-toplevel)";
        scripts = mapAttrs (name: txt: pkgs.writeScriptBin name txt)
          {
            # run = ''cargo run $(packages) $@ '';
            run = ''cargo run $@ '';
            # utest = ''cargo nextest run --workspace --nocapture -- $SINGLE_TEST '';
            # utest = ''set -x; cargo nextest run $(packages) --nocapture "$@" -- $SINGLE_TEST '';
            check = ''nix flake check --show-trace'';
            # cpkg = ''code ${(dbg solana-nix.packages)}'';

            prun = ''cargo run -p $@ '';
            # build = ''nix build . --show-trace '';
            packages = ''if [ -n "$CRATE" ]; then echo "-p $CRATE"; else echo "--workspace"; fi '';
            ptest = ''package="$1"; shift; cargo nextest run -p "$package" --nocapture "$@" -- "$SINGLE_TEST" '';

            sol = ''solana --keypair "$KEY" $@'';
            set-devnet = ''solana config set --url devnet'';
            new-wallet = ''
              if [ ! -f "$KEY" ]; then
                solana-keygen new --no-bip39-passphrase --outfile "$KEY"
              fi
            '';
            addr = ''solana address --keypair "$KEY"'';
            airdrop = ''sol airdrop 2'';

            token = ''spl-token $@ '';
            validator = ''solana-test-validator'';

            js = ''cd ${wd}/my-project; yarn install'';
            build = ''set -x; mkdir -p "$IDL_DIR"; cd ${wd}/my-project; anchor build --idl "$IDL_DIR" --idl-ts "$IDL_DIR" '';
            deploy = ''set -x; cd ${wd}/my-project; anchor deploy'';
            utest = ''set -x; cd ${wd}/my-project; anchor test --provider.wallet "$KEY" '';
          };

      in
      {
        packages = crates // { default = crates.new; } // {
          solana-platform-tools = pkgs.callPackage ownPkgs.solana-platform-tools { };
          solana-cli = pkgs.callPackage ownPkgs.solana-cli { };
          anchor-cli = pkgs.callPackage ownPkgs.anchor-cli { };
          spl-token = pkgs.callPackage ownPkgs.spl-token { };
          cargo-build-sbf = pkgs.callPackage ownPkgs.cargo-build-sbf { };
        };
        checks = tests;
        devShells.default = with pkgs; mkShellNoCC {
          inherit env;
          buildInputs = buildInputs ++ devInputs ++ (attrValues scripts);
          shellHook = ''
            ${my-utils.binaries.${system}.configure-vscode};
            dotenv
            mkdir -p "$KEYS_DIR"; mkdir -p "$IDL_DIR" 
          '';
        };
      }
    );
}
