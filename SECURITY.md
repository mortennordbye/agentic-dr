# Security Policy

## Supported Versions

Only the latest release is actively supported with security updates.

## Reporting a Vulnerability

Please do not report security vulnerabilities through public GitHub issues.
Use the "Report a vulnerability" button under this repository's **Security** tab
(private vulnerability reporting is enabled). You will receive an acknowledgement
within 48 hours.

## Scope note

This project generates infrastructure code; it holds no credentials and reaches no
network at runtime. The security properties that matter here are the blast-radius
isolation described in `ARCHITECTURE.md` §1 and the release gate in
`docs/scrub-gate.md`. A report that the generator can write outside the DR estate,
or that an identifier leaked past the scrub gate, is in scope and worth sending.
