MODULE SuperPETEdit; (** Single-buffer structural edits for DarwinA2. *)
IMPORT Modules, Unix, Texts, UTF8Strings, Strings, Streams;

CONST MaxFilters = 32;
TYPE
	Regex = RECORD (* Darwin regex_t, aligned for pointers *)
		magic: SIGNED32; nsub, endp, guts: ADDRESS
	END;
	Match = RECORD first, last: SIGNED64 END;
	Filter = RECORD op: CHAR; re: Regex END;
	Range = POINTER TO RECORD first, last: SIZE; next: Range END;

VAR compile: PROCEDURE {C}(re, pattern: ADDRESS; flags: SIGNED32; locale: ADDRESS): SIGNED32;
	execute: PROCEDURE {C}(re, string: ADDRESS; count: SIZE; match: ADDRESS; flags: SIGNED32): SIGNED32;
	free: PROCEDURE {C}(re: ADDRESS);

VAR newLocale: PROCEDURE {C}(mask: SIGNED32; name, base: ADDRESS): ADDRESS;
	useLocale: PROCEDURE {C}(locale: ADDRESS): ADDRESS;
	freeLocale: PROCEDURE {C}(locale: ADDRESS);
	utf8Locale: ADDRESS;

PROCEDURE Apply*(text: Texts.Text; dotStart, dotEnd: SIZE; CONST command: ARRAY OF CHAR; out: Streams.Writer; readOnly: BOOLEAN);
VAR filters: ARRAY MaxFilters OF Filter; count, pos, length, i, n: SIZE;
	action: CHAR; arg, bytes: Strings.String; offsets: POINTER TO ARRAY OF SIZE; used: SIZE;
	replacement: POINTER TO ARRAY OF Texts.Char32; reader: Texts.TextReader; ch: Texts.Char32; whole, bad: BOOLEAN;
	head, tail, r: Range;

	PROCEDURE Space;
	BEGIN WHILE (command[pos] = " ") OR (command[pos] = 09X) DO INC(pos) END END Space;

	PROCEDURE Argument(pattern: BOOLEAN): BOOLEAN;
	VAR k: SIZE; c: CHAR;
	BEGIN
		IF command[pos] # "/" THEN RETURN FALSE END;
		INC(pos); k := 0;
		WHILE (command[pos] # 0X) & (command[pos] # "/") DO
			c := command[pos]; INC(pos);
			IF c = 5CX THEN
				c := command[pos]; IF c = 0X THEN RETURN FALSE END; INC(pos);
				IF c = "n" THEN c := 0AX ELSIF c = "t" THEN c := 09X
				ELSIF pattern & (c # "/") THEN arg[k] := 5CX; INC(k)
				END
			END;
			arg[k] := c; INC(k)
		END;
		arg[k] := 0X;
		IF command[pos] # "/" THEN RETURN FALSE END;
		INC(pos); RETURN TRUE
	END Argument;

	PROCEDURE Parse(): BOOLEAN;
	VAR op: CHAR; previousLocale: ADDRESS; rc: SIGNED32;
	BEGIN
		Space; whole := command[pos] = ",";
		IF whole OR (command[pos] = ".") THEN INC(pos) END;
		LOOP
			Space; op := command[pos]; IF op = 0X THEN RETURN FALSE END; INC(pos);
			IF (op # "x") & (op # "g") & (op # "v") THEN EXIT END;
			IF (count = MaxFilters) OR ~Argument(TRUE) OR (arg[0] = 0X) THEN RETURN FALSE END;
			filters[count].op := op;
			previousLocale := useLocale(utf8Locale);
			rc := compile(ADDRESSOF(filters[count].re), ADDRESSOF(arg[0]), 9, utf8Locale);
			previousLocale := useLocale(previousLocale);
			IF rc # 0 THEN RETURN FALSE END;
			INC(count)
		END;
		action := op;
		IF (op = "c") OR (op = "a") OR (op = "i") THEN
			IF ~Argument(FALSE) THEN RETURN FALSE END
		ELSIF (op # "d") & (op # "p") THEN RETURN FALSE END;
		Space; RETURN command[pos] = 0X
	END Parse;

	PROCEDURE CharPos(byte: SIZE): SIZE;
	VAR lo, hi, mid: SIZE;
	BEGIN
		lo := 0; hi := length;
		WHILE lo < hi DO mid := lo + (hi-lo) DIV 2;
			IF offsets[mid] < byte THEN lo := mid+1 ELSE hi := mid END
		END;
		IF offsets[lo] # byte THEN bad := TRUE END;
		RETURN lo
	END CharPos;

	PROCEDURE Visit(level, first, last: SIZE);
	VAR m: Match; cursor, a, b, previousEnd: SIZE; flags, rc: SIGNED32; item: Range; previousLocale: ADDRESS;
	BEGIN
		IF bad THEN RETURN END;
		IF level = count THEN
			NEW(item); item.first := first; item.last := last;
			(* Keep print order forward and mutation order backward. *)
			IF action = "p" THEN
				IF tail = NIL THEN head := item ELSE tail.next := item END; tail := item
			ELSE item.next := head; head := item END;
			INC(n); RETURN
		END;
		cursor := first; previousEnd := -1;
		WHILE (cursor <= last) & ~bad DO
			flags := 4; (* REG_STARTEND *)
			IF (cursor > 0) & (bytes[offsets[cursor]-1] # 0AX) THEN INC(flags) END;
			IF (last < length) & (bytes[offsets[last]] # 0AX) THEN INC(flags, 2) END;
			m.first := offsets[cursor]; m.last := offsets[last];
			previousLocale := useLocale(utf8Locale);
			rc := execute(ADDRESSOF(filters[level].re), ADDRESSOF(bytes[0]), 1, ADDRESSOF(m), flags);
			previousLocale := useLocale(previousLocale);
			IF (rc # 0) & (rc # 1) THEN bad := TRUE; RETURN END;
			IF filters[level].op # "x" THEN
				IF (rc = 0) = (filters[level].op = "g") THEN Visit(level+1, first, last) END; RETURN
			END;
			IF rc # 0 THEN RETURN END;
			a := CharPos(m.first); b := CharPos(m.last);
			IF (a # b) OR (a # previousEnd) THEN Visit(level+1, a, b) END;
			previousEnd := b; cursor := b; IF a = b THEN INC(cursor) END
		END
	END Visit;

BEGIN
	IF (compile = NIL) OR (execute = NIL) OR (free = NIL) OR (utf8Locale = 0) OR (useLocale = NIL) THEN out.String("Edit: regex engine unavailable"); out.Ln; RETURN END;
	NEW(arg, LEN(command)); count := 0; pos := 0;
	IF ~Parse() THEN out.String("Edit: invalid command or regular expression"); out.Ln
	ELSIF readOnly & (action # "p") THEN out.String("Edit: read-only buffer"); out.Ln
	ELSE
		text.AcquireWrite; length := text.GetLength(); NEW(offsets, length+1); NEW(bytes, 4*length+1); used := 0;
		NEW(reader, text); bad := FALSE; n := 0;
		FOR i := 0 TO length-1 DO offsets[i] := used; reader.ReadCh(ch);
			IF ~UTF8Strings.EncodeChar(ch, bytes^, used) THEN bad := TRUE END
		END;
		offsets[length] := used; bytes[used] := 0X;
		IF whole THEN dotStart := 0; dotEnd := length END;
		IF (dotStart < 0) OR (dotEnd < dotStart) OR (dotEnd > length) THEN bad := TRUE END;
		Visit(0, dotStart, dotEnd);
		IF bad THEN out.String("Edit: invalid range or character boundary"); out.Ln
		ELSE
			IF (action = "i") OR (action = "c") OR (action = "a") THEN
				NEW(replacement, Strings.Length(arg^)+1); i := 0; UTF8Strings.UTF8toUnicode(arg^, replacement^, i)
			END;
			r := head; WHILE r # NIL DO
				CASE action OF
				| "p": out.Bytes(bytes^, offsets[r.first], offsets[r.last]-offsets[r.first])
				| "d": text.Delete(r.first, r.last-r.first)
				| "i": text.InsertUCS32(r.first, replacement^)
				| "a": text.InsertUCS32(r.last, replacement^)
				| "c": text.Delete(r.first, r.last-r.first); text.InsertUCS32(r.first, replacement^)
				END; r := r.next
			END;
			IF action = "p" THEN out.Ln ELSE out.String("Edit: "); out.Int(n,0); out.String(" ranges"); out.Ln END
		END;
		text.ReleaseWrite
	END;
	FOR i := 0 TO count-1 DO free(ADDRESSOF(filters[i].re)) END
END Apply;

PROCEDURE Cleanup;
BEGIN IF utf8Locale # 0 THEN freeLocale(utf8Locale) END END Cleanup;

BEGIN
	Unix.Dlsym(Unix.libc, "newlocale", ADDRESSOF(newLocale));
	Unix.Dlsym(Unix.libc, "uselocale", ADDRESSOF(useLocale));
	Unix.Dlsym(Unix.libc, "freelocale", ADDRESSOF(freeLocale));
	IF (newLocale # NIL) & (freeLocale # NIL) THEN
		utf8Locale := newLocale(63, ADDRESSOF("en_US.UTF-8"), 0); Modules.InstallTermHandler(Cleanup)
	END;
	Unix.Dlsym(Unix.libc, "regcomp_l", ADDRESSOF(compile));
	Unix.Dlsym(Unix.libc, "regexec", ADDRESSOF(execute));
	Unix.Dlsym(Unix.libc, "regfree", ADDRESSOF(free))
END SuperPETEdit.
