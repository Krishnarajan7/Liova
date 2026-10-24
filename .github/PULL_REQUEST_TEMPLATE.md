## What does this change?

<!-- One or two sentences. What and why, not how. -->

Closes #

## How was it tested?

<!-- Unit tests added, manual steps, hardware used (notched / non-notched, displays). -->

## Screenshots / GIF

<!-- Required for any UI change. Show light and dark mode if relevant. Delete this section otherwise. -->

## Checklist

- [ ] Every commit is signed off (`git commit -s`) per the [DCO](https://github.com/Krishnarajan7/Liova/blob/main/CONTRIBUTING.md#sign-your-commits-dco).
- [ ] I followed the [clean-room rule](https://github.com/Krishnarajan7/Liova/blob/main/CONTRIBUTING.md#the-clean-room-rule): no code copied or adapted from GPL/unlicensed sources.
- [ ] `make format lint test` passes locally.
- [ ] [CHANGELOG.md](https://github.com/Krishnarajan7/Liova/blob/main/CHANGELOG.md) has a line under [Unreleased], written for users (or the change is invisible to them).
- [ ] New logic has unit tests.
- [ ] Performance budget respected: no new polling or timers while idle, no window-frame animation, streaming values bypass animation ([PERFORMANCE.md](https://github.com/Krishnarajan7/Liova/blob/main/docs/PERFORMANCE.md)).
- [ ] If this touches rendering or idle behaviour, I described how I measured it above.
- [ ] No new singletons or app-wide observable state.
- [ ] New dependencies (if any) are MIT/BSD/Apache and listed here with their license.
- [ ] New permission prompts (if any) are only requested when the feature that needs them is turned on.
- [ ] Docs updated if behaviour, setup, or the public API changed.
