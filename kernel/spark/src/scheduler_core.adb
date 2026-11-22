--  SPDX-License-Identifier: GPL-3.0-or-later
package body Scheduler_Core with
  SPARK_Mode
is

   procedure Lemma_And (X, Y : Mask; T : Thread_Id) with
     Ghost,
     Post => Has (X and Y, T) = (Has (X, T) and then Has (Y, T))
   is
   begin
      null;
   end Lemma_And;

   procedure Lemma_Without (X : Mask; R, T : Thread_Id) with
     Ghost,
     Post => Has (X and not Bits (R), T) = (Has (X, T) and then T /= R)
   is
   begin
      pragma Assert (((Bits (R) and Bits (T)) /= 0) = (R = T));
   end Lemma_Without;

   procedure Lemma_With (X : Mask; R, T : Thread_Id) with
     Ghost,
     Post => Has (X or Bits (R), T) = (Has (X, T) or else T = R)
   is
   begin
      pragma Assert (((Bits (R) and Bits (T)) /= 0) = (R = T));
   end Lemma_With;

   procedure Lemma_Nonzero (X : Mask) with
     Ghost,
     Post => (X /= 0) = (for some T in Thread_Id => Has (X, T))
   is
   begin
      pragma Assert
        (if X /= 0
         then Has (X, 0) or else Has (X, 1) or else Has (X, 2)
           or else Has (X, 3) or else Has (X, 4) or else Has (X, 5)
           or else Has (X, 6) or else Has (X, 7));
   end Lemma_Nonzero;

   --  El conjunto de un nivel son exactamente sus hilos elegibles.
   procedure Lemma_Level_Set (M : Model; L : Priority) with
     Ghost,
     Pre  => Coherent (M) and then Members_Ok (M),
     Post =>
       (for all T in Thread_Id =>
          Has (M.Eligible_Set and M.Members (L), T)
          = (Eligible (M, T) and then Level_Of (M, T) = L))
   is
   begin
      for T in Thread_Id loop
         Lemma_And (M.Eligible_Set, M.Members (L), T);
         pragma Loop_Invariant
           (for all G in Thread_Id range 0 .. T =>
              Has (M.Eligible_Set and M.Members (L), G)
              = (Eligible (M, G) and then Level_Of (M, G) = L));
      end loop;
   end Lemma_Level_Set;

   --  Vuelve a calcular si X es elegible tras cambiar algo que le afecta.
   procedure Refresh (M : in out Model; X : Thread_Id) with
     Inline,
     Pre  => Coherent_Except (M, X),
     Post =>
       Coherent (M)
       and then M = (M'Old with delta Eligible_Set => M.Eligible_Set)
   is
      Old_Set : constant Mask := M.Eligible_Set with Ghost;
   begin
      if Eligible (M, X) then
         M.Eligible_Set := M.Eligible_Set or Bits (X);
         for T in Thread_Id loop
            Lemma_With (Old_Set, X, T);
            pragma Loop_Invariant
              (for all G in Thread_Id range 0 .. T =>
                 Has (M.Eligible_Set, G) = (Has (Old_Set, G) or else G = X));
         end loop;
      else
         M.Eligible_Set := M.Eligible_Set and not Bits (X);
         for T in Thread_Id loop
            Lemma_Without (Old_Set, X, T);
            pragma Loop_Invariant
              (for all G in Thread_Id range 0 .. T =>
                 Has (M.Eligible_Set, G) = (Has (Old_Set, G) and then G /= X));
         end loop;
      end if;
   end Refresh;

   --  X pasa del nivel Old al de su prioridad efectiva actual, que queda
   --  guardada. Los demás ya tenían la suya.
   procedure Move_Level (M : in out Model; X : Thread_Id; Old : Priority) with
     Inline,
     Pre  =>
       Members_Ok_Except (M, X)
       and then (for all L in Priority => Has (M.Members (L), X) = (L = Old))
       and then (for all T in Thread_Id => (if T /= X then M.Levels (T) = Effective (M, T))),
     Post =>
       Members_Ok (M)
       and then Levels_Ok (M)
       and then
         M
         = (M'Old with delta
              Members => M.Members,
              Levels  => (M'Old.Levels with delta X => Effective (M'Old, X)))
   is
      Target : constant Priority := Effective (M, X);
   begin
      M.Levels (X) := Target;
      if Target = Old then
         return;
      end if;

      declare
         From : constant Mask := M.Members (Old);
         To   : constant Mask := M.Members (Target);
      begin
         for T in Thread_Id loop
            Lemma_Without (From, X, T);
            Lemma_With (To, X, T);
            pragma Loop_Invariant
              (for all G in Thread_Id range 0 .. T =>
                 Has (From and not Bits (X), G) = (Has (From, G) and then G /= X)
                 and then Has (To or Bits (X), G) = (Has (To, G) or else G = X));
         end loop;
         M.Members (Old)    := From and not Bits (X);
         M.Members (Target) := To or Bits (X);
      end;
   end Move_Level;

   --  Recalcula y guarda todos los niveles. Solo en operaciones poco
   --  frecuentes, o que cambian el contexto de varios hilos.
   procedure Recompute_Members (M : in out Model) with
     Post =>
       Members_Ok (M)
       and then Levels_Ok (M)
       and then M = (M'Old with delta Members => M.Members, Levels => M.Levels)
   is
   begin
      M.Members := (others => 0);
      pragma Assert
        (for all K in Priority =>
           (for all G in Thread_Id => not Has (M.Members (K), G)));

      for T in Thread_Id loop
         declare
            L      : constant Priority := Effective (M, T);
            Before : constant Mask := M.Members (L);
         begin
            for X in Thread_Id loop
               Lemma_With (Before, T, X);
               pragma Loop_Invariant
                 (for all G in Thread_Id range 0 .. X =>
                    Has (Before or Bits (T), G)
                    = (Has (Before, G) or else G = T));
            end loop;
            M.Members (L) := Before or Bits (T);
            M.Levels (T)  := L;
         end;

         pragma Loop_Invariant
           (for all K in Priority =>
              (for all G in Thread_Id =>
                 Has (M.Members (K), G)
                 = (G <= T and then Effective (M, G) = K)));
         pragma Loop_Invariant
           (for all G in Thread_Id range 0 .. T => M.Levels (G) = Effective (M, G));
         pragma Loop_Invariant
           (M = (M'Loop_Entry with delta Members => M.Members, Levels => M.Levels));
      end loop;
   end Recompute_Members;

   procedure Recompute (M : in out Model) with
     Post =>
       Coherent (M)
       and then M = (M'Old with delta Eligible_Set => M.Eligible_Set)
   is
   begin
      M.Eligible_Set := 0;
      for T in Thread_Id loop
         if Eligible (M, T) then
            declare
               Before : constant Mask := M.Eligible_Set;
            begin
               for X in Thread_Id loop
                  Lemma_With (Before, T, X);
                  pragma Loop_Invariant
                    (for all G in Thread_Id range 0 .. X =>
                       Has (Before or Bits (T), G)
                       = (Has (Before, G) or else G = T));
               end loop;
               M.Eligible_Set := Before or Bits (T);
            end;
         end if;

         pragma Loop_Invariant
           (for all G in Thread_Id =>
              Has (M.Eligible_Set, G)
              = (G <= T and then Eligible (M, G)));
         pragma Loop_Invariant
           (M = (M'Loop_Entry with delta Eligible_Set => M.Eligible_Set));
      end loop;
   end Recompute;

   --  La prioridad más alta entre los hilos elegibles.
   function Top_Level (M : Model) return Priority with
     Pre  => Coherent (M) and then Members_Ok (M) and then M.Eligible_Set /= 0,
     Post =>
       (for some T in Thread_Id =>
          Eligible (M, T) and then Level_Of (M, T) = Top_Level'Result)
       and then
         (for all T in Thread_Id =>
            (if Eligible (M, T) then Level_Of (M, T) <= Top_Level'Result))
   is
      Result : Priority;
   begin
      Lemma_Nonzero (M.Eligible_Set);

      for L in reverse Priority loop
         Lemma_Level_Set (M, L);
         Lemma_Nonzero (M.Eligible_Set and M.Members (L));
         Result := L;
         exit when (M.Eligible_Set and M.Members (L)) /= 0;

         pragma Loop_Invariant
           (for all T in Thread_Id =>
              (if Eligible (M, T) then Level_Of (M, T) < L));
      end loop;

      return Result;
   end Top_Level;

   --  El siguiente elegible del nivel, en orden circular desde el cursor.
   procedure Next_In_Level
     (M      : Model;
      Level  : Priority;
      Cursor : Thread_Id;
      Next   : out Thread_Id)
   with
     Pre  =>
       Coherent (M)
       and then Members_Ok (M)
       and then
         (for some T in Thread_Id =>
            Eligible (M, T) and then Level_Of (M, T) = Level),
     Post =>
       Eligible (M, Next)
       and then Level_Of (M, Next) = Level
       and then In_Turn (Cursor, M, Next)
   is
      Set : constant Mask := M.Eligible_Set and M.Members (Level);
   begin
      Lemma_Level_Set (M, Level);
      pragma Assert
        (for all T in Thread_Id => Successor (Cursor, Distance (Cursor, T)) = T);

      for K in Step loop
         Next := Successor (Cursor, K);
         if Has (Set, Next) then
            pragma Assert (Distance (Cursor, Next) = K);
            return;
         end if;

         pragma Loop_Invariant
           (for all T in Thread_Id =>
              (if Distance (Cursor, T) <= K
               then not (Eligible (M, T) and then Level_Of (M, T) = Level)));
      end loop;

      pragma Assert
        (for all T in Thread_Id =>
           not (Eligible (M, T) and then Level_Of (M, T) = Level));
      pragma Assert (False);
   end Next_In_Level;

   procedure Charge (M : in out Model; D : Units) is
      P    : constant Thread_Id := Payer (M);
      User : constant Thread_Id := M.Lent (P);
      Cost : constant Units := Spent (M, D);
   begin
      --  Solo el último usuario del contexto puede cambiar de elegibilidad: su
      --  dueño, si lo ha prestado, y los demás usuarios están bloqueados.
      pragma Assert (if User /= P then M.Ctx (User) = P);
      pragma Assert (if User /= P then M.States (P) = Blocked);
      pragma Assert
        (for all T in Thread_Id =>
           (if T /= User and then M.Ctx (T) = P then M.States (T) = Blocked));

      M.Debt (P)      := Indebted (M, D) (P);
      M.Remaining (P) := M.Remaining (P) - Cost;
      pragma Assert (Coherent_Except (M, User));
      Refresh (M, User);
   end Charge;

   procedure Schedule (M : in out Model; D : Units; Next : out Thread_Id) is
      Before      : constant Model := M with Ghost;
      Old_Cursors : constant Cursor_Table := M.Cursors with Ghost;
      Level       : Priority;
   begin
      Charge (M, D);
      pragma Assert
        (for all T in Thread_Id =>
           Eligible (M, T) = Eligible (Charged_Model (Before, D), T));
      Lemma_Nonzero (M.Eligible_Set);
      pragma Assert
        ((M.Eligible_Set /= 0) = Any_Eligible (Charged_Model (Before, D)));

      if M.Eligible_Set = 0 then
         pragma Assert (Refilled (M) = Refilled (Charged_Model (Before, D)));
         pragma Assert (Repaid (M) = Repaid (Charged_Model (Before, D)));
         declare
            New_Remaining : constant Unit_Table := Refilled (M);
            New_Debt      : constant Unit_Table := Repaid (M);
         begin
            M.Remaining := New_Remaining;
            M.Debt      := New_Debt;
         end;
         Recompute (M);
         pragma Assert (M.States (M.Ctx (0)) /= Free);
         pragma Assert (Eligible (M, 0));
      end if;
      Lemma_Nonzero (M.Eligible_Set);
      pragma Assert (M.Eligible_Set /= 0);

      Level := Top_Level (M);
      Next_In_Level (M, Level, M.Cursors (Level), Next);

      M.Cursors (Level) := Next;
      M.Running         := Next;
      pragma Assert (M.Cursors = (Old_Cursors with delta Level => Next));
   end Schedule;

   function Top_Now (M : Model; X : Thread_Id) return Boolean is
      Own : Priority;
   begin
      if not Has (M.Eligible_Set, X) then
         return False;
      end if;

      Own := Level_Of (M, X);
      for L in reverse Priority loop
         exit when L <= Own;
         Lemma_Level_Set (M, L);
         Lemma_Nonzero (M.Eligible_Set and M.Members (L));
         if (M.Eligible_Set and M.Members (L)) /= 0 then
            return False;
         end if;

         pragma Loop_Invariant
           (for all T in Thread_Id =>
              (if Eligible (M, T) then Level_Of (M, T) < L));
      end loop;

      return True;
   end Top_Now;

   --  A recupera su contexto de todos sus usuarios. Recalcula los niveles: solo
   --  hace falta con cadenas o al terminar un hilo.
   procedure Reclaim (M : in out Model; A : Thread_Id) with
     Pre  => Valid (M) and then M.Ctx (A) = A,
     Post =>
       Valid (M)
       and then M.Lent = (M'Old.Lent with delta A => A)
       and then
         (for all T in Thread_Id =>
            M.Ctx (T)
            = (if M'Old.Ctx (T) = A and then T /= A then T else M'Old.Ctx (T)))
       and then
         (for all T in Thread_Id =>
            M.Depth (T)
            = (if M'Old.Ctx (T) = A and then T /= A then 0 else M'Old.Depth (T)))
       and then M.States = M'Old.States
       and then M.Priorities = M'Old.Priorities
       and then M.Floors = M'Old.Floors
       and then M.Remaining = M'Old.Remaining
       and then M.Debt = M'Old.Debt
       and then M.Budgets = M'Old.Budgets
       and then M.Cursors = M'Old.Cursors
       and then M.Running = M'Old.Running
   is
      Old : constant Model := M with Ghost;
   begin
      for T in Thread_Id loop
         if T /= A and then M.Ctx (T) = A then
            M.Ctx (T)   := T;
            M.Depth (T) := 0;
         end if;
         pragma Loop_Invariant
           (for all U in Thread_Id =>
              M.Ctx (U)
              = (if U <= T and then Old.Ctx (U) = A and then U /= A
                 then U
                 else Old.Ctx (U)));
         pragma Loop_Invariant
           (for all U in Thread_Id =>
              M.Depth (U)
              = (if U <= T and then Old.Ctx (U) = A and then U /= A
                 then 0
                 else Old.Depth (U)));
         pragma Loop_Invariant
           (M = (Old with delta Ctx => M.Ctx, Depth => M.Depth));
      end loop;
      M.Lent (A) := A;
      pragma Assert (Links_Ok (M));
      Recompute_Members (M);
      Recompute (M);
   end Reclaim;

   --  X, que usaba un contexto prestado, vuelve a ser el último de la cadena:
   --  los usuarios con su profundidad o más lo pierden.
   procedure Return_To (M : in out Model; X : Thread_Id) with
     Pre  => Valid (M) and then M.Ctx (X) /= X and then M.States (X) = Blocked,
     Post =>
       Valid (M)
       and then M.Lent = (M'Old.Lent with delta M'Old.Ctx (X) => X)
       and then
         (for all T in Thread_Id =>
            M.Ctx (T)
            = (if M'Old.Ctx (T) = M'Old.Ctx (X)
                 and then T /= M'Old.Ctx (X)
                 and then T /= X
                 and then M'Old.Depth (T) >= M'Old.Depth (X)
               then T
               else M'Old.Ctx (T)))
       and then M.States = M'Old.States
       and then M.Priorities = M'Old.Priorities
       and then M.Floors = M'Old.Floors
       and then M.Remaining = M'Old.Remaining
       and then M.Debt = M'Old.Debt
       and then M.Budgets = M'Old.Budgets
       and then M.Cursors = M'Old.Cursors
       and then M.Running = M'Old.Running
   is
      Old : constant Model := M with Ghost;
      A   : constant Thread_Id := M.Ctx (X);
      Dx  : constant Depth_Value := M.Depth (X);
   begin
      for T in Thread_Id loop
         if T /= A and then T /= X and then M.Ctx (T) = A and then M.Depth (T) >= Dx then
            M.Ctx (T)   := T;
            M.Depth (T) := 0;
         end if;
         pragma Loop_Invariant
           (for all U in Thread_Id =>
              M.Ctx (U)
              = (if U <= T
                   and then Old.Ctx (U) = A
                   and then U /= A
                   and then U /= X
                   and then Old.Depth (U) >= Dx
                 then U
                 else Old.Ctx (U)));
         pragma Loop_Invariant
           (for all U in Thread_Id =>
              M.Depth (U)
              = (if U <= T
                   and then Old.Ctx (U) = A
                   and then U /= A
                   and then U /= X
                   and then Old.Depth (U) >= Dx
                 then 0
                 else Old.Depth (U)));
         pragma Loop_Invariant
           (M = (Old with delta Ctx => M.Ctx, Depth => M.Depth));
      end loop;
      M.Lent (A) := X;
      pragma Assert (Links_Ok (M));
      Recompute_Members (M);
      Recompute (M);
   end Return_To;

   procedure Wake (M : in out Model; X : Thread_Id) is
      Was_Quiet  : constant Boolean := Quiet (M, X) with Ghost;
      Old_Ctx    : constant Link_Table := M.Ctx with Ghost;
      Old_Levels : constant Priority_Table := M.Levels with Ghost;
   begin
      if M.Lent (X) /= X then
         declare
            B : constant Thread_Id := M.Lent (X);
         begin
            if M.Depth (B) = 1 then
               --  Un solo usuario: el caso de una llamada sin cadena.
               declare
                  Old : constant Priority := Level_Of (M, B);
               begin
                  pragma Assert (M.Ctx (B) = X);
                  pragma Assert
                    (for all T in Thread_Id =>
                       (if T /= X and then M.Ctx (T) = X then T = B));
                  M.Ctx (B)   := B;
                  M.Depth (B) := 0;
                  M.Lent (X)  := X;
                  pragma Assert (Links_Ok (M));
                  Move_Level (M, B, Old);
                  Refresh (M, B);
               end;
            else
               Reclaim (M, X);
            end if;
         end;
      elsif M.Ctx (X) /= X and then M.Lent (M.Ctx (X)) /= X then
         --  Respuesta en una cadena: X vuelve a ser el último. Si ya lo era
         --  (acaba de recibir el préstamo), no hay nada que devolver.
         Return_To (M, X);
      end if;

      --  X ya no es un usuario intermedio: puede estar listo.
      pragma Assert (Links_Ok (M));
      pragma Assert (if M.Ctx (X) /= X then M.Lent (M.Ctx (X)) = X);
      pragma Assert (for all T in Thread_Id => (if M.Ctx (T) = X then T = X));
      pragma Assert (if Was_Quiet then M.Ctx = Old_Ctx and then M.Levels = Old_Levels);
      M.States (X) := Ready;
      pragma Assert (Links_Ok (M));
      Refresh (M, X);
      pragma Assert (Valid (M));
      pragma Assert (if Was_Quiet then M.Ctx = Old_Ctx and then M.Levels = Old_Levels);
   end Wake;

   procedure Hand_Off
     (M        : in out Model;
      D        : Units;
      Peer     : Thread_Id;
      Donate   : Boolean;
      Switched : out Boolean)
   is
      From : constant Thread_Id := M.Running;
      R    : constant Thread_Id := M.Ctx (From);
      Give : constant Boolean := Donate and then Donation_Applies (M, Peer);
      Depth_From : constant Depth_Value := M.Depth (From);
   begin
      pragma Assert (if Give then Depth_From < Max_Depth);
      --  Quien está en ejecución no tiene prestado su contexto, y si usa uno
      --  ajeno es el último de esa cadena.
      pragma Assert (M.Lent (From) = From);
      pragma Assert (if R /= From then M.Lent (R) = From);

      Charge (M, D);
      M.States (From) := Blocked;
      Refresh (M, From);

      if Give then
         --  Peer cambia el contexto que tenía por uno más prioritario.
         if M.Ctx (Peer) /= Peer then
            Release (M, Peer);
         end if;

         declare
            Old : constant Priority := Level_Of (M, Peer);
            Before : constant Model := M with Ghost;
         begin
            pragma Assert (M.Ctx (Peer) = Peer and then M.Lent (Peer) = Peer);
            pragma Assert (M.Ctx (From) = R and then M.Lent (From) = From);
            pragma Assert (M.Ctx (R) = R);
            pragma Assert (M.Lent (R) = From);
            pragma Assert
              (for all T in Thread_Id => (if M.Ctx (T) = Peer then T = Peer));
            pragma Assert (M.Depth (From) = Depth_From);
            pragma Assert (M.States (From) = Blocked);
            --  Nadie le había prestado nada a Peer ni lo usaba.
            pragma Assert (for all T in Thread_Id => M.Lent (T) /= Peer or else T = Peer);
            pragma Assert
              (for all T in Thread_Id =>
                 (if M.Ctx (T) = R and then T /= R
                  then M.Depth (T) <= Depth_From and then M.States (T) = Blocked));
            M.Lent (R)    := Peer;
            M.Ctx (Peer)  := R;
            M.Depth (Peer) := Depth_From + 1;
            pragma Assert
              (for all T in Thread_Id =>
                 (if M.Ctx (T) = R and then T /= R and then T /= Peer
                  then M.States (T) = Blocked and then M.Depth (T) < M.Depth (Peer)));
            --  El nuevo eslabón cumple su parte del invariante.
            pragma Assert
              (M.Ctx (R) = R
               and then M.States (R) = Blocked
               and then M.Lent (R) = Peer
               and then M.Ctx (Peer) = R
               and then M.Lent (Peer) = Peer
               and then M.States (Peer) /= Free
               and then M.Depth (Peer) >= 1);
            --  Los usuarios de otros contextos no cambian.
            pragma Assert
              (for all T in Thread_Id =>
                 (if T /= Peer and then Before.Ctx (T) /= R
                  then M.Ctx (T) = Before.Ctx (T)
                    and then M.Lent (Before.Ctx (T)) = Before.Lent (Before.Ctx (T))
                    and then M.Depth (T) = Before.Depth (T)
                    and then M.Depth (Before.Lent (Before.Ctx (T)))
                             = Before.Depth (Before.Lent (Before.Ctx (T)))));
            pragma Assert
              (for all T in Thread_Id =>
                 (if M.Lent (T) /= T then M.Ctx (M.Lent (T)) = T and then M.Ctx (T) = T));
            pragma Assert (Links_Ok (M));
            Move_Level (M, Peer, Old);
            pragma Assert (Links_Ok (M));
         end;
      end if;

      Wake (M, Peer);
      pragma Assert (Valid (M));
      Switched := Top_Now (M, Peer);
      if Switched then
         declare
            Woken : constant Model := M with Ghost;
         begin
            M.Running := Peer;
            --  Valid no depende de quién corre.
            pragma Assert (M = (Woken with delta Running => Peer));
            pragma Assert (Coherent (M) and then Members_Ok (M) and then Links_Ok (M));
         end;
      end if;
   end Hand_Off;

   procedure Release (M : in out Model; X : Thread_Id) is
      A : constant Thread_Id := M.Ctx (X);
   begin
      if M.Lent (A) = X and then M.Depth (X) = 1 then
         --  X es el único usuario: el caso sin cadena.
         declare
            Old : constant Priority := Level_Of (M, X);
         begin
            pragma Assert (M.Lent (X) = X);
            pragma Assert
              (for all T in Thread_Id => (if M.Ctx (T) = A then T = A or else T = X));
            pragma Assert (for all T in Thread_Id => (if M.Ctx (T) = X then T = X));
            M.Lent (A)  := A;
            M.Ctx (X)   := X;
            M.Depth (X) := 0;
            pragma Assert (Links_Ok (M));
            Move_Level (M, X, Old);
            Refresh (M, X);
         end;
      else
         Reclaim (M, A);
      end if;
   end Release;

   procedure Adopt (M : in out Model; X, Client : Thread_Id) is
      R : constant Thread_Id := M.Ctx (Client);
      Depth_Client : constant Depth_Value := M.Depth (Client);
   begin
      if M.Ctx (X) /= X then
         Release (M, X);
      end if;

      declare
         Old : constant Priority := Level_Of (M, X);
      begin
         pragma Assert (M.Lent (X) = X);
         pragma Assert (M.Ctx (X) = X);
         pragma Assert (M.Ctx (Client) = R and then M.Ctx (R) = R);
         pragma Assert (if R /= Client then M.Lent (R) = Client else M.Lent (R) = R);
         pragma Assert (for all T in Thread_Id => (if M.Ctx (T) = X then T = X));
         pragma Assert
           (for all T in Thread_Id =>
              (if M.Ctx (T) = R and then T /= R then M.Depth (T) <= M.Depth (Client)));
         pragma Assert (M.Depth (Client) = Depth_Client);
         M.Lent (R)  := X;
         M.Ctx (X)   := R;
         M.Depth (X) := Depth_Client + 1;
         pragma Assert (Links_Ok (M));
         Move_Level (M, X, Old);
         Refresh (M, X);
      end;
   end Adopt;

   procedure Block (M : in out Model; X : Thread_Id) is
   begin
      M.States (X) := Blocked;
      Refresh (M, X);
   end Block;

   procedure Finish (M : in out Model; X : Thread_Id) is
   begin
      if M.Ctx (X) /= X then
         declare
            A : constant Thread_Id := M.Ctx (X);
         begin
            pragma Assert (M.Lent (X) = X);
            pragma Assert (for all T in Thread_Id => (if M.Ctx (T) = X then T = X));
            if M.Lent (A) = X then
               --  El último de la cadena termina: el dueño recupera su contexto.
               Reclaim (M, A);
            else
               --  Un usuario intermedio, bloqueado, sale de la cadena.
               M.Ctx (X)   := X;
               M.Depth (X) := 0;
               pragma Assert (Links_Ok (M));
            end if;
            pragma Assert (for all T in Thread_Id => M.Ctx (T) /= X or else T = X);
         end;
      elsif M.Lent (X) /= X then
         Reclaim (M, X);
         pragma Assert (for all T in Thread_Id => M.Ctx (T) /= X or else T = X);
      else
         pragma Assert (for all T in Thread_Id => M.Ctx (T) /= X or else T = X);
      end if;

      pragma Assert (M.Ctx (X) = X and then M.Lent (X) = X);
      pragma Assert (for all T in Thread_Id => M.Ctx (T) /= X or else T = X);
      M.States (X)    := Free;
      M.Remaining (X) := 0;
      M.Debt (X)      := 0;
      M.Floors (X)    := 0;
      pragma Assert (Links_Ok (M));
      Recompute_Members (M);
      pragma Assert (Links_Ok (M));
      Recompute (M);
      pragma Assert (Links_Ok (M));
   end Finish;

   procedure Start (M : in out Model; X : Thread_Id) is
   begin
      pragma Assert (M.Ctx (X) = X);
      pragma Assert (M.Lent (X) = X);
      pragma Assert (for all T in Thread_Id => M.Ctx (T) /= X or else T = X);
      M.States (X)     := Ready;
      M.Priorities (X) := Default_Priority;
      M.Floors (X)     := 0;
      M.Budgets (X)    := Default_Budget;
      M.Remaining (X)  := Default_Budget;
      M.Debt (X)       := 0;
      pragma Assert (Links_Ok (M));
      Recompute_Members (M);
      pragma Assert (Links_Ok (M));
      Recompute (M);
      pragma Assert (Links_Ok (M));
   end Start;

   procedure Set_Params
     (M : in out Model; X : Thread_Id; L : Priority; Budget : Budget_Value)
   is
   begin
      M.Priorities (X) := L;
      M.Budgets (X)    := Budget;
      M.Remaining (X)  := Budget;
      M.Debt (X)       := 0;
      pragma Assert (Links_Ok (M));
      Recompute_Members (M);
      pragma Assert (Links_Ok (M));
      Recompute (M);
      pragma Assert (Links_Ok (M));
   end Set_Params;

   --  Solo cambia el nivel de X: el de los demás depende de su propio suelo y
   --  de la prioridad de su contexto, que no cambian.
   procedure Set_Floor (M : in out Model; X : Thread_Id; L : Priority) is
      Old : constant Priority := Level_Of (M, X);
   begin
      M.Floors (X) := L;
      pragma Assert (Members_Ok_Except (M, X));
      Move_Level (M, X, Old);
   end Set_Floor;

   procedure Find_Free
     (States : State_Table;
      Found  : out Boolean;
      Slot   : out Thread_Id)
   is
   begin
      Found := False;
      Slot  := 1;

      for T in Thread_Id range 1 .. Thread_Id'Last loop
         if States (T) = Free then
            Found := True;
            Slot  := T;
            return;
         end if;

         pragma Loop_Invariant
           (for all G in Thread_Id range 1 .. T => States (G) /= Free);
      end loop;
   end Find_Free;

   --  Quitar lo gastado de un elemento baja la suma exactamente en esa cantidad.
   procedure Lemma_Sum_Charged (B : Model; D : Units) with
     Ghost,
     Post =>
       Sum (Charged (B, D)) + Work (Spent (B, D)) = Sum (B.Remaining)
   is
   begin
      case Payer (B) is
         when 0 => null;
         when 1 => null;
         when 2 => null;
         when 3 => null;
         when 4 => null;
         when 5 => null;
         when 6 => null;
         when 7 => null;
      end case;
   end Lemma_Sum_Charged;

   --  Lo gastado sale del contexto que paga, no de S.
   procedure Lemma_Spent_Fits (B : Model; D : Units; S : Thread_Id) with
     Ghost,
     Pre  => S /= Payer (B),
     Post => Work (Spent (B, D)) <= Others_Sum (B.Remaining, S)
   is
   begin
      case S is
         when 0 => null;
         when 1 => null;
         when 2 => null;
         when 3 => null;
         when 4 => null;
         when 5 => null;
         when 6 => null;
         when 7 => null;
      end case;
   end Lemma_Spent_Fits;

   procedure Lemma_Sum_Mono (X, Y : Unit_Table) with
     Ghost,
     Pre  => (for all T in Thread_Id => X (T) <= Y (T)),
     Post => Sum (X) <= Sum (Y)
   is
   begin
      null;
   end Lemma_Sum_Mono;

   --  Más deuda nunca significa más relleno.
   procedure Lemma_Refill_Mono (X, Y : Model) with
     Ghost,
     Pre  =>
       (for all T in Thread_Id =>
          (X.States (T) = Free) = (Y.States (T) = Free))
       and then X.Budgets = Y.Budgets
       and then (for all T in Thread_Id => Y.Debt (T) <= X.Debt (T)),
     Post =>
       (for all T in Thread_Id => Refilled (X) (T) <= Refilled (Y) (T))
   is
   begin
      null;
   end Lemma_Refill_Mono;

   procedure Lemma_Others_Mono (X, Y : Unit_Table; S : Thread_Id) with
     Ghost,
     Pre  =>
       (for all G in Thread_Id => X (G) <= Y (G))
       and then X (S) = Y (S),
     Post => Others_Sum (X, S) <= Others_Sum (Y, S)
   is
   begin
      Lemma_Sum_Mono (X, Y);
   end Lemma_Others_Mono;

   procedure Lemma_Bounded_Wait
     (B : Model; A : Model; D : Units; Next : Thread_Id; T : Thread_Id)
   is
      S     : constant Thread_Id := B.Ctx (T);
      After : constant Unit_Table := Charged (B, D);
      CM    : constant Model := Charged_Model (B, D);
   begin
      Lemma_Sum_Charged (B, D);
      Lemma_Spent_Fits (B, D, S);
      pragma Assert (After (S) = B.Remaining (S));
      pragma Assert (CM.Debt (S) = B.Debt (S));
      pragma Assert (for all G in Thread_Id => B.Debt (G) <= CM.Debt (G));
      Lemma_Refill_Mono (CM, B);
      pragma Assert (Refilled (CM) (S) = Refilled (B) (S));

      if Any_Eligible (CM) then
         pragma Assert (A.Remaining = After);
         pragma Assert (A.Debt = CM.Debt);
         pragma Assert (Refilled (A) = Refilled (CM));
         Lemma_Others_Mono (Refilled (A), Refilled (B), S);
         pragma Assert
           (Others_Sum (A.Remaining, S) + Work (Spent (B, D))
            = Others_Sum (B.Remaining, S));
      else
         pragma Assert (not Eligible (CM, T));
         pragma Assert (CM.Remaining (S) = 0);
         pragma Assert (B.Remaining (S) = 0);
         pragma Assert (B.States (S) /= Free);
         pragma Assert (A.Remaining = Refilled (CM));
         pragma Assert (A.Remaining (S) > 0);
         Lemma_Others_Mono (Refilled (CM), Refilled (B), S);
      end if;
   end Lemma_Bounded_Wait;

   procedure Lemma_Bounded_Wait_Charged
     (B : Model; A : Model; D : Units; S : Thread_Id)
   is
   begin
      Lemma_Sum_Charged (B, D);
      Lemma_Spent_Fits (B, D, S);
      pragma Assert (Charged (B, D) (S) = B.Remaining (S));
      pragma Assert (for all G in Thread_Id => B.Debt (G) <= A.Debt (G));
      pragma Assert (A.Debt (S) = B.Debt (S));
      Lemma_Refill_Mono (A, B);
      pragma Assert (Refilled (A) (S) = Refilled (B) (S));
      Lemma_Others_Mono (Refilled (A), Refilled (B), S);
      pragma Assert
        (Others_Sum (A.Remaining, S) + Work (Spent (B, D))
         = Others_Sum (B.Remaining, S));
   end Lemma_Bounded_Wait_Charged;

   procedure Lemma_All_Time_Billed (B : Model; D : Units) is null;

   procedure Lemma_Wake_Keeps_Bound (B : Model; A : Model; S : Thread_Id) is
   begin
      pragma Assert (Refilled (A) = Refilled (B));
   end Lemma_Wake_Keeps_Bound;

   procedure Lemma_Exit_Lowers_Bound
     (B : Model; A : Model; Gone : Thread_Id; S : Thread_Id)
   is
   begin
      pragma Assert (A.Remaining (S) = B.Remaining (S));
      pragma Assert (Refilled (A) = (Refilled (B) with delta Gone => 0));
      pragma Assert (Sum (A.Remaining) <= Sum (B.Remaining));
      pragma Assert (Sum (Refilled (A)) <= Sum (Refilled (B)));
      pragma Assert (Refilled (A) (S) = Refilled (B) (S));
   end Lemma_Exit_Lowers_Bound;

   procedure Lemma_Top_Runs
     (B : Model; A : Model; D : Units; Next : Thread_Id; X : Thread_Id)
   is null;

   procedure Promote (M : in out Model; X : Thread_Id) is
   begin
      M.Cursors (Level_Of (M, X)) := Before (X);
   end Promote;

   procedure Lemma_Turn_Progress
     (B : Model; A : Model; D : Units; Next : Thread_Id; T : Thread_Id)
   is null;

   procedure Lemma_Promoted_Runs
     (B : Model; A : Model; D : Units; Next : Thread_Id; X : Thread_Id)
   is
      L : constant Priority := Level_Of (A, X);
   begin
      pragma Assert (Level_Of (A, Next) = L);
      pragma Assert (Distance (B.Cursors (L), X) = 0);
      pragma Assert (Distance (B.Cursors (L), Next) = 0);
   end Lemma_Promoted_Runs;

end Scheduler_Core;
