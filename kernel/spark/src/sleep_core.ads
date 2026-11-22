--  SPDX-License-Identifier: GPL-3.0-or-later
--  Núcleo demostrado de los hilos dormidos: cada uno espera hasta un instante.
--
--  El kernel pregunta por el vencimiento más próximo para programar el
--  temporizador, y en cada interrupción despierta a los que ya vencieron. Se
--  demuestra que el más próximo es el mínimo de los vencimientos armados, y que
--  solo se despierta a quien ya venció: nadie despierta antes de su instante.
--  Junto con que el temporizador se programa con ese mínimo, tampoco nadie se
--  queda dormido sin que haya una interrupción prevista para despertarle.
--  No es reentrante.

pragma Unevaluated_Use_Of_Old (Allow);

package Sleep_Core with
  SPARK_Mode,
  Abstract_State => State,
  Initializes    => State
is
   type U64 is mod 2**64 with Size => 64;

   Max_Threads : constant := 8;

   --  El hilo 0 es el de arranque y nunca duerme.
   type Thread_Id is range 1 .. Max_Threads - 1;
   type Flag_Table is array (Thread_Id) of Boolean;
   type Time_Table is array (Thread_Id) of U64;

   Status_Ok        : constant U64 := 0;
   Status_Invalid   : constant U64 := 1;
   Status_Not_Armed : constant U64 := 2;

   --  Ningún vencimiento, o ningún hilo.
   None : constant U64 := U64'Last;

   function Valid_Thread (T : U64) return Boolean is
     (T >= 1 and then T < U64 (Max_Threads));

   --  Qué hilos duermen, y hasta cuándo.
   function Armed return Flag_Table with
     Ghost,
     Global => (Input => State);

   function Deadlines return Time_Table with
     Ghost,
     Global => (Input => State);

   --  El hilo dormirá hasta Deadline. Status_Invalid si el hilo no es válido, ya
   --  dormía o el instante es None.
   function Arm (Thread, Deadline : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Post          =>
       (if Arm'Result = Status_Ok
        then Valid_Thread (Thread)
          and then Deadline /= None
          and then not Armed'Old (Thread_Id (Thread))
          and then Armed = (Armed'Old with delta Thread_Id (Thread) => True)
          and then
            Deadlines
            = (Deadlines'Old with delta Thread_Id (Thread) => Deadline)
        else Arm'Result = Status_Invalid
          and then Armed = Armed'Old
          and then Deadlines = Deadlines'Old),
     Export,
     Convention    => C,
     External_Name => "fb_sleep_arm";

   --  El hilo deja de dormir antes de tiempo, por ejemplo porque lo matan.
   function Disarm (Thread : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Post          =>
       Deadlines = Deadlines'Old
       and then
         (if Disarm'Result = Status_Ok
          then Valid_Thread (Thread)
            and then Armed'Old (Thread_Id (Thread))
            and then Armed = (Armed'Old with delta Thread_Id (Thread) => False)
          else Armed = Armed'Old
            and then
              (if Valid_Thread (Thread)
               then Disarm'Result = Status_Not_Armed
                 and then not Armed (Thread_Id (Thread))
               else Disarm'Result = Status_Invalid)),
     Export,
     Convention    => C,
     External_Name => "fb_sleep_disarm";

   --  El vencimiento más próximo, o None si nadie duerme.
   function Earliest return U64 with
     Global        => (Input => State),
     Post          =>
       (for all T in Thread_Id =>
          (if Armed (T) then Earliest'Result <= Deadlines (T)))
       and then
         (if Earliest'Result /= None
          then (for some T in Thread_Id =>
                  Armed (T) and then Deadlines (T) = Earliest'Result)
          else (for all T in Thread_Id => (if Armed (T) then Deadlines (T) = None))),
     Export,
     Convention    => C,
     External_Name => "fb_sleep_earliest";

   --  Saca a un hilo cuyo vencimiento ya llegó, o devuelve None si no queda
   --  ninguno: entonces todos los que duermen vencen después de Now.
   function Take_Expired (Now : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Post          =>
       Deadlines = Deadlines'Old
       and then
         (if Take_Expired'Result /= None
          then Valid_Thread (Take_Expired'Result)
            and then Armed'Old (Thread_Id (Take_Expired'Result))
            and then Deadlines (Thread_Id (Take_Expired'Result)) <= Now
            and then
              Armed
              = (Armed'Old with delta Thread_Id (Take_Expired'Result) => False)
          else Armed = Armed'Old
            and then
              (for all T in Thread_Id =>
                 (if Armed (T) then Deadlines (T) > Now))),
     Export,
     Convention    => C,
     External_Name => "fb_sleep_take_expired";

end Sleep_Core;
