--  SPDX-License-Identifier: GPL-3.0-or-later
--  Colas de espera de los endpoints de IPC síncrono.
--
--  Invariante inductiva: cada cola no tiene duplicados y cada hilo en cola sabe
--  en qué endpoint está, así que ningún hilo espera en dos sitios a la vez.
--  Demostrado en cada operación:
--    * Quien llega con un compañero esperando se empareja: nunca hace cola.
--    * Se atiende siempre al primero de la cola (FIFO).
--    * La posición de un hilo en cola nunca empeora.
--    * Una señal nunca se pierde: despierta a un receptor o queda pendiente, y
--      ningún receptor duerme mientras haya una pendiente en su endpoint.
--
--  Llamada y respuesta. Una llamada enlaza a cliente y servidor hasta la
--  respuesta. La invariante demuestra que ese enlace es biunívoco: cada servidor
--  debe a lo sumo una respuesta, cada cliente espera a lo sumo una, y responder
--  solo puede despertar a quien de verdad llamó a ese servidor.
--
--  Las esperas de respuesta no forman ciclos (Acyclic, en la invariante): un
--  enlace nuevo siempre va a un servidor que no espera a nadie, y quitar
--  enlaces no crea ciclos. El kernel puede seguir la cadena de quién espera a
--  quién sabiendo que acaba sin repetir hilos.
--
--  Respuestas aplazadas. Un servidor puede aplazar la respuesta que debe: el
--  cliente sigue esperándole, y el servidor queda libre para recibir. Más tarde
--  contesta con Reply_Held, que solo acepta a un cliente cuya respuesta aplazó
--  ese mismo servidor: nadie puede contestar a quien no le llamó.
--
--  El contenido de los mensajes lo mueve el kernel; este módulo solo decide
--  quién se encuentra con quién. No es reentrante.

pragma Unevaluated_Use_Of_Old (Allow);

package Ipc_Core with
  SPARK_Mode,
  Abstract_State    => State,
  Initializes       => State,
  Initial_Condition => Invariant
