# Historical schema fixtures

These SQL files are exact `Schema.sql` blobs from the commits in `manifest.json`, without rewriting their columns to look like the current schema. The test sets `user_version` separately because older SQL reference files left it to Swift. Sentinel source, success and unknown-attempt rows are generated in a new temporary database.

Published versions use release tags. Unreleased intermediate versions 1, 2, 4, 5, 6 and 7 use the last commit before the next version migration; these additionally exercise supported migration branches. A version number alone does not authenticate a development snapshot: the initial unpublished v11 implementation differed from the released v11 shape. It is recorded in the investigation, not claimed as a shipped upgrade regression.

The files are project code under the repository license. No personal database or media is included. `testCommitPinnedHistoricalSchemasPreserveSuccessAndUnknown` checks every fixture against current migration behavior. The manifest hash binds provenance; it does not substitute for those behavioral checks.
