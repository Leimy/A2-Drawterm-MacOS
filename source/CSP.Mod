MODULE CSP;
(** CSP communication for active objects, implemented entirely as a library.
    All mutable protocol state belongs to this module's passive monitor.
    No callbacks or application code execute while that monitor is held. *)

CONST
    Success* = 0; Closed* = 1; Cancelled* = 2; WouldBlock* = 3; Invalid* = 4;
    Sending = 0; Receiving = 1;

TYPE
    Packet* = OBJECT END Packet;

    Cancellation* = OBJECT
    VAR cancelled: BOOLEAN;
        PROCEDURE Cancel*;
        BEGIN CancelToken(SELF) END Cancel;
        PROCEDURE IsCancelled*(): BOOLEAN;
        BEGIN RETURN TokenCancelled(SELF) END IsCancelled;
    END Cancellation;

    Channel* = OBJECT
    VAR
        capacity, head, count: SIZE;
        buffer: POINTER TO ARRAY OF Packet;
        closed: BOOLEAN;
        PROCEDURE &New*(size: SIZE);
        BEGIN
            ASSERT(size >= 0); capacity := size;
            IF size > 0 THEN NEW(buffer, size) END
        END New;
        PROCEDURE Close*(): BOOLEAN;
        BEGIN RETURN CloseChannel(SELF) END Close;
        PROCEDURE IsClosed*(): BOOLEAN;
        BEGIN RETURN ChannelClosed(SELF) END IsClosed;
        PROCEDURE Capacity*(): SIZE;
        BEGIN RETURN capacity END Capacity;
        PROCEDURE SendOffer*(value: Packet): PacketOffer;
        VAR offer: PacketOffer;
        BEGIN
            NEW(offer); offer.channel := SELF; offer.direction := Sending;
            offer.value := value; RETURN offer
        END SendOffer;
        PROCEDURE ReceiveOffer*(): PacketOffer;
        VAR offer: PacketOffer;
        BEGIN
            NEW(offer); offer.channel := SELF; offer.direction := Receiving; RETURN offer
        END ReceiveOffer;
        PROCEDURE Send*(value: Packet; cancel: Cancellation): SIGNED32;
        BEGIN RETURN One(SendOffer(value), cancel, TRUE) END Send;
        PROCEDURE Receive*(VAR value: Packet; cancel: Cancellation): SIGNED32;
        VAR offer: PacketOffer; result: SIGNED32;
        BEGIN
            offer := ReceiveOffer(); result := One(offer, cancel, TRUE);
            IF result = Success THEN value := offer.value END;
            RETURN result
        END Receive;
        PROCEDURE TrySend*(value: Packet): SIGNED32;
        BEGIN RETURN One(SendOffer(value), NIL, FALSE) END TrySend;
        PROCEDURE TryReceive*(VAR value: Packet): SIGNED32;
        VAR offer: PacketOffer; result: SIGNED32;
        BEGIN
            offer := ReceiveOffer(); result := One(offer, NIL, FALSE);
            IF result = Success THEN value := offer.value END;
            RETURN result
        END TryReceive;
    END Channel;

    (** Offers are one-shot intentions. Unselected sends have no effect.
        Use fresh offers for each Select/TrySelect, including after WouldBlock. *)
    Offer* = OBJECT
    VAR channel: Channel; direction: SIGNED32; value: Packet; used, received: BOOLEAN;
        (** Typed adapters return their concrete transport offer. Select calls
            this before entering the coordinator monitor; never under its lock. *)
        PROCEDURE GetOffer*(): Offer;
        BEGIN RETURN SELF END GetOffer;
    END Offer;

    PacketOffer* = OBJECT(Offer)
        PROCEDURE ReadPacket*(VAR value: Packet): BOOLEAN;
        BEGIN RETURN ReadReceived(SELF, value) END ReadPacket;
    END PacketOffer;

    Choice = POINTER TO RECORD
        next: Choice;
        offers: POINTER TO ARRAY OF Offer;
        cancel: Cancellation;
        start, index: SIZE;
        result: SIGNED32;
        done: BOOLEAN;
    END;

