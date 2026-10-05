# Public TLS root certificates

`cacert.pem` is the Mozilla CA bundle distributed by the curl project:
https://curl.se/ca/cacert.pem (downloaded 2026-10-05).
Its license and generation date are included in the file header.

Unlike `test/fixtures/tls`, this file is a runtime Flutter asset. The Windows
Git HTTPS client loads it into its own TLS context, alongside built-in roots
and Windows ROOT certificates. Certificate-chain and hostname verification
remain enabled. It contains public certificates, no private keys.

Refresh this file from the same HTTPS source when updating release dependencies
so newly trusted authorities and trust-store changes are available to users.
