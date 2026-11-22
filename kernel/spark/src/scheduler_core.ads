--  SPDX-License-Identifier: GPL-3.0-or-later
--  Núcleo demostrado del planificador: prioridad estricta con presupuestos y
--  donación del contexto de planificación.
--
--  Cada hilo tiene un contexto propio: prioridad, presupuesto de CPU en unidades
--  de tiempo, lo que le queda y su deuda. Normalmente corre con el suyo. En una
--  llamada, el cliente presta su contexto al servidor hasta la respuesta: el
--  servidor corre con la prioridad del cliente y su tiempo se cobra al cliente.
--  Quien presta está bloqueado. Los préstamos se encadenan: si el servidor B,
--  que trabaja con el contexto de A, llama a C, C pasa a trabajar con el
--  contexto de A. Cada usuario tiene una profundidad en la cadena; el contexto
--  lo usa el más profundo y los demás están bloqueados, así que cada contexto
--  tiene a lo sumo un usuario listo. Al responder, el contexto vuelve al
--  anterior de la cadena.
--
--
--  Un servidor que aplaza una respuesta conserva el contexto prestado. Si
--  recibe la llamada de alguien con más prioridad que el dueño de ese
--  contexto, devuelve el que tenía y toma el del nuevo cliente, así que corre
--  con el contexto del cliente más urgente que le haya llegado.
--
--  Además cada hilo tiene un suelo (Floors): la urgencia que hereda y que no
--  viaja con ningún contexto, como la de un cliente de otro hart. El suelo es
--  del hilo, no del contexto: el hilo corre al menos con él, use el contexto
--  que use. Solo lo cambia Set_Floor; ninguna otra operación lo toca.
--
--  Un hilo es elegible si está listo y a su contexto le queda presupuesto.
--  Schedule elige siempre un elegible del nivel más alto, en turno circular
--  dentro del nivel. Solo cuando ninguno es elegible se rellenan todos. El
--  tiempo se cobra entero: lo que no cabe en el presupuesto queda como deuda y
--  se descuenta del siguiente relleno.
--
--  El teorema de no inanición es una función de rango por contexto.
--  Wait_Bound (M, S) es un natural, y cada unidad de CPU que se cobra a otro
--  contexto lo hace bajar en una unidad. El tiempo cobrado al propio S lo usa
--  su dueño o un servidor que trabaja con S: no es espera de S, aunque un
--  servidor que aplazó su respuesta puede gastarlo en otros clientes. Bloquear, despertar, prestar y terminar no aumentan la cota; crear
--  hilos y cambiar parámetros sí, y por eso esas operaciones exigen autoridad.

package Scheduler_Core with
  SPARK_Mode,
  Preelaborate
