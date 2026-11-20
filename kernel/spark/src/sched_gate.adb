with Scheduler_Core; use Scheduler_Core;

package body Sched_Gate with
  SPARK_Mode,
  Refined_State => (State => (Models, Home, Used, Started))
is
   type Model_Array is array (Hart_Id) of Model;
   type Home_Table is array (Thread_Id) of Hart_Id;
   type Used_Table is array (Thread_Id) of Boolean;

   Models : Model_Array :=
     (others =>
        (States       => (others => Free),
         Priorities   => (others => Default_Priority),
         Floors       => (others => 0),
         Levels       => (others => Default_Priority),
         Budgets      => (others => Default_Budget),
         Remaining    => (others => 0),
         Cursors      => (others => 0),
         Running      => 0,
         Eligible_Set => 0,
         Members      => (others => 0),
         Debt         => (others => 0),
         Ctx          => (0, 1, 2, 3, 4, 5, 6, 7),
         Lent         => (0, 1, 2, 3, 4, 5, 6, 7),
         Depth        => (others => 0)));

   Home : Home_Table := (others => 0);

   --  Huecos ocupados en algún hart. Create los busca aquí, con el cerrojo
   --  global, sin leer los modelos de los demás harts.
   Used : Used_Table := (others => False);

   Started : Boolean := False;

   --  Un hilo solo existe en el modelo de su hart, y su hueco consta como usado.
   function Homes_Ok return Boolean is
     (for all H in Hart_Id =>
        (for all T in Thread_Id =>
           (if T /= 0 and then Models (H).States (T) /= Free
            then Home (T) = H and then Used (T))));

   function Invariant return Boolean is
     (if Started
      then (for all H in Hart_Id => Valid (Models (H))) and then Homes_Ok)
   with Refined_Global => (Input => (Models, Home, Used, Started));

   function Is_Started return Boolean is (Started)
   with Refined_Global => (Input => Started);

   function Models_View return Model_View_Array is (Model_View_Array (Models))
   with Refined_Global => (Input => Models);

   function Home_View (Thread : Thread_Id) return Hart_Id is (Home (Thread))
   with Refined_Global => (Input => Home);

   function Shared_View return Shared_Data is
     ((Homes => Home_View_Array (Home),
       Used  => Used_View_Array (Used)))
   with Refined_Global => (Input => (Home, Used));

   function Home_Of (Thread : U64) return U64 is
     (if Thread <= Last_Id then U64 (Home (Thread_Id (Thread))) else None);

   function Valid_Id (T : U64) return Boolean is (T <= Last_Id);

   function Init return U64 is
   begin
      if Started then
         return Status_Already;
      end if;

      Models :=
        (others =>
        (States       => (0 => Ready, others => Free),
         Priorities   => (others => Default_Priority),
         Floors       => (others => 0),
         Levels       => (others => Default_Priority),
         Budgets      => (others => Default_Budget),
         Remaining    => (0 => Default_Budget, others => 0),
         Cursors      => (others => 0),
         Running      => 0,
         Eligible_Set => 1,
         Members      => (Default_Priority => 16#FF#, others => 0),
         Debt         => (others => 0),
         Ctx          => (for T in Thread_Id => T),
         Lent         => (for T in Thread_Id => T),
         Depth        => (others => 0)));
      Started := True;
      return Status_Ok;
   end Init;

   --  Un hueco que no usa ningún hart: el hilo nuevo es de Hart.
   function Create (Hart : U64) return U64 is
      H : Hart_Id;
   begin
      if not Started or else Hart > Last_Hart then
         return None;
      end if;

      H := Hart_Id (Hart);
      for T in Thread_Id range 1 .. Thread_Id'Last loop
         if not Used (T) then
            Start (Models (H), T);
            Home (T) := H;
            Used (T) := True;
            return U64 (T);
         end if;
      end loop;
      return None;
   end Create;

   function Pick (Hart, Elapsed : U64) return U64 is
      Next : Thread_Id;
   begin
      if not Started or else Hart > Last_Hart then
         return None;
      end if;

      Schedule (Models (Hart_Id (Hart)), Clamp (Elapsed), Next);
      return U64 (Next);
   end Pick;

   function Charge (Hart, Elapsed : U64) return U64 is
   begin
      if not Started or else Hart > Last_Hart then
         return Status_Invalid;
      end if;

      Charge (Models (Hart_Id (Hart)), Clamp (Elapsed));
      return Status_Ok;
   end Charge;

   function Hand_Off (Hart, Peer, Elapsed, Donate : U64) return U64 is
      Switched : Boolean;
   begin
      if not Started or else Hart > Last_Hart or else Peer = 0 or else Peer > Last_Id then
         return Status_Invalid;
      elsif not Can_Hand_Off (Models (Hart_Id (Hart)), Thread_Id (Peer)) then
         return Status_Wrong_State;
      end if;

      Hand_Off (Models (Hart_Id (Hart)), Clamp (Elapsed), Thread_Id (Peer), Donate /= 0, Switched);
      return (if Switched then Status_Ok else Status_Declined);
   end Hand_Off;

   function Hand_Off_Grant
     (Hart, Peer, Elapsed, Donate : U64; Granted, Donated : out U64) return U64
   is
      Switched : Boolean;
      H        : Hart_Id;
      P        : Thread_Id;
      Paid_By  : Thread_Id;
   begin
      Granted := 0;
      Donated := 0;
      if not Started or else Hart > Last_Hart or else Peer = 0 or else Peer > Last_Id then
         return Status_Invalid;
      end if;
      H := Hart_Id (Hart);
      P := Thread_Id (Peer);
      if not Can_Hand_Off (Models (H), P) then
         return Status_Wrong_State;
      end if;

      Paid_By := Payer (Models (H));
      Hand_Off (Models (H), Clamp (Elapsed), P, Donate /= 0, Switched);
      Granted := U64 (Models (H).Remaining (Models (H).Ctx (P)));
      Donated := (if Models (H).Ctx (P) = Paid_By then 1 else 0);
      return (if Switched then Status_Ok else Status_Declined);
   end Hand_Off_Grant;

   function Adopt_Client (Hart, Server, Client : U64) return U64 is
   begin
      if not Started
        or else Hart > Last_Hart
        or else Server = 0
        or else Server > Last_Id
        or else Client = 0
        or else Client > Last_Id
      then
         return Status_Invalid;
      elsif not Can_Adopt (Models (Hart_Id (Hart)), Thread_Id (Server), Thread_Id (Client)) then
         return Status_Wrong_State;
      end if;

      Adopt (Models (Hart_Id (Hart)), Thread_Id (Server), Thread_Id (Client));
      return Status_Ok;
   end Adopt_Client;

   function Block (Hart, Thread : U64) return U64 is
   begin
      --  El hilo 0 siempre debe poder ejecutarse.
      if not Started or else Hart > Last_Hart or else Thread = 0 or else Thread > Last_Id then
         return Status_Invalid;
      elsif Models (Hart_Id (Hart)).States (Thread_Id (Thread)) /= Ready then
         return Status_Wrong_State;
      end if;

      Block (Models (Hart_Id (Hart)), Thread_Id (Thread));
      return Status_Ok;
   end Block;

   function Unblock (Hart, Thread : U64) return U64 is
      H : Hart_Id;
   begin
      if not Started or else Hart > Last_Hart or else Thread = 0 or else Thread > Last_Id then
         return Status_Invalid;
      end if;

      H := Hart_Id (Hart);
      if Models (H).States (Thread_Id (Thread)) /= Blocked then
         return Status_Wrong_State;
      end if;

      Wake (Models (H), Thread_Id (Thread));
      return (if Top_Now (Models (H), Models (H).Running) then Status_Ok else Status_Yield);
   end Unblock;

   function Wake_Remote (Thread : U64) return U64 is
      H : Hart_Id;
   begin
      if not Started or else Thread = 0 or else Thread > Last_Id then
         return Status_Invalid;
      end if;

      H := Home (Thread_Id (Thread));
      if Models (H).States (Thread_Id (Thread)) /= Blocked then
         return Status_Wrong_State;
      end if;

      Wake (Models (H), Thread_Id (Thread));
      return (if Top_Now (Models (H), Models (H).Running) and then Models (H).Running /= 0
              then Status_Ok
              else Notify_Base + U64 (H));
   end Wake_Remote;

   function Promote (Hart, Thread : U64) return U64 is
   begin
      if not Started or else Hart > Last_Hart or else Thread > Last_Id then
         return Status_Invalid;
      elsif Models (Hart_Id (Hart)).States (Thread_Id (Thread)) = Free then
         return Status_Wrong_State;
      end if;

      Promote (Models (Hart_Id (Hart)), Thread_Id (Thread));
      return Status_Ok;
   end Promote;

   function Exit_Thread (Hart, Thread : U64) return U64 is
   begin
      if not Started or else Hart > Last_Hart or else Thread = 0 or else Thread > Last_Id then
         return Status_Invalid;
      elsif Models (Hart_Id (Hart)).States (Thread_Id (Thread)) = Free then
         return Status_Wrong_State;
      end if;

      Finish (Models (Hart_Id (Hart)), Thread_Id (Thread));
      Used (Thread_Id (Thread)) := False;
      return Status_Ok;
   end Exit_Thread;

   function Set_Params (Hart, Thread, Level, Budget : U64) return U64 is
      H : Hart_Id;
      T : Thread_Id;
   begin
      if not Started
        or else Hart > Last_Hart
        or else Thread > Last_Id
        or else Level >= U64 (Levels)
        or else Budget = 0
        or else Budget > U64 (Max_Budget)
      then
         return Status_Invalid;
      end if;

      H := Hart_Id (Hart);
      T := Thread_Id (Thread);
      if Models (H).States (T) = Free then
         return Status_Wrong_State;
      end if;

      Set_Params (Models (H), T, Priority (Level), Units (Budget));
      return Status_Ok;
   end Set_Params;

   function Boost (Thread, Level : U64) return U64 is
      T : Thread_Id;
      H : Hart_Id;
   begin
      if not Started
        or else Thread = 0
        or else Thread > Last_Id
        or else (Level /= None and then Level >= U64 (Levels))
      then
         return Status_Invalid;
      end if;

      T := Thread_Id (Thread);
      H := Home (T);
      if Models (H).States (T) = Free then
         return Status_Wrong_State;
      end if;

      Set_Floor (Models (H), T, (if Level = None then 0 else Priority (Level)));
      return (if Top_Now (Models (H), Models (H).Running) and then Models (H).Running /= 0
              then Status_Ok
              else Notify_Base + U64 (H));
   end Boost;

   function Floor_Of (Thread : U64) return U64 is
   begin
      if not Started or else Thread = 0 or else Thread > Last_Id then
         return None;
      end if;
      declare
         H : constant Hart_Id := Home (Thread_Id (Thread));
         M : Model renames Models (H);
      begin
         if M.States (Thread_Id (Thread)) = Free then
            return None;
         end if;
         return U64 (M.Floors (Thread_Id (Thread)));
      end;
   end Floor_Of;

   function Has_Floor (Thread : U64) return U64 is
   begin
      if not Started or else Thread = 0 or else Thread > Last_Id then
         return 0;
      end if;
      declare
         H : constant Hart_Id := Home (Thread_Id (Thread));
         M : Model renames Models (H);
      begin
         return (if M.States (Thread_Id (Thread)) /= Free and then M.Floors (Thread_Id (Thread)) /= 0
                 then 1 else 0);
      end;
   end Has_Floor;

   function Priority_Of (Thread : U64) return U64 is
   begin
      if Thread = 0 or else Thread > Last_Id then
         return None;
      end if;
      declare
         H : constant Hart_Id := Home (Thread_Id (Thread));
         M : Model renames Models (H);
      begin
         if M.States (Thread_Id (Thread)) = Free then
            return None;
         end if;
         return U64 (Level_Of (M, Thread_Id (Thread)));
      end;
   end Priority_Of;

   function State_Of (Hart, Thread : U64) return U64 is
   begin
      if Hart > Last_Hart or else not Valid_Id (Thread) then
         return None;
      end if;

      return
        (case Models (Hart_Id (Hart)).States (Thread_Id (Thread)) is
           when Free    => State_Code_Free,
           when Ready   => State_Code_Ready,
           when Blocked => State_Code_Blocked);
   end State_Of;

   function Slice_Of (Hart, Thread, Quantum, Estimate : U64) return U64 is
   begin
      if Hart > Last_Hart or else not Valid_Id (Thread) then
         return 0;
      end if;

      declare
         M : Model renames Models (Hart_Id (Hart));
         C : constant Thread_Id := M.Ctx (Thread_Id (Thread));
      begin
         return U64 (Quantum_Core.Slice_For
                       (Quantum_Core.U64 (M.Remaining (C)),
                        Quantum_Core.U64 (M.Budgets (C)),
                        Quantum_Core.U64 (Quantum),
                        Quantum_Core.U64 (Estimate)));
      end;
   end Slice_Of;

   function Budget_Of (Hart, Thread : U64) return U64 is
   begin
      if Hart > Last_Hart or else not Valid_Id (Thread) then
         return None;
      end if;

      declare
         M : Model renames Models (Hart_Id (Hart));
      begin
         return U64 (M.Budgets (M.Ctx (Thread_Id (Thread))));
      end;
   end Budget_Of;

   function Remaining_Of (Hart, Thread : U64) return U64 is
   begin
      if Hart > Last_Hart or else not Valid_Id (Thread) then
         return None;
      end if;

      declare
         M : Model renames Models (Hart_Id (Hart));
      begin
         return U64 (M.Remaining (M.Ctx (Thread_Id (Thread))));
      end;
   end Remaining_Of;

   function Context_Of (Hart, Thread : U64) return U64 is
   begin
      if Hart > Last_Hart or else not Valid_Id (Thread) then
         return None;
      end if;

      return U64 (Models (Hart_Id (Hart)).Ctx (Thread_Id (Thread)));
   end Context_Of;

   function Should_Yield (Hart : U64) return U64 is
   begin
      if not Started
        or else Hart > Last_Hart
        or else Top_Now (Models (Hart_Id (Hart)), Models (Hart_Id (Hart)).Running)
      then
         return 0;
      end if;

      return 1;
   end Should_Yield;

   function Alone (Hart : U64) return U64 is
     (if Started
        and then Hart <= Last_Hart
        and then
          (for all T in Thread_Id =>
             (if T /= Models (Hart_Id (Hart)).Running
              then Models (Hart_Id (Hart)).States (T) /= Ready))
      then 1
      else 0);

   function Running (Hart : U64) return U64 is
     (if Hart > Last_Hart then None else U64 (Models (Hart_Id (Hart)).Running));

end Sched_Gate;
