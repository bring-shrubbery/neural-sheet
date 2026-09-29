// The tags the suites carry. Only one is needed: the checkpoint suites are the package's
// cost, and the medium and large ones are minutes of decoding rather than seconds, so they
// say so.
//
// Nothing in the package skips on a tag by itself. `swift test` selects by name
// (`--filter MediumOracleTests`); the tag is what an Xcode test plan and a CI report group
// by, so a run that has no time for the large sizes can leave them out without knowing
// which suites they happen to be in today.

import Testing

extension Tag {
    /// Minutes, not seconds: a suite that decodes the `medium` or `large` checkpoint.
    @Tag static var slow: Self
}
