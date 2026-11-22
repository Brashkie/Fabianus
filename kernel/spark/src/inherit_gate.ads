--  SPDX-License-Identifier: GPL-3.0-or-later
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
--  * Call_Wake (llamar y heredar) y Reply_Wake (responder y heredar) hacen
--    en una pasada lo que el IPC entre harts necesita al llamar y al
--    contestar: despertar al otro extremo y dejar el suelo del servidor en
--    lo que pide la regla. Además conservan la regla en todos los demás
--    hilos (Kept): quien la cumplía la sigue cumpliendo.
--
--  Concurrencia: lee los modelos de varios harts, así que se llama con el
--  cerrojo global y los de todos los harts (kernel_lock.enterHarts). Call_Wake
--  y Reply_Wake reciben en Held los harts cuyos cerrojos se tienen y
--  comprueban ellas mismas que bastan (Covers: los del servidor, sus clientes
--  y el cliente que despierta); si no, no tocan nada y devuelven
--  Status_Unheld.

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
   use type Sched_Gate.Hart_Id;
   use type Scheduler_Core.Model;
   use type Scheduler_Core.Thread_State;

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

   --  El bit del hart H en una máscara de harts.
   function Hart_Bit (H : Sched_Gate.Hart_Id) return U64 is
     (case H is
        when 0 => 1,
        when 1 => 2,
        when 2 => 4,
        when 3 => 8);

   function In_Held (Held : U64; H : Sched_Gate.Hart_Id) return Boolean is
     ((Held and Hart_Bit (H)) /= 0);

   --  El hart de un hilo.
   function Home (T : Thread_Id) return Sched_Gate.Hart_Id is
     (Sched_Gate.Home_View (Scheduler_Core.Thread_Id (T)))
   with Ghost, Global => (Input => Sched_Gate.State);

   --  Los cerrojos de Held bastan para recalcular el suelo de S: tiene los
   --  harts de S y de todos sus clientes, los únicos modelos que se leen.
   function Covers (Held : U64; S : Thread_Id) return Boolean is
     (In_Held (Held, Home (S))
      and then (for all C in Thread_Id => (if Waits (C, S) then In_Held (Held, Home (C)))))
   with Ghost, Global => (Input => (Ipc_Core.State, Sched_Gate.State));

   --  Nadie que cumpliera la regla con los niveles de Old_A deja de cumplirla.
   function Kept (Old_A : Level_Array) return Boolean is
     (for all X in Thread_Id => (if Inherits_With (Old_A, X) then Inherits (X)))
   with Ghost, Global => (Input => (Ipc_Core.State, Sched_Gate.State));

   --  Faltan cerrojos: un cliente o el servidor viven en un hart fuera de
   --  Held. No se ha tocado nada; hay que repetir con más.
   Status_Unheld : constant U64 := 7;

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

   --  Llamar y heredar. Server, bloqueado esperando peticiones, acaba de
   --  recibir una llamada (Ipc_Core ya enlazó al cliente). En una pasada y con
   --  solo los cerrojos de Held: su suelo pasa a ser exactamente el mayor nivel
   --  de sus clientes y despierta en el modelo de su hart. Devuelve Status_Ok o
   --  Notify_Base + su hart (la regla de Wake_Remote). La regla queda cumplida
   --  para el servidor y se conserva para todos los demás.
   function Call_Wake (Server, Held : U64) return U64 with
     Side_Effects,
     Global => (Input => Ipc_Core.State, In_Out => Sched_Gate.State),
     Pre    => Sched_Gate.Invariant and then Ipc_Core.Invariant,
     Post   =>
       Sched_Gate.Invariant
       and then Sched_Gate.Shared_View = Sched_Gate.Shared_View'Old
       and then Sched_Gate.Is_Started = Sched_Gate.Is_Started'Old
       and then
         (if Call_Wake'Result = Status_Ok or else Call_Wake'Result >= Sched_Gate.Notify_Base
          then Server in 1 .. U64 (Thread_Id'Last)
            and then Ipc_Core.Awaited (Thread_Id (Server)) = 0
            and then Covers (Held, Thread_Id (Server))
            and then Inherits (Thread_Id (Server))
            and then Is_Needed (Thread_Id (Server), Sched_Gate.Floor_Of (Server))
            and then Kept (All_Levels'Old)
            and then
              (declare
                 T : constant Scheduler_Core.Thread_Id := Scheduler_Core.Thread_Id (Server);
                 H : constant Sched_Gate.Hart_Id := Home (Thread_Id (Server));
               begin
                 Sched_Gate.Only_Hart (Sched_Gate.Models_View'Old, Sched_Gate.Models_View, H)
                 and then Sched_Gate.Models_View'Old (H).States (T) = Scheduler_Core.Blocked
                 and then Sched_Gate.Models_View (H).States (T) = Scheduler_Core.Ready
                 and then
                   (Call_Wake'Result = Status_Ok
                    or else Call_Wake'Result = Sched_Gate.Notify_Base + U64 (H)))
          else Sched_Gate.Models_View = Sched_Gate.Models_View'Old
            and then Call_Wake'Result in Status_Invalid | Sched_Gate.Status_Wrong_State | Status_Unheld)
       --  Y no falla sin motivo.
       and then
         (if Sched_Gate.Is_Started
            and then Server in 1 .. U64 (Thread_Id'Last)
            and then Ipc_Core.Awaited (Thread_Id (Server)) = 0
            and then Covers (Held, Thread_Id (Server))
            and then
              Sched_Gate.Models_View'Old (Home (Thread_Id (Server))).States
                (Scheduler_Core.Thread_Id (Server)) = Scheduler_Core.Blocked
            and then
              Scheduler_Core.Quiet
                (Sched_Gate.Models_View'Old (Home (Thread_Id (Server))),
                 Scheduler_Core.Thread_Id (Server))
          then Call_Wake'Result = Status_Ok or else Call_Wake'Result >= Sched_Gate.Notify_Base),
     Export,
     Convention    => C,
     External_Name => "fb_inherit_call_wake";

   --  Responder y heredar. Server acaba de contestar a Client (Ipc_Core ya
   --  quitó el enlace), que espera bloqueado. En una pasada y con solo los
   --  cerrojos de Held: Client despierta en el modelo de su hart y el suelo de
   --  Server pasa a ser exactamente el mayor nivel de los clientes que le
   --  quedan. Notify lleva un bit por hart al que hay que avisar. La regla
   --  queda cumplida para el servidor y se conserva para todos los demás.
   function Reply_Wake (Server, Client, Held : U64; Notify : out U64) return U64 with
     Side_Effects,
     Global => (Input => Ipc_Core.State, In_Out => Sched_Gate.State),
     Pre    => Sched_Gate.Invariant and then Ipc_Core.Invariant,
     Post   =>
       Sched_Gate.Invariant
       and then Sched_Gate.Shared_View = Sched_Gate.Shared_View'Old
       and then Sched_Gate.Is_Started = Sched_Gate.Is_Started'Old
       and then
         (if Reply_Wake'Result = Status_Ok
          then Server in 1 .. U64 (Thread_Id'Last)
            and then Client in 1 .. U64 (Thread_Id'Last)
            and then Server /= Client
            and then Ipc_Core.Awaited (Thread_Id (Server)) = 0
            and then Ipc_Core.Awaited (Thread_Id (Client)) = 0
            and then Covers (Held, Thread_Id (Server))
            and then In_Held (Held, Home (Thread_Id (Client)))
            and then Inherits (Thread_Id (Server))
            and then Is_Needed (Thread_Id (Server), Sched_Gate.Floor_Of (Server))
            and then Kept (All_Levels'Old)
            and then
              (declare
                 T : constant Scheduler_Core.Thread_Id := Scheduler_Core.Thread_Id (Client);
                 H : constant Sched_Gate.Hart_Id := Home (Thread_Id (Client));
               begin
                 Sched_Gate.Models_View'Old (H).States (T) = Scheduler_Core.Blocked
                 and then Sched_Gate.Models_View (H).States (T) = Scheduler_Core.Ready)
            --  Solo cambian los modelos de los harts del cliente y del servidor.
            and then
              (for all G in Sched_Gate.Hart_Id =>
                 (if G /= Home (Thread_Id (Server)) and then G /= Home (Thread_Id (Client))
                  then Sched_Gate.Models_View (G) = Sched_Gate.Models_View'Old (G)))
          else Sched_Gate.Models_View = Sched_Gate.Models_View'Old
            and then Notify = 0
            and then Reply_Wake'Result in Status_Invalid | Sched_Gate.Status_Wrong_State | Status_Unheld),
     Export,
     Convention    => C,
     External_Name => "fb_inherit_reply_wake";

   --  1 si la regla se cumple para todos los servidores, 0 si no.
   function Holds return U64 with
     Global => (Input => (Ipc_Core.State, Sched_Gate.State)),
     Pre    => Ipc_Core.Invariant,
     Post   => (Holds'Result = 1) = (for all S in Thread_Id => Inherits (S)),
     Export,
     Convention    => C,
     External_Name => "fb_inherit_holds";

end Inherit_Gate;
