MODULE ActivityPlatform;
IMPORT Glue;
PROCEDURE Open*(): ADDRESS;
BEGIN RETURN Glue.dlopen(ADDRESSOF("@executable_path/libA2Activities.dylib"), 2) END Open;
END ActivityPlatform.