VAR first, last: Choice; turn: SIZE;

(* Internal helpers run only with the module monitor held. *)
PROCEDURE Finish(choice: Choice; index: SIZE; result: SIGNED32);
VAR previous, current: Choice;
BEGIN
    previous := NIL; current := first;
    WHILE (current # NIL) & (current # choice) DO previous := current; current := current.next END;
    ASSERT(current = choice);
    IF previous = NIL THEN first := choice.next ELSE previous.next := choice.next END;
    IF last = choice THEN last := previous END;
    choice.next := NIL; choice.index := index; choice.result := result; choice.done := TRUE;
    IF (index >= 0) & (result = Success) THEN
        choice.offers[index].received := choice.offers[index].direction = Receiving
    END
END Finish;

PROCEDURE CancelledChoice(choice: Choice): BOOLEAN;
BEGIN RETURN (choice.cancel # NIL) & choice.cancel.cancelled END CancelledChoice;

PROCEDURE Pump;
VAR
    choice, peer: Choice; offer, other: Offer; channel: Channel;
    i, j, index, otherIndex, tail: SIZE; progress: BOOLEAN;
BEGIN
    REPEAT
        progress := FALSE; choice := first;
        WHILE (choice # NIL) & ~progress DO
            IF CancelledChoice(choice) THEN
                Finish(choice, -1, Cancelled); progress := TRUE
            ELSE
                i := 0;
                WHILE (i < LEN(choice.offers)) & ~progress DO
                    index := (choice.start + i) MOD LEN(choice.offers);
                    offer := choice.offers[index]; channel := offer.channel;
                    IF channel.closed & ((offer.direction = Sending) OR (channel.count = 0)) THEN
                        Finish(choice, index, Closed); progress := TRUE
                    ELSIF (offer.direction = Receiving) & (channel.count > 0) THEN
                        offer.value := channel.buffer[channel.head];
                        channel.buffer[channel.head] := NIL;
                        channel.head := (channel.head + 1) MOD channel.capacity; DEC(channel.count);
                        Finish(choice, index, Success); progress := TRUE
                    ELSIF (offer.direction = Sending) & (channel.count < channel.capacity) THEN
                        tail := (channel.head + channel.count) MOD channel.capacity;
                        channel.buffer[tail] := offer.value; INC(channel.count);
                        Finish(choice, index, Success); progress := TRUE
                    ELSIF channel.capacity = 0 THEN
                        peer := first;
                        WHILE (peer # NIL) & ~progress DO
                            (* Two alternatives of the SAME choice cannot communicate. *)
                            IF (peer # choice) & ~CancelledChoice(peer) THEN
                                j := 0;
                                WHILE (j < LEN(peer.offers)) & ~progress DO
                                    otherIndex := (peer.start + j) MOD LEN(peer.offers);
                                    other := peer.offers[otherIndex];
                                    IF (other.channel = channel) & (other.direction # offer.direction) THEN
                                        IF offer.direction = Sending THEN other.value := offer.value
                                        ELSE offer.value := other.value END;
                                        Finish(choice, index, Success); Finish(peer, otherIndex, Success);
                                        progress := TRUE
                                    END;
                                    INC(j)
                                END
                            END;
                            IF ~progress THEN peer := peer.next END
                        END
                    END;
                    INC(i)
                END
            END;
            IF ~progress THEN choice := choice.next END
        END
    UNTIL ~progress
END Pump;

PROCEDURE Choose(CONST offers: ARRAY OF Offer; cancel: Cancellation; wait: BOOLEAN;
    VAR index: SIZE): SIGNED32;
VAR choice: Choice; i, j: SIZE;
BEGIN {EXCLUSIVE}
    index := -1;
    IF LEN(offers) = 0 THEN RETURN Invalid END;
    FOR i := 0 TO LEN(offers)-1 DO
        IF (offers[i] = NIL) OR offers[i].used OR (offers[i].channel = NIL) THEN RETURN Invalid END;
        FOR j := 0 TO i-1 DO IF offers[i] = offers[j] THEN RETURN Invalid END END
    END;
    NEW(choice); NEW(choice.offers, LEN(offers)); choice.cancel := cancel; choice.index := -1;
    choice.start := turn MOD LEN(offers);
    IF LEN(offers) > 1 THEN
        IF turn = MAX(SIZE) THEN turn := 0 ELSE INC(turn) END
    END;
    FOR i := 0 TO LEN(offers)-1 DO choice.offers[i] := offers[i]; offers[i].used := TRUE END;
    IF last = NIL THEN first := choice ELSE last.next := choice END; last := choice;
    Pump;
    IF ~choice.done THEN
        IF wait THEN AWAIT(choice.done) ELSE Finish(choice, -1, WouldBlock) END
    END;
    index := choice.index;
    RETURN choice.result
END Choose;

(** Atomic external choice. index identifies the selected branch on Success or
    Closed, and is -1 on Cancelled, WouldBlock or Invalid. Closing is selectable;
    buffered values are drained before a receive reports Closed. Cancellation
    wins only if observed before a communication commits. No cancellation reset. *)
PROCEDURE SelectOffers(CONST offers: ARRAY OF Offer; cancel: Cancellation; wait: BOOLEAN;
    VAR index: SIZE): SIGNED32;
VAR concrete: POINTER TO ARRAY OF Offer; i: SIZE;
BEGIN
    index := -1;
    IF LEN(offers) = 0 THEN RETURN Invalid END;
    NEW(concrete, LEN(offers));
    FOR i := 0 TO LEN(offers)-1 DO
        IF offers[i] = NIL THEN RETURN Invalid END;
        concrete[i] := offers[i].GetOffer()
    END;
    RETURN Choose(concrete^, cancel, wait, index)
END SelectOffers;

PROCEDURE Select*(CONST offers: ARRAY OF Offer; cancel: Cancellation; VAR index: SIZE): SIGNED32;
BEGIN RETURN SelectOffers(offers, cancel, TRUE, index) END Select;

PROCEDURE TrySelect*(CONST offers: ARRAY OF Offer; cancel: Cancellation; VAR index: SIZE): SIGNED32;
BEGIN RETURN SelectOffers(offers, cancel, FALSE, index) END TrySelect;

PROCEDURE One(offer: Offer; cancel: Cancellation; wait: BOOLEAN): SIGNED32;
VAR offers: ARRAY 1 OF Offer; index: SIZE;
BEGIN offers[0] := offer; RETURN Choose(offers, cancel, wait, index) END One;

PROCEDURE CancelToken(cancel: Cancellation);
BEGIN {EXCLUSIVE}
    cancel.cancelled := TRUE; Pump
END CancelToken;

PROCEDURE TokenCancelled(cancel: Cancellation): BOOLEAN;
BEGIN {EXCLUSIVE} RETURN cancel.cancelled END TokenCancelled;

PROCEDURE CloseChannel(channel: Channel): BOOLEAN;
BEGIN {EXCLUSIVE}
    IF channel.closed THEN RETURN FALSE END;
    channel.closed := TRUE; Pump; RETURN TRUE
END CloseChannel;

PROCEDURE ChannelClosed(channel: Channel): BOOLEAN;
BEGIN {EXCLUSIVE} RETURN channel.closed END ChannelClosed;

PROCEDURE ReadReceived(offer: Offer; VAR value: Packet): BOOLEAN;
BEGIN {EXCLUSIVE}
    IF ~offer.received THEN RETURN FALSE END;
    value := offer.value; RETURN TRUE
END ReadReceived;

END CSP.
