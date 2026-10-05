# Local TLS test fixtures

These files are required by `test/git_tls_test.dart`:

- `ca.der`: a generated test CA certificate, in the DER format returned by Windows CryptoAPI.
- `localhost-cert.pem`: a certificate signed by that test CA for `localhost` only.
- `localhost-key.pem`: its deliberately public test private key, used by the loopback HTTPS server.

Commit these files with the test. They contain no user credentials or production
keys, are not included in the application bundle, and must never be used for
production or installed in an operating system's trusted certificate store.
The CA is trusted only by an isolated client context in the test.

The localhost certificate expires on 5 October 2027. Renew it and the test CA
together when necessary; keep the CA private key out of the repository.
