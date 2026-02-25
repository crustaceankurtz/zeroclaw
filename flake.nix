{
  description = "ZeroClaw - Zero overhead. Zero compromise. 100% Rust AI assistant.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    crane.url = "github:ipetkov/crane";

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, crane, fenix, ... }:
    let
      # Systems we support
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      # Helper to generate per-system outputs
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Package builder for a given system
      mkPackages = system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ fenix.overlays.default ];
          };

          # Use Rust 1.87+ from fenix (stable channel)
          rustToolchain = pkgs.fenix.stable.toolchain;

          craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

          # Source filter that includes web/dist if present
          src = pkgs.lib.cleanSourceWith {
            src = ./.;
            filter = path: type:
              let
                baseName = baseNameOf path;
                relativePath = pkgs.lib.removePrefix (toString ./. + "/") path;
              in
                # Exclude common unwanted directories
                !(baseName == "node_modules" || baseName == ".git" || baseName == "target")
                # Include everything else (including web/dist if it exists)
                && (craneLib.filterCargoSources path type || pkgs.lib.hasPrefix "web/dist" relativePath);
          };

          # Common arguments for crane builds
          commonArgs = {
            inherit src;
            strictDeps = true;

            # Build inputs needed for native dependencies
            buildInputs = with pkgs; [
              openssl
              sqlite
            ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              udev  # For USB device enumeration (nusb)
            ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              darwin.apple_sdk.frameworks.Security
              darwin.apple_sdk.frameworks.SystemConfiguration
              darwin.apple_sdk.frameworks.IOKit
            ];

            nativeBuildInputs = with pkgs; [
              pkg-config
              rustToolchain
            ];

            # Environment variables
            OPENSSL_NO_VENDOR = "1";
          };

          # Build just the cargo dependencies for caching
          cargoArtifacts = craneLib.buildDepsOnly commonArgs;

          # Build the actual package
          zeroclaw = craneLib.buildPackage (commonArgs // {
            inherit cargoArtifacts;

            # Disable tests during build (run separately)
            doCheck = false;

            meta = with pkgs.lib; {
              description = "Zero overhead. Zero compromise. 100% Rust. The fastest, smallest AI assistant.";
              homepage = "https://github.com/zeroclaw-labs/zeroclaw";
              license = with licenses; [ mit asl20 ];
              maintainers = [];
              mainProgram = "zeroclaw";
              platforms = platforms.unix;
            };
          });

          # Package with specific features enabled
          zeroclawWithFeatures = features: craneLib.buildPackage (commonArgs // {
            inherit cargoArtifacts;
            cargoExtraArgs = "--features ${builtins.concatStringsSep "," features}";
            doCheck = false;

            meta = zeroclaw.meta;
          });
        in
        {
          default = zeroclaw;
          zeroclaw = zeroclaw;

          # Feature variants
          zeroclaw-full = zeroclawWithFeatures [
            "hardware"
            "channel-matrix"
            "channel-lark"
            "observability-otel"
            "sandbox-landlock"
            "browser-native"
          ];

          zeroclaw-hardware = zeroclawWithFeatures [ "hardware" ];
          zeroclaw-matrix = zeroclawWithFeatures [ "channel-matrix" ];
        };

      # Dev shell builder
      mkDevShell = system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ fenix.overlays.default ];
          };

          rustToolchain = pkgs.fenix.stable.withComponents [
            "cargo"
            "clippy"
            "rust-src"
            "rustc"
            "rustfmt"
          ];
        in
        pkgs.mkShell {
          buildInputs = with pkgs; [
            rustToolchain
            rust-analyzer
            pkg-config
            openssl
            sqlite

            # Development tools
            cargo-watch
            cargo-edit
            cargo-outdated
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            udev
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            darwin.apple_sdk.frameworks.Security
            darwin.apple_sdk.frameworks.SystemConfiguration
            darwin.apple_sdk.frameworks.IOKit
          ];

          OPENSSL_NO_VENDOR = "1";
          RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";
        };

    in
    {
      # Per-system outputs
      packages = forAllSystems mkPackages;

      devShells = forAllSystems (system: {
        default = mkDevShell system;
      });

      # Overlay for use in other flakes
      overlays.default = final: prev: {
        zeroclaw = self.packages.${prev.system}.default;
        zeroclaw-full = self.packages.${prev.system}.zeroclaw-full;
        zeroclaw-hardware = self.packages.${prev.system}.zeroclaw-hardware;
        zeroclaw-matrix = self.packages.${prev.system}.zeroclaw-matrix;
      };

      # NixOS module for system-wide installation and service
      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.zeroclaw;
        in
        {
          options.services.zeroclaw = {
            enable = lib.mkEnableOption "ZeroClaw AI assistant";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.default;
              defaultText = lib.literalExpression "pkgs.zeroclaw";
              description = "The ZeroClaw package to use.";
            };

            user = lib.mkOption {
              type = lib.types.str;
              default = "zeroclaw";
              description = "User account under which ZeroClaw runs.";
            };

            group = lib.mkOption {
              type = lib.types.str;
              default = "zeroclaw";
              description = "Group under which ZeroClaw runs.";
            };

            dataDir = lib.mkOption {
              type = lib.types.path;
              default = "/var/lib/zeroclaw";
              description = "Directory to store ZeroClaw data.";
            };

            configFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "Path to ZeroClaw configuration file.";
            };

            environmentFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "Environment file with secrets (API keys, etc).";
            };

            extraArgs = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Extra command-line arguments to pass to ZeroClaw.";
            };

            gateway = {
              enable = lib.mkEnableOption "ZeroClaw gateway server";

              port = lib.mkOption {
                type = lib.types.port;
                default = 42617;
                description = "Port for the gateway server.";
              };

              host = lib.mkOption {
                type = lib.types.str;
                default = "127.0.0.1";
                description = "Host address for the gateway server.";
              };
            };
          };

          config = lib.mkIf cfg.enable {
            # Add package to system packages for CLI usage
            environment.systemPackages = [ cfg.package ];

            # Create user and group
            users.users.${cfg.user} = lib.mkIf (cfg.user == "zeroclaw") {
              isSystemUser = true;
              group = cfg.group;
              home = cfg.dataDir;
              createHome = true;
              description = "ZeroClaw service user";
            };

            users.groups.${cfg.group} = lib.mkIf (cfg.group == "zeroclaw") {};

            # Systemd service for gateway mode
            systemd.services.zeroclaw-gateway = lib.mkIf cfg.gateway.enable {
              description = "ZeroClaw Gateway Server";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];

              serviceConfig = {
                Type = "simple";
                User = cfg.user;
                Group = cfg.group;
                WorkingDirectory = cfg.dataDir;
                ExecStart = "${cfg.package}/bin/zeroclaw gateway --host ${cfg.gateway.host} --port ${toString cfg.gateway.port} ${lib.concatStringsSep " " cfg.extraArgs}";
                Restart = "on-failure";
                RestartSec = 5;

                # Hardening
                NoNewPrivileges = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                PrivateTmp = true;
                ReadWritePaths = [ cfg.dataDir ];
              } // lib.optionalAttrs (cfg.environmentFile != null) {
                EnvironmentFile = cfg.environmentFile;
              } // lib.optionalAttrs (cfg.configFile != null) {
                Environment = [ "ZEROCLAW_CONFIG=${cfg.configFile}" ];
              };
            };
          };
        };

      # Convenient alias
      nixosModules.zeroclaw = self.nixosModules.default;
    };
}
