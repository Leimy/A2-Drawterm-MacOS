MODULE CSPTests;
IMPORT CSP, CSPDemo, Commands, Kernel, KernelLog, Streams, Strings;

TYPE
    Message = OBJECT VAR value: SIGNED32 END Message;

    Sender = OBJECT
    VAR channel: CSP.IntegerChannel; cancel: CSP.Cancellation; value: SIGNED64;
        result: SIGNED32; started, done: BOOLEAN;
        PROCEDURE &New(channel: CSP.IntegerChannel; value: SIGNED64; cancel: CSP.Cancellation);
        BEGIN SELF.channel := channel; SELF.value := value; SELF.cancel := cancel END New;
        PROCEDURE Started;
        BEGIN {EXCLUSIVE} started := TRUE END Started;
        PROCEDURE WaitStarted;
        BEGIN {EXCLUSIVE} AWAIT(started) END WaitStarted;
        PROCEDURE Finished;
        BEGIN {EXCLUSIVE} done := TRUE END Finished;
        PROCEDURE Join;
        BEGIN {EXCLUSIVE} AWAIT(done) END Join;
    BEGIN {ACTIVE}
        Started; result := channel.Send(value, cancel); Finished
    END Sender;

    Receiver = OBJECT
    VAR channel: CSP.IntegerChannel; cancel: CSP.Cancellation; value: SIGNED64;
        result: SIGNED32; started, done: BOOLEAN;
        PROCEDURE &New(channel: CSP.IntegerChannel; cancel: CSP.Cancellation);
        BEGIN SELF.channel := channel; SELF.cancel := cancel; value := -99 END New;
        PROCEDURE Started;
        BEGIN {EXCLUSIVE} started := TRUE END Started;
        PROCEDURE WaitStarted;
        BEGIN {EXCLUSIVE} AWAIT(started) END WaitStarted;
        PROCEDURE Finished;
        BEGIN {EXCLUSIVE} done := TRUE END Finished;
        PROCEDURE Join;
        BEGIN {EXCLUSIVE} AWAIT(done) END Join;
    BEGIN {ACTIVE}
        Started; result := channel.Receive(value, cancel); Finished
    END Receiver;

    ChoiceReceiver = OBJECT
    VAR a, b: CSP.IntegerChannel; cancel: CSP.Cancellation;
        offers: ARRAY 2 OF CSP.Offer; left, right: CSP.IntegerOffer;
        index: SIZE; result: SIGNED32; started, done: BOOLEAN;
        PROCEDURE &New(a, b: CSP.IntegerChannel; cancel: CSP.Cancellation);
        BEGIN SELF.a := a; SELF.b := b; SELF.cancel := cancel END New;
        PROCEDURE Started;
        BEGIN {EXCLUSIVE} started := TRUE END Started;
        PROCEDURE WaitStarted;
        BEGIN {EXCLUSIVE} AWAIT(started) END WaitStarted;
        PROCEDURE Finished;
        BEGIN {EXCLUSIVE} done := TRUE END Finished;
        PROCEDURE Join;
        BEGIN {EXCLUSIVE} AWAIT(done) END Join;
    BEGIN {ACTIVE}
        left := a.ReceiveOffer(); right := b.ReceiveOffer(); offers[0] := left; offers[1] := right;
        Started; result := CSP.Select(offers, cancel, index); Finished
    END ChoiceReceiver;

    ChoiceSender = OBJECT
    VAR a, b: CSP.IntegerChannel; offers: ARRAY 2 OF CSP.Offer;
        result: SIGNED32; index: SIZE; done: BOOLEAN;
        PROCEDURE &New(a, b: CSP.IntegerChannel);
        BEGIN SELF.a := a; SELF.b := b END New;
        PROCEDURE Finished;
        BEGIN {EXCLUSIVE} done := TRUE END Finished;
        PROCEDURE Join;
        BEGIN {EXCLUSIVE} AWAIT(done) END Join;
    BEGIN {ACTIVE}
        offers[0] := a.SendOffer(17); offers[1] := b.SendOffer(23);
        result := CSP.Select(offers, NIL, index); Finished
    END ChoiceSender;

    Collector = OBJECT
    VAR seen: ARRAY 800 OF BOOLEAN; count: SIZE;
        PROCEDURE Add(value: SIGNED64);
        BEGIN {EXCLUSIVE}
            ASSERT((value >= 0) & (value < LEN(seen)));
            ASSERT(~seen[SIZE(value)]); seen[SIZE(value)] := TRUE; INC(count)
        END Add;
        PROCEDURE Check;
        VAR i: SIZE;
        BEGIN {EXCLUSIVE}
            ASSERT(count = LEN(seen));
            FOR i := 0 TO LEN(seen)-1 DO ASSERT(seen[i]) END
        END Check;
    END Collector;

    Producer = OBJECT
    VAR channel: CSP.IntegerChannel; id: SIZE; done: BOOLEAN;
        PROCEDURE &New(channel: CSP.IntegerChannel; id: SIZE);
        BEGIN SELF.channel := channel; SELF.id := id END New;
        PROCEDURE Finish;
        BEGIN {EXCLUSIVE} done := TRUE END Finish;
        PROCEDURE Join;
        BEGIN {EXCLUSIVE} AWAIT(done) END Join;
    VAR i: SIZE;
    BEGIN {ACTIVE}
        FOR i := 0 TO 99 DO ASSERT(channel.Send(SIGNED64(id*100+i), NIL) = CSP.Success) END;
        Finish
    END Producer;

    Consumer = OBJECT
    VAR channel: CSP.IntegerChannel; collector: Collector; done: BOOLEAN;
        PROCEDURE &New(channel: CSP.IntegerChannel; collector: Collector);
        BEGIN SELF.channel := channel; SELF.collector := collector END New;
        PROCEDURE Finish;
        BEGIN {EXCLUSIVE} done := TRUE END Finish;
        PROCEDURE Join;
        BEGIN {EXCLUSIVE} AWAIT(done) END Join;
    VAR value: SIGNED64; result: SIGNED32;
    BEGIN {ACTIVE}
        LOOP
            result := channel.Receive(value, NIL);
            IF result = CSP.Closed THEN EXIT END;
            ASSERT(result = CSP.Success); collector.Add(value)
        END;
        Finish
    END Consumer;

