MODULE CSPGenericPeer;
(** Independently compiled client of the same generic integer-channel instance. *)
IMPORT CSP, Numbers := CSPChannels(SIGNED64);
PROCEDURE Send*(channel: Numbers.Channel; value: SIGNED64): SIGNED32;
BEGIN RETURN channel.Send(value, NIL) END Send;
PROCEDURE Create*(capacity: SIZE): Numbers.Channel;
VAR channel: Numbers.Channel;
BEGIN NEW(channel, capacity); RETURN channel END Create;
PROCEDURE IsChannel*(value: ANY): BOOLEAN;
BEGIN RETURN value IS Numbers.Channel END IsChannel;
END CSPGenericPeer.
