MODULE CSPDemo;
(** A concurrent prime sieve using rendezvous channels, close, and active objects. *)
IMPORT CSP, Numbers := CSPChannels(SIGNED64), Commands, Streams;

TYPE
    Primes = OBJECT
    VAR values: ARRAY 1000 OF SIGNED64; count: SIZE;
        PROCEDURE Add(value: SIGNED64);
        BEGIN {EXCLUSIVE}
            ASSERT(count < LEN(values)); values[count] := value; INC(count)
        END Add;
        (* Only the command writes output, after every filter has joined.
           Streams.Writer must not be shared between active objects. *)
        PROCEDURE Write(output: Streams.Writer);
        VAR i: SIZE;
        BEGIN
            FOR i := 0 TO count-1 DO
                IF i > 0 THEN output.Char(' ') END;
                output.Int(values[i], 0)
            END;
            output.Ln
        END Write;
    END Primes;

    Filter = OBJECT
    VAR input: Numbers.Channel; next: Filter; primes: Primes; done: BOOLEAN;
        PROCEDURE &New(primes: Primes);
        BEGIN SELF.primes := primes; NEW(input, 0) END New;
        PROCEDURE Finished;
        BEGIN {EXCLUSIVE} done := TRUE END Finished;
        PROCEDURE Join;
        BEGIN {EXCLUSIVE} AWAIT(done) END Join;
    VAR prime, value: SIGNED64; result: SIGNED32;
    BEGIN {ACTIVE}
        result := input.Receive(prime, NIL);
        IF result = CSP.Success THEN
            primes.Add(prime);
            LOOP
                result := input.Receive(value, NIL);
                IF result = CSP.Closed THEN EXIT END;
                ASSERT(result = CSP.Success);
                IF value MOD prime # 0 THEN
                    IF next = NIL THEN NEW(next, primes) END;
                    ASSERT(next.input.Send(value, NIL) = CSP.Success)
                END
            END;
            IF next # NIL THEN ASSERT(next.input.Close()); next.Join END
        ELSE ASSERT(result = CSP.Closed) END;
        Finished
    END Filter;

PROCEDURE Run*(context: Commands.Context); (** [limit, 2..1000; default 50] *)
VAR first: Filter; primes: Primes; value, limit: SIGNED32; output: Streams.Writer;
BEGIN
    IF context = NIL THEN NEW(context, NIL, NIL, NIL, NIL, NIL) END;
    output := context.out;
    limit := 50;
    context.arg.SkipWhitespace;
    IF context.arg.Available() > 0 THEN context.arg.Int(limit, FALSE) END;
    IF (limit < 2) OR (limit > 1000) THEN
        output.String('CSPDemo: limit must be between 2 and 1000'); output.Ln; output.Update; RETURN
    END;
    output.String('CSP rendezvous sieve through '); output.Int(limit, 0); output.Ln; output.Update;
    NEW(primes); NEW(first, primes);
    FOR value := 2 TO limit DO ASSERT(first.input.Send(value, NIL) = CSP.Success) END;
    ASSERT(first.input.Close()); first.Join;
    primes.Write(output);
    output.String('CSP sieve finished; all filter activities joined'); output.Ln; output.Update
END Run;
END CSPDemo.
