--  SPDX-License-Identifier: GPL-3.0-or-later
--  Cuanto de turno que se adapta al coste de cambiar de contexto.
--
--  El kernel mide cuánto tarda cada cambio de hilo y lleva una media móvil con
--  peso 1/8. El cuanto es ocho veces esa media, entre un mínimo de 1 ms y un
--  máximo de 10 ms (un tick). En hardware rápido queda en 1 ms; en una CPU
--  lenta crece para que cada turno deje trabajo útil y no se vaya entero en
--  cambiar de hilo.
--
--  Se demuestra: la media nunca desborda y queda entre la media anterior y la
--  muestra (salvo el redondeo); el cuanto está siempre entre el mínimo y el
--  máximo, y nunca por debajo de ocho veces la media salvo en el máximo. Con
--  el lema de progreso del turno, la espera entre turnos de un nivel queda por
--  debajo de Max_Threads decisiones de como mucho Max_Quantum cada una.

package Quantum_Core with
  SPARK_Mode,
  Pure
is
   type U64 is mod 2**64 with Size => 64;

   --  En unidades del reloj (10 MHz): 1 ms y 10 ms.
   Min_Quantum : constant U64 := 10_000;
   Max_Quantum : constant U64 := 100_000;
   Factor      : constant U64 := 8;

   --  Las muestras se recortan: un salto del reloj no puede disparar la media.
   function Clamp (Sample : U64) return U64 is
     (U64'Min (Sample, Max_Quantum));

   --  Por debajo de 16 unidades (1,6 us) el coste es ruido de medida y cuenta
   --  como 0: el cuanto y la rodaja quedan como sin adaptar. Así el kernel
   --  puede saltarse estas cuentas en una CPU rápida sin cambiar el resultado.
   Noise : constant U64 := 16;

   function Effective (Estimate : U64) return U64 is
     (if Estimate < Noise then 0 else Clamp (Estimate));

   --  Nueva media: E - E/8 + S/8, con E y S recortados.
   function Update (Estimate, Sample : U64) return U64 with
     Post          =>
       Update'Result <= Max_Quantum
       and then
         Update'Result
         <= U64'Max (Clamp (Estimate), Clamp (Sample))
       and then
         Update'Result + 1
         >= U64'Min (Clamp (Estimate), Clamp (Sample)),
     Export,
     Convention    => C,
     External_Name => "fb_quantum_update";

   --  El cuanto para esa media.
   function Quantum_For (Estimate : U64) return U64 with
     Post          =>
       Quantum_For'Result in Min_Quantum .. Max_Quantum
       and then
         (Quantum_For'Result = Max_Quantum
          or else Quantum_For'Result >= Factor * Effective (Estimate))
       and then (if Estimate < Noise then Quantum_For'Result = Min_Quantum),
     Export,
     Convention    => C,
     External_Name => "fb_quantum_for";

   --  El cuanto recortado a su intervalo.
   function Bounded (Quantum : U64) return U64 is
     (U64'Min (U64'Max (Quantum, Min_Quantum), Max_Quantum));

   --  La rodaja que se concede: lo que quede del presupuesto, sin pasar del
   --  cuanto. Excepción: si el presupuesto entero del contexto es menor que dos
   --  cambios de hilo, cada turno se iría en cambiar y el hilo no avanzaría
   --  nunca; entonces la rodaja es de dos cambios (sin pasar del cuanto) y lo
   --  que se pase del presupuesto se cobra como deuda. Con un presupuesto
   --  normal la rodaja nunca pasa de lo que queda: la cota de espera, que
   --  cuenta presupuesto, sigue valiendo igual.
   function Slice_For (Remaining, Budget, Quantum, Estimate : U64) return U64 with
     Post          =>
       Slice_For'Result <= Bounded (Quantum)
       and then Slice_For'Result >= U64'Min (Remaining, Bounded (Quantum))
       and then
         (if Budget >= 2 * Effective (Estimate)
          then Slice_For'Result = U64'Min (Remaining, Bounded (Quantum))
          else Slice_For'Result >= U64'Min (Bounded (Quantum), 2 * Effective (Estimate)))
       --  Lo que permite al kernel saltarse la llamada en una CPU rápida.
       and then
         (if Estimate < Noise
          then Slice_For'Result = U64'Min (Remaining, Bounded (Quantum))),
     Export,
     Convention    => C,
     External_Name => "fb_quantum_slice";

end Quantum_Core;
