{
  description = "NixOS on the 14-inch M4 Pro, with the nixos-m4pro OCaml tools";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      each = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = each (
        pkgs:
        let
          fs = pkgs.lib.fileset;
        in
        {
          default = pkgs.ocamlPackages.buildDunePackage {
            pname = "nixos-m4pro";
            version = "0.1.0";
            src = fs.toSource {
              root = ./.;
              fileset = fs.unions [
                ./dune-project
                ./nixos-m4pro.opam
                ./bin
                ./lib
                ./test
              ];
            };
            doCheck = true;
          };
        }
      );

      devShells = each (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ self.packages.${pkgs.stdenv.hostPlatform.system}.default ];
          packages = with pkgs; [
            ocaml
            dune_3
            ocamlformat
            ocamlPackages.ocaml-lsp
            ocamlPackages.utop
            ocamlPackages.odoc
          ];
        };
      });
    };
}
