{
  description = "NixOS on the 14-inch M4 Pro, with the nixos-m4pro OCaml tools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The boot chain and kernel sources, locked in flake.lock. Following
    # upstream is `nix flake update m1n1` (or u-boot, linux) and a rebuild;
    # the patches in m1n1/, u-boot/ and kernel/ apply on top.
    m1n1 = {
      url = "github:AsahiLinux/m1n1";
      flake = false;
    };
    u-boot = {
      url = "github:aurora-silicon/u-boot/aurora-wip";
      flake = false;
    };
    linux = {
      url = "github:AsahiLinux/linux/asahi";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }@inputs:
    let
      # Sets hardware.j614s.sources from this flake's inputs; part of every
      # module exported below, so a configuration elsewhere builds the
      # sources locked here.
      sources = {
        hardware.j614s.sources = {
          inherit (inputs) m1n1 linux;
          uBoot = inputs.u-boot;
        };
      };

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

      # m1n1 with the stage 1 config lines appended, as the Asahi installer
      # writes them: chainload stage 2 from the ESP (pkgs/make-stage1.sh).
      stage1 =
        m1n1:
        nixpkgs.legacyPackages.aarch64-linux.runCommand "m1n1-stage1.bin" { } ''
          sh ${./pkgs/make-stage1.sh} ${m1n1}/lib/m1n1/m1n1.bin ${espPartuuid} $out
        '';
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
            m1n1 = pkgs.callPackage ./pkgs/m1n1.nix { src = inputs.m1n1; };
            m1n1-dev = pkgs.callPackage ./pkgs/m1n1.nix {
              src = inputs.m1n1;
              release = false;
            };
            u-boot = pkgs.callPackage ./pkgs/u-boot.nix { src = inputs.u-boot; };

            # Stage 1 for the macostest volume: the release m1n1 with its
            # config lines appended, as the Asahi installer writes them.
            m1n1-stage1 = stage1 self.packages.aarch64-linux.m1n1;
            # The same with the debug m1n1, which prints its log on the
            # screen: for finding where a chainload stops.
            m1n1-stage1-dev = stage1 self.packages.aarch64-linux.m1n1-dev;

            # Everything the host sends m1n1 to boot the J614s
            # (`just dev-boot` with m1n1's linux.py, or tools/tether-boot.py):
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

      # For a personal NixOS configuration on the J614s (another flake):
      #   default   the hardware, the SSD layout and the m1n1/U-Boot boot
      #             chain; needs allowUnfree (Apple firmware, pinned by hash)
      #   desktop   Hyprland on the boot framebuffer (greetd, aquamarine fix)
      #   hardware  the hardware alone, without the SSD layout
      nixosModules = {
        default.imports = [
          ./nixos/j614s-ssd.nix
          sources
        ];
        desktop = ./nixos/desktop.nix;
        hardware.imports = [
          ./nixos/j614s.nix
          sources
        ];
      };

      # NixOS from RAM on the J614s, booted from the host through m1n1.
      #   nix build .#nixosConfigurations.m4pro-ram.config.system.build.netboot
      # It carries the installed system (m4pro) to put on the SSD.
      nixosConfigurations.m4pro-ram = nixpkgs.lib.nixosSystem {
        modules = [
          ./nixos/ram.nix
          sources
        ];
        specialArgs = {
          diskSystem = self.nixosConfigurations.m4pro.config.system.build.toplevel;
          inherit espPartuuid;
        };
      };

      # NixOS on the internal SSD.
      nixosConfigurations.m4pro = nixpkgs.lib.nixosSystem {
        modules = [
          ./nixos/disk.nix
          sources
        ];
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
