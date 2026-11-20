package body Ipc_Core with
  SPARK_Mode,
  Refined_State => (State => (Table, Where, Pending, Reply_To, Waiting, Calling, Held))
is
   --  0 si el hilo no espera; E + 1 si espera en el endpoint E.
   type Where_Tag is range 0 .. Max_Endpoints;
   type Where_Map is array (Thread_Id) of Where_Tag;

   Table : Queue_Array := (others => (Idle, 0, (others => 0)));
   Where : Where_Map := (others => 0);
   Pending : Signal_Array := (others => False);

   --  El enlace de cada llamada en curso, visto desde sus dos extremos.
   Reply_To : Thread_Link := (others => 0);
   Waiting  : Thread_Link := (others => 0);

   --  El hilo está en cola como emisor y espera respuesta.
   Calling : Call_Flags := (others => False);

   --  El servidor aplazó la respuesta de este cliente.
   Held : Call_Flags := (others => False);

   function Tag_Of (E : Endpoint_Id) return Where_Tag is (Where_Tag (E) + 1);

   function Queue_Ok (Q : Wait_Queue; E : Endpoint_Id; W : Where_Map) return Boolean is
     ((Q.Mode = Idle) = (Q.Length = 0)
      and then
        (for all I in Queue_Index =>
           (if I <= Q.Length
            then Q.Items (I) in Thread_Id
                 and then W (Q.Items (I)) = Tag_Of (E)))
      and then
        (for all I in Queue_Index =>
           (for all J in Queue_Index =>
              (if I < J and then J <= Q.Length then Q.Items (I) /= Q.Items (J)))))
   with Ghost;

   --  Quien espera un mensaje no debe ninguna respuesta.
   function Receivers_Free (Q : Wait_Queue; R : Thread_Link) return Boolean is
     (if Q.Mode = Receivers
      then (for all I in Queue_Index =>
              (if I <= Q.Length and then Q.Items (I) in Thread_Id
               then R (Q.Items (I)) = 0)))
   with Ghost;

   --  Cada cliente que espera tiene su respuesta como la actual de su servidor
   --  o aplazada, nunca las dos cosas.
   function Links_Ok
     (R, A : Thread_Link; W : Where_Map; H : Call_Flags) return Boolean
   is
     ((for all S in Thread_Id =>
         (if R (S) /= 0 then A (R (S)) = S and then W (R (S)) = 0))
      and then
      (for all C in Thread_Id =>
         (if A (C) /= 0 then (R (A (C)) = C) = not H (C)))
      and then
      (for all C in Thread_Id => (if H (C) then A (C) /= 0))
      and then
      (for all C in Thread_Id =>
         (if W (C) /= 0 then A (C) = 0)))
   with Ghost;

   --  Lemas de las cadenas de espera.

   --  Un paso más es Step del anterior.
   procedure Lemma_Unfold (W : Thread_Link; K : Chain_Steps) with
     Ghost,
     Global => null,
     Pre    => K >= 1,
     Post   => (for all X in Thread_Slot => Iter (W, X, K) = Step (W, Iter (W, X, K - 1)))
   is
   begin
      null;
   end Lemma_Unfold;

   --  Desde un hilo que no espera a nadie, la cadena acaba en el primer paso.
   procedure Lemma_End (W : Thread_Link; T : Thread_Id; K : Chain_Steps) with
     Ghost,
     Global             => null,
     Pre                => W (T) = 0 and then K >= 1,
     Post               => Iter (W, T, K) = 0,
     Subprogram_Variant => (Decreases => K)
   is
   begin
      if K > 1 then
         Lemma_End (W, T, K - 1);
         Lemma_Unfold (W, K);
      end if;
   end Lemma_End;

   --  Con un enlace nuevo de C a S, donde ni C ni S esperaban a nadie, cada
   --  cadena sigue igual, o llega a S, o ya acabó.
   procedure Lemma_Add_Step (Old_W, New_W : Thread_Link; C, S : Thread_Id; K : Chain_Steps) with
     Ghost,
     Global             => null,
     Pre                =>
       Old_W (C) = 0 and then Old_W (S) = 0 and then C /= S
       and then New_W = (Old_W with delta C => S),
     Post               =>
       (for all X in Thread_Slot =>
          Iter (New_W, X, K) = Iter (Old_W, X, K)
          or else Iter (New_W, X, K) = S
          or else Iter (New_W, X, K) = 0),
     Subprogram_Variant => (Decreases => K)
   is
   begin
      if K >= 1 then
         Lemma_Add_Step (Old_W, New_W, C, S, K - 1);
         Lemma_Unfold (Old_W, K);
         Lemma_Unfold (New_W, K);
      end if;
   end Lemma_Add_Step;

   procedure Lemma_Add (Old_W, New_W : Thread_Link; C, S : Thread_Id) with
     Ghost,
     Global => null,
     Pre    =>
       Acyclic (Old_W)
       and then Old_W (C) = 0 and then Old_W (S) = 0 and then C /= S
       and then New_W = (Old_W with delta C => S),
     Post   => Acyclic (New_W)
   is
   begin
      for K in Chain_Steps range 1 .. Chain_Steps'Last loop
         Lemma_Add_Step (Old_W, New_W, C, S, K);
         Lemma_End (New_W, S, K);
         pragma Loop_Invariant
           (for all J in Chain_Steps range 1 .. K =>
              (for all T in Thread_Id => Iter (New_W, T, J) /= T));
      end loop;
   end Lemma_Add;

   --  Quitando el enlace de C, cada cadena sigue igual o ya acabó.
   procedure Lemma_Remove_Step (Old_W, New_W : Thread_Link; C : Thread_Id; K : Chain_Steps) with
     Ghost,
     Global             => null,
     Pre                => New_W = (Old_W with delta C => 0),
     Post               =>
       (for all X in Thread_Slot =>
          Iter (New_W, X, K) = Iter (Old_W, X, K) or else Iter (New_W, X, K) = 0),
     Subprogram_Variant => (Decreases => K)
   is
   begin
      if K >= 1 then
         Lemma_Remove_Step (Old_W, New_W, C, K - 1);
         Lemma_Unfold (Old_W, K);
         Lemma_Unfold (New_W, K);
      end if;
   end Lemma_Remove_Step;

   procedure Lemma_Remove (Old_W, New_W : Thread_Link; C : Thread_Id) with
     Ghost,
     Global => null,
     Pre    => Acyclic (Old_W) and then New_W = (Old_W with delta C => 0),
     Post   => Acyclic (New_W)
   is
   begin
      for K in Chain_Steps range 1 .. Chain_Steps'Last loop
         Lemma_Remove_Step (Old_W, New_W, C, K);
         pragma Loop_Invariant
           (for all J in Chain_Steps range 1 .. K =>
              (for all T in Thread_Id => Iter (New_W, T, J) /= T));
      end loop;
   end Lemma_Remove;

   --  Quita la espera de respuesta de C: sigue sin haber ciclos.
   procedure Clear_Wait (C : Thread_Id) with
     Global => (In_Out => Waiting),
     Pre    => Acyclic (Waiting),
     Post   => Waiting = (Waiting'Old with delta C => 0) and then Acyclic (Waiting)
   is
      Old_W : constant Thread_Link := Waiting with Ghost;
   begin
      Waiting (C) := 0;
      Lemma_Remove (Old_W, Waiting, C);
   end Clear_Wait;

   function Invariant return Boolean is
     ((for all E in Endpoint_Id =>
         Queue_Ok (Table (E), E, Where)
         and then (if Pending (E) then Table (E).Mode /= Receivers)
         and then Receivers_Free (Table (E), Reply_To))
      and then Links_Ok (Reply_To, Waiting, Where, Held)
      and then (for all T in Thread_Id => (if Calling (T) then Where (T) /= 0))
      and then Acyclic (Waiting));

   function Queues return Queue_Array is (Table);

   function Signals return Signal_Array is (Pending);

   function Replies return Thread_Link is (Reply_To);

   function Awaited return Thread_Link is (Waiting);

   function Callers return Call_Flags is (Calling);

   function Deferred return Call_Flags is (Held);

   function Is_Waiting (T : Thread_Id) return Boolean is (Where (T) /= 0);

   --  Quita el elemento K, que deja de estar en espera.
   procedure Remove_At (E : Endpoint_Id; K : Queue_Index) with
     Pre  => Invariant and then K <= Table (E).Length,
     Post =>
       Invariant
       and then Where (Table'Old (E).Items (K)) = 0
       and then
         (for all X in Thread_Id =>
            (if X /= Table'Old (E).Items (K) then Where (X) = Where'Old (X)))
       and then (for all X in Endpoint_Id => (if X /= E then Table (X) = Table'Old (X)))
       and then Table (E).Length = Table'Old (E).Length - 1
       and then Table (E).Mode = (if Table (E).Length = 0 then Idle else Table'Old (E).Mode)
       and then
         (for all I in Queue_Index =>
            (if I < K then Table (E).Items (I) = Table'Old (E).Items (I)
             elsif I < Table'Old (E).Length
             then Table (E).Items (I) = Table'Old (E).Items (I + 1)))
   is
      Old_Q  : constant Wait_Queue := Table (E) with Ghost;
      Q      : Wait_Queue := Table (E);
      Thread : constant Thread_Id := Table (E).Items (K);
      Last   : constant Queue_Index := Table (E).Length;
   begin
      for I in K .. Last - 1 loop
         Q.Items (I) := Q.Items (I + 1);

         pragma Loop_Invariant (Q.Length = Old_Q.Length and then Q.Mode = Old_Q.Mode);
         pragma Loop_Invariant
           (for all J in Queue_Index =>
              (if J < K then Q.Items (J) = Old_Q.Items (J)
               elsif J <= I then Q.Items (J) = Old_Q.Items (J + 1)
               else Q.Items (J) = Old_Q.Items (J)));
      end loop;

      Q.Length := Last - 1;
      if Q.Length = 0 then
         Q.Mode := Idle;
      end if;

      pragma Assert
        (for all I in Queue_Index =>
           (if I <= Q.Length
            then Q.Items (I) in Thread_Id
                 and then Q.Items (I) /= Thread
                 and then Where (Q.Items (I)) = Tag_Of (E)));
      pragma Assert (Receivers_Free (Q, Reply_To));

      Table (E) := Q;
      Where (Thread) := 0;
      Calling (Thread) := False;

      pragma Assert (Queue_Ok (Table (E), E, Where));
   end Remove_At;

   --  Añade T al final de la cola de E.
   procedure Append (E : Endpoint_Id; T : Thread_Id; Mode : Queue_Mode) with
     Pre  =>
       Invariant
       and then Mode /= Idle
       and then Where (T) = 0
       and then Waiting (T) = 0
       and then (if Mode = Receivers then Reply_To (T) = 0)
       and then Table (E).Length < Queue_Length'Last
       and then (Table (E).Mode = Idle or else Table (E).Mode = Mode)
       and then (if Mode = Receivers then not Pending (E)),
     Post =>
       Invariant
       and then Appended (Table'Old (E), Table (E), T, Mode)
       and then (for all X in Endpoint_Id => (if X /= E then Table (X) = Table'Old (X)))
   is
      New_Length : constant Queue_Index := Table (E).Length + 1;
   begin
      --  T no está en ninguna cola: si lo estuviera, Where (T) no sería 0.
      pragma Assert
        (for all I in Queue_Index =>
           (if I <= Table (E).Length then Table (E).Items (I) /= T));

      Table (E).Items (New_Length) := T;
      Table (E).Length := New_Length;
      Table (E).Mode := Mode;
      Where (T) := Tag_Of (E);

      pragma Assert (Queue_Ok (Table (E), E, Where));
   end Append;

   procedure Meet
     (E      : Endpoint_Id;
      T      : Thread_Id;
      Mine   : Queue_Mode;
      Theirs : Queue_Mode;
      Result : out U64)
   with
     Pre  =>
       Invariant
       and then Mine /= Idle
       and then Theirs /= Idle
       and then Mine /= Theirs
       and then Mine /= Receivers,
     Post =>
       Invariant
       and then Pending = Pending'Old
       and then
         (if Result = Result_Queued
          then Table'Old (E).Mode /= Theirs and then Appended (Table'Old (E), Table (E), T, Mine)
          elsif Result /= Result_Invalid
          then Table'Old (E).Mode = Theirs
            and then Result = U64 (Table'Old (E).Items (1))
            and then Shifted (Table'Old (E), Table (E)))
   is
   begin
      if Where (T) /= 0 or else Waiting (T) /= 0 then
         Result := Result_Invalid;
      elsif Table (E).Mode = Theirs then
         Result := U64 (Table (E).Items (1));
         Remove_At (E, 1);
      elsif Table (E).Length = Queue_Length'Last then
         Result := Result_Invalid;
      else
         Append (E, T, Mine);
         Result := Result_Queued;
      end if;
   end Meet;

   --  Crea el enlace de una llamada entre dos hilos que no están en ninguna cola.
   procedure Link (Server, Caller : Thread_Id) with
     Pre  =>
       Invariant
       and then Server /= Caller
       and then Reply_To (Server) = 0
       and then Waiting (Caller) = 0
       and then Waiting (Server) = 0
       and then Where (Server) = 0
       and then Where (Caller) = 0,
     Post =>
       Invariant
       and then Reply_To (Server) = Caller
       and then Waiting (Caller) = Server
   is
      Old_W : constant Thread_Link := Waiting with Ghost;
   begin
      Reply_To (Server) := Caller;
      Waiting (Caller)  := Server;
      --  El servidor no espera a nadie: el enlace nuevo no cierra un ciclo.
      Lemma_Add (Old_W, Waiting, Caller, Server);
   end Link;

   function Send (Endpoint, Thread : U64) return U64 is
      Result : U64;
   begin
      if not Valid_Endpoint (Endpoint) or else not Valid_Thread (Thread) then
         return Result_Invalid;
      end if;
      Meet (Endpoint_Id (Endpoint), Thread_Id (Thread), Senders, Receivers, Result);
      return Result;
   end Send;

   function Recv (Endpoint, Thread : U64) return U64 is
      E : Endpoint_Id;
      T : Thread_Id;
   begin
      if not Valid_Endpoint (Endpoint) or else not Valid_Thread (Thread) then
         return Result_Invalid;
      end if;

      E := Endpoint_Id (Endpoint);
      T := Thread_Id (Thread);
      if Where (T) /= 0 or else Waiting (T) /= 0 or else Reply_To (T) /= 0 then
         return Result_Invalid;
      end if;

      --  La señal va primero: el kernel no puede esperar a que se vacíe la cola.
      if Pending (E) then
         Pending (E) := False;
         return Result_Signal;
      end if;

      if Table (E).Mode = Senders then
         declare
            Sender   : constant Thread_Id := Table (E).Items (1);
            Was_Call : constant Boolean := Calling (Sender);
         begin
            pragma Assert (Sender /= T);
            Remove_At (E, 1);
            if Was_Call then
               Link (T, Sender);
            end if;
            return U64 (Sender);
         end;
      end if;

      if Table (E).Length = Queue_Length'Last then
         return Result_Invalid;
      end if;

      Append (E, T, Receivers);
      return Result_Queued;
   end Recv;

   function Call (Endpoint, Thread : U64) return U64 is
      E : Endpoint_Id;
      T : Thread_Id;
   begin
      if not Valid_Endpoint (Endpoint) or else not Valid_Thread (Thread) then
         return Result_Invalid;
      end if;

      E := Endpoint_Id (Endpoint);
      T := Thread_Id (Thread);
      if Where (T) /= 0 or else Waiting (T) /= 0 then
         return Result_Invalid;
      end if;

      if Table (E).Mode = Receivers then
         declare
            Server : constant Thread_Id := Table (E).Items (1);
         begin
            pragma Assert (Server /= T);
            --  Estaba en cola, así que no esperaba ninguna respuesta.
            pragma Assert (Waiting (Server) = 0);
            Remove_At (E, 1);
            Link (Server, T);
            return U64 (Server);
         end;
      end if;

      if Table (E).Length = Queue_Length'Last then
         return Result_Invalid;
      end if;

      Append (E, T, Senders);
      Calling (T) := True;
      return Result_Queued;
   end Call;

   function Reply (Thread : U64) return U64 is
      T : Thread_Id;
   begin
      if not Valid_Thread (Thread) then
         return Result_Invalid;
      end if;

      T := Thread_Id (Thread);
      if Reply_To (T) = 0 then
         return Result_Invalid;
      end if;

      declare
         Caller : constant Thread_Id := Reply_To (T);
      begin
         Reply_To (T) := 0;
         Clear_Wait (Caller);
         return U64 (Caller);
      end;
   end Reply;

   function Defer (Thread : U64) return U64 is
      T : Thread_Id;
   begin
      if not Valid_Thread (Thread) then
         return Result_Invalid;
      end if;

      T := Thread_Id (Thread);
      if Reply_To (T) = 0 then
         return Result_Invalid;
      end if;

      declare
         Caller : constant Thread_Id := Reply_To (T);
      begin
         Reply_To (T)  := 0;
         Held (Caller) := True;
         return U64 (Caller);
      end;
   end Defer;

   function Reply_Held (Thread, Caller : U64) return U64 is
      C : Thread_Id;
   begin
      if not Valid_Thread (Thread) or else not Valid_Thread (Caller) then
         return Result_Invalid;
      end if;

      C := Thread_Id (Caller);
      if not Held (C) or else Waiting (C) /= Thread_Slot (Thread) then
         return Result_Invalid;
      end if;

      Clear_Wait (C);
      Held (C) := False;
      return Caller;
   end Reply_Held;

   function Abort_Held (Thread : U64) return U64 is
   begin
      if not Valid_Thread (Thread) then
         return Result_Invalid;
      end if;

      for C in Thread_Id loop
         if Held (C) and then Waiting (C) = Thread_Slot (Thread) then
            Clear_Wait (C);
            Held (C)    := False;
            return U64 (C);
         end if;

         pragma Loop_Invariant
           (for all X in Thread_Id range 1 .. C =>
              (if Held (X) then Waiting (X) /= Thread_Slot (Thread)));
      end loop;

      return Result_Invalid;
   end Abort_Held;

   procedure Lemma_Acyclic is
   begin
      null;
   end Lemma_Acyclic;

   function Waits_For (Thread : U64) return U64 is
     (if Valid_Thread (Thread) then U64 (Waiting (Thread_Id (Thread))) else 0);

   function Abort_Sender (Endpoint : U64) return U64 is
      E      : Endpoint_Id;
      Result : U64;
   begin
      if not Valid_Endpoint (Endpoint) then
         return Result_Invalid;
      end if;

      E := Endpoint_Id (Endpoint);
      if Table (E).Mode /= Senders then
         return Result_Not_Ready;
      end if;

      Result := U64 (Table (E).Items (1));
      Remove_At (E, 1);
      return Result;
   end Abort_Sender;

   function Try_Send (Endpoint : U64) return U64 is
      E      : Endpoint_Id;
      Result : U64;
   begin
      if not Valid_Endpoint (Endpoint) then
         return Result_Invalid;
      end if;

      E := Endpoint_Id (Endpoint);
      if Table (E).Mode /= Receivers then
         return Result_Not_Ready;
      end if;

      Result := U64 (Table (E).Items (1));
      Remove_At (E, 1);
      return Result;
   end Try_Send;

   function Signal (Endpoint : U64) return U64 is
      E      : Endpoint_Id;
      Result : U64;
   begin
      if not Valid_Endpoint (Endpoint) then
         return Result_Invalid;
      end if;

      E := Endpoint_Id (Endpoint);
      if Table (E).Mode /= Receivers then
         Pending (E) := True;
         return Result_Queued;
      end if;

      Result := U64 (Table (E).Items (1));
      Remove_At (E, 1);
      return Result;
   end Signal;

   function Clear_Signal (Endpoint : U64) return U64 is
   begin
      if not Valid_Endpoint (Endpoint) then
         return Status_Invalid;
      end if;
      Pending (Endpoint_Id (Endpoint)) := False;
      return Status_Ok;
   end Clear_Signal;

   function Cancel (Thread : U64) return U64 is
      T     : Thread_Id;
      E     : Endpoint_Id;
      Found : Queue_Length := 0;
   begin
      if not Valid_Thread (Thread) then
         return Status_Invalid;
      end if;

      T := Thread_Id (Thread);
      if Waiting (T) /= 0 then
         declare
            Server : constant Thread_Id := Waiting (T);
         begin
            --  Si su respuesta estaba aplazada, la actual del servidor es de otro.
            if Reply_To (Server) = T then
               Reply_To (Server) := 0;
            end if;
            Clear_Wait (T);
            Held (T)    := False;
            return Status_Ok;
         end;
      end if;

      if Where (T) = 0 then
         return Status_Not_Waiting;
      end if;

      E := Endpoint_Id (Where (T) - 1);
      for I in Queue_Index range 1 .. Queue_Index'Last loop
         pragma Loop_Invariant (Found = 0);
         if I <= Table (E).Length and then Table (E).Items (I) = T then
            Found := I;
            exit;
         end if;
      end loop;

      if Found = 0 then
         --  La invariante solo enlaza de cola a hilo: este caso no se descarta.
         return Status_Invalid;
      end if;

      Remove_At (E, Found);
      return Status_Ok;
   end Cancel;

end Ipc_Core;
