================================================================================
TRM — ISSUE TRACKER
Plain text on purpose; append, don't reformat.

Each item has a file under issues/ holding its record — what was actually
done, how it was verified, and where any screenshots and logs live. This file
stays the index; issues/README.md explains the split.

This is the same layout trm's own checklist window reads, so trm can be
supervised through trm.
================================================================================

STATUS KEY
  DEPLOYED  fixed and live
  STAGED    fixed in a working tree, NOT deployed
  OPEN      not fixed

SECTION 1 — PANES.  NOT FIXED.

T-01  A new remote pane should open in the focused remote pane's folder    OPEN
      Opening a remote pane while another remote pane is focused starts it
      in the default directory rather than beside the work already on
      screen. When you are three directories deep on a machine and want a
      second shell there, you have to navigate again by hand, and the pane
      you wanted next to the first one starts somewhere else.

      Expected: if a remote pane is focused when a new remote pane is
      opened, the new pane opens on the same host, in that pane's current
      working directory.

      Notes toward a fix: the cwd of a remote pane is already resolved for
      the issue tracker and the Command Center — `IssueTrackerStore`
      discovers it per zmx session in one SSH round trip, and
      `AgentOverviewPane.workingDirectory(for:)` reads it for local panes.
      A restored remote pane recovers its cwd from the shell process that
      owns the session, since zmx does not replay Ghostty's `pwd` action, so
      whatever this uses has to tolerate the cwd arriving late rather than
      falling back to the default the moment it is not yet known.
