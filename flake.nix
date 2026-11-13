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

      # The PARTUUID of the ESP (p4, nixos-boot). m4pro-install gives the
      # partition this UUID, and m1n1 stage 1 chainloads from it.
      espPartuuid = "c1689edb-3947-4ed4-ba55-696ead4f2833";
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
        // pkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-linux") (
          let
            ram = self.nixosConfigurations.m4pro-ram.config.system.build;
            disk = self.nixosConfigurations.m4pro.config.system.build;
            kernel = self.nixosConfigurations.m4pro.config.boot.kernelPackages.kernel;
          in
          {
            m1n1 = pkgs.callPackage ./pkgs/m1n1.nix { };
            m1n1-dev = pkgs.callPackage ./pkgs/m1n1.nix { release = false; };

            # Stage 1 for the macostest volume: the release m1n1 with its
            # config lines appended, as the Asahi installer writes them.
            m1n1-stage1 = pkgs.runCommand "m1n1-stage1.bin" { } ''
              cat ${self.packages.aarch64-linux.m1n1}/lib/m1n1/m1n1.bin > $out
              printf 'chainload=%s;m1n1/boot.bin\nchosen.asahi,efi-system-partition=%s\n' \
                ${espPartuuid} ${espPartuuid} >> $out
            '';

            # Everything the host sends m1n1 to boot the J614s
            # (tools/tether-boot.py, `just boot-ram` and `just boot-disk`):
            # the kernel and device tree, and for each system its initrd and
            # command line (init= plus the system's own kernel-params, as its
            # extlinux entry has them).
            boot-files = pkgs.runCommand "m4pro-boot-files" { } ''
              mkdir -p $out
              gzip -9n < ${kernel}/Image > $out/Image.gz
              cp ${kernel}/dtbs/apple/t6040-j614s.dtb $out/
              cp ${ram.netbootRamdisk}/initrd $out/ram-initrd
              echo "init=${ram.toplevel}/init $(cat ${ram.toplevel}/kernel-params)" > $out/ram-cmdline
              cp ${disk.initialRamdisk}/initrd $out/disk-initrd
              echo "init=${disk.toplevel}/init $(cat ${disk.toplevel}/kernel-params)" > $out/disk-cmdline
              echo ${disk.toplevel} > $out/disk-toplevel
            '';
          }
        )
      );

      # NixOS from RAM on the J614s, booted from the host through m1n1.
      #   nix build .#nixosConfigurations.m4pro-ram.config.system.build.netboot
      # It carries the installed system (m4pro) to put on the SSD.
      nixosConfigurations.m4pro-ram = nixpkgs.lib.nixosSystem {
        modules = [ ./nixos/ram.nix ];
        specialArgs = {
          diskSystem = self.nixosConfigurations.m4pro.config.system.build.toplevel;
          inherit espPartuuid;
        };
      };

      # NixOS on the internal SSD.
      nixosConfigurations.m4pro = nixpkgs.lib.nixosSystem {
        modules = [ ./nixos/disk.nix ];
      };

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
            just
          ];
        };
      });
    };
}