PROCEDURE Pass(CONST text: ARRAY OF CHAR);
BEGIN KernelLog.String('CSP PASS '); KernelLog.String(text); KernelLog.Ln END Pass;

PROCEDURE Rendezvous;
VAR channel: CSP.IntegerChannel; sender: Sender; receiver: Receiver; value: SIGNED64;
BEGIN
    NEW(channel, 0); ASSERT(channel.Capacity() = 0);
    ASSERT(channel.TrySend(12) = CSP.WouldBlock);
    value := 99; ASSERT(channel.TryReceive(value) = CSP.WouldBlock); ASSERT(value = 99);
    NEW(sender, channel, -9223372036854775807, NIL);
    ASSERT(channel.Receive(value, NIL) = CSP.Success);
    ASSERT(value = -9223372036854775807); sender.Join; ASSERT(sender.result = CSP.Success);
    NEW(receiver, channel, NIL);
    ASSERT(channel.Send(9223372036854775807, NIL) = CSP.Success);
    receiver.Join; ASSERT(receiver.result = CSP.Success); ASSERT(receiver.value = 9223372036854775807);
    ASSERT(channel.TryReceive(value) = CSP.WouldBlock);
    Pass('rendezvous, nonblocking operations and 64-bit values')
END Rendezvous;

PROCEDURE Buffered;
VAR channel: CSP.IntegerChannel; value: SIGNED64; sender: Sender;
BEGIN
    NEW(channel, 2); ASSERT(channel.Capacity() = 2);
    ASSERT(channel.TrySend(10) = CSP.Success); ASSERT(channel.TrySend(20) = CSP.Success);
    ASSERT(channel.TrySend(30) = CSP.WouldBlock);
    ASSERT(channel.TryReceive(value) = CSP.Success); ASSERT(value = 10);
    ASSERT(channel.TrySend(30) = CSP.Success);
    ASSERT(channel.Close()); ASSERT(~channel.Close()); ASSERT(channel.IsClosed());
    ASSERT(channel.TrySend(40) = CSP.Closed);
    ASSERT(channel.Receive(value, NIL) = CSP.Success); ASSERT(value = 20);
    ASSERT(channel.Receive(value, NIL) = CSP.Success); ASSERT(value = 30);
    value := 999; ASSERT(channel.Receive(value, NIL) = CSP.Closed); ASSERT(value = 999);
    NEW(channel, 1); ASSERT(channel.Send(1, NIL) = CSP.Success);
    NEW(sender, channel, 2, NIL);
    ASSERT(channel.Receive(value, NIL) = CSP.Success); ASSERT(value = 1);
    ASSERT(channel.Receive(value, NIL) = CSP.Success); ASSERT(value = 2);
    sender.Join; ASSERT(sender.result = CSP.Success);
    Pass('bounded FIFO, backpressure, close and drain')
