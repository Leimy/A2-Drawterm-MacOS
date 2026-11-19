MODULE TerminalExit;
(** A terminal application's main module returned normally. On hosted Linux
    the legacy Reboot shutdown mode runs termination handlers and exits zero. *)
IMPORT Modules;
BEGIN Modules.Shutdown(Modules.Reboot)
END TerminalExit.
