----------------------------- MODULE MonitorWake -----------------------------
EXTENDS Naturals, TLC
CONSTANT DropEarly
(* --algorithm MonitorWake
variables full = FALSE, meals = 0, produced = 0, generation = 0,
          published = 0, notified = FALSE, armed = FALSE, inbox = 0, parked = FALSE, ready = FALSE,
          failed = FALSE, unwinds = 0, joined = FALSE;

(* SignalExternal evaluates the current guard under the mailbox mutex.
   Post takes the inbox lock while that mutex remains held. published is
   a ghost generation identifying the guard that issued the notification. *)
macro SignalGuard() begin
  if published # 0 /\ full /\ ~notified then
    notified := TRUE;
    if armed then
      assert inbox = 0;
      armed := FALSE;
      if ~DropEarly \/ parked then inbox := published end if;
    end if;
  end if;
end macro;

fair process Consumer = "consumer"
begin
Check:
  if failed then goto Unwind
  elsif full then
    full := FALSE;
    meals := meals + 1;
    if meals = 2 then goto Return else goto Check end if;
  else
    \* Under the mailbox lock: publish the guard, then release the lock.
    generation := generation + 1;
    published := generation;
    notified := FALSE;
    armed := TRUE;
  end if;
Park:
  \* The producer can already have posted before this owner yields.
  parked := TRUE;
Resume:
  await ready;
  ready := FALSE;
  published := 0;
  goto Check;
Unwind:
  unwinds := unwinds + 1;
Return:
  skip;
end process;

fair process Producer = "producer"
begin
Fill:
  await ~full \/ failed \/ pc["consumer"] = "Done";
  if failed \/ pc["consumer"] = "Done" then goto Finished else
    full := TRUE;
    produced := produced + 1;
    SignalGuard();
  end if;
Recheck:
  SignalGuard();
  if produced < 2 then goto Fill end if;
Finished:
  skip;
end process;

fair process Owner = "owner"
begin
Poll:
  await pc["consumer"] = "Done" \/ (parked /\ (inbox # 0 \/ failed));
  if pc["consumer"] = "Done" then
    joined := TRUE;
  else
    assert inbox = 0 \/ inbox = generation;
    inbox := 0;
    armed := FALSE;
    parked := FALSE;
    ready := TRUE;
    goto Poll;
  end if;
end process;

process Cancellation = "canceller"
begin
Cancel:
  either skip or
    if pc["consumer"] \notin {"Return", "Done"} then failed := TRUE end if;
  end either;
end process;
end algorithm; *)
CleanJoin == joined => (~parked /\ ~ready /\ ~armed /\ published = 0 /\ inbox = 0 /\
                         IF failed THEN unwinds = 1 ELSE meals = 2)
Accounting == meals <= produced /\ produced <= 2 /\ unwinds <= 1
Progress == <>joined
=============================================================================