END Buffered;

PROCEDURE Objects;
VAR channel: CSP.ObjectChannel; intChannel: CSP.IntegerChannel; msg: Message; value: ANY;
    offers: ARRAY 2 OF CSP.Offer; integer: CSP.IntegerOffer; object: CSP.ObjectOffer; index: SIZE;
BEGIN
    NEW(channel, 2); NEW(msg); msg.value := 42;
    ASSERT(channel.Send(msg, NIL) = CSP.Success); ASSERT(channel.Send(NIL, NIL) = CSP.Success);
    ASSERT(channel.TrySend(msg) = CSP.WouldBlock);
    Kernel.GC;
    ASSERT(channel.Receive(value, NIL) = CSP.Success); ASSERT(value = msg);
    ASSERT(value(Message).value = 42);
    ASSERT(channel.Receive(value, NIL) = CSP.Success); ASSERT(value = NIL);
    NEW(intChannel, 0); integer := intChannel.ReceiveOffer(); object := channel.ReceiveOffer();
    offers[0] := integer; offers[1] := object;
    ASSERT(channel.TrySend(msg) = CSP.Success);
    ASSERT(CSP.Select(offers, NIL, index) = CSP.Success); ASSERT(index = 1);
    ASSERT(object.Get(value)); ASSERT(value = msg);
    ASSERT(channel.Close()); ASSERT(channel.Receive(value, NIL) = CSP.Closed); ASSERT(value = msg);
    Pass('object identity, NIL payload and heterogeneous choice')
END Objects;

PROCEDURE Choice;
VAR a, b: CSP.IntegerChannel; offers: ARRAY 2 OF CSP.Offer;
    left, right: CSP.IntegerOffer; index, i, selectedLeft, selectedRight: SIZE; value: SIGNED64;
