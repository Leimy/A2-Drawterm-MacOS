MODULE ConcurrentSieve;

(** A small headless demonstration of Active Oberon active objects.
    Each discovered prime owns an active filter object.  Candidates flow
    concurrently through the resulting pipeline. *)

IMPORT Commands, Kernel, KernelLog;

TYPE
	Filter = OBJECT
	VAR
		prime, value, current: SIGNED32;
		next: Filter;
		full: BOOLEAN;

		PROCEDURE &Init(p: SIGNED32);
		BEGIN
			prime := p; value := 0; next := NIL; full := FALSE;
			Register
		END Init;

		PROCEDURE Put(n: SIGNED32);
		BEGIN {EXCLUSIVE}
			AWAIT(~full);
			value := n; full := TRUE
		END Put;

	BEGIN {ACTIVE}
		LOOP
			BEGIN {EXCLUSIVE}
				AWAIT(full);
				current := value;
				full := FALSE
			END;
			IF current = 0 THEN
				IF next # NIL THEN next.Put(0) ELSE Report END;
				EXIT
			ELSIF current MOD prime # 0 THEN
				IF next = NIL THEN
					AddPrime(current);
					NEW(next, current)
				ELSE
					next.Put(current)
				END
			END
		END;
		Unregister
	END Filter;

VAR
	primes: POINTER TO ARRAY OF SIGNED32;
	nofPrimes, activeFilters, demoLimit, runLimit, startTicks: SIGNED32;

PROCEDURE Register;
BEGIN {EXCLUSIVE}
	INC(activeFilters)
END Register;

PROCEDURE Unregister;
BEGIN {EXCLUSIVE}
	DEC(activeFilters)
END Unregister;

PROCEDURE AddPrime(p: SIGNED32);
BEGIN {EXCLUSIVE}
	primes[nofPrimes] := p;
	INC(nofPrimes)
END AddPrime;

PROCEDURE Report;
VAR i: SIGNED32;
BEGIN
	KernelLog.String("Active-object sieve through "); KernelLog.Int(runLimit, 0);
	KernelLog.String(": "); KernelLog.Int(nofPrimes, 0);
	KernelLog.String(" primes in ");
	KernelLog.Int(Kernel.GetTicks() - startTicks, 0); KernelLog.String(" ms");
	KernelLog.Ln;
	FOR i := 0 TO nofPrimes - 1 DO
		KernelLog.Int(primes[i], 0);
		IF i + 1 < nofPrimes THEN KernelLog.Char(" ") END
	END;
	KernelLog.Ln
END Report;

PROCEDURE Run*(context: Commands.Context); (** [limit] ~ *)
VAR limit, n: SIGNED32; first: Filter;
BEGIN
	limit := 200;
	IF demoLimit > 0 THEN
		limit := demoLimit; demoLimit := 0
	ELSE
		context.arg.SkipWhitespace;
		IF context.arg.Available() > 0 THEN context.arg.Int(limit, FALSE) END
	END;
	IF limit < 2 THEN
		context.out.String("limit must be at least 2"); context.out.Ln;
		RETURN
	END;

	NEW(primes, limit); nofPrimes := 0; activeFilters := 0;
	AddPrime(2);
	runLimit := limit; startTicks := Kernel.GetTicks();
	NEW(first, 2);
	FOR n := 3 TO limit BY 2 DO first.Put(n) END;
	first.Put(0)
END Run;

PROCEDURE Demo*;
VAR context: Commands.Context;
BEGIN
	NEW(context, NIL, NIL, NIL, NIL, NIL);
	demoLimit := 50;
	Run(context)
END Demo;

END ConcurrentSieve.

ConcurrentSieve.Run 200 ~
