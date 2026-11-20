--  Frontera del planificador con el resto de lenguajes. Cada identificador y
--  cada cambio de estado se comprueba aquí en tiempo de ejecución.
--
--  Hay un modelo del planificador por hart: cada hilo pertenece a un hart
--  (Home) y solo existe en su modelo, y el hilo 0 de cada modelo es el hilo en
--  reposo de ese hart. Cada operación recibe el hart cuyo modelo usa. Así las
--  demostraciones de Scheduler_Core valen tal cual, una vez por hart.
--
--  Concurrencia. Lo compartido entre harts (el hart de cada hilo y qué huecos
--  están usados) solo lo cambian Create y Exit_Thread, y quien las llama tiene
--  el cerrojo global del kernel. Lo heredado de otros harts (el suelo) es de
--  cada hilo y vive en el modelo de su hart. El modelo de cada hart lo usa su hart con el global o con el
--  cerrojo del hart, y otro hart con los dos. Se demuestra (Only_Hart y
--  Shared_View en las postcondiciones) que las operaciones sobre un hart no
--  cambian ni otro modelo ni lo compartido; y cada cuerpo solo lee el modelo
--  de su hart, Started y, como mucho, el Home de hilos de ese hart. Dos
--  llamadas sobre harts distintos, cada una con su derecho, no se pisan: dan
--  lo mismo que una detrás de otra.

pragma Unevaluated_Use_Of_Old (Allow);

with Quantum_Core;
with Scheduler_Core;

package Sched_Gate with
  SPARK_Mode,
  Abstract_State    => State,
  Initializes       => State,
  Initial_Condition => Invariant
