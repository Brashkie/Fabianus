--  SPDX-License-Identifier: GPL-3.0-or-later
package body Sleep_Core with
  SPARK_Mode,
  Refined_State => (State => (Sleeping, Wake_At))
is
   Sleeping : Flag_Table := (others => False);
   Wake_At  : Time_Table := (others => 0);

   function Armed return Flag_Table is (Sleeping);

   function Deadlines return Time_Table is (Wake_At);

   function Arm (Thread, Deadline : U64) return U64 is
   begin
      if not Valid_Thread (Thread)
        or else Deadline = None
        or else Sleeping (Thread_Id (Thread))
      then
         return Status_Invalid;
      end if;

      Sleeping (Thread_Id (Thread)) := True;
      Wake_At (Thread_Id (Thread)) := Deadline;
      return Status_Ok;
   end Arm;

   function Disarm (Thread : U64) return U64 is
   begin
      if not Valid_Thread (Thread) then
         return Status_Invalid;
      elsif not Sleeping (Thread_Id (Thread)) then
         return Status_Not_Armed;
      end if;

      Sleeping (Thread_Id (Thread)) := False;
      return Status_Ok;
   end Disarm;

   function Earliest return U64 is
      Best : U64 := None;
   begin
      for T in Thread_Id loop
         if Sleeping (T) and then Wake_At (T) < Best then
            Best := Wake_At (T);
         end if;

         pragma Loop_Invariant
           (for all S in Thread_Id'First .. T =>
              (if Sleeping (S) then Best <= Wake_At (S)));
         pragma Loop_Invariant
           (if Best /= None
            then (for some S in Thread_Id'First .. T =>
                    Sleeping (S) and then Wake_At (S) = Best));
      end loop;

      return Best;
   end Earliest;

   function Take_Expired (Now : U64) return U64 is
   begin
      for T in Thread_Id loop
         if Sleeping (T) and then Wake_At (T) <= Now then
            Sleeping (T) := False;
            return U64 (T);
         end if;

         pragma Loop_Invariant
           (for all S in Thread_Id'First .. T =>
              (if Sleeping (S) then Wake_At (S) > Now));
         pragma Loop_Invariant (Sleeping = Sleeping'Loop_Entry);
      end loop;

      return None;
   end Take_Expired;

end Sleep_Core;
