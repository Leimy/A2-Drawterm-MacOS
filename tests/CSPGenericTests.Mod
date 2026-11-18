MODULE CSPGenericTests;
IMPORT CSP, CSPGenericPeer, Commands, Kernel, KernelLog,
    Numbers := CSPChannels(SIGNED64), Requests := CSPChannels(Request),
    Objects := CSPChannels(Message), Blocks := CSPChannels(Block);

TYPE
    Message = OBJECT VAR id: SIGNED32 END Message;
    Request = RECORD id: SIGNED32; label: ARRAY 8 OF CHAR; target: Message END;
    Block = ARRAY 4 OF SIGNED32;

    NumberSender = OBJECT
    VAR channel: Numbers.Channel; cancel: CSP.Cancellation; result: SIGNED32; done: BOOLEAN;
        PROCEDURE &New(channel: Numbers.Channel; cancel: CSP.Cancellation);
        BEGIN SELF.channel := channel; SELF.cancel := cancel END New;
        PROCEDURE Finish;
        BEGIN {EXCLUSIVE} done := TRUE END Finish;
        PROCEDURE Join;
        BEGIN {EXCLUSIVE} AWAIT(done) END Join;
    BEGIN {ACTIVE} result := channel.Send(101, cancel); Finish
    END NumberSender;

    RequestSender = OBJECT
    VAR channel: Requests.Channel; cancel: CSP.Cancellation; value: Request;
        result: SIGNED32; done: BOOLEAN;
        PROCEDURE &New(channel: Requests.Channel; cancel: CSP.Cancellation);
        BEGIN SELF.channel := channel; SELF.cancel := cancel; value.id := 202 END New;
        PROCEDURE Finish;
        BEGIN {EXCLUSIVE} done := TRUE END Finish;
        PROCEDURE Join;
        BEGIN {EXCLUSIVE} AWAIT(done) END Join;
    BEGIN {ACTIVE} result := channel.Send(value, cancel); Finish
    END RequestSender;

    ChoiceSender = OBJECT
    VAR numbers: Numbers.Channel; requests: Requests.Channel; value: Request;
        result: SIGNED32; index: SIZE; done: BOOLEAN; offers: ARRAY 2 OF CSP.Offer;
        PROCEDURE &New(numbers: Numbers.Channel; requests: Requests.Channel);
        BEGIN SELF.numbers := numbers; SELF.requests := requests; value.id := 404 END New;
        PROCEDURE Finish;
        BEGIN {EXCLUSIVE} done := TRUE END Finish;
        PROCEDURE Join;
        BEGIN {EXCLUSIVE} AWAIT(done) END Join;
    BEGIN {ACTIVE}
        offers[0] := numbers.SendOffer(303); offers[1] := requests.SendOffer(value);
        result := CSP.Select(offers, NIL, index); Finish
    END ChoiceSender;

PROCEDURE Values;
VAR numbers: Numbers.Channel; requests: Requests.Channel; objects: Objects.Channel; blocks: Blocks.Channel;
    a, b: Request; source, destination: Block; message: Message; number: SIGNED64;
    send: Requests.Offer; offers: ARRAY 1 OF CSP.Offer; index: SIZE; generic: ANY;