BEGIN
    NEW(a, 1); NEW(b, 1);
    ASSERT(a.TrySend(11) = CSP.Success); ASSERT(b.TrySend(22) = CSP.Success);
    selectedLeft := 0; selectedRight := 0;
    FOR i := 0 TO 19 DO
        left := a.ReceiveOffer(); right := b.ReceiveOffer(); offers[0] := left; offers[1] := right;
        value := -1; ASSERT(~left.Get(value)); ASSERT(value = -1);
        ASSERT(CSP.Select(offers, NIL, index) = CSP.Success);
        IF index = 0 THEN
            ASSERT(left.Get(value)); ASSERT(value = 11); ASSERT(~right.Get(value));
            INC(selectedLeft); ASSERT(a.TrySend(11) = CSP.Success)
        ELSE
            ASSERT(index = 1); ASSERT(right.Get(value)); ASSERT(value = 22); ASSERT(~left.Get(value));
            INC(selectedRight); ASSERT(b.TrySend(22) = CSP.Success)
        END;
        ASSERT(CSP.TrySelect(offers, NIL, index) = CSP.Invalid); ASSERT(index = -1)
    END;
    ASSERT((selectedLeft = 10) & (selectedRight = 10));
    NEW(a, 1); NEW(b, 1);
    offers[0] := a.SendOffer(1); offers[1] := b.SendOffer(2);
    ASSERT(CSP.Select(offers, NIL, index) = CSP.Success);
    IF index = 0 THEN
        ASSERT(a.TryReceive(value) = CSP.Success); ASSERT(value = 1);
        ASSERT(b.TryReceive(value) = CSP.WouldBlock)
    ELSE
        ASSERT(b.TryReceive(value) = CSP.Success); ASSERT(value = 2);
        ASSERT(a.TryReceive(value) = CSP.WouldBlock)
    END;
    Pass('atomic send/receive choice, one-shot offers and branch rotation')
END Choice;

PROCEDURE SelfAndInvalid;
VAR channel: CSP.IntegerChannel; offers: ARRAY 2 OF CSP.Offer; empty: ARRAY 0 OF CSP.Offer;
    index: SIZE; value: SIGNED64;
BEGIN
    NEW(channel, 0); offers[0] := channel.SendOffer(123); offers[1] := channel.ReceiveOffer();
    ASSERT(CSP.TrySelect(offers, NIL, index) = CSP.WouldBlock); ASSERT(index = -1);
    ASSERT(channel.TryReceive(value) = CSP.WouldBlock);
    offers[0] := channel.SendOffer(1); offers[1] := offers[0];
    ASSERT(CSP.TrySelect(offers, NIL, index) = CSP.Invalid);
    offers[1] := NIL; ASSERT(CSP.TrySelect(offers, NIL, index) = CSP.Invalid);
    ASSERT(CSP.TrySelect(empty, NIL, index) = CSP.Invalid);
    Pass('no self-rendezvous and invalid offer rejection')
END SelfAndInvalid;

PROCEDURE CancellationAndClose;
VAR channel, other: CSP.IntegerChannel; cancel: CSP.Cancellation;
    sender: Sender; receiver: Receiver; choice: ChoiceReceiver; timer: Kernel.Timer;
    value: SIGNED64; offers: ARRAY 1 OF CSP.Offer; index: SIZE;
