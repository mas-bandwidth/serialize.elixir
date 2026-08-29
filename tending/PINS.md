# Toolchain pins

- Erlang/OTP 29.0.5 (erlef/otp_builds, signed macOS build), aarch64-apple-darwin
  - url: https://github.com/erlef/otp_builds/releases/download/OTP-29.0.5/otp-aarch64-apple-darwin.tar.gz
  - sha256: 24b9e00da2b9ad25b1f182e2efd73ff316e46ec4b143c0cc3c69dbd27d5a594d
  - unpacked at: dist/otp-29.0.5/ (gitignored; re-fetch by url+sha)
- Elixir 1.20.4 (precompiled for OTP 29)
  - url: https://github.com/elixir-lang/elixir/releases/download/v1.20.4/elixir-otp-29.zip
  - sha256: 7863c546cda13fecc949e562e326042451dacf8fd8698a36783cb71eeb223b46
  - unpacked at: dist/elixir-1.20.4/ (gitignored; re-fetch by url+sha)
- invoke: PATH="dist/otp-29.0.5/bin:dist/elixir-1.20.4/bin:$PATH" then elixir / mix
- verified together: "Elixir 1.20.4 (compiled with Erlang/OTP 29)" on erts-17.0.5 [jit]