BEGIN
    NEW(numbers, 2); ASSERT(CSPGenericPeer.IsChannel(numbers));
    numbers := CSPGenericPeer.Create(2); generic := numbers;
    ASSERT(generic IS Numbers.Channel); ASSERT(numbers.Capacity() = 2);
    ASSERT(CSPGenericPeer.Send(numbers, MIN(SIGNED64)) = CSP.Success);
    ASSERT(numbers.Send(MAX(SIGNED64), NIL) = CSP.Success);
    ASSERT(numbers.TrySend(0) = CSP.WouldBlock);
    ASSERT(numbers.Receive(number, NIL) = CSP.Success); ASSERT(number = MIN(SIGNED64));
    ASSERT(numbers.Receive(number, NIL) = CSP.Success); ASSERT(number = MAX(SIGNED64));
    number := 999; ASSERT(numbers.TryReceive(number) = CSP.WouldBlock); ASSERT(number = 999);
    ASSERT(numbers.Close()); ASSERT(~numbers.Close()); ASSERT(numbers.IsClosed());
    ASSERT(numbers.Receive(number, NIL) = CSP.Closed); ASSERT(number = 999);

    NEW(requests, 1); a.id := 11; COPY('before', a.label); NEW(a.target); a.target.id := 42;
    send := requests.SendOffer(a); offers[0] := send;
    a.id := 99; a.label[0] := 'X'; a.target := NIL;
    ASSERT(CSP.Select(offers, NIL, index) = CSP.Success); ASSERT(index = 0);
    Kernel.GC;
    ASSERT(requests.Receive(b, NIL) = CSP.Success);
    ASSERT(b.id = 11); ASSERT(b.label = 'before'); ASSERT(b.target.id = 42);
    ASSERT(CSP.TrySelect(offers, NIL, index) = CSP.Invalid);
    ASSERT(requests.Close()); b.id := 123;
    ASSERT(requests.Receive(b, NIL) = CSP.Closed); ASSERT(b.id = 123);

    NEW(objects, 2); NEW(message); message.id := 9;
    ASSERT(objects.Send(message, NIL) = CSP.Success); ASSERT(objects.Send(NIL, NIL) = CSP.Success);
    message := NIL; Kernel.GC;
    ASSERT(objects.Receive(message, NIL) = CSP.Success); ASSERT(message.id = 9);
    ASSERT(objects.Receive(message, NIL) = CSP.Success); ASSERT(message = NIL);

    NEW(blocks, 1); source[0] := 1; source[1] := 2; source[2] := 3; source[3] := 4;
    ASSERT(blocks.Send(source, NIL) = CSP.Success); source[0] := -1;
    ASSERT(blocks.Receive(destination, NIL) = CSP.Success);
    ASSERT((destination[0] = 1) & (destination[3] = 4));
    KernelLog.String('GENERIC CSP PASS typed integers, records, objects, arrays and GC'); KernelLog.Ln
END Values;

PROCEDURE MixedChoices;
VAR numbers: Numbers.Channel; requests: Requests.Channel; cancel: CSP.Cancellation;
    ns: NumberSender; rs: RequestSender; chooser: ChoiceSender;
    number: SIGNED64; request: Request; left: Numbers.Offer; right: Requests.Offer;
    offers: ARRAY 2 OF CSP.Offer; i, index: SIZE;
BEGIN
    FOR i := 0 TO 99 DO
        NEW(numbers, 0); NEW(requests, 0); NEW(cancel);
        NEW(ns, numbers, cancel); NEW(rs, requests, cancel);
        left := numbers.ReceiveOffer(); right := requests.ReceiveOffer(); offers[0] := left; offers[1] := right;
        number := -1; request.id := -1;
        ASSERT(CSP.Select(offers, NIL, index) = CSP.Success); cancel.Cancel;
        ns.Join; rs.Join;
        IF index = 0 THEN
            ASSERT(left.Get(number)); ASSERT(number = 101); ASSERT(~right.Get(request)); ASSERT(request.id = -1);
            ASSERT(ns.result = CSP.Success); ASSERT(rs.result = CSP.Cancelled)
        ELSE
            ASSERT(index = 1); ASSERT(right.Get(request)); ASSERT(request.id = 202);
            ASSERT(~left.Get(number)); ASSERT(number = -1);
            ASSERT(rs.result = CSP.Success); ASSERT(ns.result = CSP.Cancelled)
        END;
        ASSERT(numbers.TryReceive(number) = CSP.WouldBlock);
        ASSERT(requests.TryReceive(request) = CSP.WouldBlock);
        ASSERT(numbers.TrySend(1) = CSP.WouldBlock); ASSERT(requests.TrySend(request) = CSP.WouldBlock)
    END;
    FOR i := 0 TO 99 DO
        NEW(numbers, 0); NEW(requests, 0); NEW(chooser, numbers, requests);
        left := numbers.ReceiveOffer(); right := requests.ReceiveOffer(); offers[0] := left; offers[1] := right;
        ASSERT(CSP.Select(offers, NIL, index) = CSP.Success); chooser.Join;
        ASSERT(chooser.result = CSP.Success); ASSERT(chooser.index = index);
        IF index = 0 THEN ASSERT(left.Get(number)); ASSERT(number = 303)
        ELSE ASSERT(right.Get(request)); ASSERT(request.id = 404) END;
        ASSERT(numbers.TrySend(1) = CSP.WouldBlock); ASSERT(requests.TrySend(request) = CSP.WouldBlock);
        ASSERT(numbers.TryReceive(number) = CSP.WouldBlock); ASSERT(requests.TryReceive(request) = CSP.WouldBlock)
    END;
    KernelLog.String('GENERIC CSP PASS one coordinator across types (200 choice races)'); KernelLog.Ln