BEGIN
    NEW(timer); NEW(channel, 0); NEW(cancel);
    NEW(receiver, channel, cancel); receiver.WaitStarted; timer.Sleep(5); Kernel.GC;
    cancel.Cancel; cancel.Cancel; receiver.Join;
    ASSERT(receiver.result = CSP.Cancelled); ASSERT(receiver.value = -99); ASSERT(cancel.IsCancelled());
    ASSERT(channel.TrySend(1) = CSP.WouldBlock);
    NEW(cancel); NEW(sender, channel, 10, cancel); sender.WaitStarted; timer.Sleep(5);
    cancel.Cancel; sender.Join; ASSERT(sender.result = CSP.Cancelled);
    ASSERT(channel.TryReceive(value) = CSP.WouldBlock);
    NEW(cancel); cancel.Cancel; ASSERT(channel.Send(1, cancel) = CSP.Cancelled);
    NEW(other, 0); NEW(cancel); NEW(choice, channel, other, cancel);
    choice.WaitStarted; timer.Sleep(5); cancel.Cancel; choice.Join;
    ASSERT(choice.result = CSP.Cancelled); ASSERT(choice.index = -1);
    ASSERT(channel.TrySend(1) = CSP.WouldBlock); ASSERT(other.TrySend(2) = CSP.WouldBlock);
    NEW(receiver, channel, NIL); receiver.WaitStarted; timer.Sleep(5);
    ASSERT(channel.Close()); receiver.Join; ASSERT(receiver.result = CSP.Closed);
    NEW(channel, 1); ASSERT(channel.Send(1, NIL) = CSP.Success);
    NEW(sender, channel, 2, NIL); sender.WaitStarted; timer.Sleep(5);
    ASSERT(channel.Close()); sender.Join; ASSERT(sender.result = CSP.Closed);
    ASSERT(channel.Receive(value, NIL) = CSP.Success); ASSERT(value = 1);
    ASSERT(channel.Receive(value, NIL) = CSP.Closed);
    NEW(channel, 1); NEW(cancel); offers[0] := channel.SendOffer(9);
    ASSERT(CSP.Select(offers, cancel, index) = CSP.Success); cancel.Cancel;
    ASSERT(channel.Receive(value, NIL) = CSP.Success); ASSERT(value = 9);
    NEW(channel, 1); ASSERT(channel.Send(7, NIL) = CSP.Success);
    NEW(cancel); cancel.Cancel; value := -1;
    ASSERT(channel.Receive(value, cancel) = CSP.Cancelled); ASSERT(value = -1);
    ASSERT(channel.Receive(value, NIL) = CSP.Success); ASSERT(value = 7);
    NEW(channel, 0); NEW(other, 0); NEW(choice, channel, other, NIL);
    choice.WaitStarted; timer.Sleep(5); ASSERT(other.Close()); choice.Join;
    ASSERT(choice.result = CSP.Closed); ASSERT(choice.index = 1);
    ASSERT(channel.TrySend(1) = CSP.WouldBlock);
    Pass('cancellation withdraws offers, close wakes waiters, commits survive cancellation')
END CancellationAndClose;

PROCEDURE CompetingChoices;
VAR a, b: CSP.IntegerChannel; cancel: CSP.Cancellation; sa, sb: Sender;
    offers: ARRAY 2 OF CSP.Offer; left, right: CSP.IntegerOffer; index, i: SIZE; value: SIGNED64;
    receiver: ChoiceReceiver; chooser: ChoiceSender;
