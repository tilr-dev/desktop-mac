## Event ordering
`ChildView.release` sets `discarded`, drops the WKWebView and calls `schedule`. The report is coalesced through `DispatchQueue.main.async`. Observing the state or the weak reference becoming nil does not establish that this queued report has arrived.

The probe records state reports and awaits the matching discarded report, using the existing automation timeout as a failure bound. It subscribes on the main actor, checking already received state first. Browser events and reports for other views do not satisfy the wait.

## Regression scenario
Seed a live state report, queue the discarded report on the main queue, and enter the same report wait used by the discard probe without yielding first. An immediate read returns the live state deterministically; an event wait resumes with the queued discarded state. This reproduces the ordering without clock delays or changes to the provider.
