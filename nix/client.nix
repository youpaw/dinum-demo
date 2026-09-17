# Demo-only overrides for the Bureautix client VM.
#
# bureautix-example is vendored as a submodule and builds its VM through
# `securix.lib.mkTerminal`, which takes no extra modules — so this is layered
# on with `extendModules` from nix/scripts/clients.sh instead of patching the
# submodule. Everything here is demo scaffolding that has no place in the
# upstream image.
{lib, ...}: let
  # The demo SSH key is generated at runtime into data/demo-ssh (it is not,
  # and should not be, in the flake), so clients.sh exports it and this reads
  # it impurely — the same pattern as the demo CA in nix/guest.nix. Empty
  # without --impure, which just means no key is baked in.
  pubKey = builtins.getEnv "SELFHOSTIX_DEMO_PUBKEY";
  keys = lib.optional (pubKey != "") pubKey;
in {
  # The image is built for French users (common/default.nix sets both as
  # mkDefault, and securix renders the X11 layout from it); the demo is driven
  # in en-US. i18n.defaultLocale is already en_US.UTF-8 upstream.
  console.keyMap = lib.mkForce "us";
  services.xserver.xkb.layout = lib.mkForce "us";

  # securix ships `PermitRootLogin prohibit-password`, so the demo key has to
  # be present before first contact — there is no password path to install it
  # over. alice gets it too, for a non-root shell into the client.
  users.users.root.openssh.authorizedKeys.keys = keys;
  users.users.alice.openssh.authorizedKeys.keys = keys;
}
