# bindgen as aurora's kernel needs it: 0.73.2 with the two patches in the
# kernel source's tools/aurora-bindgen/patches (empty-struct alignment and
# anonymous tag members). Stock bindgen drops the alignment of aligned empty
# structs, and the kernel's layout assertions then stop the Rust build
# (Documentation/rust/bindgen-layout-checks.rst in aurora's tree).
#
# `src` is the kernel source, so the patches follow the linux flake input.
{ fetchFromGitHub, rustPlatform, rust-bindgen-unwrapped, rust-bindgen, src }:

let
  version = "0.73.2";
  bindgenSrc = fetchFromGitHub {
    owner = "rust-lang";
    repo = "rust-bindgen";
    rev = "v${version}";
    hash = "sha256-b+0LM4AbngOsOPp0YjLww3EINHJFSbISLbUa2H/HiaA=";
  };
  unwrapped = rust-bindgen-unwrapped.overrideAttrs (old: {
    inherit version;
    src = bindgenSrc;
    cargoDeps = rustPlatform.fetchCargoVendor {
      src = bindgenSrc;
      name = "rust-bindgen-unwrapped-${version}";
      hash = "sha256-eiIw/FcTb+s1Syf7hLnlLyeU1+TEZa8Mz4c1NC1dEN0=";
    };
    patches = (old.patches or [ ]) ++ [
      "${src}/tools/aurora-bindgen/patches/0001-empty-alignment.patch"
      "${src}/tools/aurora-bindgen/patches/0002-anonymous-tag-members.patch"
    ];
    # bindgen's own test suite expects stock output.
    doCheck = false;
  });
in
rust-bindgen.override { rust-bindgen-unwrapped = unwrapped; }
