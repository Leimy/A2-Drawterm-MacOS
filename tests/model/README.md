# A monitor wakeup in ActivityTrees

Open `MonitorWake.tla` and start at `Check`, `Park`, and `Fill`. A PlusCal
label starts an atomic step. The consumer registers its guard at `Check`,
under the mailbox mutex. After the mutex is released, the producer can fill
the mailbox before the consumer reaches `Park`. The notification stays in
the owner's inbox until the owner can dispatch again.

| Model step | Runtime operation |
| --- | --- |
| Check | Objects.AwaitExternal registers a guard with Scheduler.PrepareWait and releases the monitor |
| Fill / Recheck | Objects.SignalExternal evaluates the published guard while holding the monitor and calls Activity.Post |
| Park | Scheduler.WaitExternal links the waiter and parks the running fiber |
| Poll | The owning worker drains the inbox or wakes parked waiters on failure |
| Resume | The waiter reacquires the monitor, removes its guard, and retests the predicate |

The model has one consumer, one producer, one mailbox, two items, and an
optional cancellation. The owner and consumer describe two phases on the
same worker. Only a parked consumer can be made ready by the owner.
Generation numbers in the model identify which registration a notification
came from. The implementation uses mutex-protected registration and removal.

The producer, consumer and owner have weak fairness: a continuously enabled
participant eventually takes a step. Cancellation is optional. The check starts
at the monitor protocol and abstracts delivery of tree failure to this owner.
TLC checks eventual completion, exact unwind on cancellation, and clean
waiter state at join for all interleavings in this finite model. GC, OS signal
delivery, unbounded trees, application deadlocks, timing, multiple consumers
competing for one item, and the rest of the scheduler are outside its scope.

## Run the model

With Java and a local copy of the [TLA+ tools](https://github.com/tlaplus/tlaplus/releases),
run from the repository root:

```sh
TLA2TOOLS=/absolute/path/to/tla2tools.jar scripts/test-a2-monitor-model.sh
```

Set `JAVA` to the absolute Java executable if needed. The script translates
the PlusCal source in a temporary directory, checks the normal protocol, then
expects a liveness counterexample with `DropEarly = TRUE`. In that trace the
mailbox is full, its consumer is parked, and the inbox is empty. TLC calls
the final repetition of that state “stuttering.”

## Run the implementation regression

```sh
scripts/test-a2-monitor-wake.sh
```

This uses the same Darwin arm64 or Linux x86-64 standalone build setup as
`scripts/test-a2-activity-trees.sh`. A test fiber wraps its worker's existing
`waitExternal` delegate. A condition-variable handshake makes a native producer
finish posting before the fiber calls the real park routine, on every round.
A parent watchdog bounds the run.

With 128 unrelated waiters parked, 64 handoffs must visit exactly 64 wait
records in the instrumented poll loops. Keep that counter on each visited
record when changing the polling algorithm. After the first handoff the test
also samples the process-wide heap allocation counter. Its small allowance
for background allocations is below one fresh guard per wait. The test drains
and checks every cold waiter before closing the scheduler.