is
   use type Scheduler_Core.Model;
   use type Scheduler_Core.Thread_State;
   use type Scheduler_Core.State_Table;
   use type Scheduler_Core.Unit_Table;
   use type Scheduler_Core.Budget_Table;
   use type Scheduler_Core.Priority_Table;
   use type Scheduler_Core.Units;
   use type Scheduler_Core.Priority;
   use type Scheduler_Core.Thread_Id;

   type U64 is mod 2**64 with Size => 64;

   None : constant U64 := U64'Last;

   Status_Ok          : constant U64 := 0;
   Status_Invalid     : constant U64 := 1;
   Status_Wrong_State : constant U64 := 2;
   Status_Already     : constant U64 := 3;
   Status_Declined    : constant U64 := 4;
   --  Hecho, y el hilo en ejecución debería ceder la CPU.
   Status_Yield       : constant U64 := 5;

   State_Code_Free    : constant U64 := 0;
   State_Code_Ready   : constant U64 := 1;
   State_Code_Blocked : constant U64 := 2;

   Last_Id : constant U64 := U64 (Scheduler_Core.Thread_Id'Last);

   Max_Harts : constant := 4;
   type Hart_Id is range 0 .. Max_Harts - 1;
   Last_Hart : constant U64 := U64 (Hart_Id'Last);

   --  El tiempo que llega de fuera nunca puede salirse del modelo.
   function Clamp (D : U64) return Scheduler_Core.Units is
     (if D > U64 (Scheduler_Core.Max_Budget)
      then Scheduler_Core.Max_Budget
      else Scheduler_Core.Units (D));

   function Invariant return Boolean with
     Ghost,
     Global => (Input => State);

   function Is_Started return Boolean with
     Ghost,
     Global => (Input => State);

   type Model_View_Array is array (Hart_Id) of Scheduler_Core.Model with Ghost;

   --  Los modelos de todos los harts.
   function Models_View return Model_View_Array with
     Ghost,
     Global => (Input => State);

   --  Entre Before y After solo pudo cambiar el modelo de H.
   function Only_Hart (Before, After : Model_View_Array; H : Hart_Id) return Boolean is
     (for all G in Hart_Id => (if G /= H then After (G) = Before (G)))
   with Ghost;

   function Home_View (Thread : Scheduler_Core.Thread_Id) return Hart_Id with
     Ghost,
     Global => (Input => State);

   type Home_View_Array is array (Scheduler_Core.Thread_Id) of Hart_Id with Ghost;
   type Used_View_Array is array (Scheduler_Core.Thread_Id) of Boolean with Ghost;

   --  Lo compartido entre harts, que solo cambia con el cerrojo global.
   type Shared_Data is record
      Homes : Home_View_Array;
      Used  : Used_View_Array;
   end record with Ghost;

   function Shared_View return Shared_Data with
     Ghost,
     Global => (Input => State),
     Post   => (for all T in Scheduler_Core.Thread_Id => Shared_View'Result.Homes (T) = Home_View (T));

   --  Resultado de Wake_Remote y Boost: hay que avisar al hart Notify_Base + H.
   Notify_Base : constant U64 := 16#100#;

   --  El hart al que pertenece un hilo, o None.
   function Home_Of (Thread : U64) return U64 with
     Global        => (Input => State),
     Post          => Home_Of'Result = None or else Home_Of'Result <= Last_Hart,
     Export,
     Convention    => C,
     External_Name => "fb_sched_home";

   function Init return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then (if Init'Result = Status_Ok then Is_Started),
     Export,
     Convention    => C,
     External_Name => "fb_sched_init";

   --  Reserva un hilo listo en el hart Hart y devuelve su identificador, o
   --  None. Con el cerrojo global.
   function Create (Hart : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then
         (if Create'Result /= None
          then Hart <= Last_Hart
            and then Create'Result in 1 .. Last_Id
            and then Only_Hart (Models_View'Old, Models_View, Hart_Id (Hart))
            and then
              Models_View (Hart_Id (Hart)).States (Scheduler_Core.Thread_Id (Create'Result))
              = Scheduler_Core.Ready
            --  Un hueco reutilizado no hereda la urgencia de su anterior dueño.
            and then
              Models_View (Hart_Id (Hart)).Floors (Scheduler_Core.Thread_Id (Create'Result)) = 0
            and then
              Scheduler_Core.Level_Of
                (Models_View (Hart_Id (Hart)), Scheduler_Core.Thread_Id (Create'Result))
              = Scheduler_Core.Default_Priority
            and then
              Shared_View.Homes
              = (Shared_View'Old.Homes with delta
                   Scheduler_Core.Thread_Id (Create'Result) => Hart_Id (Hart))
          else Models_View = Models_View'Old and then Shared_View = Shared_View'Old),
     Export,
     Convention    => C,
     External_Name => "fb_sched_create";

   --  Cobra el tiempo gastado, elige el siguiente hilo y lo hace actual.
   --  Devuelve None solo si el planificador no se ha iniciado o el hart no existe.
   function Pick (Hart, Elapsed : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Shared_View = Shared_View'Old
       and then
         (if Is_Started'Old and then Hart <= Last_Hart
          then Pick'Result <= Last_Id
            and then Only_Hart (Models_View'Old, Models_View, Hart_Id (Hart))
            and then
              Scheduler_Core.Scheduled
                (Models_View'Old (Hart_Id (Hart)),
                 Models_View (Hart_Id (Hart)),
                 Clamp (Elapsed),
                 Scheduler_Core.Thread_Id (Pick'Result))
          else Pick'Result = None and then Models_View = Models_View'Old),
     Export,
     Convention    => C,
     External_Name => "fb_sched_pick";

   --  Cobra el tiempo gastado sin elegir a nadie.
   function Charge (Hart, Elapsed : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Shared_View = Shared_View'Old
       and then
         (if Charge'Result = Status_Ok
          then Hart <= Last_Hart
            and then Only_Hart (Models_View'Old, Models_View, Hart_Id (Hart))
            and then
              Scheduler_Core.Charged_Only
                (Models_View'Old (Hart_Id (Hart)), Models_View (Hart_Id (Hart)), Clamp (Elapsed))
          else Models_View = Models_View'Old),
     Export,
     Convention    => C,
     External_Name => "fb_sched_charge";

   --  Cobra, bloquea al hilo actual y despierta a Peer, que recupera su contexto
   --  si lo había prestado. Con Donate /= 0, Peer recibe además el contexto del
   --  hilo actual cuando es posible. Status_Ok: la CPU pasa a Peer.
   --  Status_Declined: Peer tiene a alguien de más prioridad delante, y quien
   --  llama debe pedir a Pick el siguiente hilo.
   function Hand_Off (Hart, Peer, Elapsed, Donate : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Shared_View = Shared_View'Old
       and then
         (if Hand_Off'Result = Status_Ok
             or else Hand_Off'Result = Status_Declined
          then Hart <= Last_Hart
            and then Peer in 1 .. Last_Id
            and then Only_Hart (Models_View'Old, Models_View, Hart_Id (Hart))
            and then
              Scheduler_Core.Handed
                (Models_View'Old (Hart_Id (Hart)),
                 Models_View (Hart_Id (Hart)),
                 Clamp (Elapsed),
                 Scheduler_Core.Thread_Id (Peer),
                 Donate /= 0,
                 Hand_Off'Result = Status_Ok)
          else Models_View = Models_View'Old),
     Export,
     Convention    => C,
     External_Name => "fb_sched_hand_off";

   --  Hand_Off y, en la misma llamada, lo que el kernel pediría justo después
   --  para darle la CPU a Peer: Granted, lo que le queda al contexto con que
   --  correrá, y Donated = 1 si ese contexto es el que pagaba el hilo que
   --  cedió (hubo préstamo). Evita tres llamadas más por cesión, cada una con
   --  sus comprobaciones. Si falla, ninguno de los dos significa nada (0).
   function Hand_Off_Grant
     (Hart, Peer, Elapsed, Donate : U64; Granted, Donated : out U64) return U64
   with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Shared_View = Shared_View'Old
       and then
         (if Hand_Off_Grant'Result = Status_Ok
             or else Hand_Off_Grant'Result = Status_Declined
          then Hart <= Last_Hart
            and then Peer in 1 .. Last_Id
            and then Only_Hart (Models_View'Old, Models_View, Hart_Id (Hart))
            and then
              (declare
                 New_M : constant Scheduler_Core.Model := Models_View (Hart_Id (Hart));
                 Old_M : constant Scheduler_Core.Model := Models_View'Old (Hart_Id (Hart));
                 P     : constant Scheduler_Core.Thread_Id := Scheduler_Core.Thread_Id (Peer);
               begin
                 Scheduler_Core.Handed
                   (Old_M, New_M, Clamp (Elapsed), P, Donate /= 0,
                    Hand_Off_Grant'Result = Status_Ok)
                 and then Granted = U64 (New_M.Remaining (New_M.Ctx (P)))
                 and then
                   Donated
                   = (if New_M.Ctx (P) = Scheduler_Core.Payer (Old_M) then 1 else 0))
          else Models_View = Models_View'Old and then Granted = 0 and then Donated = 0),
     Export,
     Convention    => C,
     External_Name => "fb_sched_hand_off_grant";

   --  El servidor pasa a usar el contexto de Client, que espera su respuesta. Si
   --  ya usaba uno prestado, solo lo cambia por uno de más prioridad.
   --  Status_Wrong_State: no es posible, y nada cambia. Hay que cobrar antes.
   function Adopt_Client (Hart, Server, Client : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Shared_View = Shared_View'Old
       and then
         (if Adopt_Client'Result = Status_Ok
          then Hart <= Last_Hart
            and then Server in 1 .. Last_Id
            and then Client in 1 .. Last_Id
            and then Only_Hart (Models_View'Old, Models_View, Hart_Id (Hart))
            and then
              (declare
                 New_M : constant Scheduler_Core.Model := Models_View (Hart_Id (Hart));
                 Old_M : constant Scheduler_Core.Model := Models_View'Old (Hart_Id (Hart));
               begin
                 New_M.Ctx (Scheduler_Core.Thread_Id (Server))
                 = Old_M.Ctx (Scheduler_Core.Thread_Id (Client))
                 and then New_M.Floors = Old_M.Floors
                 and then New_M.Remaining = Old_M.Remaining
                 and then New_M.Debt = Old_M.Debt
                 and then New_M.Budgets = Old_M.Budgets
                 and then New_M.States = Old_M.States)
          else Models_View = Models_View'Old),
     Export,
     Convention    => C,
     External_Name => "fb_sched_adopt";

   function Block (Hart, Thread : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Shared_View = Shared_View'Old
       and then
         (if Block'Result = Status_Ok
          then Hart <= Last_Hart
            and then Thread in 1 .. Last_Id
            and then Only_Hart (Models_View'Old, Models_View, Hart_Id (Hart))
            and then
              (declare
                 New_M : constant Scheduler_Core.Model := Models_View (Hart_Id (Hart));
                 Old_M : constant Scheduler_Core.Model := Models_View'Old (Hart_Id (Hart));
               begin
                 New_M.States (Scheduler_Core.Thread_Id (Thread)) = Scheduler_Core.Blocked
                 and then New_M.Floors = Old_M.Floors
                 and then New_M.Remaining = Old_M.Remaining
                 and then New_M.Budgets = Old_M.Budgets
                 and then New_M.Debt = Old_M.Debt)
          else Models_View = Models_View'Old),
     Export,
     Convention    => C,
     External_Name => "fb_sched_block";

   --  Despierta a un hilo del hart Hart. Si había prestado su contexto, lo
   --  recupera. Status_Yield: hecho, y el hilo en ejecución ya no es el que
   --  debe correr.
   function Unblock (Hart, Thread : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Shared_View = Shared_View'Old
       and then
         (if Unblock'Result = Status_Ok or else Unblock'Result = Status_Yield
          then Hart <= Last_Hart
            and then Thread in 1 .. Last_Id
            and then Only_Hart (Models_View'Old, Models_View, Hart_Id (Hart))
            and then
              (declare
                 T     : constant Scheduler_Core.Thread_Id := Scheduler_Core.Thread_Id (Thread);
                 New_M : constant Scheduler_Core.Model := Models_View (Hart_Id (Hart));
                 Old_M : constant Scheduler_Core.Model := Models_View'Old (Hart_Id (Hart));
               begin
                 New_M.States (T) = Scheduler_Core.Ready
                 and then New_M.Lent (T) = T
                 and then New_M.Floors = Old_M.Floors
                 and then New_M.Remaining = Old_M.Remaining
                 and then New_M.Budgets = Old_M.Budgets
                 and then New_M.Debt = Old_M.Debt)
          else Models_View = Models_View'Old),
     Export,
     Convention    => C,
     External_Name => "fb_sched_unblock";

   --  Despierta a un hilo en el modelo de su propio hart. Si el despertado
   --  supera al que corre en su hart, o allí corre el hilo 0 (que puede estar
   --  dormido sin tick), devuelve Notify_Base + ese hart: es a quien hay que
   --  avisar, y a nadie más. Si no, Status_Ok, y no hace falta aviso.
   --  Status_Invalid o Status_Wrong_State: nada cambia. Ningún otro modelo
   --  cambia nunca.
   function Wake_Remote (Thread : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Shared_View = Shared_View'Old
       and then
         (if Wake_Remote'Result = Status_Ok or else Wake_Remote'Result >= Notify_Base
          then Thread in 1 .. Last_Id
            and then
              (declare
                 H   : constant Hart_Id := Home_View (Scheduler_Core.Thread_Id (Thread));
                 T   : constant Scheduler_Core.Thread_Id := Scheduler_Core.Thread_Id (Thread);
                 New_M : constant Scheduler_Core.Model := Models_View (H);
                 Old_M : constant Scheduler_Core.Model := Models_View'Old (H);
               begin
                 Only_Hart (Models_View'Old, Models_View, H)
                 and then Old_M.States (T) = Scheduler_Core.Blocked
                 and then New_M.States (T) = Scheduler_Core.Ready
                 and then New_M.Lent (T) = T
                 and then New_M.Floors = Old_M.Floors
                 and then New_M.Remaining = Old_M.Remaining
                 and then New_M.Budgets = Old_M.Budgets
                 and then New_M.Debt = Old_M.Debt
                 and then
                   (if Wake_Remote'Result = Status_Ok
                    then Scheduler_Core.Top_Now (New_M, New_M.Running)
                      and then New_M.Running /= 0
                    else Wake_Remote'Result = Notify_Base + U64 (H)
                      and then (not Scheduler_Core.Top_Now (New_M, New_M.Running)
                                or else New_M.Running = 0)))
          else Models_View = Models_View'Old
            and then Wake_Remote'Result in Status_Invalid | Status_Wrong_State)
       --  Y no falla sin motivo: un hilo bloqueado en su hart siempre despierta.
       and then
         (if Is_Started
            and then Thread in 1 .. Last_Id
            and then
              Models_View'Old (Home_View (Scheduler_Core.Thread_Id (Thread))).States
                (Scheduler_Core.Thread_Id (Thread)) = Scheduler_Core.Blocked
          then Wake_Remote'Result = Status_Ok or else Wake_Remote'Result >= Notify_Base),
     Export,
     Convention    => C,
     External_Name => "fb_sched_wake_remote";

   --  El hilo, que acaba de despertar, pasa a ser el siguiente en turno de su
   --  nivel: si nadie de más prioridad está listo, la próxima decisión es él.
   function Promote (Hart, Thread : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Shared_View = Shared_View'Old
       and then
         (if Promote'Result = Status_Ok
          then Hart <= Last_Hart
            and then Thread <= Last_Id
            and then Only_Hart (Models_View'Old, Models_View, Hart_Id (Hart))
            and then
              (declare
                 T     : constant Scheduler_Core.Thread_Id := Scheduler_Core.Thread_Id (Thread);
                 New_M : constant Scheduler_Core.Model := Models_View (Hart_Id (Hart));
                 Old_M : constant Scheduler_Core.Model := Models_View'Old (Hart_Id (Hart));
               begin
                 New_M.States (T) /= Scheduler_Core.Free
                 and then
                   New_M
                   = (Old_M with delta
                        Cursors =>
                          (Old_M.Cursors with delta
                             Scheduler_Core.Level_Of (Old_M, T) => Scheduler_Core.Before (T))))
          else Models_View = Models_View'Old),
     Export,
     Convention    => C,
     External_Name => "fb_sched_promote";

   --  El hilo termina y su hueco queda libre. Con el cerrojo global.
   function Exit_Thread (Hart, Thread : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then
         (if Exit_Thread'Result = Status_Ok
          then Hart <= Last_Hart
            and then Thread in 1 .. Last_Id
            and then Only_Hart (Models_View'Old, Models_View, Hart_Id (Hart))
            and then
              (declare
                 T     : constant Scheduler_Core.Thread_Id := Scheduler_Core.Thread_Id (Thread);
                 New_M : constant Scheduler_Core.Model := Models_View (Hart_Id (Hart));
                 Old_M : constant Scheduler_Core.Model := Models_View'Old (Hart_Id (Hart));
               begin
                 New_M.States = (Old_M.States with delta T => Scheduler_Core.Free)
                 and then New_M.Remaining = (Old_M.Remaining with delta T => 0)
                 and then New_M.Debt = (Old_M.Debt with delta T => 0)
                 and then New_M.Budgets = Old_M.Budgets
                 and then
                   Shared_View
                   = (Shared_View'Old with delta
                        Used => (Shared_View'Old.Used with delta T => False)))
          else Models_View = Models_View'Old and then Shared_View = Shared_View'Old),
     Export,
     Convention    => C,
     External_Name => "fb_sched_exit";

   --  Fija la prioridad y el presupuesto del contexto de un hilo y le da el
   --  presupuesto entero. Lo heredado no cambia. Puede aumentar lo que esperan
   --  los demás: el kernel solo la usa por sí mismo o con una capability que lo
   --  autorice.
   function Set_Params (Hart, Thread, Level, Budget : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Shared_View = Shared_View'Old
       and then
         (if Set_Params'Result = Status_Ok
          then Hart <= Last_Hart
            and then Thread <= Last_Id
            and then Level < U64 (Scheduler_Core.Levels)
            and then Budget in 1 .. U64 (Scheduler_Core.Max_Budget)
            and then Only_Hart (Models_View'Old, Models_View, Hart_Id (Hart))
            and then
              (declare
                 T     : constant Scheduler_Core.Thread_Id := Scheduler_Core.Thread_Id (Thread);
                 New_M : constant Scheduler_Core.Model := Models_View (Hart_Id (Hart));
                 Old_M : constant Scheduler_Core.Model := Models_View'Old (Hart_Id (Hart));
               begin
                 New_M.Priorities
                 = (Old_M.Priorities with delta T => Scheduler_Core.Priority (Level))
                 and then New_M.Floors = Old_M.Floors
                 and then
                   New_M.Remaining
                   = (Old_M.Remaining with delta T => Scheduler_Core.Units (Budget)))
          else Models_View = Models_View'Old),
     Export,
     Convention    => C,
     External_Name => "fb_sched_set_params";

   --  Herencia de prioridad: el hilo pasa a tener Level como suelo en el modelo
   --  de su hart (None lo quita). El suelo es del hilo: corre al menos con él
   --  use el contexto que use, el suyo o uno prestado por un cliente. Solo
   --  cambia el suelo de ese hilo; su presupuesto, lo que le queda y su deuda
   --  no: hereda la urgencia, no tiempo de CPU. El aviso sigue la regla de
   --  Wake_Remote. Ningún otro modelo cambia. Con el cerrojo global.
   function Boost (Thread, Level : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Shared_View = Shared_View'Old
       and then Is_Started = Is_Started'Old
       and then
         (if Boost'Result = Status_Ok or else Boost'Result >= Notify_Base
          then Thread in 1 .. Last_Id
            and then (Level = None or else Level < U64 (Scheduler_Core.Levels))
            and then
              (declare
                 T     : constant Scheduler_Core.Thread_Id := Scheduler_Core.Thread_Id (Thread);
                 H     : constant Hart_Id := Home_View (T);
                 New_M : constant Scheduler_Core.Model := Models_View (H);
                 Old_M : constant Scheduler_Core.Model := Models_View'Old (H);
                 Floor : constant Scheduler_Core.Priority :=
                   (if Level = None then 0 else Scheduler_Core.Priority (Level));
               begin
                 Only_Hart (Models_View'Old, Models_View, H)
                 and then Old_M.States (T) /= Scheduler_Core.Free
                 and then
                   New_M
                   = (Old_M with delta
                        Floors  => (Old_M.Floors with delta T => Floor),
                        Levels  => New_M.Levels,
                        Members => New_M.Members)
                 --  Actúa sobre el contexto con que corre de verdad.
                 and then
                   Scheduler_Core.Level_Of (New_M, T)
                   = Scheduler_Core.Priority'Max (Old_M.Priorities (Old_M.Ctx (T)), Floor)
                 --  Y solo sobre ese hilo: el nivel de los demás no cambia.
                 and then
                   (for all X in Scheduler_Core.Thread_Id =>
                      (if X /= T
                       then Scheduler_Core.Level_Of (New_M, X)
                            = Scheduler_Core.Level_Of (Old_M, X)))
                 and then
                   (if Boost'Result = Status_Ok
                    then Scheduler_Core.Top_Now (New_M, New_M.Running)
                      and then New_M.Running /= 0
                    else Boost'Result = Notify_Base + U64 (H)
                      and then (not Scheduler_Core.Top_Now (New_M, New_M.Running)
                                or else New_M.Running = 0)))
          else Models_View = Models_View'Old
            and then Boost'Result in Status_Invalid | Status_Wrong_State)
       --  Y no falla sin motivo: un hilo que existe en su hart siempre hereda.
       and then
         (if Is_Started
            and then Thread in 1 .. Last_Id
            and then (Level = None or else Level < U64 (Scheduler_Core.Levels))
            and then
              Models_View'Old (Home_View (Scheduler_Core.Thread_Id (Thread))).States
                (Scheduler_Core.Thread_Id (Thread)) /= Scheduler_Core.Free
          then Boost'Result = Status_Ok or else Boost'Result >= Notify_Base),
     Export,
     Convention    => C,
     External_Name => "fb_sched_boost";

   --  Suelo de un hilo en el modelo de su hart, o None si no existe. Nunca
   --  supera la prioridad con que corre.
   function Floor_Of (Thread : U64) return U64 with
     Global        => (Input => State),
     Pre           => Invariant,
     Post          =>
       (if Is_Started
          and then Thread in 1 .. Last_Id
          and then Models_View (Home_View (Scheduler_Core.Thread_Id (Thread))).States
                     (Scheduler_Core.Thread_Id (Thread)) /= Scheduler_Core.Free
        then Floor_Of'Result
             = U64 (Models_View (Home_View (Scheduler_Core.Thread_Id (Thread))).Floors
                      (Scheduler_Core.Thread_Id (Thread)))
          and then Floor_Of'Result
                   <= U64 (Scheduler_Core.Level_Of
                             (Models_View (Home_View (Scheduler_Core.Thread_Id (Thread))),
                              Scheduler_Core.Thread_Id (Thread)))
        else Floor_Of'Result = None),
     Export,
     Convention    => C,
     External_Name => "fb_sched_floor_of";

   --  1 si el hilo hereda un suelo distinto de 0 en el modelo de su hart, 0
   --  si no (o si no existe). La consulta mínima del camino rápido del IPC.
   function Has_Floor (Thread : U64) return U64 with
     Global        => (Input => State),
     Pre           => Invariant,
     Post          =>
       Has_Floor'Result
       = (if Floor_Of (Thread) /= None and then Floor_Of (Thread) /= 0 then 1 else 0),
     Export,
     Convention    => C,
     External_Name => "fb_sched_has_floor";

   --  Prioridad efectiva con que corre un hilo (la de su contexto, y al menos
   --  su suelo) en el modelo de su hart. None si no existe.
   function Priority_Of (Thread : U64) return U64 with
     Global        => (Input => State),
     Post          =>
       (if Thread in 1 .. Last_Id
          and then Models_View (Home_View (Scheduler_Core.Thread_Id (Thread))).States
                     (Scheduler_Core.Thread_Id (Thread)) /= Scheduler_Core.Free
        then Priority_Of'Result
             = U64 (Scheduler_Core.Level_Of
                      (Models_View (Home_View (Scheduler_Core.Thread_Id (Thread))),
                       Scheduler_Core.Thread_Id (Thread)))
        else Priority_Of'Result = None),
     Export,
     Convention    => C,
     External_Name => "fb_sched_priority_of";

   --  Estado de un hilo en el modelo de Hart, o None si no existe.
   function State_Of (Hart, Thread : U64) return U64 with
     Global        => (Input => State),
     Export,
     Convention    => C,
     External_Name => "fb_sched_state";

   --  Presupuesto que le queda al contexto con que corre un hilo, o None.
   function Remaining_Of (Hart, Thread : U64) return U64 with
     Global        => (Input => State),
     Export,
     Convention    => C,
     External_Name => "fb_sched_remaining";

   --  La rodaja para un hilo (Quantum_Core.Slice_For con el resto y el
   --  presupuesto de su contexto), en una sola llamada. 0 si no es válido.
   function Slice_Of (Hart, Thread, Quantum, Estimate : U64) return U64 with
     Global        => (Input => State),
     Post          =>
       (if Hart <= Last_Hart and then Thread <= Last_Id
        then
          (declare
             M : constant Scheduler_Core.Model := Models_View (Hart_Id (Hart));
             C : constant Scheduler_Core.Thread_Id := M.Ctx (Scheduler_Core.Thread_Id (Thread));
           begin
             Slice_Of'Result
             = U64 (Quantum_Core.Slice_For
                      (Quantum_Core.U64 (M.Remaining (C)),
                       Quantum_Core.U64 (M.Budgets (C)),
                       Quantum_Core.U64 (Quantum),
                       Quantum_Core.U64 (Estimate))))
        else Slice_Of'Result = 0),
     Export,
     Convention    => C,
     External_Name => "fb_sched_slice";

   --  Presupuesto entero del contexto con que corre un hilo, o None.
   function Budget_Of (Hart, Thread : U64) return U64 with
     Global        => (Input => State),
     Export,
     Convention    => C,
     External_Name => "fb_sched_budget";

   --  Contexto con que corre un hilo (él mismo si no lo tiene prestado), o None.
   function Context_Of (Hart, Thread : U64) return U64 with
     Global        => (Input => State),
     Export,
     Convention    => C,
     External_Name => "fb_sched_context";

   --  1 si el hilo en ejecución en Hart debería ceder la CPU: no es elegible o
   --  hay un elegible de más prioridad.
   function Should_Yield (Hart : U64) return U64 with
     Global        => (Input => State),
     Pre           => Invariant,
     Export,
     Convention    => C,
     External_Name => "fb_sched_should_yield";

   --  1 si en Hart no hay ningún hilo listo aparte del que corre: el hilo en
   --  reposo puede dormir sin tick hasta que le avisen.
   function Alone (Hart : U64) return U64 with
     Global        => (Input => State),
     Post          =>
       (if Alone'Result = 1
        then Is_Started
          and then Hart <= Last_Hart
          and then
            (declare
               M : constant Scheduler_Core.Model := Models_View (Hart_Id (Hart));
             begin
               (for all T in Scheduler_Core.Thread_Id =>
                  (if T /= M.Running then M.States (T) /= Scheduler_Core.Ready)))
        else Alone'Result = 0),
     Export,
     Convention    => C,
     External_Name => "fb_sched_alone";

   --  El hilo que corre en Hart, o None si el hart no existe.
   function Running (Hart : U64) return U64 with
     Global        => (Input => State),
     Export,
     Convention    => C,
     External_Name => "fb_sched_running";

end Sched_Gate;
