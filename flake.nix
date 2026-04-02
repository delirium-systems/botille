{
  description = "Botille — AI containment tool running agents in a rootless Podman container";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    serena = {
      url = "github:oraios/serena";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  nixConfig = {
    extra-substituters = [
      "https://delirium-systems.cachix.org"
      "https://cache.numtide.com"
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "delirium-systems.cachix.org-1:66ovNl3TR96B++WAvUK0U6nmrejRLR3DYoFzQbKnPHs="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      home-manager,
      llm-agents,
      serena,
    }:
    let
      cacheData = import ./nix/caches.nix;

      # Core builder — wraps all per-system derivations so that both
      # apps.default and lib.mkApp share the same logic.
      mkBotille =
        {
          system,
          extraHomeManagerModules ? [ ],
        }:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };

          home = "/home/user";

          containerPackages = import ./nix/packages.nix {
            inherit pkgs;
            llmAgentsPkgs = llm-agents.packages.${system};
            homeManagerPkg = home-manager.packages.${system}.home-manager;
            serenaPkg = serena.packages.${system}.default;
          };

          # Home-manager activation package (built at Nix time, activated at container start).
          # extraHomeManagerModules are appended last so they can override base settings.
          hmActivation =
            (home-manager.lib.homeManagerConfiguration {
              inherit pkgs;
              modules = [
                ./home.nix
              ]
              ++ extraHomeManagerModules;
            }).activationPackage;

          # Generate nix.conf from shared cache data
          cacheLines = builtins.concatStringsSep "" (
            map (c: "extra-substituters = ${c.url}\nextra-trusted-public-keys = ${c.key}\n") cacheData.caches
          );
          nixConf = pkgs.writeTextDir "etc/nix/nix.conf" ''
            build-users-group =
            max-jobs = auto
            auto-optimise-store = true
            use-xdg-base-directories = true
            experimental-features = nix-command flakes
            ${cacheLines}
          '';

          # Registration info for all image store paths (nix-store --load-db format)
          imageClosureInfo = pkgs.closureInfo {
            rootPaths = containerPackages ++ [
              pkgs.dockerTools.fakeNss
              nixConf
              hmActivation
            ];
          };

          # closureInfo doesn't include itself in its own registration.
          # Without this, the GC root (which points to imageClosureInfo)
          # is dangling from Nix's perspective and nix store gc ignores it,
          # collecting unreferenced leaf paths like nixConf and fakeNss.
          closureInfoReg = pkgs.closureInfo {
            rootPaths = [ imageClosureInfo ];
          };

          entrypoint = import ./nix/entrypoint.nix {
            inherit
              pkgs
              imageClosureInfo
              closureInfoReg
              home
              hmActivation
              ;
          };

          firewall = import ./nix/firewall.nix { inherit pkgs; };

          container = import ./nix/container.nix {
            inherit
              pkgs
              containerPackages
              nixConf
              entrypoint
              home
              ;
          };

          launcher = import ./nix/launcher.nix {
            inherit pkgs container home;
            inherit (firewall) hooksDir;
          };

        in
        {
          inherit pkgs container launcher;
          app = {
            type = "app";
            program = pkgs.lib.getExe launcher;
          };
        };

    in
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        built = mkBotille { inherit system; };
        inherit (built) pkgs container launcher;
        tests = import ./nix/tests.nix { inherit pkgs launcher; };
      in
      {
        packages = {
          inherit container;
          default = container;
        };

        apps.default = built.app;

        checks = {
          statix = pkgs.runCommand "statix" { nativeBuildInputs = [ pkgs.statix ]; } ''
            statix check ${self}
            touch $out
          '';

          deadnix = pkgs.runCommand "deadnix" { nativeBuildInputs = [ pkgs.deadnix ]; } ''
            deadnix --fail ${self}
            touch $out
          '';
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux tests;

        formatter = pkgs.nixfmt;
      }
    )
    // {
      # Flake library — customise the home-manager configuration baked into
      # the container image without forking this repository.
      #
      # Usage: create a wrapper flake.nix in your project:
      #
      #   {
      #     inputs.botille.url = "github:delirium-systems/botille";
      #     outputs = { self, botille }: {
      #       apps.x86_64-linux.default = botille.lib.mkApp {
      #         system = "x86_64-linux";
      #         extraHomeManagerModules = [
      #           { programs.git.userEmail = "you@example.com"; }
      #           ./extra-hm.nix
      #         ];
      #       };
      #     };
      #   }
      #
      # Note: customised images are not in the delirium-systems cachix cache
      # and will be built locally on first use.
      lib = {
        mkApp =
          {
            system,
            extraHomeManagerModules ? [ ],
          }:
          (mkBotille { inherit system extraHomeManagerModules; }).app;
      };
    };
}
