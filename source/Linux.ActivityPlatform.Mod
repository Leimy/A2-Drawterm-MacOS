MODULE ActivityPlatform;
IMPORT Glue;
PROCEDURE Open*(): ADDRESS;
BEGIN RETURN Glue.dlopen(ADDRESSOF("$ORIGIN/libA2Activities.so"), 2) END Open;
END ActivityPlatform.
