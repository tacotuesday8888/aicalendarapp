# Public Repository Notes

This tree is intended for a public source repository.

Included:

- iOS app source code and tests.
- Firebase Functions source, Firestore rules, Storage rules, and indexes.
- GitHub Actions workflows.
- Placeholder configuration templates.
- Public legal pages under `public/`.

Excluded:

- Private product planning notes.
- Internal launch and setup runbooks.
- Security audits and operational checklists.
- Real Firebase, Google, RevenueCat, Apple, and signing configuration.
- API keys, certificates, provisioning profiles, local environment files, logs, and build output.

Before changing repository visibility, verify both the current tree and Git history. A normal commit that deletes private files does not remove them from old commits.

Current status: the tracked tree is intended to be public-safe, but older reachable commits include private planning, audit, and setup documents that are no longer present in the current tree. Do not mirror-push this local clone or use old checkpoint refs for a public migration. Removing those historical documents requires an explicit approved history rewrite or publishing a fresh clean snapshot repository.