is
   type U64 is mod 2**64 with Size => 64;

   Max_Endpoints : constant := 4;
   Max_Threads   : constant := 8;

   type Endpoint_Id is range 0 .. Max_Endpoints - 1;
   type Thread_Slot is range 0 .. Max_Threads - 1;
   subtype Thread_Id is Thread_Slot range 1 .. Max_Threads - 1;

   type Queue_Mode is (Idle, Senders, Receivers);
   type Queue_Length is range 0 .. Max_Threads - 1;
   subtype Queue_Index is Queue_Length range 1 .. Max_Threads - 1;
   type Queue_Items is array (Queue_Index) of Thread_Slot;

   type Wait_Queue is record
      Mode   : Queue_Mode;
      Length : Queue_Length;
      Items  : Queue_Items;
   end record;

   type Queue_Array is array (Endpoint_Id) of Wait_Queue;
   type Signal_Array is array (Endpoint_Id) of Boolean;
   type Thread_Link is array (Thread_Id) of Thread_Slot;

   --  Cadenas de espera. Step da el hilo al que espera T (0 si ninguno, y el 0
   --  se queda en 0); Iter, el que se alcanza en K pasos. Va desenrollado: así
   --  las demostraciones no necesitan inducción sobre una función recursiva.
   subtype Chain_Steps is Natural range 0 .. Max_Threads;

   function Step (W : Thread_Link; T : Thread_Slot) return Thread_Slot is
     (if T = 0 then 0 else W (T))
   with Ghost;

   function Iter (W : Thread_Link; T : Thread_Slot; K : Chain_Steps) return Thread_Slot is
     (case K is
        when 0 => T,
        when 1 => Step (W, T),
        when 2 => Step (W, Step (W, T)),
        when 3 => Step (W, Step (W, Step (W, T))),
        when 4 => Step (W, Step (W, Step (W, Step (W, T)))),
        when 5 => Step (W, Step (W, Step (W, Step (W, Step (W, T))))),
        when 6 => Step (W, Step (W, Step (W, Step (W, Step (W, Step (W, T)))))),
        when 7 => Step (W, Step (W, Step (W, Step (W, Step (W, Step (W, Step (W, T))))))),
        when 8 => Step (W, Step (W, Step (W, Step (W, Step (W, Step (W, Step (W, Step (W, T)))))))))
   with Ghost;

   --  Ningún hilo se alcanza a sí mismo siguiendo a quién espera: no hay
   --  ciclos. Con Max_Threads - 1 hilos, un ciclo tendría a lo sumo ese
   --  largo, así que basta con mirar hasta Max_Threads pasos.
   function Acyclic (W : Thread_Link) return Boolean is
     (for all T in Thread_Id =>
        (for all K in Chain_Steps range 1 .. Chain_Steps'Last => Iter (W, T, K) /= T))
   with Ghost;
   type Call_Flags is array (Thread_Id) of Boolean;

   Result_Queued  : constant U64 := 100;
   Result_Invalid : constant U64 := 101;
   Result_Signal  : constant U64 := 102;
   Result_Not_Ready : constant U64 := 103;

   Status_Ok          : constant U64 := 0;
   Status_Not_Waiting : constant U64 := 1;
   Status_Invalid     : constant U64 := 2;

   function Valid_Endpoint (E : U64) return Boolean is (E < U64 (Max_Endpoints));

   function Valid_Thread (T : U64) return Boolean is
     (T >= 1 and then T < U64 (Max_Threads));

   function Invariant return Boolean with
     Ghost,
     Global => (Input => State);

   function Queues return Queue_Array with
     Ghost,
     Global => (Input => State);

   function Signals return Signal_Array with
     Ghost,
     Global => (Input => State);

   --  A quién debe respuesta cada servidor, o 0.
   function Replies return Thread_Link with
     Ghost,
     Global => (Input => State);

   --  De quién espera respuesta cada cliente, o 0.
   function Awaited return Thread_Link with
     Ghost,
     Global => (Input => State);

   --  Con el invariante, las cadenas de espera no tienen ciclos.
   procedure Lemma_Acyclic with
     Ghost,
     Global => (Proof_In => State),
     Pre    => Invariant,
     Post   => Acyclic (Awaited);

   --  Clientes cuya respuesta ha aplazado su servidor.
   function Deferred return Call_Flags with
     Ghost,
     Global => (Input => State);

   --  Qué emisores en cola hicieron una llamada.
   function Callers return Call_Flags with
     Ghost,
     Global => (Input => State);

   function Is_Waiting (T : Thread_Id) return Boolean with
     Ghost,
     Global => (Input => State);

   --  New_Q es Old_Q con T añadido al final.
   function Appended
     (Old_Q, New_Q : Wait_Queue;
      T            : Thread_Id;
      Mode         : Queue_Mode) return Boolean
   is
     (Old_Q.Length < Queue_Length'Last
      and then New_Q.Mode = Mode
      and then New_Q.Length = Old_Q.Length + 1
      and then (for all I in Queue_Index =>
                  (if I <= Old_Q.Length then New_Q.Items (I) = Old_Q.Items (I)))
      and then New_Q.Items (New_Q.Length) = T)
   with Ghost;

   --  New_Q es Old_Q sin su primer elemento: todos avanzan un puesto.
   function Shifted (Old_Q, New_Q : Wait_Queue) return Boolean is
     (Old_Q.Length >= 1
      and then New_Q.Length = Old_Q.Length - 1
      and then New_Q.Mode = (if New_Q.Length = 0 then Idle else Old_Q.Mode)
      and then (for all I in Queue_Index =>
                  (if I < Old_Q.Length then New_Q.Items (I) = Old_Q.Items (I + 1))))
   with Ghost;

   --  Nadie retrocede: cada elemento sigue en su puesto o avanza uno.
   function Never_Behind (Old_Q, New_Q : Wait_Queue) return Boolean is
     (for all I in Queue_Index =>
        (if I <= New_Q.Length and then I < Queue_Index'Last
         then New_Q.Items (I) = Old_Q.Items (I)
              or else New_Q.Items (I) = Old_Q.Items (I + 1)))
   with Ghost;

   --  Devuelve el receptor emparejado, Result_Queued si el emisor queda en
   --  espera, o Result_Invalid.
   function Send (Endpoint, Thread : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then
         (if Send'Result = Result_Queued
          then Valid_Endpoint (Endpoint)
            and then Valid_Thread (Thread)
            and then Queues'Old (Endpoint_Id (Endpoint)).Mode /= Receivers
            and then Appended
                       (Queues'Old (Endpoint_Id (Endpoint)),
                        Queues (Endpoint_Id (Endpoint)),
                        Thread_Id (Thread),
                        Senders)
          elsif Send'Result /= Result_Invalid
          then Valid_Endpoint (Endpoint)
            and then Queues'Old (Endpoint_Id (Endpoint)).Mode = Receivers
            and then Send'Result
                       = U64 (Queues'Old (Endpoint_Id (Endpoint)).Items (1))
            and then Shifted
                       (Queues'Old (Endpoint_Id (Endpoint)),
                        Queues (Endpoint_Id (Endpoint)))),
     Export,
     Convention    => C,
     External_Name => "fb_ipc_send";

   --  Envía y queda esperando la respuesta de quien lo reciba. Devuelve el
   --  servidor si había uno esperando, Result_Queued si el cliente hace cola, o
   --  Result_Invalid.
   function Call (Endpoint, Thread : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then
         (if Call'Result = Result_Queued
          then Valid_Endpoint (Endpoint)
            and then Valid_Thread (Thread)
            and then Queues'Old (Endpoint_Id (Endpoint)).Mode /= Receivers
            and then Appended
                       (Queues'Old (Endpoint_Id (Endpoint)),
                        Queues (Endpoint_Id (Endpoint)),
                        Thread_Id (Thread),
                        Senders)
            and then Callers (Thread_Id (Thread))
          elsif Call'Result /= Result_Invalid
          then Valid_Endpoint (Endpoint)
            and then Valid_Thread (Thread)
            and then Queues'Old (Endpoint_Id (Endpoint)).Mode = Receivers
            and then Call'Result
                       = U64 (Queues'Old (Endpoint_Id (Endpoint)).Items (1))
            and then Shifted
                       (Queues'Old (Endpoint_Id (Endpoint)),
                        Queues (Endpoint_Id (Endpoint)))
            and then Awaited (Thread_Id (Thread)) = Thread_Slot (Call'Result)
            and then Replies (Thread_Id (Call'Result)) = Thread_Id (Thread)),
     Export,
     Convention    => C,
     External_Name => "fb_ipc_call";

   --  Rompe el enlace del servidor y devuelve el cliente al que debía
   --  responder, o Result_Invalid si no debe nada. Nunca se bloquea.
   function Reply (Thread : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Queues = Queues'Old
       and then
         (if Reply'Result /= Result_Invalid
          then Valid_Thread (Thread)
            and then Reply'Result /= 0
            and then Reply'Result = U64 (Replies'Old (Thread_Id (Thread)))
            and then Reply'Result < U64 (Max_Threads)
            and then Awaited'Old (Thread_Id (Reply'Result)) = Thread_Id (Thread)
            and then Awaited (Thread_Id (Reply'Result)) = 0
            and then Replies (Thread_Id (Thread)) = 0),
     Export,
     Convention    => C,
     External_Name => "fb_ipc_reply";

   --  Aplaza la respuesta que debe el servidor y devuelve el cliente, que sigue
   --  esperando. El servidor queda libre para recibir otra petición.
   function Defer (Thread : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Queues = Queues'Old
       and then
         (if Defer'Result /= Result_Invalid
          then Valid_Thread (Thread)
            and then Valid_Thread (Defer'Result)
            and then Defer'Result = U64 (Replies'Old (Thread_Id (Thread)))
            and then Replies (Thread_Id (Thread)) = 0
            and then Awaited (Thread_Id (Defer'Result)) = Thread_Slot (Thread)
            and then Deferred (Thread_Id (Defer'Result))),
     Export,
     Convention    => C,
     External_Name => "fb_ipc_defer";

   --  Contesta una respuesta aplazada. Solo vale si Caller espera a este
   --  servidor y su respuesta se aplazó. Devuelve Caller o Result_Invalid.
   function Reply_Held (Thread, Caller : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Queues = Queues'Old
       and then
         (if Reply_Held'Result /= Result_Invalid
          then Valid_Thread (Thread)
            and then Valid_Thread (Caller)
            and then Reply_Held'Result = Caller
            and then Deferred'Old (Thread_Id (Caller))
            and then Awaited'Old (Thread_Id (Caller)) = Thread_Slot (Thread)
            and then Awaited (Thread_Id (Caller)) = 0
            and then not Deferred (Thread_Id (Caller))
            and then Replies = Replies'Old),
     Export,
     Convention    => C,
     External_Name => "fb_ipc_reply_held";

   --  El servidor muere: suelta a uno de los clientes con respuesta aplazada.
   --  Devuelve el cliente, o Result_Invalid si no queda ninguno.
   function Abort_Held (Thread : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Queues = Queues'Old
       and then
         (if Abort_Held'Result /= Result_Invalid
          then Valid_Thread (Thread)
            and then Valid_Thread (Abort_Held'Result)
            and then Awaited'Old (Thread_Id (Abort_Held'Result)) = Thread_Slot (Thread)
            and then Awaited (Thread_Id (Abort_Held'Result)) = 0
          elsif Valid_Thread (Thread)
          then (for all C in Thread_Id =>
                  (if Deferred (C) then Awaited (C) /= Thread_Slot (Thread)))),
     Export,
     Convention    => C,
     External_Name => "fb_ipc_abort_held";

   --  Servidor del que espera respuesta el hilo, o 0.
   function Waits_For (Thread : U64) return U64 with
     Inline,
     Global        => (Input => State),
     Pre           => Invariant,
     Post          =>
       (if Valid_Thread (Thread)
        then Waits_For'Result = U64 (Awaited (Thread_Id (Thread)))
        else Waits_For'Result = 0)
       --  Seguir a quién espera cada hilo nunca vuelve al punto de partida.
       and then Acyclic (Awaited),
     Export,
     Convention    => C,
     External_Name => "fb_ipc_waits_for";

   --  Saca al primer emisor de la cola: el endpoint se ha quedado sin servidor.
   function Abort_Sender (Endpoint : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then
         (if Abort_Sender'Result = Result_Not_Ready
          then Valid_Endpoint (Endpoint)
            and then Queues'Old (Endpoint_Id (Endpoint)).Mode /= Senders
            and then Queues = Queues'Old
          elsif Abort_Sender'Result /= Result_Invalid
          then Valid_Endpoint (Endpoint)
            and then Queues'Old (Endpoint_Id (Endpoint)).Mode = Senders
            and then Abort_Sender'Result
                       = U64 (Queues'Old (Endpoint_Id (Endpoint)).Items (1))
            and then Shifted
                       (Queues'Old (Endpoint_Id (Endpoint)),
                        Queues (Endpoint_Id (Endpoint)))),
     Export,
     Convention    => C,
     External_Name => "fb_ipc_abort_sender";

   --  Como Send, pero nunca hace cola: sin receptor esperando no cambia nada.
   --  Permite a un servidor contestar sin que un cliente pueda bloquearlo.
   function Try_Send (Endpoint : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then
         (if Try_Send'Result = Result_Not_Ready
          then Valid_Endpoint (Endpoint)
            and then Queues'Old (Endpoint_Id (Endpoint)).Mode /= Receivers
            and then Queues = Queues'Old
          elsif Try_Send'Result /= Result_Invalid
          then Valid_Endpoint (Endpoint)
            and then Queues'Old (Endpoint_Id (Endpoint)).Mode = Receivers
            and then Try_Send'Result
                       = U64 (Queues'Old (Endpoint_Id (Endpoint)).Items (1))
            and then Shifted
                       (Queues'Old (Endpoint_Id (Endpoint)),
                        Queues (Endpoint_Id (Endpoint)))),
     Export,
     Convention    => C,
     External_Name => "fb_ipc_try_send";

   --  La interrupción de un dispositivo. Devuelve el receptor despertado, o
   --  Result_Queued si la señal queda pendiente. Varias señales se acumulan
   --  en una sola: quien despierta debe atender todo lo que el dispositivo tenga.
   function Signal (Endpoint : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then
         (if Signal'Result = Result_Queued
          then Valid_Endpoint (Endpoint)
            and then Queues'Old (Endpoint_Id (Endpoint)).Mode /= Receivers
            and then Signals (Endpoint_Id (Endpoint))
            and then Queues = Queues'Old
          elsif Signal'Result /= Result_Invalid
          then Valid_Endpoint (Endpoint)
            and then Queues'Old (Endpoint_Id (Endpoint)).Mode = Receivers
            and then Signal'Result
                       = U64 (Queues'Old (Endpoint_Id (Endpoint)).Items (1))
            and then Shifted
                       (Queues'Old (Endpoint_Id (Endpoint)),
                        Queues (Endpoint_Id (Endpoint)))),
     Export,
     Convention    => C,
     External_Name => "fb_ipc_signal";

   --  Olvida una señal pendiente: el dispositivo se ha quedado sin dueño.
   function Clear_Signal (Endpoint : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Queues = Queues'Old
       and then
         (if Clear_Signal'Result = Status_Ok
          then Valid_Endpoint (Endpoint)
            and then not Signals (Endpoint_Id (Endpoint))),
     Export,
     Convention    => C,
     External_Name => "fb_ipc_clear_signal";

   --  Simétrica de Send, salvo que una señal pendiente se entrega antes que
   --  cualquier mensaje. Un servidor que debe una respuesta no puede recibir
   --  otra llamada: así ninguna respuesta se pierde.
   function Recv (Endpoint, Thread : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then
         (if Recv'Result /= Result_Invalid
          then Valid_Thread (Thread)
            and then Replies'Old (Thread_Id (Thread)) = 0)
       and then
         (if Recv'Result = Result_Queued
          then Valid_Endpoint (Endpoint)
            and then Valid_Thread (Thread)
            and then Queues'Old (Endpoint_Id (Endpoint)).Mode /= Senders
            and then not Signals (Endpoint_Id (Endpoint))
            and then Appended
                       (Queues'Old (Endpoint_Id (Endpoint)),
                        Queues (Endpoint_Id (Endpoint)),
                        Thread_Id (Thread),
                        Receivers)
          elsif Recv'Result = Result_Signal
          then Valid_Endpoint (Endpoint)
            and then Signals'Old (Endpoint_Id (Endpoint))
            and then not Signals (Endpoint_Id (Endpoint))
            and then Queues = Queues'Old
          elsif Recv'Result /= Result_Invalid
          then Valid_Endpoint (Endpoint)
            and then Queues'Old (Endpoint_Id (Endpoint)).Mode = Senders
            and then Recv'Result
                       = U64 (Queues'Old (Endpoint_Id (Endpoint)).Items (1))
            and then Shifted
                       (Queues'Old (Endpoint_Id (Endpoint)),
                        Queues (Endpoint_Id (Endpoint)))
            and then Valid_Thread (Recv'Result)
            and then Awaited (Thread_Id (Recv'Result))
                       = (if Callers'Old (Thread_Id (Recv'Result))
                          then Thread_Slot (Thread)
                          else 0)),
     Export,
     Convention    => C,
     External_Name => "fb_ipc_recv";

   --  Saca a un hilo de la cola donde espera o de su espera de respuesta.
   function Cancel (Thread : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then
         (if Cancel'Result = Status_Ok or else Cancel'Result = Status_Not_Waiting
          then Valid_Thread (Thread)
            and then not Is_Waiting (Thread_Id (Thread))
            and then Awaited (Thread_Id (Thread)) = 0)
       and then
         (for all E in Endpoint_Id => Never_Behind (Queues'Old (E), Queues (E))),
     Export,
     Convention    => C,
     External_Name => "fb_ipc_cancel";

end Ipc_Core;
