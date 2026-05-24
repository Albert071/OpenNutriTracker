{
  description = "OpenNutriTracker reproducible development environment (Flutter + Android SDK)";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            android_sdk.accept_license = true;
            allowUnfree = true;
          };
        };
        # Match what `android/app/build.gradle` and `android/settings.gradle`
        # ask for on current develop: compileSdk / targetSdk 36, AGP 8.11.1,
        # JDK 17. These platform and build-tools versions have to exist in the
        # pinned nixpkgs; bump them together with the Gradle config when the
        # app's Android targets move. No NDK is pulled in because the build
        # has no native C/C++ to compile; add `includeNDK = true;` with a
        # matching `ndkVersions` list if a plugin ever needs it.
        androidPkgs = pkgs.androidenv.composeAndroidPackages {
          platformVersions = [ "34" "35" "36" ];
          buildToolsVersions = [ "34.0.0" "35.0.0" "36.0.0" ];
        };
        androidSdk = androidPkgs.androidsdk;
        androidSdkRoot = "${androidSdk}/libexec/android-sdk";
      in
      {
        # The flake pins the Android toolchain, but Flutter itself is the
        # version nixpkgs provides rather than the FVM-pinned 3.41.7 in
        # `.fvmrc`. It needs to satisfy the Dart `>=3.11.0` constraint in
        # pubspec.yaml; if nixpkgs lags, run `nix flake update` to pull a
        # newer Flutter, or layer FVM on top of this shell for an exact match.
        #
        # Build a debug APK once you are in the shell:
        #   dart run build_runner build --delete-conflicting-outputs
        #   flutter build apk --flavor develop --debug
        devShells.default = pkgs.mkShell {
          ANDROID_SDK_ROOT = androidSdkRoot;
          ANDROID_HOME = androidSdkRoot;
          buildInputs = [
            pkgs.flutter
            pkgs.jdk17
            pkgs.git
            androidSdk
          ];
          # Nix ships its own read-only aapt2; point Gradle at it so the build
          # does not try to fetch and exec a downloaded binary, which fails on
          # NixOS because of the patched dynamic loader.
          shellHook = ''
            export GRADLE_OPTS="-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidSdkRoot}/build-tools/36.0.0/aapt2"
          '';
        };
      });
}
