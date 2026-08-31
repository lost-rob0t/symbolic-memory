{
  description = "Prolog-first symbolic memory server";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          prologSource = ./prolog;
        in {
          default = pkgs.writeShellApplication {
            name = "symbolic-memory-mcp";
            runtimeInputs = [ pkgs.swiProlog ];
            text = ''
              exec swipl -q -s ${prologSource}/symbolic_memory_mcp.pl -- "$@"
            '';
          };
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/symbolic-memory-mcp";
        };
      });

      checks = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in {
          tests = pkgs.runCommand "symbolic-memory-tests" {
            nativeBuildInputs = [ pkgs.swiProlog ];
          } ''
            cp -r ${./.} source
            chmod -R u+w source
            cd source
            swipl -q -s test/run_tests.pl
            touch "$out"
          '';
        });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = [ pkgs.swiProlog ];
          };
        });
    };
}
