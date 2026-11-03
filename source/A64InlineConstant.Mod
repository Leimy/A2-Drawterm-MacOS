MODULE A64InlineConstant;
IMPORT SYSTEM;
PROCEDURE -Get*(): SIGNED64;
CONST constant = 16;
CODE{SYSTEM.AArch64}
  MOV X0,constant
END Get;
END A64InlineConstant.
