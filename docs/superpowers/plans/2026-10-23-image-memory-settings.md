# Adjustable image memory peak budget

User authorization: implement directly, without a prototype round. Render the finished native settings UI with synthetic state for human review. The user approved the UI after removing the top sync-boundary paragraph, then authorized finishing development and a new beta release. Complete local squash integration and beta7 packaging; do not install, change production preferences or access the personal library for validation.

## Contract

- Settings exposes `图像处理内存峰值上限`, default 2 GiB. Choices: 512 MiB, 1, 2, 4 and 8 GiB. Explain that it budgets photo decoding and visual duplicate analysis, while models, Photos and system caches consume additional memory. This is not a whole-process RSS guarantee.
- Keep the bundled model/profile, fingerprint/policy identities and successful history unchanged. Apply the preference to the shared decoded-image budget used by both Photos and source image analysis. Live Photo encoded-resource limits remain unchanged.
- An acquired lease freezes its allowance through physical completion. Updating the budget affects subsequent atomic reservations; reducing it never frees existing leases or admits excess new work.
- Persist the selected limit and last handled limit in app preferences. Absent selected value means 2 GiB; absent handled value means the historical 512 MiB. Increasing the limit rearms only held decoded-resource failures, once after active index work and image ownership have drained, before scheduling new analysis. Persist the handled marker after successful rearm. Lowering does not rearm. A restart with the same value does not keep retrying. Changing a setting during startup uses the latest value without recreating the gateway/graph.
- Runtime settings updates do not restart the app or change pause/permission/unknown-submission protections. Read-only isolated fixtures use injected preferences or no persistent preferences.
- Waiting for old image ownership before rearming must not block catalog reconciliation, source scans, recovery, or Live Photo work. Metadata-only passes must not spin while image capacity remains held.

## Steps

1. Add failing budget/reader tests; implement a mutable shared limit and atomic current-limit reservation, preserving physical ownership and returning the lease allowance to both decoders.
2. Add failing preference/runtime tests for defaults, persistence, invalid values, one-time upgrade/rearm, no repeated restart retries, and changes during in-flight work; implement runtime application and AppModel forwarding.
3. Add the native settings picker and concise explanatory copy, update held-item guidance, and exercise defaults/custom choices with synthetic model state. Capture and inspect real SwiftUI/AppKit settings in light/dark appearances, not an image mockup.
4. Run focused checks while developing, then integrated full-profile canonical validation because resource behavior changes. Use a tester and one deep review of the integrated result; resolve material findings. Preserve evidence and deliver native images for user review.
5. After the approved UI refinement, update beta7/build24 metadata, review the final delta using the existing integrated review, squash into main, and package that exact commit with the full profile. Independently verify artifacts before delivery.

## Review focus

No change to model outputs/identities, no lost reservations on reduction/cancel, no old-budget failure arriving after an increase escaping rearm, no repeated automatic retries after restart, no UI action writing real preferences or accessing Photos during fixture rendering, and no UI promise that this is a hard cap on all process/system memory.
