MODULE CSPChannels(TYPE T);
(** Statically typed channels and offers over CSP's shared coordinator.
    Import as Integers := CSPChannels(SIGNED64), Requests := CSPChannels(Request).
    Sending captures a value of T. Embedded object references remain shared.
    Each send allocates one GC-traced box; no byte copying or unsafe casts. *)
IMPORT CSP;

TYPE
    Box = OBJECT VAR value: T END Box;

    Offer* = OBJECT(CSP.Offer)
    VAR concrete: CSP.ObjectOffer;
        PROCEDURE &New(concrete: CSP.ObjectOffer);
        BEGIN SELF.concrete := concrete END New;
        PROCEDURE GetOffer*(): CSP.Offer;
        BEGIN RETURN concrete END GetOffer;
        PROCEDURE Get*(VAR value: T): BOOLEAN;
        VAR payload: ANY;
        BEGIN
            IF ~concrete.Get(payload) THEN RETURN FALSE END;
            Unpack(payload, value); RETURN TRUE
        END Get;
    END Offer;

    Channel* = OBJECT
    VAR concrete: CSP.ObjectChannel;
        PROCEDURE &New*(capacity: SIZE);
        BEGIN NEW(concrete, capacity) END New;
        PROCEDURE SendOffer*(CONST value: T): Offer;
        VAR offer: Offer;
        BEGIN NEW(offer, concrete.SendOffer(Pack(value))); RETURN offer END SendOffer;
        PROCEDURE ReceiveOffer*(): Offer;
        VAR offer: Offer;
        BEGIN NEW(offer, concrete.ReceiveOffer()); RETURN offer END ReceiveOffer;
        PROCEDURE Send*(CONST value: T; cancel: CSP.Cancellation): SIGNED32;
        BEGIN RETURN concrete.Send(Pack(value), cancel) END Send;
        PROCEDURE Receive*(VAR value: T; cancel: CSP.Cancellation): SIGNED32;
        VAR payload: ANY; result: SIGNED32;
        BEGIN
            result := concrete.Receive(payload, cancel);
            IF result = CSP.Success THEN Unpack(payload, value) END;
            RETURN result
        END Receive;
        PROCEDURE TrySend*(CONST value: T): SIGNED32;
        BEGIN RETURN concrete.TrySend(Pack(value)) END TrySend;
        PROCEDURE TryReceive*(VAR value: T): SIGNED32;
        VAR payload: ANY; result: SIGNED32;
        BEGIN
            result := concrete.TryReceive(payload);
            IF result = CSP.Success THEN Unpack(payload, value) END;
            RETURN result
        END TryReceive;
        PROCEDURE Close*(): BOOLEAN;
        BEGIN RETURN concrete.Close() END Close;
        PROCEDURE IsClosed*(): BOOLEAN;
        BEGIN RETURN concrete.IsClosed() END IsClosed;
        PROCEDURE Capacity*(): SIZE;
        BEGIN RETURN concrete.Capacity() END Capacity;
    END Channel;

PROCEDURE Pack(CONST value: T): Box;
VAR box: Box;
BEGIN NEW(box); box.value := value; RETURN box END Pack;

PROCEDURE Unpack(payload: ANY; VAR value: T);
BEGIN
    ASSERT(payload IS Box);
    value := payload(Box).value
END Unpack;
END CSPChannels.
