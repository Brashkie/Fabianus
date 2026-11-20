pragma Unevaluated_Use_Of_Old (Allow);

package body Inherit_Gate with
  SPARK_Mode
is
   subtype Slot is Ipc_Core.Thread_Slot;

   function Iter (W : Ipc_Core.Thread_Link; T : Slot; K : Chain_Steps) return Slot
     renames Ipc_Core.Iter;

   --  Lemas de las cadenas de espera.

   --  Un paso más es Step del anterior.
   procedure Lemma_Unfold (W : Ipc_Core.Thread_Link; K : Chain_Steps) with
     Ghost,
     Global => null,
     Pre    => K >= 1,
     Post   => (for all X in Slot => Iter (W, X, K) = Ipc_Core.Step (W, Iter (W, X, K - 1)))
   is
   begin
      null;
   end Lemma_Unfold;

   --  Dar K pasos y luego J es dar K + J.
   procedure Lemma_Shift (W : Ipc_Core.Thread_Link; X : Slot; K, J : Chain_Steps) with
     Ghost,
     Global             => null,
     Pre                => K + J <= Chain_Steps'Last,
     Post               => Iter (W, Iter (W, X, K), J) = Iter (W, X, K + J),
     Subprogram_Variant => (Decreases => J)
   is
   begin
      if J >= 1 then
         Lemma_Shift (W, X, K, J - 1);
         Lemma_Unfold (W, J);
         Lemma_Unfold (W, K + J);
      end if;
   end Lemma_Shift;

   --  Sin ciclos, ningún eslabón vivo de una cadena se repite más abajo.
   procedure Lemma_Distinct (W : Ipc_Core.Thread_Link; X : Slot; J : Chain_Steps) with
     Ghost,
     Global => null,
     Pre    => Ipc_Core.Acyclic (W),
     Post   =>
       (for all K in Chain_Steps range 0 .. J =>
          (if K < J and then Iter (W, X, K) /= 0 then Iter (W, X, K) /= Iter (W, X, J)))
   is
   begin
      for K in Chain_Steps range 0 .. J loop
         if K < J then
            Lemma_Shift (W, X, K, J - K);
         end if;
         pragma Loop_Invariant
           (for all P in Chain_Steps range 0 .. K =>
              (if P < J and then Iter (W, X, P) /= 0 then Iter (W, X, P) /= Iter (W, X, J)));
      end loop;
   end Lemma_Distinct;

   --  Una cadena que llega a 0 se queda en 0.
   procedure Lemma_Stays_Zero (W : Ipc_Core.Thread_Link; X : Slot; I : Chain_Steps) with
     Ghost,
     Global => null,
     Pre    => Iter (W, X, I) = 0,
     Post   => (for all K in Chain_Steps range I .. Chain_Steps'Last => Iter (W, X, K) = 0)
   is
   begin
      for K in Chain_Steps range I .. Chain_Steps'Last loop
         Lemma_Shift (W, X, I, K - I);
         pragma Loop_Invariant
           (for all P in Chain_Steps range I .. K => Iter (W, X, P) = 0);
      end loop;
   end Lemma_Stays_Zero;

   --  Si solo cambia el nivel de Cur, y Cur no es ni X ni cliente de X, la
   --  regla para X sigue igual.
   procedure Lemma_Keep (Old_A, New_A : Level_Array; X, Cur : Thread_Id) with
     Ghost,
     Global => (Proof_In => Ipc_Core.State),
     Pre    =>
       Inherits_With (Old_A, X)
       and then X /= Cur
       and then not Waits (Cur, X)
       and then (for all T in Thread_Id => (if T /= Cur then New_A (T) = Old_A (T))),
     Post   => Inherits_With (New_A, X)
   is
   begin
      null;
   end Lemma_Keep;

   --  Lemma_Keep para todos los eslabones de la cadena por encima de I,
   --  cuando solo cambia el nivel del eslabón I.
   procedure Lemma_Keep_Chain
     (Old_A, New_A : Level_Array; W : Ipc_Core.Thread_Link; X : Slot; I : Chain_Steps)
   with
     Ghost,
     Global => (Proof_In => Ipc_Core.State),
     Pre    =>
       W = Ipc_Core.Awaited
       and then I < Chain_Steps'Last
       and then Iter (W, X, I) /= 0
       and then Iter (W, X, I + 1) = Ipc_Core.Step (W, Iter (W, X, I))
       and then
         (for all K in Chain_Steps range 0 .. I =>
            (if K < I and then Iter (W, X, K) /= 0
             then Iter (W, X, K) /= Iter (W, X, I)
               and then Iter (W, X, K) /= Iter (W, X, I + 1)
               and then Inherits_With (Old_A, Iter (W, X, K))))
       and then
         (for all T in Thread_Id =>
            (if T /= Iter (W, X, I) then New_A (T) = Old_A (T))),
     Post   =>
       (for all K in Chain_Steps range 0 .. I =>
          (if K < I and then Iter (W, X, K) /= 0
           then Inherits_With (New_A, Iter (W, X, K))))
   is
   begin
      for K in Chain_Steps range 0 .. I loop
         if K < I and then Iter (W, X, K) /= 0 then
            Lemma_Keep (Old_A, New_A, Iter (W, X, K), Iter (W, X, I));
         end if;
         pragma Loop_Invariant
           (for all P in Chain_Steps range 0 .. K =>
              (if P < I and then Iter (W, X, P) /= 0
               then Inherits_With (New_A, Iter (W, X, P))));
      end loop;
   end Lemma_Keep_Chain;

   -------------
   -- Refresh --
   -------------

   function Refresh (Server : U64) return U64 is
      L : U64 := 0;
      R : U64;
   begin
      if Server = 0
        or else Server > U64 (Thread_Id'Last)
        or else Sched_Gate.Floor_Of (Server) = None
      then
         return Status_Invalid;
      end if;

      declare
         S : constant Thread_Id := Thread_Id (Server);
      begin
         for C in Thread_Id loop
            if Ipc_Core.Waits_For (Ipc_Core.U64 (C)) = Ipc_Core.U64 (S) then
               declare
                  P : constant U64 := Sched_Gate.Priority_Of (U64 (C));
               begin
                  if P /= None and then P > L then
                     L := P;
                  end if;
               end;
            end if;
            pragma Loop_Invariant (L < U64 (Scheduler_Core.Levels));
            pragma Loop_Invariant (Ipc_Core.Acyclic (Ipc_Core.Awaited));
            pragma Loop_Invariant
              (for all D in Thread_Id'First .. C =>
                 (if Waits (D, S) and then Level (D) /= None then Level (D) <= L));
            pragma Loop_Invariant
              (L = 0
               or else (for some D in Thread_Id'First .. C =>
                          Waits (D, S) and then Level (D) = L));
         end loop;

         --  Nadie se espera a sí mismo.
         pragma Assert (Ipc_Core.Step (Ipc_Core.Awaited, Slot (S)) /= Slot (S));
         pragma Assert (not Waits (S, S));
         pragma Assert (Is_Needed (S, L));

         if Sched_Gate.Floor_Of (Server) = L then
            return Status_Ok;
         end if;

         declare
            Old_Levels : constant Level_Array := All_Levels with Ghost;
         begin
            R := Sched_Gate.Boost (Server, L);
            pragma Assert (R = Status_Ok or else R >= Sched_Gate.Notify_Base);
            pragma Assert
              (for all T in Thread_Id =>
                 (if T /= S then All_Levels (T) = Old_Levels (T)));
            pragma Assert (Sched_Gate.Floor_Of (Server) = L);
         end;
         return R;
      end;
   end Refresh;

   -------------------
   -- Refresh_Chain --
   -------------------

   function Refresh_Chain (Server : U64; Notify : out U64) return U64 is
      W    : constant Ipc_Core.Thread_Link := Ipc_Core.Awaited with Ghost;
      Shared : constant Sched_Gate.Shared_Data := Sched_Gate.Shared_View with Ghost;
      Cur  : Slot;
      Next : Ipc_Core.U64;
      R    : U64;
      I    : Chain_Steps := 0;
   begin
      Notify := 0;
      if Server > U64 (Thread_Id'Last) then
         return Status_Invalid;
      end if;
      if Server = 0 then
         return Status_Ok;
      end if;

      Cur := Slot (Server);
      Ipc_Core.Lemma_Acyclic;

      loop
         pragma Loop_Invariant (Sched_Gate.Invariant);
         pragma Loop_Invariant (Sched_Gate.Shared_View = Shared);
         pragma Loop_Invariant (Cur = Iter (W, Slot (Server), I));
         pragma Loop_Invariant
           (for all K in Chain_Steps range 0 .. I =>
              (if K < I and then Iter (W, Slot (Server), K) /= 0
               then Inherits (Iter (W, Slot (Server), K))));
         pragma Loop_Variant (Increases => I);

         exit when Cur = 0 or else I = Chain_Steps'Last;

         Next := Ipc_Core.Waits_For (Ipc_Core.U64 (Cur));
         Lemma_Unfold (W, I + 1);
         pragma Assert (Next = Ipc_Core.U64 (Iter (W, Slot (Server), I + 1)));
         Lemma_Distinct (W, Slot (Server), I);
         Lemma_Distinct (W, Slot (Server), I + 1);

         declare
            Old_A : constant Level_Array := All_Levels with Ghost;
         begin
            R := Refresh (U64 (Cur));
            if R = Status_Ok or else R >= Sched_Gate.Notify_Base then
               Lemma_Keep_Chain (Old_A, All_Levels, W, Slot (Server), I);
            end if;
         end;
         if R >= Sched_Gate.Notify_Base and then R - Sched_Gate.Notify_Base <= Sched_Gate.Last_Hart then
            Notify := Notify or 2 ** Natural (R - Sched_Gate.Notify_Base);
         elsif R /= Status_Ok then
            return R;
         end if;

         Cur := Slot (Next);
         I := I + 1;
      end loop;

      if Cur /= 0 then
         return Status_Cycle;
      end if;
      Lemma_Stays_Zero (W, Slot (Server), I);
      return Status_Ok;
   end Refresh_Chain;

   -----------
   -- Holds --
   -----------

   function Holds return U64 is
   begin
      for C in Thread_Id loop
         declare
            S : constant Ipc_Core.U64 := Ipc_Core.Waits_For (Ipc_Core.U64 (C));
         begin
            if S /= 0 then
               declare
                  PC : constant U64 := Sched_Gate.Priority_Of (U64 (C));
                  PS : constant U64 := Sched_Gate.Priority_Of (U64 (S));
               begin
                  if PC /= None and then (PS = None or else PS < PC) then
                     pragma Assert (Waits (C, Thread_Id (S)));
                     pragma Assert (not Inherits (Thread_Id (S)));
                     return 0;
                  end if;
               end;
            end if;
         end;
         pragma Loop_Invariant
           (for all D in Thread_Id'First .. C =>
              (if Ipc_Core.Awaited (D) /= 0 and then Level (D) /= None
               then Level (Ipc_Core.Awaited (D)) /= None
                 and then Level (Ipc_Core.Awaited (D)) >= Level (D)));
      end loop;
      return 1;
   end Holds;

end Inherit_Gate;
