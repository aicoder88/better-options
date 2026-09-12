# Decisions

## 2026-09-12 — Builds are signed with a fixed local identity, not ad-hoc

Every build used to be signed ad-hoc (`codesign --sign -`), which gives the app a
new signature each time. macOS pins Accessibility and Input Monitoring to the
exact signature it approved, so each reinstall silently cut the app off from the
mouse while both switches still looked on. That is what stopped the thumb wheel
working on 2026-09-10.

A self-signed code signing certificate, "Better Options Local Signing", now lives
in the login keychain and is trusted for code signing in the machine's admin
trust domain. `scripts/build_app_bundle.sh` signs with it by hash, and warns and
falls back to ad-hoc if it is missing. The designated requirement is now
`identifier "com.dgcode88.betteroptions" and certificate root = H"91cec2..."`,
which stays the same across builds.

Reverse if: the certificate is lost, or the app ever needs a real Apple Developer
identity for distribution. Then generate a new identity, put its hash in
`BETTER_OPTIONS_SIGNING_IDENTITY`, and grant both permissions one more time.