END MixedChoices;

PROCEDURE FailureAndBufferedChoice;
VAR numbers: Numbers.Channel; requests: Requests.Channel;
    number: SIGNED64; request: Request; cancel: CSP.Cancellation; index: SIZE;
    left: Numbers.Offer; right: Requests.Offer; offers: ARRAY 2 OF CSP.Offer;
BEGIN
    NEW(numbers, 0); left := numbers.ReceiveOffer(); offers[0] := left; offers[1] := left;
    ASSERT(CSP.TrySelect(offers, NIL, index) = CSP.Invalid);
    offers[1] := numbers.SendOffer(1);
    ASSERT(CSP.TrySelect(offers, NIL, index) = CSP.WouldBlock);
    number := 99; ASSERT(~left.Get(number)); ASSERT(number = 99);
    ASSERT(CSP.TrySelect(offers, NIL, index) = CSP.Invalid);
    NEW(requests, 1); NEW(cancel); cancel.Cancel; request.id := 77;
    ASSERT(requests.Receive(request, cancel) = CSP.Cancelled); ASSERT(request.id = 77);
    right := requests.ReceiveOffer(); offers[0] := right; offers[1] := numbers.ReceiveOffer();
    ASSERT(requests.Close());
    ASSERT(CSP.Select(offers, NIL, index) = CSP.Closed); ASSERT(index = 0);
    ASSERT(~right.Get(request)); ASSERT(request.id = 77);
    NEW(numbers, 1); NEW(requests, 1);
    ASSERT(numbers.Send(88, NIL) = CSP.Success); request.id := 99;
    ASSERT(requests.Send(request, NIL) = CSP.Success);
    offers[0] := numbers.ReceiveOffer(); right := requests.ReceiveOffer(); offers[1] := right;
    ASSERT(CSP.Select(offers, NIL, index) = CSP.Success);
    IF index = 0 THEN
        ASSERT(requests.Receive(request, NIL) = CSP.Success); ASSERT(request.id = 99);
        ASSERT(numbers.TryReceive(number) = CSP.WouldBlock)
    ELSE
        ASSERT(right.Get(request)); ASSERT(request.id = 99);
        ASSERT(numbers.Receive(number, NIL) = CSP.Success); ASSERT(number = 88);
        ASSERT(requests.TryReceive(request) = CSP.WouldBlock)
    END;
    KernelLog.String('GENERIC CSP PASS failure paths, offer reuse and buffered mixed choice'); KernelLog.Ln
END FailureAndBufferedChoice;

PROCEDURE Run*(context: Commands.Context);
BEGIN
    Values; MixedChoices; FailureAndBufferedChoice;
    KernelLog.String('GENERIC CSP TESTS PASS'); KernelLog.Ln
END Run;
END CSPGenericTests.