is
   Max_Threads    : constant := 8;
   Levels         : constant := 4;
   Max_Budget     : constant := 1_000_000_000;
   Default_Budget : constant := 100_000;

   type Thread_Id is range 0 .. Max_Threads - 1;
   type Thread_State is (Free, Ready, Blocked);
   type State_Table is array (Thread_Id) of Thread_State;

   type Priority is range 0 .. Levels - 1;
   Default_Priority : constant Priority := 1;

   type Units is range 0 .. Max_Budget;
   subtype Budget_Value is Units range 1 .. Units'Last;
   type Work is range 0 .. 2 * Max_Threads * Max_Budget;

   type Priority_Table is array (Thread_Id) of Priority;
   type Budget_Table is array (Thread_Id) of Budget_Value;
   type Unit_Table is array (Thread_Id) of Units;
   type Cursor_Table is array (Priority) of Thread_Id;
   type Link_Table is array (Thread_Id) of Thread_Id;

   --  Profundidad de cada usuario en la cadena de préstamos: 0 para quien usa
   --  su propio contexto.
   type Depth_Value is range 0 .. Max_Threads - 1;
   type Depth_Table is array (Thread_Id) of Depth_Value;
   Max_Depth : constant Depth_Value := Depth_Value'Last;

   --  Conjuntos de hilos, para decidir sin recorrer las tablas.
   type Mask is mod 2**8;
   type Member_Table is array (Priority) of Mask;

   Bits : constant array (Thread_Id) of Mask := (1, 2, 4, 8, 16, 32, 64, 128);

   function Has (X : Mask; T : Thread_Id) return Boolean is
     ((X and Bits (T)) /= 0);

   --  Las tablas de prioridad, presupuesto, resto y deuda están indexadas por
   --  contexto: el contexto de un hilo se identifica con su dueño. Floors está
   --  indexada por hilo.
   type Model is record
      States       : State_Table;
      Priorities   : Priority_Table;
      Floors       : Priority_Table;
      Levels       : Priority_Table;
      Budgets      : Budget_Table;
      Remaining    : Unit_Table;
      Cursors      : Cursor_Table;
      Running      : Thread_Id;
      Eligible_Set : Mask;
      Members      : Member_Table;
      Debt         : Unit_Table;
      Ctx          : Link_Table;
      Lent         : Link_Table;
      Depth        : Depth_Table;
   end record;

   subtype Step is Integer range 0 .. Max_Threads - 1;

   function Successor (From : Thread_Id; K : Step) return Thread_Id is
     (Thread_Id ((Integer (From) + 1 + K) mod Max_Threads));

   function Distance (From, To : Thread_Id) return Step is
     ((Integer (To) - Integer (From) - 1) mod Max_Threads)
   with Ghost;

   --  Prioridad efectiva: la del contexto con que corre el hilo, y nunca menos
   --  que su suelo.
   function Effective (M : Model; T : Thread_Id) return Priority is
     (Priority'Max (M.Priorities (M.Ctx (T)), M.Floors (T)));

   --  La prioridad efectiva guardada. Valid exige que coincida con Effective
   --  (Levels_Ok): cada decisión del planificador la lee en vez de calcularla,
   --  y solo se recalcula donde cambia un contexto, una prioridad o un suelo.
   function Level_Of (M : Model; T : Thread_Id) return Priority is
     (M.Levels (T));

   function Levels_Ok (M : Model) return Boolean is
     (for all T in Thread_Id => M.Levels (T) = Effective (M, T));

   function Eligible (M : Model; T : Thread_Id) return Boolean is
     (M.States (T) = Ready and then M.Remaining (M.Ctx (T)) > 0);

   function Coherent (M : Model) return Boolean is
     (for all T in Thread_Id => Has (M.Eligible_Set, T) = Eligible (M, T));

   function Coherent_Except (M : Model; X : Thread_Id) return Boolean is
     (for all T in Thread_Id =>
        (if T /= X then Has (M.Eligible_Set, T) = Eligible (M, T)));

   function Members_Ok (M : Model) return Boolean is
     (for all L in Priority =>
        (for all T in Thread_Id =>
           Has (M.Members (L), T) = (Level_Of (M, T) = L)));

   function Members_Ok_Except (M : Model; X : Thread_Id) return Boolean is
     (for all L in Priority =>
        (for all T in Thread_Id =>
           (if T /= X then Has (M.Members (L), T) = (Level_Of (M, T) = L))));

   --  Préstamos: Lent (A) es el usuario más profundo del contexto de A, el
   --  único que puede estar listo; Ctx (U) = A para todos sus usuarios. El
   --  dueño está bloqueado y usa su propio contexto; un usuario no presta el
   --  suyo; los usuarios que no son el último están bloqueados y tienen menos
   --  profundidad que él.
   function Links_Ok (M : Model) return Boolean is
     ((for all T in Thread_Id =>
         (if M.Ctx (T) /= T
          then M.Ctx (M.Ctx (T)) = M.Ctx (T)
            and then M.States (M.Ctx (T)) = Blocked
            and then M.Lent (M.Ctx (T)) /= M.Ctx (T)
            and then M.Ctx (M.Lent (M.Ctx (T))) = M.Ctx (T)
            and then M.Lent (T) = T
            and then M.States (T) /= Free
            and then M.Depth (T) >= 1
            and then M.Depth (T) <= M.Depth (M.Lent (M.Ctx (T)))
            and then
              (if T /= M.Lent (M.Ctx (T))
               then M.States (T) = Blocked
                 and then M.Depth (T) < M.Depth (M.Lent (M.Ctx (T))))
          else M.Depth (T) = 0))
      and then
        (for all T in Thread_Id =>
           (if M.Lent (T) /= T
            then M.Ctx (M.Lent (T)) = T and then M.Ctx (T) = T)));

   --  El hilo 0 siempre está listo, así que siempre hay a quién elegir.
   function Valid (M : Model) return Boolean is
     (Coherent (M)
      and then Levels_Ok (M)
      and then Members_Ok (M)
      and then Links_Ok (M)
      and then M.States (0) = Ready
      and then (for all T in Thread_Id => M.Remaining (T) <= M.Budgets (T))
      and then
        (for all T in Thread_Id =>
           (if M.States (T) = Free then M.Remaining (T) = 0)));

   --  El contexto al que se cobra el tiempo del hilo en ejecución.
   function Payer (B : Model) return Thread_Id is (B.Ctx (B.Running));

   --  Lo que se descuenta del presupuesto: el tiempo gastado, sin pasar de cero.
   function Spent (B : Model; D : Units) return Units is
     (Units'Min (B.Remaining (Payer (B)), D));

   function Charged (B : Model; D : Units) return Unit_Table is
     (B.Remaining with delta Payer (B) => B.Remaining (Payer (B)) - Spent (B, D));

   --  Lo que no cupo en el presupuesto pasa a la deuda, con un tope.
   function Indebted (B : Model; D : Units) return Unit_Table is
     (B.Debt with delta Payer (B) =>
        Units (Work'Min (Work (B.Debt (Payer (B))) + Work (D - Spent (B, D)),
                         Max_Budget)));

   function Charged_Model (B : Model; D : Units) return Model is
     (B with delta Remaining => Charged (B, D), Debt => Indebted (B, D));

   function Any_Eligible (M : Model) return Boolean is
     (for some T in Thread_Id => Eligible (M, T));

   --  Cuánta deuda se paga al rellenar. Siempre queda al menos una unidad, para
   --  que un contexto endeudado siga pudiendo usarse.
   function Repayment (M : Model; T : Thread_Id) return Units is
     (Units'Min (M.Debt (T), M.Budgets (T) - 1));

   function Refilled (M : Model) return Unit_Table is
     (for T in Thread_Id =>
        (if M.States (T) = Free then 0 else M.Budgets (T) - Repayment (M, T)));

   function Repaid (M : Model) return Unit_Table is
     (for T in Thread_Id =>
        (if M.States (T) = Free then M.Debt (T)
         else M.Debt (T) - Repayment (M, T)));

   --  X es elegible y nadie elegible tiene más prioridad.
   function Is_Top (M : Model; X : Thread_Id) return Boolean is
     (Eligible (M, X)
      and then
        (for all T in Thread_Id =>
           (if Eligible (M, T) then Level_Of (M, T) <= Level_Of (M, X))));

   --  Next es el siguiente en turno de su nivel, y el turno avanza.
   function In_Turn
     (Cursor : Thread_Id; A : Model; Next : Thread_Id) return Boolean
   is
     ((for all T in Thread_Id =>
         (if Eligible (A, T) and then Level_Of (A, T) = Level_Of (A, Next)
          then Distance (Cursor, Next) <= Distance (Cursor, T)))
      and then
        (for all T in Thread_Id =>
           (if Eligible (A, T)
              and then Level_Of (A, T) = Level_Of (A, Next)
              and then T /= Next
            then Distance (Next, T) < Distance (Cursor, T))))
   with Ghost;

   --  La especificación completa de una decisión del planificador.
   function Scheduled
     (B : Model; A : Model; D : Units; Next : Thread_Id) return Boolean
   is
     (A.States = B.States
      and then A.Priorities = B.Priorities
      and then A.Floors = B.Floors
      and then A.Budgets = B.Budgets
      and then A.Ctx = B.Ctx
      and then A.Lent = B.Lent
      and then
        A.Remaining
        = (if Any_Eligible (Charged_Model (B, D))
           then Charged (B, D)
           else Refilled (Charged_Model (B, D)))
      and then
        A.Debt
        = (if Any_Eligible (Charged_Model (B, D))
           then Indebted (B, D)
           else Repaid (Charged_Model (B, D)))
      and then A.Running = Next
      and then Is_Top (A, Next)
      and then In_Turn (B.Cursors (Level_Of (A, Next)), A, Next)
      and then
        A.Cursors = (B.Cursors with delta Level_Of (A, Next) => Next))
   with Ghost;

   procedure Schedule (M : in out Model; D : Units; Next : out Thread_Id) with
     Pre  => Valid (M),
     Post => Valid (M) and then Scheduled (M'Old, M, D, Next);

   --  Cobra el tiempo al contexto del hilo en ejecución, sin elegir a nadie.
   function Charged_Only (B : Model; A : Model; D : Units) return Boolean is
     (A = (B with delta
             Remaining    => Charged (B, D),
             Debt         => Indebted (B, D),
             Eligible_Set => A.Eligible_Set))
   with Ghost;

   procedure Charge (M : in out Model; D : Units) with
     Inline,
     Pre  => Valid (M),
     Post => Valid (M) and then Charged_Only (M'Old, M, D);

   --  Cesión directa del hilo en ejecución a Peer, que estaba bloqueado.
   function Can_Hand_Off (B : Model; Peer : Thread_Id) return Boolean is
     (B.Running /= 0
      and then Peer /= 0
      and then Peer /= B.Running
      and then B.States (B.Running) = Ready
      and then B.States (Peer) = Blocked);

   --  X puede pasar a usar el contexto de Client: siempre si usa el suyo, y si
   --  ya usa uno prestado, solo si Client tiene más prioridad que su dueño.
   function May_Take (B : Model; X, Client : Thread_Id) return Boolean is
     (B.Ctx (X) = X or else B.Priorities (Client) > B.Priorities (B.Ctx (X)));

   --  Si se pide y es posible, Peer recibe el contexto con que corre el hilo en
   --  ejecución, sea el suyo o uno prestado: la cadena crece un eslabón.
   function Donation_Applies (B : Model; Peer : Thread_Id) return Boolean is
     (B.Lent (Peer) = Peer
      and then B.Depth (B.Running) < Max_Depth
      and then May_Take (B, Peer, Payer (B)));

   --  Se cobra al hilo en ejecución, que se bloquea; Peer despierta, recuperando
   --  su contexto si lo había prestado. La CPU pasa a Peer solo si con ello no
   --  se salta a nadie de más prioridad; si no, decide Schedule.
   function Handed
     (B        : Model;
      A        : Model;
      D        : Units;
      Peer     : Thread_Id;
      Donate   : Boolean;
      Switched : Boolean) return Boolean
   is
     (A.States = (B.States with delta B.Running => Blocked, Peer => Ready)
      and then A.Priorities = B.Priorities
      and then A.Floors = B.Floors
      and then A.Budgets = B.Budgets
      and then A.Remaining = Charged (B, D)
      and then A.Debt = Indebted (B, D)
      and then A.Cursors = B.Cursors
      and then
        (if Donate and then Donation_Applies (B, Peer)
         then A.Ctx (Peer) = Payer (B) and then A.Lent (Payer (B)) = Peer)
      and then
        (if Donate
           and then Donation_Applies (B, Peer)
           and then B.Ctx (Peer) /= Peer
         then A.Lent (B.Ctx (Peer)) = B.Ctx (Peer))
      and then
        (if B.Lent (Peer) /= Peer
         then A.Lent (Peer) = Peer
           and then A.Ctx (B.Lent (Peer)) = B.Lent (Peer))
      --  Respuesta en una cadena: Peer vuelve a ser el último de su contexto.
      and then
        (if B.Ctx (Peer) /= Peer
           and then not (Donate and then Donation_Applies (B, Peer))
         then A.Ctx (Peer) = B.Ctx (Peer) and then A.Lent (B.Ctx (Peer)) = Peer)
      and then
        (if Switched
         then A.Running = Peer and then Is_Top (A, Peer)
         else A.Running = B.Running))
   with Ghost;

   procedure Hand_Off
     (M        : in out Model;
      D        : Units;
      Peer     : Thread_Id;
      Donate   : Boolean;
      Switched : out Boolean)
   with
     Inline,
     Pre  => Valid (M) and then Can_Hand_Off (M, Peer),
     Post => Valid (M) and then Handed (M'Old, M, D, Peer, Donate, Switched);

   --  X devuelve el contexto que tenía prestado, sin despertar a su dueño: el
   --  dueño lo recupera de todos sus usuarios. No cobra: si X está en
   --  ejecución, hay que cobrar antes con Charge.
   procedure Release (M : in out Model; X : Thread_Id) with
     Pre  => Valid (M) and then M.Ctx (X) /= X,
     Post =>
       Valid (M)
       and then
         (for all T in Thread_Id =>
            M.Ctx (T)
            = (if M'Old.Ctx (T) = M'Old.Ctx (X) and then T /= M'Old.Ctx (X)
               then T
               else M'Old.Ctx (T)))
       and then M.Lent = (M'Old.Lent with delta M'Old.Ctx (X) => M'Old.Ctx (X))
       and then
         (for all T in Thread_Id =>
            M.Depth (T)
            = (if M'Old.Ctx (T) = M'Old.Ctx (X) and then T /= M'Old.Ctx (X)
               then 0
               else M'Old.Depth (T)))
       and then M.States = M'Old.States
       and then M.Priorities = M'Old.Priorities
       and then M.Floors = M'Old.Floors
       and then M.Remaining = M'Old.Remaining
       and then M.Debt = M'Old.Debt
       and then M.Budgets = M'Old.Budgets
       and then M.Cursors = M'Old.Cursors
       and then M.Running = M'Old.Running;

   --  El servidor X atiende a Client, que espera su respuesta: pasa a usar su
   --  contexto. Si ya usaba uno prestado, solo lo cambia por uno de más
   --  prioridad, y devuelve el anterior. No cobra: hay que cobrar antes.
   function Can_Adopt (B : Model; X, Client : Thread_Id) return Boolean is
     (X /= 0
      and then Client /= 0
      and then Client /= X
      and then B.States (X) /= Free
      and then B.States (Client) = Blocked
      and then B.Lent (X) = X
      and then B.Lent (Client) = Client
      and then
        (B.Ctx (Client) = Client or else B.Lent (B.Ctx (Client)) = Client)
      and then B.Depth (Client) < Max_Depth
      and then May_Take (B, X, B.Ctx (Client)));

   procedure Adopt (M : in out Model; X, Client : Thread_Id) with
     Pre  => Valid (M) and then Can_Adopt (M, X, Client),
     Post =>
       Valid (M)
       and then M.Ctx (X) = M'Old.Ctx (Client)
       and then M.Lent (M'Old.Ctx (Client)) = X
       and then
         (if M'Old.Ctx (X) /= X then M.Lent (M'Old.Ctx (X)) = M'Old.Ctx (X))
       and then M.States = M'Old.States
       and then M.Priorities = M'Old.Priorities
       and then M.Floors = M'Old.Floors
       and then M.Remaining = M'Old.Remaining
       and then M.Debt = M'Old.Debt
       and then M.Budgets = M'Old.Budgets
       and then M.Running = M'Old.Running;

   --  Despertar a X no le quita un contexto a nadie: X no ha prestado el
   --  suyo y, si usa uno prestado, ya es el último de esa cadena.
   function Quiet (M : Model; X : Thread_Id) return Boolean is
     (M.Lent (X) = X and then (M.Ctx (X) = X or else M.Lent (M.Ctx (X)) = X));

   --  Despierta a X. Si había prestado su contexto, lo recupera de todos sus
   --  usuarios. Si usaba uno prestado, vuelve a ser el último de la cadena: los
   --  que había por debajo lo pierden. Si no pasa ninguna de las dos cosas
   --  (Quiet), ningún contexto ni ningún nivel cambia.
   procedure Wake (M : in out Model; X : Thread_Id) with
     Inline,
     Pre  => Valid (M) and then M.States (X) = Blocked,
     Post =>
       Valid (M)
       and then M.States = (M'Old.States with delta X => Ready)
       and then M.Lent (X) = X
       and then
         (if M'Old.Lent (X) /= X
          then (for all T in Thread_Id =>
                  (if M'Old.Ctx (T) = X and then T /= X then M.Ctx (T) = T)))
       and then
         (if M'Old.Ctx (X) /= X
          then M.Ctx (X) = M'Old.Ctx (X) and then M.Lent (M'Old.Ctx (X)) = X)
       and then
         (for all T in Thread_Id =>
            (if T /= X and then T /= M'Old.Ctx (X) then M.Lent (T) = M'Old.Lent (T)))
       and then
         (for all T in Thread_Id => M.Ctx (T) = M'Old.Ctx (T) or else M.Ctx (T) = T)
       and then (if Quiet (M'Old, X) then M.Ctx = M'Old.Ctx and then M.Levels = M'Old.Levels)
       and then M.Remaining = M'Old.Remaining
       and then M.Debt = M'Old.Debt
       and then M.Budgets = M'Old.Budgets
       and then M.Priorities = M'Old.Priorities
       and then M.Floors = M'Old.Floors
       and then M.Cursors = M'Old.Cursors
       and then M.Running = M'Old.Running;

   procedure Block (M : in out Model; X : Thread_Id) with
     Pre  => Valid (M) and then X /= 0 and then M.States (X) = Ready,
     Post =>
       Valid (M)
       and then M.States = (M'Old.States with delta X => Blocked)
       and then M.Floors = M'Old.Floors
       and then M.Remaining = M'Old.Remaining
       and then M.Debt = M'Old.Debt
       and then M.Budgets = M'Old.Budgets
       and then M.Running = M'Old.Running;

   --  X termina. Devuelve los contextos que tuviera prestados o en préstamo, y
   --  olvida lo que heredaba.
   procedure Finish (M : in out Model; X : Thread_Id) with
     Pre  => Valid (M) and then X /= 0 and then M.States (X) /= Free,
     Post =>
       Valid (M)
       and then M.States = (M'Old.States with delta X => Free)
       and then M.Floors = (M'Old.Floors with delta X => 0)
       and then M.Remaining = (M'Old.Remaining with delta X => 0)
       and then M.Debt = (M'Old.Debt with delta X => 0)
       and then M.Budgets = M'Old.Budgets
       and then M.Running = M'Old.Running;

   --  Crea un hilo listo en un hueco libre con los parámetros por defecto y
   --  sin nada heredado: un hueco reutilizado no conserva el suelo de otro.
   procedure Start (M : in out Model; X : Thread_Id) with
     Pre  => Valid (M) and then X /= 0 and then M.States (X) = Free,
     Post =>
       Valid (M)
       and then M.States = (M'Old.States with delta X => Ready)
       and then M.Floors = (M'Old.Floors with delta X => 0)
       and then Level_Of (M, X) = Default_Priority
       and then M.Running = M'Old.Running;

   --  Cambia prioridad y presupuesto de X, con el presupuesto entero y sin deuda.
   procedure Set_Params
     (M : in out Model; X : Thread_Id; L : Priority; Budget : Budget_Value)
   with
     Pre  => Valid (M) and then M.States (X) /= Free,
     Post =>
       Valid (M)
       and then M.Priorities = (M'Old.Priorities with delta X => L)
       and then M.Budgets = (M'Old.Budgets with delta X => Budget)
       and then M.Remaining = (M'Old.Remaining with delta X => Budget)
       and then M.Debt = (M'Old.Debt with delta X => 0)
       and then M.Floors = M'Old.Floors
       and then M.States = M'Old.States
       and then M.Running = M'Old.Running;

   --  Fija el suelo del hilo X. Solo cambia eso (y los conjuntos por nivel): ni
   --  contextos, ni presupuestos, ni estados. Heredar da urgencia, no tiempo de
   --  CPU. Y llega a X use el contexto que use, propio o prestado.
   procedure Set_Floor (M : in out Model; X : Thread_Id; L : Priority)
   with
     Pre  => Valid (M),
     Post =>
       Valid (M)
       and then
         M
         = (M'Old with delta
              Floors  => (M'Old.Floors with delta X => L),
              Levels  => M.Levels,
              Members => M.Members)
       and then Level_Of (M, X) = Priority'Max (M.Priorities (M.Ctx (X)), L);

   --  Lo mismo que Is_Top, sin recorrer los hilos.
   function Top_Now (M : Model; X : Thread_Id) return Boolean with
     Inline,
     Pre  => Valid (M),
     Post => Top_Now'Result = Is_Top (M, X);

   --  Busca un hueco libre. El hilo 0 es el de arranque y nunca se reutiliza.
   procedure Find_Free
     (States : State_Table;
      Found  : out Boolean;
      Slot   : out Thread_Id)
   with
     Post =>
       (if Found
        then Slot /= 0 and then States (Slot) = Free
        else (for all T in Thread_Id =>
                (if T /= 0 then States (T) /= Free)));

   --  Teorema de no inanición.

   function Sum (R : Unit_Table) return Work is
     (Work (R (0)) + Work (R (1)) + Work (R (2)) + Work (R (3))
      + Work (R (4)) + Work (R (5)) + Work (R (6)) + Work (R (7)))
   with Ghost;

   function Others_Sum (R : Unit_Table; S : Thread_Id) return Work is
     (Sum (R) - Work (R (S)))
   with Ghost;

   --  Si al contexto S le queda presupuesto, solo espera a lo que les queda a los
   --  demás. Si no, puede tener que esperar además a una ronda completa de ellos.
   function Wait_Bound (M : Model; S : Thread_Id) return Work is
     (Others_Sum (M.Remaining, S)
      + (if M.Remaining (S) = 0 then Others_Sum (Refilled (M), S) else 0))
   with
     Ghost,
     Pre => Valid (M);

   --  T espera listo con el contexto S. Toda la CPU cobrada a otro contexto baja
   --  la cota de S en lo mismo.
   procedure Lemma_Bounded_Wait
     (B : Model; A : Model; D : Units; Next : Thread_Id; T : Thread_Id)
   with
     Ghost,
     Pre  =>
       Valid (B)
       and then Valid (A)
       and then Scheduled (B, A, D, Next)
       and then B.States (T) = Ready
       and then B.Ctx (T) /= Payer (B),
     Post =>
       Wait_Bound (A, B.Ctx (T)) + Work (Spent (B, D))
       <= Wait_Bound (B, B.Ctx (T));

   --  Lo mismo para cualquier paso que solo cobra: cesión directa o cobrar sin
   --  elegir.
   procedure Lemma_Bounded_Wait_Charged
     (B : Model; A : Model; D : Units; S : Thread_Id)
   with
     Ghost,
     Pre  =>
       Valid (B)
       and then Valid (A)
       and then S /= Payer (B)
       and then A.Remaining = Charged (B, D)
       and then A.Debt = Indebted (B, D)
       and then A.Budgets = B.Budgets
       and then (for all X in Thread_Id =>
                   (A.States (X) = Free) = (B.States (X) = Free)),
     Post =>
       Wait_Bound (A, S) + Work (Spent (B, D)) <= Wait_Bound (B, S);

   --  Todo el tiempo se cobra: lo que no se descuenta del presupuesto se suma
   --  a la deuda, salvo lo que pase del tope de deuda.
   procedure Lemma_All_Time_Billed (B : Model; D : Units) with
     Ghost,
     Pre  => Work (B.Debt (Payer (B))) + Work (D) <= Max_Budget,
     Post =>
       Work (Spent (B, D))
       + (Work (Indebted (B, D) (Payer (B))) - Work (B.Debt (Payer (B))))
       = Work (D);

   --  Bloquear, despertar o prestar contextos no cambia la cota de nadie.
   procedure Lemma_Wake_Keeps_Bound (B : Model; A : Model; S : Thread_Id) with
     Ghost,
     Pre  =>
       Valid (B)
       and then Valid (A)
       and then A.Remaining = B.Remaining
       and then A.Budgets = B.Budgets
       and then A.Debt = B.Debt
       and then (for all X in Thread_Id =>
                   (A.States (X) = Free) = (B.States (X) = Free)),
     Post => Wait_Bound (A, S) = Wait_Bound (B, S);

   --  Terminar un hilo no aumenta la cota de los demás.
   procedure Lemma_Exit_Lowers_Bound
     (B : Model; A : Model; Gone : Thread_Id; S : Thread_Id)
   with
     Ghost,
     Pre  =>
       Valid (B)
       and then Valid (A)
       and then Gone /= S
       and then A.Budgets = B.Budgets
       and then A.Remaining = (B.Remaining with delta Gone => 0)
       and then A.Debt = (B.Debt with delta Gone => 0)
       and then A.States = (B.States with delta Gone => Free),
     Post => Wait_Bound (A, S) <= Wait_Bound (B, S);

   --  El anterior a X en el orden circular: con el cursor ahí, X va primero.
   function Before (X : Thread_Id) return Thread_Id is
     (Thread_Id ((Integer (X) + Max_Threads - 1) mod Max_Threads));

   --  X pasa a ser el siguiente en turno de su nivel. Solo cambia el cursor de
   --  ese nivel: ni estados, ni presupuestos, ni la cota de nadie.
   procedure Promote (M : in out Model; X : Thread_Id) with
     Pre  => Valid (M),
     Post =>
       Valid (M)
       and then
         M
         = (M'Old with delta
              Cursors =>
                (M'Old.Cursors with delta Level_Of (M'Old, X) => Before (X)));

   --  El turno avanza: si T espera elegible en el nivel del elegido, cada
   --  decisión de ese nivel lo acerca. Como la distancia es menor que
   --  Max_Threads, le toca en menos de Max_Threads decisiones de su nivel.
   procedure Lemma_Turn_Progress
     (B : Model; A : Model; D : Units; Next : Thread_Id; T : Thread_Id)
   with
     Ghost,
     Pre  =>
       Scheduled (B, A, D, Next)
       and then Eligible (A, T)
       and then Level_Of (A, T) = Level_Of (A, Next)
       and then T /= Next,
     Post =>
       Distance (A.Cursors (Level_Of (A, T)), T)
       < Distance (B.Cursors (Level_Of (A, T)), T);

   --  Tras promover a X, si nadie elegible le supera, la decisión es X.
   procedure Lemma_Promoted_Runs
     (B : Model; A : Model; D : Units; Next : Thread_Id; X : Thread_Id)
   with
     Ghost,
     Pre  =>
       Scheduled (B, A, D, Next)
       and then Is_Top (A, X)
       and then B.Cursors (Level_Of (A, X)) = Before (X),
     Post => Next = X;

   --  X es elegible y todos los demás elegibles tienen menos prioridad.
   function Strictly_Top (M : Model; X : Thread_Id) return Boolean is
     (Eligible (M, X)
      and then
        (for all T in Thread_Id =>
           (if T /= X and then Eligible (M, T)
            then Level_Of (M, T) < Level_Of (M, X))))
   with Ghost;

   --  Latencia: si X queda por encima de todos los demás elegibles, la decisión
   --  es X. Cuántos hilos haya por debajo no cambia nada.
   procedure Lemma_Top_Runs
     (B : Model; A : Model; D : Units; Next : Thread_Id; X : Thread_Id)
   with
     Ghost,
     Pre  => Scheduled (B, A, D, Next) and then Strictly_Top (A, X),
     Post => Next = X;

end Scheduler_Core;
