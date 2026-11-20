--  Herencia de prioridad: la regla que une el IPC con el planificador.
--
--  La regla: un servidor corre al menos con la urgencia de cada cliente que
--  espera su respuesta, en curso o aplazada (Inherits). El nivel de un hilo
--  vive en el modelo de su hart (Sched_Gate.Priority_Of) y a quién espera, en
--  Ipc_Core (Awaited). Aquí se demuestra:
--
--  * Refresh deja el suelo del servidor en exactamente lo que pide la regla
--    (Is_Needed: el mayor nivel de sus clientes, 0 si no tiene) y con ello la
--    cumple para ese servidor, sin cambiar el nivel de ningún otro hilo.
--  * Refresh_Chain la deja cumplida en toda la cadena que empieza en un
--    servidor: cada eslabón se recalcula con el nivel ya nuevo de su cliente.
--  * Holds dice si se cumple para todos los servidores (la comprobación de
--    Debug es esta misma regla, no una copia).
--
--  Concurrencia: lee los modelos de varios harts, así que se llama con el
--  cerrojo global y los de todos los harts (kernel_lock.enterAllHarts).

pragma Unevaluated_Use_Of_Old (Allow);

with Ipc_Core;
with Sched_Gate;
with Scheduler_Core;

package Inherit_Gate with
  SPARK_Mode
is
   use type Ipc_Core.U64;
   use type Ipc_Core.Thread_Slot;
   use type Ipc_Core.Thread_Link;
   use type Sched_Gate.U64;
   use type Sched_Gate.Shared_Data;
   use type Sched_Gate.Model_View_Array;

   subtype U64 is Sched_Gate.U64;
   subtype Thread_Id is Ipc_Core.Thread_Id;
   subtype Chain_Steps is Ipc_Core.Chain_Steps;

   None        : constant U64 := Sched_Gate.None;
   Status_Ok   : constant U64 := Sched_Gate.Status_Ok;
   --  El servidor no existe en el planificador o no es un hilo válido.
   Status_Invalid : constant U64 := Sched_Gate.Status_Invalid;
   --  La cadena no acabó en Max_Threads pasos (imposible si Acyclic).
   Status_Cycle   : constant U64 := 6;

   --  Nivel con que corre T, o None si no existe.
   function Level (T : Thread_Id) return U64 is
     (Sched_Gate.Priority_Of (U64 (T)))
   with Ghost, Global => (Input => Sched_Gate.State);

   type Level_Array is array (Thread_Id) of U64 with Ghost;

   function All_Levels return Level_Array is
     (for T in Thread_Id => Level (T))
   with Ghost, Global => (Input => Sched_Gate.State);

   --  C espera la respuesta de S.
   function Waits (C, S : Thread_Id) return Boolean is
     (Ipc_Core.Awaited (C) = Ipc_Core.Thread_Slot (S))
   with Ghost, Global => (Input => Ipc_Core.State);

   --  La regla para el servidor S, con los niveles de A.
   function Inherits_With (A : Level_Array; S : Thread_Id) return Boolean is
     (for all C in Thread_Id =>
        (if Waits (C, S) and then A (C) /= None
         then A (S) /= None and then A (S) >= A (C)))
   with Ghost, Global => (Input => Ipc_Core.State);

   --  La regla para el servidor S.
   function Inherits (S : Thread_Id) return Boolean is
     (Inherits_With (All_Levels, S))
   with Ghost, Global => (Input => (Ipc_Core.State, Sched_Gate.State));

   --  L es el mayor nivel de los clientes de S, o 0 si no tiene ninguno.
   function Is_Needed (S : Thread_Id; L : U64) return Boolean is
     ((for all C in Thread_Id =>
         (if Waits (C, S) and then Level (C) /= None then Level (C) <= L))
      and then
        (L = 0
         or else (for some C in Thread_Id => Waits (C, S) and then Level (C) = L)))
   with Ghost, Global => (Input => (Ipc_Core.State, Sched_Gate.State));

   --  Un eslabón de la cadena que empieza en S.
   function Link (S : Thread_Id; K : Chain_Steps) return Ipc_Core.Thread_Slot is
     (Ipc_Core.Iter (Ipc_Core.Awaited, Ipc_Core.Thread_Slot (S), K))
   with Ghost, Global => (Input => Ipc_Core.State);

   --  Recalcula el suelo de Server con todos sus clientes, de cualquier hart.
   --  Devuelve Status_Ok, Notify_Base + H si hay que avisar al hart H (la
   --  regla de Boost), o Status_Invalid sin tocar nada.
   function Refresh (Server : U64) return U64 with
     Side_Effects,
     Global => (Input => Ipc_Core.State, In_Out => Sched_Gate.State),
     Pre    => Sched_Gate.Invariant and then Ipc_Core.Invariant,
     Post   =>
       Sched_Gate.Invariant
       and then Sched_Gate.Shared_View = Sched_Gate.Shared_View'Old
       and then Sched_Gate.Is_Started = Sched_Gate.Is_Started'Old
       and then
         (if Refresh'Result = Status_Ok or else Refresh'Result >= Sched_Gate.Notify_Base
          then Server in 1 .. U64 (Thread_Id'Last)
            and then Inherits (Thread_Id (Server))
            and then Is_Needed (Thread_Id (Server), Sched_Gate.Floor_Of (Server))
            and then
              (for all T in Thread_Id =>
                 (if U64 (T) /= Server then All_Levels (T) = All_Levels'Old (T)))
          else Refresh'Result = Status_Invalid
            and then Sched_Gate.Models_View = Sched_Gate.Models_View'Old)
       --  Y no falla sin motivo: un hilo que existe siempre se recalcula.
       and then
         (if Sched_Gate.Is_Started'Old
            and then Server in 1 .. U64 (Thread_Id'Last)
            and then Sched_Gate.Priority_Of (Server)'Old /= None
          then Refresh'Result = Status_Ok or else Refresh'Result >= Sched_Gate.Notify_Base),
     Export,
     Convention    => C,
     External_Name => "fb_inherit_refresh";

   --  Recalcula, de arriba abajo, toda la cadena que empieza en Server.
   --  Notify lleva un bit por hart al que hay que avisar.
   function Refresh_Chain (Server : U64; Notify : out U64) return U64 with
     Side_Effects,
     Global => (Input => Ipc_Core.State, In_Out => Sched_Gate.State),
     Pre    => Sched_Gate.Invariant and then Ipc_Core.Invariant,
     Post   =>
       Sched_Gate.Invariant
       and then Sched_Gate.Shared_View = Sched_Gate.Shared_View'Old
       and then
         (if Refresh_Chain'Result = Status_Ok
          then Server <= U64 (Thread_Id'Last)
            and then
              (Server = 0
               or else
                 (for all K in Chain_Steps =>
                    (if Link (Thread_Id (Server), K) /= 0
                     then Inherits (Link (Thread_Id (Server), K)))))),
     Export,
     Convention    => C,
     External_Name => "fb_inherit_refresh_chain";

   --  1 si la regla se cumple para todos los servidores, 0 si no.
   function Holds return U64 with
     Global => (Input => (Ipc_Core.State, Sched_Gate.State)),
     Pre    => Ipc_Core.Invariant,
     Post   => (Holds'Result = 1) = (for all S in Thread_Id => Inherits (S)),
     Export,
     Convention    => C,
     External_Name => "fb_inherit_holds";

end Inherit_Gate;
