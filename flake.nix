{
  description = "WordCraft: an open-source, clean-room Microsoft Word reimplementation in pure Rust";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The WordCraft source, built as-is. Tracks the default branch: flake.lock pins the commit,
    # and this pulls the latest one:
    #   nix flake update wordcraft-src
    wordcraft-src = {
      url = "github:storytold/wordcraft";
      flake = false;
    };

    # Optional upstream build input: the CJK/Arabic UI and document fonts that every official
    # release embeds (read by crates/fonts/build.rs through CRAFT_FONTS_DIR). Pinned to the same
    # revision as `craft-fonts-ref` in WordCraft's .github/workflows/release.yml. Without it the
    # Japanese and Chinese interface shows missing-glyph boxes.
    craft-fonts = {
      url = "github:storytold/craft-fonts/8dcdacd5153e64560d109541a47d806f26f048c0";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      wordcraft-src,
      craft-fonts,
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forEachSystem = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      version = (lib.importTOML "${wordcraft-src}/Cargo.toml").workspace.package.version;

      # lastModifiedDate is "YYYYMMDDhhmmss"; AppStream wants YYYY-MM-DD.
      releaseDate =
        let
          d = wordcraft-src.lastModifiedDate or "19700101000000";
        in
        "${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}";

      # Loaded with dlopen at run time by eframe / winit / wgpu / glutin, so they are not
      # link-time inputs: they go on the GUI binary's RUNPATH instead (see postFixup).
      runtimeLibs =
        pkgs: with pkgs; [
          wayland
          libxkbcommon
          libx11
          libxcursor
          libxi
          libxrandr
          libxcb
          vulkan-loader
          libglvnd # libEGL / libGL for wgpu's GL backend and glutin
          dbus # libdbus-1.so.3: rfd's xdg-desktop-portal file chooser dlopen()s it
        ];

      mkWordcraft =
        pkgs:
        pkgs.rustPlatform.buildRustPackage {
          pname = "wordcraft";
          inherit version;

          src = wordcraft-src;

          cargoLock = {
            lockFile = "${wordcraft-src}/Cargo.lock";
            # Cargo.lock pins git dependencies on storytold/craft-libs (craft-pdf, the patched
            # krilla, craft-ui, craft-print) at exact revisions. Fetching them with
            # builtins.fetchGit means no hand-maintained hashes, so updating wordcraft-src to a
            # newer commit never needs this file touched.
            allowBuiltinFetchGit = true;
          };

          # The desktop app and the command-line tool / MCP server, as upstream's packaging
          # builds them. (The workspace also contains the wasm web app, which needs trunk and is
          # not built here.)
          cargoBuildFlags = [
            "--package"
            "wordcraft"
            "--package"
            "wordcraft-cli"
          ];

          env = {
            CRAFT_FONTS_DIR = "${craft-fonts}";
            # Fail the build, rather than silently drop CJK glyphs, if the fonts input is stale.
            CRAFT_FONTS_REQUIRED = "1";
            # Shown in Help > About next to the version.
            WORDCRAFT_BUILD_SHA = wordcraft-src.rev or "nix-dev";
          };

          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.patchelf
            pkgs.makeWrapper
          ];

          # About 800 tests; the UI ones render through wgpu and need a GPU, which the Nix
          # sandbox does not have. Run `cargo xtask ci` from the dev shell instead.
          doCheck = false;

          postInstall = ''
            app=ai.storyteller.wordcraft

            install -Dm644 packaging/linux/$app.desktop $out/share/applications/$app.desktop
            substituteInPlace $out/share/applications/$app.desktop \
              --replace-fail "TryExec=wordcraft" "TryExec=$out/bin/wordcraft" \
              --replace-fail "Exec=wordcraft %F" "Exec=$out/bin/wordcraft %F"

            install -Dm644 packaging/linux/$app.mime.xml $out/share/mime/packages/$app.xml

            mkdir -p $out/share/metainfo
            sed -e "s/@VERSION@/${version}/g" -e "s/@DATE@/${releaseDate}/g" \
              packaging/linux/$app.metainfo.xml.in > $out/share/metainfo/$app.metainfo.xml

            mkdir -p $out/share/icons
            cp -r assets/app-icon/hicolor $out/share/icons/

            # The embedded craft-fonts are OFL-1.1: ship their licences next to ours, as
            # upstream's packages do (packaging/env.sh).
            install -Dm644 -t $out/share/doc/wordcraft \
              LICENSE-APACHE LICENSE-MIT NOTICE ATTRIBUTION.md README.md
            for ofl in ${craft-fonts}/fonts/*/OFL.txt; do
              install -Dm644 "$ofl" \
                "$out/share/doc/wordcraft/OFL-$(basename "$(dirname "$ofl")").txt"
            done
          '';

          # Only the GUI needs the graphics/windowing libraries; wordcraft-cli is headless.
          postFixup = ''
            patchelf --add-rpath ${lib.makeLibraryPath (runtimeLibs pkgs)} $out/bin/wordcraft

            # WordCraft runs through XWayland whenever DISPLAY is set (winit has no file
            # drag-and-drop on Wayland, and the compositor draws proper window decorations for
            # X11 windows), so nothing is forced here. Run with WORDCRAFT_WAYLAND=1 for a native
            # Wayland client.
            #
            # dbus-send: WordCraft probes the xdg-desktop-portal file chooser with it, and uses
            # its built-in file browser when there is no portal.
            wrapProgram $out/bin/wordcraft \
              --suffix PATH : ${lib.makeBinPath [ pkgs.dbus ]}
          '';

          meta = {
            description = "Open-source, clean-room reimplementation of Microsoft Word in pure Rust";
            homepage = "https://github.com/storytold/wordcraft";
            license = with lib.licenses; [
              mit
              asl20
              ofl # the embedded craft-fonts
            ];
            mainProgram = "wordcraft";
            platforms = systems;
          };
        };
    in
    {
      packages = forEachSystem (pkgs: rec {
        wordcraft = mkWordcraft pkgs;
        default = wordcraft;
      });

      apps = forEachSystem (
        pkgs:
        let
          wordcraft = self.packages.${pkgs.stdenv.hostPlatform.system}.wordcraft;
        in
        {
          default = {
            type = "app";
            program = lib.getExe wordcraft;
            meta.description = "WordCraft desktop app";
          };
          wordcraft-cli = {
            type = "app";
            program = "${wordcraft}/bin/wordcraft-cli";
            meta.description = "WordCraft command line and MCP server";
          };
        }
      );

      devShells = forEachSystem (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ self.packages.${pkgs.stdenv.hostPlatform.system}.wordcraft ];
          packages = with pkgs; [
            clippy
            rustfmt
            rust-analyzer
          ];
          CRAFT_FONTS_DIR = "${craft-fonts}";
          RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
          # eframe/winit/wgpu dlopen these, so `cargo run` needs them on the library path.
          LD_LIBRARY_PATH = lib.makeLibraryPath (runtimeLibs pkgs);
        };
      });

      overlays.default = final: _prev: { wordcraft = mkWordcraft final; };

      formatter = forEachSystem (pkgs: pkgs.nixfmt);
    };
}