BEGIN
    FOR i := 0 TO 49 DO
        NEW(a, 0); NEW(b, 0); NEW(cancel);
        NEW(sa, a, 100, cancel); NEW(sb, b, 200, cancel);
        left := a.ReceiveOffer(); right := b.ReceiveOffer(); offers[0] := left; offers[1] := right;
        ASSERT(CSP.Select(offers, NIL, index) = CSP.Success); cancel.Cancel;
        sa.Join; sb.Join;
        IF index = 0 THEN
            ASSERT(left.Get(value)); ASSERT(value = 100); ASSERT(~right.Get(value));
            ASSERT(sa.result = CSP.Success); ASSERT(sb.result = CSP.Cancelled)
        ELSE
            ASSERT(index = 1); ASSERT(right.Get(value)); ASSERT(value = 200); ASSERT(~left.Get(value));
            ASSERT(sb.result = CSP.Success); ASSERT(sa.result = CSP.Cancelled)
        END;
        ASSERT(a.TryReceive(value) = CSP.WouldBlock); ASSERT(b.TryReceive(value) = CSP.WouldBlock);
        (* A receiving choice that blocks first must withdraw its other branch. *)
        NEW(receiver, a, b, NIL); ASSERT(b.Send(300, NIL) = CSP.Success); receiver.Join;
        ASSERT(receiver.result = CSP.Success); ASSERT(receiver.index = 1);
        ASSERT(a.TrySend(999) = CSP.WouldBlock)
    END;
    FOR i := 0 TO 49 DO
        NEW(a, 0); NEW(b, 0);
        NEW(chooser, a, b); NEW(receiver, a, b, NIL);
        chooser.Join; receiver.Join;
        ASSERT((chooser.result = CSP.Success) & (receiver.result = CSP.Success));
        ASSERT(chooser.index = receiver.index);
        IF receiver.index = 0 THEN ASSERT(receiver.left.Get(value)); ASSERT(value = 17)
        ELSE ASSERT(receiver.right.Get(value)); ASSERT(value = 23) END;
        ASSERT(a.TryReceive(value) = CSP.WouldBlock); ASSERT(b.TryReceive(value) = CSP.WouldBlock);
        ASSERT(a.TrySend(1) = CSP.WouldBlock); ASSERT(b.TrySend(2) = CSP.WouldBlock)
    END;
    FOR i := 0 TO 99 DO
        NEW(a, 0); NEW(cancel);
        NEW(sa, a, 55, cancel); NEW(sb, a, 66, cancel);
        NEW(receiver, a, a, cancel); cancel.Cancel;
        sa.Join; sb.Join; receiver.Join;
        IF receiver.result = CSP.Success THEN
            ASSERT((sa.result = CSP.Success) # (sb.result = CSP.Success));
            ASSERT((sa.result = CSP.Cancelled) OR (sb.result = CSP.Cancelled))
        ELSE
            ASSERT(receiver.result = CSP.Cancelled);
            ASSERT((sa.result = CSP.Cancelled) & (sb.result = CSP.Cancelled))
        END;
        ASSERT(a.TryReceive(value) = CSP.WouldBlock)
    END;
    Pass('bilateral choice, losing-branch withdrawal and cancellation (200 races)')
END CompetingChoices;

PROCEDURE Contention(capacity: SIZE);
VAR channel: CSP.IntegerChannel; collector: Collector;
    producers: ARRAY 8 OF Producer; consumers: ARRAY 3 OF Consumer; i: SIZE;
BEGIN
    NEW(channel, capacity); NEW(collector);
    FOR i := 0 TO LEN(consumers)-1 DO NEW(consumers[i], channel, collector) END;
    FOR i := 0 TO LEN(producers)-1 DO NEW(producers[i], channel, i) END;
    FOR i := 0 TO LEN(producers)-1 DO producers[i].Join END;
    ASSERT(channel.Close());
    FOR i := 0 TO LEN(consumers)-1 DO consumers[i].Join END;
    collector.Check;
    KernelLog.String('CSP PASS contention capacity='); KernelLog.Int(capacity, 0);
    KernelLog.String(' delivered 800 unique values'); KernelLog.Ln
END Contention;

PROCEDURE DemoOutput;
VAR context: Commands.Context; args: Streams.StringReader; output: Streams.StringWriter;
    text: ARRAY 4096 OF CHAR;
BEGIN
    NEW(output, LEN(text)); Streams.OpenStringReader(args, '50');
    NEW(context, NIL, args, output, output, NIL); CSPDemo.Run(context); output.Get(text);
    ASSERT(Strings.Pos('CSP rendezvous sieve through 50', text) >= 0);
    ASSERT(Strings.Pos('2 3 5 7 11 13 17 19 23 29 31 37 41 43 47', text) >= 0);
    ASSERT(Strings.Pos('CSP sieve finished; all filter activities joined', text) >= 0);
    NEW(output, LEN(text)); Streams.OpenStringReader(args, '1001');
    NEW(context, NIL, args, output, output, NIL); CSPDemo.Run(context); output.Get(text);
    ASSERT(Strings.Pos('limit must be between 2 and 1000', text) >= 0);
    Pass('sieve output and errors reach the invoking command writer')
END DemoOutput;

PROCEDURE Run*(context: Commands.Context);
BEGIN
    Rendezvous; Buffered; Objects; Choice; SelfAndInvalid; CancellationAndClose; CompetingChoices;
    Contention(0); Contention(1); Contention(8); DemoOutput;
    KernelLog.String('CSP TESTS PASS'); KernelLog.Ln
END Run;
END CSPTests.
